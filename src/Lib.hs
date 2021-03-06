{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Lib (goodbot) where

import Control.Concurrent.STM (
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
 )
import Control.Lens (view, (&), (.~))
import Control.Monad (filterM, when)
import Control.Monad.Catch (catchAll, catchIOError)
import Control.Monad.Reader (
    MonadTrans (lift),
    ReaderT (runReaderT),
    asks,
    forM_,
    liftIO,
 )
import Data.Aeson (
    FromJSON (parseJSON),
    defaultOptions,
    eitherDecode,
    fieldLabelModifier,
    genericParseJSON,
    withObject,
    (.:),
 )
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isAlpha, isSpace, toLower)
import Data.List (delete, nub, stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Text (Text, intercalate)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (
    defaultTimeLocale,
    formatTime,
    getCurrentTime,
    getCurrentTimeZone,
    utcToLocalTime,
 )
import Data.Yaml (decodeFileEither)
import qualified Discord as D
import qualified Discord.Internal.Rest as D
import qualified Discord.Requests as D
import GHC.Generics (Generic)
import Network.Wreq (
    Response,
    defaults,
    get,
    getWith,
    header,
    param,
    responseBody,
 )
import qualified Network.Wreq as W
import System.Environment (getArgs)
import System.Random (Random (randomIO))
import Text.Read (readMaybe)

type App a = ReaderT Config D.DiscordHandler a

data Db = Db
    { dbResponses :: [Text]
    , dbActivity :: Maybe (D.ActivityType, Text)
    }
    deriving (Show, Read)

instance Read D.ActivityType where
    readsPrec _ s =
        let (at, rest) = span isAlpha s
            parsed = case at of
                "ActivityTypeGame" -> Just D.ActivityTypeGame
                "ActivityTypeWatching" -> Just D.ActivityTypeWatching
                "ActivityTypeListening" -> Just D.ActivityTypeListening
                "ActivityTypeStreaming" -> Just D.ActivityTypeStreaming
                _ -> Nothing
         in case parsed of
                Just a -> [(a, rest)]
                Nothing -> []

defaultDb :: Db
defaultDb = Db{dbResponses = ["hi"], dbActivity = Nothing}

data Config = Config
    { configDictKey :: Maybe Text
    , configUrbanKey :: Maybe Text
    , configCommandPrefix :: Text
    , configDb :: TVar Db
    , configDbFile :: FilePath
    }

data UserConfig = UserConfig
    { userConfigDiscordToken :: Text
    , userConfigDictKey :: Maybe Text
    , userConfigUrbanKey :: Maybe Text
    , userConfigCommandPrefix :: Maybe Text
    , userConfigDbFile :: Maybe FilePath
    }
    deriving (Generic, Show)

instance FromJSON UserConfig where
    parseJSON =
        genericParseJSON
            defaultOptions
                { fieldLabelModifier = stripJSONPrefix "userConfig"
                }

stripJSONPrefix :: String -> String -> String
stripJSONPrefix prefix s =
    case stripPrefix prefix s of
        Just (c : rest) -> toLower c : rest
        _ -> s

defaultConfigFile :: FilePath
defaultConfigFile = "config.yaml"

defaultDbFile :: FilePath
defaultDbFile = "db"

logText :: Text -> IO ()
logText t = do
    now <- getCurrentTime
    tz <- getCurrentTimeZone
    T.putStrLn $
        T.pack (formatTime defaultTimeLocale "%F %T" $ utcToLocalTime tz now)
            <> ": "
            <> t

logError :: Text -> IO ()
logError t = logText $ "Error: " <> t

goodbot :: IO ()
goodbot = do
    args <- getArgs
    let configFile = case args of
            [] -> defaultConfigFile
            [path] -> path
            _ -> error "too many arguments provided: expected at most 1"
    config@UserConfig{..} <-
        either (error . show) id <$> decodeFileEither configFile
    dbStr <-
        ( Just
                <$> readFile
                    (fromMaybe defaultDbFile userConfigDbFile)
            )
            `catchIOError` \_ -> return Nothing
    let db = fromMaybe defaultDb $ dbStr >>= readMaybe
    dbRef <- newTVarIO db
    userFacingError <-
        D.runDiscord
            ( D.def
                { D.discordToken = userConfigDiscordToken
                , D.discordOnStart = onStart config
                , D.discordOnEvent = eventHandler config dbRef
                , D.discordOnLog = logText
                }
            )
            `catchAll` \e -> return $ T.pack $ show e
    T.putStrLn userFacingError

onStart :: UserConfig -> D.DiscordHandler ()
onStart config =
    liftIO $ logText $ "bot started with config " <> T.pack (show config)

updateStatus :: D.ActivityType -> Maybe Text -> D.DiscordHandler ()
updateStatus activityType mactivity =
    D.sendCommand $
        D.UpdateStatus $
            D.UpdateStatusOpts
                { D.updateStatusOptsSince = Nothing
                , D.updateStatusOptsGame = case mactivity of
                    Just activity ->
                        Just $ D.Activity activity activityType Nothing
                    Nothing -> Nothing
                , D.updateStatusOptsNewStatus = D.UpdateStatusOnline
                , D.updateStatusOptsAFK = False
                }

eventHandler :: UserConfig -> TVar Db -> D.Event -> D.DiscordHandler ()
eventHandler UserConfig{..} dbRef event =
    let config =
            Config
                { configDictKey = userConfigDictKey
                , configUrbanKey = userConfigUrbanKey
                , configCommandPrefix = fromMaybe "!" userConfigCommandPrefix
                , configDb = dbRef
                , configDbFile =
                    fromMaybe defaultDbFile userConfigDbFile
                }
     in flip runReaderT config $
            case event of
                D.Ready{} -> ready dbRef
                D.MessageCreate message -> messageCreate message
                D.TypingStart typingInfo -> typingStart typingInfo
                _ -> pure ()

ready :: TVar Db -> App ()
ready dbRef = do
    Db{dbActivity = mactivity} <- liftIO $ readTVarIO dbRef
    case mactivity of
        Just (activityType, activity) ->
            lift $ updateStatus activityType $ Just activity
        Nothing -> pure ()

type CommandFunc = D.Message -> App ()
type Predicate = D.Message -> App Bool
data Command = Command
    { commandName :: Text
    , commandHelpText :: Text
    , commandFunc :: CommandFunc
    }

commands :: [Command]
commands =
    [ Command
        { commandName = "rr"
        , commandHelpText = "Play Russian Roulette!"
        , commandFunc = russianRoulette
        }
    , Command
        { commandName = "define"
        , commandHelpText = "Look up the definition of a word or phrase."
        , commandFunc = define
        }
    , Command
        { commandName = "add"
        , commandHelpText = "Add a response to be randomly selected when the bot replies after being pinged."
        , commandFunc = addResponse
        }
    , Command
        { commandName = "remove"
        , commandHelpText = "Remove a response from the bot's response pool."
        , commandFunc = removeResponse
        }
    , Command
        { commandName = "list"
        , commandHelpText = "List all responses in the response pool."
        , commandFunc = listResponses
        }
    , Command
        { commandName = "playing"
        , commandHelpText = "Set bot's activity to Playing."
        , commandFunc = setActivity D.ActivityTypeGame
        }
    , Command
        { commandName = "listeningto"
        , commandHelpText = "Set bot's activity to Listening To."
        , commandFunc = setActivity D.ActivityTypeListening
        }
    , Command
        { commandName = "watching"
        , commandHelpText = "Set bot's activity to Watching."
        , commandFunc = setActivity D.ActivityTypeWatching
        }
    , Command
        { commandName = "help"
        , commandHelpText = "Show this help."
        , commandFunc = showHelp
        }
    ]

predicates :: [(Predicate, CommandFunc)]
predicates =
    [ (isCarl, simpleReply "Carl is a cuck")
    ,
        ( mentionsMe
            ||| messageContains "@everyone"
            ||| messageContains "@here"
        , respond
        )
    ]

messageCreate :: D.Message -> App ()
messageCreate message = do
    self <- isSelf message
    if self
        then pure ()
        else do
            commandMatches <-
                filterM
                    (\Command{..} -> isCommand commandName message)
                    commands
            case commandMatches of
                (Command{..} : _) -> commandFunc message
                _ -> do
                    predicateMatches <-
                        filterM
                            (\(p, _) -> p message)
                            predicates
                    case predicateMatches of
                        ((_, c) : _) -> c message
                        _ -> pure ()

isSelf :: Predicate
isSelf message = do
    cache <- lift D.readCache
    pure $ D.userId (D._currentUser cache) == D.userId (D.messageAuthor message)

isUser :: D.UserId -> Predicate
isUser userId message = pure $ D.userId (D.messageAuthor message) == userId

isCarl :: Predicate
isCarl = isUser 235148962103951360

typingStart :: D.TypingInfo -> App ()
typingStart (D.TypingInfo userId channelId _utcTime) = do
    shouldReply <- liftIO $ (== 0) . (`mod` 1000) <$> (randomIO :: IO Int)
    when shouldReply $
        createMessage channelId $ T.pack $ "shut up <@" <> show userId <> ">"

restCall :: (FromJSON a, D.Request (r a)) => r a -> App ()
restCall request = do
    r <- lift $ D.restCall request
    case r of
        Right _ -> pure ()
        Left err -> liftIO $ logError $ T.pack $ show err

createMessage :: D.ChannelId -> Text -> App ()
createMessage channelId message =
    let chunks = T.chunksOf 2000 message
     in forM_ chunks $ \chunk -> restCall $ D.CreateMessage channelId chunk

createGuildBan :: D.GuildId -> D.UserId -> Text -> App ()
createGuildBan guildId userId banMessage =
    restCall $
        D.CreateGuildBan
            guildId
            userId
            (D.CreateGuildBanOpts Nothing (Just banMessage))

fromBot :: D.Message -> Bool
fromBot m = D.userIsBot (D.messageAuthor m)

russianRoulette :: CommandFunc
russianRoulette message = do
    chamber <- liftIO $ (`mod` 6) <$> (randomIO :: IO Int)
    case (chamber, D.messageGuild message) of
        (0, Just gId) -> do
            createMessage (D.messageChannel message) response
            createGuildBan gId (D.userId $ D.messageAuthor message) response
          where
            response = "Bang!"
        _ -> createMessage (D.messageChannel message) "Click."

data Definition = Definition
    { defPartOfSpeech :: Maybe Text
    , defDefinitions :: [Text]
    }
    deriving (Show)

instance FromJSON Definition where
    parseJSON = withObject "Definition" $ \v -> do
        partOfSpeech <- v .: "fl"
        definitions <- v .: "shortdef"
        pure
            Definition
                { defPartOfSpeech = partOfSpeech
                , defDefinitions = definitions
                }

stripCommand :: D.Message -> App (Maybe Text)
stripCommand message = do
    prefix <- asks configCommandPrefix
    case T.stripPrefix prefix $ D.messageText message of
        Nothing -> return Nothing
        Just withoutPrefix ->
            let withoutCommand =
                    T.dropWhile isSpace $
                        T.dropWhile (not . isSpace) withoutPrefix
             in case withoutCommand of
                    "" -> return Nothing
                    m -> return $ Just m

define :: CommandFunc
define message = do
    msg <- stripCommand message
    case msg of
        Nothing ->
            createMessage
                (D.messageChannel message)
                "Missing word/phrase to define"
        Just phrase -> do
            moutput <- getDefineOutput phrase
            case moutput of
                Just output -> createMessage (D.messageChannel message) output
                Nothing ->
                    createMessage (D.messageChannel message) $
                        "No definition found for **" <> phrase <> "**"

buildDefineOutput :: Text -> Definition -> Text
buildDefineOutput word definition =
    let definitions = case defDefinitions definition of
            [def] -> def
            defs ->
                T.intercalate "\n\n" $
                    zipWith
                        (\i def -> T.pack (show i) <> ". " <> def)
                        [1 :: Int ..]
                        defs
     in "**" <> word <> "**"
            <> ( case defPartOfSpeech definition of
                    Just partOfSpeech -> " *" <> partOfSpeech <> "*"
                    Nothing -> ""
               )
            <> "\n"
            <> definitions

getDefineOutput :: Text -> App (Maybe Text)
getDefineOutput word = do
    response <- getDictionaryResponse word
    buildDefineOutputHandleFail
        word
        (response >>= eitherDecode . view responseBody)
        $ Just $ do
            urbanResponse <- getUrbanResponse word
            buildDefineOutputHandleFail
                word
                (urbanResponse >>= decodeUrban . view responseBody)
                Nothing

buildDefineOutputHandleFail ::
    Text ->
    Either String [Definition] ->
    Maybe (App (Maybe Text)) ->
    App (Maybe Text)
buildDefineOutputHandleFail word (Right defs) _
    | not (null defs) =
        pure $
            Just $
                T.intercalate "\n\n" $
                    map (buildDefineOutput word) defs
buildDefineOutputHandleFail _ (Left err) Nothing =
    liftIO (logError $ T.pack err) >> pure Nothing
buildDefineOutputHandleFail _ (Left err) (Just fallback) =
    liftIO (logError $ T.pack err) >> fallback
buildDefineOutputHandleFail _ _ (Just fallback) = fallback
buildDefineOutputHandleFail _ (Right _) Nothing = pure Nothing

getDictionaryResponse :: Text -> App (Either String (Response BSL.ByteString))
getDictionaryResponse word = do
    mapiKey <- asks configDictKey
    case mapiKey of
        Nothing -> pure $ Left "no dictionary.com api key set"
        Just apiKey ->
            liftIO $
                fmap Right <$> get $
                    T.unpack $
                        "https://dictionaryapi.com/api/v3/references/collegiate/json/"
                            <> word
                            <> "?key="
                            <> apiKey

getUrbanResponse :: Text -> App (Either String (Response BSL.ByteString))
getUrbanResponse word = do
    mapiKey <- asks configUrbanKey
    case mapiKey of
        Nothing -> pure $ Left "no urban dictionary api key set"
        Just apiKey ->
            liftIO $
                Right
                    <$> getWith
                        (urbanOpts apiKey word)
                        "https://mashape-community-urban-dictionary.p.rapidapi.com/define"

urbanOpts :: Text -> Text -> W.Options
urbanOpts apiKey term =
    defaults
        & header "x-rapidapi-key" .~ [T.encodeUtf8 apiKey]
        & header "x-rapidapi-host" .~ ["mashape-community-urban-dictionary.p.rapidapi.com"]
        & header "useQueryString" .~ ["true"]
        & param "term" .~ [term]

newtype UrbanDefinition = UrbanDefinition {urbanDefDefinition :: [Text]}
    deriving (Show)

instance FromJSON UrbanDefinition where
    parseJSON = withObject "UrbanDefinition" $ \v -> do
        list <- v .: "list"
        defs <- traverse (.: "definition") list
        pure UrbanDefinition{urbanDefDefinition = defs}

decodeUrban :: BSL.ByteString -> Either String [Definition]
decodeUrban = fmap urbanToDictionary . eitherDecode

urbanToDictionary :: UrbanDefinition -> [Definition]
urbanToDictionary (UrbanDefinition def) =
    [Definition Nothing def | not (null def)]

mentionsMe :: Predicate
mentionsMe message = do
    cache <- lift D.readCache
    pure $
        D.userId (D._currentUser cache)
            `elem` map D.userId (D.messageMentions message)

respond :: CommandFunc
respond message = do
    db <- asks configDb
    responses <- liftIO $ dbResponses <$> readTVarIO db
    responseNum <- liftIO $ (`mod` length responses) <$> (randomIO :: IO Int)
    createMessage (D.messageChannel message) $ responses !! responseNum

showHelp :: CommandFunc
showHelp message = do
    prefix <- asks configCommandPrefix
    let helpText =
            "Commands (prefix with " <> prefix
                <> ")\n-----------------------------\n"
                <> intercalate
                    "\n"
                    ( map
                        ( \Command{..} ->
                            "**" <> commandName <> "** - " <> commandHelpText
                        )
                        commands
                    )
    createMessage (D.messageChannel message) helpText

infixl 6 |||
(|||) :: Predicate -> Predicate -> Predicate
(pred1 ||| pred2) message = do
    p1 <- pred1 message
    p2 <- pred2 message
    pure $ p1 || p2

isCommand :: Text -> Predicate
isCommand command message =
    if fromBot message
        then pure False
        else do
            prefix <- asks configCommandPrefix
            ( messageEquals (prefix <> command)
                    ||| messageStartsWith (prefix <> command <> " ")
                )
                message

messageStartsWith :: Text -> Predicate
messageStartsWith text =
    pure
        . (text `T.isPrefixOf`)
        . T.toLower
        . D.messageText

messageEquals :: Text -> Predicate
messageEquals text = pure . (text ==) . T.toLower . D.messageText

messageContains :: Text -> Predicate
messageContains text = pure . (text `T.isInfixOf`) . T.toLower . D.messageText

simpleReply :: Text -> CommandFunc
simpleReply replyText message =
    createMessage
        (D.messageChannel message)
        replyText

addResponse :: CommandFunc
addResponse message = do
    postCommand <- stripCommand message
    case postCommand of
        Nothing -> createMessage (D.messageChannel message) "Missing response to add"
        Just response -> do
            dbRef <- asks configDb
            dbFileName <- asks configDbFile
            db <- liftIO $
                atomically $ do
                    modifyTVar'
                        dbRef
                        ( \d ->
                            d{dbResponses = nub $ response : dbResponses d}
                        )
                    readTVar dbRef
            liftIO $ writeFile dbFileName $ show db
            createMessage (D.messageChannel message) $
                "Added **" <> response <> "** to responses"

removeResponse :: CommandFunc
removeResponse message = do
    postCommand <- stripCommand message
    case postCommand of
        Nothing ->
            createMessage
                (D.messageChannel message)
                "Missing response to remove"
        Just response -> do
            dbRef <- asks configDb
            dbFileName <- asks configDbFile
            oldResponses <- liftIO $ dbResponses <$> readTVarIO dbRef
            if response `elem` oldResponses
                then do
                    db <- liftIO $
                        atomically $ do
                            modifyTVar'
                                dbRef
                                ( \d ->
                                    d
                                        { dbResponses =
                                            delete response $
                                                dbResponses d
                                        }
                                )
                            readTVar dbRef
                    liftIO $ writeFile dbFileName $ show db
                    createMessage (D.messageChannel message) $
                        "Removed **" <> response <> "** from responses"
                else
                    createMessage (D.messageChannel message) $
                        "Response **" <> response <> "** not found"

listResponses :: CommandFunc
listResponses message = do
    dbRef <- asks configDb
    responses <- liftIO $ intercalate "\n" . dbResponses <$> readTVarIO dbRef
    createMessage (D.messageChannel message) responses

setActivity :: D.ActivityType -> CommandFunc
setActivity activityType message = do
    dbRef <- asks configDb
    dbFileName <- asks configDbFile
    postCommand <- stripCommand message
    case postCommand of
        Nothing -> do
            lift $ updateStatus activityType Nothing
            liftIO $
                atomically $
                    modifyTVar'
                        dbRef
                        (\d -> d{dbActivity = Nothing})
            createMessage (D.messageChannel message) "Removed status"
        Just status -> do
            lift $ updateStatus activityType $ Just status
            liftIO $
                atomically $
                    modifyTVar'
                        dbRef
                        (\d -> d{dbActivity = Just (activityType, status)})
            createMessage (D.messageChannel message) $
                "Updated status to **" <> activityTypeText <> " " <> status
                    <> "**"
    liftIO $ do
        db <- readTVarIO dbRef
        writeFile dbFileName $ show db
  where
    activityTypeText = case activityType of
        D.ActivityTypeGame -> "Playing"
        D.ActivityTypeListening -> "Listening to"
        D.ActivityTypeStreaming -> "Streaming"
        D.ActivityTypeWatching -> "Watching"

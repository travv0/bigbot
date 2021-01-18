{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Lib (bigbot) where

import Control.Applicative (Alternative (empty))
import Control.Lens ((&), (.~), (^.))
import Control.Monad (filterM, when)
import Control.Monad.Reader (MonadIO (..), MonadReader, ReaderT (runReaderT), asks, forM_)
import Data.Aeson (FromJSON (parseJSON), Value (Object), eitherDecode, (.:))
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import qualified Discord as D
import qualified Discord.Internal.Rest as D
import qualified Discord.Requests as D
import Network.Wreq (Response, defaults, get, getWith, header, param, responseBody)
import qualified Network.Wreq as W
import System.Environment (getEnv, lookupEnv)
import System.Random (Random (randomIO))

data Config = Config
    { configDiscordHandle :: D.DiscordHandle
    , configDictKey :: Text
    , configUrbanKey :: Text
    }

bigbot :: IO ()
bigbot = do
    token <- T.pack <$> getEnv "BIGBOT_TOKEN"
    dictKey <- T.pack <$> getEnv "BIGBOT_DICT_KEY"
    urbanKey <- T.pack <$> getEnv "BIGBOT_URBAN_KEY"
    activityName <- fmap T.pack <$> lookupEnv "BIGBOT_ACTIVITY"
    userFacingError <-
        D.runDiscord $
            D.def
                { D.discordToken = token
                , D.discordOnStart = onStart activityName
                , D.discordOnEvent = eventHandler dictKey urbanKey
                , D.discordOnLog = T.putStrLn
                }
    T.putStrLn userFacingError

onStart :: Maybe Text -> D.DiscordHandle -> IO ()
onStart mactivity dis =
    D.sendCommand dis $
        D.UpdateStatus $
            D.UpdateStatusOpts
                { D.updateStatusOptsSince = Nothing
                , D.updateStatusOptsGame = case mactivity of
                    Just activity -> Just $ D.Activity activity D.ActivityTypeGame Nothing
                    Nothing -> Nothing
                , D.updateStatusOptsNewStatus = D.UpdateStatusOnline
                , D.updateStatusOptsAFK = False
                }

eventHandler :: Text -> Text -> D.DiscordHandle -> D.Event -> IO ()
eventHandler dictKey urbanKey dis event = do
    let config =
            Config
                { configDiscordHandle = dis
                , configDictKey = dictKey
                , configUrbanKey = urbanKey
                }
    flip runReaderT config $ case event of
        D.MessageCreate message -> messageCreate message
        D.TypingStart typingInfo -> typingStart typingInfo
        _ -> pure ()

type Command m = D.Message -> m ()
type CommandPredicate m = D.Message -> m Bool

commands :: (MonadIO m, MonadReader Config m) => [(CommandPredicate m, Command m)]
commands =
    [ (isRussianRoulette, russianRoulette)
    , (isDefine, define)
    , (mentionsMe, respond)
    ]

messageCreate :: (MonadIO m, MonadReader Config m) => D.Message -> m ()
messageCreate message
    | not (fromBot message) = do
        matches <- filterM (\(p, _) -> p message) commands
        case matches of
            ((_, cmd) : _) -> cmd message
            _ -> return ()
    | D.userId (D.messageAuthor message) == 235148962103951360 =
        simpleReply "Carl is a cuck" message
    | otherwise = return ()

typingStart :: (MonadIO m, MonadReader Config m) => D.TypingInfo -> m ()
typingStart (D.TypingInfo userId channelId _utcTime) = do
    shouldReply <- liftIO $ (== 0) . (`mod` 1000) <$> (randomIO :: IO Int)
    when shouldReply $
        createMessage channelId $ T.pack $ "shut up <@" <> show userId <> ">"

restCall :: (MonadReader Config m, MonadIO m, FromJSON a, D.Request (r a)) => r a -> m ()
restCall request = do
    dis <- asks configDiscordHandle
    r <- liftIO $ D.restCall dis request
    case r of
        Right _ -> return ()
        Left err -> liftIO $ print err

createMessage :: (MonadReader Config m, MonadIO m) => D.ChannelId -> Text -> m ()
createMessage channelId message = do
    let chunks = T.chunksOf 2000 message
    forM_ chunks $ \chunk -> restCall $ D.CreateMessage channelId chunk

createGuildBan ::
    (MonadReader Config m, MonadIO m) =>
    D.GuildId ->
    D.UserId ->
    Text ->
    m ()
createGuildBan guildId userId banMessage =
    restCall $
        D.CreateGuildBan
            guildId
            userId
            (D.CreateGuildBanOpts Nothing (Just banMessage))

fromBot :: D.Message -> Bool
fromBot m = D.userIsBot (D.messageAuthor m)

russianRoulette :: (MonadIO m, MonadReader Config m) => Command m
russianRoulette message = do
    chamber <- liftIO $ (`mod` 6) <$> (randomIO :: IO Int)
    case (chamber, D.messageGuild message) of
        (0, Just gId) -> do
            createMessage (D.messageChannel message) response
            createGuildBan gId (D.userId $ D.messageAuthor message) response
          where
            response = "Bang!"
        _ -> createMessage (D.messageChannel message) "Click."

isRussianRoulette :: Applicative f => CommandPredicate f
isRussianRoulette = messageStartsWith "!rr"

data Definition = Definition
    { defPartOfSpeech :: Maybe Text
    , defDefinitions :: [Text]
    }
    deriving (Show)

instance FromJSON Definition where
    parseJSON (Object v) = do
        partOfSpeech <- v .: "fl"
        definitions <- v .: "shortdef"
        return Definition{defPartOfSpeech = partOfSpeech, defDefinitions = definitions}
    parseJSON _ = empty

define :: (MonadIO m, MonadReader Config m) => Command m
define message = do
    let (_ : wordsToDefine) = words $ T.unpack $ D.messageText message
    let phrase = unwords wordsToDefine
    moutput <- getDefineOutput phrase
    case moutput of
        Just output -> createMessage (D.messageChannel message) output
        Nothing ->
            createMessage (D.messageChannel message) $
                "No definition found for **" <> T.pack phrase <> "**"

isDefine :: Applicative f => CommandPredicate f
isDefine = messageStartsWith "!define "

buildDefineOutput :: String -> Definition -> Text
buildDefineOutput word definition = do
    let shortDefinition = defDefinitions definition
        mpartOfSpeech = defPartOfSpeech definition
        definitions = case shortDefinition of
            [def] -> def
            defs ->
                T.intercalate "\n\n" $
                    zipWith
                        (\i def -> T.pack (show i) <> ". " <> def)
                        [1 :: Int ..]
                        defs
        formattedOutput =
            "**" <> T.pack word <> "**"
                <> ( case mpartOfSpeech of
                        Just partOfSpeech -> " *" <> partOfSpeech <> "*"
                        Nothing -> ""
                   )
                <> "\n"
                <> definitions
     in formattedOutput

getDefineOutput :: (MonadIO m, MonadReader Config m) => String -> m (Maybe Text)
getDefineOutput word = do
    response <- getDictionaryResponse word
    buildDefineOutputHandleFail word (eitherDecode (response ^. responseBody)) $
        Just $ do
            urbanResponse <- getUrbanResponse word
            buildDefineOutputHandleFail word (decodeUrban (urbanResponse ^. responseBody)) Nothing

buildDefineOutputHandleFail :: MonadIO m => String -> Either String [Definition] -> Maybe (m (Maybe Text)) -> m (Maybe Text)
buildDefineOutputHandleFail word (Right defs) _
    | not (null defs) =
        return $
            Just $
                T.intercalate "\n\n" $
                    map (buildDefineOutput word) defs
buildDefineOutputHandleFail _ (Left err) Nothing = liftIO (print err) >> return Nothing
buildDefineOutputHandleFail _ (Left _) (Just fallback) = fallback
buildDefineOutputHandleFail _ _ (Just fallback) = fallback
buildDefineOutputHandleFail _ (Right _) Nothing = return Nothing

getDictionaryResponse :: (MonadIO m, MonadReader Config m) => String -> m (Response BSL.ByteString)
getDictionaryResponse word = do
    apiKey <- asks configDictKey
    liftIO $
        get $
            T.unpack $
                "https://dictionaryapi.com/api/v3/references/collegiate/json/"
                    <> T.pack word
                    <> "?key="
                    <> apiKey

getUrbanResponse :: (MonadIO m, MonadReader Config m) => String -> m (Response BSL.ByteString)
getUrbanResponse word = do
    apiKey <- asks configUrbanKey
    liftIO $
        getWith
            (urbanOpts apiKey word)
            "https://mashape-community-urban-dictionary.p.rapidapi.com/define"

urbanOpts :: Text -> String -> W.Options
urbanOpts apiKey term =
    defaults
        & header "x-rapidapi-key" .~ [T.encodeUtf8 apiKey]
        & header "x-rapidapi-host" .~ ["mashape-community-urban-dictionary.p.rapidapi.com"]
        & header "useQueryString" .~ ["true"]
        & param "term" .~ [T.pack term]

newtype UrbanDefinition = UrbanDefinition {urbanDefDefinition :: [Text]}
    deriving (Show)

instance FromJSON UrbanDefinition where
    parseJSON (Object v) = do
        list <- v .: "list"
        defs <- traverse (.: "definition") list
        return UrbanDefinition{urbanDefDefinition = defs}
    parseJSON _ = empty

decodeUrban :: BSL.ByteString -> Either String [Definition]
decodeUrban = fmap urbanToDictionary . eitherDecode

urbanToDictionary :: UrbanDefinition -> [Definition]
urbanToDictionary (UrbanDefinition def) =
    [Definition Nothing def | not (null def)]

mentionsMe :: (MonadReader Config m, MonadIO m) => D.Message -> m Bool
mentionsMe message = do
    dis <- asks configDiscordHandle
    cache <- liftIO $ D.readCache dis
    return $ D.userId (D._currentUser cache) `elem` map D.userId (D.messageMentions message)

respond :: (MonadIO m, MonadReader Config m) => Command m
respond message
    | "thanks" `T.isInfixOf` T.toLower (D.messageText message)
        || "thank you" `T.isInfixOf` T.toLower (D.messageText message)
        || "thx" `T.isInfixOf` T.toLower (D.messageText message)
        || "thk" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "u r welcome"
    | "hi" `T.isInfixOf` T.toLower (D.messageText message)
        || "hello" `T.isInfixOf` T.toLower (D.messageText message)
        || "yo" `T.isInfixOf` T.toLower (D.messageText message)
        || "sup" `T.isInfixOf` T.toLower (D.messageText message)
        || ( "what" `T.isInfixOf` T.toLower (D.messageText message)
                && "up" `T.isInfixOf` T.toLower (D.messageText message)
           )
        || "howdy" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "hi"
    | "wb" `T.isInfixOf` T.toLower (D.messageText message)
        || "welcom" `T.isInfixOf` T.toLower (D.messageText message)
        || "welcum" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "thx"
    | "mornin" `T.isInfixOf` T.toLower (D.messageText message)
        || "gm" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "gm"
    | "night" `T.isInfixOf` T.toLower (D.messageText message)
        || "gn" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "gn"
    | "how" `T.isInfixOf` T.toLower (D.messageText message)
        && ( " u" `T.isInfixOf` T.toLower (D.messageText message)
                || " you" `T.isInfixOf` T.toLower (D.messageText message)
           ) =
        createMessage (D.messageChannel message) "i am fine thank u and u?"
    | otherwise = do
        let responses = ["what u want", "stfu", "u r ugly", "i love u"]
        responseNum <- liftIO $ (`mod` length responses) <$> (randomIO :: IO Int)
        createMessage (D.messageChannel message) $ responses !! responseNum

messageStartsWith :: Applicative f => Text -> CommandPredicate f
messageStartsWith text =
    pure
        . (text `T.isPrefixOf`)
        . T.toLower
        . D.messageText

simpleReply :: (MonadIO m, MonadReader Config m) => Text -> Command m
simpleReply replyText message =
    createMessage
        (D.messageChannel message)
        replyText

{-|
Module      : Async.Worker.Broker.Redis
Description : Redis broker functionality
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX

Based on lists:
https://redis.io/glossary/redis-queue/

The design is as follows:
- for each queue we have an 'id counter'
- each queue is represented as a set of message ids
- each message is stored under unique key, derived from its id
- the above allows us to have an archive with messages
- deleting a message means removing it's unique key from Redis

The queue itself is a list, the archive is a set (so that we can use
SISMEMBER).
-}


{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
    
module Async.Worker.Broker.Redis
  ( RedisBroker
  , BrokerInitParams(..)
  , RedisWithMsgId(..) )
where

import Async.Worker.Broker.Types (MessageBroker(..), Queue, SerializableMessage, TimeoutS(..), renderQueue)
-- import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.=), withObject, object, withScientific)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (catMaybes, fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.UnixTime (getUnixTime, UnixTime(..))
import Database.Redis qualified as Redis
import Foreign.C.Types (CTime(..))
import Text.Read (readMaybe)


data RedisBroker

instance (SerializableMessage a, Show a) => MessageBroker RedisBroker a where
  data Broker RedisBroker a =
    RedisBroker' {
        conn :: Redis.Connection
      }
  data BrokerMessage RedisBroker a =
    RedisBM (RedisWithMsgId a)
    deriving (Show)
  data Message RedisBroker a = RedisM a
  data MessageId RedisBroker = RedisMid Int
    deriving (Eq, Show, Ord)
  data BrokerInitParams RedisBroker a = RedisBrokerInitParams Redis.ConnectInfo

  messageId (RedisBM (RedisWithMsgId { rmidId })) = RedisMid rmidId
  getMessage (RedisBM (RedisWithMsgId { rmida })) = RedisM rmida
  toMessage message = RedisM message
  toA (RedisM message) = message
  initBroker (RedisBrokerInitParams connInfo) = do
    conn <- Redis.checkedConnect connInfo
    pure $ RedisBroker' { conn }
  deinitBroker (RedisBroker' { conn }) = Redis.disconnect conn
  
  -- createQueue (RedisBroker' { conn }) queue = do
  createQueue _broker _queue = do
    -- No need to actually pre-create queues
    return ()

  -- dropQueue (RedisBroker' { conn }) queue = do
  dropQueue (RedisBroker' { conn }) queue = do
    let queueK = queueKey queue
    void $ Redis.runRedis conn $ Redis.del [queueK]

  -- TODO This is simplified
  readMessageWaiting = popMessageWaiting

  popMessageWaiting b@(RedisBroker' { conn }) queue = loop
    where
      queueK = queueKey queue
      loop = do
        -- 0 means block indefinitely
        -- https://redis.io/docs/latest/commands/blpop/
        eData <- Redis.runRedis conn $ Redis.blpop [queueK] 0
        case eData of
          Left _ -> undefined
          Right Nothing -> undefined
          Right (Just (_queueK, msgIdBS)) -> case bsToId msgIdBS of
            Nothing -> undefined
            Just msgId -> do
              mMsg <- getRedisMessage b queue msgId
              maybe undefined return mMsg

  -- popMessageWaiting b@(RedisBroker' { conn }) queue = loop
  --   where
  --     queueK = queueKey queue
  --     loop = do
  --       eMsgId <- Redis.runRedis conn $ Redis.spop queueK
  --       case eMsgId of
  --         Left _ -> undefined
  --         Right Nothing -> do
  --           threadDelay (10*1000)
  --           popMessageWaiting b queue
  --         Right (Just msgIdBS) -> case bsToId msgIdBS of
  --           Nothing -> undefined
  --           Just msgId -> do
  --             mMsg <- getRedisMessage b queue msgId
  --             case mMsg of
  --               Nothing -> undefined
  --               Just msg -> return msg
                
  setMessageTimeout (RedisBroker' { conn }) queue msgId (TimeoutS timeoutS) = do
    ut <- getUnixTime
    void $ Redis.runRedis conn $ do
      let CTime t = utSeconds ut
      let ms = fromIntegral (utMicroSeconds ut) :: Integer
      Redis.hset queueK (idToBS msgId) (BSC.pack $ (show $ toInteger t + fromIntegral timeoutS) <> "." <> show ms)
    where
      queueK = messageTimeoutKey queue

  sendMessage b@(RedisBroker' { conn }) queue (RedisM message) = do
    mId <- nextId b queue
    case mId of
      Nothing -> undefined
      Just id' -> do
        let msgId = RedisMid id'
        let m = RedisWithMsgId { rmidId = id', rmida = message }
        let msgK = messageKey queue msgId
        let queueK = queueKey queue
        void $ Redis.runRedis conn $ do
          -- write the message itself under unique key
          _ <- Redis.set msgK (BSL.toStrict $ Aeson.encode m)
          -- add message id to the list
          -- Redis.sadd queueK [idToBS msgId]
          Redis.lpush queueK [idToBS msgId]
        return msgId

  -- | TODO Not implemented
  sendMessageDelayed b queue message _t = sendMessage b queue message

  -- deleteMessage (RedisBroker' { conn }) queue (RedisMid msgId) = do
  deleteMessage (RedisBroker' { conn }) queue msgId = do
    let queueK = queueKey queue
    let messageK = messageKey queue msgId
    let timeoutK = messageTimeoutKey queue
    -- void $ Redis.runRedis conn $ Redis.srem queueK [idToBS msgId]
    void $ Redis.runRedis conn $ do
      void $ Redis.lrem queueK 1 (idToBS msgId)
      void $ Redis.del [messageK]
      Redis.hdel timeoutK [idToBS msgId]

  -- archiveMessage (RedisBroker' { conn }) queue (RedisMid msgId) = do
  archiveMessage (RedisBroker' { conn }) queue msgId = do
    let queueK = queueKey queue
    let archiveK = archiveKey queue
    let timeoutK = messageTimeoutKey queue
    void $ Redis.runRedis conn $ do
      void $ Redis.lrem queueK 1 (idToBS msgId)
      void $ Redis.sadd archiveK [idToBS msgId]
      Redis.hdel timeoutK [idToBS msgId]
    -- eMove <- Redis.runRedis conn $ Redis.smove queueK archiveK (idToBS msgId)
    -- case eMove of
    --   Left _ -> undefined
    --   Right True -> return ()
    --   Right False -> do
    --     -- OK so the queue might not have the id, we just add it to archive to make sure
    --     void $ Redis.runRedis conn $ Redis.sadd archiveK [idToBS msgId]

  -- TODO This is incorrect: we should include message timeout in this count
  -- getQueueSize (RedisBroker' { conn }) queue = do
  --   let queueK = queueKey queue
  --   -- eLen <- Redis.runRedis conn $ Redis.scard queueK
  --   eLen <- Redis.runRedis conn $ Redis.llen queueK
  --   case eLen of
  --     Right len -> return $ fromIntegral len
  --     Left _ -> undefined
  getQueueSize b queue = do
    msgIds <- listPendingMessageIds b queue
    pure $ length msgIds

  getArchivedMessage b@(RedisBroker' { conn }) queue msgId = do
    let archiveK = archiveKey queue
    eIsMember <- Redis.runRedis conn $ Redis.sismember archiveK (idToBS msgId)
    case eIsMember of
      Right True -> do
        getRedisMessage b queue msgId
      _ -> return Nothing

  listPendingMessageIds b@(RedisBroker' { conn }) queue = do
    let queueK = queueKey queue
    eMsgIds <- Redis.runRedis conn $ Redis.lrange queueK 0 (-1)
    case eMsgIds of
      Left _ -> return []
      Right msgIds -> do
        let msgIds' = catMaybes (bsToId <$> msgIds)
        ut <- getUnixTime
        timeouts <- mapM (getMessageTimeout b queue) msgIds'
        pure $ map fst $ filter (\(_msgId, ts) -> (fromMaybe ut ts) <= ut) $ zip msgIds' timeouts

  getMessageById b queue msgId = do
    getRedisMessage b queue msgId

getMessageTimeout :: Broker RedisBroker a -> Queue -> MessageId RedisBroker -> IO (Maybe UnixTime)
getMessageTimeout (RedisBroker' { conn }) queue msgId = do
  eData <- Redis.runRedis conn $ Redis.hget queueK (idToBS msgId)
  case eData of
    Left _ -> undefined
    Right Nothing -> pure Nothing
    Right (Just timeoutBs) -> do
      case BSC.break (== '.') timeoutBs of
        (s, ms) -> case (readMaybe $ BSC.unpack s, readMaybe $ BSC.unpack $ BSC.drop 1 ms) of
          (Just s', Just ms') -> pure $ Just $ UnixTime (CTime s') ms'
          _ -> pure Nothing
  where
    queueK = messageTimeoutKey queue

-- Helper functions for getting redis keys

-- | Redis counter is an 'Int', while sets can only store strings
idToBS :: MessageId RedisBroker -> BSC.ByteString
idToBS (RedisMid msgId) = BSL.toStrict $  Aeson.encode msgId

bsToId :: BSC.ByteString -> Maybe (MessageId RedisBroker)
bsToId bs = RedisMid <$> Aeson.decode (BSL.fromStrict bs)

-- | A global prefix used for all keys
beePrefix :: String
beePrefix = "bee-"

-- | Redis counter that returns message ids
idKey :: Queue -> BSC.ByteString
idKey queue = BSC.pack $ beePrefix <> "sequence-" <> renderQueue queue

nextId :: Broker RedisBroker a -> Queue -> IO (Maybe Int)
nextId (RedisBroker' { conn }) queue = do
  let key = idKey queue
  eId <- Redis.runRedis  conn $ Redis.incr key
  case eId of
    Right id' -> return (Just $ fromInteger id')
    _ -> return Nothing

-- | Key under which a message is stored
messageKey :: Queue -> MessageId RedisBroker -> BSC.ByteString
messageKey queue (RedisMid msgId) = queueKey queue <> BSC.pack ("-message-" <> show msgId)

-- | Key for storing the set of message ids in queue
queueKey :: Queue -> BSC.ByteString
queueKey queue = BSC.pack $ beePrefix <> "queue-" <> renderQueue queue

-- | Key for storing the set of message ids in archive
archiveKey :: Queue -> BSC.ByteString
archiveKey queue = BSC.pack $ beePrefix <> "archive-" <> renderQueue queue

-- | Key for storing message timeouts
messageTimeoutKey :: Queue -> BSC.ByteString
messageTimeoutKey queue = BSC.pack $ beePrefix <> "timeout-" <> renderQueue queue

getRedisMessage :: FromJSON a
                => Broker RedisBroker a
                -> Queue
                -> MessageId RedisBroker
                -> IO (Maybe (BrokerMessage RedisBroker a))
getRedisMessage (RedisBroker' { conn }) queue msgId = do
  let msgKey = messageKey queue msgId
  eMsg <- Redis.runRedis conn $ Redis.get msgKey
  case eMsg of
    Left _ -> return Nothing
    Right Nothing -> return Nothing
    Right (Just msg) ->
      case Aeson.decode (BSL.fromStrict msg) of
        Just dmsg -> return $ Just $ RedisBM dmsg
        Nothing -> return Nothing
    
-- | Helper datatype to store message with a unique id.
-- We fetch the id by using 'INCR'
-- https://redis.io/docs/latest/commands/incr/
data RedisWithMsgId a =
  RedisWithMsgId { rmida  :: a
                 , rmidId :: Int }
  deriving (Show, Eq)
instance FromJSON a => FromJSON (RedisWithMsgId a) where
  parseJSON = withObject "RedisWithMsgId" $ \o -> do
    rmida <- o .: "rmida"
    rmidId <- o .: "rmidId"
    return $ RedisWithMsgId { rmida, rmidId }
instance ToJSON a => ToJSON (RedisWithMsgId a) where
  toJSON (RedisWithMsgId { .. }) = toJSON $ object [
      "rmida" .= rmida
    , "rmidId" .= rmidId
    ]



instance ToJSON (MessageId RedisBroker) where
  toJSON (RedisMid i) = toJSON i
instance FromJSON (MessageId RedisBroker) where
  parseJSON = withScientific "RedisMid" $ \n ->
    case floatingOrInteger n of
      Right i -> pure $ RedisMid i
      Left (f :: Double) -> fail $ "Integer expected: " <> show f

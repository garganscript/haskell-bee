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

import Async.Worker.Broker.Types (HasBroker(..), Queue, SerializableMessage)
-- import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.=), withObject, object)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Database.Redis qualified as Redis


data RedisBroker

instance (SerializableMessage a, Show a) => HasBroker RedisBroker a where
  data Broker RedisBroker a =
    RedisBroker' {
        conn :: Redis.Connection
      }
  data BrokerMessage RedisBroker a =
    RedisBM (RedisWithMsgId a)
    deriving (Show)
  data Message RedisBroker a = RedisM a
  data MessageId RedisBroker = RedisMid Int
    deriving (Eq, Show)
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
                
  setMessageTimeout _broker _queue _msgId _timeoutS =
    pure ()

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

  -- deleteMessage (RedisBroker' { conn }) queue (RedisMid msgId) = do
  deleteMessage (RedisBroker' { conn }) queue msgId = do
    let queueK = queueKey queue
    let messageK = messageKey queue msgId
    -- void $ Redis.runRedis conn $ Redis.srem queueK [idToBS msgId]
    void $ Redis.runRedis conn $ do
      _ <- Redis.lrem queueK 1 (idToBS msgId)
      Redis.del [messageK]

  -- archiveMessage (RedisBroker' { conn }) queue (RedisMid msgId) = do
  archiveMessage (RedisBroker' { conn }) queue msgId = do
    let queueK = queueKey queue
    let archiveK = archiveKey queue
    void $ Redis.runRedis conn $ do
      _ <- Redis.lrem queueK 1 (idToBS msgId)
      Redis.sadd archiveK [idToBS msgId]
    -- eMove <- Redis.runRedis conn $ Redis.smove queueK archiveK (idToBS msgId)
    -- case eMove of
    --   Left _ -> undefined
    --   Right True -> return ()
    --   Right False -> do
    --     -- OK so the queue might not have the id, we just add it to archive to make sure
    --     void $ Redis.runRedis conn $ Redis.sadd archiveK [idToBS msgId]

  getQueueSize (RedisBroker' { conn }) queue = do
    let queueK = queueKey queue
    -- eLen <- Redis.runRedis conn $ Redis.scard queueK
    eLen <- Redis.runRedis conn $ Redis.llen queueK
    case eLen of
      Right len -> return $ fromIntegral len
      Left _ -> undefined

  getArchivedMessage b@(RedisBroker' { conn }) queue msgId = do
    let archiveK = archiveKey queue
    eIsMember <- Redis.runRedis conn $ Redis.sismember archiveK (idToBS msgId)
    case eIsMember of
      Right True -> do
        getRedisMessage b queue msgId
      _ -> return Nothing


-- Helper functions for getting redis keys

-- | Redis counter is an 'Int', while sets can only store strings
idToBS :: MessageId RedisBroker -> BS.ByteString
idToBS (RedisMid msgId) = BSL.toStrict $  Aeson.encode msgId

bsToId :: BS.ByteString -> Maybe (MessageId RedisBroker)
bsToId bs = RedisMid <$> Aeson.decode (BSL.fromStrict bs)

-- | A global prefix used for all keys
beePrefix :: String
beePrefix = "bee-"

-- | Redis counter that returns message ids
idKey :: Queue -> BS.ByteString
idKey queue = BS.pack $ beePrefix <> "sequence-" <> queue

nextId :: Broker RedisBroker a -> Queue -> IO (Maybe Int)
nextId (RedisBroker' { conn }) queue = do
  let key = idKey queue
  eId <- Redis.runRedis  conn $ Redis.incr key
  case eId of
    Right id' -> return (Just $ fromInteger id')
    _ -> return Nothing

-- | Key under which a message is stored
messageKey :: Queue -> MessageId RedisBroker -> BS.ByteString
messageKey queue (RedisMid msgId) = queueKey queue <> BS.pack ("-message-" <> show msgId)

-- | Key for storing the set of message ids in queue
queueKey :: Queue -> BS.ByteString
queueKey queue = BS.pack $ beePrefix <> "queue-" <> queue

-- | Key for storing the set of message ids in archive
archiveKey :: Queue -> BS.ByteString
archiveKey queue = BS.pack $ beePrefix <> "archive-" <> queue
              

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


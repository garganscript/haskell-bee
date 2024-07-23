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

import Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.=), withObject, object)
import Async.Worker.Broker.Types (HasBroker(..), SerializableMessage)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
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

  -- We're using simple QUEUE so we don't care about message id as we
  -- won't be deleting/archiving the messages
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
  dropQueue _broker _queue = do
    -- We don't care about this
    return ()

  readMessageWaiting q@(RedisBroker' { conn }) queue = loop
    where
      loop = do
        eMsg <- Redis.runRedis conn $ Redis.blpop [BS.pack queue] 10
        case eMsg of
          Left _ -> undefined
          Right Nothing -> readMessageWaiting q queue
          Right (Just (_queue, msg)) -> case Aeson.decode (BSL.fromStrict msg) of
            Just dmsg -> return $ RedisBM dmsg
            Nothing -> undefined

  sendMessage (RedisBroker' { conn }) queue (RedisM message) = do
    let key = "key-" <> queue
    eId <- Redis.runRedis conn $ Redis.incr $ BS.pack key
    case eId of
      Left _err -> undefined
      Right id' -> do
        let m = RedisWithMsgId { rmidId = fromIntegral id', rmida = message }
        void $ Redis.runRedis conn $ Redis.lpush (BS.pack queue) [BSL.toStrict $ Aeson.encode m]

  -- deleteMessage (RedisBroker' { conn }) queue (RedisMid msgId) = do
  deleteMessage _broker _queue _msgId = do
    -- Nothing
    return ()

  -- archiveMessage (RedisBroker' { conn }) queue (RedisMid msgId) = do
  archiveMessage _broker _queue _msgId = do
    -- Nothing
    return ()

  getQueueSize (RedisBroker' { conn }) queue = do
    eLen <- Redis.runRedis conn $ Redis.llen (BS.pack queue)
    case eLen of
      Right len -> return $ fromIntegral len
      Left _ -> return 0


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

{-|
Module      : Async.Worker.Broker.PGMQ
Description : PGMQ broker implementation
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX
-}

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
    
module Async.Worker.Broker.PGMQ
  ( PGMQBroker
  , BrokerInitParams(..) )
where

import Async.Worker.Broker.Types (HasBroker(..), SerializableMessage)
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PGMQ.Simple qualified as PGMQ
import Database.PGMQ.Types qualified as PGMQ


data PGMQBroker

instance (SerializableMessage a, Show a) => HasBroker PGMQBroker a where
  data Broker PGMQBroker a =
    PGMQBroker' {
        conn :: PSQL.Connection
      }
  data BrokerMessage PGMQBroker a = PGMQBM (PGMQ.Message a)
    deriving (Show)
  data Message PGMQBroker a = PGMQM a
  data MessageId PGMQBroker = PGMQMid Int
    deriving (Eq, Show)
  data BrokerInitParams PGMQBroker a = PGMQBrokerInitParams PSQL.ConnectInfo

  messageId (PGMQBM (PGMQ.Message { msgId })) = PGMQMid msgId
  getMessage (PGMQBM (PGMQ.Message { message })) = PGMQM message
  toMessage message = PGMQM message
  toA (PGMQM message) = message
  initBroker (PGMQBrokerInitParams connInfo) = do
    conn <- PSQL.connect connInfo
    PGMQ.initialize conn
    pure $ PGMQBroker' { conn }
  deinitBroker (PGMQBroker' { conn }) = PSQL.close conn
  
  createQueue (PGMQBroker' { conn }) queue = do
    PGMQ.createQueue conn queue

  dropQueue (PGMQBroker' { conn }) queue = do
    PGMQ.dropQueue conn queue

  readMessageWaiting q@(PGMQBroker' { conn }) queue = loop
    where
      -- loop :: PGMQ.SerializableMessage a => IO (BrokerMessage PGMQBroker' a)
      loop = do
        mMsg <- PGMQ.readMessageWithPoll conn queue 10 5 100
        case mMsg of
          Nothing -> readMessageWaiting q queue
          Just msg -> return $ PGMQBM msg

  sendMessage (PGMQBroker' { conn }) queue (PGMQM message) =
    PGMQ.sendMessage conn queue message 0

  deleteMessage (PGMQBroker' { conn }) queue (PGMQMid msgId) = do
    PGMQ.deleteMessage conn queue msgId

  archiveMessage (PGMQBroker' { conn }) queue (PGMQMid msgId) = do
    PGMQ.archiveMessage conn queue msgId

  getQueueSize (PGMQBroker' { conn }) queue = do
    mMetrics <- PGMQ.getMetrics conn queue
    case mMetrics of
      Nothing -> return 0
      Just (PGMQ.Metrics { queueLength }) -> return queueLength

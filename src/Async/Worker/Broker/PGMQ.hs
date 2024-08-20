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
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (withMVar)
import Database.PostgreSQL.LibPQ qualified as LibPQ
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PostgreSQL.Simple.Internal qualified as PSQLInternal
import Database.PGMQ.Simple qualified as PGMQ
import Database.PGMQ.Types qualified as PGMQ


data PGMQBroker

instance (SerializableMessage a, Show a) => HasBroker PGMQBroker a where
  data Broker PGMQBroker a =
    PGMQBroker' {
        conn :: PSQL.Connection
      , defaultVt :: PGMQ.VisibilityTimeout
      }
  data BrokerMessage PGMQBroker a = PGMQBM (PGMQ.Message a)
    deriving (Show)
  data Message PGMQBroker a = PGMQM a
  data MessageId PGMQBroker = PGMQMid Int
    deriving (Eq, Show)
  data BrokerInitParams PGMQBroker a = PGMQBrokerInitParams PSQL.ConnectInfo PGMQ.VisibilityTimeout

  messageId (PGMQBM (PGMQ.Message { msgId })) = PGMQMid msgId
  getMessage (PGMQBM (PGMQ.Message { message })) = PGMQM message
  toMessage message = PGMQM message
  toA (PGMQM message) = message
  initBroker (PGMQBrokerInitParams connInfo defaultVt) = do
    conn <- PSQL.connect connInfo
    -- PGMQ is quite verbose because of initialization. We can disable
    -- notices
    -- https://hackage.haskell.org/package/postgresql-simple-0.7.0.0/docs/src/Database.PostgreSQL.Simple.Internal.html#Connection
    -- https://hackage.haskell.org/package/postgresql-libpq-0.10.1.0/docs/Database-PostgreSQL-LibPQ.html#g:13
    -- https://www.postgresql.org/docs/current/libpq-notice-processing.html
    withMVar (PSQLInternal.connectionHandle conn) $ \c -> do
      LibPQ.disableNoticeReporting c
    PGMQ.initialize conn
    pure $ PGMQBroker' { conn, defaultVt }
  deinitBroker (PGMQBroker' { conn }) = PSQL.close conn
  
  createQueue (PGMQBroker' { conn }) queue = do
    PGMQ.createQueue conn queue

  dropQueue (PGMQBroker' { conn }) queue = do
    PGMQ.dropQueue conn queue

  readMessageWaiting q@(PGMQBroker' { conn, defaultVt }) queue = loop
    where
      -- loop :: PGMQ.SerializableMessage a => IO (BrokerMessage PGMQBroker' a)
      loop = do
        -- NOTE readMessageWithPoll is not thread-safe, i.e. the
        -- blocking is outside of GHC (in PostgreSQL itself) and we
        -- can't reliably use it in a highly concurrent situation.
        
        -- mMsg <- PGMQ.readMessageWithPoll conn queue 10 5 100
        mMsg <- PGMQ.readMessage conn queue defaultVt
        case mMsg of
          Nothing -> do
            -- wait a bit, then retry
            threadDelay (50 * 1000)
            readMessageWaiting q queue
          Just msg -> do
            -- TODO! we want to set message visibility timeout so that other workers don't start this job
            return $ PGMQBM msg

  popMessageWaiting q@(PGMQBroker' { conn }) queue = loop
    where
      -- loop :: PGMQ.SerializableMessage a => IO (BrokerMessage PGMQBroker' a)
      loop = do
        -- mMsg <- PGMQ.readMessageWithPoll conn queue 10 5 100
        mMsg <- PGMQ.popMessage conn queue
        case mMsg of
          Nothing -> do
            -- wait a bit, then retry
            threadDelay (50 * 1000)
            popMessageWaiting q queue
          Just msg -> do
            -- TODO! we want to set message visibility timeout so that other workers don't start this job
            return $ PGMQBM msg

  setMessageTimeout (PGMQBroker' { conn }) queue (PGMQMid msgId) timeoutS =
    PGMQ.setMessageVt conn queue msgId timeoutS

  sendMessage (PGMQBroker' { conn }) queue (PGMQM message) =
    PGMQMid <$> PGMQ.sendMessage conn queue message 0

  deleteMessage (PGMQBroker' { conn }) queue (PGMQMid msgId) = do
    PGMQ.deleteMessage conn queue msgId

  archiveMessage (PGMQBroker' { conn }) queue (PGMQMid msgId) = do
    PGMQ.archiveMessage conn queue msgId

  getQueueSize (PGMQBroker' { conn }) queue = do
    -- NOTE: pgmq.metrics is NOT a proper way to deal with messages
    -- that have vt in the future
    -- (c.f. https://github.com/tembo-io/pgmq/issues/301)
    -- mMetrics <- PGMQ.getMetrics conn queue
    -- case mMetrics of
    --   Nothing -> return 0
    --   Just (PGMQ.Metrics { queueLength }) -> return queueLength
    PGMQ.queueAvailableLength conn queue

  getArchivedMessage (PGMQBroker' { conn }) queue (PGMQMid msgId) = do
    mMsg <- PGMQ.readMessageFromArchive conn queue msgId
    pure $ PGMQBM <$> mMsg

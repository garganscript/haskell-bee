{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-|
Module      : Async.Worker.Broker.PGMQ
Description : PGMQ broker implementation
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX
-}

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns #-}
    
module Async.Worker.Broker.PGMQ
  ( PGMQBroker
  , BrokerInitParams(..) )
where

import Async.Worker.Broker.Types (MessageBroker(..), SerializableMessage, renderQueue, TimeoutS(..))
import Data.ByteString qualified as BS
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (withMVar)
import Control.DeepSeq
import Data.Aeson (FromJSON(..), ToJSON(..), withScientific)
import Data.Scientific (floatingOrInteger)
import Database.PostgreSQL.LibPQ qualified as LibPQ
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PostgreSQL.Simple.Internal qualified as PSQLInternal
import Database.PGMQ qualified as PGMQ
import GHC.Generics

data PGMQBroker

instance (SerializableMessage a, Show a) => MessageBroker PGMQBroker a where
  data Broker PGMQBroker a =
    PGMQBroker' {
        conn :: PSQL.Connection
        -- | This is the default visibility timeout.
        -- It is important to set this to something > 0, otherwise 2
        -- workers might get the same message at the same time.
        -- This value doesn't need to be large, because later you can specify
        -- 'timeout' setting in job metadata.
        -- See: https://tembo.io/pgmq/#visibility-timeout-vt
      , defaultVt :: PGMQ.VisibilityTimeout
      }
  newtype BrokerMessage PGMQBroker a = PGMQBM (PGMQ.Message a)
    deriving (Show)
  newtype Message PGMQBroker a = PGMQM a
  newtype MessageId PGMQBroker = PGMQMid Int
    deriving (Eq, Show, Ord, Generic)
  data BrokerInitParams PGMQBroker a =
      PGMQBrokerInitParams PSQL.ConnectInfo PGMQ.VisibilityTimeout
    | PGMQBrokerInitConnStr BS.ByteString PGMQ.VisibilityTimeout

  messageId (PGMQBM (PGMQ.Message { msgId })) = PGMQMid msgId
  getMessage (PGMQBM (PGMQ.Message { message })) = PGMQM message
  toMessage message = PGMQM message
  toA (PGMQM message) = message
  initBroker (PGMQBrokerInitParams connInfo defaultVt) = do
    initBroker (PGMQBrokerInitConnStr (PSQL.postgreSQLConnectionString connInfo) defaultVt)
  initBroker (PGMQBrokerInitConnStr connStr defaultVt) = do
    conn <- PSQL.connectPostgreSQL connStr
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
  
  createQueue (PGMQBroker' { conn }) (renderQueue -> queue) = do
    PGMQ.createQueue conn queue

  dropQueue (PGMQBroker' { conn }) (renderQueue -> queue) = do
    PGMQ.dropQueue conn queue

  readMessageWaiting (PGMQBroker' { conn, defaultVt }) queue = loop
    where
      -- loop :: PGMQ.SerializableMessage a => IO (BrokerMessage PGMQBroker' a)
      loop = do
        -- NOTE readMessageWithPoll is not thread-safe, i.e. the
        -- blocking is outside of GHC (in PostgreSQL itself) and we
        -- can't reliably use it in a highly concurrent situation.
        
        -- NOTE! This sets message visibility timeout so that other
        -- workers don't start this job at the same time!
        mMsg <- PGMQ.readMessage conn (renderQueue queue) defaultVt
        case mMsg of
          Nothing -> do
            -- wait a bit, then retry
            threadDelay (150 * 1000)
            loop
          Just msg -> do
            return $ PGMQBM msg

  popMessageWaiting q@(PGMQBroker' { conn }) queue = loop
    where
      -- loop :: PGMQ.SerializableMessage a => IO (BrokerMessage PGMQBroker' a)
      loop = do
        -- mMsg <- PGMQ.readMessageWithPoll conn queue 10 5 100
        mMsg <- PGMQ.popMessage conn (renderQueue queue)
        case mMsg of
          Nothing -> do
            -- wait a bit, then retry
            threadDelay (50 * 1000)
            popMessageWaiting q queue
          Just msg -> do
            -- TODO! we want to set message visibility timeout so that other workers don't start this job
            return $ PGMQBM msg

  setMessageTimeout (PGMQBroker' { conn }) (renderQueue -> queue) (PGMQMid msgId) (TimeoutS timeoutS) =
    PGMQ.setMessageVt conn queue msgId timeoutS

  sendMessage b queue message = do
    sendMessageDelayed b queue message (TimeoutS 0)

  sendMessageDelayed (PGMQBroker' { conn }) (renderQueue -> queue) (PGMQM message) (TimeoutS t) = do
    PGMQMid <$> PGMQ.safeSendMessage conn queue message t

  deleteMessage (PGMQBroker' { conn }) (renderQueue -> queue) (PGMQMid msgId) = do
    PGMQ.deleteMessage conn queue msgId

  archiveMessage (PGMQBroker' { conn }) (renderQueue -> queue) (PGMQMid msgId) = do
    PGMQ.archiveMessage conn queue msgId

  getQueueSize (PGMQBroker' { conn }) (renderQueue -> queue) = do
    -- NOTE: pgmq.metrics is NOT a proper way to deal with messages
    -- that have vt in the future
    -- (c.f. https://github.com/tembo-io/pgmq/issues/301)
    -- mMetrics <- PGMQ.getMetrics conn queue
    -- case mMetrics of
    --   Nothing -> return 0
    --   Just (PGMQ.Metrics { queueLength }) -> return queueLength
    PGMQ.queueAvailableLength conn queue

  getArchivedMessage (PGMQBroker' { conn }) (renderQueue -> queue) (PGMQMid msgId) = do
    mMsg <- PGMQ.readMessageFromArchive conn queue msgId
    pure $ PGMQBM <$> mMsg

  listPendingMessageIds (PGMQBroker' { conn }) (renderQueue -> queue) = do
    msgIds <- PGMQ.queueAvailableIds conn queue
    pure $ PGMQMid <$> msgIds

  getMessageById (PGMQBroker' { conn }) (renderQueue -> queue) (PGMQMid msgId) = do
    mMsg <- PGMQ.readMessageById conn queue msgId
    pure $ PGMQBM <$> mMsg

deriving anyclass instance NFData (MessageId PGMQBroker)

instance ToJSON (MessageId PGMQBroker) where
  toJSON (PGMQMid i) = toJSON i
instance FromJSON (MessageId PGMQBroker) where
  parseJSON = withScientific "PGMQMid" $ \n ->
    case floatingOrInteger n of
      Right i -> pure $ PGMQMid i
      Left (f :: Double) -> fail $ "Integer expected: " <> show f

{-|
Module      : Async.Worker.Types
Description : Types for the async worker
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX

Types for worker.
-}

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
    
module Async.Worker.Types
  (
    -- * Main worker state
    State(..)
  -- * Job wrapped in metadata
  , Job(..)
    -- ** Job metadata
  , JobMetadata(..)
  , defaultMetadata
    -- *** Strategies for handling finished, errored, timed-out jobs
  , ArchiveStrategy(..)
  , ErrorStrategy(..)
  , TimeoutStrategy(..)
  -- ** Job utility functions
  , getJob
  , jobTimeout
  , Timeout
  , runAction
  -- ** Actions that the worker will perform
  , PerformAction
  -- * Events emitted during job lifetime
  , WorkerJobEvent
  , WorkerMJobEvent
  -- * Other useful types and functions
  , HasWorkerBroker
  , formatStr
  , JobTimeout(..) )
where

import Async.Worker.Broker.Types (Broker, BrokerMessage, MessageBroker, Queue)
import Control.Applicative ((<|>))
import Control.Exception.Safe (Exception)
import Data.Aeson (FromJSON(..), ToJSON(..), object, (.=), (.:), withObject, withText)
import Data.Text qualified as T
import Data.Typeable (Typeable)


type ReadCount = Int
type Timeout = Int

    

-- | Strategy for archiving finished jobs
data ArchiveStrategy =
    -- | Delete message when it's done
    ASDelete
    -- | Archive message when it's done
  | ASArchive
  deriving (Eq, Show)
instance ToJSON ArchiveStrategy where
  toJSON ASDelete = toJSON ("ASDelete" :: String)
  toJSON ASArchive = toJSON ("ASArchive" :: String)
instance FromJSON ArchiveStrategy where
  parseJSON = withText "ArchiveStrategy" $ \s -> do
    case s of
      "ASDelete" -> pure ASDelete
      "ASArchive" -> pure ASArchive
      s' -> fail $ T.unpack s'
  
-- | Strategy for handling jobs with errors
data ErrorStrategy =
    -- | Delete job when it threw an error
    ESDelete
    -- | Archive job when it threw an error
  | ESArchive
    -- | Try to repeat the job when an error ocurred (at most N
    -- times), otherwise archive the job.
  | ESRepeatNElseArchive Int
  -- TODO Repeat N times
  deriving (Eq, Show)
instance ToJSON ErrorStrategy where
  toJSON ESDelete = toJSON ("ESDelete" :: String)
  toJSON ESArchive = toJSON ("ESArchive" :: String)
  toJSON (ESRepeatNElseArchive n) = toJSON $ object [ "ESRepeatNElseArchive" .= n ]
instance FromJSON ErrorStrategy where
  parseJSON v = parseText v <|> parseESRepeatN v
    where
      parseText = withText "ErrorStrategy" $ \s -> do
        case s of
          "ESDelete" -> pure ESDelete
          "ESArchive" -> pure ESArchive
          s' -> fail $ T.unpack s'
      parseESRepeatN = withObject "ESRepeatN" $ \o -> do
        n <- o .: "ESRepeatNElseArchive"
        pure $ ESRepeatNElseArchive n

-- | Strategy for handling job timeouts
data TimeoutStrategy =
    -- | Delete job when it timed out
    TSDelete
    -- | Archive job when it timed out
  | TSArchive
    -- | Repeat job when it timed out (infinitely)
  | TSRepeat
    -- | Repeat job when it timed out (at most N times), otherwise archive it
  | TSRepeatNElseArchive Int
    -- | Repeat job when it timed out (at most N times), otherwise delete it
  | TSRepeatNElseDelete Int
  deriving (Eq, Show)
instance ToJSON TimeoutStrategy where
  toJSON TSDelete = toJSON ("TSDelete" :: String)
  toJSON TSArchive = toJSON ("TSArchive" :: String)
  toJSON TSRepeat = toJSON ("TSRepeat" :: String)
  toJSON (TSRepeatNElseArchive n) = toJSON $ object [ "TSRepeatNElseArchive" .= n ]
  toJSON (TSRepeatNElseDelete n) = toJSON $ object [ "TSRepeatNElseDelete" .= n ]
instance FromJSON TimeoutStrategy where
  parseJSON v = parseText v
            <|> parseTSRepeatNElseArchive v
            <|> parseTSRepeatNElseDelete v
    where
      -- | Parser for textual formats
      parseText = withText "TimeoutStrategy (text)" $ \s -> do
        case s of
          "TSDelete" -> pure TSDelete
          "TSArchive" -> pure TSArchive
          "TSRepeat" -> pure TSRepeat
          s' -> fail $ T.unpack s'
      -- | Parser for 'TSRepeatN' object
      parseTSRepeatNElseArchive = withObject "TimeoutStrategy (TSRepeatNElseArchive)" $ \o -> do
        n <- o .: "TSRepeatNElseArchive"
        pure $ TSRepeatNElseArchive n
      parseTSRepeatNElseDelete = withObject "TimeoutStrategy (TSRepeatNElseDelete)" $ \o -> do
        n <- o .: "TSRepeatNElseDelete"
        pure $ TSRepeatNElseDelete n

    
-- | Metadata associated with a job.
data JobMetadata =
  JobMetadata {
                -- | What to do after job is finished successfully
                archiveStrategy  :: ArchiveStrategy
                -- | What to do when a job ends with error
              , errorStrategy    :: ErrorStrategy
                -- | What to do when a job ends with timeout
              , timeoutStrategy  :: TimeoutStrategy
              -- | Time after which the job is considered to time-out
              -- (in seconds).
              , timeout          :: Timeout
              -- | Read count so we know how many times this message
              -- was processed
              , readCount        :: ReadCount
              -- | A worker might have processed a task and be
              -- killed. If 'resendWhenWorkerKilled' is 'True', this
              -- job will be resent to broker and picked up
              -- later. Otherwise it will be discarded.
              , resendWhenWorkerKilled :: Bool }
  deriving (Eq, Show)
instance ToJSON JobMetadata where
  toJSON (JobMetadata { .. }) =
    toJSON $ object [
          "astrat" .= archiveStrategy
        , "estrat" .= errorStrategy
        , "tstrat" .= timeoutStrategy
        , "timeout" .= timeout
        , "readCount" .= readCount
        , "resendWhenWorkerKilled" .= resendWhenWorkerKilled
        ]
instance FromJSON JobMetadata where
  parseJSON = withObject "JobMetadata" $ \o -> do
    archiveStrategy <- o .: "astrat"
    errorStrategy <- o .: "estrat"
    timeoutStrategy <- o .: "tstrat"
    timeout <- o .: "timeout"
    readCount <- o .: "readCount"
    resendWhenWorkerKilled <- o .: "resendWhenWorkerKilled"
    return $ JobMetadata { .. }

-- | For a typical 'Job' it's probably sane to just archive it no
-- matter how it finished.
defaultMetadata :: JobMetadata
defaultMetadata =
  JobMetadata { archiveStrategy = ASArchive
              , errorStrategy = ESArchive
              , timeoutStrategy = TSArchive
              , timeout = 10
              , readCount = 0
              , resendWhenWorkerKilled = True }
    
-- | Worker 'Job' is 'a' (defining action to call via 'performAction')
-- together with associated 'JobMetadata'.
data Job a =
  Job { job :: a
      , metadata :: JobMetadata }
  deriving (Eq, Show)

-- | Given worker 'Job' 'a', return the 'a' part
getJob :: Job a -> a
getJob (Job { job }) = job
instance ToJSON a => ToJSON (Job a) where
  toJSON (Job { .. }) =
    toJSON $ object [
          "metadata" .= metadata
        , "job" .= job
        ]
instance FromJSON a => FromJSON (Job a) where
  parseJSON = withObject "Job" $ \o -> do
    metadata <- o .: "metadata"
    job <- o .: "job"
    return $ Job { .. }

-- | For a given 'Job', return it's 'timeout' value from
-- 'JobMetadata'.
jobTimeout :: Job a -> Timeout
jobTimeout (Job { metadata }) = timeout metadata
    

-- | Main state for a running worker ('b' is 'Broker', 'a' is the
-- underlying message).
--
-- 'a' is the underlying message specification and is
-- implementation-dependent, e.g. can be of JSON form
--
-- @
-- {"function": ..., "arguments": [...]}
-- @
--
-- 'Job' 'a' is worker's wrapper around that message with metadata
-- (corresponds to broker 'Async.Worker.Broker.Types.Message' 'b'
-- 'a'). 'BrokerMessage' 'b 'a', on the other hand, is what we get
-- when the broker reads that message).
--
-- Note that our underlying 'Broker' handles messages of type 'Job'
-- 'a'.
data State b a =
  State { broker            :: Broker b (Job a)
        -- | Queue associated with this worker. If you want to support
        -- more queues, spawn more workers.
        , queueName         :: Queue
        -- | Name of this worker (useful for debugging).
        , name              :: String
        -- | Actions that will be performed when message 'a' arrives.
        , performAction     :: PerformAction b a
        
        -- | Event emitted after job was received from broker
        , onMessageReceived :: WorkerJobEvent b a
        -- | Event emitted after job was finished successfully
        , onJobFinish       :: WorkerJobEvent b a
        -- | Event emitted after job timed out
        , onJobTimeout      :: WorkerJobEvent b a
        -- | Event emitted after job ended with error
        , onJobError        :: WorkerJobEvent b a
        -- | Event emitted when worker is safely killed (don't overuse it)
        , onWorkerKilledSafely :: WorkerMJobEvent b a }

-- | Helper function to call an action for given worker, for a
-- 'BrokerMessage'.
runAction :: State b a -> BrokerMessage b (Job a) -> IO ()
runAction state brokerMessage = (performAction state) state brokerMessage

type WorkerJobEvent b a = Maybe (State b a -> BrokerMessage b (Job a) -> IO ())
type WorkerMJobEvent b a = Maybe (State b a -> Maybe (BrokerMessage b (Job a)) -> IO ())

-- | Callback definition (what to execute when a message arrives)
type PerformAction b a =
  State b a -> BrokerMessage b (Job a) -> IO ()


-- | /TODO/ 'Show' 'a' could be removed. Any logging can be done as
-- part of 'on' events in 'State'.
type HasWorkerBroker b a = ( MessageBroker b (Job a), Typeable a, Typeable b, Show a )

-- | Helper function to format a string with worker name (for logging)
formatStr :: State b a -> String -> String
formatStr (State { name }) msg =
  "[" <> name <> "] " <> msg

-- | An exception, thrown when job times out
data JobTimeout b a =
  JobTimeout { jtBMessage  :: BrokerMessage b (Job a)
             , jtTimeout   :: Timeout }
deriving instance (Show (BrokerMessage b (Job a))) => Show (JobTimeout b a)
instance (Show (BrokerMessage b (Job a)), Typeable a, Typeable b) => Exception (JobTimeout b a)

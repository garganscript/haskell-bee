{-|
Module      : Async.Worker.Types
Description : Types for the async worker
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX
-}

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
    
module Async.Worker.Types
  ( ArchiveStrategy(..)
  , ErrorStrategy(..)
  , TimeoutStrategy(..)
  , JobMetadata(..)
  , defaultMetadata
  , Job(..)
  , getJob
  , jobTimeout
  , Timeout
  -- , JobMessage
  -- , WorkerBroker
  , State(..)
  , WorkerJobEvent
  , runAction
  , PerformAction
  , HasWorkerBroker
  , formatStr
  , JobTimeout(..)
  , JobException(..) )
where

import Async.Worker.Broker.Types (Broker, BrokerMessage, HasBroker, Queue)
import Control.Applicative ((<|>))
import Control.Exception.Safe (Exception, SomeException)
import Data.Aeson (FromJSON(..), ToJSON(..), object, (.=), (.:), withObject, withText)
import Data.Text qualified as T
import Data.Typeable (Typeable)


type ReadCount = Int
type Timeout = Int

    

-- | Strategy for archiving jobs
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
  
-- | Strategy of handling jobs with errors
data ErrorStrategy =
    -- | Delete job when it threw an error
    ESDelete
    -- | Archive job when it threw an error
  | ESArchive
    -- | Try to repeat the job when an error ocurred
  | ESRepeat
  -- TODO Repeat N times
  deriving (Eq, Show)
instance ToJSON ErrorStrategy where
  toJSON ESDelete = toJSON ("ESDelete" :: String)
  toJSON ESArchive = toJSON ("ESArchive" :: String)
  toJSON ESRepeat = toJSON ("ESRepeat" :: String)
instance FromJSON ErrorStrategy where
  parseJSON = withText "ErrorStrategy" $ \s -> do
    case s of
      "ESDelete" -> pure ESDelete
      "ESArchive" -> pure ESArchive
      "ESRepeat" -> pure ESRepeat
      s' -> fail $ T.unpack s'

-- | Strategy for handling timeouts
data TimeoutStrategy =
    -- | Delete job when it timed out
    TSDelete
    -- | Archive job when it timed out
  | TSArchive
    -- | Repeat job when it timed out (inifinitely)
  | TSRepeat
    -- | Repeat job when it timed out (but only maximum number of times), otherwise archive it
  | TSRepeatNElseArchive Int
    -- | Repeat job when it timed out (but only maximum number of times), otherwise delete it
  | TSRepeatNElseDelete Int
  deriving (Eq, Show)
instance ToJSON TimeoutStrategy where
  toJSON TSDelete = toJSON ("TSDelete" :: String)
  toJSON TSArchive = toJSON ("TSArchive" :: String)
  toJSON TSRepeat = toJSON ("TSRepeat" :: String)
  toJSON (TSRepeatNElseArchive n) = toJSON $ object [ ("TSRepeatNElseArchive" .= n) ]
  toJSON (TSRepeatNElseDelete n) = toJSON $ object [ ("TSRepeatNElseDelete" .= n) ]
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

    
-- | Job metadata
data JobMetadata =
  JobMetadata { archiveStrategy  :: ArchiveStrategy
              , errorStrategy    :: ErrorStrategy
              , timeoutStrategy  :: TimeoutStrategy
              -- | Time after which the job is considered to time-out
              -- (in seconds).
              , timeout          :: Timeout
              -- | Read count so we know how many times this message
              -- was processed
              , readCount        :: ReadCount }
  deriving (Eq, Show)
instance ToJSON JobMetadata where
  toJSON (JobMetadata { .. }) =
    toJSON $ object [
          ( "astrat" .= archiveStrategy )
        , ( "estrat" .= errorStrategy )
        , ( "tstrat" .= timeoutStrategy )
        , ( "timeout" .= timeout )
        , ( "readCount" .= readCount )
        ]
instance FromJSON JobMetadata where
  parseJSON = withObject "JobMetadata" $ \o -> do
    archiveStrategy <- o .: "astrat"
    errorStrategy <- o .: "estrat"
    timeoutStrategy <- o .: "tstrat"
    timeout <- o .: "timeout"
    readCount <- o .: "readCount"
    return $ JobMetadata { .. }
defaultMetadata :: JobMetadata
defaultMetadata =
  JobMetadata { archiveStrategy = ASArchive
              , errorStrategy = ESArchive
              , timeoutStrategy = TSArchive
              , timeout = 10
              , readCount = 0 }
    
-- | Worker has specific message type, because each message carries
-- | around some metadata for the worker itself
data Job a =
  Job { job :: a
      , metadata :: JobMetadata }
  deriving (Eq, Show)
getJob :: Job a -> a
getJob (Job { job }) = job
instance ToJSON a => ToJSON (Job a) where
  toJSON (Job { .. }) =
    toJSON $ object [
          ("metadata" .= metadata)
        , ("job" .= job)
        ]
instance FromJSON a => FromJSON (Job a) where
  parseJSON = withObject "Job" $ \o -> do
    metadata <- o .: "metadata"
    job <- o .: "job"
    return $ Job { .. }

jobTimeout :: Job a -> Timeout
jobTimeout (Job { metadata }) = timeout metadata
    

-- | The worker job, as it is serialized in a queue
-- type JobMessage a msgId = HasMessageId (Job a) msgId

-- | Broker associated with the abstract worker
-- type WorkerBroker b brokerMessage a msgId = Broker b brokerMessage (Job a) msgId


-- | Main state for a running worker ('b' is broker, 'a' is the
-- underlying message).
--
-- For a worker, 'a' is the underlying message specification,
-- implementation-dependent (e.g. can be of form {'function': ...,
-- 'arguments: [...]}), 'Job a' is worker's wrapper around that
-- message with metadata (corresponds to broker 'Message b a' and
-- 'BrokerMessage b a' is what we get when the broker reads that
-- message)
data (HasWorkerBroker b a) => State b a =
  State { broker            :: Broker b (Job a)
        , queueName         :: Queue  -- name of queue
        -- custom name for this worker
        , name              :: String
        , performAction     :: PerformAction b a
        
        -- | These events are useful for debugging or adding custom functionality
        , onMessageReceived :: WorkerJobEvent b a
        , onJobFinish       :: WorkerJobEvent b a
        , onJobTimeout      :: WorkerJobEvent b a
        , onJobError        :: WorkerJobEvent b a }

runAction :: (HasWorkerBroker b a) => State b a -> BrokerMessage b (Job a) -> IO ()
runAction state brokerMessage = (performAction state) state brokerMessage

type WorkerJobEvent b a = Maybe (State b a -> BrokerMessage b (Job a) -> IO ())

-- | Callback definition (what to execute when a message arrives)
-- type PerformAction broker brokerMessage a msgId =
--      (WorkerBroker broker brokerMessage a msgId, JobMessage a msgId)
--   => State broker brokerMessage a msgId -> brokerMessage -> IO ()
type PerformAction b a =
  State b a -> BrokerMessage b (Job a) -> IO ()


-- TODO 'Show a' could be removed. Any logging can be done as part of
-- 'on' events in 'State'.
type HasWorkerBroker b a = ( HasBroker b (Job a), Typeable a, Typeable b, Show a )

-- | Helper function to format a string with worker name (for logging)
formatStr :: (HasWorkerBroker b a) => State b a -> String -> String
formatStr (State { name }) msg =
  "[" <> name <> "] " <> msg

-- -- | Thrown when job times out
data JobTimeout b a =
  JobTimeout { jtBMessage  :: BrokerMessage b (Job a)
             , jtTimeout   :: Timeout }
deriving instance (HasWorkerBroker b a) => Show (JobTimeout b a)
instance (HasWorkerBroker b a) => Exception (JobTimeout b a)

data JobException b a =
  JobException { jeBMessage :: BrokerMessage b (Job a)
               , jeException :: SomeException }
deriving instance (HasWorkerBroker b a) => Show (JobException b a)
instance (HasWorkerBroker b a) => Exception (JobException b a)

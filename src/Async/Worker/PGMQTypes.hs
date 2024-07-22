{-|
Module      : Async.Worker.Types
Description : Types for the async worker
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX
-}

{-# LANGUAGE RankNTypes #-}
    
module Async.Worker.Types
  ( ArchiveStrategy(..)
  , ErrorStrategy(..)
  , TimeoutStrategy(..)
  , JobMetadata(..)
  , Job(..)
  , getJob
  , jobTimeout
  , JobMessage
  , State(..)
  , PerformAction
  , JobTimeout(..) )
where

import Control.Applicative ((<|>))
import Control.Exception (Exception)
import Data.Aeson (FromJSON(..), ToJSON(..), object, (.=), (.:), withObject, withText)
import Data.Text qualified as T
import Database.PGMQ.Types qualified as PGMQ
import Database.PostgreSQL.Simple qualified as PSQL


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
              -- | If not-empty, sets a custom visibility timeout for
              -- | a job. Otherwise, worker's State.visibilityTimeout
              -- | will be used.
              , timeout          :: Timeout }
  deriving (Eq, Show)
instance ToJSON JobMetadata where
  toJSON (JobMetadata { .. }) =
    toJSON $ object [
          ( "astrat" .= archiveStrategy )
        , ( "estrat" .= errorStrategy )
        , ( "tstrat" .= timeoutStrategy )
        , ( "timeout" .= timeout )
        ]
instance FromJSON JobMetadata where
  parseJSON = withObject "JobMetadata" $ \o -> do
    archiveStrategy <- o .: "astrat"
    errorStrategy <- o .: "estrat"
    timeoutStrategy <- o .: "tstrat"
    timeout <- o .: "timeout"
    return $ JobMetadata { .. }
    
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

jobTimeout :: Job a -> PGMQ.VisibilityTimeout
jobTimeout (Job { metadata }) = timeout metadata
    

-- | The worker job, as it is serialized in a PGMQ table
type JobMessage a = PGMQ.Message (Job a)


-- | Main state for a running worker
data State a =
  State { connectInfo       :: PSQL.ConnectInfo
        -- custom name for this worker
        , name              :: String
        , performAction     :: PerformAction a
        , queue             :: PGMQ.Queue
        -- -- | Time in seconds that the message become invisible after reading.
        -- , visibilityTimeout :: PGMQ.VisibilityTimeout
        -- | Time in seconds to wait for new messages to reach the queue. Defaults to 5.
        , maxPollSeconds    :: PGMQ.Delay
        -- | Milliseconds between the internal poll operations. Defaults to 100.
        , pollIntervalMs    :: PGMQ.PollIntervalMs }

-- | Callback definition (what to execute when a message arrives)
type PerformAction a = State a -> JobMessage a -> IO ()         


-- | Thrown when job times out
data JobTimeout =
  JobTimeout { messageId :: Int
             , vt        :: PGMQ.VisibilityTimeout }
  deriving Show
instance Exception JobTimeout

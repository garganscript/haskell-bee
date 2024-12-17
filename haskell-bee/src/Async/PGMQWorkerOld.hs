{-|
Module      : Database.PGMQ.Worker
Description : PGMQ async worker implementation
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX

NOTE: Although this module depends on 'Database.PGMQ.Simple', it does
so only in a small way. In fact we could have a different mechanism
for sending and reading tasks, as long as it can handle JSON
serialization of our jobs with respective metadata.
-}

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
    
module Database.PGMQ.Worker
  ( -- | reexports from Types
    ArchiveStrategy(..)
  , ErrorStrategy(..)
  , TimeoutStrategy(..)
  , JobMessage
  , Job(..)
  , getJob
  , State

  -- | worker functions
  , newState
  , run
  , run'
  , formatStr
  , SendJob(..)
  , mkDefaultSendJob
  , sendJob )
where

import Control.Exception (SomeException, catch, fromException, throwIO)
import Control.Monad (forever)
import Data.Maybe (fromMaybe)
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PGMQ.Simple qualified as PGMQ
import Database.PGMQ.Types qualified as PGMQ
import Database.PGMQ.Worker.Types
import System.Timeout (timeout)


-- | Helper function to define worker 'State'
newState :: (PGMQ.SerializableMessage a)
         => PSQL.ConnectInfo
         -> String
         -> PerformAction a
         -> PGMQ.Queue
         -> State a
newState connectInfo name performAction queue = State { .. }
  where
    visibilityTimeout = 10
    maxPollSeconds = 5
    pollIntervalMs = 100
    

-- | Main function to start the worker
run :: (PGMQ.SerializableMessage a)
    => State a -> IO ()
run state = do
  conn <- PSQL.connect $ connectInfo state
  run' state conn

-- | Main function to start the worker (given a 'PSQL.Connection')
run' :: forall a. (PGMQ.SerializableMessage a)
     => State a -> PSQL.Connection -> IO ()
run' state@(State { visibilityTimeout = stateVisibilityTimeout, .. }) conn = do
  PGMQ.initialize conn
  PGMQ.createQueue conn queue
  -- The whole worker is just an infinite loop
  forever loop
  where
    -- | Main looping function (describes a single loop iteration)
    loop :: IO ()
    loop = do
      -- We catch any errors that could happen so that the worker runs
      -- safely
      catch (do
        -- Read a message from queue and handle it.
        PGMQ.readMessageWithPoll conn queue stateVisibilityTimeout maxPollSeconds pollIntervalMs >>=
          handleMessage) handleLoopError

    -- | Error handling function for the whole loop
    handleLoopError :: SomeException -> IO ()
    handleLoopError err = do
      case fromException err of
        -- TODO It can happen that the queue contains
        -- ill-formatted messages. I don't yet know how to
        -- handle this case - one would have to obtain message
        -- id to properly delete that using pgmq.
        Just (PSQL.ConversionFailed {}) -> do
          putStrLn $ formatStr state $ show err
        Just _ -> do
          putStrLn $ formatStr state $ show err
        Nothing -> do
          putStrLn $ formatStr state $ "Exception: " <> show err

    -- | Main job handling function. The message could not have
    -- | arrived before read poll ended, hence the 'Maybe JobMessage'
    -- | type.
    handleMessage :: Maybe (JobMessage a) -> IO ()
    handleMessage Nothing = return ()
    handleMessage (Just msg@PGMQ.Message { message = Job { metadata = JobMetadata { .. } }, msgId }) = do
      putStrLn $ formatStr state $ "handling message " <> show msgId <> " (AS: " <> show archiveStrategy <> ", ES: " <> show errorStrategy <> ")"
      -- Immediately set visibility timeout of a job, when it's
      -- specified in job's metadata (stateVisibilityTimeout is a
      -- global property of the worker and might not reflect job's
      -- timeout specs)
      case visibilityTimeout of
        Nothing -> pure ()
        Just vt -> PGMQ.setMessageVt conn queue msgId vt
      let vt = fromMaybe stateVisibilityTimeout visibilityTimeout
    
      let archiveHandler = do
            case archiveStrategy of
              ASDelete -> do
                -- putStrLn $ formatStr state $ "deleting completed job " <> show msgId <> " (strategy: " <> show archiveStrategy <> ")"
                PGMQ.deleteMessage conn queue msgId
              ASArchive -> do
                -- putStrLn $ formatStr state $ "archiving completed job " <> show msgId <> " (strategy: " <> show archiveStrategy <> ")"
                PGMQ.archiveMessage conn queue msgId

      -- Handle errors of 'performAction'.
      let errorHandler :: SomeException -> IO ()
          errorHandler err = do
            case fromException err of
              Just (JobTimeout { messageId }) -> do
                let PGMQ.Message { readCt } = msg
                putStrLn $ formatStr state $ "timeout occured: `" <> show timeoutStrategy <> " (readCt: " <> show readCt <> ", messageId = " <> show messageId <> ")"
                
                case timeoutStrategy of
                  TSDelete -> PGMQ.deleteMessage conn queue messageId
                  TSArchive -> PGMQ.archiveMessage conn queue messageId
                  TSRepeat -> pure ()
                  TSRepeatNElseArchive n -> do
                    -- OK so this can be repeated at most 'n' times, compare 'readCt' with 'n'
                    if readCt > n then
                      PGMQ.archiveMessage conn queue messageId
                    else
                      pure ()
                  TSRepeatNElseDelete n -> do
                    -- OK so this can be repeated at most 'n' times, compare 'readCt' with 'n'
                    if readCt > n then
                      PGMQ.deleteMessage conn queue messageId
                    else
                      pure ()                      
              _ -> do
                putStrLn $ formatStr state $ "Error occured: `" <> show err
                case errorStrategy of
                  ESDelete -> PGMQ.deleteMessage conn queue msgId
                  ESArchive -> PGMQ.deleteMessage conn queue msgId
                  ESRepeat -> return ()

      (do
        mTimeout <- timeout (vt * microsecond) (performAction state msg)
        case mTimeout of
          Just _ -> archiveHandler
          Nothing -> throwIO $ JobTimeout { messageId = msgId, vt = vt }
        ) `catch` errorHandler

        
-- | Helper function to format a string with worker name (for logging)
formatStr :: State a -> String -> String
formatStr (State { name }) msg =
  "[" <> name <> "] " <> msg

microsecond :: Int
microsecond = 10^6


    

-- | Wraps parameters for the 'sendJob' function
data SendJob a =
  SendJob { conn      :: PSQL.Connection
          , queue     :: PGMQ.Queue
          , msg       :: a
          , delay     :: PGMQ.Delay
          , archStrat :: ArchiveStrategy
          , errStrat  :: ErrorStrategy
          , toStrat   :: TimeoutStrategy
          , vt        :: Maybe PGMQ.VisibilityTimeout }

-- | Create a 'SendJob' data with some defaults
mkDefaultSendJob :: PSQL.Connection
               -> PGMQ.Queue
               -> a
               -> SendJob a
mkDefaultSendJob conn queue msg =
  SendJob { conn
          , queue
          , msg
          , delay = 0
          -- | remove finished jobs
          , archStrat = ASDelete
          -- | archive errored jobs (for inspection later)
          , errStrat = ESArchive
          -- | repeat timed out jobs
          , toStrat = TSRepeat
          , vt = Nothing }
    
    
-- | Send given message as a worker job to pgmq. This wraps
-- | 'PGMQ.sendMessage' with worker job metadata.
sendJob :: (PGMQ.SerializableMessage a)
        => SendJob a -> IO ()
sendJob (SendJob { .. }) = do
  let metadata = JobMetadata { archiveStrategy = archStrat
                             , errorStrategy = errStrat
                             , timeoutStrategy = toStrat
                             , visibilityTimeout = vt }
  PGMQ.sendMessage conn queue (Job { job = msg
                                   , metadata = metadata }) delay

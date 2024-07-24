{-|
Module      : Async.Worker
Description : Abstract async worker implementation using the 'Queue' typeclass
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX

Asynchronous worker.

-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}


module Async.Worker
  ( -- * Running
    run
    -- * Sending jobs
  , sendJob
  -- ** 'SendJob' wrappers
  -- $sendJob
  , mkDefaultSendJob
  , mkDefaultSendJob'
  , sendJob'
  , SendJob(..) )
where


{- | 'Broker' class type for the underlying broker
-}
import Async.Worker.Broker
{- | Various worker types, in particular 'State'
-}
import Async.Worker.Types
import Control.Exception.Safe (catch, fromException, throwIO, SomeException)
import Control.Monad (forever)
import System.Timeout qualified as Timeout


run :: (HasWorkerBroker b a) => State b a -> IO ()
run state@(State { .. }) = do
  createQueue broker queueName
  forever loop
  where
    loop :: IO ()
    loop = do
      -- TODO try...catch for main loop. This should catch exceptions
      -- but also job timeout events (we want to stick to the practice
      -- of keeping only one try...catch in the whole function)
      catch (do
                brokerMessage <- readMessageWaiting broker queueName
                handleMessage state brokerMessage
                callWorkerJobEvent onJobFinish state brokerMessage
            ) (\err ->
        case fromException err of
          Just jt@(JobTimeout {}) -> handleTimeoutError state jt
          Nothing -> case fromException err of
            Just je@(JobException {}) -> handleJobError state je
            _ -> handleUnknownError state err)

handleMessage :: (HasWorkerBroker b a) => State b a -> BrokerMessage b (Job a) -> IO ()
handleMessage state@(State { .. }) brokerMessage = do
  callWorkerJobEvent onMessageReceived state brokerMessage
  let msgId = messageId brokerMessage
  let msg = getMessage brokerMessage
  let job' = toA msg
  putStrLn $ formatStr state $ "received job: " <> show (job job')
  let mdata = metadata job'
  let t = jobTimeout job'
  mTimeout <- Timeout.timeout (t * microsecond) (wrapPerformActionInJobException state brokerMessage)

  let archiveHandler = do
        case archiveStrategy mdata of
          ASDelete -> do
            -- putStrLn $ formatStr state $ "deleting completed job " <> show msgId <> " (strategy: " <> show archiveStrategy <> ")"
            deleteMessage broker queueName msgId
          ASArchive -> do
            -- putStrLn $ formatStr state $ "archiving completed job " <> show msgId <> " (strategy: " <> show archiveStrategy <> ")"
            archiveMessage broker queueName msgId
  
  case mTimeout of
    Just _ -> archiveHandler
    Nothing -> do
      callWorkerJobEvent onJobTimeout state brokerMessage
      throwIO $ JobTimeout { jtBMessage = brokerMessage
                           , jtTimeout = t }
  -- onMessageFetched broker queue msg


-- | It's important to know if an exception occured inside a job. This
-- way we can apply error recovering strategy and adjust this job in
-- the broker
wrapPerformActionInJobException :: (HasWorkerBroker b a) => State b a -> BrokerMessage b (Job a) -> IO ()
wrapPerformActionInJobException state@(State { onJobError }) brokerMessage = do
  catch (do
            runAction state brokerMessage
        )
    (\err -> do
        callWorkerJobEvent onJobError state brokerMessage
        let wrappedErr = JobException { jeBMessage = brokerMessage,
                                      jeException = err }
        throwIO wrappedErr
        )


callWorkerJobEvent :: (HasWorkerBroker b a)
                   => WorkerJobEvent b a
                   -> State b a
                   -> BrokerMessage b (Job a)
                   -> IO ()
callWorkerJobEvent Nothing _ _ = pure ()
callWorkerJobEvent (Just event) state brokerMessage = event state brokerMessage

handleTimeoutError :: (HasWorkerBroker b a) => State b a -> JobTimeout b a -> IO ()
handleTimeoutError state@(State { .. }) jt@(JobTimeout { .. }) = do
  putStrLn $ formatStr state $ show jt
  let msgId = messageId jtBMessage
  let job = toA $ getMessage jtBMessage
  putStrLn $ formatStr state $ "timeout for job: " <> show job
  let mdata = metadata job
  case timeoutStrategy mdata of
    TSDelete -> deleteMessage broker queueName msgId
    TSArchive -> archiveMessage broker queueName msgId
    TSRepeat -> pure ()
    TSRepeatNElseArchive n -> do
      let readCt = readCount mdata
      -- OK so this can be repeated at most 'n' times, compare 'readCt' with 'n'
      if readCt >= n then
        archiveMessage broker queueName msgId
      else do
        -- NOTE In rare cases, when worker hangs, we might lose a job
        -- here? (i.e. delete, then resend)
        -- Also, be aware that messsage id will change with resend

        -- Delete original job first
        deleteMessage broker queueName msgId
        -- Send this job again, with increased 'readCount'
        sendJob broker queueName (job { metadata = mdata { readCount = readCt + 1 } })
    TSRepeatNElseDelete _n -> do
      -- TODO Implement 'readCt'
      undefined
      -- OK so this can be repeated at most 'n' times, compare 'readCt' with 'n'
      -- if readCt > n then
      --   PGMQ.deleteMessage conn queue messageId
      -- else
      --   pure ()                      

handleJobError :: (HasWorkerBroker b a) => State b a -> JobException b a -> IO ()
handleJobError state@(State { .. }) je@(JobException {  .. }) = do
  let msgId = messageId jeBMessage
  let job = toA $ getMessage jeBMessage
  putStrLn $ formatStr state $ "error: " <> show je <> " for job " <> show job
  let mdata = metadata job
  case errorStrategy mdata of
    ESDelete -> deleteMessage broker queueName msgId
    ESArchive -> deleteMessage broker queueName msgId
    ESRepeatNElseArchive n -> do
      let readCt = readCount mdata
      if readCt >= n then
        archiveMessage broker queueName msgId
      else
        sendJob broker queueName (job { metadata = mdata { readCount = readCt + 1 } })

handleUnknownError :: (HasWorkerBroker b a) => State b a -> SomeException -> IO ()
handleUnknownError state err = do
  putStrLn $ formatStr state $ "unknown error: " <> show err

sendJob :: (HasWorkerBroker b a) => Broker b (Job a) -> Queue -> Job a -> IO ()
sendJob broker queueName job = do
  sendMessage broker queueName $ toMessage job

microsecond :: Int
microsecond = 10^(6 :: Int)


{- $sendJob
 A worker job has quite a few metadata. Here are some utilities for
 constructing them more easily.
-}

-- | Wraps parameters for the 'sendJob' function
data (HasWorkerBroker b a) => SendJob b a =
  SendJob { broker    :: Broker b (Job a)
          , queue     :: Queue
          , msg       :: a
          -- , delay     :: Delay
          , archStrat :: ArchiveStrategy
          , errStrat  :: ErrorStrategy
          , toStrat   :: TimeoutStrategy
          , timeout   :: Timeout }

-- | Create a 'SendJob' data with some defaults
mkDefaultSendJob :: HasWorkerBroker b a
                 => Broker b (Job a)
                 -> Queue
                 -> a
                 -> Timeout
                 -> SendJob b a
mkDefaultSendJob broker queue msg timeout =
  SendJob { broker
          , queue
          , msg
          -- , delay = 0
          -- | remove finished jobs
          , archStrat = ASDelete
          -- | archive errored jobs (for inspection later)
          , errStrat = ESArchive
          -- | repeat timed out jobs
          , toStrat = TSRepeat
          , timeout }


-- | Like 'mkDefaultSendJob' but with default timeout
mkDefaultSendJob' :: HasWorkerBroker b a
                  => Broker b (Job a)
                  -> Queue
                  -> a
                  -> SendJob b a
mkDefaultSendJob' b q m = mkDefaultSendJob b q m defaultTimeout
  where
    defaultTimeout = 10

    
-- | Call 'sendJob' with 'SendJob b a' data
sendJob' :: (HasWorkerBroker b a) => SendJob b a -> IO ()
sendJob' (SendJob { .. }) = do
  let metadata = JobMetadata { archiveStrategy = archStrat
                             , errorStrategy = errStrat
                             , timeoutStrategy = toStrat
                             , timeout = timeout
                             , readCount = 0 }
  let job = Job { job = msg, metadata }
  sendJob broker queue job

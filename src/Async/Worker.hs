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
  ( KillWorkerSafely(..)
  -- * Running
  , run
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
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (readTVarIO, newTVarIO, writeTVar)
import Control.Exception.Safe (catches, Handler(..), throwIO, SomeException, Exception)
import Control.Monad (forever, void, when)
import System.Timeout qualified as Timeout


-- | If you want to stop a worker safely, use `throwTo'
-- 'workerThreadId' 'KillWorkerSafely'. This way the worker will stop
-- whatever is doing now and resend the message back to the
-- broker. This way you won't lose your jobs. If you don't care about
-- resuming a job, just set 'resendWhenWorkerKilled' property to
-- 'False'.
data KillWorkerSafely = KillWorkerSafely
  deriving (Show)
instance Exception KillWorkerSafely


-- | This is the main function to start a worker. It's an infinite
-- loop of reading the next broker message, processing it and handling
-- any errors, issues that might arrise in the meantime.
run :: (HasWorkerBroker b a) => State b a -> IO ()
run state@(State { .. }) = do
  createQueue broker queueName
  forever loop
  where
    loop :: IO ()
    loop = do
      -- TVar to hold currently processed job. This is used for
      -- exception handling.
      mBrokerMessageTVar <- newTVarIO Nothing -- :: IO (TVar (Maybe (BrokerMessage b (Job a))))
      
      catches (do
                brokerMessage <- readMessageWaiting broker queueName
                atomically $ writeTVar mBrokerMessageTVar (Just brokerMessage)
                handleMessage state brokerMessage
                callWorkerJobEvent onJobFinish state brokerMessage
            ) [
        Handler $ \(_err :: KillWorkerSafely) -> do
          mBrokerMessage <- readTVarIO mBrokerMessageTVar
          case mBrokerMessage of
            Just brokerMessage -> do
              let job = toA $ getMessage brokerMessage
              let mdata = metadata job
              -- Should we resend this message?
              when (resendWhenWorkerKilled mdata) $ do
                putStrLn $ formatStr state $ "resending job: " <> show job
                void $ sendJob broker queueName (job { metadata = mdata { readCount = readCount mdata + 1 } })
                size <- getQueueSize broker queueName
                putStrLn $ formatStr state $ "queue size: " <> show size
                
              -- In any case, deinit the broker (i.e. close connection)
              -- deinitBroker broker
              
              -- kill worker
              throwIO KillWorkerSafely
            Nothing -> pure ()
        , Handler $ \(err :: JobTimeout b a) -> handleTimeoutError state err
        , Handler $ \err -> do
            mBrokerMessage <- readTVarIO mBrokerMessageTVar
            case mBrokerMessage of
              Just brokerMessage -> do
                callWorkerJobEvent onJobError state brokerMessage
                handleJobError state brokerMessage
              Nothing -> handleUnknownError state err
        ]
 
handleMessage :: (HasWorkerBroker b a) => State b a -> BrokerMessage b (Job a) -> IO ()
handleMessage state@(State { .. }) brokerMessage = do
  callWorkerJobEvent onMessageReceived state brokerMessage
  let msgId = messageId brokerMessage
  let msg = getMessage brokerMessage
  let job' = toA msg
  -- putStrLn $ formatStr state $ "received job: " <> show (job job')
  let mdata = metadata job'
  let t = jobTimeout job'
  let timeoutS = t * microsecond
  -- Inform the broker how long a task could take. This way we prevent
  -- the broker from sending this task to another worker (e.g. 'vt' in
  -- PGMQ).
  setMessageTimeout broker queueName msgId (TimeoutS timeoutS)
  -- mTimeout <- Timeout.timeout timeoutS (wrapPerformActionInJobException state brokerMessage)
  mTimeout <- Timeout.timeout timeoutS (runAction state brokerMessage)

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


-- -- | It's important to know if an exception occured inside a job. This
-- -- way we can apply error recovering strategy and adjust this job in
-- -- the broker
-- wrapPerformActionInJobException :: (HasWorkerBroker b a) => State b a -> BrokerMessage b (Job a) -> IO ()
-- wrapPerformActionInJobException state@(State { onJobError }) brokerMessage = do
--   catch (do
--             runAction state brokerMessage
--         )
--     (\(err :: SomeException) -> do
--         callWorkerJobEvent onJobError state brokerMessage
--         throwIO err
--         )


callWorkerJobEvent :: WorkerJobEvent b a
                   -> State b a
                   -> BrokerMessage b (Job a)
                   -> IO ()
callWorkerJobEvent Nothing _ _ = pure ()
callWorkerJobEvent (Just event) state brokerMessage = event state brokerMessage

handleTimeoutError :: (HasWorkerBroker b a) => State b a -> JobTimeout b a -> IO ()
handleTimeoutError _state@(State { .. }) _jt@(JobTimeout { .. }) = do
  -- putStrLn $ formatStr state $ show jt
  let msgId = messageId jtBMessage
  let job = toA $ getMessage jtBMessage
  -- putStrLn $ formatStr state $ "timeout for job: " <> show job
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

        -- Delete this job first, otherwise we'll be duplicating jobs.
        deleteMessage broker queueName msgId

        -- Send this job again, with increased 'readCount'
        void $ sendJob broker queueName (job { metadata = mdata { readCount = readCt + 1 } })
    TSRepeatNElseDelete n -> do
      let readCt = readCount mdata
      -- OK so this can be repeated at most 'n' times, compare 'readCt' with 'n'
      if readCt >= n then
        deleteMessage broker queueName msgId
      else do
        -- NOTE In rare cases, when worker hangs, we might lose a job
        -- here? (i.e. delete, then resend)
        -- Also, be aware that messsage id will change with resend

        -- Delete this job first, otherwise we'll be duplicating jobs.
        deleteMessage broker queueName msgId

        -- Send this job again, with increased 'readCount'
        void $ sendJob broker queueName (job { metadata = mdata { readCount = readCt + 1 } })

handleJobError :: (HasWorkerBroker b a) => State b a -> BrokerMessage b (Job a) -> IO ()
handleJobError _state@(State { .. }) brokerMessage = do
  let msgId = messageId brokerMessage
  let job = toA $ getMessage brokerMessage
  -- putStrLn $ formatStr state $ "error: " <> show je <> " for job " <> show job
  let mdata = metadata job
  case errorStrategy mdata of
    ESDelete -> deleteMessage broker queueName msgId
    ESArchive -> deleteMessage broker queueName msgId
    ESRepeatNElseArchive n -> do
      let readCt = readCount mdata
      if readCt >= n then
        archiveMessage broker queueName msgId
      else do
        -- Delete this job first, otherwise we'll be duplicating jobs.
        deleteMessage broker queueName msgId

        void $ sendJob broker queueName (job { metadata = mdata { readCount = readCt + 1 } })

handleUnknownError :: State b a -> SomeException -> IO ()
handleUnknownError state err = putStrLn $ formatStr state $ "unknown error: " <> show err

sendJob :: (HasWorkerBroker b a) => Broker b (Job a) -> Queue -> Job a -> IO (MessageId b)
sendJob broker queueName job = do
  sendMessage broker queueName $ toMessage job

microsecond :: Int
microsecond = 10^(6 :: Int)


{- $sendJob
 A worker job has quite a few metadata. Here are some utilities for
 constructing them more easily.
-}

-- | Wraps parameters for the 'sendJob' function
data SendJob b a =
  SendJob { broker       :: Broker b (Job a)
          , queue        :: Queue
          , msg          :: a
          -- , delay     :: Delay
          , archStrat    :: ArchiveStrategy
          , errStrat     :: ErrorStrategy
          , toStrat      :: TimeoutStrategy
          , timeout      :: Timeout
          , resendOnKill :: Bool}

-- | Create a 'SendJob' data with some defaults
mkDefaultSendJob :: Broker b (Job a)
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
          , timeout
          , resendOnKill = True }


-- | Like 'mkDefaultSendJob' but with default timeout
mkDefaultSendJob' :: Broker b (Job a)
                  -> Queue
                  -> a
                  -> SendJob b a
mkDefaultSendJob' b q m = mkDefaultSendJob b q m defaultTimeout
  where
    defaultTimeout = 10

    
-- | Call 'sendJob' with 'SendJob b a' data
sendJob' :: (HasWorkerBroker b a) => SendJob b a -> IO (MessageId b)
sendJob' (SendJob { .. }) = do
  let metadata = defaultMetadata { archiveStrategy = archStrat
                                 , errorStrategy = errStrat
                                 , timeoutStrategy = toStrat
                                 , timeout = timeout
                                 , resendWhenWorkerKilled = resendOnKill }
  let job = Job { job = msg, metadata }
  sendJob broker queue job

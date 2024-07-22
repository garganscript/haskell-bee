{-|
  Generic Worker tests.

  TODO Add tests for which there are multiple workers in the same
  queue.
-}

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonoLocalBinds #-}   -- TODO can remove this if 'Show a' is removed from 'HasWorkerBroker'
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Integration.Worker
 ( workerTests
 , pgmqWorkerBrokerInitParams
 , redisWorkerBrokerInitParams )
where

import Async.Worker (run, mkDefaultSendJob, mkDefaultSendJob', sendJob', errStrat, toStrat)
import Async.Worker.Broker.PGMQ qualified as PGMQ
import Async.Worker.Broker.Redis qualified as Redis
import Async.Worker.Broker.Types qualified as BT
import Async.Worker.Types
import Control.Concurrent (forkIO, killThread, threadDelay, ThreadId)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (readTVarIO, newTVarIO, TVar, modifyTVar)
import Control.Exception (bracket, Exception, throwIO)
import Data.Aeson (ToJSON(..), FromJSON(..), object, (.=), (.:), withObject)
import Data.Set qualified as Set
import Test.Hspec
import Test.Integration.Utils (getPSQLEnvConnectInfo, getRedisEnvConnectInfo, randomQueueName)


data TestEnv b =
  TestEnv { state  :: State b Message
          , events :: TVar [Event]
          , threadId :: ThreadId }


testQueuePrefix :: BT.Queue
testQueuePrefix = "test_worker"


-- | Messages that we will send to worker via the broker (i.e. jobs)
data Message =
    Message { text :: String }
  | Error
  | Timeout { delay :: Int }
  deriving (Show, Eq, Ord)
instance ToJSON Message where
  toJSON (Message { text }) = toJSON $ object [ "type" .= ("Message" :: String), "text" .= text ]
  toJSON Error = toJSON $ object [ "type" .= ("Error" :: String) ]
  toJSON (Timeout { delay }) = toJSON $ object [ "type" .= ("Timeout" :: String), "delay" .= delay ]
instance FromJSON Message where
  parseJSON = withObject "Message" $ \o -> do
    type_ <- o .: "type"
    case type_ of
      "Message" -> do
        text <- o .: "text"
        pure $ Message { text }
      "Error" -> pure Error
      "Timeout" -> do
        delay <- o .: "delay"
        pure $ Timeout { delay }
      _ -> fail $ "Unknown type " <> type_


-- | We will handle job events from the worker to track what and how
-- was processed
data Event =
    EMessageReceived Message
  | EJobFinished Message
  | EJobTimeout Message
  | EJobError Message
  deriving (Eq, Show, Ord)


data SimpleException = SimpleException String
  deriving Show
instance Exception SimpleException


-- | Perform Action for this worker
pa :: (HasWorkerBroker b Message) => State b a -> BT.BrokerMessage b (Job Message) -> IO ()
pa _state bm = do
  let job' = BT.toA $ BT.getMessage bm
  case job job' of
    Message { text } -> putStrLn text
    Error -> throwIO $ SimpleException "Error!"
    Timeout { delay } -> threadDelay (delay * second)


withWorker :: (HasWorkerBroker b Message)
           => BT.BrokerInitParams b (Job Message)
           -> (TestEnv b -> IO ())
           -> IO ()
withWorker brokerInitParams = bracket (setUpWorker brokerInitParams) tearDownWorker
  where
    -- NOTE I need to pass 'b' again, otherwise GHC can't infer the
    -- type of 'b' (even with 'ScopedTypeVariables' turned on)
    setUpWorker :: (HasWorkerBroker b Message)
                => BT.BrokerInitParams b (Job Message)
                -> IO (TestEnv b)
    setUpWorker bInitParams = do
      b <- BT.initBroker bInitParams

      queue <- randomQueueName testQueuePrefix
      
      BT.dropQueue b queue
      BT.createQueue b queue

      events <- newTVarIO []
      let pushEvent evt bm = atomically $ modifyTVar events (\e -> e ++ [evt $ job $ BT.toA $ BT.getMessage bm])

      let state = State { broker = b
                        , queueName = queue
                        , name = "test worker for " <> queue
                        , performAction = pa
                        , onMessageReceived = Just (\_s bm -> pushEvent EMessageReceived bm)
                        , onJobFinish = Just (\_s bm -> pushEvent EJobFinished bm)
                        , onJobTimeout = Just (\_s bm -> pushEvent EJobTimeout bm)
                        , onJobError = Just (\_s bm -> pushEvent EJobError bm) }

      threadId <- forkIO $ run state
      
      return $ TestEnv { state, events, threadId }

    tearDownWorker :: (HasWorkerBroker b Message)
                   => TestEnv b
                   -> IO ()
    tearDownWorker (TestEnv { state = State { broker = b, queueName }, threadId }) = do
      BT.dropQueue b queueName
      killThread threadId
      BT.deinitBroker b


workerTests :: (HasWorkerBroker b Message)
            => BT.BrokerInitParams b (Job Message)
            -> Spec
workerTests brokerInitParams =
  parallel $ around (withWorker brokerInitParams) $ describe "Worker tests" $ do
    it "can process a simple job" $ \(TestEnv { state = State { broker, queueName }, events }) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0
 
      let text = "simple test"
      let msg = Message { text }
      let job = mkDefaultSendJob' broker queueName msg
      sendJob' job
 
      threadDelay (500 * millisecond)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobFinished msg ]

        -- queue should be empty
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "can handle a job with error" $ \(TestEnv { state = State { broker, queueName }, events }) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Error
      let job = mkDefaultSendJob' broker queueName msg
      sendJob' job
 
      threadDelay (500 * millisecond)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobError msg ]

      -- queue should be empty (error jobs archived by default)
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "can handle a job with error (with archive)" $ \(TestEnv { state = State { broker, queueName }, events }) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Error
      let job = (mkDefaultSendJob' broker queueName msg) { errStrat = ESDelete }
      sendJob' job
 
      threadDelay (500 * millisecond)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobError msg ]

      -- queue should be empty (error job deleted)
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "can handle a job with error (with repeat)" $ \(TestEnv { state = State { broker, queueName }, events }) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Error
      let job = (mkDefaultSendJob' broker queueName msg) { errStrat = ESRepeat }
      sendJob' job
 
      threadDelay (100 * millisecond)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobError msg ]

      -- NOTE It doesn't make sense to check queue size here, the
      -- worker just continues to run the errored task in background
      -- and currently there is no way to stop it. Maybe implementing
      -- a custom test queue could help us here.

    it "can handle a job with timeout" $ \(TestEnv { state = State { broker, queueName }, events}) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Timeout { delay = 2 }
      let job = mkDefaultSendJob broker queueName msg 1
      sendJob' job
 
      threadDelay (2*second)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobTimeout msg ]

      -- NOTE It doesn't make sense to check queue size here, the
      -- worker just continues to run the errored task in background
      -- and currently there is no way to stop it. Maybe implementing
      -- a custom test queue could help us here.

    it "can handle a job with timeout (archive strategy)" $ \(TestEnv { state = State { broker, queueName }, events}) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSArchive }
      sendJob' job
 
      threadDelay (2*second)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobTimeout msg ]

      -- Queue should be empty, since we archive timed out jobs
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "can handle a job with timeout (delete strategy)" $ \(TestEnv { state = State { broker, queueName }, events}) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSDelete }
      sendJob' job
 
      threadDelay (2*second)
 
      events2 <- readTVarIO events
      events2 `shouldBe` [ EMessageReceived msg, EJobTimeout msg ]

      -- Queue should be empty, since we archive timed out jobs
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "can handle a job with timeout (repeat N times, then archive strategy)" $ \(TestEnv { state = State { broker, queueName }, events}) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSRepeatNElseArchive 1 }
      sendJob' job
 
      threadDelay (3*second)
 
      events2 <- readTVarIO events
      -- | Should have been run 2 times, then archived
      events2 `shouldBe` [ EMessageReceived msg, EJobTimeout msg
                         , EMessageReceived msg, EJobTimeout msg ]

      -- Queue should be empty, since we archive timed out jobs
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "can process two jobs" $ \(TestEnv { state = State { broker, queueName }, events }) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0
 
      let text1 = "simple test 1"
      let msg1 = Message { text = text1 }
      let job1 = mkDefaultSendJob' broker queueName msg1
      sendJob' job1
      let text2 = "simple test 2"
      let msg2 = Message { text = text2 }
      let job2 = mkDefaultSendJob' broker queueName msg2
      sendJob' job2
 
      threadDelay (500 * millisecond)
 
      events2 <- readTVarIO events
      -- The jobs don't have to be process exactly in this order so we just use Set here
      Set.fromList events2 `shouldBe`
        Set.fromList [ EMessageReceived msg1, EJobFinished msg1
                     , EMessageReceived msg2, EJobFinished msg2 ]

      -- queue should be empty
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0

    it "after job with error, continue with another one" $ \(TestEnv { state = State { broker, queueName }, events }) -> do
      -- no events initially
      events1 <- readTVarIO events
      events1 `shouldBe` []
      -- queue should be empty
      queueLen1 <- BT.getQueueSize broker queueName
      queueLen1 `shouldBe` 0

      let msgErr = Error
      let jobErr = mkDefaultSendJob' broker queueName msgErr
      sendJob' jobErr
      let text = "simple test"
      let msg = Message { text }
      let job = mkDefaultSendJob' broker queueName msg
      sendJob' job
 
      threadDelay (500 * millisecond)
 
      events2 <- readTVarIO events
      Set.fromList events2 `shouldBe`
        Set.fromList [ EMessageReceived msgErr, EJobError msgErr
                     , EMessageReceived msg, EJobFinished msg ]

      -- queue should be empty
      queueLen2 <- BT.getQueueSize broker queueName
      queueLen2 `shouldBe` 0
 

second :: Int
second = 1000 * millisecond

millisecond :: Int
millisecond = 1000


pgmqWorkerBrokerInitParams :: IO (BT.BrokerInitParams PGMQ.PGMQBroker (Job Message))
pgmqWorkerBrokerInitParams = do
  PGMQ.PGMQBrokerInitParams <$> getPSQLEnvConnectInfo

redisWorkerBrokerInitParams :: IO (BT.BrokerInitParams Redis.RedisBroker (Job Message))
redisWorkerBrokerInitParams = do
  Redis.RedisBrokerInitParams <$> getRedisEnvConnectInfo

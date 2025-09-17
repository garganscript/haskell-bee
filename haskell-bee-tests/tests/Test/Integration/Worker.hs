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
 ( Message(..)
 
 , workerTests
 , multiWorkerTests )
where

import Async.Worker (run, mkDefaultSendJob, mkDefaultSendJob', sendJob', errStrat, toStrat, addDelayAfterRead, resendOnKill, KillWorkerSafely(..))
import Async.Worker.Broker.Types qualified as BT
import Async.Worker.Types
import Control.Concurrent (forkIO, killThread, threadDelay, ThreadId, throwTo)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (readTVarIO, newTVarIO, TVar, modifyTVar)
import Control.Exception (bracket, Exception, throwIO)
import Control.Monad (void)
import Data.Aeson (ToJSON, FromJSON)
import Data.List (sort)
import Data.Maybe (fromJust, isJust)
import Data.Set qualified as Set
import GHC.Generics (Generic)
import Test.Hspec
import Test.Integration.Utils (randomQueueName, waitUntil, waitUntilTVarEq, waitUntilTVarPred, waitUntil, waitUntilQueueEmpty)


data TestEnv b =
  TestEnv { state  :: State b Message
          , events :: TVar [Event]
          , threadId :: ThreadId
          , brokerInitParams :: BT.BrokerInitParams b (Job Message)
          -- | a separate broker so that we use separate connection from the worker
          , broker :: BT.Broker b (Job Message)
          , queueName :: BT.Queue
          }


testQueuePrefix :: BT.Queue
testQueuePrefix = "test_worker"


-- | Messages that we will send to worker via the broker (i.e. jobs)
data Message =
    Message { text :: String }
  | Error
  | Timeout { delay :: Int }
  deriving (Show, Eq, Ord, Generic)
instance ToJSON Message
instance FromJSON Message
-- instance ToJSON Message where
--   toJSON (Message { text }) = toJSON $ object [ "type" .= ("Message" :: String), "text" .= text ]
--   toJSON Error = toJSON $ object [ "type" .= ("Error" :: String) ]
--   toJSON (Timeout { delay }) = toJSON $ object [ "type" .= ("Timeout" :: String), "delay" .= delay ]
-- instance FromJSON Message where
--   parseJSON = withObject "Message" $ \o -> do
--     type_ <- o .: "type"
--     case type_ of
--       "Message" -> do
--         text <- o .: "text"
--         pure $ Message { text }
--       "Error" -> pure Error
--       "Timeout" -> do
--         delay <- o .: "delay"
--         pure $ Timeout { delay }
--       _ -> fail $ "Unknown type " <> type_


-- | We will handle job events from the worker to track what and how
-- was processed
data Event =
    EMessageReceived Message
  | EJobFinished Message
  | EJobTimeout Message
  | EJobError Message
  | EWorkerKilledSafely (Maybe Message)
  deriving (Eq, Show, Ord)


data SimpleException = SimpleException String
  deriving Show
instance Exception SimpleException


-- | Perform Action for this worker
pa :: (HasWorkerBroker b Message) => State b Message -> BT.BrokerMessage b (Job Message) -> IO ()
pa _state bm = do
  let job' = BT.toA $ BT.getMessage bm
  case job job' of
    Message { text = _text } -> return ()  -- putStrLn text
    Error -> throwIO $ SimpleException "Error!"
    Timeout { delay } -> threadDelay (delay * second)

pushEvent :: BT.MessageBroker b (Job Message)
          => TVar [Event]
          -> (Message -> Event)
          -> BT.BrokerMessage b (Job Message)
          -> IO ()
pushEvent events evt bm = atomically $ modifyTVar events (\e -> e ++ [evt $ job $ BT.toA $ BT.getMessage bm])

pushEventMMsg :: BT.MessageBroker b (Job Message)
             => TVar [Event]
             -> (Maybe Message -> Event)
             -> Maybe (BT.BrokerMessage b (Job Message))
             -> IO ()
pushEventMMsg events evt mbm = atomically $ modifyTVar events (\e -> e ++ [evt $ job <$> BT.toA <$> BT.getMessage <$> mbm])


initStateDelayed :: (HasWorkerBroker b Message)
                 => BT.BrokerInitParams b (Job Message)
                 -> TVar [Event]
                 -> BT.Queue
                 -> String
                 -> Int
                 -> IO (State b Message, ThreadId)
initStateDelayed bInitParams events queue workerName timeoutDelay = do
  let pushEvt evt _s = pushEvent events evt

  b' <- BT.initBroker bInitParams
  let state = State { broker = b'
                    , queueName = queue
                    , name = workerName <> " for " <> BT.renderQueue queue
                    , performAction = pa
                    , onMessageReceived = Just (pushEvt EMessageReceived)
                    , onJobFinish = Just (pushEvt EJobFinished)
                    , onJobTimeout = Just $ \evt s -> do
                        pushEvt EJobTimeout evt s
                        threadDelay timeoutDelay
                    , onJobError = Just (\_s bm _exc -> pushEvent events EJobError bm)
                    , onWorkerKilledSafely = Just (const $ pushEventMMsg events EWorkerKilledSafely) }

  threadId <- forkIO $ run state

  pure (state, threadId)


initState :: (HasWorkerBroker b Message)
          => BT.BrokerInitParams b (Job Message)
          -> TVar [Event]
          -> BT.Queue
          -> String
          -> IO (State b Message, ThreadId)
initState bInitParams events queue workerName = initStateDelayed bInitParams events queue workerName 0


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

      (state, threadId) <- initState bInitParams events queue "test worker"
      
      return $ TestEnv { state
                       , events
                       , threadId
                       , brokerInitParams = bInitParams
                       , broker = b
                       , queueName = queue }

    tearDownWorker :: (HasWorkerBroker b Message)
                   => TestEnv b
                   -> IO ()
    tearDownWorker (TestEnv { broker = b, queueName, state = State { broker = b' }, threadId }) = do
      killThread threadId
      BT.deinitBroker b'
      BT.dropQueue b queueName
      BT.deinitBroker b


-- | Single 'Worker' tests, abstracting the 'Broker' away.
workerTests :: (HasWorkerBroker b Message)
            => BT.BrokerInitParams b (Job Message)
            -> Spec
workerTests brokerInitParams =
  parallel $ around (withWorker brokerInitParams) $ describe "Worker tests" $ do
    it "can process a simple job" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0
 
      let text = "simple test"
      let msg = Message { text }
      let job = mkDefaultSendJob' broker queueName msg
      void $ sendJob' job
 
      waitUntilTVarEq events [ EMessageReceived msg, EJobFinished msg ] 500

      -- queue should be empty
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with error" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Error
      let job = mkDefaultSendJob' broker queueName msg
      void $ sendJob' job
 
      waitUntilTVarEq events [ EMessageReceived msg, EJobError msg ] 500

      -- queue should be empty (error jobs archived by default)
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with error (with archive)" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Error
      let job = (mkDefaultSendJob' broker queueName msg) { errStrat = ESDelete }
      void $ sendJob' job
 
      waitUntilTVarEq events [ EMessageReceived msg, EJobError msg ] 500

      -- queue should be empty (error job deleted)
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with error (with repeat n)" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Error
      let job = (mkDefaultSendJob' broker queueName msg) { errStrat = ESRepeatNElseArchive 1 }
      void $ sendJob' job
 
      waitUntilTVarEq events [ EMessageReceived msg, EJobError msg
                             , EMessageReceived msg, EJobError msg ] 500

      -- queue should be empty (error job archived)
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with timeout (archive strategy)" $ \(TestEnv { broker, queueName, events}) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Timeout { delay = 2 }
      let job' = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSArchive }
      msgId <- sendJob' job'

      waitUntilTVarEq events [ EMessageReceived msg, EJobTimeout msg ] 1200

      -- There might be a slight delay before the message is archived
      -- (handling exception step in the thread)
      waitUntil (isJust <$> BT.getArchivedMessage broker queueName msgId) 100

      -- The archive should contain our message
      mMsgArchive <- BT.getArchivedMessage broker queueName msgId
      mMsgArchive `shouldSatisfy` isJust
      let msgArchive = fromJust mMsgArchive
      job (BT.toA $ BT.getMessage msgArchive) `shouldBe` msg

      -- Queue should be empty, since we archive timed out jobs
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with timeout (delete strategy)" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSDelete }
      void $ sendJob' job
 
      waitUntilTVarEq events [ EMessageReceived msg, EJobTimeout msg ] 1200

      -- Queue should be empty, since we archive timed out jobs
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with timeout (repeat strategy)" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSRepeat }
      void $ sendJob' job
 
      waitUntilTVarPred events (\evts -> ((EMessageReceived msg) `elem` evts)
                                      && ((EJobTimeout msg) `elem` evts)) 2500

      -- NOTE It doesn't make sense to check queue size here, the
      -- worker just continues to run the errored task in background
      -- and currently there is no way to stop it. Maybe implementing
      -- a custom test queue could help us here.

    it "can handle a job with timeout (repeat N times, then archive strategy)" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSRepeatNElseArchive 1 }
      void $ sendJob' job
 
      -- | Should have been run 2 times, then archived
      waitUntilTVarEq events [ EMessageReceived msg, EJobTimeout msg
                             , EMessageReceived msg, EJobTimeout msg ] 2500

      -- Queue should be empty, since we archive timed out jobs
      waitUntilQueueEmpty broker queueName 100

    it "can handle a job with timeout (repeat N times, then delete strategy)" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSRepeatNElseDelete 1 }
      void $ sendJob' job
 
      -- | Should have been run 2 times, then archived
      waitUntilTVarEq events [ EMessageReceived msg, EJobTimeout msg
                             , EMessageReceived msg, EJobTimeout msg ] 2500

      -- Queue should be empty, since we deleted timed out jobs
      waitUntilQueueEmpty broker queueName 100

    it "can process two jobs" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0
 
      let text1 = "simple test 1"
      let msg1 = Message { text = text1 }
      let job1 = mkDefaultSendJob' broker queueName msg1
      void $ sendJob' job1
      let text2 = "simple test 2"
      let msg2 = Message { text = text2 }
      let job2 = mkDefaultSendJob' broker queueName msg2
      void $ sendJob' job2
 
      -- The jobs don't have to be process exactly in this order so we just use Set here
      waitUntilTVarPred events (
        \e -> Set.fromList e == Set.fromList 
          [ EMessageReceived msg1, EJobFinished msg1
          , EMessageReceived msg2, EJobFinished msg2 ]) 500

      -- queue should be empty
      waitUntilQueueEmpty broker queueName 100

    it "after job with error, continue with another one" $ \(TestEnv { broker, queueName, events }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      let msgErr = Error
      let jobErr = mkDefaultSendJob' broker queueName msgErr
      void $ sendJob' jobErr
      let text = "simple test"
      let msg = Message { text }
      let job = mkDefaultSendJob' broker queueName msg
      void $ sendJob' job
 
      waitUntilTVarPred events (
        \e -> Set.fromList e ==
          Set.fromList [ EMessageReceived msgErr, EJobError msgErr
                       , EMessageReceived msg, EJobFinished msg ]) 500

      -- queue should be empty
      waitUntilQueueEmpty broker queueName 100

    it "killing worker should leave a currently processed message on queue (when resendWhenWorkerKilled is True)" $ \(TestEnv { broker, queueName, events, threadId }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      -- Perform some long job
      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 2) { resendOnKill = True }
      void $ sendJob' job

      -- Let's wait a bit to make sure the message is picked up by the
      -- worker
      waitUntilTVarEq events [ EMessageReceived msg ] 300

      -- Now let's kill the thread immediately
      throwTo threadId KillWorkerSafely
      putStrLn $ "After KillWorkerSafely: " <> BT.renderQueue queueName

      waitUntilTVarEq events [ EMessageReceived msg
                             , EWorkerKilledSafely (Just msg) ] 300
      
      -- The message should still be there
      BT.getQueueSize broker queueName >>= \qs -> do
        putStrLn $ "After threadDelay: " <> BT.renderQueue queueName <> " size: " <> show qs
        qs  `shouldBe` 1

    it "killing worker should discard the currently processed message (when resendWhenWorkerKilled is False)" $ \(TestEnv { broker, queueName, events, threadId }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= flip shouldBe 0

      -- Perform some long job
      let msg = Timeout { delay = 2 }
      let job = (mkDefaultSendJob broker queueName msg 2) { resendOnKill = False }
      void $ sendJob' job

      -- Let's wait a bit to make sure the message is picked up by the
      -- worker
      waitUntilTVarEq events [ EMessageReceived msg ] 300
      waitUntilQueueEmpty broker queueName 300

      -- Now let's kill the thread immediately
      throwTo threadId KillWorkerSafely

      waitUntilTVarEq events [ EMessageReceived msg
                             , EWorkerKilledSafely (Just msg) ] 300

      -- The message shouldn't be there
      BT.getQueueSize broker queueName >>= shouldBe 0


data TestEnvMulti b =
  TestEnvMulti { broker :: BT.Broker b (Job Message)  -- a broker with which you can query its state
               , statesWithThreadIds  :: [(State b Message, ThreadId)]
               , events :: TVar [Event]
               , brokerInitParams :: BT.BrokerInitParams b (Job Message)
               , queueName :: BT.Queue
               , numWorkers :: Int }


testMultiQueuePrefix :: BT.Queue
testMultiQueuePrefix = "test_workers"


withWorkers :: (HasWorkerBroker b Message)
            => BT.BrokerInitParams b (Job Message)
            -> Int
            -> (TestEnvMulti b -> IO ())
            -> IO ()
withWorkers brokerInitParams numWorkers = bracket (setUpWorkers brokerInitParams) tearDownWorkers
  where
    -- NOTE I need to pass 'b' again, otherwise GHC can't infer the
    -- type of 'b' (even with 'ScopedTypeVariables' turned on)
    setUpWorkers :: (HasWorkerBroker b Message)
                 => BT.BrokerInitParams b (Job Message)
                 -> IO (TestEnvMulti b)
    setUpWorkers bInitParams = do
      b <- BT.initBroker bInitParams

      queue <- randomQueueName testMultiQueuePrefix
      
      BT.dropQueue b queue
      BT.createQueue b queue

      events <- newTVarIO []

      statesWithThreadIds <-
        mapM (\idx -> initStateDelayed bInitParams events queue ("test worker " <> show idx) (200*1000)) [1..numWorkers]
      
      return $ TestEnvMulti { broker = b
                            , queueName = queue
                            , statesWithThreadIds
                            , events
                            , brokerInitParams = bInitParams
                            , numWorkers }

    tearDownWorkers :: (HasWorkerBroker b Message)
                    => TestEnvMulti b
                    -> IO ()
    tearDownWorkers (TestEnvMulti { broker = b, queueName, statesWithThreadIds }) = do
      mapM_ (\(State { broker = b' }, threadId) -> do
        killThread threadId
        BT.deinitBroker b'
            ) statesWithThreadIds
      BT.dropQueue b queueName
      BT.deinitBroker b


    
-- | Multiple 'Worker' tests, abstracting the 'Broker' away. All these
-- workers operate on the same queue.
multiWorkerTests :: (HasWorkerBroker b Message)
                 => BT.BrokerInitParams b (Job Message)
                 -> Int
                 -> Spec
multiWorkerTests brokerInitParams numWorkers =
  parallel $ around (withWorkers brokerInitParams numWorkers) $ describe "Worker tests" $ do
    it "can process simple jobs" $ \(TestEnvMulti { broker, queueName, events, numWorkers = nw }) -> do
      -- no events initially
      readTVarIO events >>= shouldBe []
      -- queue should be empty
      BT.getQueueSize broker queueName >>= shouldBe 0

      -- create some messages and make sure they are processed (bombarding with messages)
      let msgs = [Message { text = "task " <> show idx } | idx <- [1..20*nw]]
 
      let jobs = map (mkDefaultSendJob' broker queueName) msgs
      mapM_ sendJob' jobs
 
      -- The jobs don't have to be process exactly in this order so we just use Set here
      let expected = concat [[EMessageReceived msg, EJobFinished msg] | msg <- msgs]
      waitUntilTVarPred events (\e -> Set.fromList e == Set.fromList expected) (fromIntegral $ 200*nw)

      -- queue should be empty
      waitUntilQueueEmpty broker queueName 100

    -- it "multiple workers and one long message should result in one message processed" $ \(TestEnvMulti { broker, queueName, events }) -> do
    --   let msg = Timeout { delay = 2 }
    --   let job' = (mkDefaultSendJob broker queueName msg 1) { toStrat = TSArchive }
    --   msgId <- sendJob' job'
 
    --   waitUntilTVarEq events [ EMessageReceived msg, EJobTimeout msg ] 1500
      
    --   -- There might be a slight delay before the message is archived
    --   -- (handling exception step in the thread)
    --   waitUntil (isJust <$> BT.getArchivedMessage broker queueName msgId) 100
      
    --   -- The archive should contain our message
    --   mMsgArchive <- BT.getArchivedMessage broker queueName msgId
    --   mMsgArchive `shouldSatisfy` isJust
    --   let msgArchive = fromJust mMsgArchive
    --   job (BT.toA $ BT.getMessage msgArchive) `shouldBe` msg
      
    --   -- Queue should be empty, since we archive timed out jobs
    --   waitUntilQueueEmpty broker queueName 100

    it "can safely timeout a job, without another worker overlapping" $
      \(TestEnvMulti { broker, queueName, events }) -> do
        readTVarIO events >>= shouldBe []
        BT.getQueueSize broker queueName >>= shouldBe 0

        -- | This job will timeout. We want to make sure that no other
        -- worker will process it.
        let msg = Timeout { delay = 2 }
        let job' = mkDefaultSendJob broker queueName msg 1
        let job = job' { addDelayAfterRead = 1
                       , toStrat = TSDelete }
        void $ sendJob' job

        waitUntilQueueEmpty broker queueName 2500
        -- Need to wait to make sure no other worker picked that job
        threadDelay (2000*1000)

        let expected = [ EMessageReceived msg, EJobTimeout msg ]
        readTVarIO events >>= shouldBe expected

    it "will fail without additionalDelayAfterRead" $
      \(TestEnvMulti { broker, queueName, events }) -> do
        readTVarIO events >>= shouldBe []
        BT.getQueueSize broker queueName >>= shouldBe 0

        -- | This job will timeout. We want to make sure that no other
        -- worker will process it.
        let msg = Timeout { delay = 2 }
        let job' = mkDefaultSendJob broker queueName msg 1
        let job = job' { addDelayAfterRead = 0
                       , toStrat = TSDelete }
        void $ sendJob' job
        
        waitUntilQueueEmpty broker queueName 2500
        -- Need to wait to make sure this times out and another worker
        -- had a chance to pick it up in the meantime
        threadDelay (2000*1000)

        -- | Should have received this twice
        let expected = [ EMessageReceived msg, EJobTimeout msg
                       , EMessageReceived msg, EJobTimeout msg ]
        readTVarIO events >>= (shouldBe $ sort expected) . sort

second :: Int
second = 1000 * millisecond

millisecond :: Int
millisecond = 1000

module Demo.Action where

import Async.Worker.Broker qualified as B
import Async.Worker.Broker.Types qualified as B
import Async.Worker.Broker.PGMQ (PGMQBroker)
import Async.Worker qualified as W
import Async.Worker.Types qualified as W
import Control.Concurrent (threadDelay)
import Control.Exception.Safe (Exception, throwIO)
import Control.Monad (void)
import Demo.Types (Job(..))


data MyException = MyException String
  deriving (Show)
instance Exception MyException


performAction :: (W.HasWorkerBroker PGMQBroker Job)
              => W.State PGMQBroker Job
              -> B.BrokerMessage PGMQBroker (W.Job Job)
              -> IO ()
performAction (W.State { broker, queueName }) bm = do
  let job = B.toA (B.getMessage bm)
  case W.getJob job of
    Echo s -> putStrLn s
    Wait t -> do
      putStrLn $ "waiting " <> show t <> "s"
      threadDelay (t * 1_000_000)
    Error e -> throwIO $ MyException e
    Quit -> throwIO $ W.KillWorkerSafely
    Periodic { counter, delay, name } -> do
      let md = W.metadata job
      putStrLn $ "[periodic " <> name <> "] counter: " <> show counter

      if (counter < 10) then do
        let sj = W.mkDefaultSendJob' broker queueName (Periodic { counter = counter + 1, delay, name })
        void $ W.sendJob' $ sj { W.delay = B.TimeoutS delay }
      else do
        putStrLn $ "[periodic " <> name <> "] stopping"

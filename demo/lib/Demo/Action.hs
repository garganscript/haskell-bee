module Demo.Action where

import Async.Worker.Broker qualified as B
import Async.Worker.Broker.Types qualified as B
import Async.Worker.Broker.PGMQ (PGMQBroker)
import Async.Worker qualified as W
import Async.Worker.Types qualified as W
import Control.Concurrent (threadDelay)
import Control.Exception.Safe (Exception, throwIO)
import Demo.Types (Job(..))


data MyException = MyException String
  deriving (Show)
instance Exception MyException


performAction :: (W.HasWorkerBroker PGMQBroker Job)
              => W.State PGMQBroker Job
              -> B.BrokerMessage PGMQBroker (W.Job Job)
              -> IO ()
performAction state bm = do
  case W.getJob (B.toA (B.getMessage bm)) of
    Echo s -> putStrLn s
    Wait t -> do
      putStrLn $ "waiting " <> show t <> "s"
      threadDelay (t * 1_000_000)
    Error e -> throwIO $ MyException e
    Quit -> throwIO $ W.KillWorkerSafely

module Demo.PGMQ where

import Async.Worker.Broker qualified as B
import Async.Worker.Broker.Types qualified as B
import Async.Worker.Broker.PGMQ (PGMQBroker, BrokerInitParams(PGMQBrokerInitConnStr))
import Async.Worker qualified as W
import Async.Worker.Types qualified as W
import Async.Worker.Types (HasWorkerBroker)
import Control.Concurrent.Async (Async, withAsync)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Demo.Action (performAction)
import Demo.Types (Job)
import System.Environment (lookupEnv)


brokerInitParams :: IO (B.BrokerInitParams PGMQBroker (W.Job Job))
brokerInitParams = do
  mConnInfo <- lookupEnv "POSTGRES_CONN"
  let connInfo = T.pack $ fromMaybe "host=localhost port=5432 dbname=postgres user=postgres" mConnInfo

  return $ PGMQBrokerInitConnStr (T.encodeUtf8 connInfo) 1


initBroker :: (HasWorkerBroker PGMQBroker Job)
           => IO (B.Broker PGMQBroker (W.Job Job))
initBroker = do
  params <- brokerInitParams
  B.initBroker params


initWorker :: (HasWorkerBroker PGMQBroker Job)
           => String
           -> B.Queue
           -> (Async () -> W.State PGMQBroker Job -> IO ())
           -> IO ()
initWorker name queueName cb = do
  putStrLn $ "[" <> name <> "] starting"
  
  broker <- initBroker

  let onWorkerKilledSafely _ _ = do
        putStrLn $ "[" <> name <> "] killing me safely"

  let state' = W.State { broker
                       , name
                       , queueName
                       , performAction
                       , onMessageReceived = Nothing
                       , onJobFinish = Nothing
                       , onJobTimeout = Nothing
                       , onJobError = Nothing
                       , onWorkerKilledSafely = Just onWorkerKilledSafely }

  withAsync (W.run state') (\a -> cb a state')

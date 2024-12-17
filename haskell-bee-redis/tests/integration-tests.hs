module Main where

import Test.Integration.Broker (brokerTests)
import Test.Integration.Redis (redisBrokerInitParams, redisWorkerBrokerInitParams)
import Test.Integration.Worker (workerTests, multiWorkerTests)
import Test.Tasty
import Test.Tasty.Hspec



main :: IO ()
main = do
  redisBInitParams <- redisBrokerInitParams
  redisBrokerSpec <- testSpec "brokerTests" (brokerTests redisBInitParams)
  redisWBInitParams <- redisWorkerBrokerInitParams
  redisWorkerSpec <- testSpec "workerTests" (workerTests redisWBInitParams)
  redisMultiWorkerSpec <- testSpec "multiWorkerTests" (multiWorkerTests redisWBInitParams 5)

  defaultMain $ testGroup "Redis integration tests"
    [
      redisBrokerSpec
    , redisWorkerSpec
    , redisMultiWorkerSpec
   ]


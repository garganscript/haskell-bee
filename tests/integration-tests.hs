module Main where

import Test.Integration.Broker (brokerTests, pgmqBrokerInitParams, redisBrokerInitParams)
import Test.Integration.Worker (workerTests, pgmqWorkerBrokerInitParams, redisWorkerBrokerInitParams)
import Test.Tasty
import Test.Tasty.Hspec



main :: IO ()
main = do
  pgmqBInitParams <- pgmqBrokerInitParams
  pgmqBrokerSpec <- testSpec "brokerTests (pgmq)" (brokerTests pgmqBInitParams)
  pgmqWBInitParams <- pgmqWorkerBrokerInitParams
  pgmqWorkerSpec <- testSpec "workerTests (pgmq)" (workerTests pgmqWBInitParams)

  redisBInitParams <- redisBrokerInitParams
  redisBrokerSpec <- testSpec "brokerTests (redis)" (brokerTests redisBInitParams)
  redisWBInitParams <- redisWorkerBrokerInitParams
  redisWorkerSpec <- testSpec "workerTests (redis)" (workerTests redisWBInitParams)

  defaultMain $ testGroup "integration tests"
    [
      pgmqBrokerSpec
    , pgmqWorkerSpec
    
    , redisBrokerSpec
    , redisWorkerSpec
    ]


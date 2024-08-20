module Main where

import Test.Integration.Broker (brokerTests, pgmqBrokerInitParams, redisBrokerInitParams)
import Test.Integration.Worker (workerTests, multiWorkerTests, pgmqWorkerBrokerInitParams, redisWorkerBrokerInitParams)
import Test.Tasty
import Test.Tasty.Hspec



main :: IO ()
main = do
  pgmqBInitParams <- pgmqBrokerInitParams
  pgmqBrokerSpec <- testSpec "brokerTests (pgmq)" (brokerTests pgmqBInitParams)
  pgmqWBInitParams <- pgmqWorkerBrokerInitParams
  pgmqWorkerSpec <- testSpec "workerTests (pgmq)" (workerTests pgmqWBInitParams)
  pgmqMultiWorkerSpec <- testSpec "multiWorkerTests (pgmq)" (multiWorkerTests pgmqWBInitParams 5)

  redisBInitParams <- redisBrokerInitParams
  redisBrokerSpec <- testSpec "brokerTests (redis)" (brokerTests redisBInitParams)
  redisWBInitParams <- redisWorkerBrokerInitParams
  redisWorkerSpec <- testSpec "workerTests (redis)" (workerTests redisWBInitParams)
  redisMultiWorkerSpec <- testSpec "multiWorkerTests (redis)" (multiWorkerTests redisWBInitParams 5)

  defaultMain $ testGroup "integration tests"
    [
      pgmqBrokerSpec
    , pgmqWorkerSpec
    , pgmqMultiWorkerSpec
    
    , redisBrokerSpec
    , redisWorkerSpec
    , redisMultiWorkerSpec
    ]


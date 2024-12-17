module Main where

import Test.Integration.Broker (brokerTests)
import Test.Integration.PGMQ (pgmqBrokerInitParams, pgmqWorkerBrokerInitParams)
import Test.Integration.Worker (workerTests, multiWorkerTests)
import Test.Tasty
import Test.Tasty.Hspec



main :: IO ()
main = do
  pgmqBInitParams <- pgmqBrokerInitParams
  pgmqBrokerSpec <- testSpec "brokerTests" (brokerTests pgmqBInitParams)
  pgmqWBInitParams <- pgmqWorkerBrokerInitParams
  pgmqWorkerSpec <- testSpec "workerTests" (workerTests pgmqWBInitParams)
  pgmqMultiWorkerSpec <- testSpec "multiWorkerTests" (multiWorkerTests pgmqWBInitParams 5)

  defaultMain $ testGroup "PGMQ integration tests"
    [
      pgmqBrokerSpec
    , pgmqWorkerSpec
    , pgmqMultiWorkerSpec
   ]


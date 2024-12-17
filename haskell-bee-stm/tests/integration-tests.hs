module Main where

import Test.Integration.Broker (brokerTests)
import Test.Integration.STM (stmBrokerInitParams, stmWorkerBrokerInitParams)
import Test.Integration.Worker (workerTests, multiWorkerTests)
import Test.Tasty
import Test.Tasty.Hspec



main :: IO ()
main = do
  stmBInitParams <- stmBrokerInitParams
  stmBrokerSpec <- testSpec "brokerTests" (brokerTests stmBInitParams)
  stmWBInitParams <- stmWorkerBrokerInitParams
  stmWorkerSpec <- testSpec "workerTests" (workerTests stmWBInitParams)
  stmMultiWorkerSpec <- testSpec "multiWorkerTests" (multiWorkerTests stmWBInitParams 5)

  defaultMain $ testGroup "STM integration tests"
    [
      stmBrokerSpec
    , stmWorkerSpec
    , stmMultiWorkerSpec
   ]


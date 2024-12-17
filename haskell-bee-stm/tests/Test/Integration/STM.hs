module Test.Integration.STM
 ( stmBrokerInitParams
 , stmWorkerBrokerInitParams )
where

import Async.Worker.Broker.STM qualified as STMB
import Async.Worker.Broker.Types qualified as BT
import Async.Worker.Types (Job(..))
import Control.Concurrent.STM.TVar (newTVarIO)
import Data.Map.Strict qualified as Map
import Test.Integration.Broker qualified as TIB
import Test.Integration.Worker qualified as TIW


stmBrokerInitParams :: IO (BT.BrokerInitParams STMB.STMBroker TIB.Message)
stmBrokerInitParams = do
  archiveMap <- newTVarIO Map.empty
  stmMap <- newTVarIO Map.empty
  pure $ STMB.STMBrokerInitParams { .. }


stmWorkerBrokerInitParams :: IO (BT.BrokerInitParams STMB.STMBroker (Job TIW.Message))
stmWorkerBrokerInitParams = do
  archiveMap <- newTVarIO Map.empty
  stmMap <- newTVarIO Map.empty
  pure $  STMB.STMBrokerInitParams { .. }

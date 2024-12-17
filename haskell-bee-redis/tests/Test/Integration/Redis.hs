
module Test.Integration.Redis
 ( redisBrokerInitParams
 , redisWorkerBrokerInitParams )
where

import Async.Worker.Broker.Redis qualified as BR
import Async.Worker.Broker.Types qualified as BT
import Async.Worker.Types (Job(..))
import Data.Maybe (fromMaybe)
import Database.Redis qualified as Redis
import System.Environment (lookupEnv)
import Test.Integration.Broker qualified as TIB
import Test.Integration.Worker qualified as TIW


-- | Redis connect info that is fetched from env
getRedisEnvConnectInfo :: IO Redis.ConnectInfo
getRedisEnvConnectInfo = do
  redisHost <- lookupEnv "REDIS_HOST"
  -- https://hackage.haskell.org/package/hedis-0.15.2/docs/Database-Redis.html#v:defaultConnectInfo
  pure $ Redis.defaultConnectInfo { Redis.connectHost = fromMaybe "localhost" redisHost }


redisBrokerInitParams :: IO (BT.BrokerInitParams BR.RedisBroker TIB.Message)
redisBrokerInitParams = do
  BR.RedisBrokerInitParams <$> getRedisEnvConnectInfo


redisWorkerBrokerInitParams :: IO (BT.BrokerInitParams BR.RedisBroker (Job TIW.Message))
redisWorkerBrokerInitParams = do
  BR.RedisBrokerInitParams <$> getRedisEnvConnectInfo

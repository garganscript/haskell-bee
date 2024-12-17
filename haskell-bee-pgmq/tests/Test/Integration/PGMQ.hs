module Test.Integration.PGMQ
 ( pgmqBrokerInitParams
 , pgmqWorkerBrokerInitParams )
where

import Async.Worker.Broker.PGMQ qualified as PGMQ
import Async.Worker.Broker.Types qualified as BT
import Async.Worker.Types (Job(..))
import Data.Maybe (fromMaybe)
import Database.PostgreSQL.Simple qualified as PSQL
import System.Environment (lookupEnv)
import Test.Integration.Broker qualified as TIB
import Test.Integration.Worker qualified as TIW

-- | Visibility timeout is a very important parameter for PGMQ. It is
-- mainly used when reading a job: it specifies for how many seconds
-- this job should be invisible for other workers. We need more tests
-- and setting this correctly, preferably in accordance with
-- 'Job.timeout'. Issue is that at the broker level we don't know
-- anything about 'Job'...
--
-- The lower the value, the more probable that some other worker will
-- pick up the same job at about the same time (before broker marks it
-- as invisible).
defaultPGMQVt :: Int
defaultPGMQVt = 1

-- | PSQL connect info that is fetched from env
getPSQLEnvConnectInfo :: IO PSQL.ConnectInfo
getPSQLEnvConnectInfo = do
  pgUser <- lookupEnv "POSTGRES_USER"
  pgDb <- lookupEnv "POSTGRES_DB"
  pgPass <- lookupEnv "POSTGRES_PASSWORD"
  pgHost <- lookupEnv "POSTGRES_HOST"
  -- https://hackage.haskell.org/package/postgresql-simple-0.7.0.0/docs/Database-PostgreSQL-Simple.html#t:ConnectInfo
  pure $ PSQL.defaultConnectInfo { PSQL.connectUser = fromMaybe "postgres" pgUser
                                 , PSQL.connectDatabase = fromMaybe "postgres" pgDb
                                 , PSQL.connectHost = fromMaybe "localhost" pgHost
                                 , PSQL.connectPassword = fromMaybe "postgres" pgPass }


pgmqBrokerInitParams :: IO (BT.BrokerInitParams PGMQ.PGMQBroker TIB.Message)
pgmqBrokerInitParams = do
  conn <- getPSQLEnvConnectInfo
  return $ PGMQ.PGMQBrokerInitParams conn defaultPGMQVt




pgmqWorkerBrokerInitParams :: IO (BT.BrokerInitParams PGMQ.PGMQBroker (Job TIW.Message))
pgmqWorkerBrokerInitParams = do
  conn <- getPSQLEnvConnectInfo
  return $ PGMQ.PGMQBrokerInitParams conn defaultPGMQVt

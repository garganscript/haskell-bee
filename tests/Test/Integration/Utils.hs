module Test.Integration.Utils
  ( getPSQLEnvConnectInfo
  , getRedisEnvConnectInfo
  , randomQueueName )
where

import Async.Worker.Broker qualified as B
import Data.Maybe (fromMaybe)
import Database.PostgreSQL.Simple qualified as PSQL
import Database.Redis qualified as Redis
import System.Environment (lookupEnv)
import Test.RandomStrings (randomASCII, randomString, onlyAlphaNum)


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

getRedisEnvConnectInfo :: IO Redis.ConnectInfo
getRedisEnvConnectInfo = do
  redisHost <- lookupEnv "REDIS_HOST"
  -- https://hackage.haskell.org/package/hedis-0.15.2/docs/Database-Redis.html#v:defaultConnectInfo
  pure $ Redis.defaultConnectInfo { Redis.connectHost = fromMaybe "localhost" redisHost }

randomQueueName :: B.Queue -> IO B.Queue
randomQueueName prefix = do
  postfix <- randomString (onlyAlphaNum randomASCII) 10
  return $ prefix <> "_" <> postfix

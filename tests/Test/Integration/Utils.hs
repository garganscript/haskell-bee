module Test.Integration.Utils
  ( getPSQLEnvConnectInfo
  , getRedisEnvConnectInfo
  , randomQueueName
  , waitUntil
  , waitUntilTVarEq
  , waitUntilTVarPred )
where

import Async.Worker.Broker qualified as B
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM.TVar (TVar, readTVarIO)
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Database.PostgreSQL.Simple qualified as PSQL
import Database.Redis qualified as Redis
import System.Environment (lookupEnv)
import System.Timeout qualified as Timeout
import Test.Hspec (expectationFailure, shouldBe, shouldSatisfy, Expectation, HasCallStack)
import Test.RandomStrings (randomASCII, randomString, onlyLower)


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

-- | Redis connect info that is fetched from env
getRedisEnvConnectInfo :: IO Redis.ConnectInfo
getRedisEnvConnectInfo = do
  redisHost <- lookupEnv "REDIS_HOST"
  -- https://hackage.haskell.org/package/hedis-0.15.2/docs/Database-Redis.html#v:defaultConnectInfo
  pure $ Redis.defaultConnectInfo { Redis.connectHost = fromMaybe "localhost" redisHost }

-- | Given a queue prefix, add a random suffix to create a queue name
randomQueueName :: B.Queue -> IO B.Queue
randomQueueName prefix = do
  postfix <- randomString (onlyLower randomASCII) 10
  return $ prefix <> "_" <> postfix

-- | Given a predicate IO action, test it for given number of
-- milliseconds or fail
waitUntil :: HasCallStack => IO Bool -> Int -> Expectation
waitUntil pred' timeoutMs = do
  _mTimeout <- Timeout.timeout (timeoutMs * 1000) performTest
  -- shortcut for testing mTimeout
  p <- pred'
  unless p (expectationFailure "Predicate test failed")
  
  where
    performTest = do
      p <- pred'
      if p
        then return ()
        else do
          threadDelay 50
          performTest

-- | Similar to 'waitUntil' but specialized to 'TVar' equality checking
waitUntilTVarEq :: (HasCallStack, Show a, Eq a) => TVar a -> a -> Int -> Expectation
waitUntilTVarEq tvar expected timeoutMs = do
  _mTimeout <- Timeout.timeout (timeoutMs * 1000) performTest
  -- shortcut for testing mTimeout
  val <- readTVarIO tvar
  val `shouldBe` expected
  
  where
    performTest = do
      val <- readTVarIO tvar
      if val == expected
        then return ()
        else do
          threadDelay 50
          performTest

-- | Similar to 'waitUntilTVarEq' but with predicate checking
waitUntilTVarPred :: (HasCallStack, Show a, Eq a) => TVar a -> (a -> Bool) -> Int -> Expectation
waitUntilTVarPred tvar predicate timeoutMs = do
  _mTimeout <- Timeout.timeout (timeoutMs * 1000) performTest
  -- shortcut for testing mTimeout
  val <- readTVarIO tvar
  val `shouldSatisfy` predicate
  
  where
    performTest = do
      val <- readTVarIO tvar
      if predicate val
        then return ()
        else do
          threadDelay 50
          performTest

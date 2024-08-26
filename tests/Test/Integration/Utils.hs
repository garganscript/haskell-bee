module Test.Integration.Utils
  ( defaultPGMQVt
  , getPSQLEnvConnectInfo
  , getRedisEnvConnectInfo
  , randomQueueName
  , waitUntil
  , waitUntilTVarEq
  , waitUntilTVarPred
  , waitUntilQueueSizeIs
  , waitUntilQueueEmpty )
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



-- | Timeout for 'wait' jobs, in ms.
newtype TimeoutMs = TimeoutMs Int
  deriving (Eq, Show, Num, Integral, Real, Enum, Ord)


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


waitThreadDelay :: Int
waitThreadDelay = 50 * 1000

-- | Given a predicate IO action, test it for given number of
-- milliseconds or fail
waitUntil :: HasCallStack => IO Bool -> TimeoutMs -> Expectation
waitUntil pred' (TimeoutMs timeoutMs) = do
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
          threadDelay waitThreadDelay
          performTest

-- | Similar to 'waitUntil' but specialized to 'TVar' equality checking
waitUntilTVarEq :: (HasCallStack, Show a, Eq a) => TVar a -> a -> TimeoutMs -> Expectation
waitUntilTVarEq tvar expected (TimeoutMs timeoutMs) = do
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
          threadDelay waitThreadDelay
          performTest

-- | Similar to 'waitUntilTVarEq' but with predicate checking
waitUntilTVarPred :: (HasCallStack, Show a, Eq a) => TVar a -> (a -> Bool) -> TimeoutMs -> Expectation
waitUntilTVarPred tvar predicate (TimeoutMs timeoutMs) = do
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
          threadDelay waitThreadDelay
          performTest

waitUntilQueueSizeIs :: (B.MessageBroker b a) => B.Broker b a -> B.Queue -> Int -> TimeoutMs -> Expectation
waitUntilQueueSizeIs b queue size (TimeoutMs timeoutMs) = do
  _mTimeout <- Timeout.timeout (timeoutMs * 1000) performTest

  qSize <- B.getQueueSize b queue
  qSize `shouldBe` size

  where
    performTest = do
      qSize <- B.getQueueSize b queue
      if qSize == size
        then return ()
        else do
          threadDelay waitThreadDelay
          performTest

waitUntilQueueEmpty :: (B.MessageBroker b a) => B.Broker b a -> B.Queue -> TimeoutMs -> Expectation
waitUntilQueueEmpty b queue timeoutMs = waitUntilQueueSizeIs b queue 0 timeoutMs

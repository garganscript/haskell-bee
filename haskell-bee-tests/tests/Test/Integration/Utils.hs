{-# LANGUAGE OverloadedStrings #-}

module Test.Integration.Utils
  ( randomQueueName
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
import Data.String (fromString)
import System.Environment (lookupEnv)
import System.Timeout qualified as Timeout
import Test.Hspec (expectationFailure, shouldBe, shouldSatisfy, Expectation, HasCallStack)
import Test.RandomStrings (randomASCII, randomString, onlyLower)



-- | Timeout for 'wait' jobs, in ms.
newtype TimeoutMs = TimeoutMs Int
  deriving (Eq, Show, Num, Integral, Real, Enum, Ord)


-- | Given a queue prefix, add a random suffix to create a queue name
randomQueueName :: B.Queue -> IO B.Queue
randomQueueName prefix = do
  postfix <- fromString <$> randomString (onlyLower randomASCII) 10
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
waitUntilTVarPred :: (HasCallStack, Show a) => TVar a -> (a -> Bool) -> TimeoutMs -> Expectation
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

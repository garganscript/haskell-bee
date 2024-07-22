{-# LANGUAGE QuasiQuotes #-}

{-
A very simple worker to test Database.PGMQ.Worker.
-}
    
module Main
where

import Async.Worker (sendJob', mkDefaultSendJob, mkDefaultSendJob', SendJob(..), run)
import Async.Worker.Broker.PGMQ (PGMQBroker, BrokerInitParams(PGMQBrokerInitParams))
import Async.Worker.Broker.Types (Broker, getMessage, toA, initBroker)
import Async.Worker.Types (State(..), PerformAction, getJob, formatStr, TimeoutStrategy(..), Job)
import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (Exception, throwIO)
import Data.Aeson (FromJSON(..), ToJSON(..), object, (.=), (.:), withObject, withText)
import Data.Text qualified as T
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PGMQ.Simple qualified as PGMQ
-- import Database.PGMQ.Worker qualified as PGMQW


data SimpleException = SimpleException String
  deriving Show
instance Exception SimpleException
    

data Message =
    Ping
  | Echo String
  | Wait Int
  | Error String
  deriving (Eq, Show)
instance ToJSON Message where
  toJSON Ping = toJSON ("ping" :: String)
  toJSON (Echo s) = toJSON $ object [ ("echo" .= s) ]
  toJSON (Wait s) = toJSON $ object [ ("wait" .= s) ]
  toJSON (Error e) = toJSON $ object [ ("error" .= e) ]
instance FromJSON Message where
  parseJSON v = parsePing v <|> parseEcho v <|> parseWait v <|> parseError v
    where
      parsePing = withText "Message (Ping)" $ \s -> do
        case s of
          "ping" -> pure Ping
          s'     -> fail $ T.unpack s'
      parseEcho = withObject "Message (Echo)" $ \o -> do
        s <- o .: "echo"
        return $ Echo s
      parseWait = withObject "Message (Wait)" $ \o -> do
        s <- o .: "wait"
        return $ Wait s
      parseError = withObject "Message (Error)" $ \o -> do
        e <- o .: "error"
        return $ Error e

    
performAction' :: PerformAction PGMQBroker Message
performAction' s brokerMessage = do
  let job = toA $ getMessage brokerMessage
  case getJob job of
    Ping -> putStrLn $ formatStr s "ping"
    Echo str -> putStrLn $ formatStr s ("echo " <> str)
    Wait int -> do 
      putStrLn $ formatStr s ( "waiting " <> show int <> " seconds")
      threadDelay (int*second)
    Error err -> do
      putStrLn $ formatStr s ("error " <> err)
      throwIO $ SimpleException $ "Error " <> err

second :: Int
second = 1000000
    
main :: IO ()
main = do
  let connInfo = PSQL.defaultConnectInfo { PSQL.connectUser = "postgres"
                                         , PSQL.connectDatabase = "postgres" }
  let brokerInitParams = PGMQBrokerInitParams connInfo :: BrokerInitParams PGMQBroker (Job Message)

  let queue = "simple_worker"
  
  -- let workersLst = [1, 2, 3, 4] :: [Int]
  let workersLst = [1, 2] :: [Int]
  -- let tasksLst = [101, 102, 102, 103, 104, 105, 106, 107] :: [Int]
  let tasksLst = [101] :: [Int]
  -- let tasksLst = [] :: [Int]

  mapM_ (\idx -> do
      broker <- initBroker brokerInitParams  :: IO (Broker PGMQBroker (Job Message))
      let state = State { broker
                        , queueName = queue
                        , name = "worker " <> show idx
                        , performAction = performAction'
                        , onMessageReceived = Nothing
                        , onJobFinish = Nothing
                        , onJobTimeout = Nothing
                        , onJobError = Nothing }
      forkIO $ run state
    ) workersLst
  
  -- delay so that the worker can initialize and settle
  threadDelay second

  conn <- PSQL.connect connInfo
  broker <- initBroker brokerInitParams :: IO (Broker PGMQBroker (Job Message))

  -- SendJob wrapper
  let mkJob msg = mkDefaultSendJob' broker queue msg
    
  mapM_ (\idx -> do
    sendJob' $ mkJob $ Ping
    sendJob' $ mkJob $ Wait 1
    sendJob' $ mkJob $ Echo $ "hello " <> show idx
    sendJob' $ mkJob $ Error $ "error " <> show idx
    ) tasksLst

  -- a job that will timeout
  let timedOut =
        (mkDefaultSendJob broker queue (Wait 5) 1)
          { toStrat = TSRepeatNElseArchive 3 }
  sendJob' timedOut
    
  threadDelay (10*second)

  metrics <- PGMQ.getMetrics conn queue
  putStrLn $ "metrics: " <> show metrics

  return ()


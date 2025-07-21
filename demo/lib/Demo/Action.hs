module Demo.Action where

import Async.Worker.Broker qualified as B
import Async.Worker.Broker.Types qualified as B
import Async.Worker.Broker.PGMQ (PGMQBroker)
import Async.Worker qualified as W
import Async.Worker.Types qualified as W
import Control.Concurrent (threadDelay)
import Control.Exception.Safe (Exception, throwIO)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.Int (Int8)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PostgreSQL.Simple.Types qualified as PSQL  -- Identifier
import Demo.State (initTable, collectWhenFinished, insertResult)
import Demo.Types (Job(..))
import System.Environment (lookupEnv)
import System.Random (randomIO)


data MyException = MyException String
  deriving (Show)
instance Exception MyException


performAction :: (W.HasWorkerBroker PGMQBroker Job)
              => W.State PGMQBroker Job
              -> B.BrokerMessage PGMQBroker (W.Job Job)
              -> IO ()
performAction (W.State { broker, queueName }) bm = do
  let job = B.toA (B.getMessage bm)
  let md = W.metadata job
  
  case W.getJob job of
    Echo s -> putStrLn s
    Wait t -> do
      putStrLn $ "waiting " <> show t <> "s"
      threadDelay (t * 1_000_000)
    Error e -> throwIO $ MyException e
    Quit -> throwIO $ W.KillWorkerSafely

    -- | A periodic task that will respawn itself
    Periodic { counter, delay, name } -> do
      putStrLn $ "[periodic " <> name <> "] counter: " <> show counter

      if (counter < 10) then do
        let sj = W.mkDefaultSendJob' broker queueName (Periodic { counter = counter + 1, delay, name })
        void $ W.sendJob' $ sj { W.delay = B.TimeoutS delay }
      else do
        putStrLn $ "[periodic " <> name <> "] stopping"

    sm@(StarMap { pgConnString, mTableName = Nothing, numJobs }) -> do
      -- No table name, this means we run for the first time.
      -- Create the table and spawn subtasks.
      tableName <- initTable pgConnString "starmap"

      msgIds <- mapM (\_ -> do
                 x <- randomIO :: IO Int8
                 let sj = W.mkDefaultSendJob' broker queueName $
                            SquareMap { pgConnString, x = fromIntegral x, tableName }
                 W.sendJob' sj
             ) [0..numJobs]

      -- Normally message ids don't need to be ints. However, with PGMQ
      -- they are and we use a hack here to get them (I don't want to
      -- expose `PGMQMid` to `Int` conversion without serious reasons)
      let jMsgIds = Aeson.encode <$> msgIds
      let intMsgIds = catMaybes $ (\j -> Aeson.decode j :: Maybe Int) <$> jMsgIds
      let sj = W.mkDefaultSendJob' broker queueName $
                 sm { mTableName = Just tableName
                    , messageIds = intMsgIds }
      void $ W.sendJob' $ sj { W.delay = B.TimeoutS 1 }

    -- | A task that watches given table and checks if all subtasks are finished
    sm@(StarMap { pgConnString, mTableName = Just tableName, messageIds }) -> do
      mRows <- collectWhenFinished pgConnString tableName messageIds :: IO (Maybe [(Int, Int)])
      case mRows of
        Just rows -> do
          putStrLn $ "[star-map @ " <> tableName <> "] all subtasks finished : " <> show rows
          putStrLn $ "[star-map @ " <> tableName <> "] sum (aggregation demo) : " <> show (sum (snd <$> rows))
        Nothing -> do
          putStrLn $ "[star-map @ " <> tableName <> "] rescheduling to check again"
          -- Need to reschedule starmap checking
          let sj = W.mkDefaultSendJob' broker queueName sm
          void $ W.sendJob' $ sj { W.delay = B.TimeoutS 5 }

    -- | A subtask which squares a number and stores in in a table, for `StarMap` to analyze
    SquareMap { pgConnString, x, tableName } -> do
       let jMsgId = Aeson.encode (B.messageId bm)
       msgId <- Aeson.throwDecode jMsgId :: IO Int

       putStrLn $ "[square-map @ " <> tableName <> " :: " <> show msgId <> "] x = " <> show x

       insertResult pgConnString tableName msgId (x*x)


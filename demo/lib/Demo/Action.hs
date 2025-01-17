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
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PostgreSQL.Simple.Types qualified as PSQL  -- Identifier
import Demo.Types (Job(..))
import System.Environment (lookupEnv)


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

    -- | A task that watches given table and checks if all subtasks are finished
    sm@(StarMap { tableName, messageIds }) -> do
      -- just reuse the broker DB
       mConnInfo <- lookupEnv "POSTGRES_CONN"
       let connInfo = T.encodeUtf8 $ T.pack $ fromMaybe "host=localhost port=5432 dbname=postgres user=postgres" mConnInfo
    
       conn <- PSQL.connectPostgreSQL connInfo

       let tName = PSQL.Identifier $ T.pack tableName
       rows <- PSQL.query conn "SELECT message_id, value FROM ? WHERE value IS NOT NULL" (PSQL.Only tName) :: IO [(Int, Int)]
       let finishedMessageIds = fst <$> rows
       if (Set.fromList finishedMessageIds) == (Set.fromList messageIds) then do
         _ <- PSQL.execute conn "DROP TABLE ?" (PSQL.Only tName)
         putStrLn $ "[star-map @ " <> tableName <> "] all subtasks finished : " <> show rows
       else do
         putStrLn $ "[star-map @ " <> tableName <> "] rescheduling to check again"
         -- Need to reschedule starmap checking
         let sj = W.mkDefaultSendJob' broker queueName sm
         void $ W.sendJob' $ sj { W.delay = B.TimeoutS 5 }

    -- | A subtask which squares a number and stores in in a table, for `StarMap` to analyze
    SquareMap { x, tableName } -> do
       let jMsgId = Aeson.encode (B.messageId bm)
       msgId <- Aeson.throwDecode jMsgId :: IO Int

       putStrLn $ "[square-map @ " <> tableName <> " :: " <> show msgId <> "] x = " <> show x
       mConnInfo <- lookupEnv "POSTGRES_CONN"
       let connInfo = T.encodeUtf8 $ T.pack $ fromMaybe "host=localhost port=5432 dbname=postgres user=postgres" mConnInfo
    
       conn <- PSQL.connectPostgreSQL connInfo

       let tName = PSQL.Identifier $ T.pack tableName
       void $ PSQL.execute conn "INSERT INTO ? (message_id, value) VALUES (?, ?)" (tName, msgId, x*x)


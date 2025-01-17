module Main where


import App.Types
import Async.Worker qualified as W
import Async.Worker.Broker.Types qualified as B
import Async.Worker.Types qualified as W
import Control.Concurrent (throwTo)
import Control.Concurrent.Async (asyncThreadId, wait)
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.Int (Int8)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PostgreSQL.Simple.Types qualified as PSQL  -- Identifier
import Demo.PGMQ (initBroker, initWorker)
import Demo.Types qualified as DT
import Options.Applicative
import System.Environment (lookupEnv)
import System.Posix.Signals (Handler(Catch), installHandler, keyboardSignal)
import System.Random (randomIO)
import Test.RandomStrings (randomASCII, randomString, onlyLower)





main :: IO ()
main = start =<< execParser programParser


start :: Program -> IO ()
start (Program (GlobalArgs { .. }) (Worker WorkerArgs)) = do
  initWorker "default" _ga_queue $ \a _state -> do
    let tid = asyncThreadId a
    _ <- installHandler keyboardSignal (Catch (throwTo tid W.KillWorkerSafely)) Nothing
    
    wait a
start (Program (GlobalArgs { .. }) QueueSize) = do
  b <- initBroker
  s <- B.getQueueSize b _ga_queue
  putStrLn $ "queue size: " <> show s
    
start (Program (GlobalArgs { .. }) (Echo (EchoArgs { .. }))) = do
  b <- initBroker
  let sj = W.mkDefaultSendJob' b _ga_queue (DT.Echo _ea_message)
  void $ W.sendJob' $ sj { W.archStrat = W.ASArchive }
start (Program (GlobalArgs { .. }) (Error (ErrorArgs { .. }))) = do
  b <- initBroker
  let sj = W.mkDefaultSendJob' b _ga_queue (DT.Error _ea_error)
  void $ W.sendJob' sj
start (Program (GlobalArgs { .. }) Quit) = do
  b <- initBroker
  let sj = W.mkDefaultSendJob' b _ga_queue DT.Quit
  void $ W.sendJob' $ sj { W.resendOnKill = False }
start (Program (GlobalArgs { .. }) (Wait (WaitArgs { .. }))) = do
  b <- initBroker
  let sj = W.mkDefaultSendJob' b _ga_queue (DT.Wait _wa_time)
  void $ W.sendJob' sj
start (Program (GlobalArgs { .. }) (Periodic (PeriodicArgs { .. }))) = do
  b <- initBroker
  let sj = W.mkDefaultSendJob' b _ga_queue (DT.Periodic { counter = 0, delay = _pa_interval, name = _pa_name })
  void $ W.sendJob' $ sj { W.delay = B.TimeoutS _pa_interval }
start (Program (GlobalArgs { .. }) (StarMap (StarMapArgs { .. }))) = do
  -- Create temporary table first
  mConnInfo <- lookupEnv "POSTGRES_CONN"
  let connInfo = T.encodeUtf8 $ T.pack $ fromMaybe "host=localhost port=5432 dbname=postgres user=postgres" mConnInfo

  postfix <- randomString (onlyLower randomASCII) 20
  let tableName = "starmap_" <> postfix
  let tName = PSQL.Identifier $ T.pack tableName

  conn <- PSQL.connectPostgreSQL connInfo

  _ <- PSQL.execute conn "CREATE TABLE ? (message_id INT, value INT)" (PSQL.Only tName)


  b <- initBroker
  msgIds <- mapM (\_ -> do
                     x <- randomIO :: IO Int8
                     let sj = W.mkDefaultSendJob' b _ga_queue (DT.SquareMap { x = fromIntegral x, tableName })
                     W.sendJob' sj
                 ) [0.._sm_jobs]
  -- Normally message ids don't need to be ints. However, with PGMQ
  -- they are and we use a hack here to get them (I don't want to
  -- expose `PGMQMid` to `Int` conversion without serious reasons)
  let jMsgIds = Aeson.encode <$> msgIds
  let intMsgIds = catMaybes $ (\j -> Aeson.decode j :: Maybe Int) <$> jMsgIds
  let sj = W.mkDefaultSendJob' b _ga_queue (DT.StarMap { tableName, messageIds = intMsgIds })
  void $ W.sendJob' $ sj { W.delay = B.TimeoutS 1 }

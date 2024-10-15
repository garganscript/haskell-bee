module Main where


import App.Types
import Async.Worker qualified as W
import Async.Worker.Broker.Types qualified as B
import Control.Concurrent (throwTo)
import Control.Concurrent.Async (asyncThreadId, wait)
import Control.Monad (void)
import Demo.PGMQ (initBroker, initWorker)
import Demo.Types qualified as DT
import Options.Applicative
import System.Posix.Signals (Handler(Catch), installHandler, keyboardSignal)





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
  void $ W.sendJob' sj
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

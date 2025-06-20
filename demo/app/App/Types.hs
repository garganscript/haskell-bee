module App.Types
  ( Program(..)
  , GlobalArgs(..)
  , Command(..)
  , WorkerArgs(..)
  , EchoArgs(..)
  , ErrorArgs(..)
  , WaitArgs(..)
  , PeriodicArgs(..)
  , StarMapArgs(..)

  , programParser )
where

import Async.Worker.Broker.Types qualified as B
import Options.Applicative


data Program =
  Program GlobalArgs Command
  deriving (Eq, Show)

programParser :: ParserInfo Program
programParser = info
  ( ( Program <$> global <*> commandParser ) <**> helper )
  ( fullDesc
   <> header "haskell-bee demo"
   <> progDesc "Simple demonstration of worker capabilities" )

data GlobalArgs =
  GlobalArgs { _ga_queue :: B.Queue }
  deriving (Eq, Show)

global :: Parser GlobalArgs
global = GlobalArgs
    <$> (B.Queue <$> strOption ( long "queue"
                              <> value "default"
                              <> help "Queue that we will use" ) )


data Command
  = Worker WorkerArgs
  | QueueSize
  
  | Echo EchoArgs
  | Error ErrorArgs
  | Quit
  | Wait WaitArgs
  | Periodic PeriodicArgs
  | StarMap StarMapArgs
  deriving (Eq, Show)

commandParser :: Parser Command
commandParser = subparser
    ( command "worker" (info (worker <**> helper) (progDesc "run worker") )
   <> command "queue-size" (info (queueSize <**> helper) (progDesc "show queue size") )

   -- tasks
   <> command "echo" (info (echo <**> helper) (progDesc "echo task") )
   <> command "error" (info (error' <**> helper) (progDesc "error task") )
   <> command "quit" (info (quit <**> helper) (progDesc "quit task") )
   <> command "wait" (info (wait <**> helper) (progDesc "wait task") )
   <> command "periodic" (info (periodic <**> helper) (progDesc "periodic task") )
   <> command "star-map" (info (starMap <**> helper) (progDesc "star-map task") )
    )

data WorkerArgs =
  WorkerArgs
  deriving (Eq, Show)

worker :: Parser Command
worker = pure $ Worker WorkerArgs

queueSize :: Parser Command
queueSize = pure QueueSize



data EchoArgs =
  EchoArgs { _ea_message :: String }
  deriving (Eq, Show)

echo :: Parser Command
echo = Echo
  <$> ( EchoArgs
      <$> argument str ( metavar "MESSAGE"
                      <> help "message to send in echo" ) )

data ErrorArgs =
  ErrorArgs { _ea_error :: String }
  deriving (Eq, Show)

error' :: Parser Command
error' = Error
  <$> ( ErrorArgs
      <$> argument str ( metavar "ERROR"
                      <> help "Error message" ) )

quit :: Parser Command
quit = pure Quit

data WaitArgs =
  WaitArgs { _wa_time :: Int }
  deriving (Eq, Show)

wait :: Parser Command
wait = Wait
  <$> ( WaitArgs
     <$> argument auto ( metavar "TIME"
                      <> help "Time to wait, in seconds") )

data PeriodicArgs =
  PeriodicArgs { _pa_interval :: Int
               , _pa_name     :: String }
  deriving (Eq, Show)

periodic :: Parser Command
periodic = Periodic
  <$> ( PeriodicArgs
     <$> argument auto ( metavar "INTERVAL"
                      <> help "Interval in seconds between tasks")
     <*> strArgument ( metavar "NAME"
                      <> help "Name of the task, to distinguish from others") )

data StarMapArgs =
  StarMapArgs { _sm_jobs :: Int }
  deriving (Eq, Show)

starMap :: Parser Command
starMap = StarMap
  <$> ( StarMapArgs
     <$> argument auto ( metavar "JOBS"
                      <> help "Number of jobs to spawn") )

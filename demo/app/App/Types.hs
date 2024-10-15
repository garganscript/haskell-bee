module App.Types
  ( Program(..)
  , GlobalArgs(..)
  , Command(..)
  , WorkerArgs(..)
  , EchoArgs(..)
  , ErrorArgs(..)
  , WaitArgs(..)

  , programParser )
where

import Async.Worker.Broker.Types qualified as B
import Options.Applicative


data Program =
  Program GlobalArgs Command
  deriving (Eq, Show)

programParser :: ParserInfo Program
programParser = info
  ( ( Program <$> global <*> commandParser ) <**> helper ) mempty

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
  deriving (Eq, Show)

commandParser :: Parser Command
commandParser = subparser
    ( command "worker" (info (worker <**> helper) mempty )
   <> command "queue-size" (info (queueSize <**> helper) mempty )

   -- tasks
   <> command "echo" (info (echo <**> helper) mempty )
   <> command "error" (info (error' <**> helper) mempty )
   <> command "quit" (info (quit <**> helper) mempty )
   <> command "wait" (info (wait <**> helper) mempty )
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

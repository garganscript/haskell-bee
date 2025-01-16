# haskell-bee demo

## DB setup

This is a simple demo of pgmq-based workers.

First, you need a postgresql database:
```shell
podman run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres postgres
```
Next, you can configure postgres access via an env variable:
```shell
export POSTGRES_CONN="host=localhost port=5432 dbname=postgres user=postgres password=postgres"
```

## Command-line

To run the command-line and see available options:
```shell
cabal v2-run demo -- -h
```

You need to spawn the worker first:
```shell
cabal v2-run demo -- worker
```

Now you can send tasks to the worker (from another terminal):
```shell
cabal v2-run demo -- echo "hello"
cabal v2-run demo -- error "oops!"
cabal v2-run demo -- wait 10
cabal v2-run demo -- quit
```

## About killing with `Ctrl-C`

`haskell-bee` implements possibility of a graceful shutdown of the worker.

Depending on the `resendWhenWorkerKilled` property in the task
metadata, the currently running task will be either killed and
discarded or killed and resent to the broker.

One often kills command-line programs with `Ctrl-C`. Hence, a small
wrapper is needed around `initWorker` to support such graceful
shutdown:
```haskell
initWorker "default" _ga_queue $ \a _state -> do
  let tid = asyncThreadId a
  _ <- installHandler keyboardSignal (Catch (throwTo tid W.KillWorkerSafely)) Nothing
  
  wait a
```

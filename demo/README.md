# haskell-bee demo

A demonstration application showing how to use haskell-bee with PostgreSQL/PGMQ for job processing.

## Setup

### DB setup

Start a PostgreSQL database:
```shell
podman run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres postgres
```
Configure database connection via environment variable:
```shell
export POSTGRES_CONN="host=localhost port=5432 dbname=postgres user=postgres password=postgres"
```

## Usage

### View Available Commands

To see all available options:
```shell
cabal v2-run demo -- -h
```

### Running the Demo

1. **Start the worker** (in one terminal):
```shell
cabal v2-run demo -- worker
```

2. **Send jobs to the worker** (from another terminal):
```shell
# Simple echo job
cabal v2-run demo -- echo "hello"

# Job that throws an error
cabal v2-run demo -- error "oops!"

# Job that waits for specified number of seconds
cabal v2-run demo -- wait 10

# Gracefully shutdown the worker
cabal v2-run demo -- quit

# Periodic job that runs every 4 seconds
cabal v2-run demo -- periodic 4 'my periodic task'

# Parallel job processing example
cabal v2-run demo -- star-map 25
```

## Graceful Shutdown with Ctrl-C

The demo implements graceful shutdown handling. When you press `Ctrl-C`, the worker will:
- Complete currently running tasks (or cancel them based on configuration)
- Either discard or re-queue interrupted tasks depending on the `resendWhenWorkerKilled` setting

The implementation uses signal handling:
```haskell
initWorker "default" _ga_queue $ \a _state -> do
  let tid = asyncThreadId a
  _ <- installHandler keyboardSignal (Catch (throwTo tid W.KillWorkerSafely)) Nothing
  wait a
```

## Development with Nix

If you encounter missing dependencies (`gmp` or `libpq`), use the provided Nix flake:
```shell
nix develop
cabal v2-build
```

This ensures all system dependencies are available in a reproducible environment.
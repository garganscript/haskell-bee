# Haskell-bee

![bee on a honeycomb. Credits: https://en.wikipedia.org/wiki/Honey_bee#/media/File:Western_honey_bee_on_a_honeycomb.jpg](img/bee-wiki.jpg)

A lightweight, type-safe library for implementing asynchronous job workers in Haskell.

This is a library for implementing asynchronous workers which can fetch jobs from a (configurable) broker.

You can think of it as a simple Haskell rewrite of [Celery](https://docs.celeryq.dev/en/stable/).

**Why Haskell?** Haskell's type system makes async job processing much safer and easier to reason about compared to Python's Celery. Combined with Haskell's [excellent concurrency story](https://bitbashing.io/haskell-concurrency.html), you get robust job processing with compile-time guarantees.

**Key features:**
- Multiple broker backends (PostgreSQL/PGMQ, Redis, STM)
- Configurable timeout and retry strategies
- Exception-safe job processing
- Support for delayed/periodic tasks

## Getting started

The quickest way to understand how to use haskell-bee is to check out the [`./demo`](./demo) app, which shows practical examples of job processing.

If you're interested in reading about various design aspects, see
[design notes](./DESIGN-NOTES.md).

## Testing

Tests are generic, they are bundled as a library in
[`haskell-bee-tests`](./haskell-bee-tests).

Each broker implements these generic tests in its own test suite.

### PGMQ

Start postgresql:
```shell
podman run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres postgres
```
Then run tests:
```shell
cabal v2-test haskell-bee-pgmq --test-show-details=streaming
```
(you can use `nix -L develop` if you miss things like `libgmp`).

### Redis

Start redis:
```shell
podman run --rm -it -p 6379:6379 redis:latest
```
Then run tests:
```shell
cabal v2-test haskell-bee-redis --test-show-details=streaming
```

### STM

No need to start the broker, just run the tests:
```shell
cabal v2-test haskell-bee-stm --test-show-details=streaming
```

## Things to watch out for

### Exceptions

`haskell-bee` uses exceptions to detect issues with
jobs and trigger timeouts. Be careful when catching exceptions in your code.

**Problem:** If your code contains something like: 
```haskell
runSomeAction `catch` (\(e :: SomeException) -> whatever)
```
and `whatever` doesn't re-throw `e`, your job will continue running without
noticing `Timeout` exceptions.

**Solution:** Always specialize your exception handling to only catch the specific exceptions you want to handle:
```haskell
runSomeAction `catch` (\(e :: MySpecificException) -> handleMyException e)
```

## Other work

[Haskell Job Queues: An Ultimate Guide (2020)](https://www.haskelltutorials.com/odd-jobs/haskell-job-queues-ultimate-guide.html)

- [hasql-queue](https://hackage.haskell.org/package/hasql-queue) This
  implements a custom PostgreSQL schema. On top of that it proviedes
  some simple strategies for running tasks.
- [immortal-queue](https://hackage.haskell.org/package/immortal-queue)
  This is a library that you can use to build an asynchronous worker
  pool. The `Broker` can be configurable.
- [job](https://hackage.haskell.org/package/job-0.1.1/docs/Job.html)
  Recent addition with Broker, Worker, job metadata. Supports
  retrying, re-nicing.
- [odd-jobs](https://hackage.haskell.org/package/odd-jobs)
  PostgreSQL-backed, has an admin UI, seems mature.
- [broccoli](https://github.com/densumesh/broccoli)
  Rust library, a message queue system with configurable brokers.
  Similar to Celery. Has configurable retry strategies.

### Brokers

These libraries implement mostly the queueing mechanism only, without
any job metadata structure like in haskell-bee. They fall into the
`Broker` category of haskell-bee.

- [postgresql-simple-queue](https://hackage.haskell.org/package/postgresql-simple-queue)
  (it uses a custom queueing mechanism; it is more like a `Broker` in haskell-bee)
- [stm-queue](https://hackage.haskell.org/package/stm-queue) (in-memory only)
- [mongodb-queue](https://hackage.haskell.org/package/mongodb-queue)
  (again, similar to our `Broker`)
- [amazonka-sqs](https://hackage.haskell.org/package/amazonka-sqs)
  (again, a `Broker`, based on Amazon SQS. Might be worth integrating
  this in the future)
- [redis-job-queue](https://hackage.haskell.org/package/redis-job-queue)
  (worth investigating the sorted set approach)
- [poolboy](https://hackage.haskell.org/package/poolboy) (in-memory only)

## Credit

All credit goes to the [Gargantext
team](https://www.gargantext.org/). This work was done as part of my
contract at [ISC-PIF CNRS](https://iscpif.fr/).

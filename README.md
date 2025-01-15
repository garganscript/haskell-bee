# Haskell-bee

![bee on a honeycomb. Credits: https://en.wikipedia.org/wiki/Honey_bee#/media/File:Western_honey_bee_on_a_honeycomb.jpg](img/bee-wiki.jpg)

This is a library for implementing asynchronous workers which can fetch jobs from a (configurable) broker.

You can think of it as a simple Haskell rewrite of [Celery](https://docs.celeryq.dev/en/stable/).

## Design

The high-level picture is that we have 2 components:
- **broker** - which is an abstraction over some queueing system
  (e.g. [pgmq](https://gitlab.iscpif.fr/gargantext/haskell-pgmq) or
  redis)
- **worker** - which takes a **broker** definition and adds a job
  system on top of it

### Broker

The library so far contains 3 implementations for brokers:
- [**pgmq**](./haskell-bee-pgmq) - which is based on
  [haskell-pgmq](https://gitlab.iscpif.fr/gargantext/haskell-pgmq)
- [**redis**](./haskell-bee-redis) - which is a very simple `LPUSH`-based queue
  (c.f. https://redis.io/glossary/redis-queue/)
- [**STM**](./haskell-bee-stm) - which uses the `STM`, could be useful for testing

`pgmq` broker so far is assumed to be most stable and complete,
`redis` and `STM` are considered experimental.

The broker definition uses some more advanced GHC type extensions
(in particular, [type families](https://wiki.haskell.org/GHC/Type_families))
at the benefit of having
[one clear interface](./haskell-bee/src/Async/Worker/Broker/Types.hs)
for what we expect from the broker.

### Worker

The worker (defined in [`./haskell-bee/src/Async/Worker.hs`](./haskell-bee/src/Async/Worker.hs)) is completely described by it's `State`.

`State` contains information such as:
- broker instance
- queue name (one worker is assumed to be assigned to a single queue. If you want more queues, just spawn more workers)
- actions to be performed on incoming data
- strategies for handling errors and timeouts
- events to call custom hooks:
  - after job is fetched from broker
  - after job finishes
  - after timeout occurred
  - after job error

This project doesn't provide worker management utilities.

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
contract there.

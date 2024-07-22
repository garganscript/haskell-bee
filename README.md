# Haskell-bee

This is a library for implementing asynchronous workers which can fetch jobs from a (configurable) broker.

You can think of it as a simple Haskell rewrite of [Celery](https://docs.celeryq.dev/en/stable/).

## Design

The high-level picture is that we have 2 components:
- **broker** - which is an abstraction over some queueing system (e.g. [pgmq](https://gitlab.iscpif.fr/gargantext/haskell-pgmq) or redis)
- **worker** - which takes a **broker** definition and adds a job system on top of it

### Broker

The library so far contains 2 implementations for brokers:
- **pgmq** - which is based on [haskell-pgmq](https://gitlab.iscpif.fr/gargantext/haskell-pgmq)
- **redis** - which is a very simple `LPUSH`-based queue (c.f. https://redis.io/glossary/redis-queue/)

The broker definition uses some more advanced GHC type extensions
(in particular, [type families](https://wiki.haskell.org/GHC/Type_families))
at the benefit of having one clear interface for what we expect from the broker.

### Worker

The worker (defined in [`./src/Async/Worker.hs`]) is completely described by it's `State`.

This contains information such as:
- broker instance
- queue name (one worker is assumed to be assigned to a single queue. If you want more queues, just spawn more workers)
- actions to be performed on incoming data
- strategies for handling errors and timeouts
- events to call custom hooks:
  - after job is fetched from broker
  - after job finishes
  - after timeout occurred
  - after job error
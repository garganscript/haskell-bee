# Design notes

The high-level picture is that we have 2 components:
- **broker** - which is an abstraction over some queueing system
  (e.g. [pgmq](https://gitlab.iscpif.fr/gargantext/haskell-pgmq) or
  redis)
- **worker** - which takes a **broker** definition and adds a job
  system on top of it

## Broker

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

### <a id="about-timeouts"></a> About timeouts

#### TLDR

Set `timeout` in your job metadata to the number of seconds you expect
your job to take (to be safe, add some margin). For PGMQ, set
`defaultVt` to some positive value (`5` is good enough).

#### <a id="broker-details"></a> Details

##### Timeout

Each job has a `timeout` field in it's metadata. When a job is
fetched, meadata is read and the timeout is set in the broker
immediately. This is to tell the broker to hide this message for given
amount of time. In case worker fails miserably (connection loss with
the broker, etc), the job will be shown again in the broker after the
specified timeout.

This means you should have some kind of estimate of how long your job
will take.

At the same time, the worker loop itself keeps an internal time
counter and compares job execution time. If it exceeds that same
`timeout` metadata value, it acts according to the specified
`TimeoutStrategy`. This should be the "normal" way to call timeouts.

##### <a id="broker-visibility-timeout"></a> Visibility timeout

The `pgmq` broker introduces a `defaultVt` value
(https://tembo.io/pgmq/#visibility-timeout-vt). This is because after
the job is sent to the worker, it is kept in pgmq queue until the
worker marks it as finished. If `defaultVt` would be `0`, the job will
be shown immediately to another worker which can result in duplicate
work. (this behavior seems to be consistent with e.g.
[Amazon SQS](https://en.wikipedia.org/wiki/Amazon_Simple_Queue_Service#Message_deletion)).

Since the worker already executes setting broker visibility timeout
using job's metadata (as fast as possible), it will eventually block
other workers from reading this message.

However, postgres transactionality leaves us a very small time frame
where the same job is available to multiple workers. To prevent this,
set `defaultVt` to some positive number. It has to be large enough
that the worker has time to fetch the message and set the custom
`timeout` from job's metadata.

##### Timeout vs visibilityt imeout

Note that `timeout` is a purely worker setting. It is used to limit
the time it takes for a job to run. If a job hangs, the worker kills
it and acts according to the job's `timeout strategy`.

On the other hand, `visibility timeout` is a broker setting.

These two are related in that the worker, upon fetching a job, will
set `visibility timeout` of a task to that of a `timeout` so that it's
invisible for a `timeout` duration.

## Worker

The worker (defined in
[`./haskell-bee/src/Async/Worker.hs`](./haskell-bee/src/Async/Worker.hs))
is completely described by it's `State`.

`State` contains information such as:
- broker instance
- queue name (one worker is assumed to be assigned to a single
  queue. If you want more queues, just spawn more workers)
- actions to be performed on incoming data
- strategies for handling errors and timeouts
- events to call custom hooks:
  - after job is fetched from broker
  - after job finishes
  - after timeout occurred
  - after job error

This project doesn't provide worker management utilities ([see
why](#higher-level-patterns)). As such, you can just use
`Control.Concurrent.Async.forConcurrently` to spawn multiple workers
yourself (see
[here](https://gitlab.iscpif.fr/gargantext/haskell-gargantext/blob/13457ca8b7db29f178a4001ce9cac0e849473cef/bin/gargantext-cli/CLI/Worker.hs#L130)). The
worker is designed in such a way that it tries to catch all exceptions
in your job, and as such shouldn't fail, leak memory, etc :P If it
does fail, it's probably a bug.

__NOTE__ A worker management system for `haskell-bee` should probably
be called `haskell-hive`.

Each worker is basically one big loop which fetches the message and
processes it accordingly. Thus you need to enumerate your jobs like
this:
```haskell
data Job = Echo String | Ping
  deriving (Show, FromJSON, ToJSON)
```
and then specify the `performAction` function which will pattern match
on the `Job` constructor.

Please note that you can spawn multiple workers assigned to the same
queue. Broker should guarantee a one-time delivery (see the [About
timeouts](#about-timeouts) section).

### Strategies

When worker processes a job, it can end in various states:
- finishes correctly. In this case `archiveStrategy` from job's
  metadata is used.
- times out. In this case, `timeoutStrategy` is used.
- errors. In this case, `errorStrategy` is used.

The strategies are implemented as a sum type, e.g.:
```haskell
data TimeoutStrategy =
    TSDelete
  | TSArchive
  | TSRepeat
  | TSRepeatNElseArchive Int
  | TSRepeatNElseDelete Int
```

In particular, the `RepeatN` strategies repeat given action `N` times
and then fall back to something different. Note that there is a
`readCount` field in each job metadata and when the job is rescheduled
because of a `RepeatN` strategy, that counter is incremented.

## The "simpler" interface

All that job metadata is quite large. Hence, there is a `SendJob`
datatype in
[`./haskell-bee/src/Async/Worker.hs`](./haskell-bee/src/Async/Worker.hs).

It aims to simplify things a bit, by specifying a `mkDefaultSendJob'`
with some good enough values. You only need to specify the queue and
the job that you want to send.

## <a id="periodic-tasks"></a> Periodic tasks

If you look at
[`./haskell-bee/src/Async/Worker.hs`](./haskell-bee/src/Async/Worker.hs),
you'll notice that there is a function called `sendJobDelayed`. This
is because broker allows for a `sendMessageDelayed`. Such a message is
queued, but the broker will show it after a predefined number of
seconds. (Internally, for PGMQ, this is just the `visibility timeout`
setting, c.f. [broker visibility timeout](#broker-visibility-timeout)).

You can use this mechanism to create periodic tasks. Just call
something like
```haskell
let sj = W.mkDefaultSendJob' broker queueName (Periodic { .. })
void $ W.sendJob' $ sj { W.delay = B.TimeoutS delay }
```
(`performAction` allows you to look up into worker's `State` which
contains the `broker` connection; don't overuse it though to not block
the worker).

The message will be hidden and the worker can process other messages
between the periodic tasks.

The same mechanism can be used to implement exponential backoff etc.

__NOTE__: To make sure your periodic task is scheduled for next
execution, wrap your action with
[`Control.Exception.Safe.finally`](https://hackage.haskell.org/package/safe-exceptions-0.1.7.4/docs/Control-Exception-Safe.html#v:finally).
The exception will be re-raised, but you have a guarantee of
scheduling the task for later.

## <a id="higher-level-patterns"></a> Higher-level patterns

Celery allows the programmer to define some [higher-level
patterns](https://docs.celeryq.dev/en/stable/userguide/canvas.html),
e.g. chaining jobs, mapping the results of multiple async jobs over
some function, etc.

`haskell-bee` doesn't support this. This is because I didn't implement
any worker management system. Each worker just observes a single queue
in a predefined broker.

If you have a mixture of long-running tasks and some fast ones, you
can create 2 queues and assign brokers to them. This way slow tasks
won't stop your fast ones from executing.

It is also possible to spawn tasks from within a task. However, you
have to trace the results of these tasks yourself, as `haskell-bee`
doesn't implement "backends" (in Celery terms, this is a database that
holds job's results).

The reason is complexity of these features in general. I have worked
with Celery couple years ago and back then the `chain` etc. mechanisms
weren't that stable and led my code to deadlocks. So this wasn't easy
for them to implement as well. Just look at the
[bug reports](https://github.com/celery/celery/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22Issue%20Type%3A%20Bug%20Report%22).
Many of them are in fact about concurrency expectations of a
multi-worker setup or higher-level task patterns.

Concurrency is hard and we avoid it by not implementing unnecessary
features :) We're still in a better position than Celery, since
Haskell's type checking allows to catch more bugs than the Python
runtime :)

### Ways to deal with it

As such, we could probably reimplement the `performAction` function to
return something (it currently returns `IO ()`) -- simplest thing
being some JSON value (we avoid too much type mangling at the cost of
runtime deserialization of that value).

Then, in the `onJobFinish` callback, we could use that return value to
trigger some other task. It might even be part of an `ArchiveStrategy`
to call other task. Probably it's best to implement this not in
`haskell-bee` itself, but as some wrapper around it.


Another way is to add some "state" parameter to your task. I.e. your
first task's return value goes into "state" of the next spawned task.

### map-reduce

The "map" part in "map-reduce" is easy: just spawn as many tasks as
you need.

It's the "reducing" that is more tricky with `haskell-bee`: wait for
all tasks to finish and call something afterwards (on the collected
results).

If we used PGMQ, then we can already use the fact that we can connect
to a PostgreSQL database :)

We thus create some table with `message_id` and `result` columns. Then
we spawn our tasks, noting to pass them the table name to use. Each
task stores it's result that table under it's own `message_id`.

Then we spawn a task to periodically (see
[periodic tasks](#periodic-tasks)) check that table and see if all
`message_id`'s are filled in. We then have a list of all the results,
from which we can trigger another task. Remember to remove that table
afterwards.

For more details, see [`demo`](./demo), where this pattern is
implemented as `StarMap` task and `SquareMap` subtask (which needs the
`tableName` to store its result).

Probably `tableName` and `messageIds` could be stored in task's
metadata (this way `StarMap` and `SquareMap` constructors can be
simplified to look almost like a RPC call). Then, table creation,
value insert, table checking and cleanup could be implemented
generically.

If you know whether it's possible to implement a "reduce" mechanism
just by message-passing in this framework, please
[tell me](mailto:pk@intrepidus.pl).

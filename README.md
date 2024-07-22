# Haskell-pgmq

This is a simple interface to Tembo's
[pgmq](https://github.com/tembo-io/pgmq) PostgreSQL extension.

Based on [elixir pgmq](https://hexdocs.pm/pgmq/Pgmq.html) bindings.

## Running test cases

There is a binary in [./bin/simple-test/Main.hs](./bin/simple-test/Main.hs), it should contain all test cases for the basic module `Database.PGMQ.Simple`.

First, let's decide which container to use:
```shell
export PGMQ_CONTAINER=docker.io/cgenie/pgmq:16-1.3.3.1
```
However with the above, some tests might fail because some functions
throw errors when a table is not there (e.g. `pgmq.drop_queue`).

Some fixes are made in our custom repo:
https://github.com/garganscript/pgmq
and you can use:
```shell
export PGMQ_CONTAINER=cgenie/pgmq:16-1.3.3.1
```

To run it, first start a pgmq container:
```shell
  podman run --name pgmq -e POSTGRES_PASSWORD=postgres -p 5432:5432 $PG_CONTAINER
```
or with Docker:
```shell
  docker run --name pgmq -e POSTGRES_PASSWORD=postgres -p 5432:5432 $PG_CONTAINER
```
Then run the tests:
```shell
  cabal v2-run simple-test
```
It should print out some debug info, but finish without errors.

# haskell-bee-tests

Generic tests for [haskell-bee](https://github.com/garganscript/haskell-bee).

This package provides a reusable test suite for any `Broker` implementation. The tests are broker-agnostic and must be integrated into specific broker packages. See [`haskell-bee-pgmq`](https://github.com/garganscript/haskell-bee/tree/master/haskell-bee-pgmq) for an example of how to use these tests in your own broker implementation.

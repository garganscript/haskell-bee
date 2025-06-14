# Haskell-bee

A lightweight, type-safe library for implementing asynchronous job workers in Haskell.

**Key features:**
- Multiple broker backends (PostgreSQL/PGMQ, Redis, STM)
- Configurable timeout and retry strategies
- Exception-safe job processing
- Support for delayed/periodic tasks

This package contains the core broker and worker implementation of the
[haskell-bee](https://github.com/garganscript/haskell-bee) project
(simple rewrite of Celery in Haskell).

## Documentation

For complete documentation, examples, and setup instructions, see the [main project README](https://github.com/garganscript/haskell-bee/blob/master/README.md).

## Getting Started

The quickest way to get started is to check out the [demo application](https://github.com/garganscript/haskell-bee/tree/master/demo) which shows practical examples of job processing.

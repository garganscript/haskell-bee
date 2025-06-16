# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0.0] - 2025-06-14

### Added
- Initial public release of haskell-bee
- Core broker and worker implementation for asynchronous job processing
- Multiple broker backends:
  - PostgreSQL/PGMQ broker (`haskell-bee-pgmq`)
  - Redis broker (`haskell-bee-redis`) 
  - STM broker (`haskell-bee-stm`)
- Configurable timeout and retry strategies
- Configurable strategies for completed jobs
- Exception-safe job processing with proper timeout handling
- Support for delayed and periodic tasks
- Graceful worker shutdown with signal handling
- Generic test suite (`haskell-bee-tests`) for broker implementations
- Demo application showing practical usage examples
- Comprehensive documentation and setup instructions

[0.1.0.0]: https://github.com/garganscript/haskell-bee/releases/tag/v0.1.0.0
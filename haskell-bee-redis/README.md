# haskell-bee-redis

Redis broker implementation for [haskell-bee](https://github.com/garganscript/haskell-bee).

To run tests:
```shell
podman run --rm -p 6379:6379 redis
cabal v2-test haskell-bee-redis --test-show-details=streaming
```


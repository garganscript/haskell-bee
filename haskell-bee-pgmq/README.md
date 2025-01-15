# haskell-bee-pgmq

`pgmq` broker implementation for `haskell-bee`.

## Database initialization

Notice that upon broker initialization, this calls `PGMQ.initialize`
which tries very hard to create the pgmq schema for you.

If you also want to pre-create the database itself, with some given
user, you can try something like this:

```haskell
import Shelly qualified as SH

createDBIfNotExists :: Text -> Text -> IO ()
createDBIfNotExists connStr dbName = do
  -- For the \gexec trick, see:
  -- https://stackoverflow.com/questions/18389124/simulate-create-database-if-not-exists-for-postgresql
  (_res, _ec) <- SH.shelly $ SH.silently $ SH.escaping False $ do
    let sql = "\"SELECT 'CREATE DATABASE " <> dbName <> "' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '" <> dbName <> "')\\gexec\""
    result <- SH.run "echo" [sql, "|", "psql", "-d", "\"" <> connStr <> "\""]
    (result,) <$> SH.lastExitCode
    
  return ()
```

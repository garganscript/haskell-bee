{-# LANGUAGE ScopedTypeVariables #-}

module Demo.State where

import Control.Monad (void)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Database.PostgreSQL.Simple qualified as PSQL
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import Database.PostgreSQL.Simple.Types qualified as PSQL  -- Identifier
import Test.RandomStrings (randomASCII, randomString, onlyLower)


type PgConnStr = String
type TableName = String


-- | Initialize table for "map-reduce" tasks
initTable :: PgConnStr -> String -> IO TableName
initTable pgConnString prefix = do
  postfix <- randomString (onlyLower randomASCII) 20
  let tableName = prefix <> "_" <> postfix
  let tName = PSQL.Identifier $ T.pack tableName

  let connInfo = T.encodeUtf8 $ T.pack pgConnString
  conn <- PSQL.connectPostgreSQL connInfo
  _ <- PSQL.execute conn "CREATE TABLE ? (message_id INT, value INT)" (PSQL.Only tName)

  return tableName


-- | Check if "map-reduce" is finished and if it is, return the values
collectWhenFinished :: FromField a => PgConnStr -> TableName -> [Int] -> IO (Maybe [(Int, a)])
collectWhenFinished pgConnString tableName childMessageIds = do
  let connInfo = T.encodeUtf8 $ T.pack pgConnString

  conn <- PSQL.connectPostgreSQL connInfo

  let tName = PSQL.Identifier $ T.pack tableName
  rows <- PSQL.query conn "SELECT message_id, value FROM ? WHERE value IS NOT NULL" (PSQL.Only tName)
  let finishedMessageIds = fst <$> rows
  if (Set.fromList finishedMessageIds) == (Set.fromList childMessageIds) then do
    _ <- PSQL.execute conn "DROP TABLE ?" (PSQL.Only tName)
    pure $ Just rows
  else do
    pure Nothing


-- | This is run by the child job, to insert the result
insertResult :: ToField a => PgConnStr -> TableName -> Int -> a -> IO ()
insertResult pgConnString tableName childMessageId value = do
  let connInfo = T.encodeUtf8 $ T.pack pgConnString

  conn <- PSQL.connectPostgreSQL connInfo

  let tName = PSQL.Identifier $ T.pack tableName
  void $ PSQL.execute conn "INSERT INTO ? (message_id, value) VALUES (?, ?)" (tName, childMessageId, value)

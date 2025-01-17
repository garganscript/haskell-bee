module Demo.Types where

import Data.Aeson
import GHC.Generics


data Job =
    Echo String
  | Wait Int
  | Error String
  | Quit
  | Periodic { counter :: Int, delay :: Int, name :: String }
  | StarMap { tableName :: String, messageIds :: [Int] }
  | SquareMap { x :: Int, tableName :: String }
  deriving (Eq, Show, Generic)
-- | Generic to/from JSON is bad, but we don't care
instance ToJSON Job
instance FromJSON Job


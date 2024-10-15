module Demo.Types where

import Data.Aeson
import GHC.Generics


data Job =
    Echo String
  | Wait Int
  | Error String
  | Quit
  deriving (Eq, Show, Generic)
-- | Generic to/from JSON is bad, but we don't care
instance ToJSON Job
instance FromJSON Job


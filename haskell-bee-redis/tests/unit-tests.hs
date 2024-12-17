{-# OPTIONS_GHC -Wno-orphans -Wno-missing-signatures #-}

module Main where

import Async.Worker.Broker.Redis qualified as R
import Data.Aeson qualified as Aeson
import Test.Tasty
import Test.Tasty.QuickCheck as QC
    

main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [propertyTests]



propertyTests = testGroup "Property tests" [aesonPropTests]
    
aesonPropTests = testGroup "Aeson (de-)serialization property tests" $
 [ aesonPropRedisTests ]


instance QC.Arbitrary a => QC.Arbitrary (R.RedisWithMsgId a) where
  arbitrary = do
    rmidId <- arbitrary
    rmida <- arbitrary
    return $ R.RedisWithMsgId { rmida, rmidId }

aesonPropRedisTests = testGroup "Aeson RedisWithMsgId (de-)serialization tests" $
  [ QC.testProperty "Aeson.decode . Aeson.encode == id" $
     \j ->
       Aeson.decode (Aeson.encode (j :: R.RedisWithMsgId String)) == Just j
  ]

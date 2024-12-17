{-# OPTIONS_GHC -Wno-orphans -Wno-missing-signatures #-}

module Main where

import Async.Worker.Broker.STM qualified as STMB
import Data.Aeson qualified as Aeson
import Data.UnixTime
import Test.Tasty
import Test.Tasty.QuickCheck as QC
    

main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [propertyTests]



propertyTests = testGroup "Property tests" [aesonPropTests]
    
aesonPropTests = testGroup "Aeson (de-)serialization property tests" $
 [ aesonPropSTMBTests ]


instance QC.Arbitrary a => QC.Arbitrary (STMB.STMWithMsgId a) where
  arbitrary = do
    stmidId <- arbitrary
    stmida <- arbitrary
    utSeconds <- arbitrary
    utMicroSeconds <- arbitrary
    let stmidInvisibleUntil = UnixTime { utSeconds, utMicroSeconds }
    return $ STMB.STMWithMsgId { stmida, stmidId, stmidInvisibleUntil }

aesonPropSTMBTests = testGroup "Aeson STMWithMsgId (de-)serialization tests" $
  [ QC.testProperty "Aeson.decode . Aeson.encode == id" $
     \j ->
       Aeson.decode (Aeson.encode (j :: STMB.STMWithMsgId String)) == Just j
  ]

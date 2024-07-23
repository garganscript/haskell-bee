{-# OPTIONS_GHC -Wno-orphans -Wno-missing-signatures #-}

module Main where

import Async.Worker.Broker.Redis qualified as R
import Async.Worker.Types qualified as WT
import Data.Aeson qualified as Aeson
import Test.Tasty
import Test.Tasty.QuickCheck as QC
    

main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [propertyTests, unitTests]



propertyTests = testGroup "Property tests" [aesonPropTests]
    
aesonPropTests = testGroup "Aeson (de-)serialization property tests" $
 [ aesonPropJobMetadataTests
 , aesonPropJobTests
 , aesonPropRedisTests ]

instance QC.Arbitrary WT.ArchiveStrategy where
  arbitrary = QC.elements [ WT.ASDelete, WT.ASArchive ]
instance QC.Arbitrary WT.ErrorStrategy where 
  arbitrary = do
    n <- arbitrary
    QC.elements [ WT.ESDelete, WT.ESArchive, WT.ESRepeatNElseArchive n ]
instance QC.Arbitrary WT.TimeoutStrategy where 
  arbitrary = do
    n <- arbitrary
    m <- arbitrary
    QC.elements [ WT.TSDelete
                , WT.TSArchive
                , WT.TSRepeat
                , WT.TSRepeatNElseArchive n
                , WT.TSRepeatNElseDelete m ]
instance QC.Arbitrary WT.JobMetadata where
  arbitrary = do
    archiveStrategy <- arbitrary
    errorStrategy <- arbitrary
    timeoutStrategy <- arbitrary
    timeout <- arbitrary
    readCount <- arbitrary
    return $ WT.JobMetadata { .. }
   
aesonPropJobMetadataTests = testGroup "Aeson WT.JobMetadata (de-)serialization tests" $
  [ QC.testProperty "Aeson.decode . Aeson.encode == id" $
      \jm ->
        Aeson.decode (Aeson.encode (jm :: WT.JobMetadata)) == Just jm
  ]

instance QC.Arbitrary a => QC.Arbitrary (WT.Job a) where
  arbitrary = WT.Job <$> arbitrary <*> arbitrary
  
aesonPropJobTests = testGroup "Aeson WT.Job (de-)serialization tests" $
  [ QC.testProperty "Aeson.decode . Aeson.encode == id" $
      \j ->
        Aeson.decode (Aeson.encode (j :: WT.Job String)) == Just j
  ]


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

    
unitTests = testGroup "Unit tests" []
  -- [ testCase "List comparison (different length)" $
  --     [1, 2, 3] `compare` [1,2] @?= GT

  -- -- the following test does not hold
  -- , testCase "List comparison (same length)" $
  --     [1, 2, 3] `compare` [1,2,2] @?= LT
  -- ]

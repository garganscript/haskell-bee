{-|
  Generic Broker tests. All brokers should satisfy them.
-}

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Integration.Broker
 ( brokerTests
 , pgmqBrokerInitParams
 , redisBrokerInitParams )
where

import Async.Worker.Broker.PGMQ qualified as PGMQ
import Async.Worker.Broker.Redis qualified as Redis
import Async.Worker.Broker.Types qualified as BT
import Control.Exception (bracket)
import Data.Aeson (ToJSON(..), FromJSON(..), withText)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Test.Hspec
import Test.Integration.Utils (getPSQLEnvConnectInfo, getRedisEnvConnectInfo, randomQueueName, waitUntil)


data TestEnv b =
  TestEnv { broker :: BT.Broker b Message
          , queue  :: BT.Queue }

testQueuePrefix :: BT.Queue
testQueuePrefix = "test_broker"


data Message =
  Message { text :: String }
  deriving (Show, Eq)
instance ToJSON Message where
  toJSON (Message { text }) = toJSON text
instance FromJSON Message where
  parseJSON = withText "Message" $ \text -> do
    pure $ Message { text = T.unpack text }


withBroker :: (BT.HasBroker b Message)
           => BT.BrokerInitParams b Message
           -> (TestEnv b -> IO ())
           -> IO ()
withBroker bInitParams = bracket (setUpBroker bInitParams) tearDownBroker
  where
    -- NOTE I need to pass 'b' again, otherwise GHC can't infer the
    -- type of 'b' (even with 'ScopedTypeVariables' turned on)
    setUpBroker :: (BT.HasBroker b Message)
                => BT.BrokerInitParams b Message -> IO (TestEnv b)
    setUpBroker bInit = do
      b <- BT.initBroker bInit

      queue <- randomQueueName testQueuePrefix
      BT.dropQueue b queue
      BT.createQueue b queue
      
      return $ TestEnv { broker = b
                       , queue }

    tearDownBroker (TestEnv { broker, queue }) = do
      BT.dropQueue broker queue
      BT.deinitBroker broker


brokerTests :: (BT.HasBroker b Message)
            => BT.BrokerInitParams b Message -> Spec
brokerTests bInitParams =
  parallel $ around (withBroker bInitParams) $ describe "Broker tests" $ do
    it "can send and receive a message" $ \(TestEnv { broker, queue }) -> do
      let msg = Message { text = "test" }
      BT.sendMessage broker queue (BT.toMessage msg)
      msg2 <- BT.readMessageWaiting broker queue
      -- putStrLn $ "[messageId] " <> show (BT.messageId msg2)
      msg `shouldBe` BT.toA (BT.getMessage msg2)

    it "can send, archive and read message from archive" $ \(TestEnv { broker, queue }) -> do
      let msg = Message { text = "test" }
      BT.sendMessage broker queue (BT.toMessage msg)
      msg2 <- BT.readMessageWaiting broker queue
      let msgId = BT.messageId msg2
      BT.archiveMessage broker queue msgId
      putStrLn $ "Reading msg " <> show msgId <> " from archive queue " <> queue
      -- It might take some time to archive a message so we wait a bit
      waitUntil (isJust <$> BT.getArchivedMessage broker queue msgId) 200
      msgArchive <- BT.getArchivedMessage broker queue msgId
      let msgIdArchive = BT.messageId <$> msgArchive
      msgIdArchive `shouldBe` Just msgId
      

pgmqBrokerInitParams :: IO (BT.BrokerInitParams PGMQ.PGMQBroker Message)
pgmqBrokerInitParams = do
  PGMQ.PGMQBrokerInitParams <$> getPSQLEnvConnectInfo

redisBrokerInitParams :: IO (BT.BrokerInitParams Redis.RedisBroker Message)
redisBrokerInitParams = do
  Redis.RedisBrokerInitParams <$> getRedisEnvConnectInfo

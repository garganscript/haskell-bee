{-|
  Generic Broker tests. All brokers should satisfy them.
-}

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Integration.Broker
 ( Message(..)
 
 , brokerTests )
where

import Async.Worker.Broker.Types qualified as BT
import Control.Exception (bracket)
import Data.Aeson (ToJSON(..), FromJSON(..), withText)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Test.Hspec
import Test.Integration.Utils (randomQueueName, waitUntil)
import Test.RandomStrings (randomASCII, randomString, onlyAlphaNum)


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


withBroker :: (BT.MessageBroker b Message)
           => BT.BrokerInitParams b Message
           -> (TestEnv b -> IO ())
           -> IO ()
withBroker bInitParams = bracket (setUpBroker bInitParams) tearDownBroker
  where
    -- NOTE I need to pass 'b' again, otherwise GHC can't infer the
    -- type of 'b' (even with 'ScopedTypeVariables' turned on)
    setUpBroker :: (BT.MessageBroker b Message)
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


brokerTests :: (BT.MessageBroker b Message)
            => BT.BrokerInitParams b Message -> Spec
brokerTests bInitParams =
  parallel $ around (withBroker bInitParams) $ describe "Broker tests" $ do
    it "can send and receive a message" $ \(TestEnv { broker, queue }) -> do
      let msg = Message { text = "test" }
      msgId <- BT.sendMessage broker queue (BT.toMessage msg)
      msg2 <- BT.readMessageWaiting broker queue
      -- putStrLn $ "[messageId] " <> show (BT.messageId msg2)
      msg `shouldBe` BT.toA (BT.getMessage msg2)
      msgId `shouldBe` BT.messageId msg2

    it "can send, archive and read message from archive" $ \(TestEnv { broker, queue }) -> do
      let msg = Message { text = "test" }
      msgId <- BT.sendMessage broker queue (BT.toMessage msg)
      msg2 <- BT.readMessageWaiting broker queue
      msgId `shouldBe` BT.messageId msg2
      BT.archiveMessage broker queue msgId
      -- It might take some time to archive a message so we wait a bit
      waitUntil (isJust <$> BT.getArchivedMessage broker queue msgId) 200
      msgArchive <- BT.getArchivedMessage broker queue msgId
      let msgIdArchive = BT.messageId <$> msgArchive
      msgIdArchive `shouldBe` Just msgId

    it "returns correct message id when sending message to broker" $ \(TestEnv { broker, queue }) -> do
      let iter = [1..20] :: [Int]  -- number of steps
      mapM_ (\_i -> do
                -- Generate random strings and make sure that the
                -- message ids we get from sendMessage match our data
                text <- randomString (onlyAlphaNum randomASCII) 20
                let msg = Message { text }
                msgId <- BT.sendMessage broker queue (BT.toMessage msg)
                bMsg <- BT.readMessageWaiting broker queue
                msg `shouldBe` BT.toA (BT.getMessage bMsg)
                msgId `shouldBe` BT.messageId bMsg
                BT.deleteMessage broker queue msgId
                ) iter

    it "preserves msgId when archiving a message" $ \(TestEnv { broker, queue }) -> do
      let iter = [1..20] :: [Int]  -- number of steps
      mapM_ (\_i -> do
                -- Generate random strings and make sure that the
                -- message ids we get from sendMessage match our data
                text <- randomString (onlyAlphaNum randomASCII) 20
                let msg = Message { text }
                msgId <- BT.sendMessage broker queue (BT.toMessage msg)
                BT.archiveMessage broker queue msgId
                msgArchive <- BT.getArchivedMessage broker queue msgId
                Just msg `shouldBe` (BT.toA . BT.getMessage <$> msgArchive)
                ) iter

    it "returns the same size of pending messages as 'getQueueSize'" $ \(TestEnv { broker, queue }) -> do
      let numSteps = 20 :: Int
      let iter = [1..numSteps] :: [Int]  -- number of steps
      mapM_ (\i -> do
                -- Generate random strings and make sure that the
                -- message ids we get from sendMessage match our data
                text <- randomString (onlyAlphaNum randomASCII) 20
                let msg = Message { text }
                msgId <- BT.sendMessage broker queue (BT.toMessage msg)
                qs <- BT.getQueueSize broker queue
                qs `shouldBe` i
                msgIds <- BT.listPendingMessageIds broker queue
                length msgIds `shouldBe` qs
                msgIds `shouldSatisfy` (elem msgId)
                ) iter

      msgIds <- BT.listPendingMessageIds broker queue
      let timeoutS = 10  -- some large enough value

      -- after message timeout is set, it shouldn't be counted
      mapM_ (\msgId -> do
                BT.setMessageTimeout broker queue msgId timeoutS
                msgIds' <- BT.listPendingMessageIds broker queue
                msgIds' `shouldSatisfy` (not . elem msgId)
                ) msgIds

      -- queue should be "empty" since all messages are timed out
      qs <- BT.getQueueSize broker queue
      qs `shouldBe` 0

    it "can get message by it's id (from queue)" $ \(TestEnv { broker, queue }) -> do
      text <- randomString (onlyAlphaNum randomASCII) 20
      let msg = Message { text }
      msgId <- BT.sendMessage broker queue (BT.toMessage msg)
      mMsg <- BT.getMessageById broker queue msgId
      (BT.toA . BT.getMessage <$> mMsg) `shouldBe` (Just msg)

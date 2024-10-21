{-|
Module      : Async.Worker.Broker.STM
Description : Simple, STM-based broker, mostly used for tests
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX

-}


{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
    
module Async.Worker.Broker.STM
  ( STMBroker
  , BrokerInitParams(..)
  , STMWithMsgId(..) )
where

import Async.Worker.Broker.Types (MessageBroker(..), Queue, _TimeoutS)
import Control.Concurrent (threadDelay)
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TVar
import Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.=), withObject, object, withScientific)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.UnixTime
import Safe (headMay)


data STMBroker

instance (Show a) => MessageBroker STMBroker a where
  data Broker STMBroker a =
    STMBroker' {
        stmMap :: TVar (Map.Map Queue (Map.Map Int (STMWithMsgId a)))
      , archiveMap :: TVar (Map.Map Queue (Map.Map Int (STMWithMsgId a)))
      , counter :: TVar Int  -- used to issue new ids
      }
  data BrokerMessage STMBroker a =
    STMBM (STMWithMsgId a)
    deriving (Show)
  data Message STMBroker a = STMM a
  data MessageId STMBroker = STMMid Int
    deriving (Eq, Show, Ord)
  data BrokerInitParams STMBroker a =
    STMBrokerInitParams { archiveMap :: TVar (Map.Map Queue (Map.Map Int (STMWithMsgId a)))
                        , stmMap :: TVar (Map.Map Queue (Map.Map Int (STMWithMsgId a))) }

  messageId (STMBM (STMWithMsgId { stmidId })) = STMMid stmidId
  getMessage (STMBM (STMWithMsgId { stmida })) = STMM stmida
  toMessage message = STMM message
  toA (STMM message) = message
  initBroker (STMBrokerInitParams { .. }) = do
    counter <- newTVarIO 0
    pure $ STMBroker' { counter, .. }
  deinitBroker (STMBroker' { }) = pure ()
  
  createQueue (STMBroker' { stmMap }) queue = do
    atomically $ modifyTVar stmMap (Map.alter f queue)
    where
      f Nothing   = Just Map.empty
      f (Just qs) = Just qs

  dropQueue (STMBroker' { stmMap }) queue = do
    atomically $ modifyTVar stmMap (Map.alter (const Nothing) queue)
    

  readMessageWaiting = popMessageWaiting
  
  popMessageWaiting (STMBroker' { stmMap }) queue = loop
    where
      loop = do
        ut <- getUnixTime
        mMsg <- atomically $ do
          map' <- readTVar stmMap
          case Map.lookup queue map' of
            Nothing -> pure Nothing
            Just qm -> do
              let qm' = Map.filter (\s -> stmidInvisibleUntil s <= ut) qm
              case snd <$> (headMay $ Map.toList qm') of
                Nothing -> pure Nothing
                Just msg' -> do
                  -- modifyTVar stmMap $ Map.insert queue (Map.insert (stmidId msg') (msg' { stmidIsAvailable = False}) qm)
                  pure $ Just msg'
        case mMsg of
          Just msg -> pure $ STMBM msg
          Nothing -> do
            threadDelay 10_000
            loop

  setMessageTimeout (STMBroker' { stmMap }) queue (STMMid msgId) timeoutS = do
    atomically $ do
      let dt = secondsToUnixDiffTime $ _TimeoutS timeoutS
      let f s = Just $ s { stmidInvisibleUntil = addUnixDiffTime (stmidInvisibleUntil s) dt }
      modifyTVar stmMap $ Map.update (\qm -> Just $ Map.update f msgId qm) queue
    
  -- setMessageTimeout (STMBroker' { stmMap }) queue msgId timeoutS = do
  --   ut <- getUnixTime
  --   atomically $ do
  --     map' <- readTVar stmMap
  --     case Map.lookup queue map' of
  --       Nothing -> undefined
  --       Just qs -> do
  --         case filter (\(STMWithMsgId { stmidId }) -> stmidId == msgId) qs of
  --           Nothing -> undefined
  --           Just q -> do

  sendMessage (STMBroker' { stmMap, counter }) queue (STMM message) = do
    id' <- atomically $ do
      modifyTVar counter (+1)
      readTVar counter
    let msgId = STMMid id'
    ut <- getUnixTime
    let m = STMWithMsgId { stmidId = id', stmida = message, stmidInvisibleUntil = ut }
    let f x = case x of
          Nothing -> Just $ Map.singleton id' m
          Just qm -> Just $ Map.insert id' m qm
    atomically $ do
      modifyTVar stmMap (Map.alter f queue)
      
    return msgId

  deleteMessage (STMBroker' { stmMap }) queue (STMMid msgId) = do
    atomically $ do
      modifyTVar stmMap $ Map.adjust (Map.delete msgId) queue
          -- modifyTVar stmMap $ Map.insert queue (filter (\(STMWithMsgId { stmidId }) -> msgId /= stmidId) qs)

  archiveMessage (STMBroker' { archiveMap, stmMap }) queue (STMMid msgId) = do
    atomically $ do
      map' <- readTVar stmMap
      case Map.lookup queue map' of
        Nothing -> pure ()
        Just qm -> do
          let el' = Map.lookup msgId qm
          -- let el' = headMay $ filter (\(STMWithMsgId { stmidId }) -> msgId == stmidId) qs
          modifyTVar stmMap $ Map.adjust (Map.delete msgId) queue
          -- modifyTVar stmMap $ Map.insert queue (filter (\(STMWithMsgId { stmidId }) -> msgId /= stmidId) qs)
          let f = case el' of
                Nothing -> id
                Just el'' -> \am -> Just (Map.insert msgId el'' $ fromMaybe Map.empty am)
          modifyTVar archiveMap $ Map.alter f queue

  getQueueSize (STMBroker' { stmMap }) queue = do
    um <- getUnixTime
    atomically $ do
      map' <- readTVar stmMap
      pure $ length $ Map.filter (\s -> stmidInvisibleUntil s <= um) $ fromMaybe Map.empty $ Map.lookup queue map'

  getArchivedMessage (STMBroker' { archiveMap }) queue (STMMid msgId) = do
    -- m' <- readTVarIO archiveMap
    -- putStrLn $ "[getArchivedMessage] m': " <> show m'
    atomically $ do
      map' <- readTVar archiveMap
      case Map.lookup queue map' of
        Nothing -> pure Nothing
        Just qm ->
          pure $ STMBM <$> (Map.lookup msgId qm)


-- | Helper datatype to store message with a unique id.
-- We fetch the id by using 'INCR'
-- https://redis.io/docs/latest/commands/incr/
data STMWithMsgId a =
  STMWithMsgId { stmida  :: a
               , stmidInvisibleUntil :: UnixTime
               , stmidId :: Int }
  deriving (Show, Eq)
instance FromJSON a => FromJSON (STMWithMsgId a) where
  parseJSON = withObject "STMWithMsgId" $ \o -> do
    stmida <- o .: "stmida"
    -- timeout handling
    stmidInvisibleUntilSec <- o .: "stmidInvisibleUntilSec"
    stmidInvisibleUntilMs <- o .: "stmidInvisibleUntilMs"
    let stmidInvisibleUntil = UnixTime { utSeconds = stmidInvisibleUntilSec
                                       , utMicroSeconds = stmidInvisibleUntilMs }
    stmidId <- o .: "stmidId"
    return $ STMWithMsgId { stmida, stmidInvisibleUntil, stmidId }
instance ToJSON a => ToJSON (STMWithMsgId a) where
  toJSON (STMWithMsgId { .. }) = toJSON $ object [
      "stmida" .= stmida
    , "stmidInvisibleUntilSec" .= utSeconds stmidInvisibleUntil
    , "stmidInvisibleUntilMs" .= utMicroSeconds stmidInvisibleUntil
    , "stmidId" .= stmidId
    ]



instance ToJSON (MessageId STMBroker) where
  toJSON (STMMid i) = toJSON i
instance FromJSON (MessageId STMBroker) where
  parseJSON = withScientific "STMMid" $ \n ->
    case floatingOrInteger n of
      Right i -> pure $ STMMid i
      Left (f :: Double) -> fail $ "Integer expected: " <> show f

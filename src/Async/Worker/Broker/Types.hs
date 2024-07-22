{-|
Module      : Async.Worker.Broker.Types
Description : Typeclass for the underlying broker that powers the worker
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX
-}


{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
    
module Async.Worker.Broker.Types
  ( Queue
  -- , HasMessageId(..)
  , HasBroker(..)
  , SerializableMessage
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Kind (Type)
import Data.Typeable (Typeable)


type Queue = String


{-| A message in the queue system must have some properties. In
  particular, it must have some sort of 'id'.
-}
-- class (Eq msgId, Show msgId, Typeable msgId) => HasMessageId msg msgId where
--   messageId :: msg -> msgId
  
-- class HasMessageId m where
--   data family Message m :: Type
--   type family MessageId m :: Type
  
--   messageId :: Message m -> MessageId m


{- NOTE There are 3 types of messages here:
 - 'a' the underlying, user-defined message
 - 'Job a' worker definition, containing message metadata
 - 'BrokerMessage message m', i.e. for PGMQ, it returns things like:
   msgId, readCt, enqueuedAt, vt

 - 'a' is read-write
 - 'Job a' is read-write
 - 'BrokerMessage' is read-only, i.e. we can't save it to broker and
   it doesn't make sense to construct it on Haskell side. Instead, we
   save 'Job a' and get 'BrokerMessage' when reading. In this sense,
   read and send are not symmetrical (similarly, Opaleye has Read and
   Write tables).
-}

-- | So this is the broker message that contains our message inside
-- class BrokerMessage brokerMessage message where
--   getMessage :: brokerMessage -> message


type SerializableMessage a = ( FromJSON a
                             , ToJSON a
                             -- NOTE This shouldn't be necessary
                             , Typeable a )
           
{-|
  This is an interface for basic broker functionality.
-}
-- class Broker broker brokerMessage message msgId | brokerMessage -> message, brokerMessage -> msgId where

class (
        Eq (MessageId b)
      , Show (MessageId b)
      , Show (BrokerMessage b a)
      ) => HasBroker b a where
  -- | Data representing the broker
  data family Broker b a :: Type
  -- | Data represenging message that is returned by broker
  data family BrokerMessage b a :: Type
  -- | Data that we serialize into broker
  data family Message b a :: Type
  -- | How to get the message id (needed for delete/archive operations)
  data family MessageId b :: Type

  data family BrokerInitParams b a :: Type

  -- The following are just constructors and deconstructors for the
  -- 'BrokerMessage', 'Message' data types
  
  -- | Operation for getting the message id from 'BrokerMessage'
  -- messageId :: (Eq (MessageId b), Show (MessageId b)) => BrokerMessage b a -> MessageId b
  messageId :: BrokerMessage b a -> MessageId b
  
  -- | 'BrokerMessage' contains 'Message' inside, this is a
  -- deconstructor for 'BrokerMessage'
  getMessage :: BrokerMessage b a -> Message b a

  -- | Convert 'a' to 'Message b a'
  toMessage :: a -> Message b a
  -- | Convert 'Message b a' to 'a'
  toA :: Message b a -> a

  
  -- | Initialize broker
  initBroker :: BrokerInitParams b a -> IO (Broker b a)
  -- | Deconstruct broker (e.g. close DB connection)
  deinitBroker :: Broker b a -> IO ()

  
  {-| Create new queue with given name. Optionally any other
    initializations can be added here. -}
  createQueue :: Broker b a -> Queue -> IO ()

  {-| Drop queue -}
  dropQueue :: Broker b a -> Queue -> IO ()

  {-| Read message, waiting for it if not present -}
  -- readMessageWaiting :: SerializableMessage a => Broker b a -> Queue -> IO (BrokerMessage b a)
  readMessageWaiting :: Broker b a -> Queue -> IO (BrokerMessage b a)

  {-| Send message -}
  -- sendMessage :: SerializableMessage a => Broker b a -> Queue -> Message b a -> IO ()
  sendMessage :: Broker b a -> Queue -> Message b a -> IO ()

  {-| Delete message -}
  deleteMessage :: Broker b a -> Queue -> MessageId b -> IO ()

  {-| Archive message -}
  archiveMessage :: Broker b a -> Queue -> MessageId b -> IO ()

  {-| Queue size -}
  getQueueSize :: Broker b a -> Queue -> IO Int

{-|
Module      : Async.Worker.Broker.Types
Description : Typeclass for the underlying broker that powers the worker
Copyright   : (c) Gargantext, 2024-Present
License     : AGPL
Maintainer  : gargantext@iscpif.fr
Stability   : experimental
Portability : POSIX

Broker typeclass definition.
-}


{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
    
module Async.Worker.Broker.Types
  ( Queue
  -- * Main broker typeclass
  -- $broker
  , HasBroker(..)
  , SerializableMessage
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Kind (Type)
import Data.Typeable (Typeable)


type Queue = String


{- $broker
/NOTE/ There are 3 types of messages here:

 * 'a' the underlying, user-defined message
 * 'Async.Worker.Types.Job' 'a' worker definition, containing message metadata
 * 'BrokerMessage' 'message' 'm', i.e. for 'PGMQ', it returns things
   like: 'Database.Broker.PGMQ.Simple.msgId',
   'Database.Broker.PGMQ.Simple.readCt',
   'Database.Broker.PGMQ.Simple.enqueuedAt',
   'Database.Broker.PGMQ.Simple.vt'

Also:

 * 'a' is read-write
 * 'Async.Worker.Types.Job' 'a' is read-write
 * 'BrokerMessage' is read-only, i.e. we can't save it to broker and
   it doesn't make sense to construct it on Haskell side. Instead, we
   save 'Job' 'a' and get 'BrokerMessage' when reading. In this sense,
   read and send are not symmetrical (similarly, Opaleye has Read and
   Write tables).
-}

-- | We want to assert some way to serialize a message. JSON is
-- assumed here. This isn't strictly broker-related but nevertheless
-- is useful.
type SerializableMessage a = ( FromJSON a
                             , ToJSON a
                             -- NOTE This shouldn't be necessary
                             , Typeable a )
           
{-|
  This is an interface for basic broker functionality.
-}
class (
        Eq (MessageId b)
      , Show (MessageId b)
      , Show (BrokerMessage b a)
      ) => HasBroker b a where
  -- | Data representing the broker
  data family Broker b a :: Type
  -- | Data represenging message that is returned by broker. You're
  -- not supposed to construct this type yourself (in similar spirit,
  -- Opaleye uses 'selectTable'
  -- https://hackage.haskell.org/package/opaleye-0.10.3.1/docs/Opaleye-Table.html#v:selectTable)
  data family BrokerMessage b a :: Type
  -- | Data that we serialize into broker (worker will wrap this into
  -- 'Async.Worker.Types.Job' 'a')
  data family Message b a :: Type
  -- | The message id type (needed for delete/archive operations)
  data family MessageId b :: Type

  -- | All the parameters needed for broker intialization
  data family BrokerInitParams b a :: Type

  -- The following are just constructors and deconstructors for the
  -- 'BrokerMessage', 'Message' data types
  
  -- | Operation for getting the 'MessageId' from 'BrokerMessage'
  messageId :: BrokerMessage b a -> MessageId b
  
  -- | 'BrokerMessage' contains 'Message' inside, this is a
  -- deconstructor for 'BrokerMessage'
  getMessage :: BrokerMessage b a -> Message b a

  -- | Convert 'a' to 'Message' 'b' 'a'
  toMessage :: a -> Message b a
  -- | Convert 'Message' 'b' 'a' to 'a'
  toA :: Message b a -> a

  
  -- | Initialize broker with given 'BrokerInitParams'.
  initBroker :: BrokerInitParams b a -> IO (Broker b a)
  -- | Deconstruct broker (e.g. close DB connection)
  deinitBroker :: Broker b a -> IO ()

  
  {-| Create new queue with given name. Optionally any other
    initializations can be added here. -}
  createQueue :: Broker b a -> Queue -> IO ()

  {-| Drop queue -}
  dropQueue :: Broker b a -> Queue -> IO ()

  {-| Read message, waiting for it if not present -}
  readMessageWaiting :: Broker b a -> Queue -> IO (BrokerMessage b a)

  {-| Send message -}
  sendMessage :: Broker b a -> Queue -> Message b a -> IO ()

  {-| Delete message -}
  deleteMessage :: Broker b a -> Queue -> MessageId b -> IO ()

  {-| Archive message -}
  archiveMessage :: Broker b a -> Queue -> MessageId b -> IO ()

  {-| Queue size -}
  getQueueSize :: Broker b a -> Queue -> IO Int

  {-| Read archived message -}
  getArchivedMessage :: Broker b a -> Queue -> MessageId b -> IO (Maybe (BrokerMessage b a))

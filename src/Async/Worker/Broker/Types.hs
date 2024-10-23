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


{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
    
module Async.Worker.Broker.Types
  ( Queue(..)
  , renderQueue
  , TimeoutS(..)
  -- * Main broker typeclass
  -- $broker
  , MessageBroker(..)
  , SerializableMessage
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Kind (Type)
import Data.String (IsString)
import Data.Text qualified as T
import Data.Typeable (Typeable)


newtype Queue = Queue { _Queue :: T.Text }
  deriving stock (Eq, Ord)
  deriving newtype (Semigroup, IsString, Show)

newtype TimeoutS = TimeoutS { _TimeoutS :: Int  } -- timeout for a message, in seconds
  deriving stock (Eq, Ord)
  deriving newtype (Num, Show)

renderQueue :: Queue -> String
renderQueue = T.unpack . _Queue

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
      , Ord (MessageId b)
      , ToJSON (MessageId b)
      , FromJSON (MessageId b)
      , Show (BrokerMessage b a)
      ) => MessageBroker b a where
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

  {-| Read message from queue, waiting for it if not present (this leaves
  the message in queue, you need to use 'setMessageTimeout' to prevent
  other workers from seeing this message). -}
  readMessageWaiting :: Broker b a -> Queue -> IO (BrokerMessage b a)

  {-| Pop message from queue, waiting for it if not present -}
  popMessageWaiting :: Broker b a -> Queue -> IO (BrokerMessage b a)

  {-| We sometimes need a way to tell the broker that a message shouldn't
  be visible for given amount of time (e.g. 'visibility timeout'
  setting in PGMQ). The broker operates only on 'a' level and isn't
  aware of 'Job' with its 'JobMetadata'. Hence, it's the worker's
  responsibility to properly set timeout after message is read. -}
  setMessageTimeout :: Broker b a -> Queue -> MessageId b -> TimeoutS -> IO ()

  {-| Send message -}
  sendMessage :: Broker b a -> Queue -> Message b a -> IO (MessageId b)

  {-| Delete message -}
  deleteMessage :: Broker b a -> Queue -> MessageId b -> IO ()

  {-| Archive message -}
  archiveMessage :: Broker b a -> Queue -> MessageId b -> IO ()

  {-| Queue size -}
  getQueueSize :: Broker b a -> Queue -> IO Int

  {-| Read archived message -}
  getArchivedMessage :: Broker b a -> Queue -> MessageId b -> IO (Maybe (BrokerMessage b a))

  {-| List all pending message ids -}
  listPendingMessageIds :: Broker b a -> Queue -> IO [MessageId b]

  {-| Get message by it's id -}
  getMessageById :: Broker b a -> Queue -> MessageId b -> IO (Maybe (BrokerMessage b a))

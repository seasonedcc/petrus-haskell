-- | Helpers for the Instance-door specs (ingress, registrations, lifecycle
-- scopes, timers, resume): the reference's one-line spellings of building an
-- instance, delivering an event, and reading its History, plus assertions on
-- refused doors.
module Petrus.Impetus.DoorSupport
  ( mkInstance
  , symbols
  , pureHandler
  , accept
  , deliver
  , deliverAt
  , historyRecords
  , storeOf
  , cloneStore
  , refusedWith
  , handlerRaisedWith
  , expectAccepted
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records (Record)
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (expectRight)
import Test.Hspec

-- | @Instance(net, ...)@ for a construction the spec expects to succeed.
mkInstance :: HasCallStack => Net -> InstanceConfig -> IO Instance
mkInstance net cfg = newInstance net cfg >>= expectRight

-- | Implementations keyed by local symbol (the reference's
-- @handlers={"name": ...}@ / @guards={...}@).
symbols :: [(Text, a)] -> Map ImplementationRef a
symbols xs = Map.fromList [(Symbol k, v) | (k, v) <- xs]

-- | A pure handler bound under a symbol.
pureHandler :: Text -> Handler -> Map ImplementationRef BoundHandler
pureHandler name h = symbols [(name, PureHandler h)]

-- | The answer is an 'AcceptedDelivery' (the reference's
-- @assert isinstance(accepted, AcceptedDelivery)@).
expectAccepted :: HasCallStack => DeliveryAnswer AcceptedDelivery -> IO AcceptedDelivery
expectAccepted = \case
  DeliveryAccepted a -> pure a
  other -> expectationFailure ("expected an AcceptedDelivery, got " <> show other) >> error "unreachable"

-- | @instance.accept_delivery(source, tokens, at=at, identity=identity, scope=scope)@
-- expected to accept.
accept :: HasCallStack => Instance -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> Maybe Instant -> IO AcceptedDelivery
accept inst source tokens identity scope at =
  acceptDelivery inst source tokens identity scope at >>= expectRight >>= expectAccepted

-- | Accept an unscoped delivery and complete it, both with no instant.
deliver :: HasCallStack => Instance -> NetPath -> [Token] -> Text -> IO FiringOutcome
deliver inst source tokens identity = deliverAt inst source tokens identity Nothing Nothing

-- | Accept and complete at one instant (the reference's paired
-- @accept_delivery(..., at=t)@ / @complete_delivery(accepted, at=t)@).
deliverAt :: HasCallStack => Instance -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> Maybe Instant -> IO FiringOutcome
deliverAt inst source tokens identity scope at = do
  accepted <- accept inst source tokens identity scope at
  completeDelivery inst accepted at >>= expectRight

-- | @instance.history.records@.
historyRecords :: Instance -> IO [Record]
historyRecords inst = Store.records (instanceHistory inst)

-- | A fresh in-memory store holding exactly these records
-- (@history = InMemoryHistoryStore(); history.extend(records)@).
storeOf :: [Record] -> IO HistoryStore
storeOf rs = do
  store <- inMemoryHistoryStore
  store.extend rs
  pure store

-- | A copy of an instance's History in a fresh in-memory store.
cloneStore :: Instance -> IO HistoryStore
cloneStore inst = historyRecords inst >>= storeOf

-- | The door refused (the reference's @ValueError@) with exactly this message.
refusedWith :: HasCallStack => Either InstanceError a -> Text -> Expectation
refusedWith result message = case result of
  Left (Refused actual) -> actual `shouldBe` message
  Left other -> expectationFailure ("expected Refused " <> show message <> ", got " <> show other)
  Right _ -> expectationFailure ("expected Refused " <> show message <> ", got a success")

-- | A handler (or projection) raised with exactly this text.
handlerRaisedWith :: HasCallStack => Either InstanceError a -> Text -> Expectation
handlerRaisedWith result message = case result of
  Left (HandlerRaised actual) -> actual `shouldBe` message
  Left other -> expectationFailure ("expected HandlerRaised " <> show message <> ", got " <> show other)
  Right _ -> expectationFailure ("expected HandlerRaised " <> show message <> ", got a success")

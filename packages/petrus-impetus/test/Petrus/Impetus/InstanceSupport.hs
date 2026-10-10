-- | Shared helpers for the Instance specs: construction shorthands and
-- assertions on refused doors, so each spec reads close to its upstream
-- test. 'InstanceError' has no 'Eq' (a store refusal carries an exception),
-- so refusals are compared by constructor and message text.
module Petrus.Impetus.InstanceSupport
  ( seededWith
  , seeded
  , beginOne
  , historyOf
  , historyLength
  , expectRefused
  , shouldRefuse
  , shouldRefuseContaining
  , expectHandlerRaised
  , symbolHandlers
  , symbolGuards
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Binding (BoundHandler (..), Handler)
import Petrus.Impetus.History.Records (Record)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet (Guard, Marking, Net)
import Petrus.Impetus.TestSupport (expectRight)
import Test.Hspec

-- | @Instance(net, marking, **config)@ for a construction the spec expects
-- to succeed.
seededWith :: HasCallStack => Net -> InstanceConfig -> IO Instance
seededWith net cfg = newInstance net cfg >>= expectRight

-- | @Instance(net, marking)@.
seeded :: HasCallStack => Net -> Marking -> IO Instance
seeded net m = seededWith net defaultInstanceConfig {initialMarking = m}

-- | Begin the head candidate — what the conservative scheduler would choose.
beginOne :: HasCallStack => Instance -> IO FiringOccurrence
beginOne inst =
  candidates inst >>= \case
    b : _ -> begin inst b Nothing >>= expectRight
    [] -> expectationFailure "expected an enabled candidate" >> error "unreachable"

-- | @instance.history.records@.
historyOf :: Instance -> IO [Record]
historyOf inst = Store.records (instanceHistory inst)

-- | @len(instance.history)@.
historyLength :: Instance -> IO Int
historyLength inst = Store.size (instanceHistory inst)

-- | The message of a door the reference refuses with @ValueError@.
expectRefused :: HasCallStack => Either InstanceError a -> IO Text
expectRefused = \case
  Left (Refused message) -> pure message
  Left other -> expectationFailure ("expected Refused, got " <> show other) >> error "unreachable"
  Right _ -> expectationFailure "expected Refused, got Right" >> error "unreachable"

-- | The door is refused (@ValueError@) with exactly this message.
shouldRefuse :: HasCallStack => Either InstanceError a -> Text -> Expectation
shouldRefuse result message = expectRefused result >>= (`shouldBe` message)

-- | The door is refused with a message containing the fragment (the
-- reference's @pytest.raises(ValueError, match=...)@ where the full text
-- embeds a minted value).
shouldRefuseContaining :: HasCallStack => Either InstanceError a -> Text -> Expectation
shouldRefuseContaining result fragment = do
  message <- expectRefused result
  if fragment `T.isInfixOf` message
    then pure ()
    else expectationFailure ("expected a refusal containing " <> show fragment <> ", got " <> show message)

-- | The text of a handler that raised.
expectHandlerRaised :: HasCallStack => Either InstanceError a -> IO Text
expectHandlerRaised = \case
  Left (HandlerRaised message) -> pure message
  Left other -> expectationFailure ("expected HandlerRaised, got " <> show other) >> error "unreachable"
  Right _ -> expectationFailure "expected HandlerRaised, got Right" >> error "unreachable"

-- | @handlers={symbol: callable}@.
symbolHandlers :: [(Text, Handler)] -> Map.Map ImplementationRef BoundHandler
symbolHandlers xs = Map.fromList [(Symbol s, PureHandler h) | (s, h) <- xs]

-- | @guards={symbol: callable}@.
symbolGuards :: [(Text, Guard)] -> Map.Map ImplementationRef Guard
symbolGuards xs = Map.fromList [(Symbol s, g) | (s, g) <- xs]

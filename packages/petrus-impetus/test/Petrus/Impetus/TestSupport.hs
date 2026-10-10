-- | Shared helpers for the kernel's specs: literal-friendly constructors and
-- assertion shorthands that keep each spec close to its upstream test.
module Petrus.Impetus.TestSupport
  ( np
  , mustNet
  , netOf
  , expectRight
  , expectLeft
  , shouldFailWith
  , shouldFailContaining
  , tok
  , tokD
  , filtersBySymbol
  , guardsBySymbol
  , impls
  , obj
  , field
  , numberField
  , enabledTransitions
  , Fired (..)
  , fireHead
  , stepNet
  , runNet
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Test.Hspec
import Data.List (nub)

-- | A literal path.
np :: Text -> NetPath
np = either (error . T.unpack) id . netPath

-- | Build a net that the spec expects to be valid.
mustNet :: HasCallStack => NetSpec -> Net
mustNet spec = case mkNet spec of
  Right net -> net
  Left err -> error ("expected a valid net: " <> T.unpack err)

-- | @Net(places, transitions, arcs)@ for a valid net.
netOf :: HasCallStack => [Place] -> [Transition] -> [Arc] -> Net
netOf ps ts as = mustNet (netSpec ps ts as)

expectRight :: (HasCallStack, Show e) => Either e a -> IO a
expectRight = \case
  Right a -> pure a
  Left e -> expectationFailure ("expected Right, got Left " <> show e) >> error "unreachable"

expectLeft :: (HasCallStack, Show a) => Either e a -> IO e
expectLeft = \case
  Left e -> pure e
  Right a -> expectationFailure ("expected Left, got Right " <> show a) >> error "unreachable"

-- | The computation fails with exactly this message.
shouldFailWith :: (HasCallStack, Show a) => Either Text a -> Text -> Expectation
shouldFailWith result message = expectLeft result >>= (`shouldBe` message)

-- | The computation fails with a message containing the fragment (the
-- reference's @pytest.raises(match=...)@).
shouldFailContaining :: (HasCallStack, Show a) => Either Text a -> Text -> Expectation
shouldFailContaining result fragment = do
  message <- expectLeft result
  if fragment `T.isInfixOf` message
    then pure ()
    else expectationFailure ("expected a failure containing " <> show fragment <> ", got " <> show message)

-- | @Token("Color")@: a colored token with no data.
tok :: Text -> Token
tok c = Token (Just c) Null

-- | @Token("Color", data)@.
tokD :: Text -> Json -> Token
tokD c = Token (Just c)

filtersBySymbol :: [(Text, Filter)] -> Map.Map ImplementationKey Filter
filtersBySymbol xs = Map.fromList [(BySymbol k, f) | (k, f) <- xs]

guardsBySymbol :: [(Text, Guard)] -> Map.Map ImplementationKey Guard
guardsBySymbol xs = Map.fromList [(BySymbol k, g) | (k, g) <- xs]

-- | Implementations from symbol-keyed filters and guards.
impls :: [(Text, Filter)] -> [(Text, Guard)] -> Implementations
impls fs gs = Implementations (filtersBySymbol fs) (guardsBySymbol gs)

-- | A JSON object literal.
obj :: [(Text, Json)] -> Json
obj = Object

-- | Python's @token.data[key]@: a missing key or a non-mapping payload is an
-- evaluation error spelled the way the reference's exception reprs are.
field :: Text -> Token -> Either Text Json
field key t = case t.payload of
  Object members -> maybe (Left ("KeyError(" <> pyRepr key <> ")")) Right (lookup key members)
  Null -> Left "TypeError(\"'NoneType' object is not subscriptable\")"
  _ -> Left "TypeError('object is not subscriptable')"
  where
    pyRepr k = "'" <> k <> "'"

-- | A numeric data field (@token.data[key]@ used in arithmetic).
numberField :: Text -> Token -> Either Text Integer
numberField key t =
  field key t >>= \case
    Int n -> Right n
    other -> Left ("TypeError(" <> T.pack (show other) <> ")")

-- | The reference's @Instance.enabled_transitions()@: distinct enabled
-- transitions in candidate (stable) order.
enabledTransitions :: HasCallStack => Net -> Marking -> Implementations -> [NetPath]
enabledTransitions net marking implementations =
  case candidates net marking implementations Nothing of
    Right bindings -> nub (map (.transition) bindings)
    Left err -> error ("candidates failed: " <> show err)

-- | One conservative firing (the reference's @Instance.step()@ with the
-- default passthrough handler): the head binding begins, its forwarded
-- tokens route through the transition's output arcs, and the firing
-- completes.
data Fired = Fired
  { binding :: Binding
  , begun :: [BeginEffect]
  , produced :: [ProducedTokens]
  , after :: Marking
  }
  deriving stock (Show)

-- | Fire one given binding.
fireHead :: Net -> Marking -> Binding -> Either Text Fired
fireHead net marking b = do
  (effects, begunMarking) <- beginFiring marking b
  let projected = route (bindingTokens b) (outputs net b.transition)
      (producedEffects, completed) = completeFiring net begunMarking b.transition projected
  Right (Fired b effects producedEffects completed)

-- | Fire the first candidate, if any.
stepNet :: Net -> Implementations -> Marking -> Either Text (Maybe Fired)
stepNet net implementations marking =
  case candidates net marking implementations Nothing of
    Left err -> Left (T.pack (show err))
    Right [] -> Right Nothing
    Right (b : _) -> Just <$> fireHead net marking b

-- | Step until quiescent (bounded), returning the final marking.
runNet :: Net -> Implementations -> Marking -> Either Text Marking
runNet net implementations = go (1000 :: Int)
  where
    go 0 _ = Left "runNet: step bound exceeded"
    go n marking =
      stepNet net implementations marking >>= \case
        Nothing -> Right marking
        Just fired -> go (n - 1) fired.after

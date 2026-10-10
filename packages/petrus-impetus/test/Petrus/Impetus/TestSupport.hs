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
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Test.Hspec

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

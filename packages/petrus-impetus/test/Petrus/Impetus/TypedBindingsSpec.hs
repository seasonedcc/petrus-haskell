-- | Parity: @tests/petrus/impetus/binding/test_typed_bindings.py@ — the
-- production typed transformation and predicate binding contracts.
--
-- The reference reflects on a Python function's signature and dataclass
-- annotations. Here the same plan is an applicative of named, typed
-- parameters ('param'), each type naming its arc colour through 'Typed'
-- ("Petrus.Impetus.Binding"). The reflection-only failure modes (a missing
-- annotation, a variadic signature, a non-dataclass return annotation, a
-- guard returning a non-@bool@) are unrepresentable, so they are enforced by
-- types and listed in the parity ledger rather than tested here.
module Petrus.Impetus.TypedBindingsSpec (spec) where

import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Binding
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport (expectRight, netOf, np, obj, tokD)
import Petrus.Json (Json (..), lookupMember)
import Test.Hspec hiding (pending)

newtype Order = Order Integer
  deriving stock (Eq, Show)

newtype Config = Config Integer
  deriving stock (Eq, Show)

newtype Receipt = Receipt Integer
  deriving stock (Eq, Show)

intMember :: Text -> Json -> Either Text Integer
intMember key value = case lookupMember key value of
  Just (Int n) -> Right n
  Just other -> Left ("TypeError(" <> T.pack (show other) <> ")")
  Nothing -> Left ("KeyError('" <> key <> "')")

instance Typed Order where
  typedColor = "Order"
  toPayload (Order n) = obj [("amount", Int n)]
  fromPayload v = Order <$> intMember "amount" v

instance Typed Config where
  typedColor = "Config"
  toPayload (Config n) = obj [("fee", Int n)]
  fromPayload v = Config <$> intMember "fee" v

instance Typed Receipt where
  typedColor = "Receipt"
  toPayload (Receipt n) = obj [("total", Int n)]
  fromPayload v = Receipt <$> intMember "total" v

pending, config, apply, result :: NetPath
pending = np "pending"
config = np "config"
apply = np "apply"
result = np "result"

applyFee :: Order -> Config -> Receipt
applyFee (Order amount) (Config fee) = Receipt (amount + fee)

withinLimit :: Order -> Config -> Bool
withinLimit (Order amount) (Config fee) = amount <= fee

-- | @apply_fee(order: Order, config: Config) -> Receipt@.
applyFeeArgs :: TypedArgs Receipt
applyFeeArgs = applyFee <$> param "order" <*> param "config"

-- | @transform_net(input_weight=..., result_color=...)@.
transformNet :: Int -> Text -> Net
transformNet inputWeight resultColor =
  netOf
    [coloredPlace pending "Order", coloredPlace config "Config", coloredPlace result resultColor]
    [Transition apply (Just (HandlerSymbol "apply_fee")) [] []]
    [ Arc config apply Read 1 Nothing Nothing
    , Arc pending apply Consume inputWeight Nothing Nothing
    , arc apply result
    ]

defaultTransformNet :: Net
defaultTransformNet = transformNet 1 "Receipt"

refusedWith :: HasCallStack => Either Text a -> Text -> Expectation
refusedWith outcome message = case outcome of
  Left m -> m `shouldBe` message
  Right _ -> expectationFailure ("expected the derivation to refuse with " <> show message)

guardBinding :: Binding
guardBinding = Binding apply [(pending, [tokD "Order" (obj [("amount", Int 40)])])] [(config, [tokD "Config" (obj [("fee", Int 50)])])] []

spec :: Spec
spec = describe "typed bindings" $ do
  -- test_typed_transform_decodes_read_and_consumed_inputs_and_routes_dataclass_result
  it "a typed transform decodes read and consumed inputs and routes its result" $ do
    handler <- expectRight (deriveTypedTransform defaultTransformNet apply applyFeeArgs)
    inst <-
      newInstance
        defaultTransformNet
        defaultInstanceConfig
          { initialMarking =
              markingFromList
                [ (pending, [tokD "Order" (obj [("amount", Int 40)])])
                , (config, [tokD "Config" (obj [("fee", Int 2)])])
                ]
          , handlerImplementations = Map.fromList [(Symbol "apply_fee", PureHandler handler)]
          }
        >>= expectRight
    _ <- run inst >>= expectRight
    marking inst
      `shouldReturn` markingFromList
        [ (config, [tokD "Config" (obj [("fee", Int 2)])])
        , (result, [tokD "Receipt" (obj [("total", Int 42)])])
        ]

  -- test_typed_guard_decodes_the_same_effective_input_contract
  it "a typed guard decodes the same effective input contract" $ do
    guard' <- expectRight (deriveTypedGuard defaultTransformNet apply (withinLimit <$> param "order" <*> param "config"))
    guard' guardBinding `shouldBe` Right True

  -- test_typed_binding_reads_effective_colors_compiled_from_places
  it "a typed binding reads effective colors compiled from places" $ do
    all (isJust . (.color)) (netArcs defaultTransformNet) `shouldBe` True
    isRight (deriveTypedTransform defaultTransformNet apply applyFeeArgs) `shouldBe` True

  -- test_typed_binding_rejects_source_transitions
  it "rejects source transitions" $ do
    let source = np "source"
        net = netOf [coloredPlace result "Receipt"] [Transition source (Just (HandlerSymbol "source")) [] []] [arc source result]
    deriveTypedTransform net source applyFeeArgs
      `refusedWith` "cannot derive typed transform for source: source transitions are not supported"

  -- test_typed_binding_rejects_weighted_inputs
  it "rejects weighted inputs" $
    deriveTypedTransform (transformNet 2 "Receipt") apply applyFeeArgs
      `refusedWith` "cannot derive typed transform for apply: input arc pending has weight 2; collection parameters are not supported"

  -- test_typed_binding_rejects_same_color_input_ambiguity
  it "rejects same-color input ambiguity" $ do
    let other = np "other"
        net =
          netOf
            [coloredPlace pending "Order", coloredPlace other "Order", coloredPlace result "Receipt"]
            [Transition apply (Just (HandlerSymbol "apply_fee")) [] []]
            [arc pending apply, arc other apply, arc apply result]
    deriveTypedTransform net apply (oneOrder <$> param "order")
      `refusedWith` "cannot derive typed transform for apply: parameter 'order' (Order) requires exactly one matching input arc, found 2"

  -- test_typed_binding_rejects_unmatched_input_arcs
  it "rejects unmatched input arcs" $
    deriveTypedTransform defaultTransformNet apply (oneOrder <$> param "order")
      `refusedWith` "cannot derive typed transform for apply: input arc config matches no parameter"

  -- test_typed_transform_rejects_output_color_mismatch
  it "rejects an output color mismatch" $
    deriveTypedTransform (transformNet 1 "Other") apply applyFeeArgs
      `refusedWith` "cannot derive typed transform for apply: output arc result has color Other, expected Receipt"
  where
    oneOrder (Order amount) = Receipt amount

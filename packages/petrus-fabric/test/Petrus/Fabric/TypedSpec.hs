{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors -Wno-missing-signatures #-}

-- | The Haskell evidence for conformance checks whose refusal the port's
-- types enforce (DIVERGENCES.md, "Type-enforced refusals"). Each ill-typed
-- use is checked against the real signature: this module compiles with
-- deferred type errors, and the example passes only when evaluating the
-- use raises a 'TypeError'. Were a signature widened to accept the value,
-- the example would fail.
module Petrus.Fabric.TypedSpec (spec, argumentOf, rejectedByType) where

import Control.Exception (TypeError (..), evaluate)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Time (LocalTime (..), fromGregorian, midnight)
import Petrus.Fabric
import Petrus.Fabric.Postgres qualified as Store
import Petrus.Json (Json (..))
import Test.Hspec

-- | The value as the argument a function's signature expects there.
argumentOf :: (a -> b) -> a -> a
argumentOf _ x = x

-- | Evaluating the value raises the deferred type error.
rejectedByType :: a -> Expectation
rejectedByType value = evaluate value `shouldThrow` \(TypeError _) -> True

-- | Forces a payload completely through the canonical encoder.
encodedLength :: Json -> Int
encodedLength value = either (const (-1)) BS.length (canonicalBytes value)

-- Each ill-typed use is its own top-level binding: a deferred type error
-- fires where its evidence is bound, and here that is only when the binding
-- is forced inside 'rejectedByType'. The store uses carry no signature, so
-- only the store function's own signature can make them ill-typed.

hostValue :: Int
hostValue = encodedLength (Object [("items", Array [id])])

intKey :: Int
intKey = encodedLength (Object [(1 :: Int, Null)])

pendingTrue = argumentOf (Store.pending undefined) True

acknowledgeTrue = argumentOf (Store.acknowledge undefined "sender" "delivery") True

naiveCutoff = argumentOf (Store.pruneAccepted undefined) (LocalTime (fromGregorian 2026 1 1) midnight)

spec :: Spec
spec = describe "Type-enforced refusals (Haskell port)" $ do
  it "F-005 a lone surrogate cannot reach the model: Text replaces it with U+FFFD" $ do
    let lone = T.pack ['\xD800']
    lone `shouldBe` T.pack ['\xFFFD']
    canonicalBytes (String lone) `shouldBe` canonicalBytes (String (T.pack ['\xFFFD']))
  it "F-007 a non-JSON host value in a payload does not type-check" $
    rejectedByType hostValue
  it "F-008 a non-string payload key does not type-check" $
    rejectedByType intKey
  it "F-076 pending's limit is an Int: True does not type-check" $
    rejectedByType pendingTrue
  it "F-080 acknowledge's occurrence is an Int: True does not type-check" $
    rejectedByType acknowledgeTrue
  it "F-091 a pruning cutoff is a UTCTime: a naive LocalTime does not type-check" $
    rejectedByType naiveCutoff

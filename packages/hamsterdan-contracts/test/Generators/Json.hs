-- | The field generators the generated model generators
-- ("Generators.ReadinessV5", "Generators.Readiness") are built from, and
-- the round-trip law they are checked against.
--
-- They draw what a decoded pydantic value can hold: untyped members are
-- finite JSON (pydantic dumps a non-finite float as @null@, so a NaN never
-- survives a token), and a @dict@ member has each key once (a Python dict).
module Generators.Json
  ( genText
  , genInteger
  , genJson
  , genObject
  , genList
  , genDict
  , genPairOrEmpty
  , roundTrip
  ) where

import Data.List (nubBy)
import Data.Function (on)
import Data.Text (Text)
import Hamsterdan.Contracts.Codec (Contract, dump, validate)
import Hedgehog (Gen, Property, forAll, property, tripping)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Petrus.Json (Json (..))

-- | Any text, short.
genText :: Gen Text
genText = Gen.text (Range.linear 0 6) (Gen.frequency [(4, Gen.alphaNum), (1, Gen.unicode)])

-- | Any integer, past 64 bits too.
genInteger :: Gen Integer
genInteger = Gen.integral (Range.linearFrom 0 (-(2 ^ (70 :: Int))) (2 ^ (70 :: Int)))

-- | A finite JSON value.
genJson :: Gen Json
genJson =
  Gen.recursive
    Gen.choice
    [ pure Null
    , Bool <$> Gen.bool
    , Int <$> genInteger
    , Float <$> Gen.double (Range.linearFracFrom 0 (-1e300) 1e300)
    , String <$> genText
    ]
    [ Array <$> Gen.list (Range.linear 0 3) genJson
    , Object <$> genDict genJson
    ]

-- | A @dict[str, Any]@.
genObject :: Gen [(Text, Json)]
genObject = genDict genJson

-- | A list or tuple.
genList :: Gen a -> Gen [a]
genList = Gen.list (Range.linear 0 3)

-- | A @dict[str, T]@: each key once, in drawing order.
genDict :: Gen a -> Gen [(Text, a)]
genDict item = nubBy ((==) `on` fst) <$> Gen.list (Range.linear 0 4) ((,) <$> genText <*> item)

-- | @tuple[int, int] | tuple[()]@.
genPairOrEmpty :: Gen (Maybe (Integer, Integer))
genPairOrEmpty = Gen.maybe ((,) <$> genInteger <*> genInteger)

-- | @validate (dump x) == Right x@: dumping a model and admitting the dump
-- gives the model back. This is what makes a record update equal to the
-- reference's @validated_update@ (dump, patch, revalidate).
roundTrip :: (Contract a, Eq a, Show a) => Gen a -> Property
roundTrip gen = property $ do
  value <- forAll gen
  tripping value dump validate

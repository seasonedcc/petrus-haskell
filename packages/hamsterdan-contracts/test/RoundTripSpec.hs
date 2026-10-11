-- | The round-trip law of every generated contract (ELG-H-12):
-- @validate (dump x) == Right x@ for every value a decoded token can hold.
--
-- The V5 folds update records with record syntax where the reference calls
-- @validated_update(**changes)@ (dump, patch the members, revalidate). The
-- two agree exactly when revalidating a well-typed record gives it back,
-- which is this law.
module RoundTripSpec (spec) where

import Control.Monad (forM_)
import Generators.Readiness qualified as Readiness
import Generators.ReadinessV5 qualified as ReadinessV5
import Hedgehog (Property)
import Hedgehog qualified as H
import Test.Hspec

spec :: Spec
spec = describe "validate . dump == Right (ELG-H-12)" $ do
  describe "readiness_v5 models" $ forM_ ReadinessV5.roundTrips holds
  describe "readiness models" $ forM_ Readiness.roundTrips holds
  where
    holds :: (String, Property) -> Spec
    holds (name, law) = it name (H.check law >>= (`shouldBe` True))

-- | Webhook signatures as properties (ELG-H-12): a signature made with a
-- secret verifies its own body, with the precomputed verifier as with the
-- plain one, and never verifies another body or under another secret.
module SignatureSpec (spec) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Hamsterdan.GitHub.Webhooks (sign, verifier, verify, verifyWith)
import Hedgehog (Gen, Property, assert, forAll, property)
import Hedgehog qualified as H
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Hspec

-- | A secret without NUL: HMAC pads a short key with zeros, so a key and
-- that key with trailing NULs are the same key.
genSecret :: Gen Text
genSecret = Gen.text (Range.linear 0 80) (Gen.filter (/= '\NUL') Gen.unicode)

genBody :: Gen ByteString
genBody = Gen.bytes (Range.linear 0 512)

spec :: Spec
spec = describe "webhook signatures (properties)" $ do
  it "verifyWith (verifier s) b (sign s b) holds, as verify does" $ holds $ property $ do
    secret <- forAll genSecret
    body <- forAll genBody
    assert (verifyWith (verifier secret) body (sign secret body))
    assert (verify secret body (sign secret body))
  it "a signature never verifies another body" $ holds $ property $ do
    secret <- forAll genSecret
    body <- forAll genBody
    other <- forAll (Gen.filter (/= body) genBody)
    assert (not (verifyWith (verifier secret) other (sign secret body)))
  it "a signature never verifies under another secret" $ holds $ property $ do
    secret <- forAll genSecret
    other <- forAll (Gen.filter (/= secret) genSecret)
    body <- forAll genBody
    assert (not (verifyWith (verifier other) body (sign secret body)))
  where
    holds :: Property -> Expectation
    holds law = H.check law >>= (`shouldBe` True)

-- | Parity: @tests/petrus/impetus/petrinet/test_schema.py@.
module Petrus.Impetus.SchemaSpec (spec) where

import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Test.Hspec

spec :: Spec
spec = describe "Petrinet.Schema" $ do
  describe "NetPath" $ do
    it "splits a dotted path into segments" $ do
      netPathSegments (np "review.start") `shouldBe` ["review", "start"]
      netPathText (np "review.start") `shouldBe` "review.start"
    it "rejects an empty path" $
      netPath "" `shouldFailWith` "NetPath requires a non-empty dotted string or a NetPath, got ''"
    it "rejects empty segments" $
      netPath "a..b" `shouldFailWith` "NetPath segments must be non-empty, got 'a..b'"
    it "reprs like the reference" $
      show (np "a.b") `shouldBe` "NetPath('a.b')"

  describe "NetUri" $ do
    it "addresses arcs with and without occurrences" $ do
      netUriText (arcUri (np "a") (np "t") Nothing) `shouldBe` "arc:/a->/t"
      netUriText (arcUri (np "a.b") (np "t") (Just 2)) `shouldBe` "arc:/a/b->/t#$2"
    it "percent-encodes declaration names" $ do
      uri <- expectRight (declarationUri TransitionOwner (np "t") "guard" (Just "é ok$"))
      netUriText uri `shouldBe` "transition:/t#guard:%C3%A9%20ok$"
    it "rejects non-canonical spellings" $ do
      netUri "arc:/a->/t%2f" `shouldFailWith` "invalid canonical NetUri 'arc:/a->/t%2f'"
      netUri "http://x" `shouldFailWith` "invalid canonical NetUri 'http://x'"

  describe "Net" $ do
    it "rejects an arc between two places" $
      mkNet (netSpec [place (np "a"), place (np "b")] [] [arc (np "a") (np "b")])
        `shouldFailWith` "arc must connect a place and a transition: a -> b"
    it "resolves a place color onto untyped incident arcs" $ do
      let net = netOf [coloredPlace (np "p") "Order"] [transition (np "t")] [arc (np "p") (np "t")]
      map (.color) (netArcs net) `shouldBe` [Just "Order"]
    it "identifies source transitions" $ do
      let net = netOf [place (np "out")] [transition (np "src")] [arc (np "src") (np "out")]
      isSource net (np "src") `shouldBe` True
      sourceTransitions net `shouldBe` [np "src"]

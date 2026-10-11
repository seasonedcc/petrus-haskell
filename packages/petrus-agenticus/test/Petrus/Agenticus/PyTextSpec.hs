-- | CPython text behaviours ('decodeUtf8Replace', 'boundedText', 'pythonSplitlines')
-- against the reference's own output in @differential/workspace_corpus.json@.
module Petrus.Agenticus.PyTextSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as B
import Data.Char (digitToInt)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Internal.PyText
import Petrus.Json.Python (decodeUtf8Replace, pythonSplitlines)
import Petrus.Agenticus.TestSupport
import Petrus.Json (Json (..))
import Test.Hspec

spec :: Spec
spec = describe "differential/workspace_corpus.json (PyText)" $ do
  corpus <- runIO (loadJson "differential/workspace_corpus.json")
  it "_bounded_text matches the reference on every byte string" $ do
    let cases = arrayItems (member "bounded_text" corpus)
    (length cases > 1000) `shouldBe` True
    forM_ cases $ \entry -> do
      let hex = memberText "hex" entry
          limit = case member "limit" entry of
            Int n -> fromInteger n
            other -> error ("bad limit " <> show other)
          expected = (memberText "text" entry, member "truncated" entry == Bool True)
      (hex, limit, boundedText (unhex hex) limit) `shouldBe` (hex, limit, expected)
  it "str.splitlines over decoded grep output matches the reference" $ do
    let cases = arrayItems (member "search_lines" corpus)
    (length cases > 100) `shouldBe` True
    forM_ cases $ \entry -> do
      let raw = unhex (memberText "hex" entry)
          projected = take 16 [T.take 256 line | line <- pythonSplitlines (fst (boundedText raw 65536)), not (T.null line)]
      projected `shouldBe` [t | String t <- arrayItems (member "lines" entry)]
  it "decodeUtf8Replace substitutes one U+FFFD per maximal subpart" $ do
    decodeUtf8Replace "\xed\xa0\x80" `shouldBe` "\xFFFD\xFFFD\xFFFD"
    decodeUtf8Replace "\xe0\xa0" `shouldBe` "\xFFFD"
    decodeUtf8Replace "\xf0\x90\x80\&a" `shouldBe` "\xFFFD\&a"
    decodeUtf8Replace "\xf4\x90\x80\x80" `shouldBe` "\xFFFD\xFFFD\xFFFD\xFFFD"
    decodeUtf8Replace "\xc0\xaf" `shouldBe` "\xFFFD\xFFFD"

arrayItems :: Json -> [Json]
arrayItems = \case
  Array items -> items
  other -> error ("expected an array, got " <> show other)

unhex :: Text -> B.ByteString
unhex = B.pack . go . T.unpack
  where
    go (a : b : rest) = fromIntegral (digitToInt a * 16 + digitToInt b) : go rest
    go _ = []

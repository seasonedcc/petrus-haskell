-- | Every case of the committed differential corpus: each operation's result
-- (the canonical bytes, the resolved net and schema, or the exception class
-- and text) must equal what petrus-engine recorded.
module Petrus.EngineFile.CorpusSpec (spec, corpusPath, checkCase) where

import Control.Monad (forM_, unless, when)
import Data.Text qualified as T
import Petrus.EngineFile.Corpus
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

-- | The corpus, from the package directory (cabal test) or the repository
-- root.
corpusPath :: IO FilePath
corpusPath = do
  local <- doesFileExist here
  pure (if local then here else "packages/petrus-engine-file" </> here)
  where
    here = "differential" </> "corpus.json"

spec :: Spec
spec = describe "differential corpus (petrus-engine verdicts)" $ do
  cases <- runIO (corpusPath >>= readCorpus)
  it "has cases from every source" $ do
    let prefixes = map (T.takeWhile (/= '/') . (.name)) cases
    forM_ ["upstream", "viewer", "edge", "fuzz"] $ \p -> p `shouldSatisfy` (`elem` prefixes)
  forM_ cases $ \c -> it (T.unpack c.name) (checkCase c)

-- | Run a case and compare each operation with the recorded verdict.
checkCase :: Case -> Expectation
checkCase c = do
  let expected = c.expect
  actual <- runCase c
  length actual `shouldBe` length expected
  forM_ (zip3 [0 :: Int ..] c.ops (zip actual expected)) $ \(i, op, (got, want)) ->
    if i `elem` c.loneSurrogateOps
      then
        unless ("UnsupportedLoneSurrogate" `T.isInfixOf` got) $
          expectationFailure (show op <> ": expected the documented lone-surrogate refusal, got " <> T.unpack got)
      else when (got /= want) $ expectationFailure (show op <> "\n  got:  " <> T.unpack got <> "\n  want: " <> T.unpack want)

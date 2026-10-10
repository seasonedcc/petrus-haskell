-- | The differential corpus: every case recorded from cel-python by
-- @test/gen-cel-corpus.py@ is replayed here.
module Corpus
  ( Corpus (..)
  , load
  , spec
  ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Petrus.Cel.Parse
import Petrus.Cel.Syntax
import Petrus.Json

data Corpus = Corpus
  { corpusMain :: Json
  , corpusOperators :: Json
  }

load :: IO Corpus
load = Corpus <$> readCorpus "test/corpus/cel-corpus.json" <*> readCorpus "test/corpus/cel-operators.json"
  where
    readCorpus path = either (fail . ((path <> ": ") <>)) pure . parseJson pythonLoads =<< BS.readFile path

field :: Text -> Json -> Maybe Json
field = lookupMember

textField :: Text -> Json -> Text
textField name j = case field name j of
  Just (String t) -> t
  _ -> ""

arrayField :: Text -> Json -> [Json]
arrayField name j = case field name j of
  Just (Array xs) -> xs
  _ -> []

-- | Check every case of a group, reporting up to ten mismatches at once.
checkAll :: [(Text, Maybe String)] -> Expectation
checkAll results = case [T.unpack label <> "\n    " <> problem | (label, Just problem) <- results] of
  [] -> pure ()
  problems ->
    expectationFailure
      (show (length problems) <> " mismatching case(s):\n  " <> concatMap (<> "\n  ") (take 10 problems))

spec :: Corpus -> Spec
spec corpus = describe "differential corpus (cel-python 0.5.0)" $ do
  let cases = arrayField "cases" (corpusMain corpus)
      groups = nub (map (textField "group") cases)
  describe "expression cases" $
    forM_ groups $ \group ->
      it (T.unpack group) $
        checkAll [(label c, checkCase c) | c <- cases, textField "group" c == group]
  where
    label c = T.pack (show (textField "expr" c))

checkCase :: Json -> Maybe String
checkCase c =
  let source = textField "expr" c
   in case (parseCel source, field "parse_error" c) of
        (Left err, Just expected) ->
          let want = (intField "line" expected, intField "column" expected)
              got = (parseErrorLine err, parseErrorColumn err)
           in if want == got then Nothing else Just ("parse error at " <> show got <> ", expected " <> show want)
        (Left err, Nothing) -> Just ("unexpected parse error: " <> show err)
        (Right _, Just expected) -> Just ("parsed, expected parse error " <> show expected)
        (Right tree, Nothing) -> case field "tree" c of
          Just (String want)
            | larkText (toLark tree) /= want -> Just ("tree " <> T.unpack (larkText (toLark tree)) <> "\n    expected " <> T.unpack want)
          _ -> Nothing
  where
    intField name j = case field name j of
      Just (Int n) -> Just (fromInteger n)
      _ -> Nothing

-- | The fingerprint gate and the seed marking, against the pinned Python
-- (scripts/gen_topology_corpus.py).
module TopologySpec (spec) where

import Control.Monad (forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.List (sort)
import Data.Text qualified as T
import Corpus
import Hamsterdan.Readiness.NetV5.Topology
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.Petrinet (Token (..), markingToList, netPathText)
import Petrus.Impetus.Petrinet.Schema (netPlaceOrder, netTransitionOrder)
import Petrus.Json (Json (..))
import Test.Hspec
import Data.Bifunctor (first)
import Hamsterdan.Python (PyObject (..), PythonException (..), pythonExceptionStr, pythonFailureText)

built :: BuiltNet
built = either (error . show) id buildNetV5

definitionBytes :: BS.ByteString
definitionBytes = either (error . T.unpack) id (projectNetDefinition built.net >>= serializeNetDefinition)

markingJson :: [(a, [Token])] -> (a -> T.Text) -> Json
markingJson entries name =
  Array
    [ Array [String (name path), Array [Array [maybe Null String tok.color, tok.payload] | tok <- tokens]]
    | (path, tokens) <- entries
    ]

spec :: Spec
spec = describe "topology" $ do
  describe "net definition fingerprint gate" $ do
    it "serializes byte for byte as the pinned Python" $ do
      expected <- readCorpusFile "net_definition.json"
      BS.length definitionBytes `shouldBe` BS.length expected
      definitionBytes == expected `shouldBe` True
    it "has the pinned sha256" $ do
      pinned <- readCorpusFile "net_definition.sha256"
      Base16.encode (SHA256.hash definitionBytes) `shouldBe` BS8.takeWhile (/= '\n') pinned
    it "has 111 places and 141 transitions" $ do
      length (netPlaceOrder built.net) `shouldBe` 111
      length (netTransitionOrder built.net) `shouldBe` 141

  describe "gates" $ do
    it "lists every gate with its variants in loop order" $ do
      [row] <- readCorpus "gates.json"
      let expected =
            [ (p, (a, [v | String v <- vs]))
            | Array [String p, String a, Array vs] <- array "gates" row
            ]
      gates `shouldBe` expected
      array "derived" row `shouldBe` []
      derived `shouldBe` []
    it "binds every handler symbol in the net to a gate" $ do
      sort (map (fst . snd) gates)
        `shouldBe` sort ["rerun_gate", "review_agent", "publish_gate", "git_gate", "reply_gate", "dash_gate", "reminder_gate", "announce_gate"]

  describe "seed_marking" $ do
    rows <- runIO (readCorpus "seed_marking.jsonl")
    it ("matches every corpus row (" <> show (length rows) <> ")") $
      expectNone
        [ show subject <> ": expected " <> T.unpack (either id spelled expected) <> ", got " <> T.unpack (either id spelled actual)
        | row <- rows
        , let subject = text "subject" row
              delay = maybe defaultReminderDelayS (\case Int i -> i; _ -> error "delay") (member "delay" row)
              expected = case member "error" row of
                Just (String message) -> Left message
                _ -> Right (maybe Null id (member "marking" row))
              actual = (\m -> markingJson (markingToList m) netPathText) <$> first valueErrorText (seedMarkingWith delay subject)
        , either id spelled expected /= either id spelled actual
        ]
    forM_ ["", "x\ty", T.replicate 901 "x", "caf\233"] $ \subject ->
      it ("refuses " <> show (T.take 12 subject)) $
        seedMarking subject `shouldSatisfy` either (\case PythonException "ValueError" [PyStr m] -> m == subjectMalformed; _ -> False) (const False)
    it "accepts exactly 900 bytes" $
      either (const False) (const True) (seedMarking (T.replicate 900 "x")) `shouldBe` True

-- | The corpus records @str(error)@ of the @ValueError@ it catches; any
-- other exception keeps its class in the text, so it cannot match.
valueErrorText :: PythonException -> T.Text
valueErrorText = \case
  e@(PythonException "ValueError" _) -> pythonExceptionStr e
  e -> pythonFailureText e

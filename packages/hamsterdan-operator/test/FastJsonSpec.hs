-- | The JSON fast path ("Hamsterdan.Operator.FastJson") against the
-- reference loader and against CPython's @json.loads@ itself: on every
-- document it accepts, its value is the reference's, and it declines every
-- document outside its subset.
module FastJsonSpec (spec) where

import Control.Monad (forM_, unless)
import Data.ByteString.Lazy qualified as BL
import Data.Char (chr)
import Data.List (unfoldr)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Export.Python (loadsText)
import Hamsterdan.Operator.FastJson (fastLoads)
import Hamsterdan.Operator.Python (dumpsPlain)
import Petrus.Json (Json (..), compact, dumps)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)
import Test.Hspec

-- | Documents in the subset.
accepted :: [Text]
accepted =
  [ "{}"
  , "[]"
  , " \t\r\n{\"a\": [1, -2, 0, -0, true, false, null, \"x\"]} \n"
  , "\"plain\""
  , "\"esc \\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u0041 \\u00e9 \\u20AC \\u0000 end\""
  , "\"caf\233 \128512 raw\""
  , "123456789012345678901234567890"
  , "-0"
  , "[[[[[]]]]]"
  , "{\"\": {\"\": []}, \"b\": \"\"}"
  , "\"\127 is fine\""
  , T.replicate 4000 "9"
  ]

-- | Documents outside the subset: the fast path declines, whatever the
-- reference makes of them.
declined :: [Text]
declined =
  [ ""
  , "   "
  , "1.5"
  , "1e3"
  , "-1E+2"
  , "NaN"
  , "-Infinity"
  , "{\"a\": 1, \"a\": 2}"
  , "\"\\ud83d\\ude00\""
  , "\"\\udc00\""
  , "\"tab\there\""
  , "[1,]"
  , "{\"a\" 1}"
  , "01"
  , "[1] x"
  , "\65279{}"
  , "\"\\x\""
  , "\"\\u12\""
  , "tru"
  , "-"
  , T.replicate 501 "[" <> T.replicate 501 "]"
  , T.replicate 4001 "9"
  , "\"unterminated"
  ]

-- ---------------------------------------------------------------------------
-- Generated documents

-- | A deterministic stream of pseudo-random numbers.
randoms :: Int -> [Int]
randoms = unfoldr (\s -> let s' = (s * 1103515245 + 12345) `mod` 2147483648 in Just (s' `div` 65536, s'))

-- | A random document text and the rest of the stream.
document :: Int -> [Int] -> (Text, [Int])
document depth = \case
  r : rest -> case r `mod` (if depth > 4 then 6 else 9) of
    0 -> ("null", rest)
    1 -> (if even (r `div` 9) then "true" else "false", rest)
    2 -> integer rest
    3 -> string rest
    4 -> string rest
    5 -> if r `mod` 23 == 0 then ("2.5", rest) else integer rest
    6 -> array (depth + 1) rest
    7 -> object (depth + 1) rest
    _ -> object (depth + 1) rest
  [] -> ("null", [])
  where
    integer = \case
      r : rest -> (T.pack (show ((r * 7919 - 1000000) * (if r `mod` 5 == 0 then 10 ^ (30 :: Int) else 1))), rest)
      [] -> ("0", [])
    string = \case
      r : rest ->
        let (count, more) = (r `mod` 12, rest)
            (pieces, remaining) = takePieces count more
         in ("\"" <> T.concat pieces <> "\"", remaining)
      [] -> ("\"\"", [])
    takePieces :: Int -> [Int] -> ([Text], [Int])
    takePieces 0 rs = ([], rs)
    takePieces n (r : rs) = let (more, remaining) = takePieces (n - 1) rs in (piece r : more, remaining)
    takePieces _ [] = ([], [])
    piece r = case r `mod` 14 of
      0 -> "\\n"
      1 -> "\\\""
      2 -> "\\u00" <> T.pack (show (10 + r `mod` 89))
      3 -> "\233"
      4 -> "\128512"
      5 -> if r `mod` 41 == 0 then "\\ud800" else "\\u4e2d"
      6 -> "\\\\"
      7 -> if r `mod` 53 == 0 then "\t" else " "
      _ -> T.singleton (chr (0x61 + r `mod` 26))
    space r = ["", " ", "\n  ", "\t"] !! (r `mod` 4)
    array d = \case
      r : rest ->
        let (items, remaining) = values d (r `mod` 5) rest
         in ("[" <> space r <> T.intercalate ("," <> space (r `div` 4)) items <> space (r `div` 16) <> "]", remaining)
      [] -> ("[]", [])
    object d = \case
      r : rest ->
        let (items, remaining) = values d (r `mod` 5) rest
            keys = [if r `mod` 31 == 0 && i == 1 then "\"k0\"" else "\"k" <> T.pack (show i) <> "\"" | i <- [0 :: Int ..]]
         in ("{" <> T.intercalate ", " [k <> ":" <> space r <> v | (k, v) <- zip keys items] <> "}", remaining)
      [] -> ("{}", [])
    values _ 0 rs = ([], rs)
    values d n rs = let (v, rs') = document d rs; (more, rs'') = values d (n - 1 :: Int) rs' in (v : more, rs'')

generated :: [Text]
generated = take 3000 (go (randoms 20261011))
  where
    go rs = let (doc, rest) = document 0 rs in doc : go rest

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "JSON fast path (Haskell port)" do
  it "accepts its subset" $
    filter (isNothing . fastLoads) accepted `shouldBe` []
  it "declines everything else" $
    filter (isJust . fastLoads) declined `shouldBe` []
  it "returns the reference loader's value on every document it accepts" do
    let documents = accepted <> declined <> generated
        disagreements =
          [ (document', show fast, show (loadsText bytes))
          | document' <- documents
          , let bytes = TE.encodeUtf8 document'
          , Just fast <- [fastLoads document']
          , Right (show fast) /= fmap show (loadsText bytes)
          ]
    disagreements `shouldBe` []
    -- The generated corpus exercises both outcomes.
    length (filter (isJust . fastLoads) generated) `shouldSatisfy` (> 2000)
    length (filter (isNothing . fastLoads) generated) `shouldSatisfy` (> 50)
  it "returns CPython's json.loads value on every document it accepts" do
    python <- upstreamPythonExecutable "hamsterdan"
    let documents = accepted <> generated
        payload = either (error . show) id (dumps compact (Array (map String documents)))
        script =
          "import json, sys\n\
          \for document in json.load(sys.stdin):\n\
          \    try:\n\
          \        print(json.dumps(json.loads(document)))\n\
          \    except Exception as error:\n\
          \        print(type(error).__name__)\n"
    (_, out, err) <- readProcess (setStdin (byteStringInput (BL.fromStrict payload)) (proc python ["-I", "-B", "-c", script]))
    unless (BL.null err) $ expectationFailure (show err)
    let reference = T.lines (TE.decodeUtf8 (BL.toStrict out))
    length reference `shouldBe` length documents
    forM_ (zip documents reference) \(document', expected) ->
      case fastLoads document' of
        Just value -> (document', dumpsPlain value) `shouldBe` (document', Right expected)
        Nothing -> pure ()

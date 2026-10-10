-- | 'isPythonPrintable' against CPython 3.14's @str.isprintable@ for every
-- code point, and 'pythonStrRepr' against reprs the pinned interpreter
-- printed.
module Petrus.Json.PythonTextSpec (spec) where

import Data.Char (chr)
import Data.IntMap.Strict qualified as IntMap
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Numeric (readHex)
import Petrus.Json.PythonText
import Test.Hspec

-- | The committed vector: alternating runs @first last verdict@ covering
-- 0..0x10FFFF, written by @gen/gen_python_printable.py@.
readVector :: IO [(Int, Int, Bool)]
readVector = do
  text <- TIO.readFile "test/python-printable.txt"
  pure
    [ (hex first, hex final, verdict == "1")
    | line <- lines (T.unpack text)
    , not ("#" `isPrefixOf` line)
    , [first, final, verdict] <- [words line]
    ]
  where
    hex s = case readHex s of
      [(v, "")] -> v
      _ -> error ("bad vector entry " <> s)

spec :: Spec
spec = describe "Petrus.Json.PythonText" $ do
  it "agrees with CPython 3.14's str.isprintable on every code point" $ do
    runs <- readVector
    -- The runs tile the whole code space, in order.
    map (\(first, _, _) -> first) runs `shouldBe` 0 : map (\(_, final, _) -> final + 1) (init runs)
    (\(_, final, _) -> final) (last runs) `shouldBe` 0x10FFFF
    let expected = IntMap.fromList [(first, (final, verdict)) | (first, final, verdict) <- runs]
        wrong =
          [ code
          | code <- [0 .. 0x10FFFF]
          , let verdict = maybe False (snd . snd) (IntMap.lookupLE code expected)
          , isPythonPrintable (chr code) /= verdict
          ]
    take 10 wrong `shouldBe` []
    length (filter (isPythonPrintable . chr) [0 .. 0x10FFFF]) `shouldBe` 154810

  describe "repr(str)" $ do
    let cases :: [(Text, Text)]
        cases =
          [ ("\xa0", "'\\xa0'")
          , ("\x0378", "'\\u0378'")
          , ("\xe9\t\n\r\\", "'\xe9\\t\\n\\r\\\\'")
          , ("\x2028x", "'\\u2028x'")
          , ("\x1F600", "'\x1F600'")
          , ("it's", "\"it's\"")
          , ("a\"b'c", "'a\"b\\'c'")
          , ("\x7f\x00\x1f", "'\\x7f\\x00\\x1f'")
          , ("\x200b", "'\\u200b'")
          , ("\xe000", "'\\ue000'")
          , ("\x0897", "'\x0897'")
          , ("\x1CC00", "'\x1CC00'")
          , ("\x3000", "'\\u3000'")
          , (" ", "' '")
          , ("\xE0001", "'\\U000e0001'")
          , ("\x10FFFF", "'\\U0010ffff'")
          , ("\xad", "'\\xad'")
          , ("\x1c89", "'\x1c89'")
          ]
    mapM_ (\(value, expected) -> it (T.unpack expected) (pythonStrRepr value `shouldBe` expected)) cases
    it "escapes a lone surrogate" $
      pythonStringRepr ['a', chr 0xD800] `shouldBe` "'a\\ud800'"

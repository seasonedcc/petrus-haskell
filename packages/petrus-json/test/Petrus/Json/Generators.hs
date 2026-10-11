-- | Generators shared by the reader's property tests and the CPython
-- differential: documents in every encoder spelling Petrus uses, their
-- mutations, number spellings and byte soup.
module Petrus.Json.Generators
  ( documentText
  , jsonValue
  , mutated
  , soup
  , numberSpelling
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Data.Word (Word8)
import Petrus.Json
import Test.QuickCheck

-- | A JSON document written by one of the encoder spellings Petrus uses.
documentText :: Gen BS.ByteString
documentText = do
  value <- sized (\n -> jsonValue (min 4 (n `div` 10 + 1)))
  options <-
    elements
      [ defaultDumps
      , compact
      , indented {allowNan = True}
      , compact {ensureAscii = True, allowNan = True}
      , defaultDumps {sortKeys = True}
      ]
  pure (either (const "null") id (dumps options value))

jsonValue :: Int -> Gen Json
jsonValue depth =
  frequency $
    [ (1, pure Null)
    , (1, Bool <$> arbitrary)
    , (3, Int <$> integer)
    , (3, Float <$> double)
    , (3, String . T.pack <$> listOf character)
    ]
      ++ if depth <= 0
        then []
        else
          [ (2, Array <$> resize 5 (listOf (jsonValue (depth - 1))))
          , (2, Object <$> resize 6 (listOf ((,) <$> (T.pack <$> listOf character) <*> jsonValue (depth - 1))))
          ]
  where
    integer =
      oneof
        [ arbitrary
        , choose (-(10 ^ (19 :: Int)), 10 ^ (19 :: Int))
        , choose (-(10 ^ (40 :: Int)), 10 ^ (40 :: Int))
        , elements
            [ 0
            , -1
            , 9007199254740991
            , 9007199254740992
            , -9007199254740991
            , -9007199254740992
            , 999999999999999999
            , 1000000000000000000
            , -999999999999999999
            , 9223372036854775807
            , -9223372036854775808
            ]
        ]
    double =
      oneof
        [ arbitrary
        , (/ 1000) . fromInteger <$> choose (-(10 ^ (12 :: Int)), 10 ^ (12 :: Int))
        , (* 1e-300) <$> arbitrary
        , elements [0, -0.0, 0.1, 1e22, 1e23, 5e-324, 1.7976931348623157e308, 1 / 0, -1 / 0, 0 / 0, 123456789012345.6, 9007199254740993]
        ]
    character =
      frequency
        [ (8, elements (['a' .. 'z'] ++ ['0' .. '9'] ++ " .:"))
        , (1, elements "\"\\/\b\f\n\r\t\x01\x1f\x7f")
        , (1, elements "\x80\xe9\x2028\xffff\x1F600\x10ffff")
        ]

-- | Random single-byte insertions, deletions, and replacements drawn from
-- the bytes that matter to the grammar.
mutated :: BS.ByteString -> Gen BS.ByteString
mutated text = do
  edits <- choose (1, 3 :: Int)
  go edits text
  where
    go :: Int -> BS.ByteString -> Gen BS.ByteString
    go 0 current = pure current
    go n current = do
      position <- choose (0, BS.length current)
      byte <- elements soup
      edit <-
        elements
          [ BS.take position current <> BS.singleton byte <> BS.drop position current
          , BS.take position current <> BS.drop (position + 1) current
          , BS.take position current <> BS.singleton byte <> BS.drop (position + 1) current
          ]
      go (n - 1) edit

soup :: [Word8]
soup =
  BS.unpack (BC.pack "{}[],:\" 0123456789-+.eEntfalsruNIiy \t\n\r\\u/bdD8")
    ++ [0x00, 0x01, 0x1f, 0x7f, 0x80, 0xbf, 0xc0, 0xc3, 0xa9, 0xed, 0xa0, 0xef, 0xbb, 0xf0, 0x9f, 0xf8, 0xff]

-- | Number spellings, valid and invalid: signs, leading zeros, fractions,
-- exponents of every size, and digit runs on both sides of the fast paths'
-- limits.
numberSpelling :: Gen String
numberSpelling = do
  sign <- elements ["", "", "-", "+"]
  whole <- frequency [(1, pure "0"), (1, pure "00"), (6, digitRun 1 25), (1, pure "")]
  fraction <- frequency [(2, pure ""), (3, ("." ++) <$> digitRun 1 25), (1, pure ".")]
  expo <-
    frequency
      [ (3, pure "")
      , (3, exponentPart 1 3)
      , (1, exponentPart 4 22)
      , (1, (: []) <$> elements "eE")
      ]
  trailer <- frequency [(6, pure ""), (1, elements [" ", "]", "x", ".", "e"])]
  pure (sign ++ whole ++ fraction ++ expo ++ trailer)
  where
    exponentPart low high = do
      marker <- elements "eE"
      sign <- elements ["", "+", "-"]
      digits <- digitRun low high
      pure (marker : sign ++ digits)
    digitRun :: Int -> Int -> Gen String
    digitRun low high = do
      n <- choose (low, high)
      vectorOf n (frequency [(1, pure '0'), (4, elements ['1' .. '9'])])

{-# LANGUAGE OverloadedRecordDot #-}

-- | 'utf8DecodeError' and 'utf8EncodeError' against CPython 3.14.6: each
-- expected text is the @str()@ of the exception the pinned interpreter
-- raised (and 'Nothing' where it succeeded).
module PyTextSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.Text (Text)
import Data.Text.Foreign qualified as TF
import Data.Word (Word8)
import Foreign.Ptr (castPtr)
import Hamsterdan.Python.Exception (PythonException (..), pythonExceptionStr)
import Hamsterdan.Python.Text (utf8DecodeError, utf8EncodeError)
import Hamsterdan.Sqlite (SQLData (..))
import Hamsterdan.Sqlite qualified as Db
import Test.Hspec

-- | @bytes.decode("utf-8")@.
decoding :: [(ByteString, Maybe Text)]
decoding =
  [ ("plain ascii\n", Nothing)
  , ("caf\xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80", Nothing)
  , ("\xff", Just "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte")
  , ("ok\x80", Just "'utf-8' codec can't decode byte 0x80 in position 2: invalid start byte")
  , ("a\xc0\xaf", Just "'utf-8' codec can't decode byte 0xc0 in position 1: invalid start byte")
  , ("\xc3", Just "'utf-8' codec can't decode byte 0xc3 in position 0: unexpected end of data")
  , ("ab\xe2\x82", Just "'utf-8' codec can't decode bytes in position 2-3: unexpected end of data")
  , ("\xe2(\xa1", Just "'utf-8' codec can't decode byte 0xe2 in position 0: invalid continuation byte")
  , ("\xe0\x80\x80", Just "'utf-8' codec can't decode byte 0xe0 in position 0: invalid continuation byte")
  , ("\xed\xa0\x80", Just "'utf-8' codec can't decode byte 0xed in position 0: invalid continuation byte")
  , ("\xf0\x90\x80", Just "'utf-8' codec can't decode bytes in position 0-2: unexpected end of data")
  , ("\xf0\x90(", Just "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte")
  , ("\xf4\x90\x80\x80", Just "'utf-8' codec can't decode byte 0xf4 in position 0: invalid continuation byte")
  , ("\xf5\x80", Just "'utf-8' codec can't decode byte 0xf5 in position 0: invalid start byte")
  , ("x\xe2\x82\xacy\xfe", Just "'utf-8' codec can't decode byte 0xfe in position 5: invalid start byte")
  , ("\xf0\x9f\x98", Just "'utf-8' codec can't decode bytes in position 0-2: unexpected end of data")
  , ("\xf0\x9f\x98\x00", Just "'utf-8' codec can't decode bytes in position 0-2: invalid continuation byte")
  , ("\xc2\&A", Just "'utf-8' codec can't decode byte 0xc2 in position 0: invalid continuation byte")
  , ("\xe1\x80\&A", Just "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte")
  , ("\xe0\xa0", Just "'utf-8' codec can't decode bytes in position 0-1: unexpected end of data")
  ]

-- | @value.encode()@, and CPython's @sqlite3@ binding the same @str@, over
-- strings holding surrogate code points (what @json.loads@ returns for a
-- lone-surrogate escape).
encoding :: [([Int], Maybe Text)]
encoding =
  [ (map fromEnum "plain", Nothing)
  , ([0xE9, 0x1F600], Nothing)
  , ([0xD800], Just "'utf-8' codec can't encode character '\\ud800' in position 0: surrogates not allowed")
  , ([0x61, 0x62, 0xDFFF], Just "'utf-8' codec can't encode character '\\udfff' in position 2: surrogates not allowed")
  , ([0xD800, 0xD800, 0x78], Just "'utf-8' codec can't encode characters in position 0-1: surrogates not allowed")
  , ([0x78, 0xDC00, 0x79, 0xD800], Just "'utf-8' codec can't encode character '\\udc00' in position 1: surrogates not allowed")
  , ([0xE9, 0xD800], Just "'utf-8' codec can't encode character '\\ud800' in position 1: surrogates not allowed")
  ]

-- | The 'Text' petrus-json keeps for such a string: its code points in
-- generalized UTF-8 (WTF-8), a surrogate spelled with its three bytes.
wtf8 :: [Int] -> IO Text
wtf8 points = BU.unsafeUseAsCStringLen bytes (\(pointer, size) -> TF.fromPtr (castPtr pointer) (fromIntegral size))
  where
    bytes = BS.pack (concatMap encode points)
    encode :: Int -> [Word8]
    encode c
      | c < 0x80 = [fromIntegral c]
      | c < 0x800 = [0xC0 .|. top 6, continuation 0]
      | c < 0x10000 = [0xE0 .|. top 12, continuation 6, continuation 0]
      | otherwise = [0xF0 .|. top 18, continuation 12, continuation 6, continuation 0]
      where
        top n = fromIntegral (c `shiftR` n)
        continuation n = 0x80 .|. fromIntegral ((c `shiftR` n) .&. 0x3F)

spec :: Spec
spec = do
  describe "Hamsterdan.Python.Text.utf8DecodeError (CPython's UnicodeDecodeError text)" $
    forM_ decoding $ \(bytes, expected) ->
      it (show bytes) $ utf8DecodeError bytes `shouldBe` expected
  describe "Hamsterdan.Python.Text.utf8EncodeError (CPython's UnicodeEncodeError text)" $
    forM_ encoding $ \(points, expected) ->
      it (show points) $ (utf8EncodeError <$> wtf8 points) `shouldReturn` expected
  describe "Hamsterdan.Sqlite binds as CPython's sqlite3 does" $
    forM_ encoding $ \(points, expected) -> it (show points) $ do
      value <- wtf8 points
      bracket (Db.open ":memory:") Db.close $ \connection -> case expected of
        Nothing -> Db.query connection "SELECT length(?)" [SQLText value] `shouldReturn` [[SQLInteger (fromIntegral (length points))]]
        Just failure -> Db.query connection "SELECT ?" [SQLText value] `shouldThrow` (\e -> e.name == "UnicodeEncodeError" && pythonExceptionStr e == failure)

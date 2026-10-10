-- | Shared helpers for the petrus-execution test suite.
module Support
  ( -- * JSON fixtures
    loadFixture
  , field
  , fieldMaybe
  , textField
  , intField
  , listField
  , bytesB64
  , bytesZB64
  , isNull
    -- * Errors
  , pythonClassKind
  , shouldThrowKind
  , shouldThrowMessage
  , errorMatching
    -- * Paths
  , withTempDir
  , raw
  ) where

import Codec.Compression.Zlib qualified as Zlib
import Control.Exception (try)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json
import Petrus.Motus.Execution.Error
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

loadFixture :: FilePath -> IO Json
loadFixture name = do
  bytes <- B.readFile ("test/fixtures" </> name)
  either (fail . ("fixture parse error: " <>)) pure (parseJson pythonLoads bytes)

field :: Text -> Json -> Json
field key value = case lookupMember key value of
  Just found -> found
  Nothing -> error ("missing fixture field " <> T.unpack key)

fieldMaybe :: Text -> Json -> Maybe Json
fieldMaybe key value = case lookupMember key value of
  Just Null -> Nothing
  other -> other

isNull :: Json -> Bool
isNull = \case
  Null -> True
  _ -> False

textField :: Text -> Json -> Text
textField key value = case field key value of
  String t -> t
  other -> error ("fixture field " <> T.unpack key <> " is not a string: " <> show other)

intField :: Text -> Json -> Integer
intField key value = case field key value of
  Int n -> n
  other -> error ("fixture field " <> T.unpack key <> " is not an int: " <> show other)

listField :: Text -> Json -> [Json]
listField key value = case field key value of
  Array items -> items
  other -> error ("fixture field " <> T.unpack key <> " is not a list: " <> show other)

bytesB64 :: Text -> Json -> ByteString
bytesB64 key value = either error id (B64.decode (TE.encodeUtf8 (textField key value)))

bytesZB64 :: Text -> Json -> ByteString
bytesZB64 key value = BL.toStrict (Zlib.decompress (BL.fromStrict (bytesB64 key value)))

-- | The 'ErrorKind' a Python exception class maps to.
pythonClassKind :: Text -> ErrorKind
pythonClassKind = \case
  "ValueError" -> ValueError
  "TypeError" -> TypeError
  "RuntimeError" -> RuntimeError
  "ConnectionError" -> ConnectionError
  "KeyError" -> KeyError
  "TimeoutError" -> TimeoutError
  cls
    | cls `elem` tarErrors -> TarError
    | cls `elem` osErrors -> OSError
    | otherwise -> OtherError cls
  where
    tarErrors =
      [ "TarError", "ReadError", "CompressionError", "ExtractError", "FilterError"
      , "AbsolutePathError", "OutsideDestinationError", "SpecialFileError", "AbsoluteLinkError"
      , "LinkOutsideDestinationError", "LinkFallbackError"
      ]
    osErrors =
      [ "OSError", "FileNotFoundError", "FileExistsError", "NotADirectoryError", "IsADirectoryError"
      , "PermissionError"
      ]

shouldThrowKind :: IO a -> ErrorKind -> Expectation
shouldThrowKind action kind = do
  result <- try action
  case result of
    Left err -> errorKind err `shouldBe` kind
    Right _ -> expectationFailure ("expected " <> show kind <> " but the action succeeded")

shouldThrowMessage :: IO a -> (ErrorKind, Text) -> Expectation
shouldThrowMessage action expected = do
  result <- try action
  case result of
    Left err -> (errorKind err, errorMessage err) `shouldBe` expected
    Right _ -> expectationFailure ("expected " <> show expected <> " but the action succeeded")

-- | Expect an 'ExecutionError' of this kind whose message contains a
-- fragment (pytest's @raises(match=...)@).
errorMatching :: IO a -> ErrorKind -> Text -> Expectation
errorMatching action kind fragment = do
  result <- try action
  case result of
    Left err -> do
      errorKind err `shouldBe` kind
      errorMessage err `shouldSatisfy` T.isInfixOf fragment
    Right _ -> expectationFailure ("expected " <> show kind <> " matching " <> show fragment)

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "petrus-execution-test"

raw :: Text -> ByteString
raw = TE.encodeUtf8

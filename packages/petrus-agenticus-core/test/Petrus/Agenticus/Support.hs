-- | Shared helpers for the Agenticus core test suite.
module Petrus.Agenticus.Support
  ( packageFile
  , loadJson
  , parseJsonText
  , shouldRaise
  , shouldRaiseIO
  , shouldRaiseMatching
  , expectRight
  , expectRightIO
  , obj
  , str
  , setMember
  ) where

import Control.Exception (try)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Error
import Petrus.Json (Json (..), parseJson, pythonLoads)
import System.Directory (doesFileExist)
import Test.Hspec

-- | A file of this package, whether the suite runs from the package or the
-- repository root.
packageFile :: FilePath -> IO FilePath
packageFile relative = do
  let candidates = [relative, "packages/petrus-agenticus-core/" <> relative]
  found <- filterIO doesFileExist candidates
  case found of
    path : _ -> pure path
    [] -> fail ("missing test file: " <> relative)
  where
    filterIO p = fmap concat . mapM (\x -> (\ok -> [x | ok]) <$> p x)

loadJson :: FilePath -> IO Json
loadJson relative = do
  path <- packageFile relative
  bytes <- B.readFile path
  either fail pure (parseJson pythonLoads bytes)

parseJsonText :: Text -> Json
parseJsonText t = either error id (parseJson pythonLoads (TE.encodeUtf8 t))

-- | The value fails with an error that is an instance of the class.
shouldRaise :: (Show a) => Either AgenticusError a -> ErrorClass -> Expectation
shouldRaise outcome cls = case outcome of
  Left e
    | e `isInstanceOf` cls -> pure ()
    | otherwise -> expectationFailure ("expected " <> show cls <> ", got " <> show e)
  Right v -> expectationFailure ("expected " <> show cls <> ", got success: " <> show v)

-- | Like 'shouldRaise', also requiring the message to contain the text
-- (pytest's @match=@ for literal patterns).
shouldRaiseMatching :: (Show a) => Either AgenticusError a -> ErrorClass -> Text -> Expectation
shouldRaiseMatching outcome cls needle = do
  outcome `shouldRaise` cls
  case outcome of
    Left e
      | needle `T.isInfixOf` errorMessage e -> pure ()
      | otherwise -> expectationFailure ("message " <> show (errorMessage e) <> " does not match " <> show needle)
    Right _ -> pure ()

shouldRaiseIO :: IO a -> ErrorClass -> Expectation
shouldRaiseIO action cls = do
  outcome <- try action
  case outcome of
    Left e
      | e `isInstanceOf` cls -> pure ()
      | otherwise -> expectationFailure ("expected " <> show cls <> ", got " <> show e)
    Right _ -> expectationFailure ("expected " <> show cls <> ", got success")

expectRight :: Either AgenticusError a -> a
expectRight = either (error . show) id

expectRightIO :: Either AgenticusError a -> IO a
expectRightIO = either (\e -> expectationFailure (show e) >> fail "unreachable") pure

obj :: [(Text, Json)] -> Json
obj = Object

str :: Text -> Json
str = String

-- | Python's @data | {key: value}@ on an object.
setMember :: Text -> Json -> Json -> Json
setMember key value = \case
  Object members
    | any ((== key) . fst) members -> Object [(k, if k == key then value else v) | (k, v) <- members]
    | otherwise -> Object (members <> [(key, value)])
  other -> other

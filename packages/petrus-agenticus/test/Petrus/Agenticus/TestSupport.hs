-- | Shared helpers for the petrus-agenticus specs.
module Petrus.Agenticus.TestSupport
  ( loadJson
  , member
  , memberText
  , expectRight
  , shouldRaise
  , refusal
  , dumpsDefault
  ) where

import Control.Exception (throwIO)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Error
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Hspec

-- | Parse a committed JSON file (paths are relative to the package root,
-- the working directory of @cabal test@).
loadJson :: FilePath -> IO Json
loadJson file = do
  bytes <- BS.readFile file
  either (\e -> throwIO (userError (file <> ": " <> show e))) pure (J.parseJson J.pythonLoads bytes)

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe Null id (lookup key members)
  _ -> Null

memberText :: Text -> Json -> Text
memberText key value = case member key value of
  String s -> s
  other -> error ("expected a string at " <> T.unpack key <> ", got " <> show other)

expectRight :: Show e => Either e a -> IO a
expectRight = either (\e -> expectationFailure (show e) >> error "unreachable") pure

-- | The value is refused with this class and a message containing the
-- fragment (pytest's @raises(..., match=...)@ for literal fragments).
shouldRaise :: Show a => Either AgenticusError a -> (ErrorClass, Text) -> Expectation
shouldRaise outcome (cls, fragment) = case outcome of
  Left e -> do
    (e `isInstanceOf` cls) `shouldBe` True
    (fragment `T.isInfixOf` e.errorMessage) `shouldBe` True
  Right v -> expectationFailure ("expected a refusal, got " <> show v)

-- | An outcome as the corpus spells a refusal.
refusal :: AgenticusError -> Json
refusal e = Object [("class", String (errorClassName e.errorClass)), ("message", String e.errorMessage)]

-- | @json.dumps(value)@ as text.
dumpsDefault :: Json -> Text
dumpsDefault value = either (error . show) TE.decodeUtf8 (J.dumps J.defaultDumps value)

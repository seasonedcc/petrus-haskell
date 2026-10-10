{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Shared test helpers: vector loading, Python error shapes, and World
-- drivers.
module Spec.Support
  ( fixturesDir
  , dataFile
  , readJson
  , member
  , memberText
  , memberList
  , canon
  , canonText
  , shouldBeJson
  , pyError
  , pyErrorOf
  , shouldFailWith
  , replayJson
  , registryOf
  , config
  , withToy
  , startWorld
  , artifactText
  , textBytes
  ) where

import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.World qualified as World
import System.FilePath ((</>))
import Test.Hspec

-- | The pinned reference's world fixtures (tests run from the package
-- directory).
fixturesDir :: FilePath
fixturesDir = "../../upstream/petrus/tests/dst/fixtures"

dataFile :: FilePath -> FilePath
dataFile name = "test/data" </> name

readJson :: FilePath -> IO Json
readJson path = do
  bytes <- BS.readFile path
  either (fail . T.unpack) pure (loadStrictJson bytes)

member :: Text -> Json -> Json
member key value = case lookupMember key value of
  Just v -> v
  Nothing -> error ("missing member " <> T.unpack key)

memberText :: Text -> Json -> Text
memberText key value = case member key value of
  String s -> s
  other -> error ("not a string: " <> show other)

memberList :: Text -> Json -> [Json]
memberList key value = case member key value of
  Array items -> items
  other -> error ("not a list: " <> show other)

-- | Canonical bytes (sorted keys, compact, ASCII).
canon :: Json -> ByteString
canon value = either (error . T.unpack) id (canonicalBytes value)

canonText :: Json -> Text
canonText = TE.decodeUtf8 . canon

-- | Compare two JSON values by their canonical bytes.
shouldBeJson :: (HasCallStack) => Json -> Json -> Expectation
shouldBeJson actual expected = canonText actual `shouldBe` canonText expected

-- | The vectors' error shape: @{"message": str(e), "type": class}@.
pyError :: DstFailure -> Json
pyError failure = Object [("message", String (failureMessage failure)), ("type", String (failureClass failure))]

-- | An optional failure in the vectors' shape (@null@ for success).
pyErrorOf :: Either DstFailure a -> Json
pyErrorOf = either pyError (const Null)

shouldFailWith :: (HasCallStack) => Either DstFailure a -> Json -> Expectation
shouldFailWith outcome expected = pyErrorOf outcome `shouldBeJson` expected

-- | A replay outcome in the vectors' shape.
replayJson :: Either DstFailure AnyReplayResult -> Json
replayJson = \case
  Left failure -> Object [("error", pyError failure)]
  Right result -> Object [("result", String (TE.decodeUtf8 (encodeReplayResult result)))]

registryOf :: [SomeProfile IO] -> [Checker] -> Registry IO
registryOf profiles checkers = either (error . show) id $ do
  withProfiles <- foldM (\r (SomeProfile p) -> registerProfile p r) emptyRegistry profiles
  foldM (flip registerChecker) withProfiles checkers

config :: Profile IO g -> SomeBudget -> [Checker] -> Maybe Integer -> WorldConfig IO g
config profile budget checkers seed = WorldConfig {profile, budget, checkers, seed, progress = Nothing}

-- | Construct a World, run a story, and always close it (Python's
-- @try: ... finally: world.close()@); any failure fails the test.
withToy :: WorldConfig IO g -> WorldT IO g a -> IO a
withToy cfg body = do
  world <- World.newWorld cfg >>= either (\f -> fail (T.unpack (failureClass f <> ": " <> failureMessage f))) pure
  (result, world') <- World.runWorldT body world
  (closed, _) <- World.runWorldT World.close world'
  either (\f -> fail ("close: " <> T.unpack (failureMessage f))) pure closed
  either (\f -> fail (T.unpack (failureClass f <> ": " <> failureMessage f))) pure result

-- | Construct a World, or return the constructor's failure.
startWorld :: WorldConfig IO g -> IO (Either DstFailure ())
startWorld cfg = do
  constructed <- World.newWorld cfg
  case constructed of
    Left failure -> pure (Left failure)
    Right world -> do
      _ <- World.runWorldT World.close world
      pure (Right ())

artifactText :: AnyArtifact -> Text
artifactText artifact = either (error . T.unpack) TE.decodeUtf8 (encodeArtifact artifact)

textBytes :: Text -> ByteString
textBytes = TE.encodeUtf8

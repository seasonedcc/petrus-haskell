{-# LANGUAGE CPP #-}

-- | Helpers shared by the campaign, failure-bundle, legacy-replay, and
-- boundary routes: JSON member access, digests, the reference's
-- @ValueError@ refusals, and the repository identity.
module Petrus.Testing.Dst.Campaign.Support
  ( -- * Refusals
    ToolError (..)
  , refuse
  , orRefuse

    -- * JSON
  , member
  , listOf
  , text
  , texts
  , canonicalDumps
  , prettyDumps

    -- * Digests and text
  , sha256Digest
  , tshow
  , pyRepr

    -- * Strict schemas
  , pListLen
  , pStrLen

    -- * Repository
  , repositoryRoot
  , upstreamRoot
  , gitIdentity
  , runtimeIdentity
  ) where

import Control.Exception (Exception (..), throwIO)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Paths_petrus_dst qualified as Paths
import Petrus.Json (EncodeOptions (..), Json (..), compact, defaultDumps, dumps, lookupMember)
import Petrus.Testing.Dst.Decode (Parser, Path, failAt, pList, pStr)
import Petrus.Testing.Dst.PyRepr (pyStrRepr)
import System.Directory (doesFileExist, getCurrentDirectory, makeAbsolute)
import System.FilePath (takeDirectory, (</>))
import System.Info (compilerName, fullCompilerVersion)
import System.Process (readProcess)

-- ---------------------------------------------------------------------------
-- Refusals

-- | The reference's @ValueError@ / @RuntimeError@ / @AssertionError@ from
-- the DST tooling, by message.
newtype ToolError = ToolError Text
  deriving stock (Eq, Show)

instance Exception ToolError where
  displayException (ToolError message) = T.unpack message

refuse :: Text -> IO a
refuse = throwIO . ToolError

orRefuse :: Either Text a -> IO a
orRefuse = either refuse pure

-- ---------------------------------------------------------------------------
-- JSON

member :: Text -> Json -> Json
member key value = fromMaybe Null (lookupMember key value)

listOf :: Text -> Json -> [Json]
listOf key value = case member key value of
  Array xs -> xs
  _ -> []

text :: Json -> Text
text = \case
  String t -> t
  _ -> ""

texts :: Json -> [Text]
texts = \case
  Array xs -> [t | String t <- xs]
  _ -> []

-- | @json.dumps(value, allow_nan=False, separators=(",", ":"),
-- sort_keys=True).encode()@.
canonicalDumps :: Json -> Either Text ByteString
canonicalDumps = either (Left . T.pack . show) Right . dumps compact {sortKeys = True, ensureAscii = True}

-- | @json.dumps(value, allow_nan=False, indent=2, sort_keys=True).encode()@.
prettyDumps :: Json -> Either Text ByteString
prettyDumps = either (Left . T.pack . show) Right . dumps defaultDumps {indent = Just 2, sortKeys = True, allowNan = False}

-- ---------------------------------------------------------------------------
-- Digests and text

-- | @"sha256:" + hashlib.sha256(payload).hexdigest()@.
sha256Digest :: ByteString -> Text
sha256Digest payload = "sha256:" <> T.pack (show (hash payload :: Digest SHA256))

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Python's @repr()@ of a string.
pyRepr :: Text -> Text
pyRepr = pyStrRepr

-- ---------------------------------------------------------------------------
-- Strict schemas

-- | A list field with pydantic's @min_length@ / @max_length@.
pListLen :: Maybe Int -> Maybe Int -> (Path -> Json -> Parser a) -> Path -> Json -> Parser [a]
pListLen lo hi p at v = do
  items <- pList p at v
  let n = length items
  case lo of
    Just l | n < l -> failAt at "too_short" ("List should have at least " <> tshow l <> " item" <> plural l <> " after validation, not " <> tshow n)
    _ -> Right ()
  case hi of
    Just h | n > h -> failAt at "too_long" ("List should have at most " <> tshow h <> " item" <> plural h <> " after validation, not " <> tshow n)
    _ -> Right ()
  Right items
  where
    plural k = if k == 1 then "" else "s" :: Text

-- | A string field with pydantic's @min_length@ / @max_length@.
pStrLen :: Maybe Int -> Maybe Int -> Path -> Json -> Parser Text
pStrLen lo hi at v = do
  s <- pStr at v
  let n = T.length s
  case lo of
    Just l | n < l -> failAt at "string_too_short" ("String should have at least " <> tshow l <> " character" <> plural l)
    _ -> Right ()
  case hi of
    Just h | n > h -> failAt at "string_too_long" ("String should have at most " <> tshow h <> " character" <> plural h)
    _ -> Right ()
  Right s
  where
    plural k = if k == 1 then "" else "s" :: Text

-- ---------------------------------------------------------------------------
-- Repository

-- | The checkout root: the nearest directory above the working directory
-- holding @cabal.project@.
repositoryRoot :: IO FilePath
repositoryRoot = getCurrentDirectory >>= makeAbsolute >>= go
  where
    go dir = do
      found <- doesFileExist (dir </> "cabal.project")
      if found
        then pure dir
        else do
          let parent = takeDirectory dir
          if parent == dir then refuse "DST tooling must run inside the repository checkout" else go parent

-- | The pinned reference checkout, whose repository-relative paths
-- (@tests/dst/fixtures/...@) the reference's manifests name.
upstreamRoot :: IO FilePath
upstreamRoot = (</> "upstream" </> "petrus") <$> repositoryRoot

-- | @repository_identity()@: the exact Git commit and whether the tree is
-- dirty.
gitIdentity :: FilePath -> IO (Text, Bool)
gitIdentity root = do
  commit <- T.strip . T.pack <$> readProcess "git" ["-C", root, "rev-parse", "HEAD"] ""
  unless (T.length commit == 40 && T.all (`elem` ("0123456789abcdef" :: String)) commit) $
    refuse "DST operation requires an exact Git commit identity"
  status <- readProcess "git" ["-C", root, "status", "--short"] ""
  pure (commit, not (null status))

-- | The interpreter and generator versions a report names: the reference's
-- Python, Hypothesis, and Petrus versions become GHC's, Hedgehog's, and
-- this package's.
runtimeIdentity :: [(Text, Text)]
runtimeIdentity =
  [ ("ghc", T.pack (compilerName <> "-" <> showVersion fullCompilerVersion))
  , ("hedgehog", VERSION_hedgehog)
  , ("petrus-dst", T.pack (showVersion Paths.version))
  ]

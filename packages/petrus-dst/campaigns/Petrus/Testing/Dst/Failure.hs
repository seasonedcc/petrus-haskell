{-# LANGUAGE OverloadedRecordDot #-}

-- | Retain, replay, and promote bounded deterministic simulation failures:
-- a port of the reference's @tests/dst/failure.py@.
--
-- A failure bundle is a directory holding exactly the failed v4 artifact
-- (@scenario.json@) and a strict manifest (@manifest.json@) naming its
-- byte identity, discovery seed, shrink evidence, semantic coverage, and
-- the ordinary green regression it was promoted into. The manifest schema
-- is the reference's, so either language replays the other's bundles.
module Petrus.Testing.Dst.Failure
  ( -- * Contract
    bundleFormat
  , bundleVersion
  , artifactFile
  , manifestFile
  , replayCommand
  , failureProperty
  , promotedFixture
  , FailureLimits (..)
  , defaultLimits

    -- * Bundles
  , retainFailureBundle
  , replayFailureBundle
  , replayFailureBundleWith
  , demonstrateFailureBundle
  , validateManifest
  , findLivelockMinimum
  , livelockReproduces

    -- * Retention safety
  , assertRetentionSafe
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isSpace, toLower)
import Data.IORef
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Hedgehog (Property, assert, evalIO, forAll, property, withShrinks, withTests)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Internal.Property (Property (..))
import Hedgehog.Internal.Report (Report (..), Result (..))
import Hedgehog.Internal.Runner (checkReport)
import Hedgehog.Internal.Seed qualified as Seed
import Hedgehog.Range qualified as Range
import Petrus.Json (Json (..))
import Petrus.Testing.Dst (AnyArtifact (..), DstFailure, ToJson (..), decodeArtifact, decodeErrorMessage, encodeArtifact, failureMessage, loadStrictJson)
import Petrus.Testing.Dst.Campaign.Support
import Petrus.Testing.Dst.Decode
import Petrus.Testing.Dst.Engine.GeneratedRuntimeQualification (buildLivelockFailureArtifact, semanticLabels)
import Petrus.Testing.Dst.Engine.ReplayWorld (replayPath)
import System.Directory
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, (</>))
import System.Info (fullCompilerVersion)
import System.IO.Temp (createTempDirectory, withTempDirectory)

-- ---------------------------------------------------------------------------
-- Contract

bundleFormat, artifactFile, manifestFile, failureProperty :: Text
bundleFormat = "petrus-dst-failure-bundle"
artifactFile = "scenario.json"
manifestFile = "manifest.json"
failureProperty = "fair phase must not repeat an unchanged eligible frontier until action exhaustion"

bundleVersion :: Integer
bundleVersion = 1

-- | @REPLAY_COMMAND@: the manifest's cross-language replay instruction.
-- The schema pins this literal, so a Haskell-retained bundle names the
-- reference's route too; @petrus-dst-world failure replay BUNDLE@ is the
-- Haskell twin of the same instruction.
replayCommand :: [Text]
replayCommand = ["uv", "run", "python", "-m", "tests.dst.failure", "replay", "{bundle}"]

-- | @PROMOTED_FIXTURE@, relative to the reference checkout.
promotedFixture :: FilePath
promotedFixture = "tests/dst/fixtures/generated-runtime-minimized-fair-regression-v4.json"

-- | @MANIFEST_BYTES@ and @BUNDLE_BYTES@ (the reference's tests monkeypatch
-- them; these tests pass a smaller record).
data FailureLimits = FailureLimits {manifestBytes :: Int, bundleBytes :: Integer}

defaultLimits :: FailureLimits
defaultLimits = FailureLimits {manifestBytes = 262144, bundleBytes = 4456448}

-- ---------------------------------------------------------------------------
-- The manifest schema (@FailureManifest@), as its model_dump

maxSafeInteger :: Integer
maxSafeInteger = 2 ^ (53 :: Int) - 1

hexLower :: Char -> Bool
hexLower c = isDigit c || (c >= 'a' && c <= 'f')

validDigest :: Text -> Bool
validDigest s = T.isPrefixOf "sha256:" s && T.length s == 71 && T.all hexLower (T.drop 7 s)

-- | One object in model field order.
objectOf :: [(Text, Path -> Json -> Parser Json)] -> Text -> Path -> Json -> Parser Json
objectOf fields name at v = do
  f <- model name (map fst fields) at v
  Object <$> forM fields (\(k, p) -> (k,) <$> field f k p)

str :: Maybe Int -> Maybe Int -> Path -> Json -> Parser Json
str lo hi at v = String <$> pStrLen lo hi at v

int :: Integer -> Integer -> Path -> Json -> Parser Json
int lo hi at v = Int <$> pIntRange (Just lo) (Just hi) at v

bool :: Path -> Json -> Parser Json
bool at v = Bool <$> pBool at v

literal :: Json -> Path -> Json -> Parser Json
literal expected = pLiteral [(expected, expected)]

digestField :: Text -> Path -> Json -> Parser Json
digestField message at v = do
  s <- pStr at v
  unless (validDigest s) $ valueError at message
  Right (String s)

stringList :: Maybe Int -> Maybe Int -> (Path -> Json -> Parser Json) -> Path -> Json -> Parser Json
stringList lo hi p at v = Array <$> pListLen lo hi p at v

-- | @FailureManifest.model_validate(value, strict=True).model_dump()@.
validateManifest :: Json -> Either SchemaError Json
validateManifest = objectOf manifestFields "FailureManifest" []
  where
    manifestFields =
      [ ("format", literal (String bundleFormat))
      , ("version", literal (Int bundleVersion))
      , ("property", str (Just 1) (Just 512))
      , ("discovery_seed", int 0 maxSafeInteger)
      , ("runtime", objectOf runtimeFields "RuntimeIdentity")
      , ("shrink", objectOf shrinkFields "ShrinkEvidence")
      , ("artifact", objectOf artifactFields "ArtifactEvidence")
      , ("replay", objectOf replayFields "ReplayInstruction")
      , ("semantic_coverage", coverage)
      , ("promotion", objectOf promotionFields "PromotionEvidence")
      ]
    runtimeFields =
      [ ("commit", commit)
      , ("dirty", bool)
      , ("python", str (Just 1) (Just 128))
      , ("dependencies", stringList (Just 1) (Just 16) (objectOf [("name", str (Just 1) (Just 128)), ("version", str (Just 1) (Just 256))] "DependencyIdentity"))
      ]
    commit at v = do
      s <- pStr at v
      unless (T.length s == 40 && T.all hexLower s) $
        valueError at "failure bundle commit must be 40 lowercase hexadecimal characters"
      Right (String s)
    shrinkFields =
      [ ("parent_scenario_id", str (Just 1) (Just 256))
      , ("parent_artifact_digest", digestField "failure bundle artifact digest must be sha256:<64 lowercase hex>")
      , ("parent_operations", int 1 100000)
      , ("parent_prefix_operations", int 1 100000)
      , ("parent_bytes", int 1 4194304)
      , ("minimized_operations", int 1 100000)
      , ("minimized_prefix_operations", int 1 100000)
      , ("minimized_bytes", int 1 4194304)
      , ("removed_retry", bool)
      , ("removed_perturbations", stringList Nothing (Just 64) (str Nothing Nothing))
      ]
    artifactFields =
      [ ("path", literal (String artifactFile))
      , ("bytes", int 1 4194304)
      , ("digest", digestField "failure bundle artifact digest must be sha256:<64 lowercase hex>")
      , ("format", literal (String "petrus-dst-world"))
      , ("version", literal (Int 4))
      , ("api", literal (String "petrus.testing.dst/v4"))
      , ("scenario_id", str (Just 1) (Just 256))
      , ("disposition", pLiteral [(String d, String d) | d <- ["budget_exhausted", "invariant_failure"]])
      , ("failure", \at v -> maybe (Right v) Left (jsonValueRecursion 1 at v))
      ]
    replayFields =
      [ ("cwd", literal (String "repository-root"))
      , ("command", command)
      ]
    command at v = do
      items <- pListLen (Just 7) (Just 7) pStr at v
      unless (items == replayCommand) $
        valueError at "failure bundle replay command must use the repository-owned replay route"
      Right (Array (map String items))
    coverage at = \case
      Object members -> Object <$> forM members (\(k, x) -> (k,) <$> stringList Nothing Nothing (str Nothing Nothing) (LKey k : at) x)
      _ -> failAt at "dict_type" "Input should be a valid dictionary"
    promotionFields =
      [ ("status", literal (String "ordinary-green-regression"))
      , ("path", str (Just 1) (Just 512))
      , ("digest", digestField "failure bundle promotion digest must be sha256:<64 lowercase hex>")
      , ("scenario_id", str (Just 1) (Just 256))
      , ("disposition", literal (String "quiescent"))
      ]

manifestOrRefuse :: Json -> IO Json
manifestOrRefuse value = case validateManifest value of
  Right manifest -> pure manifest
  Left problem -> throwIO (ToolError (renderSchemaError "FailureManifest" problem))

-- ---------------------------------------------------------------------------
-- Artifact views

artifactJson :: AnyArtifact -> Json
artifactJson = toJson

expectedOf :: Text -> Json -> Json
expectedOf key = member key . member "expected"

isCurrent :: AnyArtifact -> Bool
isCurrent = \case
  ArtifactV4 _ -> True
  _ -> False

encoded :: AnyArtifact -> IO ByteString
encoded = orRefuse . encodeArtifact

-- | @_fair_prefix_operations(artifact)@.
fairPrefixOperations :: Json -> IO Integer
fairPrefixOperations value =
  case [p | op <- listOf "operations" value, member "kind" op == String "begin_fair", Int p <- [member "position" op]] of
    p : _ -> pure (p + 1)
    [] -> refuse "DST fair-liveness failure has no fair-phase operation"

coverageOf :: AnyArtifact -> Json
coverageOf artifact =
  Object [(name, Array (map String (Set.toAscList values))) | (name, values) <- Map.toList (semanticLabels artifact)]

-- | @_canonical_file(path)@.
canonicalFile :: FilePath -> IO ByteString
canonicalFile file = do
  payload <- BS.readFile file
  pure (if BC.isSuffixOf "\n" payload then BS.init payload else payload)

-- | @_repository_path(value)@: a promoted path inside the reference
-- checkout.
repositoryPath :: Text -> IO FilePath
repositoryPath value = do
  let relative = T.unpack value
  when (isAbsolute relative || ".." `elem` splitDirectories relative) $
    refuse "DST promoted regression path must remain within the repository"
  (</> relative) <$> upstreamRoot

-- | The bundle's runtime identity: the reference's Python version and
-- Hypothesis / petrus-runtime distributions become GHC's version and the
-- Hedgehog / petrus-dst packages.
manifestRuntime :: IO Json
manifestRuntime = do
  (commit, dirty) <- repositoryRoot >>= gitIdentity
  pure $
    Object
      [ ("commit", String commit)
      , ("dirty", Bool dirty)
      , ("python", String (T.pack (showVersion fullCompilerVersion)))
      , ("dependencies", Array [Object [("name", String n), ("version", String v)] | (n, v) <- runtimeIdentity, n /= "ghc"])
      ]

-- ---------------------------------------------------------------------------
-- Retention

-- | @retain_failure_bundle(...)@: validate and atomically retain one exact
-- failed artifact and manifest. Returns the manifest's model_dump.
retainFailureBundle :: FilePath -> AnyArtifact -> AnyArtifact -> Text -> Bool -> [Text] -> FilePath -> IO Json
retainFailureBundle destination artifact parent propertyName removedRetry removedPerturbations promotedPath = do
  exists <- doesPathExist destination
  when exists $ refuse ("DST failure bundle destination already exists: " <> T.pack destination)
  let value = artifactJson artifact
      disposition = expectedOf "disposition" value
      failure = expectedOf "failure" value
  when (disposition `notElem` [String "budget_exhausted", String "invariant_failure"] || failure == Null || not (isCurrent artifact)) $
    refuse "DST failure bundle requires one exact failed v4 artifact"
  seed <- case member "origin" value of
    Null -> refuse "DST failure bundle requires exact discovery provenance"
    origin -> pure (member "seed" origin)
  artifactBytes <- encoded artifact
  parentBytes <- encoded parent
  promotedBytes <- upstreamRoot >>= canonicalFile . (</> promotedPath)
  promoted <- case decodeArtifact promotedBytes of
    Right a@(ArtifactV4 _) -> pure (artifactJson a)
    Right _ -> refuse "DST promoted regression must use the current v4 artifact"
    Left problem -> refuse (decodeErrorMessage problem)
  when (expectedOf "disposition" promoted /= String "quiescent" || expectedOf "failure" promoted /= Null) $
    refuse "DST promoted regression must be an ordinary green quiescent artifact"
  orRefuse (assertRetentionSafe value "artifact")
  runtime <- manifestRuntime
  parentPrefix <- fairPrefixOperations (artifactJson parent)
  minimizedPrefix <- fairPrefixOperations value
  let parentValue = artifactJson parent
      count = Int . toInteger . length . listOf "operations"
      size = Int . toInteger . BS.length
      draft =
        Object
          [ ("format", String bundleFormat)
          , ("version", Int bundleVersion)
          , ("property", String propertyName)
          , ("discovery_seed", seed)
          , ("runtime", runtime)
          ,
            ( "shrink"
            , Object
                [ ("parent_scenario_id", member "scenario_id" parentValue)
                , ("parent_artifact_digest", String (sha256Digest parentBytes))
                , ("parent_operations", count parentValue)
                , ("parent_prefix_operations", Int parentPrefix)
                , ("parent_bytes", size parentBytes)
                , ("minimized_operations", count value)
                , ("minimized_prefix_operations", Int minimizedPrefix)
                , ("minimized_bytes", size artifactBytes)
                , ("removed_retry", Bool removedRetry)
                , ("removed_perturbations", Array (map String removedPerturbations))
                ]
            )
          ,
            ( "artifact"
            , Object
                [ ("path", String artifactFile)
                , ("bytes", size artifactBytes)
                , ("digest", String (sha256Digest artifactBytes))
                , ("format", member "format" value)
                , ("version", member "version" value)
                , ("api", member "api" value)
                , ("scenario_id", member "scenario_id" value)
                , ("disposition", disposition)
                , ("failure", failure)
                ]
            )
          , ("replay", Object [("cwd", String "repository-root"), ("command", Array (map String replayCommand))])
          , ("semantic_coverage", coverageOf artifact)
          ,
            ( "promotion"
            , Object
                [ ("status", String "ordinary-green-regression")
                , ("path", String (T.pack promotedPath))
                , ("digest", String (sha256Digest promotedBytes))
                , ("scenario_id", member "scenario_id" promoted)
                , ("disposition", String "quiescent")
                ]
            )
          ]
  manifest <- manifestOrRefuse draft
  orRefuse (assertRetentionSafe manifest "manifest")
  manifestBytes' <- orRefuse (canonicalDumps manifest)
  when (BS.length manifestBytes' > defaultLimits.manifestBytes) $
    refuse ("DST failure manifest has " <> tshow (BS.length manifestBytes') <> " bytes; limit is " <> tshow defaultLimits.manifestBytes)
  let total = toInteger (BS.length artifactBytes + BS.length manifestBytes' + 2)
  when (total > defaultLimits.bundleBytes) $
    refuse ("DST failure bundle has " <> tshow total <> " bytes; limit is " <> tshow defaultLimits.bundleBytes)
  let parentDirectory = takeDirectory destination
  createDirectoryIfMissing True parentDirectory
  temporary <- createTempDirectory parentDirectory ".petrus-dst-failure-"
  written <- try $ do
    BS.writeFile (temporary </> T.unpack artifactFile) (artifactBytes <> "\n")
    BS.writeFile (temporary </> T.unpack manifestFile) (manifestBytes' <> "\n")
    renameDirectory temporary destination
  case written of
    Right () -> pure manifest
    Left (e :: SomeException) -> do
      removePathForcibly temporary
      throwIO e

-- ---------------------------------------------------------------------------
-- Replay

-- | @replay_failure_bundle(bundle)@ with the reference's limits.
replayFailureBundle :: FilePath -> IO Json
replayFailureBundle = replayFailureBundleWith defaultLimits

-- | @replay_failure_bundle(bundle)@: verify bundle integrity, replay its
-- failure, and verify its promotion.
replayFailureBundleWith :: FailureLimits -> FilePath -> IO Json
replayFailureBundleWith limits bundle = do
  isDirectory <- doesDirectoryExist bundle
  names <- if isDirectory then Set.fromList <$> listDirectory bundle else pure Set.empty
  unless (isDirectory && names == Set.fromList (map T.unpack [artifactFile, manifestFile])) $
    refuse "DST failure bundle must contain exactly manifest.json and scenario.json"
  let manifestPath = bundle </> T.unpack manifestFile
      artifactPath = bundle </> T.unpack artifactFile
  manifestSize <- getFileSize manifestPath
  when (manifestSize > toInteger limits.manifestBytes + 1) $
    refuse ("DST failure manifest exceeds " <> tshow limits.manifestBytes <> " bytes")
  manifestPayload <- BS.readFile manifestPath
  manifestValue <- either (\e -> refuse ("invalid strict DST failure manifest: " <> e)) pure (loadStrictJson manifestPayload)
  manifest <- manifestOrRefuse manifestValue
  orRefuse (assertRetentionSafe manifest "manifest")
  let evidence = member "artifact" manifest
      shrink = member "shrink" manifest
      promotion = member "promotion" manifest
  artifactBytes <- canonicalFile artifactPath
  when (Int (toInteger (BS.length artifactBytes)) /= member "bytes" evidence || String (sha256Digest artifactBytes) /= member "digest" evidence) $
    refuse "DST failure artifact does not match its retained byte identity"
  sizes <- mapM (getFileSize . (bundle </>)) (Set.toList names)
  when (sum sizes > limits.bundleBytes) $
    refuse ("DST failure bundle exceeds " <> tshow limits.bundleBytes <> " bytes")
  artifact <- case decodeArtifact artifactBytes of
    Right a@(ArtifactV4 _) -> pure a
    Right _ -> refuse "DST failure bundle requires a current v4 artifact"
    Left problem -> refuse (decodeErrorMessage problem)
  let value = artifactJson artifact
  orRefuse (assertRetentionSafe value "artifact")
  let mismatched = refuse "DST failure artifact does not match its manifest expectations"
      before =
        or
          [ member "format" value /= member "format" evidence
          , member "version" value /= member "version" evidence
          , member "api" value /= member "api" evidence
          , member "scenario_id" value /= member "scenario_id" evidence
          , expectedOf "disposition" value /= member "disposition" evidence
          , expectedOf "failure" value == Null
          , expectedOf "failure" value /= member "failure" evidence
          , member "origin" value == Null
          , member "seed" (member "origin" value) /= member "discovery_seed" manifest
          , Int (toInteger (length (listOf "operations" value))) /= member "minimized_operations" shrink
          ]
  when before mismatched
  -- The reference evaluates the fair prefix inside the same condition, so
  -- a missing fair phase raises its own refusal only after the checks
  -- before it held.
  prefix <- fairPrefixOperations value
  when (Int prefix /= member "minimized_prefix_operations" shrink || member "semantic_coverage" manifest /= coverageOf artifact) mismatched
  failed <- replayed artifactPath
  when
    ( member "outcome" failed /= String "pass"
        || member "disposition" failed /= member "disposition" evidence
        || member "failure" failed /= expectedOf "failure" value
        || member "journal_digest" failed /= expectedOf "journal_digest" value
    )
    $ refuse "DST failure replay did not reproduce its exact retained outcome"
  promotedPath <- repositoryPath (text (member "path" promotion))
  promotedBytes <- canonicalFile promotedPath
  when (String (sha256Digest promotedBytes) /= member "digest" promotion) $
    refuse "DST promoted regression does not match its retained identity"
  promoted <- replayed promotedPath
  when
    ( member "outcome" promoted /= String "pass"
        || member "scenario_id" promoted /= member "scenario_id" promotion
        || member "disposition" promoted /= member "disposition" promotion
        || member "failure" promoted /= Null
    )
    $ refuse "DST promoted regression did not replay green"
  pure $
    Object
      [ ("artifact_digest", member "digest" evidence)
      , ("failure", member "failure" evidence)
      , ("failure_disposition", member "disposition" failed)
      , ("failure_journal_digest", member "journal_digest" failed)
      , ("format", String "petrus-dst-failure-replay-result")
      , ("outcome", String "pass")
      , ("promoted_scenario_id", member "scenario_id" promoted)
      , ("promotion_disposition", member "disposition" promoted)
      , ("scenario_id", member "scenario_id" failed)
      , ("version", Int 1)
      ]

-- | @replay_path(path)@ as its model_dump.
replayed :: FilePath -> IO Json
replayed file = replayPath file >>= either (refuse . failureMessage) (pure . toJson)

-- | @_replay_artifact(artifact, path)@.
replayArtifact :: AnyArtifact -> FilePath -> IO ()
replayArtifact artifact file = do
  bytes <- encoded artifact
  BS.writeFile file (bytes <> "\n")
  result <- replayed file
  let value = artifactJson artifact
  when
    ( member "outcome" result /= String "pass"
        || member "disposition" result /= expectedOf "disposition" value
        || member "failure" result /= expectedOf "failure" value
        || member "journal_digest" result /= expectedOf "journal_digest" value
    )
    $ refuse "DST generated failure did not replay exactly"

-- ---------------------------------------------------------------------------
-- Demonstration and shrinking

buildLivelock :: FilePath -> Bool -> [Text] -> IO AnyArtifact
buildLivelock root retry perturbations =
  buildLivelockFailureArtifact root retry perturbations >>= either (refuse . dstMessage) pure
  where
    dstMessage :: DstFailure -> Text
    dstMessage = failureMessage

-- | @reproduces(candidate)@: does this candidate still exhaust its fair
-- budget?
livelockReproduces :: FilePath -> Bool -> [Text] -> IO Bool
livelockReproduces root retry perturbations = do
  artifact <- buildLivelock root retry perturbations
  pure (expectedOf "disposition" (artifactJson artifact) == String "budget_exhausted")

-- | Hypothesis's @find(strategy, reproduces, settings(max_examples=20,
-- derandomize=True, phases=(generate, shrink)))@ as a Hedgehog property
-- that fails on a reproducing candidate: Hedgehog generates up to 20
-- candidates from a fixed seed, shrinks the first reproducing one, and the
-- last failing candidate it ran is the minimum. Each candidate builds under
-- @root/<label>-<n>@.
findLivelockMinimum :: FilePath -> Text -> IO (Bool, [Text])
findLivelockMinimum root labelPrefix = do
  counter <- newIORef (0 :: Int)
  minimum' <- newIORef Nothing
  let candidate = do
        retry <- forAll Gen.bool
        perturbations <- forAll (Gen.list (Range.linear 0 3) (Gen.element ["observe", "crash_reload"]))
        reproduces <- evalIO $ do
          n <- atomicModifyIORef' counter (\k -> (k + 1, k))
          found <- livelockReproduces (root </> T.unpack (labelPrefix <> "-" <> tshow n)) retry perturbations
          when found $ writeIORef minimum' (Just (retry, perturbations))
          pure found
        assert (not reproduces)
      search :: Property
      search = withShrinks 1000 . withTests 20 $ property candidate
  report <- checkReport search.propertyConfig 0 (Seed.from 19003) search.propertyTest (const (pure ()))
  found <- readIORef minimum'
  case (report.reportStatus, found) of
    (Failed _, Just best) -> pure best
    _ -> refuse "DST failure search found no reproducing candidate"

-- | @demonstrate_failure_bundle(destination)@: rehearse reproduce, replay,
-- shrink, retain, replay, and promotion.
demonstrateFailureBundle :: FilePath -> IO Json
demonstrateFailureBundle destination = do
  exists <- doesPathExist destination
  when exists $ refuse ("DST failure bundle destination already exists: " <> T.pack destination)
  let parentDirectory = takeDirectory destination
  createDirectoryIfMissing True parentDirectory
  manifest <- withTempDirectory parentDirectory "petrus-dst-failure-demo-" $ \root -> do
    let removed = ["observe", "crash_reload", "observe"]
    parent <- buildLivelock (root </> "parent") True removed
    replayArtifact parent (root </> "parent-replay.json")
    minimized <- findLivelockMinimum root "shrink"
    unless (minimized == (False, [])) $
      refuse ("DST failure demonstration did not reach the accepted minimum: " <> tshow minimized)
    artifact <- buildLivelock (root </> "minimized") (fst minimized) (snd minimized)
    replayArtifact artifact (root </> "minimized-replay.json")
    retainFailureBundle destination artifact parent failureProperty True removed promotedFixture
  _ <- replayFailureBundle destination
  pure manifest

-- ---------------------------------------------------------------------------
-- Retention safety

sensitiveKeys :: [Text]
sensitiveKeys =
  [ "access_token"
  , "api_key"
  , "authorization"
  , "client_secret"
  , "cookie"
  , "credential"
  , "credentials"
  , "dsn"
  , "password"
  , "private_key"
  , "refresh_token"
  , "secret"
  ]

-- | @re.sub(r"[^a-z0-9]+", "_", key.lower()).strip("_")@.
normalizeKey :: Text -> Text
normalizeKey key = T.dropAround (== '_') (T.pack (collapse (T.unpack (T.toLower key))))
  where
    keep c = isAsciiLower c || isDigit c
    collapse = \case
      [] -> []
      c : rest
        | keep c -> c : collapse rest
        | otherwise -> '_' : collapse (dropWhile (not . keep) rest)

sensitiveKey :: Text -> Bool
sensitiveKey key =
  let normalized = normalizeKey key
   in normalized `elem` sensitiveKeys || any (\s -> ("_" <> s) `T.isSuffixOf` normalized) sensitiveKeys

-- | Python's @\\s@ over @str@: 'str.isspace'.
pySpace :: Char -> Bool
pySpace c = isSpace c || (c >= '\x1c' && c <= '\x1f') || c == '\x85'

pyWord :: Char -> Bool
pyWord c = isAlphaNum c || c == '_'

-- | Any of the reference's @_SENSITIVE_VALUES@ patterns searches true.
sensitiveValue :: Text -> Bool
sensitiveValue value = any (\suffix -> privateKey suffix || github suffix) (suffixes s) || bearer
  where
    s = T.unpack value
    suffixes xs = case xs of
      [] -> [[]]
      _ : rest -> xs : suffixes rest
    -- -----BEGIN [A-Z0-9 ]*PRIVATE KEY-----
    privateKey xs = case stripPrefix' "-----BEGIN " xs of
      Just rest ->
        let (run, after) = span (\c -> isAsciiUpper c || isDigit c || c == ' ') rest
         in "PRIVATE KEY" `isSuffixOf` run && take 5 after == "-----"
      Nothing -> False
    -- (?:gh[pousr]_|github_pat_)\S+
    github xs = case xs of
      'g' : 'h' : c : '_' : next : _ | c `elem` ("pousr" :: String) -> not (pySpace next)
      _ -> case stripPrefix' "github_pat_" xs of
        Just (next : _) -> not (pySpace next)
        _ -> False
    -- (?i)\bbearer\s+\S+
    bearer = any matchesAt (zip3 [0 :: Int ..] (' ' : s) (tails' s))
    matchesAt (i, previous, rest) =
      map toLower (take 6 rest) == "bearer"
        && (i == 0 || not (pyWord previous))
        && case span pySpace (drop 6 rest) of
          (_ : _, next : _) -> not (pySpace next)
          _ -> False
    tails' xs = case xs of
      [] -> [[]]
      _ : rest -> xs : tails' rest

stripPrefix' :: String -> String -> Maybe String
stripPrefix' prefix xs
  | take (length prefix) xs == prefix = Just (drop (length prefix) xs)
  | otherwise = Nothing

-- | @[A-Za-z][A-Za-z0-9+.-]*://[^/@\s]+:[^/@\s]+@@ searched over the value.
credentialUrl :: Text -> Bool
credentialUrl value = go "" (T.unpack value)
  where
    schemeChar c = isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ("+.-" :: String)
    -- @before@ is the reversed text already passed.
    go before xs = case xs of
      [] -> False
      ':' : '/' : '/' : rest | scheme before && authority rest -> True
      c : rest -> go (c : before) rest
    scheme before =
      let run = takeWhile schemeChar before
       in any (\c -> isAsciiUpper c || isAsciiLower c) run
    authority rest =
      let (run, after) = break (\c -> c == '/' || c == '@' || pySpace c) rest
          inner = drop 1 (take (length run - 1) run)
       in take 1 after == "@" && length run >= 3 && ':' `elem` inner

-- | @_assert_retention_safe(value, subject)@.
assertRetentionSafe :: Json -> Text -> Either Text ()
assertRetentionSafe root subject = visit root "$"
  where
    visit item at = case item of
      Object members -> forM_ members $ \(key, child) -> do
        when (sensitiveKey key) $
          Left ("DST " <> subject <> " has a credential-like field at " <> at <> "." <> key)
        visit child (at <> "." <> key)
      Array items -> forM_ (zip [0 :: Int ..] items) $ \(index, child) -> visit child (at <> "[" <> tshow index <> "]")
      String s | sensitiveValue s || credentialUrl s -> Left ("DST " <> subject <> " has a credential-like value at " <> at)
      _ -> Right ()

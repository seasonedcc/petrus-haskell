{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Bounded deterministic simulation campaigns: a port of the reference's
-- @tests/dst/campaign.py@.
--
-- The reference runs each generated profile as a pytest node in a child
-- process, seeded through Hypothesis, and retains one bounded report of the
-- reach the children recorded. Here each profile is a Hedgehog state
-- machine ("Petrus.Testing.Dst.Campaign.Machines") and the child is
-- @petrus-dst-world campaign-profile NAME@. The tiers, budgets, seeds,
-- environment variables, case summaries, and report are the reference's.
module Petrus.Testing.Dst.Campaign
  ( -- * Profiles and tiers
    Tier (..)
  , tierText
  , parseTier
  , CampaignProfile (..)
  , campaignProfiles
  , lookupProfile
  , profileExamples
  , profileSteps
  , unmodeledBoundaries

    -- * Settings
  , tierEnv
  , casePathEnv
  , seedEnv
  , CampaignSettings (..)
  , campaignSettings
  , campaignSettingsFrom

    -- * Case summaries
  , caseSummaryBytes
  , caseSummary
  , recordCampaignCase

    -- * Running a campaign
  , reportFormat
  , reportVersion
  , reportBytes
  , campaignSeed
  , validateCampaignId
  , ProfileRun (..)
  , ProfileOutcome (..)
  , CampaignRunner (..)
  , processRunner
  , repositoryIdentity
  , runCampaign
  ) where

import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (shiftL, (.|.))
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub)
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps, lookupMember, parseJson, pythonLoads)
import Petrus.Testing.Dst (AnyArtifact, encodeArtifact, toJson)
import Petrus.Testing.Dst.Campaign.Support
import Petrus.Testing.Dst.Process (Finish (..), captureWithin, killNow)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Profiles and tiers

data Tier = Ordinary | Scheduled
  deriving stock (Eq, Show)

tierText :: Tier -> Text
tierText = \case
  Ordinary -> "ordinary"
  Scheduled -> "scheduled"

-- | @_tier@.
parseTier :: Text -> Either Text Tier
parseTier = \case
  "ordinary" -> Right Ordinary
  "scheduled" -> Right Scheduled
  other -> Left ("unknown DST campaign tier " <> pyRepr other)

-- | @CampaignProfile@. The reference's @node@ is the pytest node it runs;
-- here it is the Haskell child command.
data CampaignProfile = CampaignProfile
  { name :: Text
  , node :: Text
  , ordinaryExamples :: Int
  , ordinarySteps :: Int
  }
  deriving stock (Eq, Show)

-- | @CampaignProfile.examples(tier)@.
profileExamples :: Tier -> CampaignProfile -> Int
profileExamples tier p = if tier == Ordinary then p.ordinaryExamples else p.ordinaryExamples * 4

-- | @CampaignProfile.steps(tier)@.
profileSteps :: Tier -> CampaignProfile -> Int
profileSteps tier p = if tier == Ordinary then p.ordinarySteps else p.ordinarySteps + 2

-- | @CAMPAIGN_PROFILES@.
campaignProfiles :: [CampaignProfile]
campaignProfiles =
  [ profile "delivery-broad" 30 8
  , profile "delivery-focused" 20 6
  , profile "runtime-broad" 16 5
  , profile "runtime-focused" 10 4
  ]
  where
    profile name = CampaignProfile name ("petrus-dst-world campaign-profile " <> name)

-- | @_profile(name)@.
lookupProfile :: Text -> Either Text CampaignProfile
lookupProfile name = case [p | p <- campaignProfiles, p.name == name] of
  p : _ -> Right p
  [] -> Left ("unknown DST campaign profile " <> pyRepr name)

-- | @UNMODELED_BOUNDARIES@.
unmodeledBoundaries :: [Text]
unmodeledBoundaries =
  [ "database-server power loss and PostgreSQL implementation behavior"
  , "operating-system scheduling and authority-process death"
  , "pinned Absurd transport, Worker process, and lease implementation behavior"
  , "ZeroMQ socket, dispatch-server process, and IPC implementation behavior"
  , "application-owned provider, credential, human-decision, and network authority"
  ]

-- ---------------------------------------------------------------------------
-- Settings

tierEnv, casePathEnv, seedEnv :: String
tierEnv = "PETRUS_DST_CAMPAIGN_TIER"
casePathEnv = "PETRUS_DST_CAMPAIGN_CASES"
seedEnv = "PETRUS_DST_CAMPAIGN_SEED"

-- | The reference's Hypothesis @settings@: @max_examples@ is the Hedgehog
-- test count, @stateful_step_count@ the state machine's step count, and
-- @derandomize=True@ a fixed seed. @database=None@ and @deadline=None@ hold
-- for Hedgehog by construction (it keeps no example database and has no
-- deadline).
data CampaignSettings = CampaignSettings
  { profile :: CampaignProfile
  , tier :: Tier
  , maxExamples :: Int
  , statefulStepCount :: Int
  , derandomize :: Bool
  , seed :: Integer
  -- ^ The Hedgehog seed: the campaign seed when recording, otherwise the
  -- profile's fixed derandomized seed.
  , recording :: Bool
  }
  deriving stock (Eq, Show)

-- | @campaign_settings(profile_name)@ from the process environment.
campaignSettings :: Text -> IO CampaignSettings
campaignSettings name = getEnvironment >>= orRefuse . campaignSettingsFrom name

-- | @campaign_settings@ over an explicit environment.
campaignSettingsFrom :: Text -> [(String, String)] -> Either Text CampaignSettings
campaignSettingsFrom name environment = do
  p <- lookupProfile name
  tier <- parseTier (maybe "ordinary" T.pack (lookup tierEnv environment))
  let recording = isJust (lookup casePathEnv environment)
      seedValue = lookup seedEnv environment
  when (tier == Scheduled && not recording) $
    Left "scheduled DST settings must run through tests.dst.campaign"
  when (recording && not (isJust seedValue)) $
    Left "campaign case recording requires an exact campaign seed"
  let derandomize = tier == Ordinary && not recording
  seed <-
    if derandomize
      then campaignSeed "derandomized" p.name
      else maybe (Left "campaign case recording requires an exact campaign seed") Right (seedValue >>= readMaybe)
  Right
    CampaignSettings
      { profile = p
      , tier
      , maxExamples = profileExamples tier p
      , statefulStepCount = profileSteps tier p
      , derandomize
      , seed
      , recording
      }

-- ---------------------------------------------------------------------------
-- Case summaries

-- | @CASE_SUMMARY_BYTES@.
caseSummaryBytes :: Int
caseSummaryBytes = 16384

-- | The payload-free semantic summary of one replayed artifact, with its
-- newline: the body of @record_campaign_case@.
caseSummary :: CampaignProfile -> Integer -> AnyArtifact -> Either Text ByteString
caseSummary p seed artifact = do
  encoded <- encodeArtifact artifact
  let value = toJson artifact
      ops = listOf "operations" value
      kindOf o = text (member "kind" o)
      executes = [o | o <- ops, kindOf o == "execute"]
      expected = member "expected" value
      summary =
        Object
          [ ("action_dispositions", strings [text (member "disposition" (member "result" o)) | o <- executes])
          , ("artifact_bytes", Int (toInteger (BS.length encoded)))
          , ("artifact_digest", String (sha256Digest encoded))
          , ("campaign_profile", String p.name)
          , ("campaign_seed", Int seed)
          , ("checker_triggers", strings [t | e <- listOf "checks" expected, String t <- [member "trigger" (member "value" e)]])
          , ("commands", strings [text (member "name" (member "command" o)) | o <- executes])
          , ("crash_cuts", strings [text (member "cut" o) | o <- ops, kindOf o == "crash"])
          , ("disposition", member "disposition" expected)
          , ("faults", strings [faultLabel (member "fault" o) | o <- ops, kindOf o == "activate_fault"])
          , ("journal_digest", member "journal_digest" expected)
          , ("operation_kinds", strings (map kindOf ops))
          , ("operations", Int (toInteger (length ops)))
          , ("profile", member "profile" value)
          , ("profile_resource_limits", fromMaybe (Object []) (lookupMember "profile_resources" (member "budget" value)))
          ]
  bytes <- canonicalDumps summary
  let line = bytes <> "\n"
  when (BS.length line > caseSummaryBytes) $
    Left ("DST campaign case summary has " <> tshow (BS.length line) <> " bytes; limit is " <> tshow caseSummaryBytes)
  Right line
  where
    strings = Array . map String . Set.toAscList . Set.fromList
    faultLabel f = text (member "name" f) <> "@" <> text (member "target" f)

-- | @record_campaign_case(profile_name, artifact)@: append one summary
-- when the environment names a case log.
recordCampaignCase :: Text -> AnyArtifact -> IO ()
recordCampaignCase name artifact = do
  pathValue <- lookupEnv casePathEnv
  forM_ pathValue $ \path -> do
    p <- orRefuse (lookupProfile name)
    seedValue <- lookupEnv seedEnv
    seed <- maybe (refuse "campaign case recording requires an exact campaign seed") pure (seedValue >>= readMaybe)
    line <- orRefuse (caseSummary p seed artifact)
    BS.appendFile path line

-- ---------------------------------------------------------------------------
-- Running a campaign

reportFormat :: Text
reportFormat = "petrus-dst-campaign-report"

reportVersion :: Integer
reportVersion = 1

reportBytes :: Int
reportBytes = 1048576

-- | @campaign_seed(campaign_id, profile_name)@: the first four bytes,
-- big-endian, of @sha256(json.dumps([format, version, id, profile]))@.
campaignSeed :: Text -> Text -> Either Text Integer
campaignSeed campaignId name = do
  validateCampaignId campaignId
  _ <- lookupProfile name
  payload <-
    either (Left . tshow) Right $
      dumps compact {ensureAscii = True} (Array [String reportFormat, Int reportVersion, String campaignId, String name])
  let digest = BA.unpack (hash payload :: Digest SHA256)
  Right (foldl (\acc b -> acc `shiftL` 8 .|. toInteger b) 0 (take 4 digest))

-- | @_validate_campaign_id@: @^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$@.
validateCampaignId :: Text -> Either Text ()
validateCampaignId value = case T.uncons value of
  Just (c, rest)
    | alnum c && T.length rest <= 127 && T.all (\x -> alnum x || x `elem` ("_.:-" :: String)) rest -> Right ()
  _ -> Left "DST campaign id must be 1-128 normalized characters"
  where
    alnum x = isAsciiLower x || isAsciiUpper x || isDigit x

-- | One profile's child run.
data ProfileRun = ProfileRun
  { profile :: CampaignProfile
  , tier :: Tier
  , casesPath :: FilePath
  , seed :: Integer
  , timeoutSeconds :: Int
  }

-- | A child's outcome: its exit code and output, or a timeout with the
-- output so far.
data ProfileOutcome
  = Completed Int Text Text
  | TimedOut Text Text

-- | The campaign's effects. The reference's tests monkeypatch
-- @subprocess.run@, @repository_identity@, and @CASE_SUMMARY_BYTES@; here
-- they are fields.
data CampaignRunner = CampaignRunner
  { runProfile :: ProfileRun -> IO ProfileOutcome
  , repository :: IO Json
  , summaryBytes :: Int
  }

-- | Run each profile as @EXECUTABLE campaign-profile NAME@ in the
-- repository root with the campaign environment. At its timeout the child
-- is killed (SIGKILL) and its output collected, as @subprocess.run(...,
-- timeout=)@ does.
processRunner :: FilePath -> IO CampaignRunner
processRunner executable = do
  root <- repositoryRoot
  pure
    CampaignRunner
      { runProfile = \run -> do
          environment <- getEnvironment
          let overrides =
                [ (tierEnv, T.unpack (tierText run.tier))
                , (casePathEnv, run.casesPath)
                , (seedEnv, show run.seed)
                ]
              merged = overrides <> [(k, v) | (k, v) <- environment, k `notElem` map fst overrides]
          (finish, out, err) <-
            captureWithin
              (proc executable ["campaign-profile", T.unpack run.profile.name]) {cwd = Just root, env = Just merged}
              (run.timeoutSeconds * 1000000)
              killNow
          pure $ case finish of
            Exited code -> Completed code out err
            Escalated _ -> TimedOut out err
      , repository = repositoryIdentity root
      , summaryBytes = caseSummaryBytes
      }

-- | @repository_identity()@.
repositoryIdentity :: FilePath -> IO Json
repositoryIdentity root = do
  (commit, dirty) <- gitIdentity root
  pure (Object [("commit", String commit), ("dirty", Bool dirty)])

-- | @run_campaign@: run the selected profiles serially and retain one
-- bounded report; the exit code is 0 when every profile passed in time.
runCampaign :: CampaignRunner -> Tier -> Text -> [Text] -> FilePath -> IO Int
runCampaign runner tier campaignId names reportPath = do
  profiles <- orRefuse $ do
    validateCampaignId campaignId
    when (null names) $ Left "a DST campaign must select at least one profile"
    when (length names /= length (nub names)) $ Left "a DST campaign cannot select a profile more than once"
    traverse lookupProfile names
  let profileTimeout = if tier == Ordinary then 60 else 120
      totalTimeout = profileTimeout * length profiles + 30
  started <- getCurrentTime
  results <- withSystemTempDirectory "petrus-dst-campaign-" $ \root ->
    forM profiles $ \p -> do
      seed <- orRefuse (campaignSeed campaignId p.name)
      let casesPath = root </> T.unpack p.name <> ".jsonl"
          expectedCases = profileExamples tier p
          caseLimit = expectedCases * 10
      profileStarted <- getCurrentTime
      outcome <- runner.runProfile ProfileRun {profile = p, tier, casesPath, seed, timeoutSeconds = profileTimeout}
      elapsed <- millisSince profileStarted
      loaded <- loadCases casesPath (caseLimit * runner.summaryBytes)
      let cases = either (const []) id loaded
      case outcome of
        Completed code out err -> do
          let (verdict, detail) = case loaded of
                _ | code /= 0 -> ("pytest_failure", Just ("pytest exited " <> tshow code))
                Left problem -> ("case_budget_exhausted", Just problem)
                Right recorded
                  | length recorded < expectedCases ->
                      ("incomplete", Just ("recorded " <> tshow (length recorded) <> " cases; expected at least " <> tshow expectedCases))
                  | length recorded > caseLimit ->
                      ("case_budget_exhausted", Just ("recorded " <> tshow (length recorded) <> " cases; limit is " <> tshow caseLimit))
                  | otherwise -> ("pass", Nothing)
          when (verdict /= "pass") (showFailure p.name out err)
          (verdict == "pass",) <$> profileResult p tier seed elapsed cases verdict detail
        TimedOut out err -> do
          showFailure p.name out err
          (False,) <$> profileResult p tier seed elapsed cases "timeout" (Just ("exceeded " <> tshow profileTimeout <> " seconds"))
  elapsed <- millisSince started
  repository <- runner.repository
  let passed = all fst results && elapsed <= toInteger totalTimeout * 1000
      selected = map (.name) profiles
      report =
        Object
          [
            ( "bounds"
            , Object
                [ ("artifact_bytes_per_scenario", Int 4194304)
                , ("case_summary_bytes", Int (toInteger runner.summaryBytes))
                , ("concurrency", Int 1)
                , ("profile_timeout_seconds", Int (toInteger profileTimeout))
                , ("profiles", Int (toInteger (length profiles)))
                , ("report_bytes", Int (toInteger reportBytes))
                , ("total_timeout_seconds", Int (toInteger totalTimeout))
                ]
            )
          , ("campaign_id", String campaignId)
          , ("deselected_profiles", Array [String p.name | p <- campaignProfiles, p.name `notElem` selected])
          , ("elapsed_ms", Int elapsed)
          , ("format", String reportFormat)
          , ("outcome", String (if passed then "pass" else "fail"))
          , ("profiles", Array (map snd results))
          , ("repository", repository)
          , ("runtime", Object [(k, String v) | (k, v) <- runtimeIdentity])
          , ("tier", String (tierText tier))
          , ("unmodeled_boundaries", Array (map String unmodeledBoundaries))
          , ("version", Int reportVersion)
          ]
  encoded <- orRefuse (prettyDumps report)
  let bytes = encoded <> "\n"
  when (BS.length bytes > reportBytes) $
    refuse ("DST campaign report has " <> tshow (BS.length bytes) <> " bytes; limit is " <> tshow reportBytes)
  createDirectoryIfMissing True (takeDirectory reportPath)
  BS.writeFile reportPath bytes
  pure (if passed then 0 else 1)
  where
    millisSince t = do
      now <- getCurrentTime
      pure (round (realToFrac (diffUTCTime now t) * 1000 :: Double))

-- | @_profile_result@.
profileResult :: CampaignProfile -> Tier -> Integer -> Integer -> [Json] -> Text -> Maybe Text -> IO Json
profileResult p tier seed elapsed cases verdict detail = do
  forM_ cases $ \c ->
    when (member "campaign_profile" c /= String p.name || member "campaign_seed" c /= Int seed) $
      refuse ("campaign case identity mismatch for " <> p.name)
  let union key = Array (map String (Set.toAscList (Set.fromList (concatMap (texts . member key) cases))))
      sizes = [n | c <- cases, Int n <- [member "artifact_bytes" c]]
      limits = case reverse cases of
        c : _ -> member "profile_resource_limits" c
        [] -> Object []
  pure $
    Object $
      [ ("artifact_bytes_max", Int (if null sizes then 0 else maximum sizes))
      , ("case_summaries_limit", Int (toInteger (profileExamples tier p * 10)))
      , ("cases", Int (toInteger (length cases)))
      , ("elapsed_ms", Int elapsed)
      , ("examples_target", Int (toInteger (profileExamples tier p)))
      , ("node", String p.node)
      , ("outcome", String verdict)
      , ("profile", String p.name)
      , ("profile_resource_limits", limits)
      , ("seed", Int seed)
      ,
        ( "semantic_reach"
        , Object
            [ ("action_dispositions", union "action_dispositions")
            , ("checker_triggers", union "checker_triggers")
            , ("commands", union "commands")
            , ("crash_cuts", union "crash_cuts")
            , ("dispositions", Array (map String (Set.toAscList (Set.fromList [text (member "disposition" c) | c <- cases]))))
            , ("faults", union "faults")
            , ("operation_kinds", union "operation_kinds")
            ]
        )
      , ("stateful_steps_limit", Int (toInteger (profileSteps tier p)))
      ]
        <> [("failure", String d) | Just d <- [detail]]

-- | @_load_cases@: the case log, refused above its byte limit.
loadCases :: FilePath -> Int -> IO (Either Text [Json])
loadCases path limit = do
  exists <- doesFileExist path
  if not exists
    then pure (Right [])
    else do
      size <- getFileSize path
      if size > toInteger limit
        then pure (Left ("DST campaign case log has " <> tshow size <> " bytes; limit is " <> tshow limit))
        else do
          bytes <- BS.readFile path
          pure $ forM (BC.lines bytes) $ \line -> case parseJson pythonLoads line of
            Right v@(Object _) -> Right v
            Right _ -> Left "DST campaign case must be a JSON object"
            Left problem -> Left (T.pack problem)

-- | @_show_failure@.
showFailure :: Text -> Text -> Text -> IO ()
showFailure name out err = do
  hPutStrLn stderr ("DST campaign profile " <> T.unpack name <> " failed")
  forM_ [out, err] $ \o -> unless (T.null o) (hPutStrLn stderr (T.unpack (T.takeEnd 8192 o)))

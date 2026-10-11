{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | A recorded system under test.
--
-- A 'Transcript' is what one replay asked of its profiles and checkers,
-- and what they answered: every door call in order (the door, its exact
-- arguments, every 'Petrus.Testing.Dst.Profile.ScenarioContext' service
-- it used with that service's result, and its value or raised error), and
-- every checker verdict by observation. 'transcriptRegistry' turns one
-- into a registry whose profiles serve the recorded answers, so an
-- interpreter can replay an artifact against a system it cannot run — the
-- Python reference's Engine, before the Haskell Engine exists — and must
-- make exactly the recorded calls with exactly the recorded arguments.
--
-- Generations are the transcript's integer tokens. A call that differs
-- from the next recorded one fails with a @TranscriptDivergence@ profile
-- error and is reported by 'transcriptDivergences'.
module Petrus.Testing.Dst.Transcript
  ( -- * Transcripts
    Transcript (..)
  , RecordedProfile (..)
  , RecordedChecker (..)
  , DoorCall (..)
  , ContextCall (..)
  , CheckCall (..)
  , pTranscript

    -- * Replaying against a transcript
  , TranscriptRun
  , transcriptRegistry
  , transcriptDivergences
  , replayTranscript
  ) where

import Control.Monad (forM_, unless)
import Control.Monad.Except (MonadError, catchError, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst.Codec (canonicalBytes)
import Petrus.Testing.Dst.Decode
  ( Parser
  , pApplyResult
  , pCheckResult
  , pCheckerIdentity
  , pCommand
  , pFault
  , pObservationRequest
  , pProfileIdentity
  , pResourceUsage
  , pScheduledCommand
  , renderSchemaError
  )
import Petrus.Testing.Dst.Profile hiding (door)
import Petrus.Testing.Dst.Replay (Registry, emptyRegistry, registerChecker, registerProfile, replay)
import Petrus.Testing.Dst.Types
import Petrus.Testing.Dst.World (DstFailure)

-- | One recorded replay.
data Transcript = Transcript
  { profiles :: [RecordedProfile]
  , checkers :: [RecordedChecker]
  , calls :: [DoorCall]
  , checks :: [CheckCall]
  }
  deriving stock (Eq, Show)

-- | A registered profile: its identity and whether it defines
-- @resource_usage@.
data RecordedProfile = RecordedProfile
  { identity :: ProfileIdentity
  , resourceUsage :: Bool
  }
  deriving stock (Eq, Show)

-- | A registered checker: its identity and observation request.
data RecordedChecker = RecordedChecker
  { identity :: CheckerIdentity
  , request :: ObservationRequest
  }
  deriving stock (Eq, Show)

-- | One door call: @validate@, @validate_fault@, @create@, @load@,
-- @apply@, @observe@, @drop@, @close@, or @resource_usage@.
data DoorCall = DoorCall
  { profile :: ProfileIdentity
  , door :: Text
  , arguments :: Json
  , context :: [ContextCall]
  , outcome :: Either ProfileError Json
  }
  deriving stock (Eq, Show)

-- | One context service a door used: @now@, @stable_id@, or @faults@.
data ContextCall = ContextCall
  { service :: Text
  , argument :: Maybe Text
  , result :: Either ProfileError Json
  }
  deriving stock (Eq, Show)

-- | One checker verdict.
data CheckCall = CheckCall
  { checker :: CheckerIdentity
  , observation :: Json
  , outcome :: Either ProfileError CheckResult
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Decoding (the format written by scripts/transcript_vectors.py)

-- | Decode a transcript's JSON.
pTranscript :: Json -> Either Text Transcript
pTranscript v = do
  profiles <- items "profiles" v >>= mapM recordedProfile
  checkers <- items "checkers" v >>= mapM recordedChecker
  calls <- items "calls" v >>= mapM doorCall
  checks <- items "checks" v >>= mapM checkCall
  pure Transcript {profiles, checkers, calls, checks}
  where
    recordedProfile p = do
      identity <- field "identity" p >>= schema "ProfileIdentity" pProfileIdentity
      resourceUsage <- field "resource_usage" p >>= \case
        Bool b -> Right b
        other -> Left ("resource_usage is not a bool: " <> T.pack (show other))
      pure RecordedProfile {identity, resourceUsage}
    recordedChecker c = do
      identity <- field "identity" c >>= schema "CheckerIdentity" pCheckerIdentity
      request <- field "request" c >>= schema "ObservationRequest" pObservationRequest
      pure RecordedChecker {identity, request}
    doorCall c = do
      profile <- field "profile" c >>= schema "ProfileIdentity" pProfileIdentity
      door <- field "door" c >>= text
      arguments <- field "arguments" c
      context <- items "context" c >>= mapM contextCall
      outcome <- field "outcome" c >>= recordedOutcome
      pure DoorCall {profile, door, arguments, context, outcome}
    contextCall e = do
      service <- field "service" e >>= text
      argument <- maybe (Right Nothing) (fmap Just . text) (lookupMember "argument" e)
      result <- case (lookupMember "result" e, lookupMember "error" e) of
        (Just value, Nothing) -> Right (Right value)
        (Nothing, Just failure) -> Left <$> profileErrorOf failure
        _ -> Left "a context call needs exactly one of result and error"
      pure ContextCall {service, argument, result}
    checkCall c = do
      checker <- field "checker" c >>= schema "CheckerIdentity" pCheckerIdentity
      observation <- field "observation" c
      outcome <- field "outcome" c >>= recordedOutcome >>= either (Right . Left) (fmap Right . schema "CheckResult" pCheckResult)
      pure CheckCall {checker, observation, outcome}
    recordedOutcome o = case (lookupMember "value" o, lookupMember "error" o) of
      (Just value, Nothing) -> Right (Right value)
      (Nothing, Just failure) -> Left <$> profileErrorOf failure
      _ -> Left "an outcome needs exactly one of value and error"
    profileErrorOf e = ProfileError <$> (field "type" e >>= text) <*> (field "message" e >>= text)
    field key value = maybe (Left ("missing " <> key)) Right (lookupMember key value)
    items key value = field key value >>= \case
      Array xs -> Right xs
      other -> Left (key <> " is not a list: " <> T.pack (show other))
    text = \case
      String s -> Right s
      other -> Left ("not a string: " <> T.pack (show other))

schema :: Text -> ([a] -> Json -> Parser b) -> Json -> Either Text b
schema name parser value = either (Left . renderSchemaError name) Right (parser [] value)

-- ---------------------------------------------------------------------------
-- Serving a transcript

-- | The mutable cursor behind one transcript-backed registry.
data TranscriptRun = TranscriptRun
  { remaining :: IORef [DoorCall]
  , position :: IORef Int
  , divergences :: IORef [Text]
  }

-- | A registry with one transcript-backed profile per recorded profile and
-- one lookup checker per recorded checker, registered in recorded order.
transcriptRegistry :: Transcript -> IO (Either DstFailure (Registry IO), TranscriptRun)
transcriptRegistry transcript = do
  run <- TranscriptRun <$> newIORef transcript.calls <*> newIORef 0 <*> newIORef []
  let verdicts =
        Map.fromList
          [ ((canonical (toJson c.checker), canonical c.observation), c.outcome)
          | c <- transcript.checks
          ]
      withProfiles = foldl (\r p -> r >>= registerProfile (servedProfile run p)) (Right emptyRegistry) transcript.profiles
      registry = foldl (\r c -> r >>= registerChecker (servedChecker verdicts c)) withProfiles transcript.checkers
  pure (registry, run)

-- | Every divergence so far, plus every recorded call not yet made.
transcriptDivergences :: TranscriptRun -> IO [Text]
transcriptDivergences run = do
  found <- reverse <$> readIORef run.divergences
  left <- readIORef run.remaining
  at <- readIORef run.position
  pure (found <> [T.pack (show (length left)) <> " recorded calls were never made, from call " <> T.pack (show at) | not (null left)])

-- | Replay an artifact against a transcript: the outcome, and the
-- divergences from the recorded calls (empty when the calls matched).
replayTranscript :: Transcript -> AnyArtifact -> IO (Either DstFailure AnyReplayResult, [Text])
replayTranscript transcript artifact = do
  (registry, run) <- transcriptRegistry transcript
  outcome <- either (pure . Left) (`replay` artifact) registry
  divergences <- transcriptDivergences run
  pure (outcome, divergences)

canonical :: Json -> ByteString
canonical value = either (const (TE.encodeUtf8 (T.pack (show value)))) id (canonicalBytes value)

divergence :: Text
divergence = "TranscriptDivergence"

diverge :: (MonadIO m) => TranscriptRun -> Text -> m ()
diverge run message = liftIO (modifyIORef' run.divergences (message :))

-- | Take the next recorded call, which must be this door with these
-- arguments.
expect :: TranscriptRun -> ProfileIdentity -> Text -> Json -> IO (Either Text DoorCall)
expect run identity door arguments = do
  at <- readIORef run.position
  queue <- readIORef run.remaining
  let label = "call " <> T.pack (show at) <> " (" <> door <> ")"
  case queue of
    [] -> pure (Left (label <> ": no recorded call remains"))
    call : rest
      | call.profile /= identity -> pure (Left (label <> ": recorded for profile " <> identity.name <> " but made on another"))
      | call.door /= door -> pure (Left (label <> ": recorded door is " <> call.door))
      | canonical call.arguments /= canonical arguments ->
          pure (Left (label <> ": arguments " <> decoded (canonical arguments) <> " differ from recorded " <> decoded (canonical call.arguments)))
      | otherwise -> do
          writeIORef run.remaining rest
          writeIORef run.position (at + 1)
          pure (Right call)
  where
    decoded = TE.decodeUtf8

-- | Record a divergence and refuse the door with it.
refuse :: (MonadIO m, MonadError ProfileError m) => TranscriptRun -> Text -> m a
refuse run message = do
  diverge run message
  throwError (ProfileError divergence message)

-- | The recorded answer: the raised error, or the decoded value.
answer :: (MonadIO m, MonadError ProfileError m) => TranscriptRun -> Text -> DoorCall -> (Json -> Either Text a) -> m a
answer run doorName call parse = case call.outcome of
  Left failure -> throwError failure
  Right value -> either (\e -> refuse run (doorName <> ": the recorded value does not decode: " <> e)) pure (parse value)

-- | Serve one plain door from the transcript.
serveDoor :: TranscriptRun -> ProfileIdentity -> Text -> Json -> (Json -> Either Text a) -> Door IO a
serveDoor run identity doorName arguments parse = do
  call <- liftIO (expect run identity doorName arguments) >>= either (refuse run) pure
  unless (null call.context) (refuse run (doorName <> " used context services outside a scenario door"))
  answer run doorName call parse

-- | Serve one scenario door, replaying its context services in order and
-- checking each service's result against the recorded one.
serveScenario :: TranscriptRun -> ProfileIdentity -> Text -> Json -> (Json -> Either Text a) -> Scenario IO a
serveScenario run identity doorName arguments parse = do
  call <- liftIO (expect run identity doorName arguments) >>= either (refuse run) pure
  forM_ call.context $ \c -> do
    actual <- (Right <$> service c) `catchError` (pure . Left)
    let same = case (actual, c.result) of
          (Right a, Right r) -> canonical a == canonical r
          (Left a, Left r) -> a == r
          _ -> False
    unless same $
      refuse run (doorName <> ": context " <> c.service <> " gave " <> T.pack (show actual) <> ", recorded " <> T.pack (show c.result))
  answer run doorName call parse
  where
    service c = case (c.service, c.argument) of
      ("now", Nothing) -> Int <$> now
      ("stable_id", Just namespace) -> String <$> stableId namespace
      ("faults", Just target) -> Array . map toJson <$> faults target
      _ -> refuse run ("unknown context service " <> c.service)

servedProfile :: TranscriptRun -> RecordedProfile -> Profile IO Integer
servedProfile run recorded =
  Profile
    { identity
    , validate = \c -> serveDoor run identity "validate" (Object [("command", toJson c)]) (schema "Command" pCommand)
    , validateFault = \f -> serveDoor run identity "validate_fault" (Object [("fault", toJson f)]) (schema "Fault" pFault)
    , create = serveScenario run identity "create" (Object []) generationStart
    , load = serveScenario run identity "load" (Object []) generationStart
    , apply = \g c ->
        serveScenario run identity "apply" (Object [("generation", Int g), ("command", toJson c)]) (schema "ApplyResult" pApplyResult)
    , observe = \g r ->
        serveScenario run identity "observe" (Object [("generation", Int g), ("request", toJson r)]) Right
    , dropGeneration = \g -> serveDoor run identity "drop" (Object [("generation", Int g)]) unit
    , closeGeneration = \g -> serveDoor run identity "close" (Object [("generation", Int g)]) unit
    , resourceUsage =
        if recorded.resourceUsage
          then Just $ \g ->
            serveDoor run identity "resource_usage" (Object [("generation", maybe Null Int g)]) (schema "ResourceUsage" pResourceUsage)
          else Nothing
    }
  where
    identity = recorded.identity
    unit = \case
      Null -> Right ()
      other -> Left ("expected null, recorded " <> T.pack (show other))
    generationStart value = case (lookupMember "generation" value, lookupMember "scheduled" value) of
      (Just (Int token), Just (Array scheduled)) -> do
        commands <- mapM (schema "ScheduledCommand" pScheduledCommand) scheduled
        Right GenerationStart {generation = token, scheduled = commands}
      _ -> Left ("not a recorded generation start: " <> T.pack (show value))

servedChecker :: Map (ByteString, ByteString) (Either ProfileError CheckResult) -> RecordedChecker -> Checker
servedChecker verdicts recorded =
  Checker
    { identity = recorded.identity
    , request = recorded.request
    , check = pureCheck $ \o ->
        case Map.lookup (canonical (toJson recorded.identity), canonical (toJson o)) verdicts of
          Just verdict -> verdict
          Nothing -> Left (ProfileError divergence ("no recorded verdict of " <> recorded.identity.name <> " for " <> TE.decodeUtf8 (canonical (toJson o))))
    }

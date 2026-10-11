{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The outer process runner (@petrus-dst-process-runner@ protocol version
-- 1, API @petrus.testing.dst.runner/v1@): one complete scenario runs in a
-- child process under a wall-clock watchdog, and the parent folds the
-- child's durable progress file into an exact acknowledged prefix.
--
-- The reference child imports @dotted.module:function@ dynamically. A
-- compiled program cannot, so the child here is the same executable started
-- with a hidden argument, and entrypoints are looked up in a static
-- 'Entrypoints' table under the same @dotted.module:function@ names. A
-- program that runs scenarios calls 'processChildHook' first thing in
-- @main@. The progress file, its frames, and the result are byte-for-byte
-- the reference's.
module Petrus.Testing.Dst.Runner
  ( -- * Constants
    processRunnerApi
  , processRunnerProtocol
  , processRunnerProtocolVersion
  , processResultFormat
  , processResultVersion
  , maxProcessProgressBytes

    -- * Specs
  , ProcessBudget (..)
  , ProcessRunSpec (..)
  , pProcessRunSpec

    -- * Results
  , ProcessWorldMetadata (..)
  , AcknowledgedPrefix (..)
  , lastOperation
  , lastJournalEntry
  , lastResource
  , lastCheck
  , ProcessFailure (..)
  , Outcome (..)
  , Termination (..)
  , ProcessRunResult (..)
  , encodeProcessRunResult

    -- * Frames
  , Frame (..)
  , BoundaryFrame (..)
  , encodeFrame
  , parseFrame
  , readProcessFrames
  , FoldedFrames (..)
  , foldProcessFrames
  , processResult

    -- * Children
  , Entrypoint
  , Entrypoints
  , Session
  , sessionWorld
  , processChildMain
  , processChildHook
  , childFlag

    -- * Parent
  , ChildCommand (..)
  , selfChildCommand
  , runProcessScenario
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, catch, finally, mask, onException, throwIO, try)
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst.Codec (canonicalBytes, encodeArtifact, journalDigest, loadStrictJson)
import Petrus.Testing.Dst.Decode
import Petrus.Testing.Dst.Internal.World
  ( Boundary (..)
  , DstFailure (..)
  , Progress (..)
  , World
  , WorldConfig (..)
  , WorldT
  , close
  , newWorld
  , runWorldT
  )
import Petrus.Testing.Dst.Profile (Checker (..), Profile (..))
import Petrus.Testing.Dst.Types
import System.Directory (doesFileExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (IOMode (..), openFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdWrite)
import System.Posix.Signals (Signal, signalProcessGroup, sigKILL, sigTERM)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )

-- ---------------------------------------------------------------------------
-- Constants

processRunnerApi, processRunnerProtocol, processResultFormat :: Text
processRunnerApi = "petrus.testing.dst.runner/v1"
processRunnerProtocol = "petrus-dst-process-runner"
processResultFormat = "petrus-dst-process-run-result"

processRunnerProtocolVersion, processResultVersion :: Integer
processRunnerProtocolVersion = 1
processResultVersion = 1

-- | @MAX_PROCESS_PROGRESS_BYTES@.
maxProcessProgressBytes :: Integer
maxProcessProgressBytes = 16777216

-- ---------------------------------------------------------------------------
-- Specs

-- | Nondeterministic host-containment limits, separate from World budgets.
data ProcessBudget = ProcessBudget
  { wallClockMs :: Integer
  , terminationGraceMs :: Integer
  , inputBytes :: Integer
  , progressBytes :: Integer
  }
  deriving stock (Eq, Show)

-- | One complete-scenario invocation.
data ProcessRunSpec = ProcessRunSpec
  { scenarioId :: Text
  , entrypoint :: Text
  , payload :: Json
  , budget :: ProcessBudget
  }
  deriving stock (Eq, Show)

instance ToJson ProcessBudget where
  toJson b =
    obj
      [ ("wall_clock_ms", Int b.wallClockMs)
      , ("termination_grace_ms", Int b.terminationGraceMs)
      , ("input_bytes", Int b.inputBytes)
      , ("progress_bytes", Int b.progressBytes)
      ]

instance ToJson ProcessRunSpec where
  toJson s =
    obj
      [ ("scenario_id", String s.scenarioId)
      , ("entrypoint", String s.entrypoint)
      , ("payload", s.payload)
      , ("budget", toJson s.budget)
      ]

pProcessBudget :: Path -> Json -> Parser ProcessBudget
pProcessBudget path v = do
  f <- model "ProcessBudget" ["wall_clock_ms", "termination_grace_ms", "input_bytes", "progress_bytes"] path v
  wallClockMs <- field f "wall_clock_ms" (pIntRange (Just 1) (Just 30000))
  terminationGraceMs <- field f "termination_grace_ms" (pIntRange (Just 1) (Just 5000))
  inputBytes <- field f "input_bytes" (pIntRange (Just 1) (Just maxArtifactBytes))
  progressBytes <- field f "progress_bytes" (pIntRange (Just 1) (Just maxProcessProgressBytes))
  Right ProcessBudget {wallClockMs, terminationGraceMs, inputBytes, progressBytes}

-- | @ProcessRunSpec.model_validate(value, strict=True)@.
pProcessRunSpec :: Path -> Json -> Parser ProcessRunSpec
pProcessRunSpec path v = do
  f <- model "ProcessRunSpec" ["scenario_id", "entrypoint", "payload", "budget"] path v
  scenarioId <- field f "scenario_id" $ \p x -> do
    s <- pStr p x
    unless (isName s) (valueError p "process scenario id must be normalized and non-empty")
    Right s
  entrypoint <- field f "entrypoint" $ \p x -> do
    s <- pStr p x
    unless (isEntrypoint s) (valueError p "process scenario entrypoint must be 'dotted.module:function'")
    Right s
  payload <- field f "payload" (pJsonValue "process scenario payload")
  budget <- field f "budget" pProcessBudget
  Right ProcessRunSpec {scenarioId, entrypoint, payload, budget}

-- ---------------------------------------------------------------------------
-- Results

-- | Detached identity of the one child-owned World.
data ProcessWorldMetadata = ProcessWorldMetadata
  { profile :: ProfileIdentity
  , checkers :: [CheckerIdentity]
  , budget :: SomeBudget
  , seed :: Maybe Integer
  }
  deriving stock (Eq, Show)

instance ToJson ProcessWorldMetadata where
  toJson m =
    obj
      [ ("profile", toJson m.profile)
      , ("checkers", Array (map toJson m.checkers))
      , ("budget", toJson m.budget)
      , ("seed", maybe Null Int m.seed)
      ]

pProcessWorldMetadata :: Path -> Json -> Parser ProcessWorldMetadata
pProcessWorldMetadata path v = do
  f <- model "ProcessWorldMetadata" ["profile", "checkers", "budget", "seed"] path v
  profile <- field f "profile" pProfileIdentity
  checkers <- field f "checkers" (pList pCheckerIdentity)
  budget <- field f "budget" pAnyBudget
  seed <- fieldDefault f "seed" Nothing (pNullable (pIntRange (Just 0) (Just maxPortableInteger)))
  Right ProcessWorldMetadata {profile, checkers, budget, seed}

-- | Exact complete World boundaries durably acknowledged by the child.
data AcknowledgedPrefix = AcknowledgedPrefix
  { world :: Maybe ProcessWorldMetadata
  , operations :: [ExpandedOperation]
  , journal :: [JournalEntry]
  , instant :: Integer
  , generation :: Maybe Integer
  , disposition :: Maybe Disposition
  }
  deriving stock (Eq, Show)

instance ToJson AcknowledgedPrefix where
  toJson p =
    obj
      [ ("world", maybe Null toJson p.world)
      , ("operations", Array (map toJson p.operations))
      , ("journal", Array (map toJson p.journal))
      , ("instant", Int p.instant)
      , ("generation", maybe Null Int p.generation)
      , ("disposition", maybe Null (String . dispositionText) p.disposition)
      ]

lastOperation :: AcknowledgedPrefix -> Maybe ExpandedOperation
lastOperation p = if null p.operations then Nothing else Just (last p.operations)

lastJournalEntry :: AcknowledgedPrefix -> Maybe JournalEntry
lastJournalEntry p = if null p.journal then Nothing else Just (last p.journal)

lastResource :: AcknowledgedPrefix -> Maybe JournalEntry
lastResource p = find (\e -> e.kind == JResource) (reverse p.journal)

lastCheck :: AcknowledgedPrefix -> Maybe JournalEntry
lastCheck p = find (\e -> e.kind == JCheck) (reverse p.journal)

-- | Why a run did not complete.
data ProcessFailure
  = -- | @wall_clock_timeout@ at the @wall_clock_ms@ limit.
    WallClockTimeout Integer
  | -- | @child_failure@ with its code.
    ChildFailure Text
  | -- | @protocol_failure@ with its code.
    ProtocolFailure Text
  deriving stock (Eq, Show)

instance ToJson ProcessFailure where
  toJson = \case
    WallClockTimeout limit -> obj [("kind", String "wall_clock_timeout"), ("bound", String "wall_clock_ms"), ("limit", Int limit)]
    ChildFailure code -> obj [("kind", String "child_failure"), ("code", String code)]
    ProtocolFailure code -> obj [("kind", String "protocol_failure"), ("code", String code)]

data Outcome = Completed | HarnessFailure
  deriving stock (Eq, Show)

data Termination = Exited | Terminated | Killed
  deriving stock (Eq, Show)

-- | Structured completion or containment result from one child process.
data ProcessRunResult = ProcessRunResult
  { scenarioId :: Text
  , outcome :: Outcome
  , termination :: Termination
  , returncode :: Int
  , prefix :: AcknowledgedPrefix
  , unfinishedAttempt :: Maybe ProcessAttempt
  , artifact :: Maybe AnyArtifact
  , failure :: Maybe ProcessFailure
  }
  deriving stock (Eq, Show)

instance ToJson ProcessRunResult where
  toJson r =
    obj
      [ ("format", String processResultFormat)
      , ("version", Int processResultVersion)
      , ("api", String processRunnerApi)
      , ("scenario_id", String r.scenarioId)
      , ("outcome", case r.outcome of Completed -> String "completed"; HarnessFailure -> String "harness_failure")
      , ("termination", case r.termination of Exited -> String "exited"; Terminated -> String "terminated"; Killed -> String "killed")
      , ("returncode", Int (toInteger r.returncode))
      , ("prefix", toJson r.prefix)
      , ("unfinished_attempt", maybe Null toJson r.unfinishedAttempt)
      , ("artifact", maybe Null toJson r.artifact)
      , ("failure", maybe Null toJson r.failure)
      ]

-- | Canonical bytes of a result.
encodeProcessRunResult :: ProcessRunResult -> ByteString
encodeProcessRunResult r = either (const BS.empty) id (canonicalBytes (toJson r))

-- ---------------------------------------------------------------------------
-- Frames

-- | The deltas one boundary acknowledges.
data BoundaryFrame = BoundaryFrame
  { operations :: [ExpandedOperation]
  , journal :: [JournalEntry]
  , instant :: Integer
  , generation :: Maybe Integer
  , disposition :: Maybe Disposition
  }
  deriving stock (Eq, Show)

-- | One progress line; the 'Integer' is the frame's sequence number.
data Frame
  = FStarted Integer Text
  | FWorld Integer ProcessWorldMetadata
  | FAttempt Integer ProcessAttempt
  | FBoundary Integer BoundaryFrame
  | FComplete Integer AnyArtifact
  | FFailed Integer Text
  deriving stock (Eq, Show)

frameSequence :: Frame -> Integer
frameSequence = \case
  FStarted s _ -> s
  FWorld s _ -> s
  FAttempt s _ -> s
  FBoundary s _ -> s
  FComplete s _ -> s
  FFailed s _ -> s

instance ToJson Frame where
  toJson = \case
    FStarted s sid ->
      obj
        [ ("kind", String "started")
        , ("sequence", Int s)
        , ("protocol", String processRunnerProtocol)
        , ("version", Int processRunnerProtocolVersion)
        , ("scenario_id", String sid)
        ]
    FWorld s m -> obj [("kind", String "world"), ("sequence", Int s), ("metadata", toJson m)]
    FAttempt s a -> obj [("kind", String "attempt"), ("sequence", Int s), ("attempt", toJson a)]
    FBoundary s b ->
      obj
        [ ("kind", String "boundary")
        , ("sequence", Int s)
        , ("operations", Array (map toJson b.operations))
        , ("journal", Array (map toJson b.journal))
        , ("instant", Int b.instant)
        , ("generation", maybe Null Int b.generation)
        , ("disposition", maybe Null (String . dispositionText) b.disposition)
        ]
    FComplete s a -> obj [("kind", String "complete"), ("sequence", Int s), ("artifact", toJson a)]
    FFailed s code -> obj [("kind", String "failed"), ("sequence", Int s), ("code", String code)]

-- | One canonical progress line, newline included.
encodeFrame :: Frame -> Either Text ByteString
encodeFrame frame = (<> "\n") <$> canonicalBytes (toJson frame)

-- | One progress line, admitted exactly as the reference admits it.
parseFrame :: ByteString -> Either Text Frame
parseFrame raw = do
  value <- either (Left . ("invalid strict DST process progress frame: " <>)) Right (loadStrictJson raw)
  case value of
    Object _ -> case lookupMember "kind" value of
      Just (String kind) | Just p <- lookup kind frameParsers -> either (Left . renderSchemaError (frameModel kind)) Right (p value)
      _ -> Left "unknown process progress frame"
    _ -> Left "process progress frame must be an object"
  where
    frameModel kind = case kind of
      "started" -> "_StartedFrame"
      "world" -> "_WorldFrame"
      "attempt" -> "_AttemptFrame"
      "boundary" -> "_BoundaryFrame"
      "complete" -> "_CompleteFrame"
      _ -> "_FailedFrame"

frameParsers :: [(Text, Json -> Parser Frame)]
frameParsers =
  [ ("started", \v -> do
        f <- frame "_StartedFrame" ["protocol", "version", "scenario_id"] "started" v
        s <- sequenceField f
        field f "protocol" (pLiteral [(String processRunnerProtocol, ())])
        field f "version" (pLiteral [(Int processRunnerProtocolVersion, ())])
        FStarted s <$> field f "scenario_id" pStr)
  , ("world", \v -> do
        f <- frame "_WorldFrame" ["metadata"] "world" v
        s <- sequenceField f
        FWorld s <$> field f "metadata" pProcessWorldMetadata)
  , ("attempt", \v -> do
        f <- frame "_AttemptFrame" ["attempt"] "attempt" v
        s <- sequenceField f
        FAttempt s <$> field f "attempt" pProcessAttempt)
  , ("boundary", \v -> do
        f <- frame "_BoundaryFrame" ["operations", "journal", "instant", "generation", "disposition"] "boundary" v
        s <- sequenceField f
        operations <- field f "operations" (pList pExpandedOperation)
        journal <- field f "journal" (pList pJournalEntry)
        instant <- field f "instant" (pIntRange (Just 0) (Just maxPortableInteger))
        generation <- field f "generation" (pNullable (pIntRange (Just 1) Nothing))
        disposition <- field f "disposition" (pNullable pDisposition)
        Right (FBoundary s BoundaryFrame {operations, journal, instant, generation, disposition}))
  , ("complete", \v -> do
        f <- frame "_CompleteFrame" ["artifact"] "complete" v
        s <- sequenceField f
        FComplete s <$> field f "artifact" pProcessArtifact)
  , ("failed", \v -> do
        f <- frame "_FailedFrame" ["code"] "failed" v
        s <- sequenceField f
        FFailed s <$> field f "code" (\p x -> do
          code <- pStr p x
          unless (isName code) (valueError p "process child failure code must be normalized and non-empty")
          Right code))
  ]
  where
    frame name keys kind v = do
      f <- model name ("kind" : "sequence" : keys) [] v
      field f "kind" (pLiteral [(String kind, ())])
      Right f
    sequenceField f = field f "sequence" (pIntRange (Just 0) Nothing)

-- | The version-discriminated artifact union of a complete frame.
pProcessArtifact :: Path -> Json -> Parser AnyArtifact
pProcessArtifact path v = case v of
  Object _ -> case lookupMember "version" v of
    Just (Int 1) -> nested (ArtifactV1 <$> pArtifactV1 v)
    Just (Int 2) -> nested (ArtifactV2 <$> pArtifactV2 v)
    Just (Int 3) -> nested (ArtifactV3 <$> pArtifactV3 v)
    Just (Int 4) -> nested (ArtifactV4 <$> pArtifactV4 v)
    Nothing -> failAt path "union_tag_not_found" "Unable to extract tag using discriminator 'version'"
    Just _ -> failAt path "union_tag_invalid" "Input tag found using 'version' does not match any of the expected tags: 1, 2, 3, 4"
  _ -> failAt path "model_attributes_type" "Input should be a valid dictionary or object to extract fields from"
  where
    nested = either (\e -> Left e {loc = reverse path <> e.loc}) Right

-- | @_read_process_frames@ over the progress file's bytes ('Nothing' when
-- the file does not exist): the admitted frames and a protocol failure
-- code, if any.
readProcessFrames :: Maybe ByteString -> Integer -> Bool -> ([Frame], Maybe Text)
readProcessFrames Nothing _ _ = ([], Just "progress-missing")
readProcessFrames (Just payload) limit allowPartial
  | toInteger (BS.length payload) > limit = ([], Just "progress-overflow")
  | not (BS.null payload) && BC.last payload /= '\n' && not allowPartial = ([], Just "partial-frame")
  | otherwise = go [] (splitLines complete)
  where
    complete
      | BS.null payload || BC.last payload == '\n' = payload
      | otherwise = case BC.elemIndexEnd '\n' payload of
          Just i -> BS.take (i + 1) payload
          Nothing -> BS.empty
    go acc = \case
      [] -> (reverse acc, Nothing)
      raw : rest -> case parseFrame raw of
        Right f -> go (f : acc) rest
        Left _ -> (reverse acc, Just "malformed-frame")

-- | @bytes.splitlines()@: split on @\\n@, @\\r@, and @\\r\\n@.
splitLines :: ByteString -> [ByteString]
splitLines bytes
  | BS.null bytes = []
  | otherwise =
      let (line, rest) = BC.break (\c -> c == '\n' || c == '\r') bytes
       in case BC.uncons rest of
            Nothing -> [line]
            Just ('\r', rest') -> line : splitLines (maybe rest' snd (BC.uncons rest' >>= \(c, r) -> if c == '\n' then Just (c, r) else Nothing))
            Just (_, rest') -> line : splitLines rest'

-- | The state @_fold_process_frames@ returns.
data FoldedFrames = FoldedFrames
  { prefix :: AcknowledgedPrefix
  , attempt :: Maybe ProcessAttempt
  , artifact :: Maybe AnyArtifact
  , childCode :: Maybe Text
  , protocolCode :: Maybe Text
  }
  deriving stock (Eq, Show)

data FoldState = FoldState
  { ackWorld :: Maybe ProcessWorldMetadata
  , ackOperations :: Seq.Seq ExpandedOperation
  , ackJournal :: Seq.Seq JournalEntry
  , ackInstant :: Integer
  , ackGeneration :: Maybe Integer
  , ackDisposition :: Maybe Disposition
  , openAttempt :: Maybe ProcessAttempt
  , doneArtifact :: Maybe AnyArtifact
  , doneCode :: Maybe Text
  , started :: Bool
  , ended :: Bool
  }

-- | @_fold_process_frames@: the fail-closed framed protocol state machine.
foldProcessFrames :: ProcessRunSpec -> [Frame] -> FoldedFrames
foldProcessFrames spec = go 0 initial
  where
    initial =
      FoldState
        { ackWorld = Nothing
        , ackOperations = Seq.empty
        , ackJournal = Seq.empty
        , ackInstant = 0
        , ackGeneration = Nothing
        , ackDisposition = Nothing
        , openAttempt = Nothing
        , doneArtifact = Nothing
        , doneCode = Nothing
        , started = False
        , ended = False
        }
    prefixOf s =
      AcknowledgedPrefix
        { world = s.ackWorld
        , operations = toList s.ackOperations
        , journal = toList s.ackJournal
        , instant = s.ackInstant
        , generation = s.ackGeneration
        , disposition = s.ackDisposition
        }
    refuse s code = FoldedFrames {prefix = prefixOf s, attempt = s.openAttempt, artifact = Nothing, childCode = Nothing, protocolCode = Just code}
    go :: Integer -> FoldState -> [Frame] -> FoldedFrames
    go _ s []
      | not s.started = refuse s "start-missing"
      | otherwise = FoldedFrames {prefix = prefixOf s, attempt = s.openAttempt, artifact = s.doneArtifact, childCode = s.doneCode, protocolCode = Nothing}
    go sequenceNumber s (frame : rest)
      | frameSequence frame /= sequenceNumber || s.ended = refuse s "frame-order"
      | otherwise = case frame of
          FStarted _ sid
            | s.started || sequenceNumber /= 0 || sid /= spec.scenarioId -> refuse s "frame-order"
            | otherwise -> next s {started = True}
          FWorld _ m
            | not s.started || has s.ackWorld || has s.openAttempt -> refuse s "frame-order"
            | otherwise -> next s {ackWorld = Just m}
          FAttempt _ a
            | not s.started || not (has s.ackWorld) || has s.openAttempt -> refuse s "frame-order"
            | otherwise -> next s {openAttempt = Just a}
          FBoundary _ b
            | not (has s.openAttempt) -> refuse s "frame-order"
            | map operationPosition b.operations /= positionsFrom (Seq.length s.ackOperations) b.operations
                || map (\e -> e.position) b.journal /= positionsFrom (Seq.length s.ackJournal) b.journal ->
                refuse s "prefix-position"
            | otherwise ->
                next
                  s
                    { ackOperations = s.ackOperations <> Seq.fromList b.operations
                    , ackJournal = s.ackJournal <> Seq.fromList b.journal
                    , ackInstant = b.instant
                    , ackGeneration = b.generation
                    , ackDisposition = b.disposition
                    , openAttempt = Nothing
                    }
          FComplete _ a
            | has s.openAttempt || not (has s.ackWorld) || artifactScenarioId a /= spec.scenarioId -> refuse s "frame-order"
            | otherwise -> next s {doneArtifact = Just a, ended = True}
          FFailed _ code -> next s {doneCode = Just code, ended = True}
      where
        next s' = go (sequenceNumber + 1) s' rest
    has :: Maybe a -> Bool
    has = maybe False (const True)
    positionsFrom start items = take (length items) [toInteger start ..]

-- | @_process_result@: fold the progress bytes into the run's result.
processResult :: ProcessRunSpec -> Int -> Termination -> Bool -> Maybe ByteString -> ProcessRunResult
processResult spec returncode termination timedOut progressBytes =
  ProcessRunResult
    { scenarioId = spec.scenarioId
    , outcome
    , termination
    , returncode
    , prefix = folded.prefix
    , unfinishedAttempt = folded.attempt
    , artifact = finalArtifact
    , failure
    }
  where
    (frames, readCode) = readProcessFrames progressBytes spec.budget.progressBytes timedOut
    folded = foldProcessFrames spec frames
    mismatch = case folded.artifact of
      Just a ->
        folded.prefix.operations /= artifactOperations a
          || journalDigest folded.prefix.journal /= artifactJournalDigest a
      Nothing -> False
    protocolCode = case readCode of
      Just c -> Just c
      Nothing -> case folded.protocolCode of
        Just c -> Just c
        Nothing -> if mismatch then Just "artifact-prefix-mismatch" else Nothing
    candidate = if mismatch then Nothing else folded.artifact
    (outcome, failure, finalArtifact)
      | timedOut = (HarnessFailure, Just (WallClockTimeout spec.budget.wallClockMs), Nothing)
      | Just code <- protocolCode = (HarnessFailure, Just (ProtocolFailure code), Nothing)
      | returncode /= 0 || has folded.childCode =
          (HarnessFailure, Just (ChildFailure (maybe "child-exited" id folded.childCode)), Nothing)
      | Nothing <- candidate = (HarnessFailure, Just (ProtocolFailure "terminal-missing"), Nothing)
      | otherwise = (Completed, Nothing, candidate)
    has :: Maybe a -> Bool
    has = maybe False (const True)

-- ---------------------------------------------------------------------------
-- The child

-- | One importable complete scenario: it builds at most one World through
-- the 'Session' and returns that World's artifact. Throwing anything fails
-- the scenario.
type Entrypoint = Session -> Json -> IO AnyArtifact

-- | The static entrypoint table, keyed by @dotted.module:function@ names.
type Entrypoints = Map Text Entrypoint

-- | The child-only canonical JSONL writer; every complete line is one
-- acknowledgement.
data FileProgress = FileProgress
  { fd :: Fd
  , limit :: Integer
  , cursor :: IORef Cursor
  }

data Cursor = Cursor
  { written :: Integer
  , sequenceNumber :: Integer
  , operationPosition :: Int
  , journalPosition :: Int
  , finished :: Bool
  }

openProgress :: FilePath -> ProcessRunSpec -> IO FileProgress
openProgress path spec = do
  fd <- openFd path WriteOnly defaultFileFlags {creat = Just 0o644, exclusive = True}
  cursor <- newIORef Cursor {written = 0, sequenceNumber = 0, operationPosition = 0, journalPosition = 0, finished = False}
  let progress = FileProgress {fd, limit = spec.budget.progressBytes, cursor}
  writeFrame progress (\s -> FStarted s spec.scenarioId) >>= either throwIO pure
  pure progress

-- | Write one frame with the next sequence number; refuse past the byte
-- limit with the reference's @ValueError@.
writeFrame :: FileProgress -> (Integer -> Frame) -> IO (Either DstFailure ())
writeFrame progress build = do
  c <- readIORef progress.cursor
  case encodeFrame (build c.sequenceNumber) of
    Left message -> pure (Left (ContractViolation "ValueError" message))
    Right payload
      | c.written + toInteger (BS.length payload) > progress.limit ->
          pure (Left (ContractViolation "ValueError" "DST process progress exceeds its byte limit"))
      | otherwise -> do
          writeAll progress.fd payload
          fileSynchronise progress.fd
          modifyIORef' progress.cursor (\k -> k {written = k.written + toInteger (BS.length payload), sequenceNumber = k.sequenceNumber + 1})
          pure (Right ())

writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes = unless (BS.null bytes) $ do
  n <- fdWrite fd bytes
  writeAll fd (BS.drop (fromIntegral n) bytes)

progressHooks :: FileProgress -> Progress IO
progressHooks progress =
  Progress
    { attempt = \a -> writeFrame progress (\s -> FAttempt s a)
    , boundary = \b -> do
        c <- readIORef progress.cursor
        let ops = toList (Seq.drop c.operationPosition b.operations)
            entries = toList (Seq.drop c.journalPosition b.journal)
        modifyIORef' progress.cursor (\k -> k {operationPosition = k.operationPosition + length ops, journalPosition = k.journalPosition + length entries})
        writeFrame progress $ \s ->
          FBoundary s BoundaryFrame {operations = ops, journal = entries, instant = b.instant, generation = b.generation, disposition = b.disposition}
    }

completeProgress :: FileProgress -> AnyArtifact -> IO ()
completeProgress progress a = do
  writeFrame progress (\s -> FComplete s a) >>= either throwIO pure
  modifyIORef' progress.cursor (\k -> k {finished = True})

failProgress :: FileProgress -> Text -> IO ()
failProgress progress code = do
  c <- readIORef progress.cursor
  unless c.finished $ do
    writeFrame progress (\s -> FFailed s code) >>= either throwIO pure
    modifyIORef' progress.cursor (\k -> k {finished = True})

-- | The child-owned composition root for exactly one acknowledged World.
data Session = Session
  { progress :: FileProgress
  , closer :: IORef (Maybe (IO (Either DstFailure ())))
  }

-- | @ProcessSession.world@ and the World's use in one call: acknowledge the
-- World's metadata, construct it with progress acknowledgements, and run
-- the computation against it. The World stays open until the session
-- closes after the entrypoint returns, as the reference's does; a failure
-- is thrown as a 'DstFailure' exception.
sessionWorld :: Session -> WorldConfig IO g -> WorldT IO g a -> IO a
sessionWorld session config body = do
  existing <- readIORef session.closer
  when (has existing) $ throwIO (DstError "a DST process session owns exactly one World")
  let metadata =
        ProcessWorldMetadata
          { profile = config.profile.identity
          , checkers = map (\c -> c.identity) config.checkers
          , budget = config.budget
          , seed = config.seed
          }
  case pProcessWorldMetadata [] (toJson metadata) of
    Left e -> throwIO (ContractViolation "ValidationError" (renderSchemaError "ProcessWorldMetadata" e))
    Right _ -> pure ()
  writeFrame session.progress (\s -> FWorld s metadata) >>= either throwIO pure
  constructed <-
    newWorld
      WorldConfig
        { profile = config.profile
        , budget = config.budget
        , checkers = config.checkers
        , seed = config.seed
        , progress = Just (progressHooks session.progress)
        }
  world <- either throwIO pure constructed
  (result, world') <- runWorldT body world
  writeIORef session.closer (Just (closeWorld world'))
  either throwIO pure result
  where
    has = maybe False (const True)

closeWorld :: World IO g -> IO (Either DstFailure ())
closeWorld world = fst <$> runWorldT close world

-- | The hidden argument that selects the child role.
childFlag :: String
childFlag = "--petrus-dst-process-child"

-- | @_process_child_main@: run the spec's entrypoint, acknowledge its
-- progress, and return the exit status (0 after @complete@, 70 after
-- @failed@).
processChildMain :: Entrypoints -> FilePath -> FilePath -> IO Int
processChildMain entrypoints specPath progressPath = do
  bytes <- BS.readFile specPath
  value <- either (throwIO . ContractViolation "ValueError" . ("invalid strict DST process run spec: " <>)) pure (loadStrictJson bytes)
  spec <- either (throwIO . ContractViolation "ValidationError" . renderSchemaError "ProcessRunSpec") pure (pProcessRunSpec [] value)
  progress <- openProgress progressPath spec
  closer <- newIORef Nothing
  let session = Session {progress, closer}
  outcome <- try (scenario spec session) :: IO (Either SomeException ())
  ( case outcome of
      Right () -> pure 0
      Left _ -> do
        _ <- try (failProgress progress "scenario-failed") :: IO (Either SomeException ())
        pure 70
    )
    `finally` closeFd progress.fd
  where
    scenario spec session = do
      function <- maybe (throwIO (ContractViolation "ModuleNotFoundError" ("No DST process entrypoint " <> spec.entrypoint))) pure (Map.lookup spec.entrypoint entrypoints)
      result <- function session spec.payload
      when (artifactScenarioId result /= spec.scenarioId) $
        throwIO (ContractViolation "ValueError" "DST process scenario returned a different scenario identity")
      either (throwIO . ContractViolation "ValueError") (const (pure ())) (encodeArtifact result)
      readIORef session.closer >>= maybe (pure ()) (>>= either throwIO pure)
      completeProgress session.progress result

-- | Call first in @main@ of any program that runs process scenarios: when
-- the program was started as a runner child, run the child and exit.
processChildHook :: Entrypoints -> IO ()
processChildHook entrypoints = do
  arguments <- getArgs
  case dropWhile (/= childFlag) arguments of
    _ : specPath : progressPath : _ -> do
      code <- processChildMain entrypoints specPath progressPath
      exitWith (if code == 0 then ExitSuccess else ExitFailure code)
    _ -> pure ()

-- ---------------------------------------------------------------------------
-- The parent

-- | How to start a child; the spec and progress paths are appended.
data ChildCommand = ChildCommand
  { executable :: FilePath
  , arguments :: [String]
  }
  deriving stock (Eq, Show)

-- | The running executable, with the hidden child argument.
selfChildCommand :: IO ChildCommand
selfChildCommand = do
  executable <- getExecutablePath
  pure ChildCommand {executable, arguments = [childFlag]}

-- | @run_process_scenario@: run one complete scenario in a new session
-- (process group) under the wall-clock watchdog — @SIGTERM@ to the group
-- at the deadline, @SIGKILL@ after the grace period — and fold its
-- progress. 'Left' is a refusal before launch.
runProcessScenario :: ChildCommand -> ProcessRunSpec -> IO (Either DstFailure ProcessRunResult)
runProcessScenario command spec = case pProcessRunSpec [] (toJson spec) of
  Left e -> pure (Left (ContractViolation "ValidationError" (renderSchemaError "ProcessRunSpec" e)))
  Right _ -> case canonicalBytes (toJson spec) of
    Left message -> pure (Left (ContractViolation "ValueError" message))
    Right encoded
      | toInteger (BS.length encoded) > spec.budget.inputBytes ->
          pure
            ( Left
                ( ContractViolation
                    "ValueError"
                    ("DST process run spec has " <> tshow (BS.length encoded) <> " bytes; limit is " <> tshow spec.budget.inputBytes)
                )
            )
      | otherwise -> Right <$> launch encoded
  where
    launch encoded = do
      temporary <- getTemporaryDirectory
      bracket (mkdtemp (temporary </> "petrus-dst-runner-")) removeDirectoryRecursive $ \root -> do
        let specPath = root </> "spec.json"
            progressPath = root </> "progress.jsonl"
        BS.writeFile specPath encoded
        devNull <- openFile "/dev/null" ReadWriteMode
        -- An interrupted caller (an hspec timeout, 'cancel') kills and reaps
        -- the child's group before the bracket removes its directory.
        (code, termination, timedOut) <- mask $ \restore -> do
          (_, _, _, handle) <-
            createProcess
              (proc command.executable (command.arguments ++ [specPath, progressPath]))
                { std_in = UseHandle devNull
                , std_out = UseHandle devNull
                , std_err = UseHandle devNull
                , new_session = True
                }
          restore (supervise handle)
            `onException` (signalGroup handle sigKILL >> void (waitForProcess handle))
        exists <- doesFileExist progressPath
        bytes <- if exists then Just <$> BS.readFile progressPath else pure Nothing
        pure (processResult spec (exitNumber code) termination timedOut bytes)
    supervise handle = do
      exited <- waitFor handle (fromInteger spec.budget.wallClockMs)
      case exited of
        Just code -> pure (code, Exited, False)
        Nothing -> do
          signalGroup handle sigTERM
          graceful <- waitFor handle (fromInteger spec.budget.terminationGraceMs)
          case graceful of
            Just code -> pure (code, Terminated, True)
            Nothing -> do
              signalGroup handle sigKILL
              code <- waitForProcess handle
              pure (code, Killed, True)

-- | Wait up to the given milliseconds against a monotonic deadline.
waitFor :: ProcessHandle -> Double -> IO (Maybe ExitCode)
waitFor handle milliseconds = do
  start <- getMonotonicTime
  let deadline = start + milliseconds / 1000
      loop delay = do
        status <- getProcessExitCode handle
        case status of
          Just code -> pure (Just code)
          Nothing -> do
            now <- getMonotonicTime
            if now >= deadline
              then pure Nothing
              else do
                threadDelay (min delay (max 1 (ceiling ((deadline - now) * 1e6))))
                loop (min 5000 (delay * 2))
  loop 100

-- | @_signal_process_group@: signal the child's group unless it has exited.
signalGroup :: ProcessHandle -> Signal -> IO ()
signalGroup handle requested = do
  status <- getProcessExitCode handle
  case status of
    Just _ -> pure ()
    Nothing -> do
      pid <- getPid handle
      case pid of
        Nothing -> pure ()
        Just p -> signalProcessGroup requested p `catch` \e -> unless (isDoesNotExistError e) (throwIO e)

exitNumber :: ExitCode -> Int
exitNumber = \case
  ExitSuccess -> 0
  ExitFailure n -> n

tshow :: (Show a) => a -> Text
tshow = T.pack . show


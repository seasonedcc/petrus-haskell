{-# LANGUAGE RecordWildCards #-}

-- | The test doubles of @tests/unit/agents/test_pi.py@ (@Operation@,
-- @Runtime@, @Workspace@, @Workspaces@ and the @runner(...)@ helper), shared
-- by this package's specs, the host's coding-activity specs, and the
-- benchmarks.
module Hamsterdan.Agents.Pi.Doubles
  ( -- * Constants
    testUrl
  , testWorkspaceArchive
  , readPolicy

    -- * Operations
  , FakeOperation (..)
  , newFakeOperation
  , fakePiOperation

    -- * Workspaces
  , FakeWorkspaces (..)
  , newFakeWorkspaces
  , fakeProvider

    -- * Runtimes
  , FakeRuntime (..)
  , newFakeRuntime
  , fakePiRuntime
  , fakeRunner
  , fakeRunnerFor

    -- * An installed Pi package
  , piPackageFixture
  ) where

import Control.Exception (ErrorCall (..), throwIO)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.IORef
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Pi
import Petrus.Agenticus.Error (throwLeft)
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), mkRuntimeOperationCleanup)
import Petrus.Agenticus.Runtime.PiA2Host (PiA2RuntimePolicy, PiA2RuntimeStart (..), mkPiA2RuntimePolicy)
import Petrus.Agenticus.Runtime.Result (mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Identity (EpisodeId, TurnId, literalEpisodeId, literalTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (Json (..), defaultDumps, dumpsText)
import Petrus.Agenticus.Runtime.Pi (piAiVersion, piSdkVersion)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (setFileMode)

-- | @URL@.
testUrl :: Text
testUrl = "https://example.invalid/owner/repo.git"

-- | @WORKSPACE_ARCHIVE@: an empty tar archive.
testWorkspaceArchive :: ByteString
testWorkspaceArchive = BS.replicate 10240 0

-- | @READ_POLICY@.
readPolicy :: PiA2RuntimePolicy
readPolicy = unsafePerformIO (throwLeft (mkPiA2RuntimePolicy [WorkspaceRead] [] 16 []))
{-# NOINLINE readPolicy #-}

-- | @Operation(operation, outcome=..., clean=...)@ and its subclasses: the
-- overrides stand for the tests' replaced methods.
data FakeOperation = FakeOperation
  { operationId :: IORef Text
  , outcome :: TurnOutcome
  , clean :: Bool
  , waits :: IORef Int
  , cancellations :: IORef [Text]
  , closed :: IORef Int
  , episodeId :: IORef EpisodeId
  , turnId :: IORef TurnId
  , waitOverride :: IORef (Maybe (Maybe Double -> IO ()))
  -- ^ Runs before the default settlement; throwing replaces it.
  , cancelOverride :: IORef (Maybe (Text -> IO ()))
  , identityBroken :: IORef Bool
  }

newFakeOperation :: Text -> TurnOutcome -> Bool -> IO FakeOperation
newFakeOperation identity outcome clean = do
  operationId <- newIORef identity
  waits <- newIORef 0
  cancellations <- newIORef []
  closed <- newIORef 0
  episodeId <- newIORef (literalEpisodeId "unset")
  turnId <- newIORef (literalTurnId "unset")
  waitOverride <- newIORef Nothing
  cancelOverride <- newIORef Nothing
  identityBroken <- newIORef False
  pure FakeOperation {..}

fakePiOperation :: FakeOperation -> PiOperation
fakePiOperation op =
  PiOperation
    { operationId = do
        broken <- readIORef op.identityBroken
        if broken then throwIO (ErrorCall "private runtime identity diagnostic") else readIORef op.operationId
    , wait = \bound -> do
        modifyIORef' op.waits (+ 1)
        readIORef op.waitOverride >>= maybe (pure ()) ($ bound)
        episode <- readIORef op.episodeId
        turn <- readIORef op.turnId
        let completed = op.outcome == TurnCompleted
        throwLeft $
          mkRuntimeTurnSettlement
            episode
            turn
            op.outcome
            (if completed then 1 else 0)
            (if completed then "turn-completed" else "runtime-failed")
            (if completed then Just "output:one" else Nothing)
            Nothing
    , cancel = \reason -> do
        modifyIORef' op.cancellations (<> [reason])
        readIORef op.cancelOverride >>= maybe (pure ()) ($ reason)
    , close = do
        modifyIORef' op.closed (+ 1)
        identity <- readIORef op.operationId
        throwLeft $
          mkRuntimeOperationCleanup
            identity
            (if op.clean then RuntimeCleanupClean else RuntimeCleanupUnverified)
            (if op.clean then "client-closed" else "cleanup-uncertain")
            False
    }

-- | @Workspaces(changed)@ with its one @Workspace@.
data FakeWorkspaces = FakeWorkspaces
  { changed :: [Text]
  , received :: IORef [ByteString]
  , opens :: IORef [(Text, Text)]
  }

newFakeWorkspaces :: [Text] -> IO FakeWorkspaces
newFakeWorkspaces changed = FakeWorkspaces changed <$> newIORef [] <*> newIORef []

fakeProvider :: FakeWorkspaces -> PiWorkspaceProvider
fakeProvider w = PiWorkspaceProvider $ \kind _ _ operationId body -> do
  modifyIORef' w.opens (<> [(promptKindText kind, operationId)])
  body
    PreparedPiWorkspace
      { archive = testWorkspaceArchive
      , digest = TE.decodeUtf8 (Base16.encode (SHA256.hash testWorkspaceArchive))
      , correlation = "synthetic-workspace"
      , policy = readPolicy
      , reconcile = \archive -> do
          modifyIORef' w.received (<> [archive])
          pure (if null w.changed then "" else "canonical diff", w.changed)
      }

-- | @Runtime(operation, output, archive)@.
data FakeRuntime = FakeRuntime
  { operation :: FakeOperation
  , output :: IORef Text
  , archive :: IORef ByteString
  , archiveOverride :: IORef (Maybe (Text -> IO ByteString))
  , started :: IORef [PiA2RuntimeStart]
  , loadedOutputs :: IORef [Text]
  , loadedArchives :: IORef [Text]
  , workspaces :: FakeWorkspaces
  }

newFakeRuntime :: FakeOperation -> Text -> [Text] -> IO FakeRuntime
newFakeRuntime operation output0 changed = do
  output <- newIORef output0
  archive <- newIORef "archive"
  archiveOverride <- newIORef Nothing
  started <- newIORef []
  loadedOutputs <- newIORef []
  loadedArchives <- newIORef []
  workspaces <- newFakeWorkspaces changed
  pure FakeRuntime {..}

fakePiRuntime :: FakeRuntime -> PiRuntime
fakePiRuntime r =
  PiRuntime
    { start = \value -> do
        modifyIORef' r.started (<> [value])
        writeIORef r.operation.episodeId value.episodeId
        writeIORef r.operation.turnId value.turnId
        pure (fakePiOperation r.operation)
    , loadOutput = \reference -> do
        modifyIORef' r.loadedOutputs (<> [reference])
        readIORef r.output
    , loadWorkspaceArchive = \operationId -> do
        modifyIORef' r.loadedArchives (<> [operationId])
        readIORef r.archiveOverride >>= \case
          Just override -> override operationId
          Nothing -> readIORef r.archive
    }

-- | @PiNativeRunner(runtime, runtime.workspaces, **options)@.
fakeRunnerFor :: FakeRuntime -> PiRunnerOptions -> IO PiNativeRunner
fakeRunnerFor r options =
  either (throwIO . ErrorCall . show) pure (newPiNativeRunner (fakePiRuntime r) (fakeProvider r.workspaces) options)

-- | @runner(result, operation)@: the operation's identity becomes
-- @pi_operation(identity)@, the output is @json.dumps(result)@, and the
-- workspace reports the result's @changed_files@.
fakeRunner :: Json -> FakeOperation -> IO (PiNativeRunner, FakeRuntime)
fakeRunner result operation = do
  modifyIORef' operation.operationId (`piOperationId` 1)
  let changed = case result of
        Object members | Just (Array files) <- lookup "changed_files" members -> [s | String s <- files]
        _ -> []
      rendered = either (const "") id (dumpsText defaultDumps result)
  r <- newFakeRuntime operation rendered changed
  subject <- fakeRunnerFor r defaultPiRunnerOptions
  pure (subject, r)

-- | An installed Pi coding-agent package and a Node stand-in that answers
-- @--version@ and the helper probe, below @root@: the CLI, Node and
-- package-root paths of a @PiA2InstallationConfig@.
piPackageFixture :: FilePath -> IO (FilePath, FilePath, FilePath)
piPackageFixture root = do
  let package = root </> "package"
      ai = package </> "node_modules" </> "@earendil-works" </> "pi-ai"
  createDirectoryIfMissing True (package </> "dist")
  createDirectoryIfMissing True ai
  BS.writeFile (package </> "dist" </> "cli.js") "fixture"
  BS.writeFile (package </> "dist" </> "index.js") "fixture"
  writeJson
    (package </> "package.json")
    ( Object
        [ ("name", String "@earendil-works/pi-coding-agent")
        , ("version", String piSdkVersion)
        , ("bin", Object [("pi", String "dist/cli.js")])
        , ("main", String "dist/index.js")
        , ("dependencies", Object [("@earendil-works/pi-ai", String piAiVersion)])
        ]
    )
  writeJson (ai </> "package.json") (Object [("name", String "@earendil-works/pi-ai"), ("version", String piAiVersion)])
  let node = root </> "node"
  BS.writeFile
    node
    "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf \"v22.19.0\\n\"; else printf '{\"type\":\"probe\",\"ok\":true}\\n'; fi\n"
  setFileMode node 0o700
  pure (package </> "dist" </> "cli.js", node, package)
  where
    writeJson path value = either (throwIO . userError . show) (BS.writeFile path . TE.encodeUtf8) (dumpsText defaultDumps value)

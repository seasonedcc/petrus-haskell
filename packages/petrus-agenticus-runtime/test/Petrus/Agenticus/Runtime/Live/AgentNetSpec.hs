-- | @tests/petrus/agenticus/runtime/test_agent_net_real.py@: the exact
-- credential-free Agent-as-a-Net probe and the direct-key binding cell.
--
-- The model phase runs the runtime's own @pi_model_phase_helper.mjs@ on
-- the explicitly selected @node@ and Pi package, as in production.
module Petrus.Agenticus.Runtime.Live.AgentNetSpec (spec) where

import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (MotusAttachmentBinding, bindingCancel, bindingCleanupResult, bindingExecution, bindingSettle, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment, episodeDeadline, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (capabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( ConnectionIdentity
  , ConnectionStatus (..)
  , ConnectionView (..)
  , ErasureResult (..)
  , RevocationResult (..)
  , erase
  , lookupConnection
  , mkConnectionIdentity
  , revoke
  )
import Petrus.Agenticus.Connection.Key (KeyOperations (..))
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..))
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), capabilityScopedHands)
import Petrus.Agenticus.Hands.Grants (grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (newMotusWorkspaceAdapter, defaultCommandTimeout, workspaceHandsAdapter)
import Petrus.Agenticus.Program.AgentNet (StopReason (..), handsActivity, mkLoopState, modelPhaseActivity, stopReasonText, terminalCodeText)
import Petrus.Agenticus.Runtime.AgentNetRunner
  ( AgentNetRunner
  , closeRunner
  , createRunner
  , drain
  , projectionSettled
  , runnerEngine
  )
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Live.Support
import Petrus.Agenticus.Runtime.Pi (piAiVersion, piSdkVersion)
import Petrus.Agenticus.Runtime.PiModelPhase
  ( PiModelPhaseAdapter
  , PiModelPhaseConfig (..)
  , PiModelPhaseContinuationPayloadV1
  , PiModelPhaseCustody (..)
  , PiModelPhaseOperations (..)
  , PiModelPhaseOutputPayloadV1
  , PiModelPhasePublication
  , mkPiModelPhasePublication
  , modelPhaseAdapterActivity
  , newPiModelPhaseAdapter
  , piModelPhaseConfig
  , piModelPhaseHelperPath
  , probeModelPhase
  )
import Petrus.Agenticus.Runtime.Profiles (TerritoryProfile (..), agentAsNetA5Local, territoryIdentity)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkThreadId)
import Petrus.Agenticus.Thread.Lifecycle (EpisodeOutcome (..), TurnOutcome (..), newThread)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.History.Records (ActivityRequested (..), Record (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution (defaultSpec, providerLookup)
import Petrus.Motus.Execution qualified as Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (canonicalizePath, createDirectory, doesDirectoryExist, doesPathExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout qualified as Timeout
import Test.Hspec

provider', model', host, connectionName :: Text
provider' = "anthropic"
model' = "claude-sonnet-4-5"
host = "agent-net-live-host"
connectionName = "agent-net-live"

identity :: ConnectionIdentity
identity = ok (mkConnectionIdentity connectionName provider' (sha256Text "agent-net-live-account") "api-key")

expectedConnection :: ConnectionView
expectedConnection = ConnectionView identity StatusReady 1 1 Nothing

-- | @_Operations@: private payload custody kept outside both durable
-- process stores.
data Operations = Operations
  { outputs :: IORef (Map Text PiModelPhaseOutputPayloadV1)
  , continuations :: IORef (Map Text PiModelPhaseContinuationPayloadV1)
  , published :: IORef (Map Text PiModelPhasePublication)
  }

newOperations :: IO Operations
newOperations = Operations <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef Map.empty

clearOperations :: Operations -> IO ()
clearOperations o = writeIORef o.outputs Map.empty >> writeIORef o.continuations Map.empty >> writeIORef o.published Map.empty

privateOperations :: Operations -> PiModelPhaseOperations
privateOperations o =
  PiModelPhaseOperations
    { loadContinuation = \reference -> lookupOr reference =<< readIORef o.continuations
    , publish = \operationId output continuation ->
        Map.lookup operationId <$> readIORef o.published >>= \case
          Just prior -> do
            priorOutput <- lookupOr prior.outputReference =<< readIORef o.outputs
            priorContinuation <- lookupOr prior.continuationReference =<< readIORef o.continuations
            when (priorOutput /= output || priorContinuation /= continuation) $
              failWith "Agent-as-a-Net private publication conflict"
            pure prior
          Nothing -> do
            ordinal <- (+ 1) . Map.size <$> readIORef o.published
            let suffix = T.pack (show ordinal)
            publication <- either (failWith . show) pure (mkPiModelPhasePublication ("agent-net-output-" <> suffix) ("agent-net-continuation-" <> suffix))
            modifyIORef' o.outputs (Map.insert publication.outputReference output)
            modifyIORef' o.continuations (Map.insert publication.continuationReference continuation)
            modifyIORef' o.published (Map.insert operationId publication)
            pure publication
    }
  where
    lookupOr reference values = maybe (failWith ("KeyError: " <> T.unpack reference)) pure (Map.lookup reference values)

-- | @_CustodyBridge@: probe before authority, then delegate only to
-- production custody.
custodyBridge :: IORef (Maybe HostConnectionCustody) -> PiModelPhaseCustody
custodyBridge ref =
  PiModelPhaseCustody
    { materialize = \connection host' mode ttl operation -> target >>= \c -> c.materialize connection host' mode ttl operation
    , admitResult = \fence operation -> target >>= \c -> c.admitResult fence operation
    , release = \materialization operation -> target >>= \c -> c.release materialization operation
    }
  where
    target = readIORef ref >>= maybe (failWith "credential-free probe may not materialize authority") pure

-- | @_OperationsBridge@.
operationsBridge :: IORef (Maybe PiModelPhaseOperations) -> PiModelPhaseOperations
operationsBridge ref =
  PiModelPhaseOperations
    { loadContinuation = \reference -> target >>= \o -> o.loadContinuation reference
    , publish = \operationId output continuation -> target >>= \o -> o.publish operationId output continuation
    }
  where
    target = readIORef ref >>= maybe (failWith "credential-free probe may not load or publish private values") pure

-- | @_required_path(name, directory=...)@.
requiredPath :: String -> Bool -> IO FilePath
requiredPath name directory = do
  value <- required name ("Agent-as-a-Net qualification requires " <> name)
  exists <- doesPathExist value
  unless exists $ failWith ("Agent-as-a-Net qualification cannot resolve " <> name)
  path <- canonicalizePath value
  isDirectory <- doesDirectoryExist path
  check (directory == isDirectory) ("Agent-as-a-Net qualification received the wrong " <> name <> " path kind")
  pure path

-- | @_required_handoff@.
requiredHandoff :: IO FilePath
requiredHandoff = do
  value <- required "PETRUS_CV16_AGENT_NET_AUTH_FILE" "Agent-as-a-Net qualification requires its authority handoff"
  check (take 1 value == "/") "Agent-as-a-Net authority handoff must be absolute"
  pure value

handoffMessages :: HandoffMessages
handoffMessages =
  HandoffMessages
    { missing = "the approved Agent-as-a-Net handoff is unavailable"
    , inspect = "the approved Agent-as-a-Net handoff is unavailable"
    , custodyInvariant = "the approved Agent-as-a-Net handoff failed private-file custody"
    , open = "the approved Agent-as-a-Net handoff changed during transfer"
    , read = "the approved Agent-as-a-Net handoff changed during transfer"
    , changedDuringTransfer = "the approved Agent-as-a-Net handoff changed during transfer"
    , notAuthority = "the approved Agent-as-a-Net handoff is not direct API-key authority"
    , changedBeforeCustody = "the approved Agent-as-a-Net handoff changed before DS2 acceptance"
    , notConsumed = "the approved Agent-as-a-Net handoff was not consumed"
    , consume = "the approved Agent-as-a-Net handoff was not consumed"
    }

-- | @_adapter@: the model-phase adapter over a private runtime root.
adapterFor :: FilePath -> PiModelPhaseCustody -> PiModelPhaseOperations -> IO PiModelPhaseAdapter
adapterFor root custody operations = do
  let runtime = root </> "phase-runtime"
  createDirectory runtime
  setFileMode runtime 0o700
  node <- requiredPath "PETRUS_CV16_AGENT_NET_NODE" False
  newPiModelPhaseAdapter
    (piModelPhaseConfig provider' model' host runtime "agent-net-live-episode" "agent-net-live-turn")
      { systemPrompt = "Follow the bounded task exactly. Use only the supplied Agenticus tools and never invent workspace data."
      , observation =
          "Call workspace_read exactly once with path marker.txt. After its result, call no more tools and reply with the exact marker content."
      , timeout = 240
      }
    expectedConnection
    custody
    operations
    node
    Nothing
    Nothing

-- | @_probe@: the exact @node@ and Pi packages, then the adapter's own
-- credential-free probe.
probeExact :: PiModelPhaseAdapter -> IO (FilePath, FilePath)
probeExact adapter = do
  package <- requiredPath "PETRUS_CV16_AGENT_NET_PACKAGE_ROOT" True
  node <- requiredPath "PETRUS_CV16_AGENT_NET_NODE" False
  (code, out, _) <- readCreateProcessWithExitCode (proc node ["--version"]) ""
  code `shouldBe` ExitSuccess
  T.strip (T.pack out) `shouldBe` "v22.19.0"
  let manifest path = do
        value <- either (failWith . show) pure . J.parseJson J.surrogateRefusingLoads =<< B.readFile path
        pure (member "name" value, member "version" value)
  manifest (package </> "package.json") `shouldReturn` (Just (String "@earendil-works/pi-coding-agent"), Just (String piSdkVersion))
  manifest (package </> "node_modules/@earendil-works/pi-ai/package.json") `shouldReturn` (Just (String "@earendil-works/pi-ai"), Just (String piAiVersion))
  manifest (package </> "node_modules/@earendil-works/pi-agent-core/package.json")
    `shouldReturn` (Just (String "@earendil-works/pi-agent-core"), Just (String piSdkVersion))
  probeModelPhase adapter package `shouldReturn` True
  pure (node, package)

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

-- | Objects with their members sorted, recursively: Python's @dict@
-- equality ignores order.
normalized :: Json -> Json
normalized = \case
  Object members -> Object (sortOn fst [(k, normalized v) | (k, v) <- members])
  Array items -> Array (map normalized items)
  value -> value

parse :: ByteString -> IO Json
parse = either (failWith . show) pure . J.parseJson J.surrogateRefusingLoads

spec :: Spec
spec = describe "test_agent_net_real" $ do
  live
    "test_exact_agent_net_pi_installation_and_public_phase"
    "PETRUS_CV16_AGENT_NET_QUALIFY"
    "the exact credential-free Agent-as-a-Net probe"
    $ withSystemTempDirectory "agent-net-qualify"
    $ \tmp -> do
      custody <- newIORef Nothing
      operations <- newIORef Nothing
      adapter <- adapterFor tmp (custodyBridge custody) (operationsBridge operations)
      (node, package) <- probeExact adapter
      helper <- piModelPhaseHelperPath
      result <-
        Timeout.timeout 20000000 $
          readCreateProcessWithExitCode
            (proc node [helper, package </> "dist/index.js", "--test-probe"])
              { env = Just [("HOME", tmp), ("PATH", takeDirectory node), ("LANG", "C.UTF-8"), ("LC_ALL", "C.UTF-8")]
              }
            ""
      (code, out, err) <- maybe (failWith "the test probe timed out") pure result
      (code, err) `shouldBe` (ExitSuccess, "")
      frame <- parse (TE.encodeUtf8 (T.pack out))
      normalized frame
        `shouldBe` normalized
          ( Object
              [ ("type", String "test-probe")
              , ("ok", Bool True)
              , ("stream_calls", Int 1)
              , ("convert", Bool True)
              , ("tool_execute", Bool False)
              , ("network", Bool False)
              , ("complete", Bool True)
              ]
          )

  live
    "test_agent_net_direct_anthropic_key_runs_one_bounded_local_task"
    "PETRUS_CV16_AGENT_NET_LIVE"
    "the direct-key Agent-as-a-Net binding cell"
    $ withSystemTempDirectory "agent-net-live"
    $ \tmp -> do
      handoff <- requiredHandoff
      custodyRef <- newIORef Nothing
      operationsRef <- newIORef Nothing
      adapter <- adapterFor tmp (custodyBridge custodyRef) (operationsBridge operationsRef)
      -- The exact package and credential-free helper gate before authority
      -- transfer.
      _ <- probeExact adapter
      (authority, handoffIdentity) <- readHandoff handoffMessages handoff 8192 True "sk-ant-"
      (keys, retained) <- perConnectionKeys
      c <- openLiveCustody tmp keys
      operations <- newOperations
      runnerRef <- newIORef (Nothing :: Maybe AgentNetRunner)
      attachmentRef <- newIORef (Nothing :: Maybe EpisodeAttachment)
      bindingRef <- newIORef (Nothing :: Maybe MotusAttachmentBinding)
      let cleanup =
            ( readIORef runnerRef >>= \case
                Just runner -> closeRunner runner >> writeIORef runnerRef Nothing
                Nothing -> pure ()
            )
              `withCleanup` ( ( do
                                  attachment <- readIORef attachmentRef
                                  binding <- readIORef bindingRef
                                  case (attachment, binding) of
                                    (Just a, _) -> do
                                      done <- Episode.settled a
                                      unless done $ Episode.cancel a "qualification-cleanup" >> () <$ Episode.settle a 15
                                    (Nothing, Just b) -> do
                                      cleaned <- bindingCleanupResult b
                                      when (isNothing cleaned) $ bindingCancel b "qualification-cleanup" >> () <$ bindingSettle b
                                    (Nothing, Nothing) -> pure ()
                              )
                                `withCleanup` ( ( tryAny (lookupConnection c.custody connectionName) >>= \case
                                                    Left _ -> pure ()
                                                    Right current -> do
                                                      current' <-
                                                        if current.status == StatusReady
                                                          then revoke c.custody connectionName "agent-net-live-revoke" >> lookupConnection c.custody connectionName
                                                          else pure current
                                                      unless (current'.status == StatusReauthorizationRequired) $
                                                        () <$ erase c.custody connectionName "agent-net-live-erase"
                                                )
                                                  `withCleanup` (() <$ keys.erase connectionName >> clearOperations operations)
                                              )
                            )
      flip withCleanup c.storage.close . flip withCleanup cleanup $ do
        _ <- authorizeLive c host "agent-net-live-enroll" identity authority "agent-net-live-authorize"
        current <- lookupConnection c.custody connectionName
        (current.identity, current.status, current.authorityEpoch, current.stateVersion)
          `shouldBe` (expectedConnection.identity, expectedConnection.status, expectedConnection.authorityEpoch, expectedConnection.stateVersion)
        writeIORef custodyRef . Just =<< hostConnectionCustody c.custody
        writeIORef operationsRef (Just (privateOperations operations))
        consumeHandoff handoffMessages handoff handoffIdentity

        marker' <- marker "AGENT_NET_" 12
        let source = tmp </> "workspace-source"
        createDirectory source
        writeFile (source </> "marker.txt") (T.unpack marker')
        provider <- localProvider <$> newLocalProcessEnvironment
        archive <- workspaceArchive source
        binding <- openMotusBinding provider "agent-net-live-territory" defaultSpec archive (sha256Text (TE.encodeUtf8 marker'))
        writeIORef bindingRef (Just binding)
        let snapshot = ok (mkResolutionSnapshot 1 [agentAsNetA5Local, capabilityScopedHands, capabilityDescriptor (territoryIdentity Local) [] []])
        now <- getMonotonicTime
        attachment <-
          newEpisodeAttachment (ok (mkEpisodeId "agent-net-live-episode")) snapshot (motusBinding binding) "agent-net-live-attachment" (now + 600) episodeOptions
        writeIORef attachmentRef (Just attachment)
        grant <- openGrant (Episode.grants attachment) (grantSpec [WorkspaceRead] (episodeDeadline attachment) 2)
        execution <- bindingExecution binding
        workspace <- newMotusWorkspaceAdapter provider execution ["/usr/bin/true"] defaultCommandTimeout
        let initial = ok (mkLoopState "agent-net-live-episode" "agent-net-live-turn" 1 3 0 2 Nothing Nothing grant.grantEpoch ["workspace_read"] [])
            thread = ok (newThread (ok (mkThreadId "agent-net-live-thread")) Nothing)
            root = tmp </> "runner"
        createDirectory root
        active <-
          createRunner root "agent-net-live-instance" thread initial attachment (modelPhaseAdapterActivity adapter) (workspaceHandsAdapter workspace)
        writeIORef runnerRef (Just active)

        projection <- drain active 64

        projectionSettled projection `shouldBe` True
        (terminalCodeText . (.code) <$> projection.terminal) `shouldBe` Just "completed"
        (length projection.appends, length projection.hands) `shouldBe` (2, 1)
        episode <- case Seq.viewr projection.thread.episodes of
          _ Seq.:> e -> pure e
          Seq.EmptyR -> failWith "the projected Thread has no Episode"
        episode.acceptedAppends `shouldBe` 2
        lastTurn <- case Seq.viewr episode.turns of
          _ Seq.:> t -> pure t
          Seq.EmptyR -> failWith "the projected Episode has no Turn"
        lastTurn.outcome `shouldBe` Just TurnCompleted
        episode.settlement `shouldBe` Just EpisodeCompleted
        lastAppend <- case reverse projection.appends of
          a : _ -> pure a
          [] -> failWith "no projected append"
        ((.stateReference) <$> episode.nextContinuation) `shouldBe` Just lastAppend.continuationReference

        records <- Engine.records (runnerEngine active)
        let requests = [r | RActivityRequested r <- records]
            completions = [() | RActivityCompleted _ <- records]
        map (.activity) requests `shouldBe` [modelPhaseActivity, handsActivity, modelPhaseActivity]
        length completions `shouldBe` 3
        handsRequest <- case requests of
          _ : r : _ -> pure r.input
          _ -> failWith "no Hands request"
        let proposal = member "proposal" handsRequest
        (proposal >>= member "method") `shouldBe` Just (String "workspace_read")
        (proposal >>= member "params") `shouldBe` Just (Object [("path", String "marker.txt")])

        continuations <- readIORef operations.continuations
        outputs <- readIORef operations.outputs
        firstAppend <- case projection.appends of
          a : _ -> pure a
          [] -> failWith "no projected append"
        let transcript append = maybe (failWith "no private continuation") (pure . (.transcriptJson)) (Map.lookup append.continuationReference continuations)
        first <- transcript firstAppend
        second <- transcript lastAppend
        firstMessages <- parse first
        secondMessages <- parse second
        (firstItems, secondItems) <- case (firstMessages, secondMessages) of
          (Array a, Array b) -> pure (a, b)
          _ -> failWith "private transcripts are not message arrays"
        map normalized (take (length firstItems) secondItems) `shouldBe` map normalized firstItems
        let results = [m | m <- secondItems, member "role" m == Just (String "toolResult")]
        length results `shouldBe` 1
        resultText <- case results of
          [m] | Just (Array (content : _)) <- member "content" m, Just (String text) <- member "text" content -> pure text
          _ -> failWith "the tool result carries no text"
        modelResult <- parse (TE.encodeUtf8 resultText)
        (case modelResult of Object ms -> Set.fromList (map fst ms); _ -> Set.empty) `shouldBe` Set.fromList ["version", "ok", "data", "error"]
        member "ok" modelResult `shouldBe` Just (Bool True)
        (member "data" modelResult >>= member "content") `shouldBe` Just (String marker')
        finalOutput <- maybe (failWith "no private output") (pure . (.assistantJson)) (Map.lookup lastAppend.outputReference outputs)
        finalMessage <- parse finalOutput
        let texts = case member "content" finalMessage of
              Just (Array items) -> T.concat [t | item <- items, Just (String t) <- [member "text" item]]
              _ -> ""
        (marker' `T.isInfixOf` texts) `shouldBe` True
        member "stopReason" finalMessage `shouldBe` Just (String (stopReasonText Stop))
        privateTranscript <-
          either (failWith . show) pure (J.dumpsText J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} secondMessages)
        coordinates <- Episode.coordinates attachment
        (coordinates.attachmentId `T.isInfixOf` privateTranscript) `shouldBe` False
        forM_ ["attachment_id", "attachment_epoch", "grant_epoch"] $ \name -> (name `T.isInfixOf` privateTranscript) `shouldBe` False

        historyText <- TE.decodeUtf8 <$> B.readFile (root </> "history.jsonl")
        threadBytes <- B.readFile (root </> "thread.json")
        let threadText = TE.decodeUtf8 threadBytes
        (marker' `T.isInfixOf` historyText, marker' `T.isInfixOf` threadText) `shouldBe` (True, False)
        forM_ ["api_key", "ANTHROPIC_API_KEY", privateTranscript] $ \value ->
          (value `T.isInfixOf` (historyText <> threadText)) `shouldBe` False
        ("sk-ant-" `T.isInfixOf` (historyText <> threadText <> privateTranscript)) `shouldBe` False
        threadJson <- parse threadBytes
        threadDump <- either (failWith . show) pure (J.dumpsText J.defaultDumps (maybe Null id (member "thread" threadJson)))
        ("\"attachment\"" `T.isInfixOf` threadDump) `shouldBe` False

        Episode.settled attachment `shouldReturn` True
        lastSettlement <- maybe (failWith "no last settlement") pure =<< Episode.lastSettlement attachment
        lastSettlement.settlement.verified `shouldBe` True
        (second `B.isInfixOf` lastSettlement.archive) `shouldBe` False
        (BC.pack "sk-ant-" `B.isInfixOf` lastSettlement.archive) `shouldBe` False
        (fmap Execution.cleanupVerified <$> bindingCleanupResult binding) `shouldReturn` Just True
        (isNothing <$> providerLookup provider "agent-net-live-territory") `shouldReturn` True
        isEmptyDirectory (tmp </> "phase-runtime") `shouldReturn` True
        isEmptyDirectory c.materialized `shouldReturn` True
        leasesReleased c `shouldReturn` True

        revoked <- revoke c.custody connectionName "agent-net-live-revoke"
        revoked.connection.status `shouldBe` StatusRevoked
        erased <- erase c.custody connectionName "agent-net-live-erase"
        erased.connection.status `shouldBe` StatusReauthorizationRequired
        (erased.connection.stateVersion, erased.connection.authorityEpoch) `shouldBe` (2, 2)
        erased.connection.stateDigest `shouldBe` Nothing
        retained `shouldReturn` 0
        clearOperations operations
        (Map.null <$> readIORef operations.outputs) `shouldReturn` True

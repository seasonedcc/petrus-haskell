-- | @tests/petrus/agenticus/runtime/test_pi_a2_host.py@: deterministic
-- conformance for the supported Petrus-owned Pi A2 host.
--
-- The reference's @Keys@, @Plan@, @Client@, @Factory@ and @Authority@
-- fixtures are ported one to one. Its two child-process tests run
-- @python -c@ against the test module; here they re-execute this test binary
-- with @PETRUS_PI_A2_HOST_CHILD@ set, and 'child' plays the script.
module Petrus.Agenticus.Runtime.PiA2HostSpec (spec, child) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (finally, throwIO, try)
import Control.Monad (forM_, forever, unless, void, when)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (AttachmentCoordinates (..))
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorIdentity (..))
import Petrus.Agenticus.Catalog.Resolution (snapshotDescriptor)
import Petrus.Agenticus.Connection.Custody (ConnectionIdentity, mkConnectionIdentity)
import Petrus.Agenticus.Connection.Key (KeyOperations (..), ScrubbedBytes)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), ToolResult (..), allToolMethods)
import Petrus.Agenticus.Hands.Gateway qualified as Gateway
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), RuntimeOperationCleanup (..), cleanupVerified, runtimeProtocolError, runtimeProtocolErrorCode)
import Petrus.Agenticus.Runtime.Pi
  ( PiCandidate (..)
  , PiContinuationPayloadV1 (..)
  , PiHelperArgs (..)
  , PiHelperClient (..)
  , PiHelperFactory (..)
  , PiHelperResult (..)
  , PiRuntimeInvocation (..)
  , adapterConfig
  , piDurableWorkFingerprint
  )
import Petrus.Agenticus.Runtime.PiA2Host
import Petrus.Agenticus.Runtime.PiRecovery (ledgerAdmit, ledgerClose, ledgerLookup, recordSettlement)
import Petrus.Agenticus.Runtime.PiSupport (aesKeys, claimed, ok, raises, waitUntil, withTemp)
import Petrus.Agenticus.Runtime.Profiles (piNativeA2Local)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..))
import Petrus.Agenticus.Thread.Continuation (Continuation)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Motus.Execution (CleanupDisposition (..), CleanupResult (..), EnvironmentProvider (..), leaseIdentity)
import Petrus.Motus.Execution qualified as Motus
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (..), withFile)
import System.Posix.Files (setFileMode)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
import System.Timeout (timeout)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Fixtures

sessionId :: Text
sessionId = "11111111-1111-4111-8111-111111111111"

apiKey :: ByteString
apiKey = "host-factory-api-key-canary"

-- | @_session()@.
sessionBytes :: ByteString
sessionBytes =
  "{\"type\":\"session\",\"version\":3,\"id\":\""
    <> TE.encodeUtf8 sessionId
    <> "\"}\n{\"type\":\"message\",\"body\":\"session-canary\"}\n"

-- | @Plan@.
data Plan = Plan
  { text :: Text
  , clean :: Bool
  , failure :: Maybe Text
  , hands :: Bool
  , readPath :: Maybe Text
  , block :: Bool
  , delay :: Double
  , ignoreCancel :: Bool
  , writeExpected :: Maybe Bool
  , writePath :: Text
  }

plan :: Plan
plan =
  Plan
    { text = "answer"
    , clean = True
    , failure = Nothing
    , hands = False
    , readPath = Nothing
    , block = False
    , delay = 0
    , ignoreCancel = False
    , writeExpected = Nothing
    , writePath = "output.txt"
    }

-- | @Client@.
data Client = Client
  { clientPlan :: Plan
  , prior :: Maybe PiContinuationPayloadV1
  , clientKey :: Maybe Text
  , entered :: MVar ()
  }

assert :: String -> Bool -> IO ()
assert what held = unless held $ throwIO (userError ("assertion failed: " <> what))

allM :: [IO Bool] -> IO Bool
allM = \case
  [] -> pure True
  action : rest -> action >>= \held -> if held then allM rest else pure False

runClient :: Client -> PiHelperClient
runClient c = PiHelperClient {run, close = pure p.clean}
  where
    p = c.clientPlan
    run gw inv current deadline = do
      live <- current
      start <- getMonotonicTime
      assert "current and before the deadline" (live && deadline > start)
      void (tryPutMVar c.entered ())
      let delayedUntil = start + p.delay
          pause = do
            now <- getMonotonicTime
            proceed <- if p.ignoreCancel then pure True else current
            when (now < delayedUntil && proceed) (threadDelay 5000 >> pause)
          blocked = do
            now <- getMonotonicTime
            live' <- current
            when (p.block && live' && now < deadline) (threadDelay 5000 >> blocked)
      pause
      blocked
      forM_ p.failure (throwIO . runtimeProtocolError)
      coords <- Episode.coordinates inv.attachment
      let submit callId method params =
            Gateway.submit
              gw
              ( Object
                  [ ("version", Int 1)
                  , ("episode_id", String coords.episodeId)
                  , ("attachment_id", String coords.attachmentId)
                  , ("attachment_epoch", Int coords.attachmentEpoch)
                  , ("grant_epoch", Int inv.grantEpoch)
                  , ("call_id", String callId)
                  , ("method", String method)
                  , ("params", Object params)
                  ]
              )
      forM_ p.readPath $ \path -> do
        result <- submit "continued-read" "workspace_read" [("path", String path)]
        assert "continued read" result.ok
      when p.hands $ do
        true <- trueCommand
        let requests =
              [ ("read", "workspace_read", [("path", String "input.txt")])
              , ("search", "workspace_search", [("query", String "input"), ("path", String "input.txt")])
              , ("shell", "workspace_shell", [("argv", Array [String true]), ("cwd", String ".")])
              , ("write", "workspace_write", [("path", String "output.txt"), ("content", String "changed")])
              , ("test", "workspace_test", [])
              ]
        held <- allM [(.ok) <$> submit callId method params | (callId, method, params) <- requests]
        assert "all hands requests" held
      forM_ p.writeExpected $ \expected -> do
        result <-
          submit "policy-write" "workspace_write" [("path", String p.writePath), ("content", String "policy-changed")]
        assert "policy write" (result.ok == expected)
      let body = maybe sessionBytes (.sessionJsonl) c.prior <> "{\"type\":\"message\",\"body\":\"next\"}\n"
      pure
        PiHelperResult
          { candidate = Just PiCandidate {sessionId, text = p.text, sessionJsonl = body}
          , nativeAuth = Nothing
          , code = "turn-completed"
          }

-- | @Factory@.
data Factory = Factory
  { plans :: IORef [Plan]
  , madeCalls :: IORef [PiHelperArgs]
  , clients :: IORef [Client]
  }

newFactory :: [Plan] -> IO Factory
newFactory selected = Factory <$> newIORef (if null selected then [plan] else selected) <*> newIORef [] <*> newIORef []

factoryRecord :: Factory -> PiHelperFactory
factoryRecord f = PiHelperFactory $ \args -> do
  modifyIORef' f.madeCalls (<> [args])
  next <- atomicModifyIORef' f.plans $ \case
    selected : rest -> (rest, selected)
    [] -> ([], error "IndexError: pop from empty list")
  entered <- newEmptyMVar
  let client = Client {clientPlan = next, prior = args.prior, clientKey = args.apiKey, entered}
  modifyIORef' f.clients (<> [client])
  pure (runClient client)

-- | @Authority@ with the reference's counting @Keys@.
data Authority = Authority
  { keys :: KeyOperations
  , erased :: IORef Int
  , supplied :: IORef Int
  , buffers :: IORef [ScrubbedBytes]
  }

newAuthority :: IO Authority
newAuthority = do
  base <- aesKeys
  erased <- newIORef 0
  supplied <- newIORef 0
  buffers <- newIORef []
  let keys =
        KeyOperations
          { seal = base.seal
          , open = base.open
          , erase = \connectionId -> modifyIORef' erased (+ 1) >> base.erase connectionId
          }
  pure Authority {keys, erased, supplied, buffers}

identity :: ConnectionIdentity
identity = ok (mkConnectionIdentity "direct" "anthropic" "account" "api-key")

-- | @Authority.supply@ for @value@ bytes.
supplying :: Authority -> ByteString -> IO ScrubbedBytes
supplying a value = do
  modifyIORef' a.supplied (+ 1)
  let buffer = BA.convert value :: ScrubbedBytes
  modifyIORef' a.buffers (<> [buffer])
  pure buffer

authorityValue :: Authority -> PiA2DirectAuthority
authorityValue a = ok (mkPiA2DirectAuthority identity a.keys (supplying a apiKey))

suppliedCount :: Authority -> IO Int
suppliedCount a = readIORef a.supplied

-- | The reference's @/bin/true@, which macOS ships only as @/usr/bin/true@.
trueCommand :: IO Text
trueCommand = doesFileExist "/bin/true" >>= \exists -> pure (if exists then "/bin/true" else "/usr/bin/true")

-- | The keyword changes @_config(tmp_path, **changes)@ takes.
data Changes = Changes
  { changedRoot :: Maybe FilePath
  , changedModel :: Text
  , changedCapabilities :: Set ToolMethod
  , changedMaxCalls :: Int
  , changedWall :: Double
  , changedAttachment :: Double
  , changedCredential :: Double
  }

unchanged :: Changes
unchanged =
  Changes
    { changedRoot = Nothing
    , changedModel = "claude-sonnet-4-5"
    , changedCapabilities = Set.fromList allToolMethods
    , changedMaxCalls = 8
    , changedWall = 0.5
    , changedAttachment = 2
    , changedCredential = 1
    }

slow :: Changes
slow = unchanged {changedWall = 30, changedAttachment = 31, changedCredential = 31}

-- | @_config(tmp_path, **changes)@; validation happens at composition (or
-- through 'newPiA2RuntimeHostConfig').
configWith :: FilePath -> Changes -> IO PiA2RuntimeHostConfig
configWith tmp c = do
  true <- trueCommand
  let working = tmp </> "working"
  createDirectoryIfMissing False working
  B.writeFile (working </> "input.txt") "input"
  pure
    PiA2RuntimeHostConfig
      { stateRoot = fromMaybe (tmp </> "state") c.changedRoot
      , workingDirectory = working
      , provider = "anthropic"
      , model = c.changedModel
      , hostId = "hamsterdan"
      , capabilities = c.changedCapabilities
      , allowedArgv = Set.fromList [[true]]
      , testCommand = [true]
      , maxToolCalls = c.changedMaxCalls
      , attachmentTimeout = c.changedAttachment
      , commandTimeout = 1
      , credentialTtl = c.changedCredential
      , wallTimeout = c.changedWall
      , cancellationGrace = 0.05
      , cliPath = Nothing
      , nodePath = Nothing
      , packageRoot = Nothing
      }

config :: FilePath -> IO PiA2RuntimeHostConfig
config tmp = configWith tmp unchanged

-- | The arguments of @_start(...)@.
data StartOptions = StartOptions
  { optName :: Text
  , optContinuation :: Maybe Continuation
  , optPrompt :: Text
  , optArchive :: Maybe ByteString
  , optDigest :: Maybe Text
  , optCorrelation :: Maybe Text
  , optPolicy :: Maybe PiA2RuntimePolicy
  }

named :: Text -> StartOptions
named name = StartOptions name Nothing "prompt" Nothing Nothing Nothing Nothing

fullPolicy :: PiA2RuntimePolicy
fullPolicy = ok (mkPiA2RuntimePolicy allToolMethods ["output.txt"] 8 [])

-- | @_start(...)@, validated as the reference's dataclass is.
startWith :: FilePath -> StartOptions -> IO PiA2RuntimeStart
startWith tmp o = do
  selected <- maybe (workspaceArchive (tmp </> "working")) pure o.optArchive
  let selectedDigest = sha256Hex selected
  newPiA2RuntimeStart
    PiA2RuntimeStart
      { operationId = o.optName
      , episodeId = ok (mkEpisodeId ("episode-" <> o.optName))
      , turnId = ok (mkTurnId ("turn-" <> o.optName))
      , prompt = o.optPrompt
      , workspaceArchive = selected
      , workspaceDigest = fromMaybe selectedDigest o.optDigest
      , workspaceCorrelation = fromMaybe ("test-tree-" <> selectedDigest) o.optCorrelation
      , policy = fromMaybe fullPolicy o.optPolicy
      , continuation = o.optContinuation
      }

start' :: FilePath -> Text -> IO PiA2RuntimeStart
start' tmp name = startWith tmp (named name)

clock :: IO Double
clock = getMonotonicTime

-- | @_host(tmp_path, authority, factory, provider)@.
hostWith :: FilePath -> Authority -> Factory -> Maybe EnvironmentProvider -> IO PiA2RuntimeHost
hostWith = hostWithHooks noPiA2HostHooks

hostWithHooks :: PiA2HostHooks -> FilePath -> Authority -> Factory -> Maybe EnvironmentProvider -> IO PiA2RuntimeHost
hostWithHooks hooks tmp a f selected = do
  c <- config tmp
  h <- composePiA2ScriptedClientRuntimeWith hooks c (authorityValue a) (factoryRecord f) selected clock
  void (scriptedReadiness h)
  pure h

host' :: FilePath -> Authority -> IO PiA2RuntimeHost
host' tmp a = newFactory [] >>= \f -> hostWith tmp a f Nothing

-- | @_tar_with(name, kind=..., linkname=...)@: a one-member POSIX archive
-- laid out as @tarfile@ writes it (ustar headers, 10240-byte records).
tarWith :: ByteString -> Maybe ByteString -> ByteString
tarWith memberName link = padRecord (header <> content <> B.replicate 1024 0)
  where
    body = maybe "input" (const "") link
    field width value = value <> B.replicate (width - B.length value) 0
    octal width n = let digits = BC.pack (showOctal n) in B.replicate (width - 1 - B.length digits) 48 <> digits <> "\0"
    showOctal :: Int -> String
    showOctal n = if n < 8 then show n else showOctal (n `div` 8) <> show (n `mod` 8)
    blank =
      B.concat
        [ field 100 memberName
        , octal 8 0o644
        , octal 8 0
        , octal 8 0
        , octal 12 (B.length body)
        , octal 12 0
        , B.replicate 8 32
        , maybe "0" (const "2") link
        , field 100 (fromMaybe "" link)
        , "ustar\0"
        , "00"
        , field 32 ""
        , field 32 ""
        , octal 8 0
        , octal 8 0
        , field 155 ""
        , B.replicate 12 0
        ]
    checksum = sum (map fromIntegral (B.unpack blank)) :: Int
    header = B.take 148 blank <> B.replicate (6 - length (showOctal checksum)) 48 <> BC.pack (showOctal checksum) <> "\0 " <> B.drop 156 blank
    content = if B.null body then "" else body <> B.replicate (512 - B.length body) 0
    padRecord bytes = bytes <> B.replicate ((10240 - B.length bytes `mod` 10240) `mod` 10240) 0

raisesE :: Either AgenticusError a -> ErrorClass -> Text -> Expectation
raisesE value = raises (either throwIO pure value)

completed :: RuntimeTurnSettlement -> Expectation
completed s = (s.outcome, s.terminationCode) `shouldBe` (TurnCompleted, "turn-completed")

verified :: RuntimeOperationCleanup -> Expectation
verified c = cleanupVerified c `shouldBe` True

extractTo :: FilePath -> ByteString -> IO FilePath
extractTo destination bytes = extractWorkspaceArchive bytes destination >> pure destination

readText :: FilePath -> IO ByteString
readText = B.readFile

outputReference :: Text
outputReference = "pi-a2-output-" <> sha256Hex "operation\0answer"

territoryAbsent :: EnvironmentProvider -> Expectation
territoryAbsent selected = (isNothing <$> providerLookup selected (piA2TerritoryOperation "operation")) `shouldReturn` True

localEnvironment :: IO EnvironmentProvider
localEnvironment = localProvider <$> newLocalProcessEnvironment

-- ---------------------------------------------------------------------------
-- Child processes

childVariable, rootVariable, markerVariable :: String
childVariable = "PETRUS_PI_A2_HOST_CHILD"
rootVariable = "PETRUS_PI_A2_HOST_ROOT"
markerVariable = "PETRUS_PI_A2_HOST_MARKER"

-- | The child scripts of the two process tests, selected by
-- @PETRUS_PI_A2_HOST_CHILD@.
child :: String -> IO ()
child mode = do
  root <- fromMaybe (error "missing root") <$> lookupEnv rootVariable
  case mode of
    "killed" -> do
      marker <- fromMaybe (error "missing marker") <$> lookupEnv markerVariable
      a <- newAuthority
      c <- configWith root slow
      h <- composePiA2ScriptedRuntime c (authorityValue a) [PiA2ScriptedTurn {outputText = "delayed", calls = [], delaySeconds = 30, cleanupVerified = True, failureCode = Nothing}] clock
      void (scriptedReadiness h)
      void (startHost h =<< start' root "operation")
      B.writeFile marker "admitted"
      forever (threadDelay 1000000)
    _ -> do
      a <- newAuthority
      h <- host' root a
      operation <- startHost h =<< start' root "prior"
      settlement <- waitPiA2 operation (Just 2)
      assert "prior output" (isJust settlement.outputReference)
      cleanup <- closePiA2 operation
      assert "prior cleanup" (cleanupVerified cleanup)
      when (mode == "reconstructed-True") $ closeHost h >>= assert "clean close"
      exitImmediately ExitSuccess

childProcess :: FilePath -> String -> [(String, String)] -> IO CreateProcess
childProcess tmp mode extra = do
  executable <- getExecutablePath
  environment <- getEnvironment
  let overrides = [(childVariable, mode), (rootVariable, tmp), ("TMPDIR", tmp)] <> extra
      kept = [entry | entry@(k, _) <- environment, k `notElem` map fst overrides]
  pure (proc executable ["+RTS", "-M2G", "-RTS"]) {env = Just (kept <> overrides)}

-- ---------------------------------------------------------------------------
-- Tests

spec :: Spec
spec = describe "test_pi_a2_host" $ do
  it "test_config_and_composition_are_exactly_direct_pi_a2_local" $ withTemp $ \tmp -> do
    c <- config tmp
    a <- newAuthority
    h <- composePiA2Runtime c (authorityValue a) clock
    hostDescriptor `shouldBe` piNativeA2Local
    snapshotDescriptor piNativeA2Local.identity.kind hostSnapshot `shouldBe` Just piNativeA2Local
    providerName (hostProvider h) `shouldBe` "local-process"
    hostFactoryKind h `shouldBe` NoClientFactory
    suppliedCount a `shouldReturn` 0
    closeHost h `shouldReturn` True
    suppliedCount a `shouldReturn` 0
    readIORef a.erased `shouldReturn` 0
    raises (newPiA2RuntimeHostConfig =<< configWith tmp unchanged {changedModel = "foreign-model"}) ValueError "exact direct API-key"
    local <- localEnvironment
    raises
      (composePiA2RuntimeWith c (authorityValue a) local {providerName = "foreign"} clock Nothing)
      ValueError
      "only the Local"

  it "test_public_host_construction_boundaries_exclude_arbitrary_collaborators" $ withTemp $ \tmp -> do
    -- The signature and Protocol checks are fixed by the Haskell types.
    nativeConfig <- config tmp
    nativeAuthority <- newAuthority
    native <- composePiA2Runtime nativeConfig (authorityValue nativeAuthority) clock
    providerName (hostProvider native) `shouldBe` "local-process"
    hostFactoryKind native `shouldBe` NoClientFactory
    closeHost native `shouldReturn` True
    let scriptedRoot = tmp </> "scripted"
    createDirectory scriptedRoot
    c <- config scriptedRoot
    a <- newAuthority
    scripted <- composePiA2ScriptedRuntime c (authorityValue a) [piA2ScriptedTurn "bounded"] clock
    providerName (hostProvider scripted) `shouldBe` "local-process"
    hostFactoryKind scripted `shouldBe` ScriptedClientFactory
    closeHost scripted `shouldReturn` True

  it "test_start_requires_exact_safe_workspace_and_operation_policy" $ withTemp $ \tmp -> do
    _ <- config tmp
    _ <- start' tmp "operation"
    -- A bytearray archive has no counterpart: the field is a ByteString.
    raises (startWith tmp (named "operation") {optDigest = Just (T.replicate 64 "0")}) ValueError "does not match"
    raises (startWith tmp (named "operation") {optArchive = Just "not-an-archive"}) ValueError "malformed"
    raises
      (startWith tmp (named "operation") {optArchive = Just (tarWith "redirect" (Just "input.txt"))})
      ValueError
      "links are not permitted"
    forM_ [".git", ".petrus-hands-stage"] $ \root -> do
      raises
        (startWith tmp (named "operation") {optArchive = Just (tarWith (TE.encodeUtf8 root <> "/state") Nothing)})
        ValueError
        "forbidden archive member"
      raisesE (mkPiA2RuntimePolicy [WorkspaceWrite] [root <> "/state"] 1 []) ValueError "control roots"
      raisesE (mkPiA2RuntimePolicy [WorkspaceWrite] [] 1 [root]) ValueError "control roots"
    raisesE (mkPiA2RuntimePolicy [WorkspaceRead] ["output.txt"] 1 []) ValueError "require workspace-write"
    raisesE (mkPiA2RuntimePolicy [WorkspaceRead] [] 1 ["."]) ValueError "require workspace-write"

  it "test_probe_is_authority_free_and_nonready_start_fails_before_admission" $ withTemp $ \tmp -> do
    a <- newAuthority
    c <- config tmp
    h <- composePiA2Runtime c (authorityValue a) clock
    result <- probeHost h
    result.disposition `shouldNotBe` ProbeReady
    raises (startHost h =<< start' tmp "operation") RuntimeProtocolError "runtime-not-ready"
    suppliedCount a `shouldReturn` 0
    (isNothing <$> ledgerLookup (hostLedger h) "operation") `shouldReturn` True
    closeHost h `shouldReturn` True

  it "test_completed_operation_commits_bodies_only_after_verified_cleanup" $ withTemp $ \tmp -> do
    a <- newAuthority
    true <- trueCommand
    let call method params = ok (mkPiA2ScriptedCall method params True)
        script =
          [ PiA2ScriptedTurn
              { outputText = "answer"
              , delaySeconds = 0
              , cleanupVerified = True
              , failureCode = Nothing
              , calls =
                  [ call WorkspaceRead "{\"path\":\"input.txt\"}"
                  , call WorkspaceSearch "{\"query\":\"input\",\"path\":\"input.txt\"}"
                  , call WorkspaceShell ("{\"argv\":[\"" <> true <> "\"],\"cwd\":\".\"}")
                  , call WorkspaceWrite "{\"path\":\"output.txt\",\"content\":\"changed\"}"
                  , call WorkspaceTest "{}"
                  ]
              }
          ]
    c <- config tmp
    h <- composePiA2ScriptedRuntime c (authorityValue a) script clock
    readiness <- scriptedReadiness h
    readiness.ready `shouldBe` True
    readiness.supportLabel `shouldBe` "Pi A2 Local host lifecycle \x2014 scripted runtime conformance"
    suppliedCount a `shouldReturn` 0
    hostAuthorityRequested h `shouldReturn` False
    operation <- startHost h =<< start' tmp "operation"
    settlement <- waitPiA2 operation (Just 1)
    completed settlement
    settlement.acceptedAppends `shouldBe` 1
    output <- maybe (pure Nothing) (fmap Just . loadOutput h) settlement.outputReference
    output `shouldBe` Just "answer"
    isJust settlement.continuationReference `shouldBe` True
    stored <- loadWorkspaceArchive h "operation"
    (not (B.null stored) && not (apiKey `B.isInfixOf` stored)) `shouldBe` True
    extracted <- extractTo (tmp </> "extracted") stored
    readText (extracted </> "output.txt") `shouldReturn` "changed"
    (apiKey `B.isInfixOf`) <$> B.readFile (tmp </> "state" </> "operations.sqlite3") `shouldReturn` False
    (apiKey `B.isInfixOf`) <$> B.readFile (tmp </> "state" </> "bodies.sqlite3") `shouldReturn` False
    suppliedCount a `shouldReturn` 1
    zeroed <- all (\buffer -> BA.null buffer || BA.all (== 0) buffer) <$> readIORef a.buffers
    zeroed `shouldBe` True
    cleanup <- closePiA2 operation
    cleanup.disposition `shouldBe` RuntimeCleanupClean
    closeHost h `shouldReturn` True
    readIORef a.erased `shouldReturn` 1

  it "test_start_archive_not_global_working_directory_is_episode_input" $ withTemp $ \tmp -> do
    a <- newAuthority
    h <- host' tmp a
    start <- start' tmp "operation"
    B.writeFile (tmp </> "working" </> "input.txt") "ambient-change"
    settlement <- startHost h start >>= \operation -> waitPiA2 operation (Just 1)
    extracted <- loadWorkspaceArchive h "operation" >>= extractTo (tmp </> "start-archive")
    completed settlement
    readText (extracted </> "input.txt") `shouldReturn` "input"
    closeHost h `shouldReturn` True

  it "test_per_start_policy_is_exact_attachment_authority" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory [plan {writeExpected = Just False}, plan {writeExpected = Just True, writePath = "new/output.txt"}]
    h <- hostWith tmp a f Nothing
    let readOnly = ok (mkPiA2RuntimePolicy [WorkspaceRead, WorkspaceSearch] [] 2 [])
        coding = ok (mkPiA2RuntimePolicy [WorkspaceRead, WorkspaceWrite] [] 2 ["."])
    first <- startHost h =<< startWith tmp (named "read-only") {optPolicy = Just readOnly}
    firstSettled <- waitPiA2 first (Just 1)
    second <- startHost h =<< startWith tmp (named "coding") {optPolicy = Just coding}
    secondSettled <- waitPiA2 second (Just 1)
    completed firstSettled
    completed secondSettled
    extracted <- loadWorkspaceArchive h "coding" >>= extractTo (tmp </> "policy-archive")
    readText (extracted </> "new" </> "output.txt") `shouldReturn` "policy-changed"
    closeHost h `shouldReturn` True

  it "test_policy_ceiling_rejection_does_not_burn_operation_identity" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory []
    c <- configWith tmp unchanged {changedCapabilities = Set.fromList [WorkspaceRead], changedMaxCalls = 2}
    h <- composePiA2ScriptedClientRuntime c (authorityValue a) (factoryRecord f) Nothing clock
    void (scriptedReadiness h)
    let excessCapability = ok (mkPiA2RuntimePolicy [WorkspaceWrite] ["output.txt"] 1 [])
        excessCalls = ok (mkPiA2RuntimePolicy [WorkspaceRead] [] 3 [])
    forM_ [("capability", excessCapability), ("calls", excessCalls)] $ \(name, selected) -> do
      raises (startHost h =<< startWith tmp (named name) {optPolicy = Just selected}) RuntimeProtocolError "operation-policy-exceeds-host"
      (isNothing <$> ledgerLookup (hostLedger h) name) `shouldReturn` True
    let corrected = ok (mkPiA2RuntimePolicy [WorkspaceRead] [] 2 [])
    operation <- startHost h =<< startWith tmp (named "capability") {optPolicy = Just corrected}
    waitPiA2 operation (Just 1) >>= completed
    suppliedCount a `shouldReturn` 1
    closeHost h `shouldReturn` True

  it "test_continuation_and_second_operation_reuse_one_host_authorization" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory [plan {text = "first", hands = True}, plan {text = "second", readPath = Just "output.txt"}]
    h <- hostWith tmp a f Nothing
    first <- startHost h =<< start' tmp "one"
    firstSettled <- waitPiA2 first (Just 1)
    reference <- maybe (expectationFailure "no continuation" >> pure "") pure firstSettled.continuationReference
    prior <- loadWorkspaceArchive h "one"
    second <- startHost h =<< startWith tmp (named "two") {optContinuation = Just (claimed reference), optArchive = Just prior}
    secondSettled <- waitPiA2 second (Just 1)
    loadOutput h (fromMaybe "" secondSettled.outputReference) `shouldReturn` "second"
    suppliedCount a `shouldReturn` 1
    made <- readIORef f.madeCalls
    length made `shouldBe` 2
    fmap (.sessionId) (made !! 1).prior `shouldBe` Just sessionId
    closeHost h `shouldReturn` True

  it "test_continuation_workspace_mismatch_precedes_admission_and_can_be_corrected" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory [plan {writeExpected = Just True}, plan {text = "continued", readPath = Just "output.txt"}]
    h <- hostWith tmp a f Nothing
    first <- startHost h =<< start' tmp "one"
    firstSettled <- waitPiA2 first (Just 1)
    reference <- maybe (expectationFailure "no continuation" >> pure "") pure firstSettled.continuationReference
    let continued = (named "two") {optContinuation = Just (claimed reference)}
    raises (startHost h =<< startWith tmp continued) RuntimeProtocolError "operation-conflict"
    (isNothing <$> ledgerLookup (hostLedger h) "two") `shouldReturn` True
    length <$> readIORef f.madeCalls `shouldReturn` 1
    suppliedCount a `shouldReturn` 1
    prior <- loadWorkspaceArchive h "one"
    corrected <- startHost h =<< startWith tmp continued {optArchive = Just prior}
    waitPiA2 corrected (Just 1) >>= completed
    length <$> readIORef f.madeCalls `shouldReturn` 2
    suppliedCount a `shouldReturn` 1
    closeHost h `shouldReturn` True

  it "test_terminal_replay_precedes_probe_authority_and_territory" $ withTemp $ \tmp -> do
    original <- newAuthority
    h <- host' tmp original
    start <- start' tmp "operation"
    expected <- startHost h start >>= \operation -> waitPiA2 operation (Just 1)
    closeHost h `shouldReturn` True
    replayAuthority <- newAuthority
    c <- config tmp
    replay <- composePiA2ScriptedRuntime c (authorityValue replayAuthority) [piA2ScriptedTurn "must-not-run"] clock
    operation <- startHost replay start
    waitPiA2 operation Nothing `shouldReturn` expected
    suppliedCount replayAuthority `shouldReturn` 0
    territoryAbsent (hostProvider replay)
    closePiA2 operation >>= verified
    closeHost replay `shouldReturn` True

  it "test_concurrent_starts_serialize_one_shot_authority_and_dedupe_live_work" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory [plan, plan]
    h <- hostWith tmp a f Nothing
    one <- start' tmp "one"
    two <- start' tmp "two"
    results <- mapM (\start -> newEmptyMVar >>= \box -> forkIO (try (startHost h start) >>= putMVar box) >> pure box) [one, two]
    operations <-
      mapM (\box -> takeMVar box >>= either (\(e :: AgenticusError) -> throwIO e) pure) results
    again <- startHost h one
    (Just again == listToMaybe operations) `shouldBe` True
    forM_ operations $ \operation -> waitPiA2 operation (Just 1) >>= completed
    suppliedCount a `shouldReturn` 1
    length <$> readIORef f.madeCalls `shouldReturn` 2
    closeHost h `shouldReturn` True

  it "test_close_fences_new_starts_and_cancels_active_operation" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory [plan {block = True}]
    h <- hostWith tmp a f Nothing
    operation <- startHost h =<< start' tmp "operation"
    closeHost h `shouldReturn` True
    closePiA2 operation >>= verified
    raises (startHost h =<< start' tmp "later") RuntimeProtocolError "host-closed"

  it "test_indeterminate_close_prevents_late_waiter_publication" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory [plan {delay = 0.4, ignoreCancel = True}]
    h <- hostWith tmp a f Nothing
    operation <- startHost h =<< start' tmp "operation"
    waiter <- newEmptyMVar
    void (forkIO (try (waitPiA2 operation (Just 1)) >>= putMVar waiter))
    waitUntil 5 (not . null <$> readIORef f.clients)
    clients <- readIORef f.clients
    entered <- mapM (timeout 1000000 . readMVar . (.entered)) (take 1 clients)
    entered `shouldBe` [Just ()]
    cleanup <- closePiA2 operation
    cleanup.disposition `shouldBe` RuntimeCleanupUnverified
    late <- timeout 1000000 (takeMVar waiter)
    case late of
      Just (Left (e :: AgenticusError)) -> runtimeProtocolErrorCode e `shouldBe` Just "operation-closed"
      Just (Right _) -> expectationFailure "the late waiter published"
      Nothing -> expectationFailure "the late waiter did not finish"
    raises (loadOutput h outputReference) RuntimeProtocolError "output-absent"
    record <- ledgerLookup (hostLedger h) "operation"
    fmap (fmap (.outcome) . recordSettlement) record `shouldBe` Just (Right TurnIndeterminate)
    raises (closeHost h) RuntimeProtocolError "host-cleanup-uncertain"

  it "test_changed_work_conflicts_before_probe_or_authority" $ withTemp $ \tmp -> do
    original <- newAuthority
    h <- host' tmp original
    originalArchive <- workspaceArchive (tmp </> "working")
    let base = (named "operation") {optArchive = Just originalArchive}
    operation <- startHost h =<< startWith tmp base
    void (waitPiA2 operation (Just 1))
    closeHost h `shouldReturn` True
    replayAuthority <- newAuthority
    c <- config tmp
    replay <- composePiA2Runtime c (authorityValue replayAuthority) clock
    B.writeFile (tmp </> "working" </> "input.txt") "changed-input"
    changedArchive <- workspaceArchive (tmp </> "working")
    let originalCorrelation = "test-tree-" <> sha256Hex originalArchive
        changed =
          [ base {optPrompt = "changed"}
          , base {optArchive = Just changedArchive, optCorrelation = Just originalCorrelation}
          , base {optCorrelation = Just "changed-tree"}
          , base {optPolicy = Just (ok (mkPiA2RuntimePolicy [WorkspaceRead] [] 1 []))}
          , base {optPolicy = Just (ok (mkPiA2RuntimePolicy allToolMethods [] 8 ["."]))}
          ]
    forM_ changed $ \options ->
      raises (startHost replay =<< startWith tmp options) RuntimeProtocolError "operation-conflict"
    suppliedCount replayAuthority `shouldReturn` 0
    territoryAbsent (hostProvider replay)
    closeHost replay `shouldReturn` True

  it "test_surviving_executing_record_becomes_indeterminate_without_authority" $ withTemp $ \tmp -> do
    a <- newAuthority
    h <- host' tmp a
    start <- start' tmp "operation"
    fingerprint <- hostFingerprint h start
    void (ledgerAdmit (hostLedger h) start.operationId fingerprint start.episodeId start.turnId)
    bodyStoreClose (hostBodies h)
    ledgerClose (hostLedger h)
    (hostStorage h).close
    recoveredAuthority <- newAuthority
    c <- config tmp
    recovered <- composePiA2Runtime c (authorityValue recoveredAuthority) clock
    raises (startHost recovered start) RuntimeProtocolError "operation-indeterminate"
    suppliedCount recoveredAuthority `shouldReturn` 0
    raises (closeHost recovered) RuntimeProtocolError "host-cleanup-uncertain"

  it "test_killed_host_process_reopens_admitted_work_without_redispatch" $ withTemp $ \tmp -> do
    let marker = tmp </> "admitted"
    process <- childProcess tmp "killed" [(markerVariable, marker)]
    withFile (tmp </> "child.log") WriteMode $ \logHandle -> do
      (_, _, _, handle) <- createProcess process {std_out = UseHandle logHandle, std_err = UseHandle logHandle}
      let stop =
            getProcessExitCode handle >>= \case
              Just _ -> pure ()
              Nothing -> getPid handle >>= mapM_ (signalProcess sigKILL) >> void (waitForProcess handle)
      flip finally stop $ do
        deadline <- (+ 10) <$> getMonotonicTime
        let poll = do
              admitted <- doesFileExist marker
              exited <- isJust <$> getProcessExitCode handle
              now <- getMonotonicTime
              unless (admitted || exited || now >= deadline) (threadDelay 10000 >> poll)
        poll
        admitted <- doesFileExist marker
        unless admitted $ do
          stop
          output <- B.readFile (tmp </> "child.log")
          expectationFailure ("child did not durably admit work: " <> BC.unpack output)
        getPid handle >>= mapM_ (signalProcess sigKILL)
        waitForProcess handle `shouldReturn` ExitFailure (-9)
        a <- newAuthority
        c <- configWith tmp slow
        reopened <- composePiA2ScriptedRuntime c (authorityValue a) [piA2ScriptedTurn "must-not-run"] clock
        map (.terminationCode) (hostRecoveredSettlements reopened) `shouldBe` ["restart-indeterminate"]
        raises (startHost reopened =<< startWith tmp (named "operation")) RuntimeProtocolError "operation-indeterminate"
        suppliedCount a `shouldReturn` 0
        raises (closeHost reopened) RuntimeProtocolError "host-cleanup-uncertain"

  forM_ [("replacement-installation-key", True), ("replacement-installation-key", False), ("", True), ("", False)] $
    \(freshKey, cleanShutdown) ->
      it
        ( "test_reconstructed_host_requires_current_authority_for_new_work["
            <> BC.unpack freshKey
            <> "-"
            <> show cleanShutdown
            <> "]"
        )
        $ withTemp
        $ \tmp -> do
          process <- childProcess tmp ("reconstructed-" <> show cleanShutdown) []
          (code, _, err) <- readCreateProcessWithExitCode process ""
          (code, err) `shouldBe` (ExitSuccess, err)
          a <- newAuthority
          f <- newFactory [plan, plan]
          c <- config tmp
          let authority' = ok (mkPiA2DirectAuthority identity a.keys (supplying a freshKey))
          reopened <- composePiA2ScriptedClientRuntime c authority' (factoryRecord f) Nothing clock
          void (scriptedReadiness reopened)
          flip finally (closeHost reopened `shouldReturn` True) $ do
            replay <- startHost reopened =<< start' tmp "prior"
            replayed <- waitPiA2 replay (Just 1)
            isJust replayed.outputReference `shouldBe` True
            closePiA2 replay >>= verified
            suppliedCount a `shouldReturn` 0
            forM_ ["new", "another"] $ \name ->
              if B.null freshKey
                then do
                  supplied <- suppliedCount a
                  raises
                    (startHost reopened =<< start' tmp name)
                    RuntimeProtocolError
                    (if supplied == 0 then "credential-invalid" else "authority-unavailable")
                else do
                  operation <- startHost reopened =<< start' tmp name
                  settlement <- waitPiA2 operation (Just 2)
                  isJust settlement.outputReference `shouldBe` True
                  closePiA2 operation >>= verified
            suppliedCount a `shouldReturn` 1
            keysSeen <- map (.clientKey) <$> readIORef f.clients
            keysSeen `shouldBe` (if B.null freshKey then [] else replicate 2 (Just (TE.decodeUtf8 freshKey)))

  it "test_pre_workspace_fingerprint_conflicts_without_authority_or_provider_work" $ withTemp $ \tmp -> do
    a <- newAuthority
    local <- localEnvironment
    f <- newFactory []
    h <- hostWith tmp a f (Just local)
    start <- start' tmp "operation"
    let adapterSettings = adapterConfig (hostAdapter h)
    old <- either throwIO pure (piDurableWorkFingerprint adapterSettings start.episodeId start.turnId start.prompt identity Nothing)
    void (ledgerAdmit (hostLedger h) start.operationId old start.episodeId start.turnId)
    raises (startHost h start) RuntimeProtocolError "operation-conflict"
    suppliedCount a `shouldReturn` 0
    territoryAbsent local
    raises (closeHost h) RuntimeProtocolError "host-cleanup-uncertain"

  it "test_invalid_authority_is_consumed_once_and_replays_terminal_failure" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory []
    c <- config tmp
    let invalid = ok (mkPiA2DirectAuthority identity a.keys (supplying a ""))
    h <- composePiA2ScriptedClientRuntime c invalid (factoryRecord f) Nothing clock
    void (scriptedReadiness h)
    raises (startHost h =<< start' tmp "operation") RuntimeProtocolError "credential-invalid"
    replay <- startHost h =<< start' tmp "operation"
    settlement <- waitPiA2 replay Nothing
    settlement.outcome `shouldBe` TurnFailed
    suppliedCount a `shouldReturn` 1
    closePiA2 replay >>= verified
    closeHost h `shouldReturn` True

  it "test_partial_attachment_construction_rolls_back_and_replays_clean_failure" $ withTemp $ \tmp -> do
    a <- newAuthority
    local <- localEnvironment
    let attachFailure = local {providerAttach = \_ _ _ -> throwIO (userError "synthetic")}
    f <- newFactory []
    h <- hostWith tmp a f (Just attachFailure)
    start <- start' tmp "operation"
    raises (startHost h start) RuntimeProtocolError "runtime-start-failed"
    replay <- startHost h start
    settlement <- waitPiA2 replay Nothing
    settlement.outcome `shouldBe` TurnFailed
    closePiA2 replay >>= verified
    loadWorkspaceArchive h "operation" `shouldReturn` start.workspaceArchive
    suppliedCount a `shouldReturn` 1
    territoryAbsent attachFailure
    closeHost h `shouldReturn` True

  it "test_body_publication_failure_leaves_output_unreadable_and_operation_indeterminate" $ withTemp $ \tmp -> do
    a <- newAuthority
    f <- newFactory []
    h <- hostWithHooks PiA2HostHooks {publishBodies = Just (\_ -> throwIO (userError "synthetic"))} tmp a f Nothing
    operation <- startHost h =<< start' tmp "operation"
    raises (waitPiA2 operation (Just 1)) RuntimeProtocolError "host-cleanup-uncertain"
    raises (loadOutput h outputReference) RuntimeProtocolError "output-absent"
    raises (startHost h =<< start' tmp "operation") RuntimeProtocolError "operation-indeterminate"
    closeHost h `shouldReturn` True

  it "test_unverified_territory_cleanup_never_publishes_success" $ withTemp $ \tmp -> do
    a <- newAuthority
    local <- localEnvironment
    let unverifiedDestroy =
          local
            { providerDestroy = \lease ->
                pure CleanupResult {cleanupIdentity = leaseIdentity lease, cleanupDisposition = Unverified, cleanupDetail = "synthetic"}
            }
    f <- newFactory []
    h <- hostWith tmp a f (Just unverifiedDestroy)
    operation <- startHost h =<< start' tmp "operation"
    raises (waitPiA2 operation (Just 1)) RuntimeProtocolError "host-cleanup-uncertain"
    cleanup <- closePiA2 operation
    cleanup.disposition `shouldBe` RuntimeCleanupUnverified
    raises (startHost h =<< start' tmp "operation") RuntimeProtocolError "operation-indeterminate"
    raises (closeHost h) RuntimeProtocolError "host-cleanup-uncertain"
    lease <- providerLookup unverifiedDestroy (piA2TerritoryOperation "operation")
    case lease of
      Nothing -> expectationFailure "the territory lease is gone"
      Just live -> (Motus.cleanupVerified <$> providerDestroy local live) `shouldReturn` True

  it "test_private_state_root_rejects_unsafe_existing_mode" $ withTemp $ \tmp -> do
    let state = tmp </> "unsafe"
    createDirectory state
    setFileMode state 0o755
    a <- newAuthority
    c <- configWith tmp unchanged {changedRoot = Just state}
    raises (composePiA2Runtime c (authorityValue a) clock) StorageSecurityError "mode-0700"
    suppliedCount a `shouldReturn` 0

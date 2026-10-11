-- | Port of @tests/petrus/agenticus/attachment/test_episode.py@.
module Petrus.Agenticus.EpisodeSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Resolution
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract
import Petrus.Agenticus.Hands.Gateway
import Petrus.Agenticus.Hands.Grants
import Petrus.Agenticus.Hands.Workspace
import Petrus.Agenticus.Thread.Identity
import Petrus.Json (Json (..))
import Petrus.Motus.Execution hiding (ErrorKind (..))
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

snapshot :: Text -> ResolutionSnapshot
snapshot suffix =
  ok $
    mkResolutionSnapshot
      1
      [ capabilityDescriptor (descriptorIdentity kind (kindText kind <> "-" <> suffix) 1) [] []
      | kind <- [KindRuntime, KindHands, KindTerritory]
      ]

episode :: Text -> EpisodeId
episode = ok . mkEpisodeId

-- | The upstream scripted @Binding@: each @settle@ pops one outcome (a
-- verification flag or an exception); every lifecycle call is recorded.
data Scripted = Scripted
  { binding :: AttachmentBinding
  , events :: IORef [Text]
  }

data Outcome = Verified Bool | Raise Text

scripted :: [Outcome] -> IO Scripted
scripted = scriptedWith (\_ -> pure ()) (pure ())

-- | A scripted binding whose @cancel@ and @export_archive@ run an extra hook
-- (used to block them).
scriptedWith :: (Text -> IO ()) -> IO () -> [Outcome] -> IO Scripted
scriptedWith onCancel onExport outcomes = do
  events' <- newIORef []
  remaining <- newIORef outcomes
  let record e = modifyIORef' events' (<> [e])
      kind' = "provider-managed"
  pure
    Scripted
      { binding =
          AttachmentBinding
            { kind = kind'
            , cancel = \reason -> record "cancel" >> onCancel reason
            , exportArchive = record "export" >> onExport >> pure "archive"
            , settle = do
                record "destroy"
                next <- atomicModifyIORef' remaining (\case x : xs -> (xs, x); [] -> ([], Raise "exhausted"))
                case next of
                  Raise message -> throwIO (userError (T.unpack message))
                  Verified v -> either throwIO pure (mkBindingSettlement kind' (if v then "clean" else "unverified") v "")
            , motus = Nothing
            }
      , events = events'
      }

attachmentAt :: Scripted -> Text -> Integer -> IO EpisodeAttachment
attachmentAt s identity epoch' =
  newEpisodeAttachment (episode "episode-1") (snapshot "one") s.binding identity 100 episodeOptions {attachmentEpoch = epoch', clock = pure 1}

attachment :: Scripted -> IO EpisodeAttachment
attachment s = attachmentAt s "attachment-1" 1

raises :: IO a -> ErrorClass -> Text -> Expectation
raises action cls fragment =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      (e.errorClass `isSubclassOf` cls) `shouldBe` True
      (fragment `T.isInfixOf` e.errorMessage) `shouldBe` True
    Right _ -> expectationFailure ("expected " <> show cls <> " containing " <> show fragment)

-- | Run an action on another thread; the result is read from the MVar.
async' :: IO a -> IO (MVar (Either SomeException a))
async' action = do
  box <- newEmptyMVar
  void (forkIO (try action >>= putMVar box))
  pure box

await :: MVar (Either SomeException a) -> IO a
await box = timeout 5_000_000 (takeMVar box) >>= maybe (fail "timed out") (either throwIO pure)

done :: MVar a -> IO Bool
done box = maybe False (const True) <$> tryReadMVar box

waitFor :: MVar () -> IO ()
waitFor signal = timeout 2_000_000 (readMVar signal) >>= maybe (fail "event not set") pure

-- | Wait (bounded like 'waitFor') until a settlement in progress has closed
-- the attachment's admission, its first ordered step.
admissionClosed :: EpisodeAttachment -> IO ()
admissionClosed a = timeout 2_000_000 loop >>= maybe (fail "settlement did not close admission") pure
  where
    loop = fenceSnapshot a (episodeEpoch a) >>= \fence -> when fence.open (threadDelay 100 >> loop)

readRequest :: Text -> Text -> Text -> Integer -> Integer -> Text -> Json
readRequest callId episodeText attachment' epoch' grantEpoch' path =
  Object
    [ ("version", Int 1)
    , ("call_id", String callId)
    , ("episode_id", String episodeText)
    , ("attachment_id", String attachment')
    , ("attachment_epoch", Int epoch')
    , ("grant_epoch", Int grantEpoch')
    , ("method", String "workspace_read")
    , ("params", Object [("path", String path)])
    ]

-- | An adapter that only reads; every other operation is a test failure.
readOnlyAdapter :: IO Text -> HandsAdapter
readOnlyAdapter onRead =
  HandsAdapter
    { read = const onRead
    , search = \_ _ -> pure []
    , shell = \_ _ -> fail "AssertionError"
    , stageWrite = \_ _ _ -> fail "AssertionError"
    , commitWrite = const (fail "AssertionError")
    , discardWrite = const (fail "AssertionError")
    , runTest = fail "AssertionError"
    , discardAllStages = pure 0
    }

spec :: Spec
spec = describe "attachment/test_episode.py" $ do
  it "test_settlement_is_ordered_and_successor_is_a_new_episode_attachment" $ do
    oldBinding <- scripted [Verified True]
    old <- attachmentAt oldBinding "attachment-1" 4
    cancel old "stop"
    record <- settle old 30
    readIORef oldBinding.events `shouldReturn` ["cancel", "export", "destroy"]
    (record.epoch, record.archive, record.settlement.verified) `shouldBe` (4, "archive", True)
    newBinding <- scripted [Verified True]
    next <- successor old (episode "episode-2") (snapshot "two") newBinding.binding "attachment-2" 200 Nothing Nothing
    episodeEpoch next `shouldBe` 5
    (episodeBinding next).kind `shouldBe` "provider-managed"
    ((.episodeId) <$> coordinates next) `shouldReturn` "episode-2"
    settled old `shouldReturn` True
    raises (successor old (episode "episode-1") (snapshot "two") newBinding.binding "attachment-2" 200 Nothing Nothing) EpisodeAttachmentError ""

  it "test_unverified_custody_blocks_progress_until_destroy_retry_verifies" $ do
    s <- scripted [Verified False, Verified True]
    old <- attachment s
    ((.settlement.verified) <$> settle old 30) `shouldReturn` False
    custodyUncertain old `shouldReturn` True
    other <- scripted [Verified True]
    raises (successor old (episode "episode-2") (snapshot "two") other.binding "attachment-2" 200 Nothing Nothing) UncertainCustodyError ""
    ((.settlement.verified) <$> retrySettlement old) `shouldReturn` True
    readIORef s.events `shouldReturn` ["export", "destroy", "destroy"]

  it "test_raising_binding_settlement_records_uncertain_custody_and_can_retry" $ do
    s <- scripted [Raise "SECRET-CANARY", Verified True]
    old <- attachment s
    outcome <- try (settle old 30)
    case outcome of
      Left (e :: AgenticusError) -> do
        e.errorClass `shouldBe` EpisodeAttachmentError
        ("binding settlement failed" `T.isInfixOf` e.errorMessage) `shouldBe` True
        ("SECRET-CANARY" `T.isInfixOf` T.pack (show e)) `shouldBe` False
      Right _ -> expectationFailure "settlement must raise"
    custodyUncertain old `shouldReturn` True
    (fmap (.settlement.verified) <$> lastSettlement old) `shouldReturn` Just False
    ((.settlement.verified) <$> retrySettlement old) `shouldReturn` True

  -- The reference delays the grant ledger's @consume@ by monkeypatching it.
  -- The Haskell ledger is not patchable, so the claimed call blocks inside
  -- the adapter instead: the call is in flight either way when settlement
  -- starts. The reference releases the call right after submitting
  -- settlement and relies on the settlement thread having closed admission
  -- by then; nothing orders the two. Here the release waits until
  -- settlement has observably closed admission (and is therefore draining
  -- the claimed call), otherwise the call can finish first, legitimately
  -- succeed, and leave nothing to wait for.
  it "test_settlement_waits_for_every_claimed_call_before_export_and_destroy" $ do
    s <- scripted [Verified True]
    current <- attachment s
    entered <- newEmptyMVar
    release <- newEmptyMVar
    gw <- gateway current (readOnlyAdapter (putMVar entered () >> waitFor release >> pure "safe")) 256
    grant <- openGrant (grants current) (grantSpec [WorkspaceRead] 50 1)
    submitted <- async' (submit gw (readRequest "settlement-race" "episode-1" "attachment-1" 1 grant.grantEpoch "README.md"))
    waitFor entered
    settledBox <- async' (settle current 2)
    admissionClosed current
    done settledBox `shouldReturn` False
    readIORef s.events `shouldReturn` []
    putMVar release ()
    ((.ok) <$> await submitted) `shouldReturn` False
    ((.settlement.verified) <$> await settledBox) `shouldReturn` True
    readIORef s.events `shouldReturn` ["export", "destroy"]

  it "test_concurrent_settlement_cannot_export_or_destroy_one_binding_twice" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    s <- scriptedWith (\_ -> pure ()) (putMVar entered () >> waitFor release) [Verified True]
    current <- attachment s
    first <- async' (settle current 30)
    waitFor entered
    raises (settle current 30) EpisodeAttachmentError "already in progress"
    putMVar release ()
    ((.settlement.verified) <$> await first) `shouldReturn` True
    readIORef s.events `shouldReturn` ["export", "destroy"]

  it "test_cancellation_is_serialized_before_settlement_and_is_too_late_afterward" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    s <- scriptedWith (\_ -> putMVar entered () >> waitFor release) (pure ()) [Verified True]
    current <- attachment s
    cancelled <- async' (cancel current "stop")
    waitFor entered
    settledBox <- async' (settle current 30)
    done settledBox `shouldReturn` False
    readIORef s.events `shouldReturn` ["cancel"]
    putMVar release ()
    await cancelled
    ((.settlement.verified) <$> await settledBox) `shouldReturn` True
    readIORef s.events `shouldReturn` ["cancel", "export", "destroy"]
    raises (cancel current "late") EpisodeAttachmentError "already settled"

  it "test_cancellation_cannot_enter_after_settlement_has_started" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    s <- scriptedWith (\_ -> pure ()) (putMVar entered () >> waitFor release) [Verified True]
    current <- attachment s
    settledBox <- async' (settle current 30)
    waitFor entered
    raises (cancel current "late") EpisodeAttachmentError "already in progress"
    putMVar release ()
    ((.settlement.verified) <$> await settledBox) `shouldReturn` True
    readIORef s.events `shouldReturn` ["export", "destroy"]

  it "test_local_episode_attachment_composes_gateway_archive_cleanup_and_successor_fences" $
    withSystemTempDirectory "petrus-agenticus-episode" $ \tmp -> do
      let source = tmp </> "source"
      createDirectory source
      provider <- localProvider <$> newLocalProcessEnvironment
      archive' <- workspaceArchive source
      motusBinding' <- openMotusBinding provider "ds6-composed-episode" defaultSpec archive' "input"
      current <-
        newEpisodeAttachment
          (episode "episode-local-1")
          (snapshot "local")
          (motusBinding motusBinding')
          "attachment-local-1"
          100
          episodeOptions {Episode.clock = pure 1}
      execution <- bindingExecution motusBinding'
      adapter <- newMotusWorkspaceAdapter provider execution ["/bin/sh", "-c", "test -f output.txt"] defaultCommandTimeout
      gw <- gateway current (workspaceHandsAdapter adapter) 256
      grant <-
        openGrant
          (grants current)
          (grantSpec [WorkspaceWrite, WorkspaceTest] 90 2) {specWritablePaths = ["output.txt"]}
      let payload callId method params =
            Object
              [ ("version", Int 1)
              , ("call_id", String callId)
              , ("episode_id", String "episode-local-1")
              , ("attachment_id", String (episodeAttachmentId current))
              , ("attachment_epoch", Int (episodeEpoch current))
              , ("grant_epoch", Int grant.grantEpoch)
              , ("method", String method)
              , ("params", Object params)
              ]
      ((.ok) <$> submit gw (payload "write" "workspace_write" [("path", String "output.txt"), ("content", String "safe")])) `shouldReturn` True
      ((.ok) <$> submit gw (payload "test" "workspace_test" [])) `shouldReturn` True
      record <- settle current 30
      let restored = tmp </> "restored"
      extractWorkspaceArchive record.archive restored
      readFile (restored </> "output.txt") `shouldReturn` "safe"
      record.settlement.verified `shouldBe` True
      cleanup <- bindingCleanupResult motusBinding'
      maybe False (const True) cleanup `shouldBe` True
      (maybe False (const True) <$> providerLookup provider "ds6-composed-episode") `shouldReturn` False

      providerManaged <- scripted [Verified True]
      next <- successor current (episode "episode-local-2") (snapshot "provider") providerManaged.binding "attachment-local-2" 200 Nothing Nothing
      successorGrant <- openGrant (grants next) (grantSpec [WorkspaceRead] 190 1)
      poison <- gateway next (readOnlyAdapter (fail "stale request crossed the successor gateway")) 256
      stale <- submit poison (readRequest "old-attachment" "episode-local-2" "attachment-local-1" 1 successorGrant.grantEpoch "output.txt")
      (rejectionCategoryText . (.category) <$> stale.resultError) `shouldBe` Just "stale_epoch"

  -- @True@ is not an 'Integer'; the Haskell type already refuses it.
  forM_ [0, -1] $ \epoch' ->
    it ("test_attachment_epoch_is_exactly_positive[" <> show epoch' <> "]") $ do
      s <- scripted [Verified True]
      raises (attachmentAt s "attachment-1" epoch') ValueError "epoch"

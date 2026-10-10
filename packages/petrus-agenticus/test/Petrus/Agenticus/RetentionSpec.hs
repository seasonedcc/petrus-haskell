-- | Port of @tests/petrus/agenticus/attachment/test_retention.py@.
--
-- The reference monkeypatches provider methods on a live object. Here
-- 'EnvironmentProvider' is a record, so each test builds the overridden
-- record before the binding captures it, or passes it to the custody call
-- that uses it.
module Petrus.Agenticus.RetentionSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, void)
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Attachment.Retention
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Resolution
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Thread.Identity
import Petrus.Motus.Execution hiding (ErrorKind (..))
import Petrus.Motus.Execution.Archive (workspaceArchive)
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

raises :: IO a -> ErrorClass -> Text -> Expectation
raises action cls fragment =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      (e.errorClass, e.errorClass `isSubclassOf` cls) `shouldBe` (e.errorClass, True)
      (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
    Right _ -> expectationFailure ("expected " <> show cls <> " containing " <> show fragment)

localEnvironment :: IO EnvironmentProvider
localEnvironment = localProvider <$> newLocalProcessEnvironment

-- | @_attachment@: an Episode attachment at epoch 3 over a fresh Motus lease
-- for @territory-operation@.
attachmentIn :: FilePath -> EnvironmentProvider -> IO (EpisodeAttachment, MotusAttachmentBinding)
attachmentIn root provider = do
  let sourceDir = root </> "source"
  createDirectory sourceDir
  writeFile (sourceDir </> "canary.txt") "retained"
  archive' <- workspaceArchive sourceDir
  binding <- openMotusBinding provider "territory-operation" defaultSpec archive' "initial"
  attachment <-
    newEpisodeAttachment
      (episode "episode-one")
      (snapshot "one")
      (motusBinding binding)
      "attachment-one"
      100
      episodeOptions {Episode.attachmentEpoch = 3}
  pure (attachment, binding)

custodyAt :: FilePath -> Double -> IO SqliteTerritoryCustody
custodyAt path' now = openTerritoryCustodyWith path' (pure now)

reclaimTwo :: SqliteTerritoryCustody -> Text -> EnvironmentProvider -> IO EpisodeAttachment
reclaimTwo custody custodyId' provider =
  reclaim custody custodyId' "host-one" provider (episode "episode-two") (snapshot "two") "attachment-two" 100 Nothing Nothing

phaseOf :: SqliteTerritoryCustody -> Text -> IO (Maybe TerritoryCustodyPhase)
phaseOf custody custodyId' = fmap (.phase) <$> lookupCustody custody custodyId'

-- | @with sqlite3.connect(path) as database: database.execute(...)@.
rawExecute :: FilePath -> Text -> [SqlValue] -> IO ()
rawExecute path' sql parameters = do
  db <- openDatabase path'
  statement <- prepareStatement db sql
  runStatement statement parameters
  finalizeStatement statement
  closeDatabase db

rawPhase :: FilePath -> Text -> IO (Maybe [SqlValue])
rawPhase path' custodyId' = do
  db <- openDatabase path'
  statement <- prepareStatement db "SELECT phase FROM territory_custody WHERE custody_id=?"
  row <- queryRow statement [SQLText custodyId']
  finalizeStatement statement
  closeDatabase db
  pure row

withTemp :: (FilePath -> IO a) -> IO a
withTemp = withSystemTempDirectory "retention"

spec :: Spec
spec = describe "attachment._retention (test_retention.py)" $ do
  it "retained lease reclaims into a distinct episode and retires exactly" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, oldBinding) <- attachmentIn tmp provider
    let path' = tmp </> "custody" </> "territories.db"
    custody <- custodyAt path' 10
    released <- release custody "custody-one" "host-one" attachment 50 30
    Just retained <- lookupCustody custody "custody-one"
    retained.phase `shouldBe` Retained
    retained.archive `shouldBe` Just released.archive
    (isJust <$> providerLookup provider (identityOperationId released.territory)) `shouldReturn` True
    raises (bindingExportArchive oldBinding) MotusBindingError "released"
    closeTerritoryCustody custody

    reconstructed <- custodyAt path' 20
    successor' <- reclaimTwo reconstructed "custody-one" provider
    phaseOf reconstructed "custody-one" `shouldReturn` Just Attached
    episodeId successor' `shouldBe` episode "episode-two"
    episodeEpoch successor' `shouldBe` 4
    (bindingLeaseIdentity <$> (episodeBinding successor').motus) `shouldBe` Just released.territory

    void (release reconstructed "custody-one" "host-one" successor' 60 30)
    retired <- retire reconstructed "custody-one" "host-one" provider
    retired.phase `shouldBe` Retired
    (isJust retired.cleanup, isNothing retired.archive) `shouldBe` (True, True)
    (isNothing <$> providerLookup provider (identityOperationId released.territory)) `shouldReturn` True
    closeTerritoryCustody reconstructed
    bytes <- B.readFile path'
    ("retained" `B.isInfixOf` bytes) `shouldBe` False

  it "recovery retires an incomplete release instead of reusing it" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    let path' = tmp </> "custody" </> "territories.db"
    custody <- custodyAt path' 10
    void (beginRelease custody "custody-crash" "host-one" attachment 50)
    closeTerritoryCustody custody

    recovered <- custodyAt path' 20
    [record] <- recover recovered
    (record.phase, record.archive) `shouldBe` (Retiring, Nothing)
    ((.phase) <$> retire recovered "custody-crash" "host-one" provider) `shouldReturn` Retired
    (isNothing <$> providerLookup provider (leaseOperationId record.lease)) `shouldReturn` True
    closeTerritoryCustody recovered

  it "a corrupt archive never reclaims and preserves the exact cleanup obligation" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    let path' = tmp </> "custody" </> "territories.db"
    custody <- custodyAt path' 10
    released <- release custody "custody-corrupt" "host-one" attachment 50 30
    closeTerritoryCustody custody
    rawExecute path' "UPDATE territory_custody SET archive=? WHERE custody_id=?" [SQLBlob "corrupt", SQLText "custody-corrupt"]

    recovered <- custodyAt path' 20
    raises (reclaimTwo recovered "custody-corrupt" provider) StorageError "digest"
    phaseOf recovered "custody-corrupt" `shouldReturn` Just Retiring
    ((.phase) <$> retire recovered "custody-corrupt" "host-one" provider) `shouldReturn` Retired
    (isNothing <$> providerLookup provider (identityOperationId released.territory)) `shouldReturn` True
    closeTerritoryCustody recovered

  it "a missing retained lease never falls through to creation" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    custody <- custodyAt (tmp </> "custody" </> "territories.db") 10
    void (release custody "custody-missing" "host-one" attachment 50 30)
    Just retained <- lookupCustody custody "custody-missing"
    (cleanupVerified <$> providerDestroy provider retained.lease) `shouldReturn` True
    let noCreate = provider {providerCreate = \_ _ -> throwIO (userError "create must not run")}
    raises (reclaimTwo custody "custody-missing" noCreate) StorageError "absent or not ready"
    phaseOf custody "custody-missing" `shouldReturn` Just Retiring
    ((.phase) <$> retire custody "custody-missing" "host-one" noCreate) `shouldReturn` Retired
    closeTerritoryCustody custody

  it "a foreign lookup remains retryable until exact retirement is verified" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    custody <- custodyAt (tmp </> "custody" </> "territories.db") 10
    void (release custody "custody-foreign" "host-one" attachment 50 30)
    Just retained <- lookupCustody custody "custody-foreign"
    let l = retained.lease
        foreignLease = ok (mkEnvironmentLease (leaseOperationId l) (leaseProvider l) "foreign-lease" (leaseCapabilities l) (leaseState l))
        foreignProvider = provider {providerLookup = \_ -> pure (Just foreignLease)}
    raises (reclaimTwo custody "custody-foreign" foreignProvider) StorageError "conflicts"
    phaseOf custody "custody-foreign" `shouldReturn` Just Retiring
    raises (retire custody "custody-foreign" "host-one" foreignProvider) StorageError "foreign current lease"
    ((.phase) <$> retire custody "custody-foreign" "host-one" provider) `shouldReturn` Retired
    (isNothing <$> providerLookup provider (leaseOperationId l)) `shouldReturn` True
    closeTerritoryCustody custody

  it "expired custody moves to exact retirement instead of reclaim" $ withTemp $ \tmp -> do
    now <- newIORef (10 :: Double)
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    custody <- openTerritoryCustodyWith (tmp </> "custody" </> "territories.db") (readIORef now)
    void (release custody "custody-expired" "host-one" attachment 15 30)
    writeIORef now 20
    raises (reclaimTwo custody "custody-expired" provider) StorageError "expired"
    ((.phase) <$> retire custody "custody-expired" "host-one" provider) `shouldReturn` Retired
    closeTerritoryCustody custody

  it "expiry during export never acknowledges retention" $ withTemp $ \tmp -> do
    now <- newIORef (10 :: Double)
    base <- localEnvironment
    let provider = base {providerExport = \execution -> providerExport base execution <* writeIORef now 20}
    (attachment, _) <- attachmentIn tmp provider
    custody <- openTerritoryCustodyWith (tmp </> "custody" </> "territories.db") (readIORef now)
    raises (release custody "custody-export-expired" "host-one" attachment 15 30) EpisodeAttachmentError "release to host custody failed"
    phaseOf custody "custody-export-expired" `shouldReturn` Just Retiring
    ((.phase) <$> retire custody "custody-export-expired" "host-one" provider) `shouldReturn` Retired
    closeTerritoryCustody custody

  it "the custody database has one live writer" $ withTemp $ \tmp -> do
    let path' = tmp </> "custody" </> "territories.db"
    first <- openTerritoryCustody path'
    raises (openTerritoryCustody path') StorageError "live writer"
    closeTerritoryCustody first

  it "release closes operation admission and waits before export" $ withTemp $ \tmp -> do
    exported <- newEmptyMVar
    base <- localEnvironment
    let provider = base {providerExport = \execution -> void (tryPutMVar exported ()) >> providerExport base execution}
    (attachment, binding) <- attachmentIn tmp provider
    custody <- custodyAt (tmp </> "custody" </> "territories.db") 10
    entered <- newEmptyMVar
    finish <- newEmptyMVar
    running <- async' $ withBindingOperation binding $ do
      putMVar entered ()
      timeout 2_000_000 (readMVar finish) >>= maybe (fail "finish not set") pure
    waitFor entered
    releasing <- async' (release custody "custody-drain" "host-one" attachment 50 30)
    closed <- pollClosed binding 100
    closed `shouldBe` True
    (,) <$> done releasing <*> (isJust <$> tryReadMVar exported) `shouldReturn` (False, False)
    putMVar finish ()
    void (await running)
    released <- await releasing
    (isJust <$> tryReadMVar exported) `shouldReturn` True
    phaseOf custody "custody-drain" `shouldReturn` Just Retained
    void (retire custody "custody-drain" "host-one" provider)
    closeTerritoryCustody custody
    identityOperationId released.territory `shouldBe` "territory-operation"

  it "one provider operation cannot have two live custody ids" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    custody <- custodyAt (tmp </> "custody" </> "territories.db") 10
    void (beginRelease custody "custody-a" "host-one" attachment 50)
    raises (beginRelease custody "custody-b" "host-one" attachment 50) StorageError "live custody obligation"
    [record] <- recover custody
    (record.custodyId, record.phase) `shouldBe` ("custody-a", Retiring)
    void (retire custody "custody-a" "host-one" provider)
    closeTerritoryCustody custody

  forM_ ["episode", "attachment" :: Text] $ \reuse ->
    it ("reclaim refuses source identities without changing retained custody (" <> T.unpack reuse <> ")") $ withTemp $ \tmp -> do
      provider <- localEnvironment
      (attachment, _) <- attachmentIn tmp provider
      custody <- custodyAt (tmp </> "custody" </> "territories.db") 10
      void (release custody "custody-distinct" "host-one" attachment 50 30)
      let episode' = if reuse == "episode" then episodeId attachment else episode "episode-two"
          attachmentId' = if reuse == "attachment" then episodeAttachmentId attachment else "attachment-two"
      raises
        (reclaim custody "custody-distinct" "host-one" provider episode' (snapshot "two") attachmentId' 100 Nothing Nothing)
        ValueError
        "distinct"
      phaseOf custody "custody-distinct" `shouldReturn` Just Retained
      void (retire custody "custody-distinct" "host-one" provider)
      closeTerritoryCustody custody

  it "malformed non-identity state becomes retirable but a malformed identity quarantines" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    let path' = tmp </> "custody" </> "territories.db"
    custody <- custodyAt path' 10
    void (release custody "custody-malformed" "host-one" attachment 50 30)
    closeTerritoryCustody custody
    rawExecute path' "UPDATE territory_custody SET capabilities='not-json' WHERE custody_id='custody-malformed'" []
    recovered <- custodyAt path' 20
    [retiring] <- recover recovered
    retiring.phase `shouldBe` Retiring
    void (retire recovered "custody-malformed" "host-one" provider)
    closeTerritoryCustody recovered

    let secondRoot = tmp </> "second"
    createDirectory secondRoot
    (second, _) <- attachmentIn secondRoot provider
    let secondPath = tmp </> "other-custody" </> "territories.db"
    custody2 <- custodyAt secondPath 10
    void (release custody2 "custody-bad-identity" "host-one" second 50 30)
    closeTerritoryCustody custody2
    rawExecute secondPath "UPDATE territory_custody SET lease_id='' WHERE custody_id='custody-bad-identity'" []
    quarantined <- custodyAt secondPath 20
    raises (recover quarantined) StorageError "quarantined"
    rawPhase secondPath "custody-bad-identity" `shouldReturn` Just [SQLText "quarantined"]
    closeTerritoryCustody quarantined

  forM_ ["operation_id", "provider", "lease_id" :: Text] $ \column ->
    it ("non-text destruction identity quarantines without provider cleanup (" <> T.unpack column <> ")") $ withTemp $ \tmp -> do
      base <- localEnvironment
      (attachment, _) <- attachmentIn tmp base
      let path' = tmp </> "custody" </> "territories.db"
      custody <- custodyAt path' 10
      void (release custody "custody-binary-identity" "host-one" attachment 50 30)
      closeTerritoryCustody custody
      rawExecute
        path'
        ("UPDATE territory_custody SET " <> column <> "=? WHERE custody_id=?")
        [SQLBlob "territory-identity", SQLText "custody-binary-identity"]
      cleanupCalled <- newIORef False
      let provider =
            base
              { providerDestroy = \_ -> do
                  writeIORef cleanupCalled True
                  throwIO (userError "malformed identity must never reach provider cleanup")
              }
      recovered <- custodyAt path' 20
      raises (recover recovered) StorageError "quarantined"
      raises (retire recovered "custody-binary-identity" "host-one" provider) StorageError "malformed"
      readIORef cleanupCalled `shouldReturn` False
      rawPhase path' "custody-binary-identity" `shouldReturn` Just [SQLText "quarantined"]
      closeTerritoryCustody recovered

  it "recovery fences an attached lease instead of reconstructing active work" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, binding) <- attachmentIn tmp provider
    let path' = tmp </> "custody" </> "territories.db"
    custody <- custodyAt path' 10
    void (release custody "custody-attached-crash" "host-one" attachment 50 30)
    reclaimed <- reclaimTwo custody "custody-attached-crash" provider
    (bindingLeaseIdentity <$> (episodeBinding reclaimed).motus) `shouldBe` Just (bindingLeaseIdentity binding)
    closeTerritoryCustody custody

    recovered <- custodyAt path' 20
    [record] <- recover recovered
    record.phase `shouldBe` Retiring
    ((.phase) <$> retire recovered "custody-attached-crash" "host-one" provider) `shouldReturn` Retired
    closeTerritoryCustody recovered

  it "retirement retries unverified cleanup and a destroy before commit" $ withTemp $ \tmp -> do
    provider <- localEnvironment
    (attachment, _) <- attachmentIn tmp provider
    let path' = tmp </> "custody" </> "territories.db"
    custody <- custodyAt path' 10
    void (release custody "custody-retire-retry" "host-one" attachment 50 30)
    Just retained <- lookupCustody custody "custody-retire-retry"
    let operation = leaseOperationId retained.lease
        unverified = provider {providerDestroy = \l -> pure (CleanupResult (leaseIdentity l) Unverified "uncertain")}
    first <- retire custody "custody-retire-retry" "host-one" unverified
    first.phase `shouldBe` Retiring
    (isJust <$> providerLookup provider operation) `shouldReturn` True

    -- The reference swaps @custody._write@ for a crashing one after the real
    -- destroy. Here a second connection takes the write lock after the
    -- destroy, so the tombstone write genuinely fails after its busy timeout.
    blocker <- newIORef Nothing
    let destroyThenBlock l = do
          result <- providerDestroy provider l
          db <- openDatabase path'
          execute_ db "BEGIN EXCLUSIVE"
          writeIORef blocker (Just db)
          pure result
    try (retire custody "custody-retire-retry" "host-one" provider {providerDestroy = destroyThenBlock}) >>= \case
      Left (e :: AgenticusError) -> e.errorClass `shouldBe` OtherError "OperationalError"
      Right _ -> expectationFailure "the tombstone write must fail while the ledger is locked"
    readIORef blocker >>= mapM_ (\db -> execute_ db "ROLLBACK" >> closeDatabase db)
    (isNothing <$> providerLookup provider operation) `shouldReturn` True
    ((.phase) <$> retire custody "custody-retire-retry" "host-one" provider) `shouldReturn` Retired
    closeTerritoryCustody custody

-- | Run an action on another thread; the result is read from the MVar.
async' :: IO a -> IO (MVar (Either SomeException a))
async' action = do
  box <- newEmptyMVar
  void (forkIO (try action >>= putMVar box))
  pure box

await :: MVar (Either SomeException a) -> IO a
await box = timeout 5_000_000 (takeMVar box) >>= maybe (fail "timed out") (either throwIO pure)

done :: MVar a -> IO Bool
done box = isJust <$> tryReadMVar box

waitFor :: MVar () -> IO ()
waitFor signal = timeout 2_000_000 (readMVar signal) >>= maybe (fail "event not set") pure

-- | Poll (10 ms apart, at most @n@ times) until the binding's operation
-- admission refuses.
pollClosed :: MotusAttachmentBinding -> Int -> IO Bool
pollClosed binding n
  | n <= 0 = pure False
  | otherwise =
      try (withBindingOperation binding (pure ())) >>= \case
        Left (e :: AgenticusError) | e.errorClass == MotusBindingError -> pure True
        Left e -> throwIO e
        Right () -> do
          threadDelay 10_000
          pollClosed binding (n - 1)

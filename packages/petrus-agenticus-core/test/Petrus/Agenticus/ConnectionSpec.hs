{-# LANGUAGE RecordWildCards #-}

-- | @tests/petrus/agenticus/connection/test_custody.py@, test for test.
module Petrus.Agenticus.ConnectionSpec (spec) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Bits ((.&.))
import Data.ByteArray qualified as BA
import Data.ByteString qualified as B
import Data.IORef
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.ConnectionSupport
import Petrus.Agenticus.Connection.Custody
import Petrus.Agenticus.Connection.Key
import Petrus.Agenticus.Connection.Materialization
import Petrus.Agenticus.Connection.Storage
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import System.Directory (createFileLink, doesDirectoryExist, doesFileExist, listDirectory, removeFile)
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import System.Posix.Types (FileMode)
import System.Timeout (timeout)
import Test.Hspec hiding (pending)

spec :: Spec
spec = describe "connection/test_custody.py" $ do
  it "test_ordinary_materialization_moves_one_logical_connection_between_hosts" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    enrollHost rig.custody "h2" "enroll-h2"
    _ <- authorizeMain rig

    h1 <- materialize rig.custody "connection-main" "h1" LeaseRefresh 60 "materialize-h1"
    modeOf (materializerRoot rig.materializer) `shouldReturn` 0o700
    modeOf (materializedPath h1.home) `shouldReturn` 0o600
    activate rig.custody h1 "activate-h1"
    readMaterialized h1.home >>= providerRefresh rig.provider >>= replaceMaterialized h1.home
    publication <- checkpoint rig.custody h1 "checkpoint-h1"

    publication.connection.identity `shouldBe` mainIdentity
    publication.connection.status `shouldBe` StatusReady
    publication.connection.stateVersion `shouldBe` 2
    publication.cleanup.removed `shouldBe` True
    publication.cleanup.physicalErasureGuaranteed `shouldBe` False
    materializedErased h1.home `shouldReturn` True

    h2 <- materialize rig.custody "connection-main" "h2" LeaseRead 30 "materialize-h2"
    (providerInspect rig.provider <$> readMaterialized h2.home) `shouldReturn` ("account-1", 1)
    readIORef rig.provider.authorizeCalls `shouldReturn` 1
    operation <- lookupOperation rig.custody "materialize-h2"
    ((.eventKind) <$> operation) `shouldBe` Just "materialization.acquired"
    (operation >>= (.leaseId)) `shouldBe` Just h2.fence.leaseId
    raisesMatching (admitResult rig.custody (forged h2.fence) "admit-forged") StaleAttachment "result"
    released <- release rig.custody h2 "release-h2"
    released.cleanup.removed `shouldBe` True
    materializedErased h2.home `shouldReturn` True
    repeated <- release rig.custody h2 "release-h2-again"
    repeated.cleanup.alreadyAbsent `shouldBe` True

  -- repr() keeps characters Unicode 16.0 assigned (CPython 3.14): GHC's
  -- Unicode 15.1 general categories called U+105C0 unassigned, so the copy
  -- this package carried escaped it as \U000105c0.
  it "spells connection ids with CPython 3.14's repr" $ withRig $ \rig -> do
    _ <- authorizeWith rig "connection-\x105C0" "authorize-new"
    raisesMatching (authorizeWith rig "connection-\x105C0" "authorize-again") CustodyError "connection 'connection-\x105C0' is already authorized"

  it "test_concurrent_refresh_has_one_cas_winner_and_waits_for_readers" $ withRig $ \rig -> do
    forM_ ["h1", "h2"] $ \host -> enrollHost rig.custody host ("enroll-" <> host)
    _ <- authorizeMain rig
    reader <- materialize rig.custody "connection-main" "h1" LeaseRead 60 "reader"
    raisesMatching
      (materialize rig.custody "connection-main" "h2" LeaseRefresh 60 "blocked-writer")
      LeaseConflict
      "refresh custody"
    _ <- release rig.custody reader "release-reader"

    revision <- (.revision) <$> rig.storage.load
    barrier <- newBarrier 2
    contenders <- forM [1 :: Int, 2] $ \_ -> do
      inner <- openSqliteConnectionStorage (rig.root </> "connections.sqlite3")
      storage <- barrierStorage inner barrier revision
      materializer <- newPrivateFileMaterializer (rig.root </> "materialized")
      pure (agentConnectionCustody storage rig.keys.operations materializer (readIORef rig.clock))
    pending <- forM (zip [1 :: Int ..] contenders) $ \(index, contender) -> do
      done <- newEmptyMVar
      _ <-
        forkFinally
          ( materialize
              contender
              "connection-main"
              ("h" <> T.pack (show index))
              LeaseRefresh
              60
              ("contender-" <> T.pack (show index))
          )
          (putMVar done)
      pure done
    outcomes <- forM pending $ \done ->
      takeMVar done >>= \case
        Right materialization -> pure (Right materialization)
        Left failure -> case fromAgenticus failure of
          Just refusal | refusal `isInstanceOf` LeaseConflict -> pure (Left refusal)
          _ -> throwIO failure
    let winners = [winner | Right winner <- outcomes]
    length winners `shouldBe` 1
    length [() | Left _ <- outcomes] `shouldBe` 1
    forM_ winners $ \winner -> do
      let owner = if winner.fence.hostId == "h1" then head' contenders else last' contenders
      _ <- release owner winner "release-winner"
      pure ()
    mapM_ closeCustody contenders

  it "test_current_host_renews_bounded_read_and_current_attachments_are_admitted" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    reader <- materialize rig.custody "connection-main" "h1" LeaseRead 10 "renewable-reader"

    advance rig 9
    renewal <- renew rig.custody reader 10 "renew-reader"
    advance rig 2
    admitted <- admitResult rig.custody reader.fence "admit-current-result"

    renewal.expiresAt `shouldBe` 1019
    admitted.purpose `shouldBe` "result"
    admitted.attachmentId `shouldBe` reader.fence.attachmentId
    (providerInspect rig.provider <$> readMaterialized reader.home) `shouldReturn` ("account-1", 0)
    _ <- release rig.custody reader "release-renewed-reader"

    refresh <- materialize rig.custody "connection-main" "h1" LeaseRefresh 10 "current-refresh"
    activate rig.custody refresh "activate-current-refresh"
    effect <- admitEffect rig.custody refresh.fence "admit-current-effect"
    effect.purpose `shouldBe` "effect"
    readMaterialized refresh.home >>= providerRefresh rig.provider >>= replaceMaterialized refresh.home
    _ <- checkpoint rig.custody refresh "checkpoint-current-refresh"
    pure ()

  forM_ [("nan", 0 / 0), ("inf", 1 / 0 :: Double)] $ \(label, ttl) ->
    it ("test_materialization_and_renewal_refuse_nonfinite_lease_bounds[" <> label <> "]") $ withRig $ \rig -> do
      enrollHost rig.custody "h1" "enroll-h1"
      _ <- authorizeMain rig

      raisesMatching
        (materialize rig.custody "connection-main" "h1" LeaseRead ttl "nonfinite-materialization")
        ValueError
        "finite"

      reader <- materialize rig.custody "connection-main" "h1" LeaseRead 10 "finite-reader"
      raisesMatching (renew rig.custody reader ttl "nonfinite-renewal") ValueError "finite"
      _ <- release rig.custody reader "release-finite-reader"
      pure ()

  it "test_operation_lookup_reconciles_a_lost_publication_acknowledgement" $ withRig $ \rig -> do
    inner <- openSqliteConnectionStorage (rig.root </> "uncertain.sqlite3")
    loseNext <- newIORef True
    let storage =
          ConnectionStorage
            { load = inner.load
            , compareAndSwap = \expected replacement -> do
                published <- inner.compareAndSwap expected replacement
                lose <- readIORef loseNext
                if published && lose
                  then do
                    writeIORef loseNext False
                    throwAgenticus RuntimeError "synthetic lost publication acknowledgement"
                  else pure published
            , close = inner.close
            }
    materializer <- newPrivateFileMaterializer (rig.root </> "uncertain-materialized")
    let uncertain = agentConnectionCustody storage rig.keys.operations materializer (readIORef rig.clock)

    raisesMatching (enrollHost uncertain "h1" "uncertain-enrollment") RuntimeError "lost publication acknowledgement"

    operation <- lookupOperation uncertain "uncertain-enrollment"
    ((.eventKind) <$> operation) `shouldBe` Just "host.enrolled"
    (operation >>= (.hostId)) `shouldBe` Just "h1"
    ((.details) <$> operation)
      `shouldBe` Just
        [ ("ambiguous_connections", AuditInt 0)
        , ("canceled_leases", AuditInt 0)
        , ("enrollment_epoch", AuditInt 1)
        , ("expired_leases", AuditInt 0)
        ]
    raisesMatching (enrollHost uncertain "h1" "uncertain-enrollment") OperationConflict "lookup_operation"
    closeCustody uncertain

  it "test_cas_contention_is_bounded_and_publishes_no_operation" $ withRig $ \rig -> do
    inner <- openSqliteConnectionStorage (rig.root </> "refusing.sqlite3")
    attempts <- newIORef (0 :: Int)
    let storage =
          ConnectionStorage
            { load = inner.load
            , compareAndSwap = \_ _ -> modifyIORef' attempts (+ 1) >> pure False
            , close = inner.close
            }
    materializer <- newPrivateFileMaterializer (rig.root </> "refusing-materialized")
    let custody = agentConnectionCustody storage rig.keys.operations materializer (readIORef rig.clock)

    raisesMatching (enrollHost custody "h1" "never-published") StorageContention "bounded CAS retries"

    readIORef attempts `shouldReturn` 8
    lookupOperation custody "never-published" `shouldReturn` Nothing
    closeCustody custody

  it "test_crash_before_provider_mutation_reconciles_to_last_accepted_state" $ withRig $ \rig -> do
    forM_ ["h1", "h2"] $ \host -> enrollHost rig.custody host ("enroll-" <> host)
    original <- authorizeMain rig
    abandoned <- materialize rig.custody "connection-main" "h1" LeaseRefresh 5 "abandoned-before-activation"
    closeCustody rig.custody
    advance rig 6

    recovered <- reopen rig
    result <- recover recovered "recover-before-activation"

    result.expiredLeases `shouldBe` 1
    result.ambiguousConnections `shouldBe` []
    ((.status) <$> lookupConnection recovered "connection-main") `shouldReturn` StatusReady
    materializedErased abandoned.home `shouldReturn` True
    h2 <- materialize recovered "connection-main" "h2" LeaseRead 10 "read-recovered"
    readMaterialized h2.home `shouldReturn` original
    _ <- release recovered h2 "release-recovered"
    closeCustody recovered

  it "test_crash_after_provider_rotation_fails_closed_to_reauthorization" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    abandoned <- materialize rig.custody "connection-main" "h1" LeaseRefresh 5 "rotating-runtime"
    activate rig.custody abandoned "activate-rotating-runtime"
    rotated <- readMaterialized abandoned.home >>= providerRefresh rig.provider
    replaceMaterialized abandoned.home rotated
    closeCustody rig.custody
    advance rig 6

    recovered <- reopen rig
    result <- recover recovered "recover-ambiguous-refresh"

    result.expiredLeases `shouldBe` 1
    result.ambiguousConnections `shouldBe` ["connection-main"]
    view <- lookupConnection recovered "connection-main"
    view.status `shouldBe` StatusReauthorizationRequired
    view.authorityEpoch `shouldBe` 2
    view.stateDigest `shouldBe` Nothing
    materializedErased abandoned.home `shouldReturn` True
    raisesMatching
      (materialize recovered "connection-main" "h1" LeaseRead 10 "fail-closed-read")
      ReauthorizationRequired
      "connection-main"
    mismatched <- newOpaqueState rotated
    different <-
      either throwIO pure $
        mkConnectionIdentity "connection-main" providerId "different-account" "subscription_oauth"
    raisesMatching
      (authorize recovered different mismatched "mismatched-reauthorization")
      CustodyError
      "different provider authority"
    opaqueStateErased mismatched `shouldReturn` True
    fresh <- newOpaqueState rotated
    _ <- authorize recovered mainIdentity fresh "explicit-reauthorization"
    ((.status) <$> lookupConnection recovered "connection-main") `shouldReturn` StatusReady
    closeCustody recovered

  it "test_recovery_sweeps_released_plaintext_left_after_publication_crash" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    reader <- materialize rig.custody "connection-main" "h1" LeaseRead 10 "published-reader"
    _ <- release rig.custody reader "published-release"

    let abandoned = BA.convert (TE.encodeUtf8 accessCanary) :: ScrubbedBytes
    orphan <- materializeState rig.materializer reader.fence.attachmentId abandoned
    eraseBuffer abandoned
    materializedErased orphan `shouldReturn` False

    recovered <- reopen rig
    result <- recover recovered "sweep-published-orphan"

    result.expiredLeases `shouldBe` 0
    result.cleanup.removed `shouldBe` 1
    result.cleanup.unresolved `shouldBe` 0
    materializedErased orphan `shouldReturn` True
    closeCustody recovered

  it "test_stale_writer_never_replaces_a_newer_rotated_authority" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    stale <- materialize rig.custody "connection-main" "h1" LeaseRefresh 60 "stale-writer"
    activate rig.custody stale "activate-stale-writer"
    readMaterialized stale.home >>= providerRefresh rig.provider >>= replaceMaterialized stale.home

    currentState <- providerRotateForOperator rig.provider
    rotated <- newOpaqueState currentState >>= \state -> rotate rig.custody "connection-main" state "operator-rotation"

    rotated.authorityEpoch `shouldBe` 2
    rotated.stateVersion `shouldBe` 2
    raisesMatching (checkpoint rig.custody stale "late-stale-return") StaleCustody "no longer current"
    raisesMatching (admitResult rig.custody stale.fence "late-stale-result") StaleAttachment "result"
    materializedErased stale.home `shouldReturn` True
    lookupConnection rig.custody "connection-main" `shouldReturn` rotated

  it "test_rotation_supersedes_an_expired_unreconciled_refresh_lease" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    expired <- materialize rig.custody "connection-main" "h1" LeaseRefresh 5 "expired-writer"
    activate rig.custody expired "activate-expired-writer"
    advance rig 6

    state <- providerRotateForOperator rig.provider >>= newOpaqueState
    rotated <- rotate rig.custody "connection-main" state "rotate-after-expiry"

    rotated.status `shouldBe` StatusReady
    rotated.authorityEpoch `shouldBe` 2
    rotated.stateVersion `shouldBe` 2
    materializedErased expired.home `shouldReturn` True
    raisesMatching (checkpoint rig.custody expired "expired-return") StaleCustody "no longer current"

  it "test_releasing_activated_refresh_fails_closed_and_is_idempotently_cleanable" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    refresh <- materialize rig.custody "connection-main" "h1" LeaseRefresh 10 "activated-release"
    activate rig.custody refresh "activate-release"

    released <- release rig.custody refresh "release-ambiguous"

    connection <- lookupConnection rig.custody "connection-main"
    connection.status `shouldBe` StatusReauthorizationRequired
    connection.authorityEpoch `shouldBe` 2
    connection.stateDigest `shouldBe` Nothing
    released.cleanup.removed `shouldBe` True
    repeated <- release rig.custody refresh "release-ambiguous-again"
    repeated.cleanup.alreadyAbsent `shouldBe` True

  it "test_host_removal_and_reenrollment_fence_old_custody_and_clean_reachable_state" $ withRig $ \rig -> do
    forM_ ["h1", "h2"] $ \host -> enrollHost rig.custody host ("enroll-" <> host)
    _ <- authorizeMain rig
    old <- materialize rig.custody "connection-main" "h2" LeaseRefresh 60 "old-host-view"

    removal <- removeHost rig.custody "h2" "remove-h2"

    removal.canceledLeases `shouldBe` 1
    removal.cleanup.removed `shouldBe` 1
    removal.cleanup.unresolved `shouldBe` 0
    removal.offlineErasureLimit `shouldBe` True
    materializedErased old.home `shouldReturn` True
    raisesMatching (renew rig.custody old 10 "removed-renew") HostNotEnrolled "h2"
    raisesMatching (checkpoint rig.custody old "removed-checkpoint") StaleCustody "no longer current"
    raisesMatching (admitEffect rig.custody old.fence "removed-effect") StaleAttachment "effect"

    enrollHost rig.custody "h2" "reenroll-h2"
    replacement <- materialize rig.custody "connection-main" "h2" LeaseRead 10 "replacement-view"
    replacement.fence.hostEpoch `shouldBe` 3
    _ <- release rig.custody replacement "release-replacement"
    pure ()

  it "test_revoke_fences_every_attachment_and_returns_secret_free_cleanup" $ withRig $ \rig -> do
    forM_ ["h1", "h2"] $ \host -> enrollHost rig.custody host ("enroll-" <> host)
    _ <- authorizeMain rig
    h1 <- materialize rig.custody "connection-main" "h1" LeaseRead 60 "read-h1"
    h2 <- materialize rig.custody "connection-main" "h2" LeaseRead 60 "read-h2"

    result <- revoke rig.custody "connection-main" "revoke-main"

    result.connection.status `shouldBe` StatusRevoked
    result.connection.authorityEpoch `shouldBe` 2
    result.providerRevocation `shouldBe` "not_claimed"
    result.cleanup.attempted `shouldBe` 2
    result.cleanup.removed `shouldBe` 2
    materializedErased h1.home `shouldReturn` True
    materializedErased h2.home `shouldReturn` True
    raisesMatching (admitResult rig.custody h1.fence "late-result") StaleAttachment "result"
    raisesMatching (admitEffect rig.custody h2.fence "late-effect") StaleAttachment "effect"
    raisesMatching
      (materialize rig.custody "connection-main" "h1" LeaseRead 10 "revoked-read")
      ReauthorizationRequired
      "connection-main"

  it "test_erase_is_key_backed_retryable_and_requires_explicit_reauthorization" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    _ <- authorizeWith rig "connection-fallback" "authorize-fallback"
    _ <- revoke rig.custody "connection-main" "revoke-main"

    writeIORef rig.keys.failErasure True
    raisesMatching (erase rig.custody "connection-main" "erase-main") KeyOperationError "erasure failed"
    pending <- lookupConnection rig.custody "connection-main"
    pending.status `shouldBe` StatusErasurePending
    pending.stateDigest `shouldSatisfy` isJust

    writeIORef rig.keys.failErasure False
    result <- erase rig.custody "connection-main" "erase-main"

    result.connection.status `shouldBe` StatusReauthorizationRequired
    result.connection.stateDigest `shouldBe` Nothing
    result.keyErasure.erased `shouldBe` True
    ((.status) <$> lookupConnection rig.custody "connection-fallback") `shouldReturn` StatusReady
    raisesMatching
      (materialize rig.custody "connection-main" "h1" LeaseRead 10 "erased-read")
      ReauthorizationRequired
      "connection-main"

    newState <- providerAuthorize rig.provider "account-1" >>= newOpaqueState
    reauthorized <- authorize rig.custody mainIdentity newState "reauthorize-after-erase"
    reauthorized.status `shouldBe` StatusReady
    reauthorized.authorityEpoch `shouldBe` 3
    reauthorized.stateVersion `shouldBe` 3

  it "test_secret_canaries_never_reach_durable_rendered_or_cleanup_evidence" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    plaintext <- authorizeMain rig
    materialized <- materialize rig.custody "connection-main" "h1" LeaseRefresh 10 "canary-view"
    activate rig.custody materialized "activate-canary-view"
    readMaterialized materialized.home >>= providerRefresh rig.provider >>= replaceMaterialized materialized.home
    result <- checkpoint rig.custody materialized "checkpoint-canary-view"
    raised <- raisesWith (checkpoint rig.custody materialized "repeat-checkpoint") StaleCustody

    databaseFiles <- filter ("connections.sqlite3" `isPrefixOf`) <$> listDirectory rig.root
    databaseBytes <- B.concat <$> mapM (B.readFile . (rig.root </>)) databaseFiles
    materializedBytes <- B.concat <$> (regularFiles (materializerRoot rig.materializer) >>= mapM B.readFile)
    records <- auditRecords rig.custody
    logText <- T.unlines <$> readIORef rig.logs
    let rendered =
          TE.encodeUtf8 (T.pack (show records <> show result <> show materialized <> show raised)) <> TE.encodeUtf8 logText
    forM_ [plaintext, TE.encodeUtf8 accessCanary, TE.encodeUtf8 refreshCanary, keyCanary] $ \marker -> do
      (marker `B.isInfixOf` databaseBytes) `shouldBe` False
      (marker `B.isInfixOf` materializedBytes) `shouldBe` False
      (marker `B.isInfixOf` rendered) `shouldBe` False
    result.connection.stateDigest `shouldNotBe` Just (sha256Hex plaintext)
    materializedErased materialized.home `shouldReturn` True
    ("credential" `T.isInfixOf` T.toLower logText) `shouldBe` False
    -- The operation log is the reference's INFO line, one per publication.
    length (T.lines logText) `shouldBe` length records

  it "test_materialization_refuses_permissive_modes_and_symlink_substitution" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    materialized <- materialize rig.custody "connection-main" "h1" LeaseRead 10 "mode-check"
    let path = materializedPath materialized.home

    setFileMode path 0o644
    raisesMatching (readMaterialized materialized.home) MaterializationSecurityError "mode"
    setFileMode path 0o600
    let outside = rig.scratch </> "outside"
    B.writeFile outside (TE.encodeUtf8 accessCanary)
    removeFile path
    createFileLink outside path
    raisesMatching (readMaterialized materialized.home) MaterializationSecurityError "symlink"
    cleaned <- release rig.custody materialized "release-tampered"
    cleaned.cleanup.securityViolation `shouldBe` True
    B.readFile outside `shouldReturn` TE.encodeUtf8 accessCanary

    let symlinkRoot = rig.scratch </> "materialized-link"
    createFileLink rig.scratch symlinkRoot
    raisesMatching (newPrivateFileMaterializer symlinkRoot) MaterializationSecurityError "symlink"

  it "test_sqlite_storage_enforces_private_modes_and_refuses_symlink_files" $ withScratch $ \scratch -> do
    let root = scratch </> "private-store"
        path = root </> "connections.sqlite3"
    storage <- openSqliteConnectionStorage path
    modeOf root `shouldReturn` 0o700
    modeOf path `shouldReturn` 0o600
    storage.close

    setFileMode path 0o644
    raisesMatching (openSqliteConnectionStorage path) StorageSecurityError "mode"
    removeFile path
    let outside = scratch </> "outside.sqlite3"
    B.writeFile outside ""
    setFileMode outside 0o600
    createFileLink outside path
    raisesMatching (openSqliteConnectionStorage path) StorageSecurityError "symlink"

  it "test_storage_validation_refuses_state_the_live_writer_cannot_publish" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    refresh <- materialize rig.custody "connection-main" "h1" LeaseRefresh 10 "refresh-state"
    snapshot <- rig.storage.load
    (connection, lease) <- case (snapshot.connections, snapshot.leases) of
      ([connection], [lease]) -> pure (connection, lease)
      _ -> fail "expected one connection and one lease"

    let withConnections replacement StorageSnapshot {..} = StorageSnapshot {connections = replacement, ..}
        withLeases replacement StorageSnapshot {..} = StorageSnapshot {leases = replacement, ..}
        readyConnection = let StoredConnection {..} = connection in StoredConnection {status = "ready", ..}
        staleLease = let StoredLease {..} = lease in StoredLease {authorityEpoch = 2, ..}
        expiring value = let StoredLease {..} = lease in StoredLease {expiresAt = value, ..}
    refusesMatching (validateSnapshot (withConnections [readyConnection] snapshot)) StorageError "active refresh custody"
    refusesMatching (validateSnapshot (withLeases [staleLease] snapshot)) StorageError "stale connection authority"
    forM_ [0 / 0, 1 / 0] $ \expiresAt ->
      refusesMatching (validateSnapshot (withLeases [expiring expiresAt] snapshot)) StorageError "finite"

    _ <- release rig.custody refresh "release-refresh-state"
    pure ()

  it "test_empty_provider_return_is_not_published" $ withRig $ \rig -> do
    enrollHost rig.custody "h1" "enroll-h1"
    _ <- authorizeMain rig
    refresh <- materialize rig.custody "connection-main" "h1" LeaseRefresh 10 "empty-return"
    activate rig.custody refresh "activate-empty-return"
    B.writeFile (materializedPath refresh.home) ""

    raisesMatching (checkpoint rig.custody refresh "reject-empty-return") CustodyError "empty opaque state"

    released <- release rig.custody refresh "release-empty-return"
    released.cleanup.alreadyAbsent `shouldBe` True
    ((.status) <$> lookupConnection rig.custody "connection-main") `shouldReturn` StatusReauthorizationRequired

  forM_
    [ (StatusRevoked, "revoke" :: Text)
    , (StatusErasurePending, "erase-pending")
    , (StatusReauthorizationRequired, "erased")
    ]
    $ \(terminalStatus, operation) ->
      it
        ( "test_terminal_and_fail_closed_states_never_materialize["
            <> T.unpack (connectionStatusText terminalStatus)
            <> "-"
            <> T.unpack operation
            <> "]"
        )
        $ withRig
        $ \rig -> do
          enrollHost rig.custody "h1" "enroll-h1"
          _ <- authorizeMain rig
          _ <- revoke rig.custody "connection-main" "revoke-main"
          when (terminalStatus /= StatusRevoked) $ do
            writeIORef rig.keys.failErasure (terminalStatus == StatusErasurePending)
            outcome <- try (erase rig.custody "connection-main" "erase-main")
            case outcome of
              Left failure | failure `isInstanceOf` KeyOperationError -> pure ()
              Left failure -> throwIO failure
              Right _ -> pure ()
          ((.status) <$> lookupConnection rig.custody "connection-main") `shouldReturn` terminalStatus
          raisesMatching
            (materialize rig.custody "connection-main" "h1" LeaseRead 10 ("blocked-" <> operation))
            ReauthorizationRequired
            "connection-main"

-- | @replace(fence, attachment_id="attachment-forged")@.
forged :: AttachmentFence -> AttachmentFence
forged AttachmentFence {..} = AttachmentFence {attachmentId = "attachment-forged", ..}

-- | @stat.S_IMODE(path.stat().st_mode)@.
modeOf :: FilePath -> IO FileMode
modeOf path = (.&. 0o7777) . fileMode <$> getFileStatus path

regularFiles :: FilePath -> IO [FilePath]
regularFiles directory = do
  entries <- map (directory </>) <$> listDirectory directory
  fmap concat . forM entries $ \entry -> do
    isDirectory <- doesDirectoryExist entry
    isFile <- doesFileExist entry
    if isDirectory then regularFiles entry else pure [entry | isFile]

refusesMatching :: (Show a) => Either AgenticusError a -> ErrorClass -> Text -> Expectation
refusesMatching outcome cls fragment = case outcome of
  Left failure -> do
    unless (failure `isInstanceOf` cls) $ expectationFailure ("expected " <> show cls <> ", got " <> show failure)
    unless (fragment `T.isInfixOf` failure.errorMessage) $
      expectationFailure ("message " <> show failure.errorMessage <> " does not match " <> show fragment)
  Right value -> expectationFailure ("expected " <> show cls <> ", got " <> show value)

fromAgenticus :: SomeException -> Maybe AgenticusError
fromAgenticus = fromException

-- | @threading.Barrier(parties)@ whose @wait(timeout=5)@ breaks on timeout.
newtype Barrier = Barrier (TVar Int)

newBarrier :: Int -> IO Barrier
newBarrier parties = Barrier <$> newTVarIO parties

barrierWait :: Barrier -> IO ()
barrierWait (Barrier remaining) = do
  atomically (modifyTVar' remaining (subtract 1))
  released <- timeout 5000000 (atomically (readTVar remaining >>= \left -> check (left <= 0)))
  when (released == Nothing) $ throwAgenticus (OtherError "BrokenBarrierError") ""

-- | @BarrierStorage@: align exactly one CAS attempt across two independent
-- custody owners.
barrierStorage :: ConnectionStorage -> Barrier -> Integer -> IO ConnectionStorage
barrierStorage inner barrier revision = do
  waited <- newIORef False
  pure
    ConnectionStorage
      { load = inner.load
      , compareAndSwap = \expected replacement -> do
          already <- readIORef waited
          when (expected == revision && not already) $ do
            writeIORef waited True
            barrierWait barrier
          inner.compareAndSwap expected replacement
      , close = inner.close
      }

head', last' :: [a] -> a
head' = \case
  x : _ -> x
  [] -> error "empty"
last' = head' . reverse

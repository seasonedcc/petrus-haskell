{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Complement deterministic Worlds with bounded real-boundary
-- qualification: a port of the reference's @tests/dst/boundaries.py@.
--
-- Each profile names one exact owner test of this repository — the
-- Haskell twin of the reference's pytest node — by its Cabal test suite
-- and hspec path. The route runs the selected owners in one bounded child
-- per suite under one wall clock, refuses pending or empty selections (the
-- reference's @--forbid-skips@), and retains a claim-limited report.
module Petrus.Testing.Dst.Boundaries
  ( -- * Contract
    reportFormat
  , reportVersion
  , reportBytes
  , profileTimeoutSeconds
  , terminationGraceSeconds
  , outputTailBytes
  , lockPath
  , BoundaryProfile (..)
  , boundaryProfiles
  , unmodeledBoundaries

    -- * Running
  , BoundaryRunner (..)
  , processBoundaryRunner
  , runBoundaryQualification
  , runBoundaryQualificationWith
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, evaluate)
import Control.Monad (forM, unless, when)
import Data.ByteString qualified as BS
import Data.List (nub, sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Petrus.Json (Json (..))
import Petrus.Posix.Flock (LockKind (..), openLockFileWith, tryLock)
import Petrus.Testing.Dst.Campaign (repositoryIdentity)
import Petrus.Testing.Dst.Campaign.Support
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.IO (closeFd)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Process
import System.Timeout (timeout)

reportFormat :: Text
reportFormat = "petrus-dst-production-boundary-report"

reportVersion :: Integer
reportVersion = 1

reportBytes :: Int
reportBytes = 262144

profileTimeoutSeconds, terminationGraceSeconds, outputTailBytes :: Int
profileTimeoutSeconds = 120
terminationGraceSeconds = 5
outputTailBytes = 8192

-- | The reference's lock file, so a Haskell and a Python qualification
-- never own the shared test resources at once. Both take it with
-- @flock(2)@ (the reference's @fcntl.flock@), the only lock that excludes
-- the other language's holder.
lockPath :: FilePath
lockPath = "/tmp/petrus-dst-production-boundaries.lock"

-- | @BoundaryProfile@: the reference's claim text, with the owner test
-- named by its package, Cabal test suite, and hspec path.
data BoundaryProfile = BoundaryProfile
  { name :: Text
  , package :: FilePath
  , suite :: String
  , match :: Text
  , evidence :: Text
  , cut :: Text
  , recovery :: Text
  , claim :: Text
  }

-- | The report's @node@: the owner's suite and hspec selection.
node :: BoundaryProfile -> Text
node p = T.pack p.package <> ":test:" <> T.pack p.suite <> " --match " <> pyRepr p.match

boundaryProfiles :: [BoundaryProfile]
boundaryProfiles =
  [ BoundaryProfile
      { name = "simulated-dispatch-crash-load"
      , package = "petrus-dst"
      , suite = "petrus-dst-test"
      , match = "Engine-backed worlds (real Haskell Engine profiles)/authoring (is_exact_and_replayable)/engine_world.build_dispatch_refusal_artifact"
      , evidence = "deterministic-world"
      , cut = "scripted Dispatch refusal after durable ActivityRequested, then abrupt generation drop"
      , recovery = "fresh public Engine load republishes the stable invocation and converges"
      , claim = "one exact bounded World schedule replays through the same interpreter and independent checker"
      }
  , BoundaryProfile
      { name = "postgres-open-transaction-drop"
      , package = "petrus-engine-absurd"
      , suite = "petrus-engine-absurd-test"
      , match = "TestAuthorityKill/a crash before the begin transaction commits leaves nothing anywhere"
      , evidence = "real-postgresql-absurd-transaction"
      , cut = "close the real authority connection with joined History and Absurd work staged but uncommitted"
      , recovery = "PostgreSQL aborts both sides; fresh authority begins and completes from the prior committed fact"
      , claim = "the joined transaction is commit-or-vanish under the real PostgreSQL and pinned Absurd adapters"
      }
  , BoundaryProfile
      { name = "postgres-absurd-postcommit-reload"
      , package = "petrus-engine-absurd"
      , suite = "petrus-engine-absurd-test"
      , match = "TestAuthorityKill/killed after the dispatch commit, the authority resumes without a double spawn"
      , evidence = "real-postgresql-absurd-reconstruction"
      , cut = "abandon authority session objects after the joined begin and task commit"
      , recovery = "fresh provider load reconstructs one occurrence and leaves the one live task alone"
      , claim = "post-commit authority reconstruction preserves one invocation, task, effect, and terminal"
      }
  , BoundaryProfile
      { name = "absurd-worker-sigkill-redelivery"
      , package = "petrus-engine-absurd"
      , suite = "petrus-engine-absurd-test"
      , match = "TestWorkerKill/SIGKILL mid-activity redispatches on lease expiry with exactly one effect"
      , evidence = "real-worker-process-sigkill"
      , cut = "SIGKILL the Worker after its real external-effect commit and before terminal reporting"
      , recovery = "a replacement Worker reclaims after lease expiry and completes the same durable task"
      , claim = "two executions preserve one idempotent external effect and one canonical Activity terminal"
      }
  , BoundaryProfile
      { name = "zeromq-uncertain-terminal-restart"
      , package = "petrus-motus-zeromq"
      , suite = "petrus-motus-zeromq-test"
      , match = "uncertain completion redelivers exactly across dispatch process death/"
      , evidence = "real-zeromq-dispatch-process-kill"
      , cut = "kill the dispatch server after durable completion but before the Worker receives acknowledgement"
      , recovery = "replacement server accepts exact terminal redelivery and LocalDispatch collects it once"
      , claim = "uncertain terminal delivery survives real ZeroMQ server process death without changed content"
      }
  , BoundaryProfile
      { name = "zeromq-lease-restart"
      , package = "petrus-motus-zeromq"
      , suite = "petrus-motus-zeromq-test"
      , match = "dispatch service process death preserves lease details and restart recovery/"
      , evidence = "real-zeromq-dispatch-process-kill"
      , cut = "kill the dispatch server while one attempt owns a live lease and checkpoint details"
      , recovery = "restart preserves heartbeat details, then lease expiry authorizes epoch-2 reclaim and completion"
      , claim = "real IPC process restart preserves lease fencing, details, and one collected terminal"
      }
  ]

unmodeledBoundaries :: [Text]
unmodeledBoundaries =
  [ "authority-process OS SIGKILL while its joined PostgreSQL transaction is open"
  , "PostgreSQL server power loss, replication, failover, and storage corruption"
  , "network partition or loss outside the exercised local ZeroMQ IPC cuts"
  , "live provider, credential, human-decision, and application-specific external authority"
  ]

-- | The reference's monkeypatchable seams: @_execute_profiles@ and
-- @repository_identity@.
data BoundaryRunner = BoundaryRunner
  { execute :: [BoundaryProfile] -> IO Json
  , repository :: IO Json
  }

processBoundaryRunner :: IO BoundaryRunner
processBoundaryRunner = do
  root <- repositoryRoot
  pure BoundaryRunner {execute = executeProfiles root, repository = repositoryIdentity root}

-- | @run_boundary_qualification(profile_names=..., report_path=...)@.
runBoundaryQualification :: [Text] -> FilePath -> IO Int
runBoundaryQualification names reportPath = do
  runner <- processBoundaryRunner
  runBoundaryQualificationWith runner reportBytes names reportPath

-- | 'runBoundaryQualification' over an explicit runner and report limit.
runBoundaryQualificationWith :: BoundaryRunner -> Int -> [Text] -> FilePath -> IO Int
runBoundaryQualificationWith runner limit names reportPath = do
  when (null names) $ refuse "production-boundary qualification must select at least one profile"
  when (length names /= length (nub names)) $
    refuse "production-boundary qualification cannot select a profile more than once"
  profiles <- forM names $ \n -> case [p | p <- boundaryProfiles, p.name == n] of
    p : _ -> pure p
    [] -> refuse ("unknown production-boundary profile " <> pyRepr n)
  started <- getCurrentTime
  execution <- runner.execute profiles
  elapsed <- millisSince started
  repository <- runner.repository
  let outcome = member "outcome" execution
      passed = outcome == String "pass"
      report =
        Object
          [
            ( "bounds"
            , Object
                [ ("concurrency", Int 1)
                , ("output_tail_bytes_on_failure", Int (toInteger outputTailBytes))
                , ("profiles", Int (toInteger (length profiles)))
                , ("report_bytes", Int (toInteger limit))
                , ("termination_grace_seconds", Int (toInteger terminationGraceSeconds))
                , ("wall_clock_seconds", Int (toInteger profileTimeoutSeconds))
                ]
            )
          , ("comparisons", Array [dispatchRecoveryComparison names])
          , ("deselected_profiles", Array [String p.name | p <- boundaryProfiles, p.name `notElem` names])
          , ("elapsed_ms", Int elapsed)
          , ("execution", execution)
          , ("format", String reportFormat)
          , ("outcome", outcome)
          ,
            ( "profiles"
            , Array
                [ Object
                    [ ("claim", String p.claim)
                    , ("cut", String p.cut)
                    , ("evidence", String p.evidence)
                    , ("name", String p.name)
                    , ("node", String (node p))
                    , ("outcome", String (if passed then "pass" else "not-qualified"))
                    , ("recovery", String p.recovery)
                    ]
                | p <- profiles
                ]
            )
          , ("repository", repository)
          , ("runtime", Object [(k, String v) | (k, v) <- runtimeIdentity])
          , ("unmodeled_boundaries", Array (map String unmodeledBoundaries))
          , ("version", Int reportVersion)
          ]
  pretty <- orRefuse (prettyDumps report)
  let encoded = pretty <> "\n"
  when (BS.length encoded > limit) $
    refuse ("production-boundary report has " <> tshow (BS.length encoded) <> " bytes; limit is " <> tshow limit)
  createDirectoryIfMissing True (takeDirectory reportPath)
  BS.writeFile reportPath encoded
  pure (if passed then 0 else 1)

millisSince :: UTCTime -> IO Integer
millisSince started = do
  now <- getCurrentTime
  pure (round (realToFrac (diffUTCTime now started) * 1000 :: Double))

-- | @_dispatch_recovery_comparison(selected)@.
dispatchRecoveryComparison :: [Text] -> Json
dispatchRecoveryComparison selected =
  Object
    [ ("real_profile", String real)
    , ("shared_contract", String "an accepted ActivityRequested survives authority-generation loss and recovery reuses one stable invocation identity")
    , ("simulated_profile", String simulated)
    , ("status", String (if simulated `elem` selected && real `elem` selected then "complete" else "partial"))
    , ("stronger_real_evidence", String "the real route reconstructs through PostgreSQL and pinned Absurd and proves one durable provider task")
    ,
      ( "non_equivalence"
      , String
          "World uses deterministic abrupt generation drop plus scripted Dispatch refusal; the real route abandons in-process authority objects after commit and does not OS-kill the authority"
      )
    ]
  where
    simulated = "simulated-dispatch-crash-load"
    real = "postgres-absurd-postcommit-reload"

-- ---------------------------------------------------------------------------
-- Execution

-- | One owner child: a built test suite and the hspec selections it runs.
data OwnerRun = OwnerRun {package :: FilePath, suite :: String, matches :: [Text]}

ownerRuns :: [BoundaryProfile] -> [OwnerRun]
ownerRuns profiles =
  [ OwnerRun {package = pkg, suite = s, matches = [p.match | p <- profiles, p.suite == s]}
  | (pkg, s) <- nub [(p.package, p.suite) | p <- profiles]
  ]

-- | The newest built binary of a test suite under @dist-newstyle@.
ownerBinary :: FilePath -> OwnerRun -> IO FilePath
ownerBinary root run = do
  let build = root </> "dist-newstyle" </> "build"
  candidates <- findSuites build (6 :: Int)
  stamped <- forM candidates $ \c -> (,c) <$> getModificationTime c
  case sortOn (Down . fst) stamped of
    (_, best) : _ -> pure best
    [] ->
      refuse
        ( "production-boundary owner suite "
            <> T.pack run.suite
            <> " is not built; run cabal build "
            <> T.pack run.package
            <> ":test:"
            <> T.pack run.suite
        )
  where
    target = "t" </> run.suite </> "build" </> run.suite </> run.suite
    findSuites dir depth = do
      present <- doesDirectoryExist dir
      if not present || depth < 0
        then pure []
        else do
          let candidate = dir </> target
          found <- doesFileExist candidate
          here <- if found then pure [candidate] else pure []
          children <- listDirectory dir
          below <-
            if found
              then pure []
              else concat <$> mapM (\c -> findSuites (dir </> c) (depth - 1)) [c | c <- children, c /= "t", c /= "cache", c /= "setup-config"]
          pure (here <> below)

-- | @_execute_profiles(profiles)@: run the owner tests in bounded children
-- under one exclusive lock and one wall clock.
executeProfiles :: FilePath -> [BoundaryProfile] -> IO Json
executeProfiles root profiles = do
  createDirectoryIfMissing True (takeDirectory lockPath)
  bracket (openLockFileWith lockPath 0o644) closeFd $ \lock -> do
    owned <- tryLock lock Exclusive
    unless owned $ refuse "another production-boundary qualification owns its test resources"
    started <- getCurrentTime
    let deadline = fromIntegral profileTimeoutSeconds
        loop = \case
          [] -> pure (Right (0 :: Int))
          run : rest -> do
            binary <- ownerBinary root run
            spent <- realToFrac . (`diffUTCTime` started) <$> getCurrentTime
            let remaining = max 0 (deadline - spent :: Double)
            result <- runOwner binary (root </> "packages" </> run.package) run.matches remaining
            case result of
              Right 0 -> loop rest
              other -> pure other
    result <- loop (ownerRuns profiles)
    elapsed <- millisSince started
    pure $ case result of
      Right code ->
        Object
          [ ("elapsed_ms", Int elapsed)
          , ("outcome", String (if code == 0 then "pass" else "pytest-failure"))
          , ("returncode", Int (toInteger code))
          , ("termination", String "exited")
          ]
      Left (code, termination) ->
        Object
          [ ("elapsed_ms", Int elapsed)
          , ("outcome", String "timeout")
          , ("returncode", Int (toInteger code))
          , ("termination", String termination)
          ]

-- | Run one owner child in its own process group; on the wall clock, TERM
-- the group, then KILL it after the grace period.
runOwner :: FilePath -> FilePath -> [Text] -> Double -> IO (Either (Int, Text) Int)
runOwner binary directory matches remaining = do
  let arguments = concat [["--match", T.unpack m] | m <- matches] <> ["--fail-on=empty,pending", "+RTS", "-M2G", "-RTS"]
  bracket
    ( createProcess
        (proc binary arguments)
          { cwd = Just directory
          , std_in = NoStream
          , std_out = CreatePipe
          , std_err = CreatePipe
          , create_group = True
          }
    )
    (\(_, _, _, handle) -> terminateProcess handle)
    $ \(_, out, err, handle) -> do
      outVar <- drain out
      errVar <- drain err
      finished <- timeout (round (remaining * 1000000)) (waitForProcess handle)
      case finished of
        Just code -> do
          let n = exitInt code
          stdoutText <- takeMVar outVar
          stderrText <- takeMVar errVar
          when (n /= 0) $ showFailure stdoutText stderrText
          pure (Right n)
        Nothing -> do
          group <- getPid handle
          forM_' group (signalProcessGroup sigTERM)
          graceful <- timeout (terminationGraceSeconds * 1000000) (waitForProcess handle)
          (code, termination) <- case graceful of
            Just c -> pure (exitInt c, "terminated")
            Nothing -> do
              forM_' group (signalProcessGroup sigKILL)
              c <- waitForProcess handle
              pure (exitInt c, "killed")
          stdoutText <- takeMVar outVar
          stderrText <- takeMVar errVar
          showFailure stdoutText stderrText
          pure (Left (code, termination))
  where
    forM_' = flip mapM_
    exitInt = \case
      ExitSuccess -> 0
      ExitFailure n -> n
    drain handle = do
      var <- newEmptyMVar
      _ <- forkIO $ case handle of
        Just h -> BS.hGetContents h >>= evaluate >>= putMVar var . TE.decodeUtf8Lenient
        Nothing -> putMVar var ""
      pure var

-- | @_show_failure(stdout, stderr)@.
showFailure :: Text -> Text -> IO ()
showFailure out err = do
  hPutStrLn stderr "DST production-boundary qualification failed"
  mapM_ (\o -> unless (T.null o) (hPutStrLn stderr (T.unpack (T.takeEnd outputTailBytes o)))) [out, err]

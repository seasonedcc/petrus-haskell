-- | @tests/integration/host/test_pi_workspace.py@: the private Git
-- workspace provider against real Git repositories.
module PiWorkspaceSpec (spec, ustar, TarEntry (..)) where

import Control.Exception (Exception, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hamsterdan.Agents.Pi (PiWorkspaceError (..), PiWorkspaceProvider (..), PreparedPiWorkspace (..), PromptKind (..))
import Hamsterdan.Agents.Protocol
import Hamsterdan.Host.PiWorkspace
import Hamsterdan.Python.Exception (PythonException (..), pythonExceptionStr)
import Hamsterdan.Python.Hashlib (sha256Hex)
import Numeric (showOct)
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Runtime.PiA2Host (PiA2RuntimePolicy (..))
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import System.Directory (createDirectory, listDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcess)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "pi-workspace"

-- | The reference's @git(root, *arguments)@ test helper.
git :: FilePath -> [String] -> IO Text
git root arguments = T.strip . T.pack <$> readProcess "git" ("-C" : root : arguments) ""

-- | The @repository@ fixture.
repository :: FilePath -> IO (FilePath, Text)
repository tmp = do
  let root = tmp </> "repository"
  createDirectory root
  _ <- git root ["init", "-q"]
  _ <- git root ["config", "user.name", "Test"]
  _ <- git root ["config", "user.email", "test@example.invalid"]
  TIO.writeFile (root </> "keep.txt") "before\n"
  TIO.writeFile (root </> "delete.txt") "delete\n"
  TIO.writeFile (root </> ".gitignore") "ignored.log\n"
  TIO.writeFile (root </> "tool") "#!/bin/sh\n"
  setFileMode (root </> "tool") 0o755
  _ <- git root ["add", "."]
  _ <- git root ["commit", "-qm", "base"]
  headSha <- git root ["rev-parse", "HEAD"]
  pure (root, headSha)

request :: Text -> AgentRequest
request headSha =
  AgentCoding
    CodingRequest
      { kind = "change"
      , repository = "owner/repo"
      , pullRequest = 7
      , epoch = 2
      , head = headSha
      , base = headSha
      , ref = "hamsterdan/change/test"
      , selectedWork = []
      , failureEvidence = []
      , fingerprint = ""
      , lineage = []
      , reproductionStatus = "unknown"
      , mergeBase = False
      }

review :: Text -> Text -> AgentRequest
review headSha baseSha =
  AgentReview
    ReviewRequest
      { repository = "owner/repo"
      , pullRequest = 7
      , epoch = 2
      , head = headSha
      , base = baseSha
      , diffPath = "diff.patch"
      , policy = []
      , reviewLenses = []
      , contextPaths = []
      , actionsEvidence = []
      , priorFindings = []
      , priorComments = []
      , priorReplies = []
      , appliedChanges = []
      }

openWith :: GitPiWorkspaceProvider -> PromptKind -> FilePath -> AgentRequest -> Text -> (PreparedPiWorkspace -> IO a) -> IO a
openWith receiver kind source = let PiWorkspaceProvider open = gitPiWorkspaceProvider receiver in open kind (T.pack source)

emptyRoot :: GitPiWorkspaceProvider -> Expectation
emptyRoot receiver = listDirectory (providerRoot receiver) `shouldReturn` []

isWorkspaceError :: PiWorkspaceError -> Bool
isWorkspaceError = const True

messageContains :: Text -> PiWorkspaceError -> Bool
messageContains needle = \case
  PiWorkspaceError message -> needle `T.isInfixOf` message
  PiWorkspaceCleanupError _ -> needle `T.isInfixOf` "Pi workspace cleanup is unverified"

newtype BodyFailure = BodyFailure Int
  deriving stock (Eq, Show)

instance Exception BodyFailure

-- | One member for the reference's @_tar(...)@ helper.
data TarEntry = TarEntry
  { name :: ByteString
  , typeflag :: Char
  , mode :: Int
  , linkname :: ByteString
  , content :: ByteString
  }

-- | @_tar(*entries)@: @tarfile.PAX_FORMAT@ writes a plain ustar header for
-- short ASCII names, with uid/gid 0, empty owner names and mtime 0.
ustar :: [TarEntry] -> ByteString
ustar entries =
  let body = BS.concat (map member entries) <> BS.replicate 1024 0
      record = 10240
      padded = body <> BS.replicate ((record - BS.length body `mod` record) `mod` record) 0
   in padded
  where
    field width value = BS.take width value <> BS.replicate (width - min width (BS.length value)) 0
    octal width value = field width (BC.pack (pad (width - 1) (showOct value "")))
    pad width digits = replicate (width - length digits) '0' <> digits
    member entry =
      let size = if entry.typeflag `elem` ['0', '\0'] then BS.length entry.content else 0
          header checksum =
            BS.concat
              [ field 100 entry.name
              , octal 8 entry.mode
              , octal 8 (0 :: Int)
              , octal 8 (0 :: Int)
              , octal 12 size
              , octal 12 (0 :: Int)
              , checksum
              , BC.singleton entry.typeflag
              , field 100 entry.linkname
              , "ustar\NUL00"
              , field 32 ""
              , field 32 ""
              , octal 8 (0 :: Int)
              , octal 8 (0 :: Int)
              , field 155 ""
              , BS.replicate 12 0
              ]
          unsigned = sum (map fromIntegral (BS.unpack (header "        "))) :: Int
          final = header (BC.pack (pad 6 (showOct unsigned "")) <> "\NUL ")
          payload = BS.take size entry.content
          dataPad = BS.replicate ((512 - size `mod` 512) `mod` 512) 0
       in final <> payload <> dataPad

regular :: ByteString -> Int -> ByteString -> TarEntry
regular name mode content = TarEntry {name, typeflag = '0', mode, linkname = "", content}

spec :: Spec
spec = describe "tests/integration/host/test_pi_workspace.py" $ do
  it "test_unchanged_workspace_is_exact_and_private_stages_are_removed" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    openWith receiver CodingKind source (request headSha) "pi:unchanged" $ \prepared -> do
      prepared.digest `shouldBe` sha256Hex prepared.archive
      prepared.correlation `shouldSatisfy` T.isPrefixOf "hamsterdan-pr-v1:"
      prepared.policy.writableRoots `shouldBe` Set.fromList ["."]
      prepared.policy.maxToolCalls `shouldBe` 32
      prepared.policy.capabilities `shouldNotSatisfy` Set.member WorkspaceShell
      prepared.reconcile prepared.archive `shouldReturn` ("", [])
    emptyRoot receiver

  it "test_non_coding_workspace_policy_has_no_mutation_authority" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    openWith receiver ReviewKind source (request headSha) "pi:review" $ \prepared -> do
      prepared.policy.writablePaths `shouldBe` Set.empty
      prepared.policy.writableRoots `shouldBe` Set.empty
      prepared.policy.capabilities `shouldBe` Set.fromList [WorkspaceRead, WorkspaceSearch]
      prepared.policy.maxToolCalls `shouldBe` 16
    emptyRoot receiver

  it "test_review_workspace_supplies_the_requested_diff_and_exact_numbered_head" . withTmp $ \tmp -> do
    (source, baseSha) <- repository tmp
    TIO.writeFile (source </> "keep.txt") "first\n\nthird\n"
    _ <- git source ["add", "keep.txt"]
    _ <- git source ["commit", "-qm", "change"]
    headSha <- git source ["rev-parse", "HEAD"]
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    openWith receiver ReviewKind source (review headSha baseSha) "pi:review-input" $ \prepared -> do
      let files = tmp </> "files"
      extractWorkspaceArchive prepared.archive files
      expected <- git source ["diff", T.unpack (baseSha <> "..." <> headSha)]
      (T.strip <$> TIO.readFile (files </> "diff.patch")) `shouldReturn` expected
      TIO.readFile (files </> "diff.patch.lines") `shouldReturn` "keep.txt\n1: first\n2: \n3: third\n"
      prepared.policy.capabilities `shouldNotSatisfy` Set.member WorkspaceWrite
    emptyRoot receiver

  it "test_changed_workspace_derives_reproducible_add_modify_delete_and_executable_patch" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    let result = tmp </> "settled"
    (patch, changed) <- openWith receiver CodingKind source (request headSha) "pi:changed" $ \prepared -> do
      extractWorkspaceArchive prepared.archive result
      TIO.writeFile (result </> "keep.txt") "after\n"
      removeFile (result </> "delete.txt")
      TIO.writeFile (result </> "added.sh") "#!/bin/sh\nexit 0\n"
      setFileMode (result </> "added.sh") 0o755
      prepared.reconcile =<< workspaceArchive result
    changed `shouldBe` ["added.sh", "delete.txt", "keep.txt"]
    patch `shouldSatisfy` T.isInfixOf "new file mode 100755"
    patch `shouldSatisfy` T.isInfixOf "deleted file mode 100644"
    patch `shouldSatisfy` (\value -> "-before" `T.isInfixOf` value && "+after" `T.isInfixOf` value)
    emptyRoot receiver

  -- Not upstream tests: the reference's `_run_git` runs Git with
  -- `text=True`, so non-UTF-8 output raises CPython's `UnicodeDecodeError`.
  -- During preparation `open`'s `except Exception` sanitizes it like any
  -- other staging failure.
  it "a non-UTF-8 review diff is a sanitized preparation failure" . withTmp $ \tmp -> do
    (source, baseSha) <- repository tmp
    BS.writeFile (source </> "latin1.txt") "caf\xe9\n"
    _ <- git source ["add", "latin1.txt"]
    _ <- git source ["commit", "-qm", "latin-1"]
    headSha <- git source ["rev-parse", "HEAD"]
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    openWith receiver ReviewKind source (review headSha baseSha) "pi:latin-1" (\_ -> expectationFailure "an undecodable diff must not enter the agent")
      `shouldThrow` (== PiWorkspaceError "private Pi workspace preparation failed")
    emptyRoot receiver

  -- `reconcile` runs outside that `try`: a settled Latin-1 file makes the
  -- canonical patch (`git diff --cached --binary`, a text diff for a file
  -- without NUL bytes) raise `UnicodeDecodeError` to the host, which
  -- records that class name. The message names the byte and its offset in
  -- Git's output, after a new file's diff header (seven-digit abbreviated
  -- blob name) and the added line's `+caf`.
  it "a non-UTF-8 canonical patch raises CPython's UnicodeDecodeError" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    let result = tmp </> "settled"
        header = "diff --git a/latin1.txt b/latin1.txt\nnew file mode 100644\nindex 0000000..1234567\n--- /dev/null\n+++ b/latin1.txt\n@@ -0,0 +1 @@\n+caf" :: ByteString
        expected = "'utf-8' codec can't decode byte 0xe9 in position " <> T.pack (show (BS.length header)) <> ": invalid continuation byte"
    openWith receiver CodingKind source (request headSha) "pi:latin-1" (\prepared -> do
      extractWorkspaceArchive prepared.archive result
      BS.writeFile (result </> "latin1.txt") "caf\xe9\n"
      _ <- prepared.reconcile =<< workspaceArchive result
      expectationFailure "an undecodable patch must not be returned")
      `shouldThrow` (\e -> e.name == "UnicodeDecodeError" && pythonExceptionStr e == expected)
    emptyRoot receiver

  describe "test_review_inputs_never_overwrite_a_tracked_file" $
    forM_ ["diff.patch", "diff.patch.lines"] $ \path -> it path . withTmp $ \tmp -> do
      (source, baseSha) <- repository tmp
      TIO.writeFile (source </> path) "repository-owned\n"
      _ <- git source ["add", path]
      _ <- git source ["commit", "-qm", "tracked input name"]
      headSha <- git source ["rev-parse", "HEAD"]
      receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
      openWith receiver ReviewKind source (review headSha baseSha) "pi:collision" (\_ -> expectationFailure "colliding review input must not enter the agent")
        `shouldThrow` messageContains "collide"
      TIO.readFile (source </> path) `shouldReturn` "repository-owned\n"
      emptyRoot receiver

  it "test_ignored_result_file_is_part_of_the_canonical_patch" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    let result = tmp </> "settled"
    (patch, changed) <- openWith receiver CodingKind source (request headSha) "pi:ignored" $ \prepared -> do
      extractWorkspaceArchive prepared.archive result
      TIO.writeFile (result </> "ignored.log") "must not disappear\n"
      prepared.reconcile =<< workspaceArchive result
    changed `shouldBe` ["ignored.log"]
    patch `shouldSatisfy` T.isInfixOf "must not disappear"
    emptyRoot receiver

  describe "test_archive_rejects_unsafe_paths_links_special_files_and_modes" $
    forM_
      [ ("../escape", '0', 0o644, "")
      , ("/absolute", '0', 0o644, "")
      , (".git/config", '0', 0o644, "")
      , (".petrus-hands-stage/value", '0', 0o644, "")
      , ("link", '2', 0o777, "keep.txt")
      , ("hard", '1', 0o644, "keep.txt")
      , ("device", '6', 0o644, "")
      , ("mode", '0', 0o600, "")
      ]
      $ \(name, kind, mode, link) -> it (BC.unpack name) $ do
        let content = if kind == '0' then "value" else ""
            archive = ustar [TarEntry {name, typeflag = kind, mode, linkname = link, content}]
        either isWorkspaceError (const False) (validatedEntries maxBytes archive) `shouldBe` True

  it "test_archive_rejects_duplicate_malformed_missing_and_oversized" $ do
    let duplicate = ustar [regular "duplicate" 0o644 "a", regular "duplicate" 0o644 "b"]
    either (messageContains "duplicated") (const False) (validatedEntries maxBytes duplicate) `shouldBe` True
    forM_ ["", "not-a-tar"] $ \malformed ->
      either isWorkspaceError (const False) (validatedEntries maxBytes malformed) `shouldBe` True
    either (messageContains "oversized") (const False) (validatedEntries 10 (BC.replicate 11 'x')) `shouldBe` True

  it "test_stale_head_fails_before_runtime_and_cleans_stage" . withTmp $ \tmp -> do
    (source, _) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    openWith receiver CodingKind source (request (T.replicate 40 "f")) "pi:stale" (\_ -> expectationFailure "stale workspace must not be admitted")
      `shouldThrow` isWorkspaceError
    emptyRoot receiver

  it "test_input_size_is_rejected_before_reading_beyond_bound" . withTmp $ \tmp -> do
    (source, _) <- repository tmp
    BS.writeFile (source </> "large.bin") (BC.replicate 32 'x')
    _ <- git source ["add", "large.bin"]
    _ <- git source ["commit", "-qm", "large"]
    headSha <- git source ["rev-parse", "HEAD"]
    receiver <- newGitPiWorkspaceProviderWith defaultWorkspaceOptions {maxWorkspaceBytes = 50} (tmp </> "receiver")
    openWith receiver CodingKind source (request headSha) "pi:oversized-input" (\_ -> expectationFailure "oversized input must not be admitted")
      `shouldThrow` messageContains "expanded bound"
    emptyRoot receiver

  it "test_body_failure_propagates_without_reclassification_and_cleans_stage" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    receiver <- newGitPiWorkspaceProvider (tmp </> "receiver")
    caught <- try (openWith receiver CodingKind source (request headSha) "pi:body-failure" (\_ -> throwIO (BodyFailure 17)))
    caught `shouldBe` (Left (BodyFailure 17) :: Either BodyFailure ())
    emptyRoot receiver

  it "test_cleanup_uncertainty_is_fail_closed" . withTmp $ \tmp -> do
    (source, headSha) <- repository tmp
    let failing _ = throwIO (userError "synthetic")
    receiver <- newGitPiWorkspaceProviderWith defaultWorkspaceOptions {removeTree = failing} (tmp </> "receiver")
    openWith receiver CodingKind source (request headSha) "pi:cleanup" (\_ -> pure ())
      `shouldThrow` messageContains "cleanup is unverified"
  where
    maxBytes = 64 * 1024 * 1024

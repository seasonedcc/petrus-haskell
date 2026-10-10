-- | Secret-safe host ownership of commits proposed by disposable agents
-- (@host/git_publish.py@).
--
-- The publisher applies a host-captured binary patch to a fresh,
-- credential-free clone, validates the staged tree, recreates it through
-- GitHub's object API, and advances the one same-repository PR ref with an
-- exact compare-and-swap. Every operation is identified by
-- @Hamsterdan-Operation@ / @Hamsterdan-Payload-Digest@ trailers, so a
-- replay reconciles against the PR's first-parent history.
module Hamsterdan.Host.GitPublish
  ( -- * Failures
    PublicationCategory (..)
  , categoryName
  , GitPublishError (..)

    -- * Results
  , GitPublishResult (..)
  , GitReconciliation (..)

    -- * The authority port
  , PublicationAuthority (..)
  , publicationAuthority

    -- * The publisher
  , HostGitPublisher (..)
  , hostGitPublisher
  , hostGitPublisherWith
  , publish
  , reconcile
  , reconcileSelfCaused
  , validateStagedTree
  , createCommit
  , advanceRef
  , runGit
  , withPublicationDirectory

    -- * Validation
  , sameRepository
  , safeBranch
  , safePath
  , validateDeclaredPaths
  , validateCommitMessage
  , hasConflictMarkers
  , payloadDigest
  , pySplitlines
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception (..), IOException, SomeException, catch, evaluate, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (UnicodeException)
import Hamsterdan.Agents.Protocol (CodingResult (..))
import Hamsterdan.GitHub.Gateway (GitHubAuthority)
import Hamsterdan.GitHub.Gateway qualified as Gateway
import Hamsterdan.GitHub.Models
  ( BoundaryKind (..)
  , GitHubBoundaryError (..)
  , GraphQLTransport (..)
  , PullRequestSnapshot (..)
  )
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.Host.Python (ValueError (..), dumpsSortedText, sha256HexText)
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..))
import Petrus.Json (Json)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files qualified as Posix
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , proc
  , waitForProcess
  , withCreateProcess
  )
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Failures

-- | @PublicationCategory@: the closed, coordinate-free publication stage.
data PublicationCategory
  = Correlation
  | RepositoryRef
  | PatchAdmission
  | GitOperation
  | Idempotency
  | CurrentAuthority
  | ObjectWriteFailure
  | RefCas
  | BoundaryUnavailable
  deriving stock (Eq, Show, Enum, Bounded)

categoryName :: PublicationCategory -> Text
categoryName = \case
  Correlation -> "correlation"
  RepositoryRef -> "repository_ref"
  PatchAdmission -> "patch_admission"
  GitOperation -> "git_operation"
  Idempotency -> "idempotency"
  CurrentAuthority -> "current_authority"
  ObjectWriteFailure -> "object_write"
  RefCas -> "ref_cas"
  BoundaryUnavailable -> "boundary_unavailable"

-- | @GitPublishError(category, reason)@ (a @RuntimeError@).
data GitPublishError = GitPublishError
  { category :: PublicationCategory
  , reason :: Text
  }
  deriving stock (Eq, Show)

instance Exception GitPublishError where
  displayException e = T.unpack e.reason

failWith :: PublicationCategory -> Text -> IO a
failWith c r = throwIO (GitPublishError c r)

-- ---------------------------------------------------------------------------
-- Results

-- | @GitPublishResult(head, recovered)@.
data GitPublishResult = GitPublishResult
  { head :: Text
  , recovered :: Bool
  }
  deriving stock (Eq, Show)

-- | @GitReconciliation(disposition, observed_head, commit, parents)@.
data GitReconciliation = GitReconciliation
  { disposition :: Text
  -- ^ @absent@ or @existing@.
  , observedHead :: Text
  , commit :: Text
  , parents :: [Text]
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- The authority port

-- | The @GitHubAuthority@ surface the publisher binds to.
data PublicationAuthority = PublicationAuthority
  { repository :: Text
  , pullRequest :: IO PullRequestSnapshot
  , createTree :: Text -> [(Text, Text, Maybe ByteString)] -> IO Text
  -- ^ @create_tree(base_tree=, entries=)@
  , createCommit :: Text -> [Text] -> Text -> Text -> Text -> IO Text
  -- ^ @create_commit(tree=, parents=, message=, name=, email=)@
  , compareAndSwapRef :: Maybe (Text -> Text -> Text -> Text -> IO ())
  -- ^ @graphql.compare_and_swap_ref@, absent without GraphQL.
  }

publicationAuthority :: GitHubAuthority -> PublicationAuthority
publicationAuthority authority =
  PublicationAuthority
    { repository = authority.repository
    , pullRequest = Gateway.pullRequest authority
    , createTree = Gateway.createTree authority
    , createCommit = Gateway.createCommit authority
    , compareAndSwapRef = (.compareAndSwapRef) <$> authority.graphql
    }

-- ---------------------------------------------------------------------------
-- The publisher

-- | @HostGitPublisher(authority, clone_url, commit_name=, commit_email=)@.
data HostGitPublisher = HostGitPublisher
  { authority :: PublicationAuthority
  , cloneUrl :: Text
  , commitName :: Text
  , commitEmail :: Text
  }

hostGitPublisher :: PublicationAuthority -> Text -> IO HostGitPublisher
hostGitPublisher authority cloneUrl =
  hostGitPublisherWith authority cloneUrl "Hamsterdan" "hamster-dan[bot]@users.noreply.github.com"

hostGitPublisherWith :: PublicationAuthority -> Text -> Text -> Text -> IO HostGitPublisher
hostGitPublisherWith authority cloneUrl commitName commitEmail = do
  let afterScheme = snd (T.breakOn "://" cloneUrl)
  when (T.null cloneUrl || ("://" `T.isInfixOf` cloneUrl && "@" `T.isInfixOf` T.drop 3 afterScheme)) $
    throwIO (ValueError "a credential-free clone URL is required")
  when (T.null (Py.strip commitName) || T.null (Py.strip commitEmail) || "\n" `T.isInfixOf` (commitName <> commitEmail)) $
    throwIO (ValueError "explicit commit metadata is invalid")
  pure HostGitPublisher {authority, cloneUrl, commitName, commitEmail}

-- | @publish(result, operation=, payload_digest=, expected_head=,
-- base_head=, merge_base=)@.
publish :: HostGitPublisher -> CodingResult -> Text -> Text -> Text -> Text -> Bool -> IO GitPublishResult
publish p result operation digest expectedHead baseHead mergeBase = do
  validateDeclaredPaths result.changedFiles
  validateCommitMessage result.proposedCommitMessage
  when (result.head /= expectedHead || result.base /= baseHead) $
    failWith Correlation "stale or incorrectly correlated Git publication"
  reconciled <- reconcile p operation digest expectedHead baseHead mergeBase
  if reconciled.disposition == "existing"
    then pure (GitPublishResult reconciled.commit True)
    else do
      pull <- p.authority.pullRequest
      unless (publishable p pull) $
        failWith RepositoryRef "fork or unsafe pull-request ref is not publishable"
      when (result.status /= "changed" || T.null (Py.strip result.diff) || hasConflictMarkers result.diff) $
        failWith PatchAdmission "empty, unchanged, or conflicted agent patch is not publishable"
      withPublicationDirectory $ \temporary -> do
        let root = temporary </> "repository"
            rootT = T.pack root
        _ <- runGit ["clone", "--quiet", "--no-checkout", "--", p.cloneUrl, rootT] Nothing
        _ <- runGit ["-C", rootT, "checkout", "--quiet", "--detach", expectedHead] Nothing
        let parents = expectedHead : [baseHead | mergeBase]
        when (pull.head /= expectedHead || pull.base /= baseHead) $
          failWith CurrentAuthority "stale or incorrectly correlated Git publication"
        when mergeBase $ do
          _ <- runGit ["-C", rootT, "cat-file", "-e", baseHead <> "^{commit}"] Nothing
          pure ()
        let patch = temporary </> "change.patch"
        BS.writeFile patch (TE.encodeUtf8 result.diff)
        _ <- runGit ["-C", rootT, "apply", "--binary", "--index", "--", T.pack patch] Nothing
        changed <- validateStagedTree root
        when (changed /= result.changedFiles || null changed) $
          failWith PatchAdmission "agent patch files differ from its declared result"
        tree <- Py.strip <$> runGit ["-C", rootT, "write-tree"] Nothing
        baseTree <- Py.strip <$> runGit ["-C", rootT, "rev-parse", expectedHead <> "^{tree}"] Nothing
        let message =
              result.proposedCommitMessage <> "\n\n" <> "Hamsterdan-Operation: " <> operation
                <> "\nHamsterdan-Payload-Digest: "
                <> digest
                <> "\n"
        commit <- createCommit p root baseTree tree changed parents message
        current <- p.authority.pullRequest
        unless (samePull current pull && current.head == expectedHead && current.base == baseHead) $
          failWith CurrentAuthority "pull request changed before Git publication"
        advanced <- try (advanceRef p pull.headRef expectedHead commit)
        case advanced of
          Left (e :: GitPublishError)
            | e.category /= RefCas -> throwIO e
            | otherwise -> do
                again <- reconcileSelfCaused p operation digest expectedHead baseHead mergeBase commit
                if again.disposition == "existing"
                  then pure (GitPublishResult again.commit True)
                  else throwIO e
          Right () -> do
            verified <- reconcileSelfCaused p operation digest expectedHead baseHead mergeBase commit
            unless (verified.disposition == "existing") $
              failWith RefCas "ref advance succeeded without a provable operation commit"
            pure (GitPublishResult verified.commit False)

publishable :: HostGitPublisher -> PullRequestSnapshot -> Bool
publishable p pull =
  sameRepository pull.repository p.authority.repository
    && sameRepository pull.headRepository p.authority.repository
    && safeBranch pull.headRef

-- | @reconcile(operation=, payload_digest=, expected_head=, base_head=,
-- merge_base=)@.
reconcile :: HostGitPublisher -> Text -> Text -> Text -> Text -> Bool -> IO GitReconciliation
reconcile p operation digest expectedHead baseHead mergeBase =
  reconcileSelfCaused p operation digest expectedHead baseHead mergeBase ""

-- | 'reconcile' with @self_caused_head@: the one commit this publication
-- just created, whose lagging PR projection alone is tolerated.
reconcileSelfCaused :: HostGitPublisher -> Text -> Text -> Text -> Text -> Bool -> Text -> IO GitReconciliation
reconcileSelfCaused p operation digest expectedHead baseHead mergeBase selfCausedHead = do
  pull <-
    p.authority.pullRequest `catch` \(_ :: GitHubBoundaryError) ->
      failWith BoundaryUnavailable "GitHub PR projection is unavailable"
  unless (publishable p pull) $
    failWith RepositoryRef "fork or unsafe pull-request ref is not publishable"
  withPublicationDirectory $ \temporary -> do
    let root = T.pack (temporary </> "repository")
    _ <- runGit ["clone", "--quiet", "--no-checkout", "--", p.cloneUrl, root] Nothing
    let destination = "refs/heads/" <> pull.headRef
    remote <- pySplitlines <$> runGit ["-C", root, "ls-remote", "--heads", "origin", destination] Nothing
    line <- case remote of
      [one] -> pure one
      _ -> failWith BoundaryUnavailable "Git remote ref lookup is incoherent"
    let fields = pyWords line
        firstField = case fields of
          f : _ -> f
          [] -> ""
        lagging = not (T.null selfCausedHead) && firstField == selfCausedHead && pull.head == expectedHead
    -- @fields[0]@ of a blank line raises IndexError in the reference
    -- (evaluated only for a self-caused head).
    when (null fields && not (T.null selfCausedHead)) $
      throwIO (PythonException "IndexError" [PyStr "list index out of range"])
    unless (length fields == 2 && fields !! 1 == destination && (firstField == pull.head || lagging)) $
      failWith BoundaryUnavailable "Git remote ref differs from the current PR projection"
    let observedHead = firstField
    _ <- runGit ["-C", root, "fetch", "--quiet", "origin", observedHead] Nothing
    raw <- runGit ["-C", root, "log", "--first-parent", "-z", "--format=%H%x00%P%x00%B", observedHead] Nothing
    let pieces = T.splitOn "\0" raw
        (history, final) = (init pieces, last pieces)
    when (not (T.null final) || length history `mod` 3 /= 0) $
      failWith GitOperation "Git operation history is malformed"
    let operationLine = "Hamsterdan-Operation: " <> operation
        digestLine = "Hamsterdan-Payload-Digest: " <> digest
    matches <-
      fmap concat . forM (triples history) $ \(commit, rawParents, body) -> do
        let trailers = pySplitlines body
            count x = length (filter (== x) trailers)
        if operationLine `notElem` trailers
          then pure []
          else do
            when (count operationLine /= 1 || count digestLine /= 1) $
              failWith Idempotency "stable operation was reused with a different payload"
            pure [(commit, pyWords rawParents)]
    case matches of
      _ : _ : _ -> failWith Idempotency "stable operation identifies multiple commits"
      [] -> pure (GitReconciliation "absent" observedHead "" [])
      [(commit, parents)] -> do
        unless (parents == expectedHead : [baseHead | mergeBase]) $
          failWith Idempotency "recovered operation has unexpected commit parents"
        pure (GitReconciliation "existing" observedHead commit parents)
  where
    triples = \case
      a : b : c : rest -> (a, b, c) : triples rest
      _ -> []

-- | @_validate_staged_tree(root)@.
validateStagedTree :: FilePath -> IO [Text]
validateStagedTree root = do
  let rootT = T.pack root
  changed <- runGit ["-C", rootT, "diff", "--cached", "--name-only", "-z"] Nothing
  let changedPaths = filter (not . T.null) (T.splitOn "\0" changed)
  validateDeclaredPaths changedPaths
  raw <- runGit ["-C", rootT, "ls-files", "--stage", "-z"] Nothing
  entries <-
    fmap concat . forM (filter (not . T.null) (T.splitOn "\0" raw)) $ \entry -> do
      let (metadata, rest) = T.breakOn "\t" entry
          fields = pyWords metadata
      case fields of
        [mode, _, stage] | not (T.null rest) -> pure [(T.drop 1 rest, (mode, stage))]
        _ -> unsafeMode
  forM_ changedPaths $ \path -> do
    let values = [v | (k, v) <- entries, k == path]
    case values of
      [] -> pure ()
      [(mode, stage)] | mode `elem` ["100644", "100755"] && stage == "0" -> pure ()
      _ -> unsafeMode
  pure changedPaths
  where
    unsafeMode = failWith PatchAdmission "staged tree contains an unsafe mode or unmerged entry"

-- | @_create_commit(root, base_tree, expected_tree, changed, parents,
-- message)@.
createCommit :: HostGitPublisher -> FilePath -> Text -> Text -> [Text] -> [Text] -> Text -> IO Text
createCommit p root baseTree expectedTree changed parents message = do
  entries <- forM changed $ \path -> do
    index <- runGit ["-C", T.pack root, "ls-files", "--stage", "-z", "--", path] Nothing
    if T.null index
      then pure (path, "100644", Nothing)
      else do
        let stripped = fromMaybe index (T.stripSuffix "\0" index)
            (metadata, rest) = T.breakOn "\t" stripped
            observed = T.drop 1 rest
            fields = pyWords metadata
        case fields of
          [mode, _, "0"] | not (T.null rest) && observed == path -> do
            bytes <- BS.readFile (root </> T.unpack path)
            pure (path, mode, Just bytes)
          _ -> failWith PatchAdmission "staged tree contains an unsafe mode or unmerged entry"
  createdTree <- objectWrite (p.authority.createTree baseTree entries)
  when (createdTree /= expectedTree) $
    failWith ObjectWriteFailure "GitHub-created tree differs from the host-validated tree"
  objectWrite (p.authority.createCommit createdTree parents message p.commitName p.commitEmail)
  where
    objectWrite action =
      action `catch` \(e :: GitHubBoundaryError) ->
        if e.kind == ObjectWrite
          then failWith ObjectWriteFailure "GitHub did not prove Git object creation"
          else throwIO e

-- | @_advance_ref(ref, expected_head, commit)@.
advanceRef :: HostGitPublisher -> Text -> Text -> Text -> IO ()
advanceRef p ref expectedHead commit = do
  let destination = "refs/heads/" <> ref
  case p.authority.compareAndSwapRef of
    Nothing -> failWith RefCas "GitHub exact ref compare-and-swap is unavailable"
    Just cas ->
      cas p.authority.repository destination expectedHead commit `catch` \(_ :: GitHubBoundaryError) ->
        failWith RefCas "GitHub rejected or did not prove the exact ref compare-and-swap"

-- ---------------------------------------------------------------------------
-- Git subprocesses

-- | @_git_environment()@.
gitEnvironment :: [(String, String)]
gitEnvironment =
  [ ("PATH", "/bin:/usr/bin")
  , ("LANG", "C.UTF-8")
  , ("LC_ALL", "C.UTF-8")
  , ("HOME", "/dev/null")
  , ("GIT_CONFIG_NOSYSTEM", "1")
  , ("GIT_TERMINAL_PROMPT", "0")
  , ("GIT_CONFIG_COUNT", "2")
  , ("GIT_CONFIG_KEY_0", "credential.helper")
  , ("GIT_CONFIG_VALUE_0", "")
  , ("GIT_CONFIG_KEY_1", "core.hooksPath")
  , ("GIT_CONFIG_VALUE_1", "/dev/null")
  ]

-- | @git@ resolved on the child's @PATH@ (@os.defpath@), as
-- @subprocess@ resolves it.
gitExecutable :: IO (Maybe FilePath)
gitExecutable = firstExisting ["/bin/git", "/usr/bin/git"]
  where
    firstExisting = \case
      [] -> pure Nothing
      candidate : rest -> do
        exists <- doesFileExist candidate
        executable <- if exists then Posix.fileAccess candidate False False True else pure False
        if executable then pure (Just candidate) else firstExisting rest

-- | @HostGitPublisher._git(*arguments, capture=True, input_text=)@: the
-- decoded standard output (universal newlines). Any spawn failure,
-- nonzero exit, or 60-second timeout is a 'GitOperation' failure.
runGit :: [Text] -> Maybe Text -> IO Text
runGit arguments input = do
  executable <- gitExecutable
  path <- maybe gitFailed pure executable
  let process =
        (proc path (map T.unpack arguments))
          { env = Just gitEnvironment
          , std_in = CreatePipe
          , std_out = CreatePipe
          , std_err = CreatePipe
          }
  outcome <-
    try @SomeException . timeout 60000000 $
      withCreateProcess process $ \stdinH stdoutH stderrH handle -> case (stdinH, stdoutH, stderrH) of
        (Just hin, Just hout, Just herr) -> do
          mapM_ (`hSetBinaryMode` True) [hin, hout, herr]
          out <- newEmptyMVar
          err <- newEmptyMVar
          _ <- forkIO (BS.hGetContents hout >>= evaluate >>= putMVar out)
          _ <- forkIO (BS.hGetContents herr >>= evaluate >>= putMVar err)
          _ <- try @IOException (BS.hPut hin (TE.encodeUtf8 (fromMaybe "" input)))
          _ <- try @IOException (hClose hin)
          stdout <- takeMVar out
          _ <- takeMVar err
          code <- waitForProcess handle
          pure (code, stdout)
        _ -> throwIO (userError "git pipes were not created")
  case outcome of
    Right (Just (ExitSuccess, stdout)) -> decode stdout
    _ -> gitFailed
  where
    gitFailed = failWith GitOperation "Git operation failed"
    decode bytes = case TE.decodeUtf8' bytes of
      Left (_ :: UnicodeException) -> throwIO (PythonException "UnicodeDecodeError" [])
      Right text -> pure (universalNewlines text)
    universalNewlines = T.replace "\r" "\n" . T.replace "\r\n" "\n"

-- | @_publication_directory()@: a private temporary directory; failing to
-- create or remove it is a 'GitOperation' failure.
withPublicationDirectory :: (FilePath -> IO a) -> IO a
withPublicationDirectory action =
  withSystemTempDirectory "hamsterdan-git-" action `catch` \(_ :: IOException) ->
    failWith GitOperation "Git operation failed"

-- ---------------------------------------------------------------------------
-- Validation

-- | @_same_repository(left, right)@.
sameRepository :: Text -> Text -> Bool
sameRepository left right = Py.casefold left == Py.casefold right

-- | @_safe_branch(value)@.
safeBranch :: Text -> Bool
safeBranch value =
  safeRef value && not (".." `T.isInfixOf` value) && not ("@{" `T.isInfixOf` value) && not ("-" `T.isPrefixOf` value)
  where
    safeRef s = case T.uncons s of
      Just (c, rest) -> alnum c && T.length rest <= 254 && T.all (\x -> alnum x || x `elem` ("._/-" :: String)) rest
      Nothing -> False
    alnum x = (x >= 'a' && x <= 'z') || (x >= 'A' && x <= 'Z') || (x >= '0' && x <= '9')

-- | @_safe_path(value)@.
safePath :: Text -> Bool
safePath value
  | T.null value || "\0" `T.isInfixOf` value || "\\" `T.isInfixOf` value || "-" `T.isPrefixOf` value = False
  | otherwise =
      let parts = T.splitOn "/" value
       in all (`notElem` ["", "."]) parts
            && ".." `notElem` parts
            && all (\part -> Py.casefold part /= ".git" && Py.casefold part /= ".gitmodules") parts

-- | @_validate_declared_paths(paths)@.
validateDeclaredPaths :: [Text] -> IO ()
validateDeclaredPaths paths =
  when (null paths || length paths /= length (nub paths) || not (all safePath paths)) $
    failWith PatchAdmission "declared or staged paths are unsafe"

-- | @_validate_commit_message(message)@.
validateCommitMessage :: Text -> IO ()
validateCommitMessage message =
  when (any reserved (pySplitlines message)) $
    failWith PatchAdmission "proposed commit message contains a reserved publication trailer"
  where
    reserved line =
      let folded = Py.casefold (Py.strip line)
       in "hamsterdan-operation:" `T.isPrefixOf` folded || "hamsterdan-payload-digest:" `T.isPrefixOf` folded

-- | @_same_pull(current, original)@.
samePull :: PullRequestSnapshot -> PullRequestSnapshot -> Bool
samePull a b =
  a.repository == b.repository
    && a.number == b.number
    && a.headRepository == b.headRepository
    && a.headRef == b.headRef
    && a.base == b.base
    && a.baseRef == b.baseRef
    && a.state == b.state
    && a.draft == b.draft
    && a.merged == b.merged
    && a.closed == b.closed

-- | @_has_conflict_markers(diff)@.
hasConflictMarkers :: Text -> Bool
hasConflictMarkers diff = any marker (pySplitlines diff)
  where
    marker line = any (`T.isPrefixOf` line) ["+<<<<<<<", "+=======", "+>>>>>>>"]

-- | @payload_digest(value)@: the SHA-256 of the sorted compact JSON.
payloadDigest :: Json -> Text
payloadDigest = sha256HexText . dumpsSortedText

-- | @str.splitlines()@.
pySplitlines :: Text -> [Text]
pySplitlines text
  | T.null text = []
  | otherwise = go text
  where
    go s
      | T.null s = []
      | otherwise =
          let (line, rest) = T.break boundary s
           in case T.uncons rest of
                Nothing -> [line]
                Just ('\r', more) | Just ('\n', after) <- T.uncons more -> line : go after
                Just (_, after) -> line : go after
    boundary c = c `elem` ("\n\r\v\f\x1c\x1d\x1e\x85\x2028\x2029" :: String)

-- | @str.split()@.
pyWords :: Text -> [Text]
pyWords = filter (not . T.null) . T.split Py.isSpace

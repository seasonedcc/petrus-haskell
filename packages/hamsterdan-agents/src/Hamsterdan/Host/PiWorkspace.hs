-- | Private receiving-host proof from settled Pi workspaces to canonical
-- Git patches (@hamsterdan.host.pi_workspace@).
--
-- The provider clones the exact PR head below an owned private root,
-- exports the tracked files (plus the review diff inputs) as the Petrus
-- canonical workspace archive, and on settlement re-derives a canonical
-- patch from the returned archive, proving it by re-applying it to a fresh
-- clone. Every stage is removed when the body ends.
module Hamsterdan.Host.PiWorkspace
  ( -- * Limits
    maxWorkspaceEntries
  , maxChangedPaths
  , maxPatchBytes
  , readPolicy
  , codePolicy

    -- * The provider
  , WorkspaceOptions (..)
  , defaultWorkspaceOptions
  , GitPiWorkspaceProvider
  , newGitPiWorkspaceProvider
  , newGitPiWorkspaceProviderWith
  , providerRoot
  , gitPiWorkspaceProvider

    -- * Archive admission
  , ArchiveEntry (..)
  , validatedEntries
  , safeWorkspacePath
  ) where

import Control.Exception (IOException, SomeAsyncException, SomeException, fromException, mask, onException, throw, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Char8 qualified as BC
import Data.List (sort)
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Pi (PiWorkspaceError (..), PiWorkspaceProvider (..), PreparedPiWorkspace (..), PromptKind (..))
import Hamsterdan.Agents.Protocol
import Hamsterdan.Python.Exception (raise)
import Hamsterdan.Python.Hashlib (sha256Hex)
import Hamsterdan.Python.Text (utf8Decode)
import Hamsterdan.Python.Text qualified as Py
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Runtime.PiA2Host (PiA2RuntimePolicy, mkPiA2RuntimePolicy)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Archive.Tar (Member (..), isDirectory, isRegular, readTar)
import Petrus.Motus.Worker (ValueError (..))
import Petrus.Posix.File (makeDirectories, writeAll)
import System.Directory (canonicalizePath, doesFileExist, doesPathExist, findExecutable, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files qualified as Posix
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.User (getEffectiveUserID)
import System.Posix.Types (FileMode)
import System.Process.Typed (closed, proc, readProcess, setEnv, setStdin)
import System.Timeout (timeout)
import Petrus.Json.Python (randomBytes)

-- ---------------------------------------------------------------------------
-- Limits

maxWorkspaceEntries, maxChangedPaths, maxPatchBytes :: Int
maxWorkspaceEntries = 20000
maxChangedPaths = 1000
maxPatchBytes = 4000000

deniedRoots :: [Text]
deniedRoots = [".git", ".gitmodules", ".impetus", ".petrus-hands-stage"]

-- | @_READ_POLICY@ and @_CODE_POLICY@: module constants the reference
-- builds at import, raising the policy's 'AgenticusError' if it were
-- invalid (it is not: the arguments are fixed).
readPolicy, codePolicy :: PiA2RuntimePolicy
readPolicy = either throw id (mkPiA2RuntimePolicy [WorkspaceRead, WorkspaceSearch] [] 16 [])
codePolicy = either throw id (mkPiA2RuntimePolicy [WorkspaceRead, WorkspaceSearch, WorkspaceWrite] [] 32 ["."])

-- | The module globals the reference tests patch: @MAX_WORKSPACE_BYTES@
-- and @shutil.rmtree@.
data WorkspaceOptions = WorkspaceOptions
  { maxWorkspaceBytes :: Int
  , removeTree :: FilePath -> IO ()
  }

defaultWorkspaceOptions :: WorkspaceOptions
defaultWorkspaceOptions = WorkspaceOptions {maxWorkspaceBytes = 64 * 1024 * 1024, removeTree = removeDirectoryRecursive}

failWith :: Text -> IO a
failWith = throwIO . PiWorkspaceError

-- ---------------------------------------------------------------------------
-- The provider

-- | @GitPiWorkspaceProvider(root)@.
data GitPiWorkspaceProvider = GitPiWorkspaceProvider
  { root :: FilePath
  , options :: WorkspaceOptions
  }

providerRoot :: GitPiWorkspaceProvider -> FilePath
providerRoot provider = provider.root

newGitPiWorkspaceProvider :: FilePath -> IO GitPiWorkspaceProvider
newGitPiWorkspaceProvider = newGitPiWorkspaceProviderWith defaultWorkspaceOptions

newGitPiWorkspaceProviderWith :: WorkspaceOptions -> FilePath -> IO GitPiWorkspaceProvider
newGitPiWorkspaceProviderWith options selected = do
  root <- privateRoot selected
  pure GitPiWorkspaceProvider {root, options}

-- | @_private_root(path)@.
privateRoot :: FilePath -> IO FilePath
privateRoot selected = do
  linked <- either (const False) Posix.isSymbolicLink <$> try @IOException (Posix.getSymbolicLinkStatus selected)
  when linked $ throwIO (ValueError "Pi workspace receiver root must not be a symlink")
  makeDirectories selected 0o700
  Posix.setFileMode selected 0o700
  metadata <- Posix.getSymbolicLinkStatus selected
  euid <- getEffectiveUserID
  unless (Posix.isDirectory metadata && Posix.fileMode metadata .&. 0o7777 == 0o700 && Posix.fileOwner metadata == euid) $
    throwIO (ValueError "Pi workspace receiver root must be owned and private")
  canonicalizePath selected

-- | The provider as the runner's 'PiWorkspaceProvider'.
gitPiWorkspaceProvider :: GitPiWorkspaceProvider -> PiWorkspaceProvider
gitPiWorkspaceProvider provider = PiWorkspaceProvider (openWorkspace provider)

-- | @tempfile.mkdtemp(prefix="operation-", dir=root)@.
makeOperationRoot :: FilePath -> IO FilePath
makeOperationRoot root = go (100 :: Int)
  where
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_" :: String
    go attempts = do
      random <- randomBytes 8
      let path = root </> ("operation-" <> [alphabet !! (fromIntegral byte `mod` length alphabet) | byte <- BS.unpack random])
      created <- try (PosixDir.createDirectory path 0o700)
      case created of
        Right () -> pure path
        Left e
          | isAlreadyExistsError e && attempts > 1 -> go (attempts - 1)
          | otherwise -> throwIO e

-- | The fields every agent request carries.
requestFacts :: AgentRequest -> (Text, Integer, Integer, Text, Text)
requestFacts = \case
  AgentReview r -> (r.repository, r.pullRequest, r.epoch, r.head, r.base)
  AgentConversation r -> (r.repository, r.pullRequest, r.epoch, r.head, r.base)
  AgentCoding r -> (r.repository, r.pullRequest, r.epoch, r.head, r.base)


-- | @GitPiWorkspaceProvider.open(kind, repository_url, request, operation_id)@.
openWorkspace :: GitPiWorkspaceProvider -> PromptKind -> Text -> AgentRequest -> Text -> (PreparedPiWorkspace -> IO a) -> IO a
openWorkspace provider kind repositoryUrl request operationId body = mask $ \restore -> do
  created <- try @IOException (makeOperationRoot provider.root)
  operationRoot <- either (const (failWith "private Pi workspace preparation failed")) pure created
  let cleanup preparationFailed = do
        removed <- try @IOException (provider.options.removeTree operationRoot)
        either (const (throwIO (PiWorkspaceCleanupError preparationFailed))) pure removed
  prepared <- try @SomeException (restore (prepare provider kind repositoryUrl request operationId operationRoot))
  case prepared of
    Left e -> do
      cleanup True
      case fromException e of
        Just (failure :: PiWorkspaceError) -> throwIO failure
        Nothing
          | isJust (fromException @SomeAsyncException e) -> throwIO e
          | otherwise -> failWith "private Pi workspace preparation failed"
    Right workspace -> do
      result <- restore (body workspace) `onException` cleanup False
      cleanup False
      pure result

prepare :: GitPiWorkspaceProvider -> PromptKind -> Text -> AgentRequest -> Text -> FilePath -> IO PreparedPiWorkspace
prepare provider kind repositoryUrl request operationId operationRoot = do
  let checkout = operationRoot </> "source"
      base = operationRoot </> "base"
      result = operationRoot </> "result"
      verify = operationRoot </> "verify"
      (repository, pullRequest, epoch, headSha, baseSha) = requestFacts request
      limit = provider.options.maxWorkspaceBytes
  cloneExact repositoryUrl checkout headSha
  exportTracked limit checkout base
  case (kind, request) of
    (ReviewKind, AgentReview review) -> reviewInputs checkout base review
    _ -> pure ()
  archive <- workspaceArchive base
  when (BS.length archive > limit) $ failWith "input workspace archive exceeds its bound"
  let correlation =
        "hamsterdan-pr-v1:"
          <> sha256Hex
            ( TE.encodeUtf8
                ( T.intercalate
                    "\0"
                    [operationId, repository, T.pack (show pullRequest), T.pack (show epoch), headSha, baseSha]
                )
            )
  pure
    PreparedPiWorkspace
      { archive
      , digest = sha256Hex archive
      , correlation
      , policy = if kind == CodingKind then codePolicy else readPolicy
      , reconcile = reconcileWorkspace limit checkout result verify headSha
      }

-- | @PreparedGitWorkspace.reconcile(archive)@.
reconcileWorkspace :: Int -> FilePath -> FilePath -> FilePath -> Text -> ByteString -> IO (Text, [Text])
reconcileWorkspace limit checkout result verify headSha archive = do
  entries <- either throwIO pure (validatedEntries limit archive)
  extract entries result
  canonical <- workspaceArchive result
  when (canonical /= archive) $ failWith "settled workspace archive is not canonical"
  stageTree checkout result
  changed <- gitPaths checkout ["diff", "--cached", "--name-only", "-z", "HEAD", "--"]
  if null changed || length changed > maxChangedPaths
    then do
      unless (null changed) $ failWith "settled workspace changes exceed the path limit"
      pure ("", [])
    else do
      when (changed /= sort changed || not (all safeWorkspacePath changed)) $
        failWith "settled workspace changed paths are unsafe"
      patch <- gitText (Just checkout) ["diff", "--cached", "--binary", "HEAD", "--"] Nothing
      when (T.null (Py.strip patch) || BS.length (TE.encodeUtf8 patch) > maxPatchBytes) $
        failWith "canonical workspace patch is empty or exceeds its bound"
      resultTree <- Py.strip <$> gitText (Just checkout) ["write-tree"] Nothing
      cloneExact (T.pack checkout) verify headSha
      let patchPath = takeDirectory verify </> "canonical.patch"
      BS.writeFile patchPath (TE.encodeUtf8 patch)
      _ <- gitText (Just verify) ["apply", "--binary", "--index", "--", T.pack patchPath] Nothing
      verified <- Py.strip <$> gitText (Just verify) ["write-tree"] Nothing
      when (verified /= resultTree) $ failWith "canonical workspace patch could not reproduce the settled tree"
      pure (patch, changed)

-- | @_review_inputs(checkout, destination, request)@.
reviewInputs :: FilePath -> FilePath -> ReviewRequest -> IO ()
reviewInputs checkout destination request = do
  let paths = [request.diffPath, request.diffPath <> ".lines"]
  collisions <- forM paths $ \path ->
    if safeWorkspacePath path then doesPathExist (destination </> T.unpack path) else pure True
  when (or collisions) $ failWith "review input paths collide with repository content or are unsafe"
  let revision = request.base <> "..." <> request.head
  patch <- gitText (Just checkout) ["diff", "--no-ext-diff", "--no-textconv", revision, "--"] Nothing
  changed <- gitPaths checkout ["diff", "--name-only", "--diff-filter=ACMRT", "-z", revision, "--"]
  numbered <- fmap concat . forM changed $ \path -> do
    unless (safeWorkspacePath path) $ failWith "review changed path is unsafe"
    let source = destination </> T.unpack path
    isFile <- doesFileExist source
    if not isFile
      then pure []
      else do
        bytes <- BS.readFile source
        pure $ case TE.decodeUtf8' bytes of
          Left _ -> [path <> "\n", "[binary file; no numbered text]\n"]
          Right text ->
            (path <> "\n")
              : [T.pack (show line) <> ": " <> content <> "\n" | (line, content) <- zip [1 :: Int ..] (Py.splitlines (universalNewlines text))]
  forM_ (zip paths [patch, T.concat numbered]) $ \(path, content) -> do
    let encoded = TE.encodeUtf8 content
    when (BS.length encoded > maxPatchBytes) $ failWith "review input exceeds its bound"
    let target = destination </> T.unpack path
    makeDirectories (takeDirectory target) 0o777
    BS.writeFile target encoded

-- | @_clone_exact(repository_url, destination, head)@.
cloneExact :: Text -> FilePath -> Text -> IO ()
cloneExact repositoryUrl destination headSha = do
  _ <- gitText Nothing ["clone", "--quiet", "--no-checkout", "--", repositoryUrl, T.pack destination] Nothing
  _ <- gitText (Just destination) ["checkout", "--quiet", "--detach", headSha] Nothing
  current <- Py.strip <$> gitText (Just destination) ["rev-parse", "HEAD"] Nothing
  when (current /= headSha) $ failWith "workspace checkout differs from the requested head"
  _ <- gitText (Just destination) ["fsck", "--strict", "--no-dangling"] Nothing
  pure ()

-- | @_export_tracked(checkout, destination)@.
exportTracked :: Int -> FilePath -> FilePath -> IO ()
exportTracked limit checkout destination = do
  PosixDir.createDirectory destination 0o700
  raw <- gitBytes checkout ["ls-files", "--stage", "-z"] Nothing
  let entries = filter (not . BS.null) (BS.split 0 raw)
  when (length entries > maxWorkspaceEntries) $ failWith "input workspace has too many entries"
  let go _ _ [] = pure ()
      go total seen (entry : rest) = do
        let (metadata, remainder) = BS.breakSubstring "\t" entry
            separator = not (BS.null remainder)
            encodedPath = BS.drop 1 remainder
            fields = BC.words metadata
        path <- either (const (failWith "input workspace path is not UTF-8")) pure (TE.decodeUtf8' encodedPath)
        when
          ( not separator
              || length fields /= 3
              || take 1 fields `notElem` [["100644"], ["100755"]]
              || drop 2 fields /= ["0"]
              || Set.member path seen
              || not (safeWorkspacePath path)
          )
          $ failWith "input workspace contains an unsupported tracked entry"
        let source = checkout </> T.unpack path
        status <- Posix.getSymbolicLinkStatus source
        let mode = Posix.fileMode status .&. 0o7777
        unless (Posix.isRegularFile status && mode `elem` [0o644, 0o755]) $
          failWith "input workspace contains an unsupported file mode"
        let remaining = limit - total
        when (fromIntegral (Posix.fileSize status) > remaining) $ failWith "input workspace exceeds its expanded bound"
        content <- readBounded source (remaining + 1)
        when (fromIntegral (BS.length content) /= Posix.fileSize status) $
          failWith "input workspace file changed while being captured"
        writeEntry destination path content mode
        go (total + BS.length content) (Set.insert path seen) rest
  go 0 Set.empty entries
  where
    readBounded path count = do
      bytes <- BS.readFile path
      pure (BS.take count bytes)

-- | One validated settled-archive member.
data ArchiveEntry = ArchiveEntry
  { path :: Text
  , mode :: FileMode
  , content :: ByteString
  , directory :: Bool
  }
  deriving stock (Eq, Show)

-- | @_validated_entries(data)@ with @MAX_WORKSPACE_BYTES@ as an argument.
validatedEntries :: Int -> ByteString -> Either PiWorkspaceError [ArchiveEntry]
validatedEntries limit bytes
  | BS.null bytes || BS.length bytes > limit = Left (PiWorkspaceError "settled workspace archive is missing or oversized")
  | otherwise = case readTar bytes of
      Left _ -> Left (PiWorkspaceError "settled workspace archive is malformed")
      Right members -> do
        when (length members > maxWorkspaceEntries) $ Left (PiWorkspaceError "settled workspace has too many entries")
        entries <- walk Set.empty 0 members
        let files = Set.fromList [entry.path | entry <- entries, not entry.directory]
            directories = Set.fromList [entry.path | entry <- entries, entry.directory]
            required = Set.fromList (concatMap ancestors (Set.toList files))
        when (directories /= required) $ Left (PiWorkspaceError "settled workspace contains missing or empty directories")
        pure entries
  where
    refuse = Left . PiWorkspaceError
    walk _ _ [] = Right []
    walk seen total (member : rest) = do
      path <- either (const (refuse "settled workspace path is unsafe or duplicated")) Right (TE.decodeUtf8' member.memberName)
      when (Set.member path seen || not (safeWorkspacePath path)) $ refuse "settled workspace path is unsafe or duplicated"
      let mode = fromIntegral (member.memberMode .&. 0o7777) :: FileMode
      if isDirectory member
        then do
          when (mode /= 0o755) $ refuse "settled workspace directory mode is unsupported"
          (ArchiveEntry path mode "" True :) <$> walk (Set.insert path seen) total rest
        else do
          unless (isRegular member && mode `elem` [0o644, 0o755]) $
            refuse "settled workspace entry type or mode is unsupported"
          let total' = total + member.memberSize
          when (member.memberSize < 0 || total' > fromIntegral limit) $ refuse "settled workspace exceeds its expanded bound"
          let start = fromIntegral member.memberOffsetData
              size = fromIntegral member.memberSize
              content = BS.take size (BS.drop start bytes)
          when (BS.length content /= size || isJust member.memberSparse) $
            refuse "settled workspace file size is inconsistent"
          (ArchiveEntry path mode content False :) <$> walk (Set.insert path seen) total' rest
    -- every proper ancestor directory of a file, other than "."
    ancestors file =
      let parts = T.splitOn "/" file
       in [T.intercalate "/" (take n parts) | n <- [1 .. length parts - 1]]

-- | @_extract(entries, destination)@.
extract :: [ArchiveEntry] -> FilePath -> IO ()
extract entries destination = do
  PosixDir.createDirectory destination 0o700
  forM_ entries $ \entry ->
    if entry.directory
      then do
        let target = destination </> T.unpack entry.path
        makeDirectories target 0o755
        status <- Posix.getSymbolicLinkStatus target
        unless (Posix.isDirectory status) $ failWith "settled workspace staging path is unsafe"
        Posix.setFileMode target 0o755
      else writeEntry destination entry.path entry.content entry.mode

-- | @_write(root, path, content, mode)@.
writeEntry :: FilePath -> Text -> ByteString -> FileMode -> IO ()
writeEntry root path content mode = do
  let target = root </> T.unpack path
      parent = takeDirectory target
  makeDirectories parent 0o755
  let checkParents current = do
        unless (current == takeDirectory root) $ do
          status <- Posix.getSymbolicLinkStatus current
          when (Posix.isSymbolicLink status || not (Posix.isDirectory status)) $
            failWith "workspace staging parent is unsafe"
          unless (current == root || takeDirectory current == current) $ checkParents (takeDirectory current)
  checkParents parent
  fd <- openFd target WriteOnly defaultFileFlags {creat = Just mode, exclusive = True, nofollow = True}
  ( do
      writeAll fd content
      Posix.setFdMode fd mode
    )
    `onException` closeFd fd
  closeFd fd

-- | @_stage_tree(checkout, result)@.
stageTree :: FilePath -> FilePath -> IO ()
stageTree checkout result = do
  _ <- gitText (Just checkout) ["add", "--all", "--force", "--", "."] (Just [("GIT_WORK_TREE", result)])
  pure ()

-- | @_safe_workspace_path(value)@.
safeWorkspacePath :: Text -> Bool
safeWorkspacePath value =
  safePath value && Py.casefold (T.takeWhile (/= '/') value) `notElem` deniedRoots

-- | @git_publish._safe_path(value)@.
safePath :: Text -> Bool
safePath value
  | T.null value || "\0" `T.isInfixOf` value || "\\" `T.isInfixOf` value || "-" `T.isPrefixOf` value = False
  | otherwise =
      let parts = T.splitOn "/" value
       in all (`notElem` ["", "."]) parts
            && ".." `notElem` parts
            && all (\part -> Py.casefold part /= ".git" && Py.casefold part /= ".gitmodules") parts

-- ---------------------------------------------------------------------------
-- Git

-- | @_git_environment()@ (plus any extra variables).
gitEnvironment :: [(String, String)] -> IO [(String, String)]
gitEnvironment extra = do
  path <- fromMaybe "" <$> lookupEnv "PATH"
  pure $
    [ ("PATH", path)
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
      <> extra

gitFailed :: IO a
gitFailed = failWith "private Git workspace operation failed"

-- | @subprocess.run(("git", "-C", root, *arguments), check=True,
-- capture_output=True, timeout=60, env=...)@: the raw standard output.
gitBytes :: FilePath -> [Text] -> Maybe [(String, String)] -> IO ByteString
gitBytes root arguments extra =
  runGit (Just root) arguments extra >>= \case
    (ExitSuccess, stdout, _) -> pure stdout
    _ -> gitFailed

-- | Run Git to completion: its exit status, standard output and standard
-- error. A failure to start it, or the 60-second timeout, is the
-- reference's @PiWorkspaceError@ (@OSError@ and @SubprocessError@).
runGit :: Maybe FilePath -> [Text] -> Maybe [(String, String)] -> IO (ExitCode, ByteString, ByteString)
runGit root arguments extra = do
  environment <- gitEnvironment (fromMaybe [] extra)
  executable <- maybe gitFailed pure =<< findExecutable "git"
  let argv = maybe [] (\r -> ["-C", r]) root <> map T.unpack arguments
      process = setStdin closed . setEnv environment $ proc executable argv
  outcome <- try @SomeException (timeout 60000000 (readProcess process))
  case outcome of
    Right (Just (code, stdout, stderr)) -> pure (code, BL.toStrict stdout, BL.toStrict stderr)
    Left e | isJust (fromException @SomeAsyncException e) -> throwIO e
    _ -> gitFailed

-- | @_git(root, *arguments, capture=True)@ / @_run_git(...)@ with
-- @text=True@: strict UTF-8 and universal newlines. @subprocess.run@
-- decodes standard output, then standard error, before @check=True@ looks
-- at the exit status, so undecodable output of either is CPython's
-- @UnicodeDecodeError@ (which is not a 'PiWorkspaceError'), with its
-- message, whatever the status.
gitText :: Maybe FilePath -> [Text] -> Maybe [(String, String)] -> IO Text
gitText root arguments extra = do
  (code, stdout, stderr) <- runGit root arguments extra
  forM_ [stdout, stderr] (either raise (const (pure ())) . utf8Decode)
  case code of
    ExitSuccess -> pure (universalNewlines (TE.decodeUtf8 stdout))
    _ -> gitFailed

-- | @_git_paths(root, *arguments)@.
gitPaths :: FilePath -> [Text] -> IO [Text]
gitPaths root arguments = do
  raw <- gitBytes root arguments Nothing
  forM (filter (not . BS.null) (BS.split 0 raw)) $ \value ->
    either (const (failWith "canonical changed path is not UTF-8")) pure (TE.decodeUtf8' value)

universalNewlines :: Text -> Text
universalNewlines = T.replace "\r" "\n" . T.replace "\r\n" "\n"


-- | Closed, credential-free evidence for bounded Git publication
-- qualification (@host/publication_qualification.py@).
--
-- Every record here has a fixed shape and holds only closed categories, so
-- no private input (a credential, a repository coordinate, a provider
-- diagnostic) can reach retained evidence. The one mutation of the setup
-- sequence is 'AtomicSetupPush': a durable, owner-only spent marker is
-- written and synced before its single @git push --atomic@ runs, so a
-- restart can never push twice.
module Hamsterdan.Host.PublicationQualification
  ( -- * Categories
    QualificationCategory (..)
  , qualificationCategoryName
  , SetupCategory (..)
  , setupCategoryName
  , SetupPhase (..)
  , setupPhaseName

    -- * Setup evidence
  , SetupPushResult (..)
  , pushSanitized
  , SetupObservationResult (..)
  , observationSanitized
  , SetupQualificationResult (..)
  , setupAccepted
  , setupSanitized

    -- * The setup sequence
  , SetupSequence (..)
  , qualifySetup
  , observeSetupBoundary

    -- * The atomic push
  , AtomicSetupPush (..)
  , atomicSetupPush
  , push
  , setupCommand
  , setupMarker

    -- * The file-system calls the fence makes
  , SetupFs (..)
  , OpenRequest (..)
  , systemFs

    -- * Publication evidence
  , PublicationQualification
  , newPublicationQualification
  , PublicationState (..)
  , ReplayCategory (..)
  , PublicationEffect (..)
  , OriginalEvidence (..)
  , recordOriginal
  , runPublicationAssertions
  , recordCleanup
  , snapshot
  , publicationAssertionsAllowed
  , publicationAccepted
  , publicationSanitized
  , QualificationError (..)
  , RuntimeError (..)

    -- * Helpers
  , trySync
  ) where

import Control.Exception (Exception (..), SomeAsyncException, SomeException, catch, finally, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Hamsterdan.Agents.Protocol (AgentCleanupCategory, AgentResultCategory)
import Hamsterdan.Contracts.Codec (Contract (..), encode)
import Hamsterdan.Contracts.Readiness (ChangeResult (..), RepairResult (..))
import Hamsterdan.Python.Object (PV (..))
import Hamsterdan.Host.GitPublish (GitPublishError (..), PublicationCategory, categoryName)
import Hamsterdan.Operator.Posix (Stat (..), effectiveUid, isDirectory, isRegular, isSymlink, pathName, pathParent, permissionBits)
import Hamsterdan.Operator.Posix qualified as Posix
import Petrus.Json (Json (..))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd, openFdAt)
import System.Posix.IO.ByteString (fdRead, fdWrite)
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

-- ---------------------------------------------------------------------------
-- Categories

-- | Non-publication failures that must remain distinct in retained
-- evidence.
data QualificationCategory = ReplayBoundary | CleanupUnverified
  deriving stock (Eq, Show, Enum, Bounded)

qualificationCategoryName :: QualificationCategory -> Text
qualificationCategoryName = \case
  ReplayBoundary -> "replay_boundary"
  CleanupUnverified -> "cleanup_unverified"

-- | Closed outcomes for private qualification setup observations and
-- effects.
data SetupCategory
  = AlreadySpent
  | FenceUnavailable
  | BoundaryUnavailable
  | ObservationUnconfirmed
  | PushUnconfirmed
  | InputUnavailable
  deriving stock (Eq, Show, Enum, Bounded)

setupCategoryName :: SetupCategory -> Text
setupCategoryName = \case
  AlreadySpent -> "already_spent"
  FenceUnavailable -> "fence_unavailable"
  BoundaryUnavailable -> "boundary_unavailable"
  ObservationUnconfirmed -> "observation_unconfirmed"
  PushUnconfirmed -> "push_unconfirmed"
  InputUnavailable -> "input_unavailable"

-- | Closed phases for retained setup evidence.
data SetupPhase
  = Preparation
  | Identity
  | Target
  | PrePush
  | Push
  | Readback
  | PullRequest
  | CurrentCas
  | StaleCas
  deriving stock (Eq, Show, Enum, Bounded)

setupPhaseName :: SetupPhase -> Text
setupPhaseName = \case
  Preparation -> "setup_preparation"
  Identity -> "identity"
  Target -> "target"
  PrePush -> "pre_push"
  Push -> "push"
  Readback -> "readback"
  PullRequest -> "pull_request"
  CurrentCas -> "current_cas"
  StaleCas -> "stale_cas"

orEmpty :: (a -> Text) -> Maybe a -> PV
orEmpty name = PStr . maybe "" name

-- ---------------------------------------------------------------------------
-- Setup evidence

-- | Coordinate-free evidence for one admitted atomic push command.
data SetupPushResult = SetupPushResult
  { attempted :: Bool
  , commandSucceeded :: Bool
  , category :: Maybe SetupCategory
  }
  deriving stock (Eq, Show)

pushSanitized :: SetupPushResult -> PV
pushSanitized r =
  PDict
    [ ("attempted", PBool r.attempted)
    , ("command_succeeded", PBool r.commandSucceeded)
    , ("category", orEmpty setupCategoryName r.category)
    ]

-- | Private-input-free evidence for a setup observation.
data SetupObservationResult = SetupObservationResult
  { confirmed :: Bool
  , category :: Maybe SetupCategory
  }
  deriving stock (Eq, Show)

observationSanitized :: SetupObservationResult -> PV
observationSanitized r = PDict [("confirmed", PBool r.confirmed), ("category", orEmpty setupCategoryName r.category)]

-- | Fixed-shape evidence for the bounded qualification-setup sequence.
data SetupQualificationResult = SetupQualificationResult
  { identity :: Maybe SetupObservationResult
  , target :: Maybe SetupObservationResult
  , prePush :: Maybe SetupObservationResult
  , push :: Maybe SetupPushResult
  , readback :: Maybe SetupObservationResult
  , pullRequest :: Maybe SetupObservationResult
  , currentCas :: Maybe SetupObservationResult
  , staleCas :: Maybe SetupObservationResult
  , cleanup :: SetupObservationResult
  , firstCausePhase :: Maybe SetupPhase
  , firstCauseCategory :: Maybe SetupCategory
  }
  deriving stock (Eq, Show)

-- | @SetupQualificationResult.accepted@.
setupAccepted :: SetupQualificationResult -> Bool
setupAccepted r =
  all
    (maybe False (.confirmed))
    [r.identity, r.target, r.prePush, r.readback, r.pullRequest, r.currentCas, r.staleCas]
    && maybe False (.commandSucceeded) r.push
    && isNothing r.firstCauseCategory
    && r.cleanup.confirmed

-- | @SetupQualificationResult.sanitized()@.
setupSanitized :: SetupQualificationResult -> PV
setupSanitized r =
  PDict
    [ ("accepted", PBool (setupAccepted r))
    , ("identity", observation r.identity)
    , ("target", observation r.target)
    , ("pre_push", observation r.prePush)
    , ("push", maybe PNone pushSanitized r.push)
    , ("readback", observation r.readback)
    , ("pull_request", observation r.pullRequest)
    , ("current_cas", observation r.currentCas)
    , ("stale_cas", observation r.staleCas)
    , ("cleanup", observationSanitized r.cleanup)
    , ("first_cause_phase", orEmpty setupPhaseName r.firstCausePhase)
    , ("first_cause_category", orEmpty setupCategoryName r.firstCauseCategory)
    ]
  where
    observation = maybe PNone observationSanitized

-- ---------------------------------------------------------------------------
-- The setup sequence

-- | The keyword arguments of @qualify_setup@. Every callback is an
-- observation except the push.
data SetupSequence = SetupSequence
  { onIdentity :: IO Bool
  , onTarget :: IO Bool
  , onPrePush :: IO Bool
  , pusher :: AtomicSetupPush
  , remote :: Text
  , base :: Text
  , head :: Text
  , runner :: [Text] -> IO Int
  , onReadback :: IO Bool
  , onPullRequest :: IO Bool
  , onCurrentCas :: IO Bool
  , onStaleCas :: IO Bool
  , onCleanup :: IO Bool
  }

-- | @qualify_setup(...)@: run one setup attempt; the atomic push is its sole
-- mutation. Later phases are unreachable until exact readback confirms both
-- refs, and the cleanup observation always runs last.
qualifySetup :: SetupSequence -> IO SetupQualificationResult
qualifySetup s = do
  outcome <- body `onException` observeSetupBoundary s.onCleanup
  cleanupResult <- observeSetupBoundary s.onCleanup
  pure outcome {cleanup = cleanupResult}
  where
    empty =
      SetupQualificationResult
        { identity = Nothing
        , target = Nothing
        , prePush = Nothing
        , push = Nothing
        , readback = Nothing
        , pullRequest = Nothing
        , currentCas = Nothing
        , staleCas = Nothing
        , cleanup = SetupObservationResult False Nothing
        , firstCausePhase = Nothing
        , firstCauseCategory = Nothing
        }
    store phase value r = case phase of
      Identity -> r {identity = Just value}
      Target -> r {target = Just value}
      PrePush -> r {prePush = Just value}
      Readback -> r {readback = Just value}
      PullRequest -> r {pullRequest = Just value}
      CurrentCas -> r {currentCas = Just value}
      StaleCas -> r {staleCas = Just value}
      _ -> r
    firstCause phase category r
      | isJust r.firstCausePhase = r
      | otherwise = r {firstCausePhase = Just phase, firstCauseCategory = category}
    -- Observe each phase in turn; stop at the first that does not confirm.
    observeAll [] r = pure (r, True)
    observeAll ((phase, callback) : rest) r = do
      outcome <- observeSetupBoundary callback
      let r' = store phase outcome r
      if outcome.confirmed then observeAll rest r' else pure (firstCause phase outcome.category r', False)
    body = do
      (before, admitted) <- observeAll [(Identity, s.onIdentity), (Target, s.onTarget), (PrePush, s.onPrePush)] empty
      if not admitted
        then pure before
        else do
          pushed <- push s.pusher s.remote s.base s.head s.runner
          let afterPush =
                (if pushed.commandSucceeded then id else firstCause Push pushed.category)
                  before {push = Just pushed}
          -- Once execution was attempted, uncertainty is resolved only by the
          -- one exact readback. A rejected command is treated the same way.
          if not pushed.attempted
            then pure afterPush
            else do
              exact <- observeSetupBoundary s.onReadback
              let afterReadback =
                    (if exact.confirmed then id else firstCause Readback exact.category)
                      afterPush {readback = Just exact}
              if not exact.confirmed
                then pure afterReadback
                else
                  fst
                    <$> observeAll
                      [(PullRequest, s.onPullRequest), (CurrentCas, s.onCurrentCas), (StaleCas, s.onStaleCas)]
                      afterReadback

-- | @observe_setup_boundary(observer)@: run a private setup observation
-- without allowing its exception to render.
observeSetupBoundary :: IO Bool -> IO SetupObservationResult
observeSetupBoundary observer =
  trySync observer >>= \case
    Left _ -> pure (SetupObservationResult False (Just BoundaryUnavailable))
    Right False -> pure (SetupObservationResult False (Just ObservationUnconfirmed))
    Right True -> pure (SetupObservationResult True Nothing)

-- | Run an action, returning any synchronous exception (Python's
-- @except Exception@); asynchronous exceptions still propagate.
trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other

-- ---------------------------------------------------------------------------
-- The atomic push

-- | How the fence opens a file (the flag sets of its @os.open@ calls).
data OpenRequest
  = -- | @O_RDONLY | O_DIRECTORY | O_NOFOLLOW@.
    OpenDirectory
  | -- | @O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW@, mode @0600@.
    CreateExclusive
  | -- | @O_RDONLY | O_NOFOLLOW@.
    OpenRead
  deriving stock (Eq, Show)

-- | The @os@ functions the fence calls. Tests replace single calls, as the
-- reference's tests monkeypatch @os.fsync@, @os.close@, @os.open@ and
-- @os.write@.
data SetupFs = SetupFs
  { open :: Maybe Fd -> FilePath -> OpenRequest -> IO Fd
  -- ^ @os.open(path, flags, mode, dir_fd=...)@.
  , fstat :: Fd -> IO Stat
  , statAt :: Fd -> FilePath -> IO Stat
  -- ^ @os.stat(name, dir_fd=..., follow_symlinks=False)@.
  , lstat :: FilePath -> IO Stat
  , fchmod :: Fd -> IO ()
  -- ^ @os.fchmod(fd, 0o600)@.
  , write :: Fd -> ByteString -> IO Int
  , read :: Fd -> Int -> IO ByteString
  , fsync :: Fd -> IO ()
  , close :: Fd -> IO ()
  , geteuid :: IO Word64
  }

-- | The real calls.
systemFs :: SetupFs
systemFs =
  SetupFs
    { open = \dir path request -> case request of
        OpenDirectory -> openFdAt dir path ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}
        CreateExclusive ->
          openFdAt dir path WriteOnly defaultFileFlags {exclusive = True, nofollow = True, creat = Just 0o600, cloexec = True}
        OpenRead -> case dir of
          Nothing -> openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True}
          Just _ -> openFdAt dir path ReadOnly defaultFileFlags {nofollow = True, cloexec = True}
    , fstat = Posix.fdStat
    , statAt = Posix.statAt
    , lstat = Posix.lstat
    , fchmod = \fd -> setFdMode fd 0o600
    , write = \fd bytes -> fromIntegral <$> fdWrite fd bytes
    , read = \fd count -> fdRead fd (fromIntegral count)
    , fsync = fileSynchronise
    , close = closeFd
    , geteuid = effectiveUid
    }

-- | @AtomicSetupPush(spent_path)@: durably admit one exact atomic two-ref
-- push without retaining private inputs.
data AtomicSetupPush = AtomicSetupPush
  { spentPath :: FilePath
  , fs :: SetupFs
  }

atomicSetupPush :: FilePath -> AtomicSetupPush
atomicSetupPush path = AtomicSetupPush {spentPath = path, fs = systemFs}

-- | @_SETUP_MARKER@.
setupMarker :: ByteString
setupMarker = "atomic-two-ref-v1\n"

-- | @AtomicSetupPush.push(remote, base, head, runner)@.
push :: AtomicSetupPush -> Text -> Text -> Text -> ([Text] -> IO Int) -> IO SetupPushResult
push subject remote base head' runner = case setupCommand remote base head' of
  Nothing -> pure (SetupPushResult False False (Just BoundaryUnavailable))
  Just command ->
    trySync (spend subject) >>= \case
      Left _ -> pure (SetupPushResult False False (Just FenceUnavailable))
      Right (Just fence) -> pure (SetupPushResult False False (Just fence))
      Right Nothing ->
        trySync (runner command) >>= \case
          Left _ -> pure (SetupPushResult True False (Just BoundaryUnavailable))
          Right 0 -> pure (SetupPushResult True True Nothing)
          Right _ -> pure (SetupPushResult True False (Just PushUnconfirmed))

-- | @_spend()@: create the marker exclusively in an owner-only directory,
-- write it, sync the file and then the directory, and confirm that neither
-- was substituted meanwhile. 'Nothing' when the push may run. An
-- 'IOException' anywhere is @FENCE_UNAVAILABLE@ (as is any exception, to
-- the caller).
spend :: AtomicSetupPush -> IO (Maybe SetupCategory)
spend subject
  | name `elem` ["", ".", ".."] = pure (Just FenceUnavailable)
  | otherwise =
      either (\(_ :: IOError) -> Just FenceUnavailable) id <$> try do
        parentFd <- fs.open Nothing parent OpenDirectory
        (`finally` fs.close parentFd) do
          metadata <- fs.fstat parentFd
          euid <- fs.geteuid
          if isSymlink metadata || not (isDirectory metadata) || permissionBits metadata /= 0o700 || metadata.uid /= euid
            then pure (Just FenceUnavailable)
            else
              try (fs.open (Just parentFd) name CreateExclusive) >>= \case
                Left e
                  | isAlreadyExistsError e -> do
                      valid <- validSetupMarker fs parentFd name
                      pure (Just (if valid then AlreadySpent else FenceUnavailable))
                  | otherwise -> throwIO e
                Right fd -> do
                  written <- (`finally` fs.close fd) do
                    fs.fchmod fd
                    marker <- fs.fstat fd
                    if not (isRegular marker) || permissionBits marker /= 0o600 || marker.uid /= euid
                      then pure (Left FenceUnavailable)
                      else do
                        count <- fs.write fd setupMarker
                        if count /= BS.length setupMarker
                          then pure (Left FenceUnavailable)
                          else do
                            fs.fsync fd
                            entry <- fs.statAt parentFd name
                            pure
                              if (entry.dev, entry.ino) /= (marker.dev, marker.ino)
                                || not (isRegular entry)
                                || permissionBits entry /= 0o600
                                || entry.uid /= euid
                                then Left FenceUnavailable
                                else Right marker
                  case written of
                    Left fence -> pure (Just fence)
                    Right marker -> do
                      fs.fsync parentFd
                      currentParent <- fs.lstat parent
                      currentMarker <- fs.lstat subject.spentPath
                      pure
                        if (currentParent.dev, currentParent.ino) /= (metadata.dev, metadata.ino)
                          || isSymlink currentParent
                          || (currentMarker.dev, currentMarker.ino) /= (marker.dev, marker.ino)
                          || isSymlink currentMarker
                          then Just FenceUnavailable
                          else Nothing
  where
    fs = subject.fs
    parent = pathParent subject.spentPath
    name = pathName subject.spentPath

-- | @_valid_setup_marker(parent_descriptor, name)@.
validSetupMarker :: SetupFs -> Fd -> FilePath -> IO Bool
validSetupMarker fs parentFd name =
  either (\(_ :: IOError) -> False) id <$> try do
    euid <- fs.geteuid
    metadata <- fs.statAt parentFd name
    if isSymlink metadata
      || not (isRegular metadata)
      || permissionBits metadata /= 0o600
      || metadata.uid /= euid
      || metadata.size /= fromIntegral (BS.length setupMarker)
      then pure False
      else do
        fd <- fs.open (Just parentFd) name OpenRead
        (current, value) <- (`finally` fs.close fd) do
          current <- fs.fstat fd
          value <- fs.read fd (BS.length setupMarker + 1)
          pure (current, value)
        pure
          ( (current.dev, current.ino) == (metadata.dev, metadata.ino)
              && permissionBits current == 0o600
              && current.uid == euid
              && value == setupMarker
          )

-- | @_setup_command(remote, base, head)@: the one admitted command, or
-- 'Nothing' when any input is outside its grammar.
setupCommand :: Text -> Text -> Text -> Maybe [Text]
setupCommand remote base head' = do
  rest <- T.stripPrefix "https://github.com/" remote
  let (owner, afterOwner) = T.breakOn "/" rest
  path <- T.stripPrefix "/" afterOwner
  repository <- T.stripSuffix ".git" path
  let validOwner = case T.uncons owner of
        Just (c, more) -> asciiAlnum c && T.length more <= 38 && T.all (\x -> asciiAlnum x || x == '-') more
        Nothing -> False
      validRepository =
        T.length repository >= 1
          && T.length repository <= 100
          && T.all (\x -> asciiAlnum x || x `elem` ("._-" :: String)) repository
          && not (".." `T.isInfixOf` repository)
          && not ("." `T.isPrefixOf` repository)
          && not ("." `T.isSuffixOf` repository)
  unless (validOwner && validRepository && sha base && sha head' && base /= head') Nothing
  pure ["git", "push", "--atomic", remote, base <> ":refs/heads/main", head' <> ":refs/heads/hamsterdan/ds11-live-v4"]
  where
    asciiAlnum c = isAsciiLower c || isAsciiUpper c || isDigit c
    sha value = T.length value == 40 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) value

-- ---------------------------------------------------------------------------
-- Publication evidence

-- | A publication-category failure of the qualification itself: Python's
-- @ValueError@ or @TypeError@, with its message.
data QualificationError = QualificationError {cls :: Text, message :: Text}
  deriving stock (Eq, Show)

instance Exception QualificationError

-- | The Haskell spelling of a Python @RuntimeError@ raised by a replay
-- callback (other than 'GitPublishError', which carries its category).
newtype RuntimeError = RuntimeError Text
  deriving stock (Eq, Show)

instance Exception RuntimeError

-- | What a replay's first cause can be.
data ReplayCategory
  = ReplayPublication PublicationCategory
  | ReplayQualification QualificationCategory
  deriving stock (Eq, Show)

replayCategoryName :: ReplayCategory -> Text
replayCategoryName = \case
  ReplayPublication c -> categoryName c
  ReplayQualification c -> qualificationCategoryName c

-- | The fields of @PublicationQualification@.
data PublicationState = PublicationState
  { originalPublications :: Maybe Int
  , agentResultCategory :: Maybe AgentResultCategory
  , agentCleanupCategory :: Maybe AgentCleanupCategory
  , originalCategory :: Maybe PublicationCategory
  , schemaAssertion :: Maybe Bool
  , treeAssertion :: Maybe Bool
  , replayAssertion :: Maybe Bool
  , replayCategory :: Maybe ReplayCategory
  , cleanupVerified :: Maybe Bool
  , cleanupCategory :: Maybe QualificationCategory
  , assertionsStarted :: Bool
  }
  deriving stock (Eq, Show)

-- | First-cause-preserving state for one qualification publication.
newtype PublicationQualification = PublicationQualification (IORef PublicationState)

newPublicationQualification :: IO PublicationQualification
newPublicationQualification =
  PublicationQualification
    <$> newIORef
      PublicationState
        { originalPublications = Nothing
        , agentResultCategory = Nothing
        , agentCleanupCategory = Nothing
        , originalCategory = Nothing
        , schemaAssertion = Nothing
        , treeAssertion = Nothing
        , replayAssertion = Nothing
        , replayCategory = Nothing
        , cleanupVerified = Nothing
        , cleanupCategory = Nothing
        , assertionsStarted = False
        }

snapshot :: PublicationQualification -> IO PublicationState
snapshot (PublicationQualification ref) = readIORef ref

-- | The fields of a @ChangeResult@ or @RepairResult@ the evidence reads.
data OriginalEvidence = OriginalEvidence
  { ok :: Bool
  , publicationCategory :: Text
  , agentResultCategory :: Text
  , agentCleanupCategory :: Text
  }
  deriving stock (Eq, Show)

-- | @ChangeResult | RepairResult@.
class PublicationEffect a where
  originalEvidence :: a -> OriginalEvidence

instance PublicationEffect ChangeResult where
  originalEvidence r = OriginalEvidence r.ok r.publicationCategory r.agentResultCategory r.agentCleanupCategory

instance PublicationEffect RepairResult where
  originalEvidence r = OriginalEvidence r.ok r.publicationCategory r.agentResultCategory r.agentCleanupCategory

valueError :: Text -> IO a
valueError = throwIO . QualificationError "ValueError"

-- | @_category(value, vocabulary, name)@.
closedCategory :: (Bounded c, Enum c) => (c -> Text) -> Text -> Text -> IO (Maybe c)
closedCategory spell name value
  | T.null value = pure Nothing
  | otherwise = case [c | c <- [minBound .. maxBound], spell c == value] of
      c : _ -> pure (Just c)
      [] -> valueError (name <> " category is outside the closed vocabulary")

contractName :: Contract c => c -> Text
contractName c = case encode contract c of
  String s -> s
  _ -> ""

-- | @record_original(result, publications)@.
recordOriginal :: PublicationEffect r => PublicationQualification -> r -> Int -> IO ()
recordOriginal (PublicationQualification ref) result publications = do
  state <- readIORef ref
  let evidence = originalEvidence result
  when (isJust state.originalPublications || publications `notElem` [0, 1]) $
    valueError "original publication evidence is inconsistent"
  category <- closedCategory categoryName "original publication" evidence.publicationCategory
  resultCategory <- closedCategory contractName "agent result" evidence.agentResultCategory
  cleanupCategory <- closedCategory contractName "agent cleanup" evidence.agentCleanupCategory
  when (isJust category && isJust resultCategory) $
    valueError "agent admission and publication causes cannot overlap"
  when (evidence.ok && (publications /= 1 || isJust category || isJust resultCategory || isJust cleanupCategory)) $
    valueError "successful publication evidence is inconsistent"
  when
    ( not evidence.ok
        && (publications /= 0 || isNothing category && isNothing resultCategory && isNothing cleanupCategory)
    )
    $ valueError "failed publication lacks a closed category"
  modifyIORef' ref \s ->
    s
      { originalPublications = Just publications
      , agentResultCategory = resultCategory
      , agentCleanupCategory = cleanupCategory
      , originalCategory = category
      }

-- | @publication_assertions_allowed@.
publicationAssertionsAllowed :: PublicationState -> Bool
publicationAssertionsAllowed s = s.originalPublications == Just 1 && isNothing s.originalCategory

-- | @run_publication_assertions(schema=..., tree=..., replay=...)@. Only a
-- 'GitPublishError' or a 'RuntimeError' from the replay is recorded; any
-- other exception propagates, as in the reference.
runPublicationAssertions :: PublicationQualification -> IO Bool -> IO Bool -> IO Bool -> IO ()
runPublicationAssertions (PublicationQualification ref) schema tree replay = do
  started <- (.assertionsStarted) <$> readIORef ref
  when started $ valueError "publication assertions already started"
  modifyIORef' ref \s -> s {assertionsStarted = True}
  allowed <- publicationAssertionsAllowed <$> readIORef ref
  when allowed do
    schemaPassed <- schema
    modifyIORef' ref \s -> s {schemaAssertion = Just schemaPassed}
    treePassed <- tree
    modifyIORef' ref \s -> s {treeAssertion = Just treePassed}
    when (schemaPassed && treePassed) do
      outcome <-
        (Right <$> replay)
          `catch` (\(e :: GitPublishError) -> pure (Left (ReplayPublication e.category)))
          `catch` (\(_ :: RuntimeError) -> pure (Left (ReplayQualification ReplayBoundary)))
      modifyIORef' ref \s -> case outcome of
        Right passed -> s {replayAssertion = Just passed}
        Left category -> s {replayAssertion = Just False, replayCategory = Just category}

-- | @record_cleanup(verified)@.
recordCleanup :: PublicationQualification -> Bool -> IO ()
recordCleanup (PublicationQualification ref) verified = do
  state <- readIORef ref
  when (isJust state.cleanupVerified) $ valueError "cleanup evidence is inconsistent"
  modifyIORef' ref \s ->
    s {cleanupVerified = Just verified, cleanupCategory = if verified then Nothing else Just CleanupUnverified}

-- | @accepted@.
publicationAccepted :: PublicationState -> Bool
publicationAccepted s =
  publicationAssertionsAllowed s
    && s.schemaAssertion == Just True
    && s.treeAssertion == Just True
    && s.replayAssertion == Just True
    && isNothing s.replayCategory
    && s.cleanupVerified == Just True
    && isNothing s.cleanupCategory

-- | @sanitized()@: a fixed-shape record containing no caller-controlled
-- text.
publicationSanitized :: PublicationState -> PV
publicationSanitized s =
  PDict
    [ ("accepted", PBool (publicationAccepted s))
    , ("original_publications", maybe PNone (PInt . fromIntegral) s.originalPublications)
    , ("agent_result_category", orEmpty contractName s.agentResultCategory)
    , ("agent_cleanup_category", orEmpty contractName s.agentCleanupCategory)
    , ("original_category", orEmpty categoryName s.originalCategory)
    , ("publication_assertions_allowed", PBool (publicationAssertionsAllowed s))
    , ("schema_assertion", maybe PNone PBool s.schemaAssertion)
    , ("tree_assertion", maybe PNone PBool s.treeAssertion)
    , ("replay_assertion", maybe PNone PBool s.replayAssertion)
    , ("replay_category", orEmpty replayCategoryName s.replayCategory)
    , ("cleanup_verified", maybe PNone PBool s.cleanupVerified)
    , ("cleanup_category", orEmpty qualificationCategoryName s.cleanupCategory)
    ]

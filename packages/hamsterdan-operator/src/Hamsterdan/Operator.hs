{-# LANGUAGE RankNTypes #-}

-- | Bounded human-operator tooling for Hamsterdan qualification
-- (@src/hamsterdan/operator.py@, @python -m hamsterdan.operator@).
--
-- The demo commands act with the operator's configured @gh@ and Git
-- identity and print one sorted-key JSON object. The DS11 setup command
-- instead consumes one private credential file into a bounded child
-- environment. Neither route accepts credential values as arguments, and
-- no command reproduces provider prose or command output.
--
-- Provider JSON is read with the reference's dynamic Python semantics
-- ("Hamsterdan.Python.Object"): where the reference would raise an
-- exception it does not catch (an @AttributeError@ for a list where a dict
-- belongs, say), the port raises the same 'PythonException', and the command line
-- prints the last line of the reference's traceback.
module Hamsterdan.Operator
  ( -- * The fixture
    Fixture (..)
  , hbNetworkFixture
  , fixtureBotLogin
  , fixtureBrokerAuthorization

    -- * Constants
  , repository
  , orgId
  , repositoryId
  , appBotLogin
  , heroReviewer
  , brokerPath
  , brokerValidatorPath
  , delegatedBrokerDigest
  , delegatedValidatorDigest
  , oldMarker
  , newMarker
  , legacyBrokerAuthorization
  , appBrokerAuthorization
  , authorityExpectations
  , authorityReviewFacts
  , creatableScenarios

    -- * Failures
  , OperatorError (..)

    -- * Running commands
  , Completed (..)
  , Runner
  , commandRunner
  , Operator (..)
  , WithTemporary (..)
  , defaultOperator

    -- * Qualification setup
  , SetupCompleted (..)
  , SetupRunner
  , setupSubprocess
  , consumePrivateFile
  , parseSetupRefs
  , qualificationSetup

    -- * Demo commands
  , brokerStatus
  , brokerSourceDigest
  , preflight
  , scenarioValue
  , create
  , prepareBroker
  , safeComment
  , InspectOptions (..)
  , defaultInspectOptions
  , inspect
  , authorityPolicy
  , latestReviews
  , inspectAuthority

    -- * Command line
  , operatorParser
  , operatorParserFor
  , OperatorCommand (..)
  , OperatorEnvironment (..)
  , productionEnvironment
  , runOperator
  ) where

import Control.Applicative ((<|>))
import Control.Exception (Exception, IOException, SomeException, bracket, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Petrus.Argparse (Arg, ArgumentParser (..), Outcome (..), formattingFor, parse, pathText)
import Petrus.Argparse qualified as Argparse
import Hamsterdan.Python.Object
  ( PV (..)
  , PythonException (..)
  , errorLine
  , hashCheck
  , intText
  , iterateValue
  , pyEq
  , pyInt
  , pyStr
  , raiseEither
  , truthy
  )
import Hamsterdan.Python.Object qualified as PyV
import Hamsterdan.Python.Hashlib (sha256HexText)
import Hamsterdan.Python.Text (splitlines, utf8Encode)
import Hamsterdan.Host.PublicationQualification
import Hamsterdan.Operator.Posix (effectiveUid, normpath, pathParent)
import Hamsterdan.Operator.Posix qualified as Posix
import Hamsterdan.Operator.Python
import Petrus.Json.Python (fsEncode, pythonStrListRepr, utf8BackslashReplace)
import Petrus.Json.Wtf8 (fromCodePoints)
import Petrus.Posix.At (FileStat (..), Follow (..), isDirectory, isRegularFile, permissionBits)
import Petrus.Posix.At qualified as At
import Hamsterdan.Python.Exception (ioException, pythonError)
import System.Directory (canonicalizePath, doesFileExist, getTemporaryDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hFlush, stderr, stdout)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (createTempDirectory, withTempDirectory)
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files qualified as PosixFiles
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdRead, fdWrite)
import System.Process.Typed qualified as P
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Constants

-- | The repository, organization and App the demo commands act on: the
-- reference's module constants @REPOSITORY@, @ORG_ID@, @REPOSITORY_ID@,
-- @APP_SLUG@ (with @APP_BOT_LOGIN@ and @APP_BROKER_AUTHORIZATION@ derived
-- from it), @HERO_REVIEWER@ and the organization of @preflight@'s
-- @/orgs/HBNetwork@. 'hbNetworkFixture' is the reference's, and the one
-- 'defaultOperator' and the command line use. A tier C run
-- (docs/e2e.md) acts on its own copies through 'Operator.fixture'; the
-- delegated broker digests are 'Operator.brokerDigest' and
-- 'Operator.validatorDigest'.
data Fixture = Fixture
  { repository :: Text
  , organization :: Text
  , orgId :: Integer
  , repositoryId :: Integer
  , appSlug :: Text
  , heroReviewer :: Text
  }
  deriving stock (Eq, Show)

hbNetworkFixture :: Fixture
hbNetworkFixture =
  Fixture
    { repository = "HBNetwork/demo-pr-readiness"
    , organization = "HBNetwork"
    , orgId = 108842540
    , repositoryId = 1316665126
    , appSlug = "hamster-dan"
    , heroReviewer = "crisbastos"
    }

-- | @APP_BOT_LOGIN = f"{APP_SLUG}[bot]"@.
fixtureBotLogin :: Fixture -> Text
fixtureBotLogin fixture = fixture.appSlug <> "[bot]"

-- | @APP_BROKER_AUTHORIZATION@.
fixtureBrokerAuthorization :: Fixture -> Text
fixtureBrokerAuthorization fixture =
  "github.event.comment.user.type == 'Bot' &&\n      github.event.comment.user.login == '" <> fixtureBotLogin fixture <> "' &&"

repository :: Text
repository = hbNetworkFixture.repository

orgId, repositoryId :: Integer
orgId = hbNetworkFixture.orgId
repositoryId = hbNetworkFixture.repositoryId

defaultBranch :: Text
defaultBranch = "main"

workflows :: [Text]
workflows = ["ci", "rerun-broker"]

appBotLogin :: Text
appBotLogin = fixtureBotLogin hbNetworkFixture

scenarioPath :: Text
scenarioPath = ".pr-lab/scenario.json"

creatableScenarios :: [Text]
creatableScenarios = ["clean-green", "first-attempt-flake", "hero-review"]

heroReviewer :: Text
heroReviewer = hbNetworkFixture.heroReviewer

brokerPath, brokerValidatorPath :: Text
brokerPath = ".github/workflows/rerun-broker.yml"
brokerValidatorPath = "tools/rerun_broker.py"

-- | The normalized source pair accepted at
-- @HBNetwork/demo-pr-readiness\@a83e9223f7ffc6b0af919b0b8261fa2578261b41@.
delegatedBrokerDigest, delegatedValidatorDigest :: Text
delegatedBrokerDigest = "373195c1935ef1a339526a577a6e3e6c30b9b618a135cfec8bd6fd2ad9c15ef9"
delegatedValidatorDigest = "2869cce84573f4d3d21202a023f14b6138144667ae1a058cffab7442b7ab767a"

oldMarker, newMarker :: Text
oldMarker = "impetus-rerun"
newMarker = "hamsterdan-rerun"

legacyBrokerAuthorization :: Text
legacyBrokerAuthorization =
  "contains(fromJSON('[\"OWNER\",\"MEMBER\",\"COLLABORATOR\"]'), github.event.comment.author_association) &&"

appBrokerAuthorization :: Text
appBrokerAuthorization = fixtureBrokerAuthorization hbNetworkFixture

heroSuggestionLocation, heroConceptualLocation, heroRelatedLocation :: (Text, Integer)
heroSuggestionLocation = ("scenario-fixtures/hero_review/gate.py", 10)
heroConceptualLocation = ("scenario-fixtures/hero_review/gate.py", 16)
heroRelatedLocation = ("scenario-fixtures/hero_review/cache.py", 11)

heroFindingLocations :: [(Text, Integer)]
heroFindingLocations = [heroSuggestionLocation, heroConceptualLocation, heroRelatedLocation]

authorityExpectations :: [Text]
authorityExpectations =
  [ "non-draft"
  , "strict-stale"
  , "conflict"
  , "review-requested"
  , "changes-requested"
  , "required-approval"
  , "unresolved-thread"
  , "collaboration-clear"
  ]

authorityReviewFacts :: Text
authorityReviewFacts =
  T.unlines
    [ ""
    , "query($owner:String!,$repository:String!,$number:Int!) {"
    , "  repository(owner:$owner,name:$repository) {"
    , "    pullRequest(number:$number) {"
    , "      reviewDecision"
    , "      reviewThreads(first:100) {"
    , "        nodes { id isResolved }"
    , "        pageInfo { hasNextPage endCursor }"
    , "      }"
    , "    }"
    , "  }"
    , "}"
    ]

privateInputLimit :: Int
privateInputLimit = 4096

-- ---------------------------------------------------------------------------
-- Failures

-- | @OperatorError@: a bounded operator failure safe to display.
newtype OperatorError = OperatorError Text
  deriving stock (Eq, Show)

instance Exception OperatorError

operatorError :: Text -> IO a
operatorError = throwIO . OperatorError

-- | Raise what the reference raises, or continue.
py :: Either PythonException a -> IO a
py = raiseEither

-- ---------------------------------------------------------------------------
-- Running commands

-- | @subprocess.CompletedProcess[str]@.
data Completed = Completed
  { returncode :: Int
  , stdout :: Text
  , stderr :: Text
  }
  deriving stock (Eq, Show)

-- | @Runner@: run a command (with an optional working directory).
type Runner = [Text] -> Maybe FilePath -> IO Completed

-- | @command_runner@: @subprocess.run(command, cwd=cwd, text=True,
-- capture_output=True, check=False)@.
commandRunner :: Runner
commandRunner command cwd = case command of
  [] -> throwIO (pythonError "IndexError" "list index out of range")
  executable : arguments -> do
    (program, argv) <- execStrings executable arguments
    let config =
          maybe id P.setWorkingDir cwd
            . P.setStdout P.byteStringOutput
            . P.setStderr P.byteStringOutput
            $ P.proc program argv
    outcome <- try (P.readProcess config)
    case outcome of
      -- The OSError subprocess raises when the executable cannot run.
      Left (e :: IOException) -> ioException executable e >>= throwIO
      Right (code, out, err) -> do
        decodedOut <- py (decodeOutput (BL.toStrict out))
        decodedErr <- py (decodeOutput (BL.toStrict err))
        pure Completed {returncode = exitInt code, stdout = decodedOut, stderr = decodedErr}

-- | What @subprocess@ hands to @exec@: the executable, then each argument
-- (see 'execString').
execStrings :: Text -> [Text] -> IO (String, [String])
execStrings executable arguments = (,) <$> execString executable <*> mapM execString arguments

-- | A string as @subprocess@ passes it to @exec@, through @os.fsencode@:
-- @UnicodeEncodeError@, before anything is spawned, for a surrogate that
-- is not an escaped byte. An escaped byte stays its lone-surrogate
-- 'Char', which the process library's foreign encoding (UTF-8//ROUNDTRIP,
-- set by the executable's @main@) turns back into the byte.
execString :: Text -> IO String
execString text = either throwIO (const (pure (T.unpack text))) (fsEncode text)

exitInt :: ExitCode -> Int
exitInt = \case
  ExitSuccess -> 0
  ExitFailure n -> n

-- | What the reference's module-level hooks and globals provide, so tests
-- can replace them as the reference's tests monkeypatch them.
data Operator = Operator
  { runner :: Runner
  , stamp :: IO Text
  -- ^ @time.strftime("%Y%m%d-%H%M%S", time.gmtime())@.
  , withTemporary :: WithTemporary
  -- ^ @tempfile.TemporaryDirectory(prefix=...)@.
  , brokerDigest :: Text
  -- ^ @DELEGATED_BROKER_DIGEST@.
  , validatorDigest :: Text
  -- ^ @DELEGATED_VALIDATOR_DIGEST@.
  , fixture :: Fixture
  -- ^ The repository, organization and App acted on.
  }

-- | @with tempfile.TemporaryDirectory(prefix=prefix) as temporary@.
newtype WithTemporary = WithTemporary (forall a. String -> (FilePath -> IO a) -> IO a)

temporaryDirectory :: Operator -> String -> (FilePath -> IO a) -> IO a
temporaryDirectory Operator {withTemporary = WithTemporary within} = within

defaultOperator :: Operator
defaultOperator =
  Operator
    { runner = commandRunner
    , stamp = T.pack . formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getCurrentTime
    , withTemporary = WithTemporary \prefix action -> do
        parent <- getTemporaryDirectory
        withTempDirectory parent prefix action
    , brokerDigest = delegatedBrokerDigest
    , validatorDigest = delegatedValidatorDigest
    , fixture = hbNetworkFixture
    }

-- | @_run(runner, command, cwd)@.
run :: Operator -> [Text] -> Maybe FilePath -> IO Text
run op command cwd = do
  result <- op.runner command cwd
  when (result.returncode /= 0) $
    -- Never reproduce provider/command output: it can contain
    -- credential-bearing URLs or headers.
    operatorError
      ( pyStrip
          ( "command failed: "
              <> fromMaybe "" (listToMaybe command)
              <> " "
              <> fromMaybe "" (listToMaybe (drop 1 command))
          )
      )
  pure (pyStrip result.stdout)

-- | @_json(runner, command, cwd)@.
jsonOf :: Operator -> [Text] -> Maybe FilePath -> IO PV
jsonOf op command cwd = do
  out <- run op command cwd
  case loadsJson (PStr (if T.null out then "null" else out)) of
    Loaded value -> pure value
    Malformed -> operatorError ("malformed JSON from " <> fromMaybe "" (listToMaybe command))
    Raised e -> throwIO e

-- | @_api(runner, path)@.
api :: Operator -> Text -> IO PV
api op path = jsonOf op ["gh", "api", path] Nothing

-- ---------------------------------------------------------------------------
-- Qualification setup

-- | @subprocess.CompletedProcess[bytes]@ as the setup route reads it.
data SetupCompleted = SetupCompleted
  { returncode :: Int
  , stdout :: ByteString
  , stderr :: ByteString
  }
  deriving stock (Eq, Show)

-- | @SetupRunner@: command, working directory, the complete environment,
-- and standard input.
type SetupRunner = [Text] -> FilePath -> [(Text, Text)] -> Maybe ByteString -> IO SetupCompleted

-- | @_setup_subprocess@: run with exactly the given environment, capture
-- both streams, and give up after 30 seconds (the child is killed and the
-- call raises, as @subprocess.TimeoutExpired@ does).
setupSubprocess :: SetupRunner
setupSubprocess command cwd environment input = case command of
  [] -> throwIO (pythonError "IndexError" "tuple index out of range")
  executable : arguments -> do
    variables <- mapM (\(k, v) -> (,) <$> execString k <*> execString v) environment
    (program, argv) <- execStrings executable arguments
    let config =
          P.setWorkingDir cwd
            . P.setEnv variables
            . maybe id (P.setStdin . P.byteStringInput . BL.fromStrict) input
            . P.setStdout P.byteStringOutput
            . P.setStderr P.byteStringOutput
            $ P.proc program argv
    finished <- timeout 30000000 (P.readProcess config)
    case finished of
      Nothing -> throwIO (pythonError "TimeoutExpired" "Command timed out after 30 seconds")
      Just (code, out, err) ->
        pure SetupCompleted {returncode = exitInt code, stdout = BL.toStrict out, stderr = BL.toStrict err}

-- | @Path.write_text(content)@: @open(path, "w")@ (@O_WRONLY | O_CREAT |
-- O_TRUNC | O_CLOEXEC@, mode @0666@ before the umask), every byte written,
-- closed. Straight system calls rather than a 'Handle', which would add an
-- @fstat@, an @ftruncate@ and the handle lock table to each file.
writeText :: FilePath -> ByteString -> IO ()
writeText path content =
  bracket (openFd path WriteOnly defaultFileFlags {creat = Just 0o666, trunc = True, cloexec = True}) closeFd \fd ->
    let go remaining = unless (BS.null remaining) do
          written <- fdWrite fd remaining
          go (BS.drop (fromIntegral written) remaining)
     in go content

-- | @_consume_private_file(path)@: read and remove one owned @0600@ regular
-- file without following links.
consumePrivateFile :: FilePath -> IO ByteString
consumePrivateFile path = do
  outcome <- try do
    bracket (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True}) closeFd \fd -> do
      metadata <- At.fdStat fd
      entry <- At.statAt Nothing path NoFollowLinks
      euid <- effectiveUid
      when
        ( not (isRegularFile metadata)
            || permissionBits metadata /= 0o600
            || metadata.statUid /= euid
            || metadata.statLinkCount /= 1
            || (metadata.statDevice, metadata.statInode) /= (entry.statDevice, entry.statInode)
            || metadata.statSize < 1
            || metadata.statSize > fromIntegral privateInputLimit
        )
        unavailable
      value <- fdRead fd (fromIntegral (privateInputLimit + 1))
      when (fromIntegral (BS.length value) /= metadata.statSize) unavailable
      PosixFiles.removeLink path
      stillThere <- PosixFiles.fileExist path
      when stillThere unavailable
      pure value
  case outcome of
    Left (_ :: IOException) -> unavailable
    Right value -> pure value
  where
    unavailable = operatorError "private input file is unavailable"

-- | @_parse_setup_refs(raw)@: parse an exact smart-HTTP ref projection
-- without ignoring malformed data.
parseSetupRefs :: ByteString -> Either OperatorError [(Text, Text)]
parseSetupRefs raw = do
  -- decode("ascii"), then no \r, \v or \f anywhere.
  unless (BS.all (< 0x80) raw) malformed
  when (BS.any (\w -> w == 0x0d || w == 0x0b || w == 0x0c) raw) malformed
  let pieces = BS.split 0x0a raw
      -- str.split("\n") of "" is [""], which the trailing-"" rule empties.
      lines' = case reverse pieces of
        "" : rest -> reverse rest
        _ -> pieces
  when (any BS.null lines') malformed
  let step (seen, found) line = case BS.split 0x09 line of
        [sha, reference]
          | isSha sha
          , validRef reference
          , not (".." `BS.isInfixOf` reference)
          , not ("@{" `BS.isInfixOf` reference)
          , not ("/" `BS.isSuffixOf` reference || "." `BS.isSuffixOf` reference)
          , not (any (\c -> BS.null c || "." `BS.isPrefixOf` c || ".lock" `BS.isSuffixOf` c) (BS.split 0x2f reference))
          , not (reference `Set.member` seen) ->
              Right (Set.insert reference seen, (TE.decodeLatin1 reference, TE.decodeLatin1 sha) : found)
        _ -> malformed
  reverse . snd <$> foldlM' step (Set.empty, []) lines'
  where
    malformed :: Either OperatorError a
    malformed = Left (OperatorError "Git ref observation is malformed")
    isSha s = BS.length s == 40 && BS.all (\w -> (w >= 0x30 && w <= 0x39) || (w >= 0x61 && w <= 0x66)) s
    -- refs/[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\Z
    validRef r = case BS.stripPrefix "refs/" r of
      Just rest -> case BS.uncons rest of
        Just (c, more) -> alnum c && BS.length more <= 255 && BS.all (\x -> alnum x || x == 0x2e || x == 0x5f || x == 0x2f || x == 0x2d) more
        Nothing -> False
      Nothing -> False
    alnum w = (w >= 0x30 && w <= 0x39) || (w >= 0x41 && w <= 0x5a) || (w >= 0x61 && w <= 0x7a)
    foldlM' f z = \case
      [] -> Right z
      x : xs -> f z x >>= \z' -> foldlM' f z' xs

asciiAlnum :: Char -> Bool
asciiAlnum c = isAsciiLower c || isAsciiUpper c || isDigit c

-- | @qualification_setup(credential_file, target_file, spent_path, runner=...)@:
-- run the one-mutation setup route with isolated, managed authority.
qualificationSetup :: SetupRunner -> FilePath -> FilePath -> FilePath -> IO PV
qualificationSetup runner credentialFile targetFile spentPath = do
  rootRef <- newIORef Nothing
  inputsRef <- newIORef (pathString credentialFile, pathString targetFile)
  attemptedRef <- newIORef False
  confirmedRef <- newIORef False
  let removeFile' path = do
        let attempt (0 :: Int) = pure ()
            attempt n =
              try (PosixFiles.removeLink path) >>= \case
                Right () -> attempt (n - 1)
                Left (e :: IOException)
                  | isDoesNotExistError e -> pure ()
                  | otherwise -> attempt (n - 1)
        attempt 2
        absentAfter path
      absentAfter path =
        try (At.statAt Nothing path NoFollowLinks) >>= \case
          Left (e :: IOException) -> pure (isDoesNotExistError e)
          Right _ -> pure False
      cleanup = do
        writeIORef attemptedRef True
        (credentialPath, targetPath) <- readIORef inputsRef
        credentialAbsent <- removeFile' credentialPath
        targetAbsent <- removeFile' targetPath
        root <- readIORef rootRef
        rootAbsent <- case root of
          Nothing -> pure True
          Just directory -> do
            let attempt (0 :: Int) = pure ()
                attempt n =
                  try (At.rmtree directory) >>= \case
                    Right () -> attempt (n - 1)
                    Left (e :: IOException)
                      | isDoesNotExistError e -> pure ()
                      | otherwise -> attempt (n - 1)
            attempt 2
            absentAfter directory
        let absent = credentialAbsent && targetAbsent && rootAbsent
        writeIORef confirmedRef absent
        pure absent
      preparationFailure = do
        void cleanup
        confirmed <- readIORef confirmedRef
        let result =
              SetupQualificationResult
                { identity = Nothing
                , target = Nothing
                , prePush = Nothing
                , push = Nothing
                , readback = Nothing
                , pullRequest = Nothing
                , currentCas = Nothing
                , staleCas = Nothing
                , cleanup = SetupObservationResult confirmed (if confirmed then Nothing else Just ObservationUnconfirmed)
                , firstCausePhase = Just Preparation
                , firstCauseCategory = Just InputUnavailable
                }
        pure (evidence False result)
      evidence accepted result =
        PDict [("command", PStr "qualification-setup"), ("ok", PBool accepted), ("evidence", setupSanitized result)]
      body = do
        let rawPaths = [credentialFile, targetFile, spentPath]
        if not (all Posix.isAbsolute rawPaths)
          then preparationFailure
          else do
            let normalized = map normpath rawPaths
            if Set.size (Set.fromList normalized) /= 3
              then preparationFailure
              else case normalized of
                [credentialPath, targetPath, marker] -> do
                  writeIORef inputsRef (credentialPath, targetPath)
                  gitFound <- Posix.which "git"
                  ghFound <- Posix.which "gh"
                  case (gitFound, ghFound) of
                    (Just gitPath, Just ghPath) -> do
                      gitExecutable <- T.pack <$> canonicalizePath gitPath
                      ghExecutable <- T.pack <$> canonicalizePath ghPath
                      let markerParent = pathParent marker
                      parent <- At.statAt Nothing markerParent NoFollowLinks
                      resolved <- canonicalizePath markerParent
                      euid <- effectiveUid
                      if resolved /= markerParent
                        || not (isDirectory parent)
                        || permissionBits parent /= 0o700
                        || parent.statUid /= euid
                        then preparationFailure
                        else do
                          credential <- consumePrivateFile credentialPath
                          targetInput <- consumePrivateFile targetPath
                          prepared credential targetInput marker gitExecutable ghExecutable
                    _ -> preparationFailure
                _ -> preparationFailure
      prepared credential targetInput marker gitExecutable ghExecutable
        | not (BS.all (< 0x80) credential) = preparationFailure
        | otherwise = do
            let token = TE.decodeLatin1 credential
            if T.null token || pyStrip token /= token || T.any pyIsSpace token
              then preparationFailure
              else case loadsJson (PBytes targetInput) of
                Loaded (PDict members)
                  | Set.fromList (map fst members) == Set.fromList ["repository", "account_id", "repository_id"]
                  , Just (PStr targetName) <- lookup "repository" members
                  , Just (PInt accountId) <- lookup "account_id" members
                  , Just (PInt targetRepositoryId) <- lookup "repository_id" members
                  , validTarget targetName ->
                      let (owner, rest) = T.breakOn "/" targetName
                          repositoryName = T.drop 1 rest
                       in if ".." `T.isInfixOf` repositoryName
                            || "." `T.isPrefixOf` repositoryName
                            || "." `T.isSuffixOf` repositoryName
                            then preparationFailure
                            else launch token marker gitExecutable ghExecutable targetName owner repositoryName accountId targetRepositoryId
                Raised _ -> preparationFailure
                _ -> preparationFailure
      launch token marker gitExecutable ghExecutable targetName owner repositoryName accountId targetRepositoryId = do
        temporary <- getTemporaryDirectory
        root <- createTempDirectory temporary "hamsterdan-qualification-"
        writeIORef rootRef (Just root)
        PosixFiles.setFileMode root 0o700
        let home = root </> "home"
            ghConfig = root </> "gh"
            fixture = root </> "fixture"
        forM_ [home, ghConfig, fixture] \directory -> PosixDir.createDirectory directory 0o700
        let environment =
              [ ("PATH", "/bin:/usr/bin")
              , ("HOME", T.pack home)
              , ("GH_CONFIG_DIR", T.pack ghConfig)
              , ("GH_PROMPT_DISABLED", "1")
              , ("GH_TOKEN", token)
              , ("GIT_TERMINAL_PROMPT", "0")
              , ("GIT_CONFIG_NOSYSTEM", "1")
              , ("GIT_CONFIG_GLOBAL", "/dev/null")
              ]
            rawRun command cwd env = runner command cwd env Nothing
            gitOptions =
              [ "-c"
              , "credential.helper="
              , "-c"
              , "credential.helper=!" <> shlexQuote ghExecutable <> " auth git-credential"
              , "-c"
              , "core.hooksPath=/dev/null"
              , "-c"
              , "http.followRedirects=false"
              , "-c"
              , "protocol.file.allow=never"
              ]
            git env arguments = rawRun (gitExecutable : gitOptions <> arguments) fixture env
            fixtureCommands =
              [ ["init", "--quiet", "--initial-branch=main"]
              , ["config", "user.name", "Hamsterdan Qualification"]
              , ["config", "user.email", "qualification@invalid"]
              ]
            commitEnvironment =
              environment <> [("GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"), ("GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z")]
            fixtureRun = git commitEnvironment
            allSucceed [] = pure True
            allSucceed (command : more) = do
              result <- command
              if result.returncode /= 0 then pure False else allSucceed more
            decodeStripped bytes = case decodeOutput bytes of
              Left e -> throwIO e
              Right text -> pure (pyStrip text)
        initialized <- allSucceed (map (git environment) fixtureCommands)
        if not initialized
          then preparationFailure
          else do
            writeText (fixture </> "qualification.txt") "hamsterdan qualification fixture v1\n"
            committed <- allSucceed (map fixtureRun [["add", "qualification.txt"], ["commit", "--quiet", "-m", "base"]])
            if not committed
              then preparationFailure
              else do
                baseResult <- fixtureRun ["rev-parse", "HEAD"]
                base <- decodeStripped baseResult.stdout
                writeText (fixture </> "requested-change.txt") "requested change\n"
                changed <- allSucceed (map fixtureRun [["add", "requested-change.txt"], ["commit", "--quiet", "-m", "change"]])
                if not changed
                  then preparationFailure
                  else do
                    headResult <- fixtureRun ["rev-parse", "HEAD"]
                    head' <- decodeStripped headResult.stdout
                    if baseResult.returncode /= 0 || headResult.returncode /= 0 || not (isSha base) || not (isSha head')
                      then preparationFailure
                      else do
                        let remote = "https://github.com/" <> owner <> "/" <> repositoryName <> ".git"
                            refs names = do
                              result <- git environment (["ls-remote", "--refs", remote] <> names)
                              if result.returncode /= 0
                                then pure Nothing
                                else either throwIO (pure . Just) (parseSetupRefs result.stdout)
                            qualificationRef = "refs/heads/hamsterdan/ds11-live-v4"
                            expected = [("refs/heads/main", base), (qualificationRef, head')]
                            sameRefs a b = Map.fromList a == Map.fromList b
                            empty = maybe False null <$> refs []
                            exact = maybe False (sameRefs expected) <$> refs []
                            pullRequestReady = do
                              -- GitHub exposes PR heads as read-only smart-HTTP
                              -- refs. The target is ready only when no existing
                              -- PR advertises this exact head.
                              advertised <- refs ["refs/pull/*/head"]
                              pure (maybe False (notElem head' . map snd) advertised)
                            staleCasObserved = do
                              current <- refs [qualificationRef]
                              pure
                                ( fmap Map.fromList current == Just (Map.fromList [(qualificationRef, head')])
                                    && fmap Map.fromList current /= Just (Map.fromList [(qualificationRef, base)])
                                )
                            ghJson endpoint = do
                              result <- rawRun [ghExecutable, "api", endpoint] root environment
                              when (result.returncode /= 0) $ throwIO (pythonError "RuntimeError" "")
                              case loadsJson (PBytes result.stdout) of
                                Loaded value -> pure value
                                Malformed -> throwIO (pythonError "JSONDecodeError" "")
                                Raised e -> throwIO e
                            identityCheck = do
                              value <- ghJson "/user"
                              pure case value of
                                PDict members -> pyEq (fromMaybe PNone (lookup "id" members)) (PInt accountId)
                                _ -> False
                            targetReady = do
                              value <- ghJson ("/repos/" <> owner <> "/" <> repositoryName)
                              pure case value of
                                PDict members ->
                                  let member name = fromMaybe PNone (lookup name members)
                                      isFalse = \case PBool False -> True; _ -> False
                                   in pyEq (member "full_name") (PStr targetName)
                                        && pyEq (member "id") (PInt targetRepositoryId)
                                        && isFalse (member "private")
                                        && isFalse (member "archived")
                                        && isFalse (member "disabled")
                                        && pyEq (member "size") (PInt 0)
                                        && pyEq (member "default_branch") (PStr "main")
                                        && case member "permissions" of
                                          PDict permissions -> case lookup "push" permissions of
                                            Just (PBool True) -> True
                                            _ -> False
                                          _ -> False
                                _ -> False
                        result <-
                          qualifySetup
                            SetupSequence
                              { onIdentity = identityCheck
                              , onTarget = targetReady
                              , onPrePush = targetReady >>= \ready -> if ready then empty else pure False
                              , pusher = atomicSetupPush marker
                              , remote
                              , base
                              , head = head'
                              , runner = \command -> (.returncode) <$> rawRun (gitExecutable : gitOptions <> drop 1 command) fixture environment
                              , onReadback = exact
                              , -- These are deliberately observations. No PR or ref
                                -- mutation is performed by qualification setup.
                                onPullRequest = pullRequestReady
                              , onCurrentCas = exact
                              , onStaleCas = staleCasObserved
                              , onCleanup = cleanup
                              }
                        pure (evidence (setupAccepted result) result)
  outcome <- trySync body
  result <- either (const preparationFailure) pure outcome
  attempted <- readIORef attemptedRef
  unless attempted (void cleanup)
  pure result
  where
    isSha s = T.length s == 40 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) s
    validTarget name =
      let (owner, rest) = T.breakOn "/" name
          repositoryName = T.drop 1 rest
       in case T.uncons owner of
            Just (c, more) ->
              asciiAlnum c
                && T.length more <= 38
                && T.all (\x -> asciiAlnum x || x == '-') more
                && "/" `T.isPrefixOf` rest
                && T.length repositoryName >= 1
                && T.length repositoryName <= 100
                && T.all (\x -> asciiAlnum x || x `elem` ("._-" :: String)) repositoryName
            Nothing -> False

-- ---------------------------------------------------------------------------
-- The broker

-- | @broker_status(text, validator)@.
brokerStatus :: Operator -> Text -> Maybe Text -> Text
brokerStatus op text validator
  | oldPrefix && oldRegex && legacyAuth && not newPrefix && not newRegex && not appAuth = "legacy"
  | newPrefix && newRegex && appAuth && not oldPrefix && not oldRegex && not legacyAuth = "hamsterdan"
  | delegated = "hamsterdan"
  | otherwise = "malformed"
  where
    oldPrefix = "startsWith(github.event.comment.body, '<!-- impetus-rerun ')" `T.isInfixOf` text
    oldRegex = "<!-- impetus-rerun run=" `T.isInfixOf` text
    newPrefix = "startsWith(github.event.comment.body, '<!-- hamsterdan-rerun ')" `T.isInfixOf` text
    newRegex = "<!-- hamsterdan-rerun run=" `T.isInfixOf` text
    legacyAuth = T.count legacyBrokerAuthorization text == 1
    appAuth = T.count (fixtureBrokerAuthorization op.fixture) text == 1
    delegated = case validator of
      Nothing -> False
      Just source -> brokerSourceDigest text == op.brokerDigest && brokerSourceDigest source == op.validatorDigest

-- | @_broker_digest(source)@.
brokerSourceDigest :: Text -> Text
brokerSourceDigest source =
  sha256HexText (pyStrip (T.replace "\r\n" "\n" source))

-- | @_check(name, passed, observed)@.
check :: Text -> Bool -> PV -> PV
check name verdict observed = PDict [("name", PStr name), ("pass", PBool verdict), ("observed", observed)]

-- | @preflight(runner, health_url=...)@.
preflight :: Operator -> Maybe Text -> IO PV
preflight op healthUrl = do
  auth <- op.runner ["gh", "auth", "status"] Nothing
  let authCheck = check "gh_auth" (auth.returncode == 0) (PStr (if auth.returncode == 0 then "authenticated" else "unavailable"))
  inventory <- try do
    org <- api op ("/orgs/" <> op.fixture.organization)
    repo <- api op ("/repos/" <> op.fixture.repository)
    workflowList <- api op ("/repos/" <> op.fixture.repository <> "/actions/workflows?per_page=100")
    broker <-
      run
        op
        ["gh", "api", "/repos/" <> op.fixture.repository <> "/contents/" <> brokerPath <> "?ref=" <> defaultBranch, "-H", "Accept: application/vnd.github.raw+json"]
        Nothing
    validator <-
      if "tools/rerun_broker.py" `T.isInfixOf` broker
        then
          Just
            <$> run
              op
              [ "gh"
              , "api"
              , "/repos/" <> op.fixture.repository <> "/contents/" <> brokerValidatorPath <> "?ref=" <> defaultBranch
              , "-H"
              , "Accept: application/vnd.github.raw+json"
              ]
              Nothing
        else pure Nothing
    let brokerState = brokerStatus op broker validator
    names <- py do
      listed <- getOr "workflows" (PList []) workflowList
      items <- iterateValue listed
      found <- forM [item | item <- items, isDict item] (getMaybe "name")
      mapM_ hashCheck found
      pure found
    let strings = Set.fromList [s | PStr s <- names]
    orgIdValue <- py (getMaybe "id" org)
    repoIdValue <- py (getMaybe "id" repo)
    private <- py (getMaybe "private" repo)
    privateDefaulted <- py (getOr "private" (PBool True) repo)
    branch <- py (getMaybe "default_branch" repo)
    pure
      [ check "organization_identity" (pyEq orgIdValue (PInt op.fixture.orgId)) orgIdValue
      , check "repository_identity" (pyEq repoIdValue (PInt op.fixture.repositoryId)) repoIdValue
      , check "repository_public" (case private of PBool False -> True; _ -> False) (PBool (not (truthy privateDefaulted)))
      , check "default_branch" (pyEq branch (PStr defaultBranch)) branch
      , check "required_workflows" (all (`Set.member` strings) workflows) (PList (map PStr (Set.toAscList strings)))
      , check "default_broker" (brokerState `elem` ["legacy", "hamsterdan"]) (PStr brokerState)
      ]
  let inventoryChecks = case inventory of
        Right found -> found
        Left (OperatorError message) -> [check "provider_inventory" False (PStr message)]
  health <- case healthUrl of
    Just url | not (T.null url) -> do
      let endpoint = T.dropWhileEnd (== '/') url <> "/healthz"
      result <- op.runner ["curl", "--fail", "--silent", "--show-error", "--max-time", "10", endpoint] Nothing
      healthy <-
        if result.returncode /= 0
          then pure False
          else case loadsJson (PStr result.stdout) of
            Loaded value -> pure (isDict value)
            Malformed -> pure False
            Raised e -> throwIO e
      pure [check "app_host_health" healthy (PStr (if healthy then "healthy" else "unavailable"))]
    _ -> pure []
  let checks = authCheck : inventoryChecks <> health
  pure (PDict [("command", PStr "preflight"), ("ok", PBool (all passed checks)), ("checks", PList checks)])

passed :: PV -> Bool
passed = \case
  PDict members -> maybe False truthy (lookup "pass" members)
  _ -> False

-- | @scenario_value(scenario)@.
scenarioValue :: Text -> Either OperatorError PV
scenarioValue scenario = do
  behavior <-
    if scenario == "first-attempt-flake"
      then Right (PDict [("kind", PStr "first_attempt_flake"), ("fingerprint", PStr "scenario:first-attempt-flake:v1")])
      else
        if scenario `elem` ["clean-green", "hero-review"]
          then Right (PDict [("kind", PStr "pass")])
          else Left (OperatorError "unsupported scenario")
  pure
    ( PDict
        [ ("schema_version", PInt 1)
        , ("scenario", PStr scenario)
        , ("behavior", behavior)
        , ("review_lenses", PList (map PStr ["correctness", "test-quality", "risk"]))
        ]
    )

-- | @_clone(runner, root)@.
clone :: Operator -> FilePath -> IO FilePath
clone op root = do
  let checkout = root </> "demo-pr-readiness"
  void (run op ["git", "clone", "--origin", "origin", "https://github.com/" <> op.fixture.repository <> ".git", T.pack checkout] Nothing)
  void (run op ["git", "fetch", "origin", defaultBranch] (Just checkout))
  pure checkout

-- | @_assert_only(runner, checkout, admitted)@.
assertOnly :: Operator -> FilePath -> Set.Set Text -> IO ()
assertOnly op checkout admitted = do
  changed <- Set.fromList . splitlines <$> run op ["git", "diff", "--name-only", "origin/main...HEAD"] (Just checkout)
  when (changed /= admitted) $
    operatorError ("refusing unexpected changed paths: " <> pythonStrListRepr (Set.toAscList changed))

-- | @create(scenario, runner)@.
create :: Operator -> Text -> IO PV
create op scenario = do
  stampText <- op.stamp
  let branch = "hamsterdan/" <> scenario <> "-" <> stampText
      title = "Hamsterdan demo: " <> scenario
  (pr, head') <- temporaryDirectory op "hamsterdan-operator-" \temporary -> do
    checkout <- clone op temporary
    let inCheckout command = run op command (Just checkout)
    void (inCheckout ["git", "switch", "--create", branch, "origin/main"])
    prepared <- jsonOf op ["python", "tools/scenario_control.py", "prepare", scenario] (Just checkout)
    admitted <- if isDict prepared then py (getMaybe "admitted_changed_paths" prepared) else pure PNone
    admittedPaths <- case admitted of
      PList items
        | not (null items)
        , all (\case PStr s -> not (T.null s); _ -> False) items
        , any (pyEq (PStr scenarioPath)) items ->
            pure (Set.fromList [s | PStr s <- items])
      _ -> operatorError "scenario preparation returned malformed admitted paths"
    void (inCheckout ["python", "tools/scenario_control.py", "--attempt", "2"])
    modified <- splitlines <$> inCheckout ["git", "diff", "--name-only"]
    untracked <- splitlines <$> inCheckout ["git", "ls-files", "--others", "--exclude-standard"]
    let changed = Set.fromList (modified <> untracked)
    when (Set.null changed || not (changed `Set.isSubsetOf` admittedPaths)) $
      operatorError ("refusing unexpected changed paths: " <> pythonStrListRepr (Set.toAscList changed))
    void (inCheckout (["git", "add", "--"] <> Set.toAscList changed))
    void (inCheckout ["git", "commit", "-m", title])
    assertOnly op checkout changed
    void (inCheckout ["git", "push", "--set-upstream", "origin", branch])
    void
      ( inCheckout
          [ "gh"
          , "pr"
          , "create"
          , "--repo"
          , op.fixture.repository
          , "--base"
          , defaultBranch
          , "--head"
          , branch
          , "--title"
          , title
          , "--body"
          , "Controlled Hamsterdan qualification scenario. Do not merge automatically."
          ]
      )
    pr <- jsonOf op ["gh", "pr", "view", branch, "--repo", op.fixture.repository, "--json", "number,url,headRefName"] (Just checkout)
    when (scenario == "hero-review") do
      number <- py (subscriptKey "number" pr)
      void
        ( inCheckout
            [ "gh"
            , "api"
            , "--method"
            , "POST"
            , "/repos/" <> op.fixture.repository <> "/pulls/" <> pyStr number <> "/requested_reviewers"
            , "-f"
            , "reviewers[]=" <> op.fixture.heroReviewer
            ]
        )
    head' <- inCheckout ["git", "rev-parse", "HEAD"]
    pure (pr, head')
  number <- py (subscriptKey "number" pr)
  url <- py (subscriptKey "url" pr)
  pure
    ( PDict
        [ ("command", PStr "create")
        , ("ok", PBool True)
        , ("number", number)
        , ("url", url)
        , ("head", PStr head')
        , ("branch", PStr branch)
        , ("requested_reviewer", if scenario == "hero-review" then PStr op.fixture.heroReviewer else PNone)
        ]
    )

-- | @str(Path(path))@. A 'FilePath' holds an undecodable byte as its
-- lone surrogate (the file-system encoding round-trips it), which
-- 'fromCodePoints' keeps.
pathString :: FilePath -> FilePath
pathString = T.unpack . pathText . fromCodePoints

-- | @Path.read_text(encoding="utf-8")@: the @OSError@ a failed open
-- raises for the path, or the text.
readText :: FilePath -> IO Text
readText path = do
  outcome <- try (BS.readFile path)
  case outcome of
    Left (e :: IOException) -> ioException (fromCodePoints path) e >>= throwIO
    Right bytes -> py (decodeOutput bytes)

-- | @prepare_broker(runner)@.
prepareBroker :: Operator -> IO PV
prepareBroker op = do
  prepared <-
    jsonOf
      op
      [ "gh"
      , "pr"
      , "list"
      , "--repo"
      , op.fixture.repository
      , "--state"
      , "open"
      , "--search"
      , "in:title Hamsterdan broker identity cutover"
      , "--json"
      , "number,url,headRefName"
      , "--limit"
      , "10"
      ]
      Nothing
  items <- py (iterateValue prepared)
  matching <-
    fmap concat . forM items $ \item -> do
      ref <- py (getOr "headRefName" (PStr "") item)
      pure [item | "hamsterdan/broker-cutover-" `T.isPrefixOf` pyStr ref]
  case matching of
    item : _ -> do
      number <- py (subscriptKey "number" item)
      url <- py (subscriptKey "url" item)
      branch <- py (subscriptKey "headRefName" item)
      pure
        ( PDict
            [ ("command", PStr "prepare-broker")
            , ("ok", PBool True)
            , ("status", PStr "prepared")
            , ("changed", PBool False)
            , ("number", number)
            , ("url", url)
            , ("branch", branch)
            ]
        )
    [] -> do
      stampText <- op.stamp
      let branch = "hamsterdan/broker-cutover-" <> stampText
      outcome <- temporaryDirectory op "hamsterdan-broker-" \temporary -> do
        checkout <- clone op temporary
        let inCheckout command = run op command (Just checkout)
            sourcePath = checkout </> T.unpack brokerPath
            validatorPath = checkout </> T.unpack brokerValidatorPath
        source <- readText sourcePath
        validatorExists <- doesFileExist validatorPath
        validator <- if validatorExists then Just <$> readText validatorPath else pure Nothing
        let state = brokerStatus op source validator
        if state == "hamsterdan"
          then pure Nothing
          else do
            when (state /= "legacy" || T.count oldMarker source /= 2 || T.count legacyBrokerAuthorization source /= 1) $
              operatorError "default broker is malformed; refusing automated preparation"
            void (inCheckout ["git", "switch", "--create", branch, "origin/main"])
            let target = T.replace legacyBrokerAuthorization (fixtureBrokerAuthorization op.fixture) (T.replace oldMarker newMarker source)
            when
              ( brokerStatus op target Nothing /= "hamsterdan"
                  || T.count newMarker target /= 2
                  || T.count (fixtureBrokerAuthorization op.fixture) target /= 1
              )
              $ operatorError "broker transformation did not produce strict Hamsterdan grammar"
            BS.writeFile sourcePath (TE.encodeUtf8 target)
            void (inCheckout ["git", "add", "--", brokerPath])
            void (inCheckout ["git", "commit", "-m", "Hamsterdan broker identity cutover"])
            assertOnly op checkout (Set.singleton brokerPath)
            void (inCheckout ["git", "push", "--set-upstream", "origin", branch])
            void
              ( inCheckout
                  [ "gh"
                  , "pr"
                  , "create"
                  , "--repo"
                  , op.fixture.repository
                  , "--base"
                  , defaultBranch
                  , "--head"
                  , branch
                  , "--title"
                  , "Hamsterdan broker identity cutover"
                  , "--body"
                  , "Merge only after the Hamsterdan App host is ready; never run legacy and App writers together."
                  ]
              )
            Just <$> jsonOf op ["gh", "pr", "view", branch, "--repo", op.fixture.repository, "--json", "number,url,headRefName"] (Just checkout)
      case outcome of
        Nothing -> pure (PDict [("command", PStr "prepare-broker"), ("ok", PBool True), ("status", PStr "current"), ("changed", PBool False)])
        Just pr -> do
          number <- py (subscriptKey "number" pr)
          url <- py (subscriptKey "url" pr)
          pure
            ( PDict
                [ ("command", PStr "prepare-broker")
                , ("ok", PBool True)
                , ("status", PStr "prepared")
                , ("changed", PBool True)
                , ("number", number)
                , ("url", url)
                , ("branch", PStr branch)
                ]
            )

-- ---------------------------------------------------------------------------
-- Markers

-- | A pattern anchored with @\\Z@ can only match a suffix that starts at an
-- HTML comment opener; the leftmost such suffix is what @search@ finds.
suffixMatch :: (Text -> Maybe a) -> Text -> Maybe a
suffixMatch grammar body = listToMaybe (mapMaybe (grammar . snd) (T.breakOnAll "<!-- " body))

isLowerHex :: Char -> Bool
isLowerHex c = isDigit c || (c >= 'a' && c <= 'f')

-- | @[A-Za-z0-9][A-Za-z0-9._:-]{0,127}@.
validOperation :: Text -> Bool
validOperation op = case T.uncons op of
  Just (c, more) -> asciiAlnum c && T.length more <= 127 && T.all (\x -> asciiAlnum x || x `elem` ("._:-" :: String)) more
  Nothing -> False

-- | @MARKER_RE@: identity, run, head, operation.
markerGrammar :: Text -> Maybe (Text, Text, Text, Text)
markerGrammar s = do
  r1 <- T.stripPrefix "<!-- " s
  (identity, r2) <- (("hamsterdan-rerun",) <$> T.stripPrefix "hamsterdan-rerun" r1) <|> (("impetus-rerun",) <$> T.stripPrefix "impetus-rerun" r1)
  r3 <- T.stripPrefix " run=" r2
  let (runId, r4) = T.span isDigit r3
  case T.uncons runId of
    Just (first, _) | first /= '0' -> pure ()
    _ -> Nothing
  r5 <- T.stripPrefix " head=" r4
  let (hd, r6) = T.splitAt 40 r5
  unless (T.length hd == 40 && T.all isLowerHex hd) Nothing
  r7 <- T.stripPrefix " operation=" r6
  op <- T.stripSuffix " -->" r7
  unless (validOperation op) Nothing
  pure (identity, runId, hd, op)

-- | @IMMUTABLE_RE@: kind, operation, head.
immutableGrammar :: Text -> Maybe (Text, Text, Text)
immutableGrammar s = do
  r1 <- T.stripPrefix "<!-- hamsterdan:" s
  (kind, r2) <-
    (("finding",) <$> T.stripPrefix "finding" r1)
      <|> (("reminder",) <$> T.stripPrefix "reminder" r1)
      <|> (("readiness",) <$> T.stripPrefix "readiness" r1)
  r3 <- T.stripPrefix " operation=" r2
  let (op, r4) = T.break (== ' ') r3
  unless (validOperation op) Nothing
  r5 <- T.stripPrefix " head=" r4
  hd <- T.stripSuffix " -->" r5
  unless (T.length hd == 40 && T.all isLowerHex hd) Nothing
  pure (kind, op, hd)

-- | The lines of a text split at @\\n@ only, with each line's offset.
linesWithOffsets :: Text -> [(Int, Text)]
linesWithOffsets body = go 0 (T.splitOn "\n" body)
  where
    go _ [] = []
    go offset (line : more) = (offset, line) : go (offset + T.length line + 1) more

-- | The start offsets of @BATCH_FINDING_RE.finditer(body)@.
batchFindingStarts :: Text -> [Int]
batchFindingStarts body = go (linesWithOffsets body)
  where
    go ((offset, header) : rest@((_, severity) : more))
      | headerLine header && severityLine severity = offset : go more
      | otherwise = go rest
    go _ = []
    headerLine line = isJust do
      r1 <- T.stripPrefix "### `" line
      let (identifier, r2) = T.span idChar r1
      case T.uncons identifier of
        Just (c, more) | asciiAlnum c && T.length more <= 47 -> pure ()
        _ -> Nothing
      r3 <- T.stripPrefix "` \x2014 " r2
      unless (not (T.null r3)) Nothing
    idChar c = asciiAlnum c || c `elem` ("._-" :: String)
    severityLine line = isJust do
      r1 <- T.stripPrefix "**blocking**" line <|> T.stripPrefix "advisory" line
      r2 <- T.stripPrefix " \xB7 severity: **" r1
      level <- T.stripSuffix "**" r2
      unless (not (T.null level) && not (T.any (== '*') level)) Nothing

-- | @PRIMARY_LOCATION_RE.search(section)@: path and line.
primaryLocation :: Text -> Maybe (Text, Text)
primaryLocation section = listToMaybe (mapMaybe (location . snd) (linesWithOffsets section))
  where
    location line = do
      r1 <- T.stripPrefix "Primary location: `" line
      inner <- T.stripSuffix "`" r1
      unless (not (T.any (== '`') inner)) Nothing
      let (pathPart, colonAndLine) = T.breakOnEnd ":" inner
      path <- T.stripSuffix ":" pathPart
      unless (not (T.null path)) Nothing
      case T.uncons colonAndLine of
        Just (c, _) | c /= '0' && T.all isDigit colonAndLine -> pure (path, colonAndLine)
        _ -> Nothing

-- | @FINDINGS_DIGEST_RE.search(body) is not None@.
hasFindingsDigest :: Text -> Bool
hasFindingsDigest body = any (digestLine . snd) (linesWithOffsets body)
  where
    digestLine line = case T.stripPrefix "<!-- hamsterdan:findings-digest " line >>= T.stripSuffix " -->" of
      Just digest -> T.length digest == 64 && T.all isLowerHex digest
      Nothing -> False

-- | @_safe_comment(comment, bot_login, inline=...)@: the comment's
-- coordinate-only projection (if it carries a Hamsterdan marker) and its
-- markers.
safeComment :: PV -> Text -> Bool -> IO (Maybe PV, [PV])
safeComment comment botLogin inline = do
  body <- pyStr <$> py (getOr "body" (PStr "") comment)
  owner <- pyStr <$> py (getOr "user" (PDict []) comment >>= getOr "login" (PStr ""))
  url <- py (getMaybe "html_url" comment)
  identifier <- py (getMaybe "id" comment)
  let dashboard = "<!-- hamsterdan:dashboard -->" `T.isSuffixOf` body
      immutable = suffixMatch immutableGrammar body
      immutableMarkers =
        [ PDict
            [ ("type", PStr kind)
            , ("operation", PStr op)
            , ("head", PStr hd)
            , ("comment_id", identifier)
            , ("url", url)
            , ("owner", PStr owner)
            ]
        | Just (kind, op, hd) <- [immutable]
        ]
      rerun = suffixMatch markerGrammar body
  rerunMarkers <- forM (maybe [] pure rerun) \(identity, runId, hd, op) -> do
    runNumber <- py (intText runId)
    pure
      ( PDict
          [ ("type", PStr identity)
          , ("run_id", PInt runNumber)
          , ("head", PStr hd)
          , ("operation", PStr op)
          , ("comment_id", identifier)
          , ("url", url)
          , ("owner", PStr owner)
          ]
      )
  let kind =
        (case rerun of Just (identity, _, _, _) | identity == newMarker -> Just newMarker; _ -> Nothing)
          <|> (case immutable of Just (k, _, _) -> Just k; Nothing -> Nothing)
          <|> (if dashboard then Just "dashboard" else Nothing)
      markers = immutableMarkers <> rerunMarkers
  case kind of
    Nothing -> pure (Nothing, markers)
    Just kindText -> do
      let base =
            [ ("id", identifier)
            , ("url", url)
            , ("owner", PStr owner)
            , ("type", PStr kindText)
            , ("inline", PBool inline)
            , ("owned_by_app", PBool (pyCasefold owner == pyCasefold botLogin))
            ]
      finding <-
        if kindText /= "finding"
          then pure []
          else do
            let batch =
                  not inline
                    && "## Hamsterdan review findings\n\n" `T.isPrefixOf` body
                    && hasFindingsDigest body
                starts = if batch then batchFindingStarts body else []
                ends = drop 1 starts <> [T.length body]
                sections = case zipWith (\start end -> T.take (end - start) (T.drop start body)) starts ends of
                  [] -> [body]
                  found -> found
            locations <-
              if inline
                then do
                  primary <- py (getMaybe "line" comment)
                  line <- if truthy primary then pure primary else py (getMaybe "original_line" comment)
                  path <- pyStr <$> py (getOr "path" (PStr "") comment)
                  pure [case line of PInt n | n > 0 -> Just (path, n); _ -> Nothing]
                else forM sections \section -> case primaryLocation section of
                  Just (path, lineText) -> Just . (path,) <$> py (intText lineText)
                  Nothing -> pure Nothing
            let paired = zip locations sections
                count = PInt . fromIntegral . length . filter id
            pure
              [ ("finding_count", PInt (fromIntegral (length sections)))
              , ("hero_finding_count", count [maybe False (`elem` heroFindingLocations) l | l <- locations])
              , ( "suggestion_count"
                , count [l == Just heroSuggestionLocation && "```suggestion\n" `T.isInfixOf` s | (l, s) <- paired]
                )
              , ("conceptual_count", count [l == Just heroConceptualLocation | l <- locations])
              , ( "related_location_count"
                , count [l == Just heroRelatedLocation && "\nRelated locations:\n- " `T.isInfixOf` s | (l, s) <- paired]
                )
              ]
      pure (Just (PDict (base <> finding)), markers)

-- ---------------------------------------------------------------------------
-- Inspection

-- | The keyword arguments of @inspect@.
data InspectOptions = InspectOptions
  { botLogin :: Text
  , expectHeroReview :: Bool
  , expectReadiness :: Bool
  }

defaultInspectOptions :: InspectOptions
defaultInspectOptions = InspectOptions {botLogin = appBotLogin, expectHeroReview = False, expectReadiness = True}

field :: Text -> PV -> PV
field key = \case
  PDict members -> fromMaybe PNone (lookup key members)
  _ -> PNone

-- | @inspect(pr_number, runner, bot_login=..., expect_hero_review=...,
-- expect_readiness=...)@.
inspect :: Operator -> Integer -> InspectOptions -> IO PV
inspect op prNumber options = do
  when (prNumber < 1) $ operatorError "PR number must be positive"
  let number = T.pack (show prNumber)
      prefix = "/repos/" <> op.fixture.repository
  pull <- api op (prefix <> "/pulls/" <> number)
  comments <- api op (prefix <> "/issues/" <> number <> "/comments?per_page=100")
  reviewComments <- api op (prefix <> "/pulls/" <> number <> "/comments?per_page=100")
  head' <- pyStr <$> py (getOr "head" (PDict []) pull >>= getOr "sha" (PStr ""))
  commit <- api op (prefix <> "/commits/" <> head')
  runsValue <- api op (prefix <> "/actions/runs?event=pull_request&head_sha=" <> head' <> "&per_page=100")
  issueFound <- forM (case comments of PList items -> take 100 items; _ -> []) \comment -> safeComment comment options.botLogin False
  reviewFound <- forM (case reviewComments of PList items -> take 100 items; _ -> []) \comment -> safeComment comment options.botLogin True
  let found = issueFound <> reviewFound
      safeComments = [safe | (Just safe, _) <- found]
      markers = concatMap snd found
  runItems <- py (getOr "workflow_runs" (PList []) runsValue >>= sliceItems 20)
  runs <- forM runItems \item -> do
    attempt <- py (getOr "run_attempt" (PInt 1) item >>= pyInt)
    runId <- py (subscriptKey "id" item)
    jobsValue <- api op (prefix <> "/actions/runs/" <> pyStr runId <> "/attempts/" <> T.pack (show attempt) <> "/jobs?per_page=100")
    let get key = py (getMaybe key item)
    identifier <- get "id"
    name <- get "name"
    headSha <- get "head_sha"
    status <- get "status"
    conclusion <- get "conclusion"
    htmlUrl <- get "html_url"
    jobItems <- py (getOr "jobs" (PList []) jobsValue >>= sliceItems 100)
    jobs <- forM jobItems \job -> do
      values <- py (mapM (`getMaybe` job) ["id", "name", "status", "conclusion"])
      pure (PDict (zip ["id", "name", "status", "conclusion"] values))
    pure
      ( PDict
          [ ("id", identifier)
          , ("name", name)
          , ("attempt", PInt attempt)
          , ("head", headSha)
          , ("status", status)
          , ("conclusion", conclusion)
          , ("url", htmlUrl)
          , ("jobs", PList jobs)
          ]
      )
  let typeOf item = field "type" item
      ownedByApp item = truthy (field "owned_by_app" item)
      newMarkers = [item | item <- markers, pyEq (typeOf item) (PStr newMarker)]
      oldMarkers = [item | item <- markers, pyEq (typeOf item) (PStr oldMarker)]
      owned = not (null safeComments) && all ownedByApp safeComments
      markerOwned = all (\item -> pyCasefold (pyStr (field "owner" item)) == pyCasefold options.botLogin) newMarkers
      kinds = Set.fromList [pyStr (typeOf item) | item <- safeComments, ownedByApp item]
  baseRepoId <- py (getOr "base" (PDict []) pull >>= getOr "repo" (PDict []) >>= getMaybe "id")
  let readinessPresent = "readiness" `Set.member` kinds
      checks =
        [ check "pull_identity" (pyEq baseRepoId (PInt op.fixture.repositoryId)) baseRepoId
        , check "hamsterdan_comment_ownership" (owned && markerOwned) (PStr options.botLogin)
        , check "dashboard_present" ("dashboard" `Set.member` kinds) (PBool ("dashboard" `Set.member` kinds))
        , check
            (if options.expectReadiness then "readiness_advisory_present" else "readiness_advisory_absent")
            (readinessPresent == options.expectReadiness)
            (PBool readinessPresent)
        , check "legacy_markers_absent" (null oldMarkers) (PInt (fromIntegral (length oldMarkers)))
        , check "workflow_heads_match" (all (\r -> pyEq (field "head" r) (PStr head')) runs) (PStr head')
        ]
      findings = [item | item <- safeComments, pyEq (typeOf item) (PStr "finding"), ownedByApp item]
      total key = sum [n | item <- findings, PInt n <- [field key item]]
      heroChecks
        | options.expectHeroReview =
            let findingCount = total "hero_finding_count"
                suggestionCount = total "suggestion_count"
                conceptualCount = total "conceptual_count"
                relatedCount = total "related_location_count"
             in [ check "hero_findings" (findingCount >= 3) (PInt findingCount)
                , check "hero_suggestion" (suggestionCount > 0) (PInt suggestionCount)
                , check "hero_conceptual" (conceptualCount > 0) (PInt conceptualCount)
                , check "hero_related_locations" (relatedCount > 0) (PInt relatedCount)
                ]
        | otherwise = []
      allChecks = checks <> heroChecks
  authored <- py (getOr "commit" (PDict []) commit)
  commitAuthor <- py (getMaybe "author" authored)
  commitCommitter <- py (getMaybe "committer" authored)
  pullUrl <- py (getMaybe "html_url" pull)
  pullState <- py (getMaybe "state" pull)
  pullDraft <- py (getMaybe "draft" pull)
  headRef <- py (getOr "head" (PDict []) pull >>= getMaybe "ref")
  baseRef <- py (getOr "base" (PDict []) pull >>= getMaybe "ref")
  authenticatedAuthor <- loginOf "author" commit
  authenticatedCommitter <- loginOf "committer" commit
  pure
    ( PDict
        [ ("command", PStr "inspect")
        , ("repository", PStr op.fixture.repository)
        , ("number", PInt prNumber)
        , ( "pull"
          , PDict
              [ ("url", pullUrl)
              , ("state", pullState)
              , ("draft", pullDraft)
              , ("head", PStr head')
              , ("head_ref", headRef)
              , ("base_ref", baseRef)
              ]
          )
        , ("comments", PList (take 100 safeComments))
        , ("markers", PList (take 100 markers))
        , ("runs", PList runs)
        , ( "attribution"
          , PDict
              [ ("commit_author", commitAuthor)
              , ("commit_committer", commitCommitter)
              , ("authenticated_author", authenticatedAuthor)
              , ("authenticated_committer", authenticatedCommitter)
              ]
          )
        , ("checks", PList allChecks)
        , ("ok", PBool (all passed allChecks))
        ]
    )
  where
    loginOf key commit = do
      value <- py (getMaybe key commit)
      if isDict value then py (getOr key (PDict []) commit >>= getMaybe "login") else pure PNone

-- | @_authority_policy(rules)@: strict base, required approvals,
-- conversation resolution.
authorityPolicy :: PV -> Either OperatorError (Bool, Integer, Bool)
authorityPolicy rules = case rules of
  PList items
    | all isDict items ->
        if length items >= 100
          then Left (OperatorError "GitHub authority policy exceeds one bounded page")
          else foldl step (Right (False, 0, False)) items
  _ -> malformed
  where
    malformed = Left (OperatorError "GitHub authority policy evidence is malformed")
    step acc rule = do
      (strict, approvals, resolution) <- acc
      let ruleType = field "type" rule
          parameters = field "parameters" rule
      if pyEq ruleType (PStr "required_status_checks")
        then case parameters of
          PDict _
            | PBool policy <- field "strict_required_status_checks_policy" parameters
            , PList required <- field "required_status_checks" parameters -> do
                forM_ required \case
                  PDict check' | Just (PStr context) <- lookup "context" check', not (T.null context) -> Right ()
                  _ -> malformed
                Right (strict || policy, approvals, resolution)
          _ -> malformed
        else
          if pyEq ruleType (PStr "pull_request")
            then
              let count = if isDict parameters then field "required_approving_review_count" parameters else PNone
                  conversations = if isDict parameters then field "required_review_thread_resolution" parameters else PNone
               in case (count, conversations) of
                    (PInt n, PBool c) | n >= 0 -> Right (strict, max approvals n, resolution || c)
                    _ -> malformed
            else Right (strict, approvals, resolution)

-- | @_latest_reviews(value)@: each reviewer's latest decisive review, in
-- case-folded reviewer order, with dismissals as tombstones.
latestReviews :: PV -> Either OperatorError [(Text, Text)]
latestReviews value = case value of
  PList items
    | all isDict items ->
        if length items >= 100
          then Left (OperatorError "GitHub review authority exceeds one bounded page")
          else do
            latest <- foldl step (Right ([], Map.empty)) items
            let (order, table) = latest
                folded = [table Map.! key | key <- reverse order]
            Right
              [ (login, state)
              | (login, state, _, _) <- sortOn (\(login, _, _, _) -> pyCasefold login) folded
              , state /= "DISMISSED"
              ]
  _ -> malformed
  where
    malformed = Left (OperatorError "GitHub review authority evidence is malformed")
    step acc review = do
      (order, table) <- acc
      let login = case field "user" review of
            user@(PDict _) -> field "login" user
            _ -> PNone
      case (login, field "state" review, field "submitted_at" review, field "id" review) of
        (PStr loginText, PStr state, PStr submitted, PInt identifier) | not (T.null loginText) -> do
          let normalized = pyUpper state
              key = pyCasefold loginText
          if normalized `notElem` ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
            then Right (order, table)
            else case Map.lookup key table of
              Nothing -> Right (key : order, Map.insert key (loginText, normalized, submitted, identifier) table)
              Just (_, _, previousSubmitted, previousIdentifier)
                | (submitted, identifier) > (previousSubmitted, previousIdentifier) ->
                    Right (order, Map.insert key (loginText, normalized, submitted, identifier) table)
                | otherwise -> Right (order, table)
        _ -> malformed

-- | @_review_facts(pr_number, runner)@: unresolved threads and the review
-- decision.
reviewFacts :: Operator -> Integer -> IO (Integer, PV)
reviewFacts op prNumber = do
  let (owner, rest) = T.breakOn "/" op.fixture.repository
  value <-
    jsonOf
      op
      [ "gh"
      , "api"
      , "graphql"
      , "-f"
      , "query=" <> authorityReviewFacts
      , "-F"
      , "owner=" <> owner
      , "-F"
      , "repository=" <> T.drop 1 rest
      , "-F"
      , "number=" <> T.pack (show prNumber)
      ]
      Nothing
  let malformed :: IO a
      malformed = operatorError "GitHub review-thread authority evidence is malformed"
      dig = either (const Nothing) Just . foldl (\acc key -> acc >>= subscriptKey key) (Right value)
  (decision, nodes, page) <- case dig ["data", "repository", "pullRequest"] of
    Nothing -> malformed
    Just pull -> case (subscriptKey "reviewDecision" pull, subscriptKey "reviewThreads" pull) of
      (Right decision, Right threads) -> case (subscriptKey "nodes" threads, subscriptKey "pageInfo" threads) of
        (Right nodes, Right page) -> pure (decision, nodes, page)
        _ -> malformed
      _ -> malformed
  let validNode node = case node of
        PDict _ -> isStr (field "id" node) && isBool (field "isResolved" node)
        _ -> False
  nodeItems <- case nodes of
    PList items | all validNode items -> pure items
    _ -> malformed
  hasNext <- case page of
    PDict _ | PBool b <- field "hasNextPage" page -> pure b
    _ -> malformed
  knownDecision <- py (inSet decision [PNone, PStr "APPROVED", PStr "CHANGES_REQUESTED", PStr "REVIEW_REQUIRED"])
  unless knownDecision malformed
  when hasNext $ operatorError "GitHub review-thread authority exceeds one bounded page"
  pure (fromIntegral (length [() | node <- nodeItems, field "isResolved" node `pyEqBool` False]), decision)
  where
    pyEqBool v b = case v of PBool x -> x == b; _ -> False

-- | @inspect_authority(pr_number, expected, runner)@: inspect real GitHub
-- authority without copying provider objects.
inspectAuthority :: Operator -> Integer -> Text -> IO PV
inspectAuthority op prNumber expected = do
  when (prNumber < 1) $ operatorError "PR number must be positive"
  unless (expected `elem` authorityExpectations) $ operatorError "unsupported authority expectation"
  let number = T.pack (show prNumber)
      prefix = "/repos/" <> op.fixture.repository
      dig root keys = either (const Nothing) Just (foldl (\acc key -> acc >>= subscriptKey key) (Right root) keys)
      isHexSha s = T.length s == 40 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) s
  pull <- api op (prefix <> "/pulls/" <> number)
  unless (isDict pull) $ operatorError "GitHub pull-request authority evidence is malformed"
  (headSha, baseRef, author) <- case (dig pull ["head", "sha"], dig pull ["base", "ref"], dig pull ["user", "login"]) of
    (Just (PStr sha), Just (PStr ref), Just (PStr login))
      | isHexSha sha && not (T.null ref) && not (T.null login) -> pure (sha, ref, login)
    _ -> operatorError "GitHub pull-request authority evidence is malformed"
  let encodedBase = urlQuote baseRef
  reference <- api op (prefix <> "/git/ref/heads/" <> encodedBase)
  baseSha <- case dig reference ["object", "sha"] of
    Just (PStr sha) | isHexSha sha -> pure sha
    _ -> operatorError "GitHub base authority evidence is malformed"
  comparison <- api op (prefix <> "/compare/" <> baseSha <> "..." <> headSha)
  behind <- case (if isDict comparison then field "behind_by" comparison else PNone) of
    PInt n | n >= 0 -> pure n
    _ -> operatorError "GitHub comparison authority evidence is malformed"
  (strict, required, resolution) <-
    api op (prefix <> "/rules/branches/" <> encodedBase <> "?per_page=100") >>= either throwIO pure . authorityPolicy
  requestedValue <- api op (prefix <> "/pulls/" <> number <> "/requested_reviewers")
  let requestedUsers = if isDict requestedValue then field "users" requestedValue else PNone
      requestedTeams = if isDict requestedValue then field "teams" requestedValue else PNone
  (users, teamItems) <- case (requestedUsers, requestedTeams) of
    (PList us, PList ts) | all isDict us && all isDict ts -> pure (us, ts)
    _ -> operatorError "GitHub requested-reviewer authority evidence is malformed"
  let requested = sort [login | user <- users, PStr login <- [field "login" user], not (T.null login)]
      teams = sort [slug | team <- teamItems, PStr slug <- [field "slug" team], not (T.null slug)]
  reviews <- api op (prefix <> "/pulls/" <> number <> "/reviews?per_page=100") >>= either throwIO pure . latestReviews
  let approvals = sort [login | (login, state) <- reviews, state == "APPROVED", pyCasefold login /= pyCasefold author]
      changes = sort [login | (login, state) <- reviews, state == "CHANGES_REQUESTED"]
  (unresolved, reviewDecision) <- reviewFacts op prNumber
  let mergeable = field "mergeable" pull
      mergeableState = field "mergeable_state" pull
      draftValue = field "draft" pull
  knownMergeable <- py (inSet mergeable [PBool True, PBool False, PNone])
  draft <- case (knownMergeable, mergeableState, draftValue) of
    (True, PStr _, PBool d) -> pure d
    _ -> operatorError "GitHub mergeability authority evidence is malformed"
  case mergeable of
    PNone -> operatorError "GitHub mergeability authority is indeterminate; retry inspection"
    _ -> pure ()
  finalPull <- api op (prefix <> "/pulls/" <> number)
  finalReference <- api op (prefix <> "/git/ref/heads/" <> encodedBase)
  finalBasis <- case (dig finalPull ["head", "sha"], dig finalPull ["base", "ref"], dig finalReference ["object", "sha"]) of
    (Just a, Just b, Just c) -> pure (a, b, c)
    _ -> operatorError "GitHub final authority basis is malformed"
  let (finalHead, finalBase, finalSha) = finalBasis
  unless (pyEq finalHead (PStr headSha) && pyEq finalBase (PStr baseRef) && pyEq finalSha (PStr baseSha)) $
    operatorError "GitHub authority changed during inspection"
  let mergeableState' = case mergeableState of PStr s -> s; _ -> ""
      isTrue = \case PBool True -> True; _ -> False
      isFalse = \case PBool False -> True; _ -> False
      authority =
        PDict
          [ ("draft", PBool draft)
          , ("head", PStr (T.toLower headSha))
          , ("base", PStr (T.toLower baseSha))
          , ("base_ref", PStr baseRef)
          , ("behind_by", PInt behind)
          , ("mergeable", mergeable)
          , ("mergeable_state", mergeableState)
          , ("strict_base", PBool strict)
          , ("required_approvals", PInt required)
          , ("conversation_resolution", PBool resolution)
          , ("requested_reviewers", PList (map PStr requested))
          , ("requested_teams", PList (map PStr teams))
          , ( "latest_reviews"
            , PList [PDict [("reviewer", PStr login), ("state", PStr state)] | (login, state) <- sortOn fst reviews]
            )
          , ("distinct_approvals", PList (map PStr approvals))
          , ("changes_requested", PList (map PStr changes))
          , ("unresolved_threads", PInt unresolved)
          , ("review_decision", reviewDecision)
          ]
      approved = pyEq reviewDecision (PStr "APPROVED")
      expectation = case expected of
        "non-draft" -> not draft
        "strict-stale" -> not draft && strict && behind > 0 && isTrue mergeable
        "conflict" -> not draft && (isFalse mergeable || mergeableState' == "dirty")
        "review-requested" -> not (null requested && null teams)
        "changes-requested" -> not (null changes)
        "required-approval" -> required > 0 && approved
        "unresolved-thread" -> resolution && unresolved > 0
        _ -> null requested && null teams && null changes && (required == 0 || approved) && unresolved == 0
      checkValue = check expected expectation authority
  url <- py (getMaybe "html_url" pull)
  pure
    ( PDict
        [ ("command", PStr "inspect-authority")
        , ("repository", PStr op.fixture.repository)
        , ("number", PInt prNumber)
        , ("url", url)
        , ("expectation", PStr expected)
        , ("authority", authority)
        , ("checks", PList [checkValue])
        , ("ok", PBool expectation)
        ]
    )

-- ---------------------------------------------------------------------------
-- Command line

-- | @parser()@, decoded: the subcommand's name with its 'OperatorCommand'.
operatorParser :: ArgumentParser (Text, OperatorCommand)
operatorParser = operatorParserFor hbNetworkFixture

-- | @parser()@ over a fixture: @inspect --bot-login@ defaults to its bot.
operatorParserFor :: Fixture -> ArgumentParser (Text, OperatorCommand)
operatorParserFor fixture =
  ArgumentParser
    { prog = "python -m hamsterdan.operator"
    , description = Nothing
    , arguments = Argparse.subcommands "command" [(name, (name,) <$> arguments) | (name, arguments) <- operatorCommands fixture]
    }

-- | The decoded command line: each subcommand with what it reads.
data OperatorCommand
  = -- | @preflight [--health-url]@.
    Preflight (Maybe Text)
  | -- | @create --scenario@.
    Create Text
  | PrepareBroker
  | -- | @inspect --pr@ with its expectations.
    Inspect Integer InspectOptions
  | -- | @inspect-authority --pr --expect@.
    InspectAuthority Integer Text
  | -- | @qualification-setup --credential-file --target-file --spent-marker@.
    QualificationSetup FilePath FilePath FilePath

-- | The subcommands, in the reference's order: each name with its
-- arguments, which declare its parser and decode its namespace. Required
-- options and choices are enforced by @parse_args@ (status 2).
operatorCommands :: Fixture -> [(Text, Arg OperatorCommand)]
operatorCommands fixture =
  [ ("preflight", Preflight <$> Argparse.option Argparse.str ["--health-url"] [])
  , ("create", Create <$> Argparse.required (Argparse.oneOf creatableScenarios) ["--scenario"] [])
  , ("prepare-broker", pure PrepareBroker)
  ,
    ( "inspect"
    , inspectCommand
        <$> pr
        <*> Argparse.defaulted Argparse.str ["--bot-login"] (fixtureBotLogin fixture) []
        <*> Argparse.flag ["--expect-hero-review"] []
        <*> Argparse.defaulted (Argparse.choice [("present", True), ("absent", False)]) ["--expect-readiness"] True []
    )
  , ("inspect-authority", InspectAuthority <$> pr <*> Argparse.required (Argparse.oneOf authorityExpectations) ["--expect"] [])
  , ("qualification-setup", QualificationSetup <$> file ["--credential-file"] <*> file ["--target-file"] <*> file ["--spent-marker"])
  ]
  where
    pr = Argparse.required Argparse.int ["--pr"] []
    inspectCommand prNumber botLogin expectHeroReview expectReadiness =
      Inspect prNumber InspectOptions {botLogin, expectHeroReview, expectReadiness}
    file strings = T.unpack <$> Argparse.required Argparse.path strings []

-- | Where the command line reads and writes.
data OperatorEnvironment = OperatorEnvironment
  { environment :: Map String String
  , output :: Handle
  , errors :: Handle
  , operator :: Operator
  , setupRunner :: SetupRunner
  }

productionEnvironment :: IO OperatorEnvironment
productionEnvironment = do
  environment <- Map.fromList <$> getEnvironment
  pure OperatorEnvironment {environment, output = stdout, errors = stderr, operator = defaultOperator, setupRunner = setupSubprocess}

-- | @main()@: parse, dispatch, print the sorted JSON object, and exit 0
-- when it says @ok@. An exception the reference does not catch prints the
-- last line of its traceback and exits 1.
runOperator :: OperatorEnvironment -> [Text] -> IO ExitCode
runOperator env argv = do
  formatting <- formattingFor env.environment env.output
  let fixture = env.operator.fixture
  case parse formatting (operatorParserFor fixture) argv of
    Exited status printed problems -> do
      printed' <- printOut env printed
      emit env.errors problems
      pure (if not printed' then ExitFailure 1 else if status == 0 then ExitSuccess else ExitFailure status)
    Parsed (name, command) -> dispatch name command
  where
    op = env.operator
    dispatch name command = do
      outcome <- try do
        result <- try case command of
          Preflight healthUrl -> preflight op healthUrl
          Create scenario -> create op scenario
          PrepareBroker -> prepareBroker op
          Inspect prNumber options -> inspect op prNumber options
          InspectAuthority prNumber expected -> inspectAuthority op prNumber expected
          QualificationSetup credentialFile targetFile spentMarker ->
            qualificationSetup env.setupRunner credentialFile targetFile spentMarker
        let value = case result of
              Right v -> v
              Left (OperatorError message) -> PDict [("command", PStr name), ("ok", PBool False), ("error", PStr message)]
        line <- raiseEither (PyV.dumpsLine value)
        pure (line, truthy (field "ok" value))
      case outcome of
        Right (line, ok) -> do
          BS.hPut env.output (line <> "\n")
          hFlush env.output
          pure (if ok then ExitSuccess else ExitFailure 1)
        Left (e :: SomeException)
          | Just (problem :: PythonException) <- fromException e -> do
              emit env.errors (errorLine problem <> "\n")
              pure (ExitFailure 1)
          | otherwise -> do
              emit env.errors (T.pack (show e) <> "\n")
              pure (ExitFailure 1)

-- | A write to @sys.stderr@, whose @backslashreplace@ handler spells a
-- lone surrogate as its escape.
emit :: Handle -> Text -> IO ()
emit handle text = BS.hPut handle (utf8BackslashReplace text)

-- | A write to @sys.stdout@, which encodes strict UTF-8: a lone surrogate
-- raises @UnicodeEncodeError@ before anything is written, and the
-- interpreter reports it as uncaught. 'False' when it did.
printOut :: OperatorEnvironment -> Text -> IO Bool
printOut env text = case utf8Encode text of
  Right bytes -> True <$ BS.hPut env.output bytes
  Left failure -> False <$ emit env.errors (errorLine failure <> "\n")



-- | The external programs the ported tests stand in for, run as modes of
-- the test binary itself (shell wrappers @exec@ it with a mode flag):
--
-- * @--fake-provider ROOT NAME ARG...@: a scripted @gh@, @git@, @curl@ or
--   @python@ for the command-line differential. It logs its normalized
--   argument vector and working directory to @ROOT/calls.log@ and answers
--   from @ROOT/responses.json@ by the normalized command line (the nth
--   call of a command line gets the nth scripted answer, the last one
--   repeating; an unscripted command exits 1 silently). @git clone@ first
--   copies the scripted template checkout to its destination.
-- * @--fake-op ARG...@: @test_secret_launch.py@'s fake 1Password CLI.
-- * @--launch-child@: @test_secret_launch.py@'s application child.
module Fakes
  ( dispatch
  , normalizeText
  , wrapperScript
  , writeExecutable
  ) where

import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAlphaNum, isDigit)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Config (HostConfig (..), fromEnvironment, revealSecret)
import Petrus.Json (Json (..), compact, dumps, parseJson, pythonLoads)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getHomeDirectory
  , listDirectory
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (isAbsolute, (</>))
import System.IO (hClose, hPutStr, hPutStrLn, stderr, stdout)
import System.Posix.Files (setFileMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), defaultFileFlags, fdToHandle, openFd)
import System.Posix.Signals (raiseSignal)
import System.Process.Typed (proc, runProcess, setEnv)

-- | Run a fake mode when the arguments name one; otherwise return.
dispatch :: [String] -> IO Bool
dispatch = \case
  "--fake-provider" : root : name : arguments -> fakeProvider root name arguments >> pure True
  "--fake-op" : arguments -> fakeOp arguments >> pure True
  ["--launch-child"] -> launchChild >> pure True
  _ -> pure False

-- | @#!/bin/sh@ wrapper that runs this test binary in a fake mode.
wrapperScript :: FilePath -> [String] -> String
wrapperScript binary arguments =
  "#!/bin/sh\nexec " <> unwords (map quote (binary : arguments)) <> " \"$@\"\n"
  where
    quote s = "'" <> concatMap (\c -> if c == '\'' then "'\"'\"'" else [c]) s <> "'"

-- | Write an executable script (mode 0755) through a close-on-exec
-- descriptor. A descriptor from 'writeFile' is inherited by every process
-- another thread spawns while it is open (the differential cases run in
-- parallel), and while such a process holds the script open for writing,
-- executing the script fails with ETXTBSY. Python's PATH search then goes
-- on to the next @gh@ on PATH (a CI runner's real one) instead of the fake.
writeExecutable :: FilePath -> String -> IO ()
writeExecutable path contents = do
  fd <- openFd path WriteOnly defaultFileFlags {creat = Just 0o755, trunc = True, cloexec = True}
  handle <- fdToHandle fd
  hPutStr handle contents `finally` hClose handle
  setFileMode path 0o755

-- ---------------------------------------------------------------------------
-- The scripted provider

-- | Replace what legitimately differs between the two sides of a
-- differential case: the side's root directory, the random suffixes of
-- temporary directories, and UTC time stamps.
normalizeText :: Text -> Text -> Text
normalizeText root = stamps . temporaries . T.replace root "<root>"
  where
    temporaries text = foldl suffix text ["hamsterdan-operator-", "hamsterdan-broker-", "hamsterdan-qualification-"]
    suffix text prefix = case T.splitOn prefix text of
      first : rest -> T.intercalate prefix (first : map (\piece -> "X" <> T.dropWhile tempChar piece) rest)
      [] -> text
    tempChar c = isAlphaNum c || c == '_' || c == '-'
    stamps = T.pack . go . T.unpack
    go s = case s of
      [] -> []
      _
        | (date, '-' : rest) <- splitAt 8 s
        , all isDigit date
        , (time, more) <- splitAt 6 rest
        , length time == 6
        , all isDigit time ->
            "<stamp>" <> go more
      c : more -> c : go more

fakeProvider :: FilePath -> String -> [String] -> IO ()
fakeProvider root name arguments = do
  cwd <- getCurrentDirectory
  let rootText = T.pack root
      normalized = map (normalizeText rootText . T.pack) arguments
      key = T.unwords (T.pack name : normalized)
      logPath = root </> "calls.log"
  logged <- doesFileExist logPath
  previous <- if logged then BC.lines <$> BS.readFile logPath else pure []
  let entry =
        Object
          [ ("argv", Array (map String (T.pack name : normalized)))
          , ("cwd", String (normalizeText rootText (T.pack cwd)))
          ]
      line = either (error . show) id (dumps compact entry)
      count = length [() | l <- previous, keyOf l == Just key]
  BS.appendFile logPath (line <> "\n")
  scripted <- BS.readFile (root </> "responses.json")
  let answers = case parseJson pythonLoads scripted of
        Right (Object members) -> case lookup key members of
          Just (Array items) | not (null items) -> Just (items !! min count (length items - 1))
          Just single@(Object _) -> Just single
          _ -> Nothing
        _ -> Nothing
  case answers of
    Nothing -> exitWith (ExitFailure 1)
    Just (Object answer) -> do
      when (name == "git" && take 1 arguments == ["clone"]) $
        case lookup "template" answer of
          Just (String template) -> copyTree (root </> T.unpack template) (last arguments)
          _ -> pure ()
      let text field = case lookup field answer of
            Just (String s) -> TE.encodeUtf8 s
            _ -> ""
          hex field = case lookup field answer of
            Just (String s) -> either (const "") id (Base16.decode (TE.encodeUtf8 s))
            _ -> ""
      BS.hPut stdout (text "stdout" <> hex "stdout_hex")
      BS.hPut stderr (text "stderr")
      case lookup "returncode" answer of
        Just (Int 0) -> pure ()
        Just (Int n) -> exitWith (ExitFailure (fromIntegral n))
        _ -> pure ()
    Just _ -> exitWith (ExitFailure 1)
  where
    keyOf l = case parseJson pythonLoads l of
      Right (Object members) | Just (Array argv) <- lookup "argv" members -> Just (T.unwords [s | String s <- argv])
      _ -> Nothing

copyTree :: FilePath -> FilePath -> IO ()
copyTree source destination = do
  createDirectoryIfMissing True destination
  entries <- listDirectory source
  forM_ entries \entry -> do
    directory <- doesDirectoryExist (source </> entry)
    if directory
      then copyTree (source </> entry) (destination </> entry)
      else copyFile (source </> entry) (destination </> entry)

-- ---------------------------------------------------------------------------
-- test_secret_launch.py

required :: [String]
required =
  [ "HAMSTERDAN_GITHUB_APP_ID"
  , "HAMSTERDAN_GITHUB_APP_SLUG"
  , "HAMSTERDAN_GITHUB_CLIENT_ID"
  , "HAMSTERDAN_GITHUB_PRIVATE_KEY"
  , "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"
  , "HAMSTERDAN_PI_API_KEY"
  ]

pem :: Text
pem = "-----BEGIN PRIVATE KEY-----\nfixture-only\n-----END PRIVATE KEY-----\n"

assert :: String -> Bool -> IO ()
assert what holds = unless holds do
  hPutStrLn stderr ("AssertionError: " <> what)
  exitWith (ExitFailure 1)

-- | The fake @op@: check what the launcher hands it, count the fetch,
-- create the CLI configuration directory, refuse when told to, then add
-- the current Environment and run the command after @--@.
fakeOp :: [String] -> IO ()
fakeOp arguments = do
  environment <- Map.fromList <$> getEnvironment
  assert "required variables are scrubbed" (all (`Map.notMember` environment) required)
  assert "bootstrap token" (Map.lookup "OP_SERVICE_ACCOUNT_TOKEN" environment == Just "loader-only-canary")
  assert "no OP_SA_ variables" (not (any ("OP_SA_" `isPrefixOf`) (Map.keys environment)))
  assert "op run --environment" (take 3 arguments == ["run", "--environment", replicate 26 'a'])
  let counter = fromMaybe "" (Map.lookup "TEST_FETCH_COUNTER" environment)
  exists <- doesFileExist counter
  previous <- if exists then read . BC.unpack <$> BS.readFile counter else pure (0 :: Int)
  BS.writeFile counter (BC.pack (show (previous + 1)))
  config <- case break (== "--config") arguments of
    (_, "--config" : directory : _) -> pure directory
    _ -> (</> ".config/op") <$> getHomeDirectory
  created <- try (createDirectoryIfMissing True config)
  case created of
    Left (e :: SomeException) -> hPutStrLn stderr (show e) >> exitWith (ExitFailure 1)
    Right () -> pure ()
  when (Map.lookup "TEST_DENIED" environment == Just "1") $ exitWith (ExitFailure 23)
  source <- BS.readFile (fromMaybe "" (Map.lookup "TEST_SOURCE" environment))
  let added = case parseJson pythonLoads source of
        Right (Object members) -> Map.fromList [(T.unpack k, T.unpack v) | (k, String v) <- members]
        _ -> Map.empty
      command = drop 1 (dropWhile (/= "--") arguments)
  case command of
    executable : rest -> do
      -- The reference's fake execs the command (os.execvpe). This one runs
      -- it as a child and exits with its status, as the real op run does:
      -- an exec from the threaded RTS fails at random, because Linux
      -- refuses a new thread (EAGAIN, copy_fs) while another thread of the
      -- process is in execve, and the RTS may be starting a worker then,
      -- which it treats as fatal ("failed to create OS thread").
      status <- runProcess (setEnv (Map.toList (Map.union added environment)) (proc executable rest))
      case status of
        ExitFailure code | code < 0 -> raiseSignal (fromIntegral (negate code)) >> exitWith (ExitFailure 1)
        _ -> exitWith status
    [] -> assert "a command after --" False

-- | The application child: no ambient credential family survives, and the
-- host configuration reads exactly the current Environment's values.
launchChild :: IO ()
launchChild = do
  environment <- Map.fromList <$> getEnvironment
  let families = ["OP_", "GH_", "GITHUB_", "AMP_", "ANTHROPIC_", "OPENAI_", "OPENROUTER_", "PETRUS_", "EXE_DEV_"]
  assert "no ambient credential family" (not (any (\name -> any (`isPrefixOf` name) families) (Map.keys environment)))
  assert "HAMSTERDAN_OP_TOKEN_FILE removed" (Map.notMember "HAMSTERDAN_OP_TOKEN_FILE" environment)
  assert "HAMSTERDAN_OP_COMMAND removed" (Map.notMember "HAMSTERDAN_OP_COMMAND" environment)
  outcome <- try (fromEnvironment environment)
  config <- case outcome of
    Left (e :: SomeException) -> hPutStrLn stderr (show e) >> exitWith (ExitFailure 1)
    Right config -> pure config
  assert "GitHub credentials" ((revealSecret config.privateKey, revealSecret config.webhookSecret) == (pem, "current-webhook-secret"))
  -- PiA2InstallationConfig.from_environment's environment contract.
  let value name = fromMaybe "" (Map.lookup name environment)
      names = ["HAMSTERDAN_PI_PROVIDER", "HAMSTERDAN_PI_MODEL", "HAMSTERDAN_PI_API_KEY", "HAMSTERDAN_PI_CLI_PATH", "HAMSTERDAN_PI_NODE_PATH", "HAMSTERDAN_PI_PACKAGE_ROOT"]
  assert "no retired Pi credential file" (Map.notMember "HAMSTERDAN_PI_API_KEY_FILE" environment)
  assert "explicit direct key and Pi runtime paths" (all (not . null . value) names)
  assert "absolute installation paths" (all (isAbsolute . value) (drop 3 names))
  assert "direct key" (value "HAMSTERDAN_PI_API_KEY" == "current-api-key-canary")
  putStrLn "current credentials accepted"

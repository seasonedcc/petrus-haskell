-- | The @petrus@ command (@bin/petrus.mjs@): start the viewer server,
-- optionally with a net file (local path or URL, cached locally) to open.
--
-- Argument handling, messages, and exit codes follow the Node CLI. Instead
-- of spawning @pnpm exec vite@ the server runs in process and serves the
-- built UI; a few extra options configure it (they are listed after the
-- upstream help text).
module Petrus.Viewer.Cli
  ( CliArgs (..)
  , CliAction (..)
  , parseCliArgs
  , helpText
  , runCli
  , main
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless, when)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Petrus.Viewer.Server
import Petrus.Viewer.UiDir (locateUiDir)
import Petrus.Viewer.Url (normalizeGitHubUrl)
import Petrus.Viewer.UrlCache
import System.Directory (doesDirectoryExist, doesFileExist, doesPathExist, getCurrentDirectory)
import System.Environment (getArgs, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO
import System.Info (os)
import System.Process qualified as P
import Text.Read (readMaybe)

data CliArgs = CliArgs
  { argNoOpen :: Bool
  , argFile :: Maybe FilePath
  -- ^ as given (resolved against the working directory later)
  , argUrl :: Maybe Text
  , argPort :: Maybe Int
  , argHost :: Maybe String
  , argStrictPort :: Bool
  , argUiDir :: Maybe FilePath
  , argTemporalTarget :: Maybe String
  , argObservation :: [Text]
  }
  deriving stock (Eq, Show)

data CliAction
  = ShowHelp
  | Start CliArgs
  | BadOption String
  deriving stock (Eq, Show)

emptyArgs :: CliArgs
emptyArgs = CliArgs False Nothing Nothing Nothing Nothing False Nothing Nothing []

isUrl :: String -> Bool
isUrl s = take 8 s == "https://" || take 7 s == "http://"

-- | Parse arguments in order, like the Node loop: @--help@ wins as soon as
-- it is seen, unknown dash options are ignored, and the last positional
-- argument of each kind (file or URL) wins.
parseCliArgs :: [String] -> CliAction
parseCliArgs = go emptyArgs
  where
    go acc = \case
      [] -> Start acc {argObservation = reverse (argObservation acc)}
      "--no-open" : rest -> go acc {argNoOpen = True} rest
      "--help" : _ -> ShowHelp
      "-h" : _ -> ShowHelp
      "--strict-port" : rest -> go acc {argStrictPort = True} rest
      a : rest
        | Just (name, inline) <- valued a ->
            case maybe (uncons' rest) (\v -> Just (v, rest)) inline of
              Nothing -> BadOption ("option " <> name <> " requires a value")
              Just (v, rest') -> case setValued name v acc of
                Left e -> BadOption e
                Right acc' -> go acc' rest'
        | take 1 a == "-" -> go acc rest
        | isUrl a -> go acc {argUrl = Just (T.pack a)} rest
        | otherwise -> go acc {argFile = Just a} rest
    uncons' = \case
      v : r -> Just (v, r)
      [] -> Nothing
    valued a =
      let (name, rest) = break (== '=') a
       in if name `elem` ["--port", "--host", "--ui-dir", "--temporal-target", "--observation"]
            then Just (name, if null rest then Nothing else Just (drop 1 rest))
            else Nothing
    setValued name v acc = case name of
      "--port" -> case readMaybe v of
        Just p | p >= 0 && p < 65536 -> Right acc {argPort = Just p}
        _ -> Left ("invalid port: " <> v)
      "--host" -> Right acc {argHost = Just v}
      "--ui-dir" -> Right acc {argUiDir = Just v}
      "--temporal-target" -> Right acc {argTemporalTarget = Just v}
      _ -> Right acc {argObservation = T.pack v : argObservation acc}

helpText :: Text
helpText =
  T.unlines
    [ "Usage: petrus [options] [file | url]"
    , ""
    , "Options:"
    , "  --no-open    Don't open the browser automatically"
    , "  -h, --help   Show this help"
    , ""
    , "Examples:"
    , "  petrus                              Start with default/last-opened file"
    , "  petrus examples/sample-net.json     Open a specific net file"
    , "  petrus https://github.com/org/repo/blob/main/path/to/net.json   Open from GitHub"
    , ""
    , "Server options (Haskell backend):"
    , "  --port <n>               First port to try (default 5173; the next free one is used;"
    , "                           0 picks any free port)"
    , "  --strict-port            Fail instead of moving to the next free port"
    , "  --host <host>            Address to bind (default localhost: 127.0.0.1 and ::1); like"
    , "                           vite --host, also serves the collaboration relay at /collab-ws"
    , "  --ui-dir <dir>           Built viewer UI (pnpm build output); env PETRUS_UI_DIR"
    , "                           (default: ./dist, else a build next to this executable)"
    , "  --temporal-target <url>  Temporal HTTP API behind /temporal (default http://localhost:7243)"
    , "  --observation <url>      Petrus observation endpoint served as Temporal history"
    , "                           (repeatable); env PETRUS_OBSERVATION_URLS (comma separated)"
    ]

main :: IO ()
main = getArgs >>= runCli

runCli :: [String] -> IO ()
runCli argv = case parseCliArgs argv of
  ShowHelp -> TIO.putStr helpText >> hFlush stdout >> exitWith ExitSuccess
  BadOption e -> hPutStrLn stderr ("Error: " <> e) >> exitWith (ExitFailure 1)
  Start args -> do
    cwd <- getCurrentDirectory
    let filePath0 = fmap (resolveFrom cwd) (argFile args)
    forM_ filePath0 $ \fp -> do
      exists <- doesPathExist fp
      unless exists $ do
        hPutStrLn stderr ("Error: file not found: " <> fp)
        exitWith (ExitFailure 1)
    filePath <- case argUrl args of
      Nothing -> pure filePath0
      Just url -> Just <$> fetchAndCache url
    -- the Node CLI passes its environment to Vite, so inherited
    -- PETRUS_OPEN_FILE / PETRUS_SOURCE_URL apply when not overridden
    envFile <- nonEmpty <$> lookupEnv "PETRUS_OPEN_FILE"
    envSource <- nonEmpty <$> lookupEnv "PETRUS_SOURCE_URL"
    let sourceUrl = case argUrl args of
          Just u -> Just (normalizeGitHubUrl u)
          Nothing -> T.pack <$> envSource
        pendingFile = filePath `orElse` envFile
    uiDir <- resolveUiDir cwd (argUiDir args)
    obsEnv <- lookupEnv "PETRUS_OBSERVATION_URLS"
    let observation =
          argObservation args
            ++ [T.strip u | Just v <- [obsEnv], u <- T.splitOn "," (T.pack v), not (T.null (T.strip u))]
    temporalEnv <- lookupEnv "PETRUS_TEMPORAL_TARGET"
    -- like PETRUS_PERF=0 for the MCP server: silence the relay timing log
    relayPerfEnv <- lookupEnv "PETRUS_RELAY_PERF"
    let cfg =
          defaultServerConfig
            { serverHost = fromMaybe "localhost" (argHost args)
            , serverPort = fromMaybe 5173 (argPort args)
            , serverStrictPort = argStrictPort args
            , serverUiDir = uiDir
            , serverTemporalTarget = fromMaybe "http://localhost:7243" (argTemporalTarget args `orElse` temporalEnv)
            , serverObservation = observation
            , serverOpenFile = pendingFile
            , serverSourceUrl = sourceUrl
            , serverRelayPerf = relayPerfEnv /= Just "0"
            , -- Vite serves /collab-ws only when it runs with --host
              serverCollab = isJust (argHost args)
            }
    hSetBuffering stdout LineBuffering
    runServer cfg $ \port -> do
      let shown = if serverHost cfg `elem` ["localhost", "127.0.0.1", "::1"] then "localhost" else serverHost cfg
          local = "http://" <> shown <> ":" <> show port <> "/"
      putStrLn ""
      putStrLn "  petrus viewer server (Haskell) ready"
      putStrLn ""
      putStrLn ("  \10140  Local:   " <> local)
      when (isJust uiDir) $ forM_ uiDir $ \d -> putStrLn ("  \10140  UI:      " <> d)
      unless (null observation) $ putStrLn ("  \10140  History: " <> T.unpack (T.intercalate ", " observation))
      hFlush stdout
      unless (argNoOpen args) (openBrowser local)
  where
    orElse a b = maybe b Just a
    nonEmpty = \case
      Just "" -> Nothing
      other -> other

resolveFrom :: FilePath -> FilePath -> FilePath
resolveFrom cwd p =
  let joined = if take 1 p == "/" then p else cwd <> "/" <> p
      n = normalizePosix joined
   in if length n > 1 && last n == '/' then init n else n

-- | @--ui-dir@, else @PETRUS_UI_DIR@, else @./dist@ when it holds a build,
-- else a build found next to the executable ("Petrus.Viewer.UiDir").
resolveUiDir :: FilePath -> Maybe FilePath -> IO (Maybe FilePath)
resolveUiDir cwd flag = do
  env <- lookupEnv "PETRUS_UI_DIR"
  case flag `orElse'` env of
    Just d -> do
      let dir = resolveFrom cwd d
      ok <- doesDirectoryExist dir
      unless ok $ do
        hPutStrLn stderr ("Error: UI directory not found: " <> dir)
        exitWith (ExitFailure 1)
      pure (Just dir)
    Nothing -> do
      let dist = cwd </> "dist"
      built <- doesFileExist (dist </> "index.html")
      if built
        then pure (Just dist)
        else do
          exe <- getExecutablePath
          locateUiDir [takeDirectory exe]
  where
    orElse' a b = maybe b Just a

-- | Fetch a URL argument and cache it like the Node CLI.
fetchAndCache :: Text -> IO FilePath
fetchAndCache sourceUrl = do
  let rawUrl = normalizeGitHubUrl sourceUrl
  mgr <- newFetchManager
  r <- fetchText mgr rawUrl
  case r of
    FetchHttpError code -> do
      hPutStrLn stderr ("Error: Failed to fetch " <> T.unpack rawUrl <> " (HTTP " <> show code <> ")")
      exitWith (ExitFailure 1)
    FetchFailed msg -> do
      hPutStrLn stderr ("Error: Failed to fetch URL: " <> T.unpack msg)
      exitWith (ExitFailure 1)
    FetchOk content -> case (slugifyUrl rawUrl, cacheRelativePath rawUrl) of
      (Right (Just slug), Right rel) -> do
        w <- try @SomeException (cacheFile slug rel content)
        case w of
          Left e -> do
            hPutStrLn stderr ("Error: Failed to fetch URL: " <> show e)
            exitWith (ExitFailure 1)
          Right path -> do
            putStrLn ("Cached to: " <> path)
            pure path
      (Left e, _) -> failWith e
      (_, Left e) -> failWith e
      (Right Nothing, _) -> do
        hPutStrLn stderr ("Error: Failed to determine cache slug for " <> T.unpack rawUrl)
        exitWith (ExitFailure 1)
  where
    failWith e = do
      hPutStrLn stderr ("Error: Failed to fetch URL: " <> T.unpack e)
      exitWith (ExitFailure 1)

openBrowser :: String -> IO ()
openBrowser url = do
  let cmd = if os == "darwin" then "open" else "xdg-open"
  _ <- try @SomeException (P.spawnProcess cmd [url])
  pure ()

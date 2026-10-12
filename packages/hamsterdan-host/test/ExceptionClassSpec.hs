-- | 'exceptionClass' is closed and names the reference's classes.
--
-- * Every exception type the Hamsterdan packages under the host declare is
--   listed (or explicitly unlisted, with its reason): a new type fails here
--   instead of reaching stored state under its Haskell name.
-- * Each listed Hamsterdan type's class exists in the pinned reference
--   under that name.
-- * A SQLite failure is named as CPython's @sqlite3@ names it, with
--   SQLite's message, for the same statements on the pinned interpreter.
module ExceptionClassSpec (spec) where

import Control.Exception (SomeException, fromException, toException, try)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Typeable (tyConName, typeRepTyCon)
import Database.SQLite3 qualified as S
import Hamsterdan.Agents.Pi (PiWorkspaceError (..))
import Hamsterdan.Agents.Protocol (AgentProtocolError (..))
import Hamsterdan.GitHub.Config (ConfigurationError (..))
import Hamsterdan.GitHub.Http (ClientError (..), ClientErrorKind (..))
import Hamsterdan.GitHub.Models
  ( BoundaryKind (..)
  , ContractRefused (..)
  , FailureClass (..)
  , GitHubBoundaryError (..)
  , InvalidRequest (..)
  , PublicationCollision (..)
  , PublicationRejected (..)
  , RerunRefused (..)
  , boundary
  )
import Hamsterdan.GitHub.Routing (InventoryMismatch (..))
import Hamsterdan.GitHub.Webhooks (WebhookRejected (..))
import Hamsterdan.Host.Agenticus (AgentCompositionError (..))
import Hamsterdan.Host.Errors (UnstagedCustodyError (..))
import Hamsterdan.Host.ExceptionClass (exceptionClass, listedExceptionTypes, unlistedExceptionTypes)
import Hamsterdan.Host.GitPublish (GitPublishError (..), PublicationCategory (..))
import Hamsterdan.Host.Python (LookupError (..), RuntimeError (..), TypeError (..), ValueError (..))
import Hamsterdan.Sqlite qualified as Sql
import Petrus.Json (Json (..), defaultDumps, dumpsText, parseJson, surrogateRefusingLoads)
import Petrus.Json.Python (PythonException, pythonExceptionStr)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed (proc, readProcessStdout_)
import Test.Hspec

spec :: Spec
spec = describe "exceptionClass (type(error).__name__)" $ do
  it "lists every exception type the host's Hamsterdan packages declare" $ do
    root <- repoRoot
    declared <- fmap concat . forM packages $ \package -> sourcesUnder (root </> "packages" </> package </> "src") >>= mapM declarations
    let listed = Set.fromList (map (T.pack . tyConName . typeRepTyCon) listedExceptionTypes)
        unlisted = Set.fromList (map fst unlistedExceptionTypes)
    filter (\name -> not (Set.member name listed || Set.member name unlisted)) (sort (concat declared)) `shouldBe` []

  it "names each Hamsterdan failure by a class the pinned reference defines" $ do
    map (exceptionClass . fst) referenceClasses `shouldBe` map (snd . snd) referenceClasses
    executable <- upstreamPythonExecutable "hamsterdan"
    let program =
          "import importlib, json, sys\n\
          \pairs = json.loads(sys.argv[1])\n\
          \def name(module, cls):\n\
          \    found = getattr(importlib.import_module(module), cls)\n\
          \    assert issubclass(found, Exception), cls\n\
          \    return found.__name__\n\
          \print(json.dumps([name(m, c) for m, c in pairs]))\n"
        pairs = Array [Array [String m, String c] | (_, (m, c)) <- referenceClasses]
    out <- readProcessStdout_ (proc executable ["-I", "-B", "-c", program, encoded pairs])
    parseJson surrogateRefusingLoads (BL.toStrict out) `shouldBe` Right (Array [String c | (_, (_, c)) <- referenceClasses])

  it "names a SQLite failure as CPython's sqlite3 does, with SQLite's message" . withSystemTempDirectory "exception-class" $ \tmp -> do
    let database = tmp </> "store.sqlite3"
        notADatabase = tmp </> "garbage.sqlite3"
    BS.writeFile notADatabase (BS.replicate 4096 0x41)
    mine <- forM statements $ \(path, sql) -> do
      connection <- Sql.open (T.pack (if path == "garbage" then notADatabase else database))
      outcome <- try @SomeException (mapM_ (Sql.script connection) sql)
      Sql.close connection
      pure $ case outcome of
        Right () -> Null
        Left e -> Array [String (exceptionClass e), String (maybe "" pythonExceptionStr (fromException @PythonException e))]
    executable <- upstreamPythonExecutable "hamsterdan"
    let program =
          "import json, sqlite3, sys\n\
          \cases = json.loads(sys.argv[3])\n\
          \out = []\n\
          \for path, sql in cases:\n\
          \    connection = sqlite3.connect(sys.argv[2] if path == 'garbage' else sys.argv[1], isolation_level=None)\n\
          \    try:\n\
          \        for statement in sql:\n\
          \            connection.executescript(statement)\n\
          \        out.append(None)\n\
          \    except Exception as error:\n\
          \        out.append([type(error).__name__, str(error)])\n\
          \    connection.close()\n\
          \print(json.dumps(out))\n"
        pythonDatabase = tmp </> "python.sqlite3"
        cases = Array [Array [String path, Array (map String sql)] | (path, sql) <- statements]
    out <- readProcessStdout_ (proc executable ["-I", "-B", "-c", program, pythonDatabase, notADatabase, encoded cases])
    parseJson surrogateRefusingLoads (BL.toStrict out) `shouldBe` Right (Array mine)
    exceptionClass (toException (S.SQLError S.ErrorBusy "database is locked" "step")) `shouldBe` "OperationalError"
  where
    packages = ["hamsterdan-contracts", "hamsterdan-cli", "hamsterdan-github", "hamsterdan-agents", "hamsterdan-readiness", "hamsterdan-host"]
    statements :: [(Text, [Text])]
    statements =
      [ ("store", ["CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT NOT NULL)", "INSERT INTO t VALUES(1, 'a')"])
      , ("store", ["INSERT INTO t VALUES(1, 'b')"])
      , ("store", ["INSERT INTO t VALUES(2, NULL)"])
      , ("store", ["SELECT * FROM missing"])
      , ("store", ["SELEC 1"])
      , ("garbage", ["SELECT * FROM sqlite_master"])
      ]
    encoded = either (error . show) T.unpack . dumpsText defaultDumps

-- | One failure of each listed Hamsterdan type, with the reference module
-- and class it stands for.
referenceClasses :: [(SomeException, (Text, Text))]
referenceClasses =
  [ (toException (boundary "x"), ("hamsterdan.github_app.models", "GitHubBoundaryError"))
  , (toException (GitHubBoundaryError ObjectWrite "x" TransportAmbiguity Nothing "none"), ("hamsterdan.github_app.gateway", "GitHubObjectWriteError"))
  , (toException (UnstagedCustodyError "x"), ("hamsterdan.host.v5.gates", "UnstagedCustodyError"))
  , (toException (RerunRefused "x"), ("hamsterdan.github_app.models", "RerunRefusedError"))
  , (toException (ContractRefused "x"), ("builtins", "RuntimeError"))
  , (toException (InvalidRequest "x"), ("builtins", "ValueError"))
  , (toException PublicationCollision, ("builtins", "ValueError"))
  , (toException (PublicationRejected "x"), ("builtins", "ValueError"))
  , (toException (InventoryMismatch "x"), ("builtins", "ValueError"))
  , (toException (ClientError OsKind "ConnectionResetError" "x"), ("builtins", "ConnectionResetError"))
  , (toException (ConfigurationError "x"), ("hamsterdan.github_app.config", "ConfigurationError"))
  , (toException (WebhookRejected "x"), ("hamsterdan.github_app.webhooks", "WebhookRejected"))
  , (toException (AgentCompositionError "x"), ("hamsterdan.host.agenticus", "AgentCompositionError"))
  , (toException protocolError, ("hamsterdan.agents.protocol", "AgentProtocolError"))
  , (toException (PiWorkspaceError "x"), ("hamsterdan.agents.pi", "PiWorkspaceError"))
  , (toException (PiWorkspaceCleanupError True), ("hamsterdan.agents.pi", "PiWorkspaceCleanupError"))
  , (toException (GitPublishError RefCas "x"), ("hamsterdan.host.git_publish", "GitPublishError"))
  , (toException (RuntimeError "x"), ("builtins", "RuntimeError"))
  , (toException (ValueError "x"), ("builtins", "ValueError"))
  , (toException (TypeError "x"), ("builtins", "TypeError"))
  , (toException (LookupError "x"), ("builtins", "LookupError"))
  ]
  where
    protocolError = AgentProtocolError {reason = "x", canceled = False, timedOut = False, resultCategory = Nothing, cleanupCategory = Nothing}

-- | The Haskell sources under a directory.
sourcesUnder :: FilePath -> IO [FilePath]
sourcesUnder directory = do
  exists <- doesDirectoryExist directory
  if not exists
    then pure []
    else do
      entries <- listDirectory directory
      fmap concat . forM entries $ \entry -> do
        let path = directory </> entry
        isDirectory <- doesDirectoryExist path
        if isDirectory
          then sourcesUnder path
          else pure [path | takeExtension path == ".hs"]

-- | The types a source declares an @Exception@ instance for.
declarations :: FilePath -> IO [Text]
declarations path = do
  source <- TE.decodeUtf8 <$> BS.readFile path
  pure
    [ T.takeWhile (\c -> c /= ' ' && c /= ')') rest
    | line <- T.lines source
    , Just rest <- [T.stripPrefix "instance Exception " line]
    ]

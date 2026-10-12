{-# LANGUAGE RankNTypes #-}

-- | Fixtures shared by the Fabric and process-lifecycle conformance checks:
-- launching implementations, database groups, per-check schema resets, and
-- the reference tests' parties.
module Petrus.Fabric.Conformance.Setup
  ( Launcher (..)
  , pythonLauncher
  , haskellLauncher
  , Ctx (..)
  , unitGroup
  , dbGroup
  , Env (..)
  , withEnv
  , withBare
  , withFreshDatabase
  , connectImpl
  , Party (..)
  , PartyMap
  , parties
  , party
  , openRoute
  , envelopeArgs
  , withArgs
  , js
  , scalar
  , count
  , rowsOf
  , exec
  , dbNow
  , isoPlus
  , Pair (..)
  , Side (..)
  , interopGroup
  , both
  , registerOn
  , refusal
  , neutralLibrary
  , publicEngineDoorsOnly
  ) where

import Control.Exception (bracket, try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric (Category, FabricError, errorCategory, errorMessage)
import Petrus.Fabric.Postgres (parseTimestamptz)
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Postgres (Param, Sql)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), lookupPostgresUrl, repoRoot, skipMessage, withScratchDatabase)
import System.FilePath ((</>))
import Test.Hspec

-- | Starts an implementation for the duration of an action.
newtype Launcher = Launcher (forall a. (Impl -> IO a) -> IO a)

pythonLauncher :: Launcher
pythonLauncher = Launcher withPythonImpl

haskellLauncher :: (Handles -> [Ops]) -> Launcher
haskellLauncher tables = Launcher (\k -> newHandles >>= \h -> k (haskellImpl (tables h)))

-- | A database check's context: the implementation, its scratch database,
-- and a way to start a second instance of the same implementation.
data Ctx = Ctx {impl :: Impl, target :: PostgresTarget, launcher :: Launcher}

-- | Unit checks against one running implementation.
unitGroup :: Launcher -> SpecWith Impl -> Spec
unitGroup (Launcher with) = aroundAll with

-- | Database checks: one scratch database and one running implementation
-- for the group, or pending when PETRUS_TEST_POSTGRES is unset.
dbGroup :: Launcher -> SpecWith Ctx -> Spec
dbGroup l@(Launcher with) body = do
  url <- runIO lookupPostgresUrl
  case url of
    Nothing -> around (\_ -> pendingWith skipMessage) body
    Just configured -> aroundAll (\k -> withScratchDatabase configured (\t -> with (\i -> k (Ctx i t l)))) body

-- | One check's environment: a Haskell admin connection for inspection and
-- the implementation's own autocommit connection handle.
data Env = Env {admin :: Pg.Connection, conn :: Json}

connectImpl :: Ctx -> Bool -> IO Json
connectImpl ctx mode = ok ctx.impl "connect" [("dsn", String (TE.decodeUtf8 ctx.target.targetUrl)), ("autocommit", Bool mode)]

-- | Reset the Fabric and lifecycle schemas (the reference fixtures' DROP
-- SCHEMA … CASCADE) and provision Fabric with the implementation under
-- test.
withEnv :: Ctx -> (Env -> IO a) -> IO a
withEnv ctx action = withBare ctx $ \env -> do
  _ <- ok ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
  action env

-- | 'withEnv' without provisioning: both schemas dropped.
withBare :: Ctx -> (Env -> IO a) -> IO a
withBare ctx action =
  bracket (Pg.connect ctx.target.targetUrl True) Pg.close $ \admin -> do
    exec admin "DROP SCHEMA IF EXISTS impetus_fabric CASCADE" []
    exec admin "DROP SCHEMA IF EXISTS impetus_lifecycle CASCADE" []
    handle <- connectImpl ctx True
    result <- action (Env admin handle)
    _ <- ctx.impl.call "close" [("conn", handle)]
    pure result

-- | A check that needs its own database (schema-shape checks).
withFreshDatabase :: Ctx -> (Ctx -> Pg.Connection -> IO a) -> IO a
withFreshDatabase ctx action =
  withScratchDatabase ctx.target.adminUrl $ \fresh ->
    bracket (Pg.connect fresh.targetUrl True) Pg.close (action (Ctx ctx.impl fresh ctx.launcher))

-- | Interop checks: one scratch database shared by the Haskell port and the
-- pinned Python reference.
data Pair = Pair {haskell :: Impl, python :: Impl, target :: PostgresTarget}

-- | One implementation's side of an interop check, with its own autocommit
-- connection to the shared database.
data Side = Side {impl :: Impl, conn :: Json, dsn :: Text}

interopGroup :: Launcher -> SpecWith Pair -> Spec
interopGroup (Launcher with) body = do
  url <- runIO lookupPostgresUrl
  case url of
    Nothing -> around (\_ -> pendingWith skipMessage) body
    Just configured ->
      aroundAll (\k -> withScratchDatabase configured (\t -> with (\h -> withPythonImpl (\p -> k (Pair h p t))))) body

-- | An interop check in both directions: Python first then Haskell, and
-- Haskell first then Python. Both schemas are dropped before each run.
both :: String -> (Pg.Connection -> Side -> Side -> IO ()) -> SpecWith Pair
both label check = do
  it (label <> " [Python, then Haskell]") $ \pair -> run pair pair.python pair.haskell
  it (label <> " [Haskell, then Python]") $ \pair -> run pair pair.haskell pair.python
  where
    run pair first second =
      bracket (Pg.connect pair.target.targetUrl True) Pg.close $ \admin -> do
        exec admin "DROP SCHEMA IF EXISTS impetus_fabric CASCADE" []
        exec admin "DROP SCHEMA IF EXISTS impetus_lifecycle CASCADE" []
        let open i = ok i "connect" [("dsn", String (TE.decodeUtf8 pair.target.targetUrl)), ("autocommit", Bool True)]
        a <- open first
        b <- open second
        let url = TE.decodeUtf8 pair.target.targetUrl
        check admin (Side first a url) (Side second b url)
        _ <- first.call "close" [("conn", a)]
        _ <- second.call "close" [("conn", b)]
        pure ()

-- | Register a process through one side; answers its credential and client.
registerOn :: Side -> Text -> IO (Text, Json)
registerOn side n = do
  credential <-
    ok side.impl "issue_credential" [] >>= \case
      String c -> pure c
      other -> error ("issue_credential answered " <> show other)
  _ <- ok side.impl "register" [("conn", side.conn), ("instance", String n), ("credential", String credential)]
  client <- ok side.impl "client" [("conn", side.conn), ("instance", String n), ("credential", String credential)]
  pure (credential, client)

-- | A registered process and its client handle.
data Party = Party {name :: Text, credential :: Text, client :: Json}

type PartyMap = Map Text Party

-- | test_fabric's @parties@: sender-a, sender-b, recipient.
parties :: Ctx -> Env -> IO PartyMap
parties ctx env = Map.fromList <$> mapM (\n -> (n,) <$> party ctx env n) ["sender-a", "sender-b", "recipient"]

-- | Register one process with a fresh credential and open its client.
party :: Ctx -> Env -> Text -> IO Party
party ctx env n = do
  credential <-
    ok ctx.impl "issue_credential" [] >>= \case
      String c -> pure c
      other -> error ("issue_credential answered " <> show other)
  _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", String n), ("credential", String credential)]
  client <- ok ctx.impl "client" [("conn", env.conn), ("instance", String n), ("credential", String credential)]
  pure (Party n credential client)

-- | test_fabric's @open_route@.
openRoute :: Ctx -> PartyMap -> IO ()
openRoute ctx ps = do
  let recipient = (ps Map.! "recipient").client
  _ <- ok ctx.impl "expose" [("client", recipient), ("source", "commands/start")]
  _ <- ok ctx.impl "offer" [("client", recipient), ("source", "commands/start"), ("service", "worker"), ("capabilities", js "{\"model\":\"large\",\"tools\":[\"shell\"]}")]
  _ <- ok ctx.impl "grant" [("client", recipient), ("sender", "sender-a"), ("source", "commands/start")]
  pure ()

-- | test_fabric's @envelope(...)@ arguments, with overrides.
envelopeArgs :: [(Text, Json)] -> [(Text, Json)]
envelopeArgs overrides = withArgs base overrides
  where
    sender = maybe "sender-a" id (lookup "sender" overrides)
    base =
      [ ("delivery_id", "delivery-1")
      , ("sender", "sender-a")
      , ("recipient", "recipient")
      , ("source", "commands/start")
      , ("correlation", "conversation-1")
      , ("payload", js "{\"command\":\"go\"}")
      , ("reply_route", Array [sender, "replies/finish"])
      ]

-- | Replace or add members.
withArgs :: [(Text, Json)] -> [(Text, Json)] -> [(Text, Json)]
withArgs base overrides =
  [(k, maybe v id (lookup k overrides)) | (k, v) <- base] ++ [o | o@(k, _) <- overrides, k `notElem` map fst base]

-- | A JSON literal.
js :: Text -> Json
js text = either (error . ("bad JSON literal: " <>)) id (parseJson surrogateRefusingLoads (TE.encodeUtf8 text))

scalar :: Pg.Connection -> Sql -> [Param] -> IO (Maybe ByteString)
scalar c statement params =
  Pg.queryFirst c statement params >>= \case
    Just (value : _) -> pure value
    _ -> pure Nothing

count :: Pg.Connection -> Sql -> [Param] -> IO Int
count c statement params = maybe 0 (read . BC.unpack) <$> scalar c statement params

rowsOf :: Pg.Connection -> Sql -> [Param] -> IO [[Maybe Text]]
rowsOf c statement params = map (map (fmap TE.decodeUtf8)) <$> Pg.query c statement params

exec :: Pg.Connection -> Sql -> [Param] -> IO ()
exec = Pg.execute_

-- | The database's clock.
dbNow :: Pg.Connection -> IO UTCTime
dbNow c =
  scalar c "SELECT clock_timestamp()" [] >>= \case
    Just raw -> either error pure (parseTimestamptz raw)
    Nothing -> error "no clock"

-- | An offset-carrying ISO time some seconds after the given one.
isoPlus :: NominalDiffTime -> UTCTime -> Json
isoPlus seconds time = String (stampText (addUTCTime seconds time))

-- | The reference tests' @pytest.raises(..., match=...)@: the action is
-- refused with this category and a message containing each fragment in
-- order.
refusal :: Category -> [Text] -> IO a -> Expectation
refusal category fragments action =
  try action >>= \case
    Right _ -> expectationFailure ("expected a " <> show category <> " refusal, got success")
    Left (e :: FabricError)
      | errorCategory e == category && inOrder fragments (errorMessage e) -> pure ()
      | otherwise -> expectationFailure ("expected a " <> show category <> " refusal matching " <> show fragments <> ", got " <> show e)
  where
    inOrder [] _ = True
    inOrder (f : fs) message = case T.breakOn f message of
      (_, rest) | T.null rest -> False
      (_, rest) -> inOrder fs (T.drop (T.length f) rest)

-- | The reference's neutral-import tests guard Python's import hook against
-- psycopg; the port's equivalent is the package boundary: the package's
-- main library depends on none of the PostgreSQL packages, so importing it
-- cannot reach a database driver.
neutralLibrary :: FilePath -> Expectation
neutralLibrary package = do
  root <- repoRoot
  cabal <- TE.decodeUtf8 <$> BS.readFile (root </> "packages" </> package </> (package <> ".cabal"))
  let mainLibrary = takeWhile (not . isStanza) (drop 1 (dropWhile (/= "library") (T.lines cabal)))
      isStanza line = any (`T.isPrefixOf` line) ["library ", "executable ", "test-suite ", "benchmark ", "common "]
      depends = T.unwords mainLibrary
  mainLibrary `shouldSatisfy` (not . null)
  forM_ ["petrus-postgres", "postgresql-libpq", "petrus-engine-postgres", ":postgres"] $ \forbidden ->
    (forbidden, forbidden `T.isInfixOf` depends) `shouldBe` (forbidden, False)

-- | @test_cv5_demos_host_only_through_public_engine_doors@ for one demo
-- module (a path from the repository root). The reference parses each demo
-- script's imports and calls; the port's equivalent reads the demo module's
-- imports and qualified uses. A demo must import the public 'Engine' type
-- and the PostgreSQL provider's @createEngine@ and @loadEngine@ doors, and
-- reach neither the coordinator, the Engine's internals, nor the authority
-- fence, nor construct or move an Instance itself.
publicEngineDoorsOnly :: FilePath -> Expectation
publicEngineDoorsOnly relative = do
  root <- repoRoot
  source <- TE.decodeUtf8 <$> BS.readFile (root </> relative)
  let code = [line | line <- T.lines source, not ("--" `T.isPrefixOf` T.stripStart line)]
      imports = [(moduleOf line, namesOf line) | line <- code, "import " `T.isPrefixOf` line]
      moduleOf line = case T.words line of
        _ : name : _ -> name
        _ -> ""
      namesOf line = T.words (T.map (\c -> if c `elem` ("(),." :: String) then ' ' else c) (T.drop 1 (T.dropWhile (/= '(') line)))
      importsNaming name = [m | (m, names) <- imports, name `elem` names]
      forbiddenModules = ["Petrus.Engine.Coordinator", "Petrus.Engine.Internal", "Petrus.Postgres.Fence"]
      forbiddenNames = ["Coordinator", "newInstance", "resume", "begin", "candidates"]
      forbidden name = name `elem` forbiddenNames || "Fence" `T.isInfixOf` name
      -- Qualified uses such as @Pg.acquireFence@ or @Instance.begin@.
      qualifiedUses =
        [ used
        | line <- code
        , not ("import " `T.isPrefixOf` line)
        , word <- T.split (\c -> not (c `elem` ("._'" :: String) || ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || ('0' <= c && c <= '9'))) line
        , let parts = T.splitOn "." word
        , length parts > 1
        , let used = last parts
        , forbidden used
        ]
  (relative, [m | (m, _) <- imports, m `elem` forbiddenModules]) `shouldBe` (relative, [])
  (relative, [name | (_, names) <- imports, name <- names, forbidden name]) `shouldBe` (relative, [])
  (relative, qualifiedUses) `shouldBe` (relative, [])
  (relative, importsNaming "Engine") `shouldSatisfy` (elem "Petrus.Engine" . snd)
  (relative, importsNaming "createEngine", importsNaming "loadEngine")
    `shouldBe` (relative, ["Petrus.Engine.Postgres"], ["Petrus.Engine.Postgres"])

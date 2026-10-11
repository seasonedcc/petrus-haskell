-- | Host-owned deterministic Agenticus composition and operation routing
-- (@hamsterdan.host.agenticus@): the static catalog resolution of the one
-- isolated Pi route, the runner selection after an exact READY probe, and
-- the durable @agent-routes.sqlite3@ store that fences each logical agent
-- operation to its composition across Attempts and restarts.
--
-- The store's DDL is the reference's text, byte for byte (SQLite keeps it
-- in @sqlite_master@), so either host can resume the other's routes.
module Hamsterdan.Host.Agenticus
  ( -- * Composition
    piProvider
  , piModel
  , hostFencedEffect
  , agenticusDescriptors
  , AgentCompositionError (..)
  , AgentComposition (..)
  , mkAgentComposition
  , resolveAgenticus
  , composeAgent
  , snapshotData

    -- * Runner selection
  , ComposedRunner (..)
  , composeAgentRunner
  , composedAgentRunner

    -- * Operation routes
  , OperationRoute (..)
  , AgentRouteStore
  , openAgentRouteStore
  , activateRoutes
  , claimRoute
  , settleRoutes
  , closeRoutes
  , routeDatabase
  , routedAgentRunner
  , terminalOperations
  , routeIdentifier
  ) where

import Control.Concurrent.MVar
import Control.Exception (Exception, SomeAsyncException, SomeException, fromException, mask, onException, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Pi (PiNativeRunner, PiRuntime, PiWorkspaceProvider, defaultPiRunnerOptions, newPiNativeRunner, piAgentRunner, unavailablePiRunner)
import Hamsterdan.Agents.Protocol (AgentRunner (..), CodingRequest (..), Invocation (..))
import Hamsterdan.GitHub.Python (isAscii, isPrintable, pyIntBase, utf8Length)
import Hamsterdan.GitHub.Sqlite (Connection, SQLData (..))
import Hamsterdan.GitHub.Sqlite qualified as Sql
import Hamsterdan.Host.Binding (InstanceBinding (..), readInstanceBinding)
import Petrus.Agenticus.Catalog.Descriptor
  ( CapabilityDescriptor (..)
  , DescriptorIdentity (..)
  , DescriptorKind (..)
  , capabilityDescriptor
  , descriptorIdentity
  )
import Petrus.Agenticus.Catalog.Resolution
  ( CatalogState
  , Resolution (..)
  , ResolutionSnapshot
  , emptyCatalogState
  , enableState
  , incompatibilities
  , mkResolutionRequest
  , registerState
  , resolveState
  , snapshotFromData
  , snapshotToData
  )
import Petrus.Agenticus.Catalog.Result (CompatibilityIssue (..), CompatibilityResult (..))
import Petrus.Agenticus.Error (throwLeft)
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), RuntimeInstallation (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Pi
  ( piApiKeyCatalog
  , piCollocatedHands
  , piConnectionCapabilities
  , piContinuationCapabilities
  , piLocalTerritory
  , piProgramCapabilities
  )
import Petrus.Agenticus.Runtime.Profiles (agentAsNetA5Local, ampA1, piNativeA2Local)
import Petrus.Impetus.History.Codec (decodeRecord)
import Petrus.Impetus.History.Records (ActivityCompleted (..), ActivityFailed (..), ActivityRequested (..), Record (..))
import Petrus.Impetus.Petrinet.Schema (netPathText)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsText, parseJson, pythonLoads)
import Petrus.Motus.Worker (ValueError (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesPathExist, listDirectory)
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files qualified as Posix

-- ---------------------------------------------------------------------------
-- Composition

-- | @PI_PROVIDER@ and @PI_MODEL@: the default qualified pair.
piProvider, piModel :: Text
piProvider = "anthropic"
piModel = "claude-sonnet-4-5"

-- | @HOST_FENCED_EFFECT@.
hostFencedEffect :: CapabilityDescriptor
hostFencedEffect = capabilityDescriptor (descriptorIdentity KindEffect "hamsterdan.host-fenced" 1) ["effect.host-fenced"] []

-- | @AGENTICUS_DESCRIPTORS@, in the reference's order.
agenticusDescriptors :: [CapabilityDescriptor]
agenticusDescriptors =
  [ piConnectionCapabilities
  , piProgramCapabilities
  , piNativeA2Local
  , piCollocatedHands
  , piLocalTerritory
  , piContinuationCapabilities
  , hostFencedEffect
  ]

-- | @AgentCompositionError@: the selected agent route cannot be composed
-- without substitution (a @RuntimeError@).
newtype AgentCompositionError = AgentCompositionError Text
  deriving stock (Eq, Show)

instance Exception AgentCompositionError

-- | @AgentComposition@.
data AgentComposition = AgentComposition
  { provider :: Text
  , model :: Text
  , profile :: Text
  , snapshot :: ResolutionSnapshot
  }
  deriving stock (Eq, Show)

-- | @AgentComposition(...)@ with its @__post_init__@ check.
mkAgentComposition :: Text -> Text -> Text -> ResolutionSnapshot -> Either Text AgentComposition
mkAgentComposition provider model profile snapshot
  | (provider, model) `notElem` piApiKeyCatalog || profile /= expected =
      Left "Agenticus composition requires the exact qualified profile and snapshot"
  | otherwise = Right AgentComposition {provider, model, profile, snapshot}
  where
    expected = "pi-native-a2-local-" <> provider <> "-" <> model <> "-api-key"

refuse :: Text -> IO a
refuse = throwIO . AgentCompositionError

-- | @resolve_agenticus(descriptors=..., enabled=...)@.
resolveAgenticus :: [CapabilityDescriptor] -> Maybe [DescriptorIdentity] -> IO ResolutionSnapshot
resolveAgenticus selected enabled = do
  let runtimes = [d.identity | d <- selected, d.identity.kind == KindRuntime]
  when (agentAsNetA5Local.identity `elem` runtimes) $
    refuse "AgentNetRunner A5 topology cannot satisfy the selected Pi native A2 route"
  when (ampA1.identity `elem` runtimes) $ refuse "Amp A1 provider-managed territory is not agent isolation"
  registered <- foldl (\acc d -> acc >>= throwLeft . registerState d) (pure emptyCatalogState) selected
  let identities = maybe (map (.identity) selected) id enabled
  catalog <- foldl (\acc i -> acc >>= throwLeft . enableState i) (pure registered :: IO CatalogState) identities
  request <- throwLeft (mkResolutionRequest (map (.identity) selected))
  let resolution = resolveState request catalog
  case resolution.snapshot of
    Just snapshot -> pure snapshot
    Nothing -> do
      let codes = Set.toAscList (Set.fromList [issue.code | result <- incompatibilities resolution, issue <- result.issues])
      refuse ("Agenticus profile is unavailable: " <> T.intercalate "," codes)

-- | @compose_agent(environment, provider=..., model=...)@: 'Nothing' for
-- the environment is the reference's @None@.
composeAgent :: Maybe [(Text, Text)] -> Maybe Text -> Maybe Text -> IO AgentComposition
composeAgent environment provider0 model0 = do
  let removed = ["HAMSTERDAN_AGENT_ISOLATION_REQUIRED", "HAMSTERDAN_AGENT_MODE"]
      configured = [name | name <- removed, isJust (lookup name (maybe [] id environment))]
  unless (null configured) $
    refuse
      ( T.intercalate ", " configured
          <> " is no longer supported; isolated Agenticus Pi is the only agent route"
      )
  let (provider1, model1) = case (environment, provider0, model0) of
        (Nothing, Nothing, Nothing) -> (Just piProvider, Just piModel)
        _ -> (provider0, model0)
  (provider, model) <- case (provider1, model1) of
    (Just p, Just m) -> pure (p, m)
    _ -> refuse "Agenticus requires an explicit provider and model"
  when ((provider, model) `notElem` piApiKeyCatalog) $
    refuse "the exact Pi direct API-key provider and model are not qualified"
  snapshot <- resolveAgenticus agenticusDescriptors Nothing
  either (throwIO . ValueError) pure $
    mkAgentComposition provider model ("pi-native-a2-local-" <> provider <> "-" <> model <> "-api-key") snapshot

sortedCompact :: EncodeOptions
sortedCompact = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True}

-- | @_snapshot_data(snapshot)@.
snapshotData :: ResolutionSnapshot -> Text
snapshotData snapshot = either (error . show) id (dumpsText sortedCompact (snapshotToData snapshot))

-- ---------------------------------------------------------------------------
-- Runner selection

-- | Which runner @compose_agent_runner@ selected.
data ComposedRunner
  = SelectedPi PiNativeRunner
  | -- | @UnavailablePiRunner()@.
    SelectedUnavailable

composedAgentRunner :: ComposedRunner -> AgentRunner
composedAgentRunner = \case
  SelectedPi runner -> piAgentRunner runner
  SelectedUnavailable -> unavailablePiRunner

-- | @compose_agent_runner(pi_runtime=..., pi_workspaces=...)@: Pi
-- execution only after an exact READY probe, never a fallback. The probe
-- is the runtime's @probe()@.
composeAgentRunner :: Maybe (IO RuntimeProbeResult, PiRuntime, PiWorkspaceProvider) -> IO ComposedRunner
composeAgentRunner = \case
  Nothing -> pure SelectedUnavailable
  Just (probe, runtime, workspaces) -> do
    outcome <- try probe
    case outcome of
      Left e
        | isJust (fromException @SomeAsyncException e) -> throwIO e
        | otherwise -> pure SelectedUnavailable
      Right result
        | ready result -> pure (either (const SelectedUnavailable) SelectedPi (newPiNativeRunner runtime workspaces defaultPiRunnerOptions))
        | otherwise -> pure SelectedUnavailable
  where
    required = Set.fromList ["runtime.cancel", "runtime.continue", "runtime.harness-owned", "runtime.local"]
    ready :: RuntimeProbeResult -> Bool
    ready probe = case probe.installation of
      Just installation ->
        probe.disposition == ProbeReady
          && probe.runtime == piNativeA2Local.identity
          && installation.runtime == piNativeA2Local.identity
          && installation.adapterContractVersion == 1
          && required `Set.isSubsetOf` installation.capabilities
      Nothing -> False

-- ---------------------------------------------------------------------------
-- Routes

-- | @OperationRoute@.
data OperationRoute = OperationRoute
  { operation :: Text
  , profile :: Text
  , snapshot :: ResolutionSnapshot
  , resolved :: Bool
  }
  deriving stock (Eq, Show)

-- | @AgentRouteStore(path)@.
data AgentRouteStore = AgentRouteStore
  { database :: Connection
  , lock :: MVar ()
  , legacySchema :: IORef Bool
  }

-- | The store's connection (the tests read its tables).
routeDatabase :: AgentRouteStore -> Connection
routeDatabase store = store.database

routesSchema :: Text
routesSchema =
  T.intercalate
    "\n"
    [ ""
    , "            CREATE TABLE IF NOT EXISTS agent_routes ("
    , "                operation TEXT PRIMARY KEY,"
    , "                profile TEXT NOT NULL,"
    , "                snapshot TEXT NOT NULL,"
    , "                resolved INTEGER NOT NULL CHECK (resolved IN (0, 1))"
    , "            );"
    , "            CREATE TABLE IF NOT EXISTS active_agent_route ("
    , "                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),"
    , "                profile TEXT NOT NULL,"
    , "                snapshot TEXT NOT NULL"
    , "            );"
    ]

migrationStatements :: [Text]
migrationStatements =
  [ T.intercalate
      "\n"
      [ "CREATE TABLE agent_routes_v2 ("
      , "                    operation TEXT PRIMARY KEY,"
      , "                    profile TEXT NOT NULL,"
      , "                    snapshot TEXT NOT NULL,"
      , "                    resolved INTEGER NOT NULL CHECK (resolved IN (0, 1))"
      , "            )"
      ]
  , T.intercalate
      "\n"
      [ "INSERT INTO agent_routes_v2"
      , "                    SELECT operation, profile, snapshot, resolved FROM agent_routes"
      , "                    WHERE mode = 'agenticus' AND snapshot IS NOT NULL"
      ]
  , T.intercalate
      "\n"
      [ "CREATE TABLE active_agent_route_v2 ("
      , "                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),"
      , "                    profile TEXT NOT NULL,"
      , "                    snapshot TEXT NOT NULL"
      , "            )"
      ]
  , T.intercalate
      "\n"
      [ "INSERT INTO active_agent_route_v2"
      , "                    SELECT singleton, profile, snapshot FROM active_agent_route"
      , "                    WHERE mode = 'agenticus' AND snapshot IS NOT NULL"
      ]
  , "DROP TABLE active_agent_route"
  , "DROP TABLE agent_routes"
  , "ALTER TABLE agent_routes_v2 RENAME TO agent_routes"
  , "ALTER TABLE active_agent_route_v2 RENAME TO active_agent_route"
  ]

-- | @path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)@.
mkdirPrivate :: FilePath -> IO ()
mkdirPrivate directory = do
  exists <- doesPathExist directory
  unless exists $ do
    createDirectoryIfMissing True (takeDirectory directory)
    PosixDir.createDirectory directory 0o700 `onException` pure ()

openAgentRouteStore :: FilePath -> IO AgentRouteStore
openAgentRouteStore path = do
  mkdirPrivate (takeDirectory path)
  database <- Sql.open (T.pack path)
  lock <- newMVar ()
  legacySchema <- newIORef False
  let store = AgentRouteStore {database, lock, legacySchema}
  ( do
      void (Sql.query database "PRAGMA journal_mode=WAL" [])
      columns <- Sql.query database "PRAGMA table_info(agent_routes)" []
      let legacy = any (\case (_ : SQLText "mode" : _) -> True; _ -> False) columns
      writeIORef legacySchema legacy
      unless legacy $ Sql.script database routesSchema
    )
    `onException` Sql.close database
  pure store

-- | @with self._transaction():@ (@BEGIN IMMEDIATE@ under the store lock).
transaction :: AgentRouteStore -> IO a -> IO a
transaction store action = withMVar store.lock $ \_ -> mask $ \restore -> do
  Sql.script store.database "BEGIN IMMEDIATE"
  result <- restore action `onException` void (try @SomeException (Sql.script store.database "ROLLBACK"))
  Sql.script store.database "COMMIT"
  pure result

-- | @_identifier(value, name)@.
routeIdentifier :: Text -> Text -> Either Text Text
routeIdentifier name value
  | T.null value || utf8Length value > 1024 || not (isAscii value) || not (isPrintable value) =
      Left ("agent route " <> name <> " is malformed")
  | otherwise = Right value

identifier :: Text -> IO Text
identifier = either (throwIO . ValueError) pure . routeIdentifier "operation"

settleUnlocked :: AgentRouteStore -> [Text] -> IO ()
settleUnlocked store operations = do
  values <- traverse identifier (Set.toList (Set.fromList operations))
  forM_ values $ \operation ->
    Sql.execute store.database "UPDATE agent_routes SET resolved = 1 WHERE operation = ?" [SQLText operation]

migrateLegacySchema :: AgentRouteStore -> IO ()
migrateLegacySchema store = do
  unresolved <- Sql.query store.database "SELECT 1 FROM agent_routes WHERE mode != 'agenticus' AND resolved = 0 LIMIT 1" []
  unless (null unresolved) $ refuse "unresolved legacy Amp work cannot be resumed"
  incomplete <-
    Sql.query
      store.database
      "SELECT 1 FROM agent_routes WHERE mode = 'agenticus' AND resolved = 0 AND snapshot IS NULL LIMIT 1"
      []
  unless (null incomplete) $ refuse "unresolved Agenticus work lacks reconstructible composition"
  forM_ migrationStatements $ \statement -> Sql.execute store.database statement []
  writeIORef store.legacySchema False

-- | @AgentRouteStore.activate(composition, histories)@.
activateRoutes :: AgentRouteStore -> AgentComposition -> FilePath -> IO ()
activateRoutes store composition histories = do
  terminal <- terminalOperations histories
  let encoded = snapshotData composition.snapshot
  transaction store $ do
    settleUnlocked store (Set.toList terminal)
    legacy <- readIORef store.legacySchema
    when legacy $ migrateLegacySchema store
    blocked <-
      Sql.query
        store.database
        "SELECT 1 FROM agent_routes\n                WHERE resolved = 0 AND (profile != ? OR snapshot IS NOT ?)\n                LIMIT 1"
        [SQLText composition.profile, SQLText encoded]
    unless (null blocked) $ refuse "agent route change refused while prior-route work is unresolved"
    void $
      Sql.execute
        store.database
        "INSERT INTO active_agent_route VALUES (1, ?, ?)\n                ON CONFLICT(singleton) DO UPDATE SET profile=excluded.profile, snapshot=excluded.snapshot"
        [SQLText composition.profile, SQLText encoded]

-- | @AgentRouteStore.claim(operation, composition)@.
claimRoute :: AgentRouteStore -> Text -> AgentComposition -> IO OperationRoute
claimRoute store operation composition = do
  _ <- identifier operation
  let encoded = snapshotData composition.snapshot
  route <- transaction store $ do
    active <- Sql.query store.database "SELECT profile, snapshot FROM active_agent_route WHERE singleton = 1" []
    case active of
      [SQLText profile, SQLText snapshot] : _ | (profile, snapshot) == (composition.profile, encoded) -> pure ()
      _ -> refuse "agent process route is no longer active"
    void $
      Sql.execute
        store.database
        "INSERT OR IGNORE INTO agent_routes VALUES (?, ?, ?, 0)"
        [SQLText operation, SQLText composition.profile, SQLText encoded]
    route <- loadRoute store operation
    when route.resolved $ refuse "resolved agent work cannot be redispatched"
    pure route
  when ((route.profile, snapshotData route.snapshot) /= (composition.profile, encoded)) $
    refuse "operation is already fenced to a different agent route"
  pure route

loadRoute :: AgentRouteStore -> Text -> IO OperationRoute
loadRoute store operation = do
  rows <- Sql.query store.database "SELECT profile, snapshot, resolved FROM agent_routes WHERE operation = ?" [SQLText operation]
  case rows of
    [SQLText profile, SQLText snapshot, resolved] : _ -> do
      value <- either (throwIO . ValueError . T.pack) pure (parseJson pythonLoads (TE.encodeUtf8 snapshot))
      decoded <- throwLeft (snapshotFromData value)
      pure OperationRoute {operation, profile, snapshot = decoded, resolved = truthy resolved}
    [] -> refuse "agent operation route is not persisted"
    _ -> throwIO (ValueError "agent operation route is malformed")
  where
    truthy = \case
      SQLInteger 0 -> False
      SQLNull -> False
      _ -> True

-- | @AgentRouteStore.settle(operations)@.
settleRoutes :: AgentRouteStore -> [Text] -> IO ()
settleRoutes store operations = transaction store (settleUnlocked store operations)

-- | @AgentRouteStore.close()@.
closeRoutes :: AgentRouteStore -> IO ()
closeRoutes store = withMVar store.lock $ \_ -> Sql.close store.database

-- | @RoutedAgentRunner(runner, routes, composition, before_call=...)@:
-- claim logical operation ownership before delegating one explicit Attempt.
routedAgentRunner :: AgentRunner -> AgentRouteStore -> AgentComposition -> Maybe (Text -> Text -> Integer -> IO ()) -> AgentRunner
routedAgentRunner runner routes composition beforeCall =
  AgentRunner
    { review = \url request inv -> claimed "review" inv >> runner.review url request inv
    , converse = \url request inv -> claimed "conversation" inv >> runner.converse url request inv
    , code = \url request inv -> claimed request.kind inv >> runner.code url request inv
    }
  where
    claimed kind inv = do
      when (inv.attempt < 1) $ refuse "agent attempt must be a positive integer"
      void (claimRoute routes inv.operation composition)
      forM_ beforeCall $ \hook -> hook kind inv.operation inv.attempt

-- ---------------------------------------------------------------------------
-- History repair

malformed :: IO a
malformed = refuse "agent route repair History is malformed"

agentTransitions :: Set.Set Text
agentTransitions =
  Set.fromList ["execute.review", "execute.conversation", "execute.repair", "execute.change", "review.agent", "mut.git_gate"]

-- | @histories.glob("*/*/*/history.jsonl")@ (hidden names included, as
-- pathlib matches them).
historyPaths :: FilePath -> IO [FilePath]
historyPaths histories = do
  isDirectory <- doesDirectoryExist histories
  if not isDirectory
    then pure []
    else do
      level1 <- children histories
      level2 <- concat <$> traverse children level1
      level3 <- concat <$> traverse children level2
      fmap concat . forM level3 $ \directory -> do
        let candidate = directory </> "history.jsonl"
        exists <- doesPathExist candidate
        pure [candidate | exists]
  where
    children directory = do
      isDirectory <- doesDirectoryExist directory
      if isDirectory then map (directory </>) . sort <$> listDirectory directory else pure []

-- | Python's @json.loads@ result, a @Mapping@ check, and @decode_record@.
decodeLine :: Text -> Either () Record
decodeLine line = do
  value <- either (const (Left ())) Right (parseJson pythonLoads (TE.encodeUtf8 line))
  case value of
    Object _ -> either (const (Left ())) Right (decodeRecord value)
    _ -> Left ()

-- | @str.splitlines()@.
splitLines :: Text -> [Text]
splitLines text
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

-- | @value.get(name)@ on a dict.
getKey :: Text -> Json -> Maybe Json
getKey name = \case
  Object members -> lookup name (reverse members)
  _ -> Nothing

-- | @_terminal_operations(histories)@: the agent operations whose
-- requesting Activity has a known terminal record in some Instance
-- History.
terminalOperations :: FilePath -> IO (Set.Set Text)
terminalOperations histories = do
  paths <- historyPaths histories
  fmap Set.unions . forM paths $ \path -> do
    size <- try @IOError (Posix.fileSize <$> Posix.getFileStatus path)
    case size of
      Right bytes | bytes > 16 * 1024 * 1024 -> refuse "agent route repair History exceeds its bound"
      Right _ -> pure ()
      Left _ -> malformed
    contents <- try @IOError (BS.readFile path)
    text <- case contents of
      Right bytes | Right decoded <- TE.decodeUtf8' bytes -> pure decoded
      _ -> malformed
    (requests, terminal) <- scan path (splitLines text) Map.empty Map.empty
    fmap Set.fromList . fmap concat . forM (Map.toAscList (Map.intersectionWith (,) requests terminal)) $
      \(_, ((transition, operation), (terminalTransition, variant, failed))) -> do
        when (terminalTransition /= transition) $
          refuse "agent route repair History has a mismatched terminal Activity"
        if
          | transition == "mut.git_gate" && not failed && variant == Just "FaultM" -> pure []
          | transition == "mut.git_gate" && not failed && variant `notElem` map Just ["Pushed", "MovedM", "DeclinedM"] ->
              refuse "agent route repair History has a malformed mutation terminal"
          | transition == "review.agent" && not failed && variant == Just "RoundDeferred" -> pure []
          | transition == "review.agent" && not failed && variant `notElem` map Just ["AgentReview", "RoundMoved", "RoundUnable"] ->
              refuse "agent route repair History has a malformed review terminal"
          | otherwise -> pure [operation]
  where
    scan _ [] requests terminal = pure (requests, terminal)
    scan path (line : rest) requests terminal = case decodeLine line of
      Left () -> malformed
      Right (RActivityRequested record) -> do
        let transition = netPathText record.transition
            work = case record.input of
              Object _ -> Just (maybe (maybe Null id (getKey "command" record.input)) id (getKey "work" record.input))
              _ -> Nothing
        if transition `Set.member` agentTransitions
          then do
            operation <-
              if transition == "mut.git_gate"
                then do
                  let opKey = case work of
                        Just value@(Object _) -> getKey "op_key" value
                        _ -> Nothing
                  Just <$> mutationAgentOperation path opKey
                else pure $ case work of
                  Just value@(Object _) -> case getKey "operation" value of
                    Just (String s) -> Just s
                    _ -> Nothing
                  _ -> Nothing
            case operation of
              Just op | not (Map.member record.occurrence requests) ->
                scan path rest (Map.insert record.occurrence (transition, op) requests) terminal
              _ -> malformed
          else scan path rest requests terminal
      Right (RActivityCompleted record) -> settled record.occurrence (netPathText record.transition) (variantOf record.result) False
      Right (RActivityFailed record) -> settled record.occurrence (netPathText record.transition) Nothing True
      Right _ -> scan path rest requests terminal
      where
        settled occurrence transition variant failed
          | Map.member occurrence terminal = malformed
          | otherwise = scan path rest requests (Map.insert occurrence (transition, variant, failed) terminal)
    variantOf result = case getKey "$variant" result of
      Just (String s) -> Just s
      _ -> Nothing

-- | @_mutation_agent_operation(history, op_key)@: every failure is the
-- reference's malformed-History refusal.
mutationAgentOperation :: FilePath -> Maybe Json -> IO Text
mutationAgentOperation history opKey = do
  key <- case opKey of
    Just (String s) -> pure s
    _ -> malformed
  bindingOutcome <- try @SomeException (readInstanceBinding (takeDirectory history </> "binding.json"))
  binding <- case bindingOutcome of
    Right binding -> pure binding
    Left e
      | isJust (fromException @SomeAsyncException e) -> throwIO e
      | otherwise -> malformed
  let parts = reverse (take 3 (drop 1 (reverse (splitDirectories history))))
  numbers <- case traverse (pyIntBase 10 . T.pack) parts of
    Just [installation, repositoryId, pull] | minimum [installation, repositoryId, pull] > 0 -> pure (installation, repositoryId, pull)
    _ -> malformed
  let (installation, repositoryId, pull) = numbers
      expected = "github:" <> tshow installation <> ":" <> tshow repositoryId <> ":pr:" <> tshow pull
  when (binding.instanceId /= expected || binding.pullRequest /= pull) malformed
  either (const malformed) pure (routeIdentifier "operation" ("mutation:" <> binding.repository <> ":pr:" <> tshow pull <> ":" <> key))
  where
    tshow = T.pack . show


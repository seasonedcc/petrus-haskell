-- | Durable execution custody across a crash, between the two languages.
--
-- A provider's custody state outlives the process that created it: Docker's
-- @run.petrus.*@ container labels, Gondolin's @registry.json@ and the
-- authenticated sidecar it names, and (for the Local provider, whose lease
-- registry and private-file registry live only in the creating process) the
-- orphaned territory directory. Each example lets one language provision a
-- territory and die (@os._exit@ / 'exitImmediately': no cleanup), then a
-- fresh process of either language recovers the operation lookup-first:
-- reconcile, lookup, an idempotent create and a colliding one, attach,
-- execute, private files where the lease grants them, export, and destroy
-- of the dead process's lease.
--
-- The four pairings (reference/reference, reference/Haskell,
-- Haskell/reference, Haskell/Haskell) must print byte-identical reports, and
-- the reference against itself must print the committed one. The Python
-- side is @test/interop/custody_interop.py@ under the pinned reference; the
-- Haskell side is this test executable re-run with 'helperVariable' set.
-- Docker runs @test/fixtures/fake_docker.py@ as @docker@ on @PATH@, and
-- Gondolin the verbatim sidecar against @test/fixtures/fake_gondolin.mjs@.
module CustodyInteropSpec (spec, helperVariable, helper) where

import Control.Exception (throwIO, try)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.List (isPrefixOf, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, lookupMember, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Providers.Docker (defaultDockerConfig, dockerProvider, newDockerEnvironmentWith)
import Petrus.Motus.Execution.Providers.Gondolin (GondolinConfig (..), gondolinConfig, gondolinProvider, newGondolinEnvironment)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
import Support (withTempDir)
import System.Directory
  ( createDirectory
  , createFileLink
  , doesDirectoryExist
  , findExecutable
  , listDirectory
  , makeAbsolute
  , removeDirectoryRecursive
  )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Process (exitImmediately)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | Set (to any value) when this executable runs as the Haskell side.
helperVariable :: String
helperVariable = "PETRUS_EXECUTION_CUSTODY_HELPER"

-- ---------------------------------------------------------------------------
-- The Haskell side (custody_interop.py's twin)

-- | @provision PROVIDER OPERATION@ or @resume PROVIDER OPERATION LEASE_JSON@.
helper :: [String] -> IO ()
helper = \case
  ["provision", name, operation] -> do
    (provider, wanted, _) <- scenario name
    lease <- providerCreate provider (T.pack operation) wanted
    B.putStr (encode (leaseJson lease) <> "\n")
    hFlush stdout
    exitImmediately ExitSuccess
  ["resume", name, operation, provisioned] -> resume name (T.pack operation) (BC.pack provisioned)
  arguments -> fail ("custody helper: unexpected arguments " <> show arguments)

-- | The provider, the scenario's spec, and a materially different one.
scenario :: String -> IO (EnvironmentProvider, EnvironmentSpec, EnvironmentSpec)
scenario = \case
  "local" -> do
    env <- newLocalProcessEnvironment
    pure (localProvider env, environmentSpec Nothing [capPrivateFileTransfer], environmentSpec Nothing [])
  "docker" -> do
    env <- newDockerEnvironmentWith defaultDockerConfig
    pure (dockerProvider env, environmentSpec (Just "fake/image:1") [], environmentSpec (Just "fake/image:2") [])
  "gondolin" -> do
    root <- required "PETRUS_CUSTODY_GONDOLIN_ROOT"
    sdk <- required "PETRUS_CUSTODY_GONDOLIN_SDK"
    env <- newGondolinEnvironment root (gondolinConfig (T.pack sdk)) {gondolinLeaseTtl = 30}
    pure (gondolinProvider env, environmentSpec (Just "fake-image") [capPrivateFileTransfer], environmentSpec (Just "other-image") [])
  other -> fail ("unknown provider " <> show other)
  where
    required variable = lookupEnv variable >>= maybe (fail (variable <> " is not set")) pure

resume :: String -> Text -> ByteString -> IO ()
resume name operation provisionedJson = do
  (provider, wanted, other) <- scenario name
  provisioned <- either fail pure (parseJson surrogateRefusingLoads provisionedJson >>= leaseFromJson)
  reconciled <- providerReconcile provider operation
  looked <- providerLookup provider operation
  lease <- providerCreate provider operation wanted
  collided <- try (providerCreate provider operation other)
  collide <- case collided of
    Right again -> pure (leaseReport provisioned (Just lease) (Just again))
    Left failure
      | errorKind failure `elem` [RuntimeError, ValueError] -> pure (Object [("error", Array [String (kindName (errorKind failure)), String (errorMessage failure)])])
      | otherwise -> throwIO failure
  archive <- withSystemTempDirectory "custody" $ \source -> do
    B.writeFile (source </> "input") "host"
    workspaceArchive source
  attachment <- providerAttach provider lease archive "custody-digest"
  result <- providerExecute provider attachment (command ["/bin/sh", "-c", "/bin/cat input; printf done > output"] [])
  private <-
    if capPrivateFileTransfer `Set.member` leaseCapabilities lease
      then case providerPrivateFiles provider of
        Nothing -> fail "a lease granting private-file transfer from a provider without it"
        Just transfer -> do
          reference <- importPrivateFile transfer attachment (valid (mkPrivateFile "secret" "canary"))
          bound <-
            providerExecute provider attachment $
              command ["/bin/sh", "-c", "/bin/cat \"$PRIVATE/secret\"; printf after > \"$PRIVATE/secret\""] [("PRIVATE", reference)]
          exported <- exportPrivateFile transfer attachment reference
          cleaned <- cleanupPrivateFiles transfer attachment
          pure $
            Object
              [ ("execute", Array [Int (toInteger (resultReturncode bound)), text (resultStdout bound), text (resultStderr bound)])
              , ("export", Array [String (privateFileName exported), text (privateFileContent exported)])
              , ("cleanup", Array [String (cleanupDispositionText (privateCleanupDisposition cleaned)), Int (toInteger (privateCleanupRemoved cleaned)), Bool (privateCleanupVerified cleaned)])
              ]
      else pure Null
  exported <- files =<< providerExport provider attachment
  destroyed <- providerDestroy provider provisioned
  destroyedNew <-
    if lease /= provisioned
      then cleanupJson <$> providerDestroy provider lease
      else pure Null
  afterwards <- providerLookup provider operation
  reconciledAfter <- providerReconcile provider operation
  B.putStr . (<> "\n") . encode $
    Object
      [ ( "reconcile"
        , Object
            [ ("classification", String (reconcileClassText (reconcileClassification reconciled)))
            , ("lease", leaseReport provisioned Nothing (reconcileLease reconciled))
            , ("detail", String (reconcileDetail reconciled))
            ]
        )
      , ("lookup", leaseReport provisioned Nothing looked)
      , ("create", leaseReport provisioned Nothing (Just lease))
      , ("collide", collide)
      , ("execute", Array [Int (toInteger (resultReturncode result)), text (resultStdout result), text (resultStderr result), Bool (resultTimedOut result)])
      , ("private", private)
      , ("export", exported)
      , ("destroy", cleanupJson destroyed)
      , ("destroy_new", destroyedNew)
      , ("after", leaseReport provisioned (Just lease) afterwards)
      , ("reconcile_after", Array [String (reconcileClassText (reconcileClassification reconciledAfter)), String (reconcileDetail reconciledAfter)])
      ]
  where
    cleanupJson result = Array [String (cleanupDispositionText (cleanupDisposition result)), String (cleanupDetail result)]

environmentSpec :: Maybe Text -> [Capability] -> EnvironmentSpec
environmentSpec image capabilities = valid (mkEnvironmentSpec image capabilities)

command :: [Text] -> [(Text, PrivateFileRef)] -> Command
command argv roots = valid (mkCommand (commandSpec argv) {specPrivateRoots = roots})

valid :: Either ExecutionError a -> a
valid = either (error . show) id

kindName :: ErrorKind -> Text
kindName = \case
  OtherError name -> name
  kind -> T.pack (show kind)

text :: ByteString -> Json
text = String . TE.decodeUtf8

encode :: Json -> ByteString
encode = either (error . show) id . dumps defaultDumps {sortKeys = True}

leaseJson :: EnvironmentLease -> Json
leaseJson lease =
  Object
    [ ("operation_id", String (leaseOperationId lease))
    , ("provider", String (leaseProvider lease))
    , ("lease_id", String (leaseId lease))
    , ("capabilities", capabilitiesJson lease)
    , ("state", String (leaseStateText (leaseState lease)))
    ]

capabilitiesJson :: EnvironmentLease -> Json
capabilitiesJson lease = Array (map (String . capabilityKey) (Set.toAscList (leaseCapabilities lease)))

leaseFromJson :: Json -> Either String EnvironmentLease
leaseFromJson value = do
  let member key = maybe (Left ("lease JSON lacks " <> T.unpack key)) Right (lookupMember key value)
      string key =
        member key >>= \case
          String found -> Right found
          _ -> Left ("lease JSON " <> T.unpack key <> " is not a string")
  operation <- string "operation_id"
  provider <- string "provider"
  lease <- string "lease_id"
  stateText <- string "state"
  state <- maybe (Left "unknown lease state") Right (lookup stateText [(leaseStateText s, s) | s <- [minBound .. maxBound]])
  capabilities <-
    member "capabilities" >>= \case
      Array items -> forM items $ \case
        String key -> Right (Capability key)
        _ -> Left "capability is not a string"
      _ -> Left "capabilities is not an array"
  either (Left . show) Right (mkEnvironmentLease operation provider lease (Set.fromList capabilities) state)

-- | A lease as the report spells it (the script's @describe@): none, the dead process's, the one this
-- process created, or another.
leaseReport :: EnvironmentLease -> Maybe EnvironmentLease -> Maybe EnvironmentLease -> Json
leaseReport provisioned created = \case
  Nothing -> Null
  Just lease
    | lease == provisioned -> String "provisioned"
    | Just lease == created -> String "created"
    | otherwise -> Object [("new", Object [("capabilities", capabilitiesJson lease), ("state", String (leaseStateText (leaseState lease)))])]

-- | Every file of a workspace archive, by relative path.
files :: ByteString -> IO Json
files archive = withSystemTempDirectory "custody-export" $ \root -> do
  extractWorkspaceArchive archive root
  Object <$> walk root ""
  where
    walk root relative = do
      names <- sort <$> listDirectory (root </> relative)
      concat <$> forM names (\name -> do
        let path = if null relative then name else relative </> name
        directory <- doesDirectoryExist (root </> path)
        if directory
          then walk root path
          else (\content -> [(T.pack path, text content)]) <$> B.readFile (root </> path))

-- ---------------------------------------------------------------------------
-- The suite

data Side = Reference | Haskell
  deriving stock (Show)

data Context = Context
  { contextEnvironment :: [(String, String)]
  , contextTemporary :: FilePath
  , contextDockerState :: FilePath
  , contextGondolinRoot :: FilePath
  }

spec :: Spec
spec = describe "Execution custody interop with the reference" $ do
  node <- runIO (findExecutable "node")
  forM_ ["local", "docker", "gondolin"] $ \name ->
    it ("recovers a crashed " <> name <> " territory across languages, as the reference recovers its own") $
      case (name, node) of
        ("gondolin", Nothing) -> pendingWith "node is not on PATH"
        _ -> withContext $ \setting -> do
          let crossing (provisioner, resumer) tag = do
                let operation = "custody-" <> name <> "-" <> tag
                provisioned <- run setting provisioner ["provision", name, operation]
                report <- run setting resumer ["resume", name, operation, BC.unpack (BC.strip provisioned)]
                leftovers setting name
                pure (shape provisioned, report)
          reference <- crossing (Reference, Reference) "pp"
          snd reference `shouldBe` expected name
          forM_ [((Reference, Haskell), "ph"), ((Haskell, Reference), "hp"), ((Haskell, Haskell), "hh")] $ \(pairing, tag) -> do
            other <- crossing pairing tag
            (pairing, other) `shouldBeReport` (pairing, reference)
  where
    shouldBeReport (pairing, (shapeA, reportA)) (_, (shapeB, reportB)) = do
      (show pairing, shapeA) `shouldBe` (show pairing, shapeB)
      (show pairing, reportA) `shouldBe` (show pairing, reportB)

-- | A provisioned lease without its (fresh) identity.
shape :: ByteString -> Json
shape provisioned = case parseJson surrogateRefusingLoads provisioned of
  Right (Object members) -> Object [(key, value) | (key, value) <- members, key `notElem` ["operation_id", "lease_id"]]
  other -> error ("provision printed " <> show other)

run :: Context -> Side -> [String] -> IO ByteString
run setting side arguments = do
  process <- case side of
    Reference -> do
      python <- pythonExecutable
      script <- makeAbsolute ("test" </> "interop" </> "custody_interop.py")
      root <- upstreamPetrus
      pure (proc python ("-I" : script : arguments)) {cwd = Just root, env = Just (contextEnvironment setting)}
    Haskell -> do
      self <- getExecutablePath
      pure (proc self arguments) {env = Just ((helperVariable, "1") : contextEnvironment setting)}
  (code, out, err) <- readCreateProcessWithExitCode process ""
  unless (code == ExitSuccess) $
    expectationFailure (show side <> " " <> unwords (take 2 arguments) <> " exited with " <> show code <> ":\n" <> err)
  pure (BC.pack out)

-- | The children's environment: @fake_docker.py@ as @docker@ first on
-- @PATH@, its state directory, a private @TMPDIR@ (the Local territories),
-- and the Gondolin state root and fake SDK.
withContext :: (Context -> IO a) -> IO a
withContext action = withTempDir $ \tmp -> do
  fake <- makeAbsolute ("test" </> "fixtures" </> "fake_docker.py")
  sdk <- makeAbsolute ("test" </> "fixtures" </> "fake_gondolin.mjs")
  let bin = tmp </> "bin"
      temporary = tmp </> "tmp"
      dockerState = tmp </> "docker-state"
      gondolinRoot = tmp </> "g"
  mapM_ createDirectory [bin, temporary]
  createFileLink fake (bin </> "docker")
  inherited <- getEnvironment
  let path = maybe bin ((bin <> ":") <>) (lookup "PATH" inherited)
      overrides =
        [ ("PATH", path)
        , ("TMPDIR", temporary)
        , ("DOCKER_FAKE_STATE", dockerState)
        , ("PETRUS_CUSTODY_GONDOLIN_ROOT", gondolinRoot)
        , ("PETRUS_CUSTODY_GONDOLIN_SDK", sdk)
        ]
      kept = [(key, value) | (key, value) <- inherited, key `notElem` map fst overrides, not ("DOCKER_FAKE_" `isPrefixOf` key)]
  action (Context (overrides <> kept) temporary dockerState gondolinRoot)

-- | What the crossing left behind: nothing, except the Local territory of
-- the dead process, which no other process can find (its lease registry
-- died with it) and which is removed here.
leftovers :: Context -> String -> IO ()
leftovers setting name = do
  entries <- listDirectory (contextTemporary setting)
  case name of
    "local" -> do
      map (take (length territoryPrefix)) entries `shouldBe` [territoryPrefix]
      mapM_ (removeDirectoryRecursive . (contextTemporary setting </>)) entries
    _ -> entries `shouldBe` []
  case name of
    "docker" -> do
      state <- B.readFile (contextDockerState setting </> "state.json")
      (lookupMember "containers" =<< either (const Nothing) Just (parseJson surrogateRefusingLoads state)) `shouldBe` Just (Object [])
    "gondolin" -> listDirectory (contextGondolinRoot setting) `shouldReturn` []
    _ -> pure ()
  where
    territoryPrefix = "impetus-execution-"

-- | The reference's report against itself (sorted keys, as both sides print).
expected :: String -> ByteString
expected = \case
  "local" ->
    "{\"after\": null, \"collide\": \"created\", \"create\": {\"new\": {\"capabilities\": [\"command-cancellation\", \"explicit-environment\", \"private-file-transfer\", \"process-group\", \"workspace\"], \"state\": \"ready\"}}, \"destroy\": [\"unverified\", \"operation resolves to a different local lease\"], \"destroy_new\": [\"clean\", \"\"], \"execute\": [0, \"host\", \"\", false], \"export\": {\"input\": \"host\", \"output\": \"done\"}, \"lookup\": null, \"private\": {\"cleanup\": [\"clean\", 1, true], \"execute\": [0, \"canary\", \"\"], \"export\": [\"secret\", \"after\"]}, \"reconcile\": {\"classification\": \"retryable\", \"detail\": \"no local lease\", \"lease\": null}, \"reconcile_after\": [\"retryable\", \"no local lease\"]}\n"
  "docker" ->
    "{\"after\": null, \"collide\": {\"error\": [\"ValueError\", \"operation id collides with a materially different environment spec\"]}, \"create\": \"provisioned\", \"destroy\": [\"clean\", \"\"], \"destroy_new\": null, \"execute\": [0, \"host\", \"\", false], \"export\": {\"input\": \"host\", \"output\": \"done\"}, \"lookup\": \"provisioned\", \"private\": null, \"reconcile\": {\"classification\": \"uncertain\", \"detail\": \"container readiness does not prove operation outcome\", \"lease\": \"provisioned\"}, \"reconcile_after\": [\"retryable\", \"no container\"]}\n"
  _ ->
    "{\"after\": null, \"collide\": {\"error\": [\"ValueError\", \"operation id collides with a materially different environment spec\"]}, \"create\": \"provisioned\", \"destroy\": [\"clean\", \"\"], \"destroy_new\": null, \"execute\": [0, \"host\", \"\", false], \"export\": {\"input\": \"host\", \"output\": \"done\"}, \"lookup\": \"provisioned\", \"private\": {\"cleanup\": [\"clean\", 1, true], \"execute\": [0, \"canary\", \"\"], \"export\": [\"secret\", \"after\"]}, \"reconcile\": {\"classification\": \"uncertain\", \"detail\": \"VM readiness does not prove operation outcome\", \"lease\": \"provisioned\"}, \"reconcile_after\": [\"retryable\", \"no Gondolin lease\"]}\n"

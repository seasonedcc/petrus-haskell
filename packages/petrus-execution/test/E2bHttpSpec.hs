-- | The native E2B client ("Petrus.Motus.Execution.Providers.E2b.Http")
-- against a fake E2B (@test/fixtures/fake_e2b.py@) that speaks the official
-- SDK's wire protocol and runs commands for real.  These examples check the
-- requests the client sends, the SDK behaviors it reproduces, and the whole
-- upstream live lifecycle end to end.
module E2bHttpSpec (spec) where

import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import E2bLive (liveLifecycle)
import Network.HTTP.Client qualified as H
import Network.HTTP.Client.TLS (getGlobalManager)
import Petrus.Json
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Internal.Common (specFingerprint)
import Petrus.Motus.Execution.Providers.E2b
import Petrus.Motus.Execution.Providers.E2b.Http
import Support
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO (hGetLine)
import System.Process
import Test.Hspec

rightOr :: (Show e) => Either e a -> a
rightOr = either (error . show) id

apiKeyValue :: Text
apiKeyValue = "e2b_fake_0123456789"

data Fake = Fake {fakeUrl :: Text, fakeManager :: H.Manager}

withFakeE2b :: (Fake -> IO a) -> IO a
withFakeE2b action = withTempDir $ \tmp ->
  bracket
    ( createProcess
        (proc "test/fixtures/fake_e2b.py" [tmp, T.unpack apiKeyValue])
          { std_out = CreatePipe
          }
    )
    (\(_, _, _, handle) -> terminateProcess handle >> waitForProcess handle)
    $ \(_, stdoutPipe, _, _) -> do
      out <- maybe (fail "fake_e2b.py has no stdout pipe") pure stdoutPipe
      line <- hGetLine out
      port <- case words line of
        ["PORT", n] -> pure n
        _ -> fail ("fake_e2b.py did not announce its port: " <> line)
      manager <- getGlobalManager
      action (Fake ("http://127.0.0.1:" <> T.pack port) manager)

connectionTo :: Fake -> E2bConnection
connectionTo fake = E2bConnection "e2b.app" (fakeUrl fake) (Just (fakeUrl fake)) 60 3 (fakeManager fake)

configFor :: Fake -> E2bConfig
configFor fake = defaultE2bConfig {e2bApiKey = Just apiKeyValue, e2bSdkLoader = pure (httpSdk (connectionTo fake))}

control :: Fake -> Text -> Json -> IO Json
control fake path body = do
  base <- H.parseRequest (T.unpack (fakeUrl fake <> path))
  let request = base {H.method = "POST", H.requestBody = H.RequestBodyBS (rightOr (dumps compact body))}
  response <- H.httpLbs request (fakeManager fake)
  pure (rightOr (parseJson pythonLoads (BL.toStrict (H.responseBody response))))

requestLog :: Fake -> IO [Json]
requestLog fake = do
  base <- H.parseRequest (T.unpack (fakeUrl fake <> "/_fake/requests"))
  response <- H.httpLbs base (fakeManager fake)
  case rightOr (parseJson pythonLoads (BL.toStrict (H.responseBody response))) of
    Array entries -> pure entries
    other -> fail ("unexpected request log " <> show other)

member :: Text -> Json -> Json
member key value = fromMaybe Null (lookupMember key value)

str :: Text -> Json -> Text
str key value = case member key value of
  String text -> text
  other -> error ("not a string: " <> T.unpack key <> " = " <> show other)

requestsTo :: Text -> Text -> [Json] -> [Json]
requestsTo method path = filter (\entry -> str "method" entry == method && str "path" entry == path)

header :: Text -> Json -> Maybe Text
header name entry = case lookupMember name (member "headers" entry) of
  Just (String value) -> Just value
  _ -> Nothing

queryValues :: Text -> Json -> [Text]
queryValues name entry = case lookupMember name (member "query" entry) of
  Just (Array values) -> [v | String v <- values]
  _ -> []

template :: EnvironmentSpec
template = rightOr (mkEnvironmentSpec (Just "petrus-agent-template") [])

cmdWith :: [Text] -> (CommandSpec -> CommandSpec) -> Command
cmdWith argv f = rightOr (mkCommand (f (commandSpec argv)))

withLease :: E2bConfig -> Text -> EnvironmentSpec -> FilePath -> (EnvironmentProvider -> EnvironmentLease -> ExecutionAttachment -> IO a) -> IO a
withLease config operation environment directory action = do
  provider <- e2bProvider <$> newE2bEnvironment config
  lease <- providerCreate provider operation environment
  ( do
      archive <- workspaceArchive directory
      attachment <- providerAttach provider lease archive "digest"
      action provider lease attachment
    )
    `finally` providerDestroy provider lease

-- | Set environment variables for the duration of an action, restoring them.
withEnv :: [(String, Maybe String)] -> IO a -> IO a
withEnv settings action = do
  saved <- mapM (\(name, _) -> (,) name <$> lookupEnv name) settings
  let apply = mapM_ (\(name, value) -> maybe (unsetEnv name) (setEnv name) value)
  bracket (apply settings) (const (apply saved)) (const action)

spec :: Spec
spec = describe "e2b native client (fake E2B server)" $ do
  it "runs upstream's live lifecycle through the default loader and the SDK's environment variables" $
    withFakeE2b $ \fake -> withTempDir $ \tmp ->
      withEnv
        [ ("E2B_API_KEY", Just (T.unpack apiKeyValue))
        , ("E2B_API_URL", Just (T.unpack (fakeUrl fake)))
        , ("E2B_SANDBOX_URL", Just (T.unpack (fakeUrl fake)))
        , ("E2B_DOMAIN", Nothing)
        ]
        (liveLifecycle defaultE2bConfig "base" tmp)

  it "sends the SDK's control-plane requests" $ withFakeE2b $ \fake -> withTempDir $ \tmp -> do
    let operation = "e2b-wire-control"
    withLease (configFor fake) operation template tmp $ \_ _ _ -> pure ()
    entries <- requestLog fake
    forM_ (filter (\entry -> header "e2b-sandbox-id" entry == Nothing) entries) $ \entry ->
      header "x-api-key" entry `shouldBe` Just apiKeyValue
    [created] <- pure (requestsTo "POST" "/v2/sandboxes" entries)
    member "json" created
      `shouldBe` Object
        [ ("templateID", String "petrus-agent-template")
        , ("timeout", Int 900)
        , ( "metadata"
          , Object [("run.petrus.operation", String operation), ("run.petrus.spec", String (specFingerprint template))]
          )
        , ("envVars", Object [])
        ]
    header "content-type" created `shouldBe` Just "application/json"
    let lists = requestsTo "GET" "/v2/sandboxes" entries
    lists `shouldNotBe` []
    forM_ lists $ \entry -> do
      queryValues "metadata" entry `shouldBe` ["run.petrus.operation=" <> operation]
      queryValues "limit" entry `shouldSatisfy` (`elem` [["1"], ["2"]])
    [killed] <- pure [entry | entry <- entries, str "method" entry == "DELETE"]
    str "path" killed `shouldSatisfy` T.isPrefixOf "/sandboxes/sbx"

  it "sends the SDK's envd requests: files over HTTP, commands over Connect with the JSON codec" $ withFakeE2b $ \fake -> withTempDir $ \tmp ->
    withLease (configFor fake) "e2b-wire-envd" template tmp $ \provider lease attachment -> do
      result <-
        providerExecute provider attachment $
          cmdWith ["printf", "%s", "argument with spaces; $(unsafe)"] (\c -> c {specEnvironment = [("ALLOWED", "yes")]})
      resultStdout result `shouldBe` "argument with spaces; $(unsafe)"
      entries <- requestLog fake
      let envd = filter (\entry -> header "e2b-sandbox-id" entry == Just (leaseId lease)) entries
      envd `shouldNotBe` []
      forM_ envd $ \entry -> do
        header "e2b-sandbox-port" entry `shouldBe` Just "49983"
        header "x-access-token" entry `shouldSatisfy` maybe False (not . T.null)
        header "x-api-key" entry `shouldBe` Nothing
        header "authorization" entry `shouldBe` Nothing
      [upload] <- pure (requestsTo "POST" "/files" envd)
      member "multipart" upload `shouldBe` Bool True
      queryValues "username" upload `shouldBe` []
      [inputPath] <- pure (queryValues "path" upload)
      inputPath `shouldSatisfy` T.isPrefixOf "/tmp/petrus-input-"
      [removed] <- pure (requestsTo "POST" "/filesystem.Filesystem/Remove" envd)
      member "json" removed `shouldBe` Object [("path", String inputPath)]
      header "content-type" removed `shouldBe` Just "application/json"
      header "connect-protocol-version" removed `shouldBe` Just "1"
      starts <- pure (requestsTo "POST" "/process.Process/Start" envd)
      map (member "args" . member "process" . member "json") starts
        `shouldBe` [ Array [String "-l", String "-c", String ("rm -rf /home/user/workspace && mkdir -p /home/user/workspace && tar -xf " <> inputPath <> " -C /home/user/workspace")]
                   , Array [String "-l", String "-c", String "printf %s 'argument with spaces; $(unsafe)'"]
                   ]
      (attachStart, execution) <- case starts of
        [first, second] -> pure (first, second)
        _ -> fail ("expected two Start calls, got " <> show (length starts))
      member "json" execution
        `shouldBe` Object
          [ ( "process"
            , Object
                [ ("cmd", String "/bin/bash")
                , ("args", Array [String "-l", String "-c", String "printf %s 'argument with spaces; $(unsafe)'"])
                , ("envs", Object [("ALLOWED", String "yes")])
                , ("cwd", String "/home/user/workspace")
                ]
            )
          , ("stdin", Bool False)
          ]
      member "envelope_flags" execution `shouldBe` Int 0
      header "content-type" execution `shouldBe` Just "application/connect+json"
      header "connect-protocol-version" execution `shouldBe` Just "1"
      header "keepalive-ping-interval" execution `shouldBe` Just "50"
      -- No command timeout: the lease timeout bounds the stream.
      header "connect-timeout-ms" execution `shouldBe` Just "900000"
      header "connect-timeout-ms" attachStart `shouldBe` Just "60000"

  it "kills a timed-out command with SendSignal SIGKILL and reports envd's exit" $ withFakeE2b $ \fake -> withTempDir $ \tmp ->
    withLease (configFor fake) "e2b-wire-kill" template tmp $ \provider _ attachment -> do
      result <- providerExecute provider attachment (cmdWith ["sleep", "30"] (\c -> c {specTimeout = Just 0.3}))
      (resultTimedOut result, resultSuperseded result) `shouldBe` (True, False)
      entries <- requestLog fake
      [signalled] <- pure (requestsTo "POST" "/process.Process/SendSignal" entries)
      case member "json" signalled of
        Object [("process", Object [("pid", Int _)]), ("signal", String "SIGNAL_SIGKILL")] -> pure ()
        other -> expectationFailure ("unexpected SendSignal request " <> show other)
      [_, execution] <- pure (requestsTo "POST" "/process.Process/Start" entries)
      -- max(timeout, 1) seconds, as upstream passes to commands.run.
      header "connect-timeout-ms" execution `shouldBe` Just "1000"
      -- Superseded under a long stream deadline: the result carries the exit
      -- envd reports for a killed process.
      observations <- newIORef [True, False]
      let current = atomicModifyIORef' observations (\case x : xs -> (xs, x); [] -> ([], False))
      superseded <- providerExecute provider attachment (cmdWith ["sleep", "30"] (\c -> c {specTimeout = Just 30, specIsCurrent = Just current}))
      (resultSuperseded superseded, resultTimedOut superseded, resultReturncode superseded) `shouldBe` (True, False, -1)

  it "returns non-zero exits as results and bounds output" $ withFakeE2b $ \fake -> withTempDir $ \tmp ->
    withLease (configFor fake) "e2b-exit-and-bound" template tmp $ \provider _ attachment -> do
      failed <- providerExecute provider attachment (cmdWith ["/bin/sh", "-c", "printf out; printf err >&2; exit 3"] id)
      (resultReturncode failed, resultStdout failed, resultStderr failed) `shouldBe` (3, "out", "err")
      bounded <- providerExecute provider attachment (cmdWith ["/bin/sh", "-c", "printf '%0100d' 0 | tr 0 x"] (\c -> c {specOutputLimit = 10}))
      (resultOutputTruncated bounded, resultStdout bounded, resultStderr bounded) `shouldBe` (True, "xxxxxxxxxx", "")

  it "raises CommandExitException when a foreground run fails, as the SDK's commands.run does" $ withFakeE2b $ \fake -> withTempDir $ \tmp ->
    withLease (configFor fake) "e2b-foreground-failure" template tmp $ \provider _ attachment -> do
      _ <- providerExecute provider attachment (cmdWith ["rm", "-rf", "/home/user/workspace"] id)
      errorMatching (providerExport provider attachment) (OtherError "CommandExitException") "Command exited with code "

  it "does not mislabel a dropped command stream as a command failure" $ withFakeE2b $ \fake -> withTempDir $ \tmp ->
    withLease (configFor fake) "e2b-dropped-stream" template tmp $ \provider _ attachment -> do
      _ <- control fake "/_fake/drop-next-stream" (Object [])
      errorMatching (providerExecute provider attachment (cmdWith ["sleep", "5"] id)) (OtherError "SandboxException") "dropped"

  it "talks to old envd as the default user, as the SDK does below envd 0.4.0" $ withFakeE2b $ \fake -> withTempDir $ \tmp -> do
    let old = rightOr (mkEnvironmentSpec (Just "envd-0.3") [])
    withLease (configFor fake) "e2b-old-envd" old tmp $ \provider lease attachment -> do
      result <- providerExecute provider attachment (cmdWith ["printf", "ok"] id)
      resultStdout result `shouldBe` "ok"
      entries <- requestLog fake
      let envd = filter (\entry -> header "e2b-sandbox-id" entry == Just (leaseId lease)) entries
      forM_ (requestsTo "POST" "/files" envd) $ \entry -> queryValues "username" entry `shouldBe` ["user"]
      forM_ (requestsTo "POST" "/process.Process/Start" envd) $ \entry -> header "authorization" entry `shouldBe` Just "Basic dXNlcjo="

  it "kills and refuses a template whose envd predates 0.1.0" $ withFakeE2b $ \fake -> do
    provider <- e2bProvider <$> newE2bEnvironment (configFor fake)
    providerCreate provider "e2b-ancient" (rightOr (mkEnvironmentSpec (Just "old-envd") []))
      `shouldThrowMessage` (OtherError "TemplateException", "You need to update the template to use the new SDK.")
    entries <- requestLog fake
    length [entry | entry <- entries, str "method" entry == "DELETE"] `shouldBe` 1
    providerLookup provider "e2b-ancient" `shouldReturn` Nothing

  it "requires an API key, reporting the SDK's AuthenticationException as uncertain" $ withFakeE2b $ \fake ->
    withEnv [("E2B_API_KEY", Nothing)] $ do
      provider <- e2bProvider <$> newE2bEnvironment (configFor fake) {e2bApiKey = Nothing}
      result <- providerReconcile provider "e2b-no-key"
      reconcileClassification result `shouldBe` ReconcileUncertain
      reconcileDetail result `shouldSatisfy` T.isPrefixOf "API key is required, please visit the API Keys tab"
      wrong <- e2bProvider <$> newE2bEnvironment (configFor fake) {e2bApiKey = Just "e2b_wrong"}
      reconcileDetail <$> providerReconcile wrong "e2b-bad-key"
        `shouldReturn` "401: Unauthorized, please check your credentials. - Invalid API key"

  it "retries 503s like the SDK, and never retries a 502 on create" $ withFakeE2b $ \fake -> do
    provider <- e2bProvider <$> newE2bEnvironment (configFor fake)
    _ <- control fake "/_fake/fail" (Object [("path", String "/v2/sandboxes"), ("status", Int 503), ("count", Int 2)])
    providerLookup provider "e2b-retried" `shouldReturn` Nothing
    _ <- control fake "/_fake/fail" (Object [("path", String "/v2/sandboxes"), ("status", Int 503), ("count", Int 4)])
    reconcileDetail <$> providerReconcile provider "e2b-busy"
      `shouldReturn` "503: Service temporarily unavailable, please retry. - injected failure"
    _ <- control fake "/_fake/fail" (Object [("path", String "/v2/sandboxes"), ("method", String "POST"), ("status", Int 502), ("count", Int 1)])
    creates <- length . requestsTo "POST" "/v2/sandboxes" <$> requestLog fake
    providerCreate provider "e2b-bad-gateway" template
      `shouldThrowMessage` (OtherError "SandboxException", "502: injected failure")
    creates' <- length . requestsTo "POST" "/v2/sandboxes" <$> requestLog fake
    creates' - creates `shouldBe` 1

  it "follows x-next-token pagination" $ withFakeE2b $ \fake -> do
    let sdk = httpSdk (connectionTo fake)
        options = E2bOptions (Just apiKeyValue)
        metadata = [("run.petrus.operation", "e2b-paged")]
    forM_ [1 :: Int .. 3] $ \_ -> sdkCreate sdk options "base" 60 (Map.fromList metadata)
    paginator <- sdkList sdk options (Map.fromList metadata) 2
    first <- paginatorNextItems paginator options
    paginatorHasNext paginator `shouldReturn` True
    second <- paginatorNextItems paginator options
    paginatorHasNext paginator `shouldReturn` False
    (length first, length second) `shouldBe` (2, 1)
    map infoState (first <> second) `shouldBe` ["running", "running", "running"]
    entries <- requestLog fake
    mapMaybe (\entry -> case queryValues "nextToken" entry of [t] -> Just t; _ -> Nothing) (requestsTo "GET" "/v2/sandboxes" entries)
      `shouldBe` ["2"]

-- | The Engine-level Fabric checks, on the CV5 demo's nets and roles:
--
-- * F-100 against each implementation;
-- * F-108 across them (one delivers into the recipient's History and
--   crashes before acknowledging, the other resumes that History);
-- * F-107: the demo's whole scenario with each split role played by either
--   implementation, under either implementation's orchestrator.
module Petrus.Fabric.DemoSpec (spec, demoRun, demoLines) where

import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Fabric.Conformance.Demo (demoOps)
import Petrus.Fabric.Conformance.Haskell (fabricOps)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Conformance.Setup
import Petrus.Json (Json (..), typeExactEq)
import Petrus.TestSupport (PostgresTarget (..), lookupPostgresUrl, pythonExecutable, repoRoot, skipMessage, withScratchDatabase)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

haskell :: Launcher
haskell = haskellLauncher (\h -> [fabricOps h, demoOps h])

spec :: Spec
spec = describe "CV5 Fabric demo: Engine-level checks (spec/fabric-conformance.md)" $ do
  describe "Haskell port" (dbGroup haskell engineChecks)
  describe "Python reference" (dbGroup pythonLauncher engineChecks)
  describe "across implementations" (interopGroup haskell interopChecks)
  describe "F-107 the demo with split roles across implementations" splitRoles

shouldBeJson :: Json -> Json -> Expectation
shouldBeJson actual expected =
  if typeExactEq actual expected
    then pure ()
    else expectationFailure ("expected " <> showJson expected <> "\n but got " <> showJson actual)

arrayOf :: Json -> [Json]
arrayOf = \case
  Array xs -> xs
  _ -> []

-- | Fresh parent and child names and credentials for one scenario.
data Names = Names {parent :: Text, child :: Text, parentCredential :: Text, childCredential :: Text}

fresh :: Impl -> Text -> IO Names
fresh impl tag = do
  suffix <- T.take 8 . T.filter (`elem` ['a' .. 'z']) . T.toLower . textOf <$> ok impl "issue_credential" []
  pc <- textOf <$> ok impl "issue_credential" []
  cc <- textOf <$> ok impl "issue_credential" []
  pure (Names (tag <> "-parent-" <> suffix) (tag <> "-child-" <> suffix) pc cc)
  where
    textOf = \case
      String s -> s
      _ -> ""

bootstrapOn :: Impl -> Text -> Names -> IO ()
bootstrapOn impl dsn p =
  () <$ ok impl "demo_bootstrap" [("dsn", String dsn), ("parent", String p.parent), ("child", String p.child), ("credentials", obj [(p.parent, String p.parentCredential), (p.child, String p.childCredential)])]

openOn :: Impl -> Text -> Names -> Text -> Bool -> IO Json
openOn impl dsn p role dropCustody =
  ok
    impl
    "demo_open"
    [ ("dsn", String dsn)
    , ("role", String role)
    , ("authority", String (if role == "parent" then p.parent else p.child))
    , ("parent", String p.parent)
    , ("child", String p.child)
    , ("credential", String (if role == "parent" then p.parentCredential else p.childCredential))
    , ("drop_custody", Bool dropCustody)
    ]

-- | The demo's request envelope, built by the implementation.
requestOf :: Impl -> Names -> IO Json
requestOf impl p =
  ok
    impl
    "envelope"
    [ ("delivery_id", String ("request-" <> p.parent))
    , ("sender", String p.parent)
    , ("recipient", String p.child)
    , ("source", "request")
    , ("correlation", String ("correlation-" <> p.parent))
    , ("payload", obj [("question", "ping")])
    , ("reply_route", Array [String p.parent, "reply"])
    ]

dsnText :: PostgresTarget -> Text
dsnText target = T.pack (BC.unpack target.targetUrl)

engineChecks :: SpecWith Ctx
engineChecks =
  it "F-100 a drained delivery is ExternalEventDelivered under its ingress identity; a redelivery appends nothing" $ \ctx -> do
    let dsn = dsnText ctx.target
    p <- fresh ctx.impl "f100"
    bootstrapOn ctx.impl dsn p
    parentRole <- openOn ctx.impl dsn p "parent" False
    ok ctx.impl "demo_drive" [("live", parentRole)] >>= (`shouldBeJson` "awaiting") . member "status"
    childRole <- openOn ctx.impl dsn p "child" False
    request <- requestOf ctx.impl p
    let identity = member "ingress_identity" request
    ok ctx.impl "demo_drain" [("live", childRole)] >>= (`shouldBeJson` Int 1)
    records <- arrayOf <$> ok ctx.impl "demo_records" [("live", childRole)]
    filter (\r -> case arrayOf r of [String "ExternalEventDelivered", _] -> True; _ -> False) records
      `shouldSatisfy` \case
        [r] -> case arrayOf r of [_, i] -> typeExactEq i identity; _ -> False
        _ -> False
    again <- ok ctx.impl "demo_deliver" [("live", childRole), ("envelope", member "data" request)]
    member "kind" again `shouldBeJson` "prior"
    later <- arrayOf <$> ok ctx.impl "demo_records" [("live", childRole)]
    length later `shouldBe` length records
    _ <- ok ctx.impl "demo_close" [("live", childRole)]
    _ <- ok ctx.impl "demo_close" [("live", parentRole)]
    pure ()

interopChecks :: SpecWith Pair
interopChecks =
  both "F-108 a recipient History written by one is resumed by the other; redelivery is the prior acknowledgement" $ \admin a b -> do
    _ <- pure admin
    let target = a.dsn
    p <- fresh a.impl "f108"
    bootstrapOn a.impl target p
    parentRole <- openOn a.impl target p "parent" False
    _ <- ok a.impl "demo_drive" [("live", parentRole)]
    request <- requestOf a.impl p
    -- a delivers into the child's History and "crashes" before acknowledging.
    crashed <- openOn a.impl target p "child" False
    first <- ok a.impl "demo_deliver" [("live", crashed), ("envelope", member "data" request)]
    member "kind" first `shouldBeJson` "fired"
    written <- length . arrayOf <$> ok a.impl "demo_records" [("live", crashed)]
    _ <- ok a.impl "demo_close" [("live", crashed)]
    -- b resumes that History: draining gets the prior acknowledgement.
    resumed <- openOn b.impl target p "child" False
    ok b.impl "demo_drain" [("live", resumed)] >>= (`shouldBeJson` Int 1)
    length . arrayOf <$> ok b.impl "demo_records" [("live", resumed)] >>= (`shouldBe` written)
    again <- ok b.impl "demo_deliver" [("live", resumed), ("envelope", member "data" request)]
    again `shouldBeJson` obj [("kind", "prior"), ("occurrence", member "occurrence" first)]
    sender <- ok a.impl "client" [("conn", a.conn), ("instance", String p.parent), ("credential", String p.parentCredential)]
    receipt <- ok a.impl "receipt" [("client", sender), ("delivery_id", String ("request-" <> p.parent))]
    member "state" receipt `shouldBeJson` "accepted"
    member "occurrence" receipt `shouldBeJson` member "occurrence" first
    -- and b finishes the conversation the other started.
    ok b.impl "demo_drive" [("live", resumed)] >>= (`shouldBeJson` "completed") . member "status"
    ok b.impl "demo_invocations" [("live", resumed)] >>= (`shouldBeJson` Int 1)
    _ <- ok a.impl "demo_drain" [("live", parentRole)]
    ok a.impl "demo_drive" [("live", parentRole)] >>= (`shouldBeJson` "completed") . member "status"
    mapM_ (\(i, l) -> ok i "demo_close" [("live", l)]) [(b.impl, resumed), (a.impl, parentRole)]

-- ---------------------------------------------------------------------------
-- F-107

-- | The lines every passing run prints (the reference test's assertions).
demoLines :: [Text]
demoLines =
  [ "overall: PASS"
  , "offline pending count: 1"
  , "parent: awaiting -> completed"
  , "discovery: "
  , "duplicate: accepted/true occurrence="
  , "replay: parent appends=0 invocations=0; child appends=0 invocations=0"
  , "in-flight crash resume: occurrence="
  , "dispatches=1 completed=true"
  , "local/split semantic-shape equality: true"
  ]

-- | Run a demo command; answers its stdout after checking it passed.
demoRun :: FilePath -> [String] -> IO Text
demoRun exe arguments = do
  (code, out, err) <- readCreateProcessWithExitCode (proc exe arguments) ""
  let evidence = out <> "\n--- stderr ---\n" <> err
  code `shouldBe` ExitSuccess
  mapM_ (\l -> (l `T.isInfixOf` T.pack out) `shouldBe` True) demoLines
  pure (T.pack evidence)

splitRoles :: Spec
splitRoles = do
  url <- runIO lookupPostgresUrl
  case url of
    Nothing -> it "runs" (pendingWith skipMessage)
    Just configured -> aroundAll (withScratchDatabase configured) $ do
      let haskellExe = findExecutable "cv5-fabric-demo" >>= maybe (fail "cv5-fabric-demo is not on PATH (build-tool-depends)") pure
          pythonScript = (\root -> root </> "upstream" </> "petrus" </> "scripts" </> "cv5-fabric-demo.py") <$> repoRoot
          mixed = (\root -> root </> "packages" </> "petrus-fabric" </> "test" </> "interop" </> "fabric_demo_mixed.py") <$> repoRoot
          dsn target = BC.unpack target.targetUrl
          pythonRole = do
            python <- pythonExecutable
            script <- pythonScript
            pure ("[" <> show python <> "," <> show script <> ",\"--internal-role\"]")
      it "Haskell orchestrator, Python child" $ \target -> do
        exe <- haskellExe
        role <- pythonRole
        _ <- demoRun exe ["--dsn", dsn target, "--child-command", role]
        pure ()
      it "Haskell orchestrator, Python parent" $ \target -> do
        exe <- haskellExe
        role <- pythonRole
        _ <- demoRun exe ["--dsn", dsn target, "--parent-command", role]
        pure ()
      it "Python orchestrator, Haskell child" $ \target -> do
        exe <- haskellExe
        python <- pythonExecutable
        script <- mixed
        _ <- demoRun python ["-B", script, "--dsn", dsn target, "--haskell-role", "child", "--haskell-exe", exe]
        pure ()
      it "Python orchestrator, Haskell parent" $ \target -> do
        exe <- haskellExe
        python <- pythonExecutable
        script <- mixed
        _ <- demoRun python ["-B", script, "--dsn", dsn target, "--haskell-role", "parent", "--haskell-exe", exe]
        pure ()

-- | Tier C's tooling (docs/hamsterdan.md §5.2, tier C), offline: each seam
-- a live run uses, with the reference and this port side by side, against
-- fakes. Nothing here reaches GitHub.
--
-- * The carried agent (@HAMSTERDAN_E2E_AGENTS@): the calls a recorded
--   journey made, carried to another repository, installation and heads,
--   get the same answers from @host_seams.CarriedRunner@ and
--   "Hamsterdan.E2E.Agents".
-- * The operators over a fixture: @e2e_operator.py@ (a runtime overlay of
--   @hamsterdan.operator@) and @hamsterdan-e2e-operator@ run @preflight@
--   and @inspect@ against a scripted @gh@ (@fake_gh.py@); outputs, exit
--   statuses and the @gh@ calls must be equal, and name only the fixture.
-- * The hosts' start (@rehearse_hosts.py@): both hosts under the §1.8
--   environment against @fake_github.py@ answer health and a webhook
--   alike, and end alike on SIGTERM and SIGINT; the reference's live tape
--   holds no secret.
-- * Live-shaped tapes (@live_style.py@): converge steps and sticky reads,
--   replayed into both hosts, which must agree.
-- * The normalizing comparator (@compare_tier_c.py@) on synthetic captures
--   (@test_compare_tier_c.py@), including ones that must fail.
-- * @scripts/e2e@: every command's @--dry-run@ runs nothing (a @gh@, @git@,
--   @curl@ or @cabal@ on PATH fails the test if called), writes nothing,
--   prints no secret, and prints what docs/e2e.md promises.
module TierCSpec (spec) where

import Control.Monad (forM, forM_, unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.E2E.Agents (CarriedRunner (..), carriedRunner, replaceStrings)
import Hamsterdan.E2E.Tape (Tape (..), canonical, field, member, readTape)
import Petrus.Json (Json (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import Support
import System.Directory (createDirectoryIfMissing, doesPathExist, findExecutable)
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process.Typed
import Test.Hspec

spec :: Spec
spec = describe "tier C tooling, against fakes" $ do
  carried
  operators
  rehearsal
  liveStyle
  comparator
  dryRuns

-- ---------------------------------------------------------------------------
-- The carried agent

carried :: Spec
carried = describe "the carried agent (HAMSTERDAN_E2E_AGENTS)" $
  forM_ [("true_conflict_resolution", Nothing), ("seeded_review_finding, its agent call failing", Just "agent")] $ \(name, fault) ->
    it ("answers " <> name <> " carried to another repository alike in both hosts") $ withRoot $ \dir -> do
      let journey = takeWhile (/= ',') name
      (interpreter, tapePath) <- record dir journey fault
      recorded <- readTape tapePath
      moved <- mapM carry recorded.agents
      let calls = case moved of
            -- The first call once more (its record is spent) and a call
            -- nothing recorded: both unknown.
            first : _ -> moved <> [first, obj [("kind", String "code"), ("operation", String "mutation:never:recorded"), ("attempt", Int 1), ("request", obj [])]]
            [] -> []
      length moved `shouldSatisfy` (> 0)
      BS.writeFile (dir </> "calls.jsonl") (BS.concat [TE.encodeUtf8 (canonical call) <> "\n" | call <- calls])
      out <- script interpreter "carry_check.py" [tapePath, dir </> "calls.jsonl"]
      python <- mapM readJson (BC.lines out)
      runner <- carriedRunner recorded
      answers <- forM calls $ \call -> do
        kind <- field "kind" call
        operation <- field "operation" call
        attempt <- field "attempt" call
        runner.answer kind operation attempt =<< field "request" call
      report <- runner.report
      let haskell = answers <> [obj [("unknown", member "unknown" report)]]
      map canonical haskell `shouldBe` map canonical python
      unknown <- field @[Json] "unknown" report
      length unknown `shouldBe` 2
      -- A carried result speaks of the new request only.
      let old = "owner/repo" : [value | record' <- recorded.agents, name' <- ["head", "base"], String value <- [member name' (member "request" record')]]
      forM_ (zip calls answers) $ \(call, answer) -> case member "result" answer of
        Null -> pure ()
        result -> do
          forM_ ["kind", "repository", "pull_request", "epoch", "head", "base", "ref"] $ \key ->
            unless (member key result == Null) $ member key result `shouldBe` member key (member "request" call)
          forM_ old $ \value -> T.unpack (canonical result) `shouldNotContain` T.unpack value
      unless (fault == Nothing) $
        [() | answer <- answers, member "class" (member "error" answer) == String "AgentProtocolError", member "timed_out" (member "error" answer) == Bool True]
          `shouldSatisfy` (not . null)

-- | A recorded call moved to @seasonedcc/demo-pr-readiness-hs@,
-- installation 4401, repository 3101, pull request 12 and reversed heads.
carry :: Json -> IO Json
carry recorded = do
  operation <- field "operation" recorded
  pure $
    obj
      [ ("kind", member "kind" recorded)
      , ("operation", String (T.replace ":pr:7:" ":pr:12:" (T.replace "github:44:31:" "github:4401:3101:" (strings operation))))
      , ("attempt", member "attempt" recorded)
      , ("request", setMember "pull_request" (Int 12) (replaceStrings replacements (member "request" recorded)))
      ]
  where
    replacements =
      ("owner/repo", "seasonedcc/demo-pr-readiness-hs")
        : [(value, T.reverse value) | name <- ["head", "base"], String value <- [member name (member "request" recorded)]]
    strings value = case replaceStrings replacements (String value) of
      String replaced -> replaced
      _ -> value

setMember :: Text -> Json -> Json -> Json
setMember name value = \case
  Object members -> Object [(key, if key == name then value else old) | (key, old) <- members]
  other -> other

obj :: [(Text, Json)] -> Json
obj = Object

-- ---------------------------------------------------------------------------
-- The operators over a fixture

data OperatorCase = OperatorCase
  { name :: String
  , arguments :: [String]
  , answers :: [(Text, [(Text, Int)])]
  , ok :: Bool
  }

repository, organization, slug, bot, legacyBot :: Text
repository = "seasonedcc/demo-pr-readiness-hs"
organization = "seasonedcc"
slug = "hamster-dan-hs"
bot = slug <> "[bot]"
legacyBot = "hamster-dan[bot]"

-- | The copy's rerun broker and validator (@scripts/e2e prepare-repos@
-- substitutes the bot login); their digests go in the fixture.
brokerSource, validatorSource :: Text
brokerSource = "name: rerun-broker\non: issue_comment\njobs:\n  rerun:\n    steps:\n      - run: python tools/rerun_broker.py\n"
validatorSource = "APP_BOT_LOGIN = '" <> bot <> "'\n"

operatorCases :: [OperatorCase]
operatorCases =
  [ OperatorCase "preflight, the copy's delegated broker" ["preflight"] (preflightAnswers brokerSource (Just validatorSource)) True
  , OperatorCase "preflight, a broker authorizing the fixture's bot" ["preflight"] (preflightAnswers (inlineBroker bot) Nothing) True
  , OperatorCase "preflight, a broker still authorizing HBNetwork's bot" ["preflight"] (preflightAnswers (inlineBroker legacyBot) Nothing) False
  , OperatorCase "inspect, comments by the fixture's bot" ["inspect", "--pr", "7"] (inspectAnswers bot) True
  , OperatorCase "inspect, comments by HBNetwork's bot" ["inspect", "--pr", "7"] (inspectAnswers legacyBot) False
  ]

inlineBroker :: Text -> Text
inlineBroker login =
  "if: startsWith(github.event.comment.body, '<!-- hamsterdan-rerun ') &&\n      github.event.comment.user.type == 'Bot' &&\n      github.event.comment.user.login == '"
    <> login
    <> "' &&\n# <!-- hamsterdan-rerun run=\n"

api :: Text -> Json -> (Text, [(Text, Int)])
api path value = ("api " <> path, [(canonical value, 0)])

repo :: Text -> Text
repo suffix = "/repos/" <> repository <> suffix

preflightAnswers :: Text -> Maybe Text -> [(Text, [(Text, Int)])]
preflightAnswers broker validator =
  [ ("auth status", [("", 0)])
  , api ("/orgs/" <> organization) (obj [("id", Int 4242)])
  , api (repo "") (obj [("id", Int 777), ("private", Bool False), ("default_branch", String "main")])
  , api (repo "/actions/workflows?per_page=100") (obj [("workflows", Array [obj [("name", String "ci")], obj [("name", String "rerun-broker")]])])
  , (raw ".github/workflows/rerun-broker.yml", [(broker, 0)])
  ]
    <> [(raw "tools/rerun_broker.py", [(source, 0)]) | Just source <- [validator]]
  where
    raw path = "api " <> repo ("/contents/" <> path <> "?ref=main") <> " -H Accept: application/vnd.github.raw+json"

inspectAnswers :: Text -> [(Text, [(Text, Int)])]
inspectAnswers login =
  [ api (repo "/pulls/7") (obj [("html_url", String "https://github.test/pr/7"), ("state", String "open"), ("draft", Bool False), ("head", obj [("sha", String sha), ("ref", String "hamsterdan/demo")]), ("base", obj [("ref", String "main"), ("repo", obj [("id", Int 777)])])])
  , api (repo "/issues/7/comments?per_page=100") (Array [comment 1 "dashboard\n<!-- hamsterdan:dashboard -->", comment 2 ("readiness\n<!-- hamsterdan:readiness operation=readiness:1 head=" <> sha <> " -->"), comment 3 ("<!-- hamsterdan-rerun run=5 head=" <> sha <> " operation=rerun:5 -->")])
  , api (repo "/pulls/7/comments?per_page=100") (Array [])
  , api (repo ("/commits/" <> sha)) (obj [("commit", obj [("author", obj [("name", String "Author")]), ("committer", obj [("name", String "Committer")])]), ("author", obj [("login", String "second-account")]), ("committer", obj [("login", String login)])])
  , api (repo ("/actions/runs?event=pull_request&head_sha=" <> sha <> "&per_page=100")) (obj [("workflow_runs", Array [obj [("id", Int 5), ("name", String "ci"), ("run_attempt", Int 1), ("head_sha", String sha), ("status", String "completed"), ("conclusion", String "success"), ("html_url", String "https://github.test/run/5")]])])
  , api (repo "/actions/runs/5/attempts/1/jobs?per_page=100") (obj [("jobs", Array [obj [("id", Int 9), ("name", String "test"), ("status", String "completed"), ("conclusion", String "success")]])])
  ]
  where
    sha = "0123456789abcdef0123456789abcdef01234567"
    comment :: Integer -> Text -> Json
    comment identity body = obj [("id", Int identity), ("html_url", String ("https://github.test/c/" <> T.pack (show identity))), ("body", String body), ("user", obj [("login", String login)])]

operators :: Spec
operators = describe "the operators over a fixture (a scripted gh)" $
  forM_ operatorCases $ \c ->
    it c.name $ withRoot $ \dir -> do
      interpreter <- upstreamPythonExecutable "hamsterdan"
      fake <- scriptPath "fake_gh.py"
      let bin = dir </> "bin"
      createDirectoryIfMissing True bin
      BS.writeFile (bin </> "gh") (BC.pack ("#!/bin/sh\nexec '" <> interpreter <> "' -I -B '" <> fake <> "' \"$@\"\n"))
      setFileMode (bin </> "gh") 0o700
      let fixture =
            obj
              [ ("repository", String repository)
              , ("organization", String organization)
              , ("org_id", Int 4242)
              , ("repository_id", Int 777)
              , ("app_slug", String slug)
              , ("hero_reviewer", String "second-account")
              , ("broker_digest", String (digestOf brokerSource))
              , ("validator_digest", String (digestOf validatorSource))
              ]
      BS.writeFile (dir </> "fixture.json") (TE.encodeUtf8 (canonical fixture))
      BS.writeFile (dir </> "answers.json") (TE.encodeUtf8 (canonical (obj [(key, Array [obj [("stdout", String out), ("code", Int (toInteger code))] | (out, code) <- outs]) | (key, outs) <- c.answers])))
      inherited <- getEnvironment
      let environment side =
            [("PATH", bin <> ":" <> maybe "/usr/bin:/bin" id (lookup "PATH" inherited)), ("FAKE_GH_SCRIPT", dir </> "answers.json"), ("FAKE_GH_LOG", dir </> side <> ".jsonl")]
              <> [(key, value) | (key, value) <- inherited, key `notElem` ["PATH", "FAKE_GH_SCRIPT", "FAKE_GH_LOG"]]
          run side command = do
            (status, out, _) <- readProcess (setEnv (environment side) command)
            calls <- BS.readFile (dir </> side <> ".jsonl")
            pure (status, BL.toStrict out, calls)
      overlay <- scriptPath "e2e_operator.py"
      haskellOperator <- findExecutable "hamsterdan-e2e-operator" >>= maybe (fail "hamsterdan-e2e-operator is not on PATH (build-tool-depends)") pure
      python@(pythonStatus, pythonOut, pythonCalls) <- run "python" (proc interpreter (["-I", "-B", overlay, dir </> "fixture.json"] <> c.arguments))
      haskell <- run "haskell" (proc haskellOperator ((dir </> "fixture.json") : c.arguments))
      haskell `shouldBe` python
      pythonStatus `shouldBe` (if c.ok then ExitSuccess else ExitFailure 1)
      output <- readJson pythonOut
      member "ok" output `shouldBe` Bool c.ok
      -- Every call names the fixture, never HBNetwork's repository.
      BC.unpack pythonCalls `shouldNotContain` "HBNetwork"
      BC.unpack pythonCalls `shouldContain` T.unpack repository
  where
    -- @operator._broker_digest@.
    digestOf source = TE.decodeUtf8 (Base16.encode (SHA256.hash (TE.encodeUtf8 (T.strip source))))

-- ---------------------------------------------------------------------------
-- The hosts' start

rehearsal :: Spec
rehearsal = describe "the hosts' start (rehearse_hosts.py, a fake GitHub)" $
  forM_ [("SIGTERM", "TERM", Int (-15)), ("SIGINT", "INT", Int 0)] $ \(name, signal, status) ->
    it ("start, answer health and a webhook, and end on " <> name <> " alike") $ withRoot $ \dir -> do
      (interpreter, tapePath) <- record (dir </> "recorded") "clean_green" Nothing
      host <- findExecutable "hamsterdan-e2e-host" >>= maybe (fail "hamsterdan-e2e-host is not on PATH (build-tool-depends)") pure
      out <- script interpreter "rehearse_hosts.py" ["--work", dir </> "rehearse", "--reference", interpreter, "--haskell-host", host, "--agents", tapePath, "--signal", signal]
      report <- readJson out
      let python = member "python" report
          haskell = member "haskell" report
      forM_ ["health", "webhook", "exit", "github"] $ \key ->
        member key haskell `shouldBe` member key python
      member "exit" python `shouldBe` status
      member "health" python `shouldSatisfy` (\case Array (Int 200 : _) -> True; _ -> False)
      webhook <- field @[Json] "webhook" python
      map (member "disposition") (drop 1 webhook) `shouldSatisfy` (\case String "accepted" : _ -> True; _ -> False)
      github <- field @[Json] "github" python
      map (member "kind") github `shouldNotContain` [String "unanswered"]
      member "secrets_on_disk" report `shouldBe` Array []
      ops <- mapM (field @Text "op") =<< field @[Json] "tape_steps" python
      take 2 ops `shouldBe` ["registry", "deliver"]
      ops `shouldContain` ["close"]
      member "source" (member "tape_meta" python) `shouldBe` String "live"

-- ---------------------------------------------------------------------------
-- Live-shaped tapes

liveStyle :: Spec
liveStyle = describe "live-shaped tapes (converge steps, sticky reads)" $
  forM_ ["clean_green", "agent_repair", "true_conflict_resolution"] $ \journey ->
    it ("replay " <> journey <> " alike in both hosts") $ withRoot $ \dir -> do
      (interpreter, tapePath) <- record dir journey Nothing
      let live = dir </> "live"
      _ <- script interpreter "live_style.py" [tapePath, live]
      shaped <- readTape live
      ops <- mapM (field @Text "op") shaped.steps
      ops `shouldContain` ["converge"]
      ops `shouldNotContain` ["process"]
      python <- replayPython interpreter ["--sticky-reads"] live (dir </> "python")
      haskell <- replayHaskell interpreter ["--sticky-reads"] live (dir </> "haskell")
      (status, report) <- compareSides interpreter live Nothing [("python", python), ("haskell", haskell)] ["--allow-unused"]
      unless (status == ExitSuccess && member "ok" report == Bool True) $
        expectationFailure ("the live-shaped replays differ:\n" <> render report)
      case member "writes" (member "haskell" (member "summary" report)) of
        Int writes -> writes `shouldSatisfy` (> 0)
        other -> expectationFailure ("no write count: " <> show other)

-- ---------------------------------------------------------------------------
-- The comparator

comparator :: Spec
comparator = describe "the normalizing comparator (compare_tier_c.py)" $
  it "passes and fails synthetic captures as docs/hamsterdan.md §5.2 tier C step 5 says" $ do
    interpreter <- upstreamPythonExecutable "hamsterdan"
    path <- scriptPath "test_compare_tier_c.py"
    (status, _, err) <- readProcess (proc interpreter ["-I", "-B", path])
    unless (status == ExitSuccess) $ expectationFailure ("test_compare_tier_c.py:\n" <> BC.unpack (BL.toStrict err))
    BC.unpack (BL.toStrict err) `shouldContain` "OK"

-- ---------------------------------------------------------------------------
-- scripts/e2e --dry-run

dryRuns :: Spec
dryRuns = describe "scripts/e2e --dry-run" $
  it "runs nothing, writes nothing, prints no secret, and prints the plan" $ withRoot $ \dir -> do
    interpreter <- upstreamPythonExecutable "hamsterdan"
    root <- repoRoot
    let bin = dir </> "bin"
        called = dir </> "called"
        e2e = root </> "scripts" </> "e2e"
        config = dir </> "config.json"
        secret = "sk-tier-c-dry-run-must-not-print"
    createDirectoryIfMissing True bin
    forM_ ["gh", "git", "curl", "cabal"] $ \tool -> do
      BS.writeFile (bin </> tool) (BC.pack ("#!/bin/sh\necho " <> tool <> " \"$@\" >> '" <> called <> "'\nexit 1\n"))
      setFileMode (bin </> tool) 0o700
    inherited <- getEnvironment
    let environment =
          [("PATH", bin <> ":" <> maybe "/usr/bin:/bin" id (lookup "PATH" inherited)), ("HAMSTERDAN_PI_API_KEY", secret)]
            <> [(key, value) | (key, value) <- inherited, key `notElem` ["PATH", "HAMSTERDAN_PI_API_KEY"]]
        e2eRun arguments = do
          (status, out, err) <- readProcess (setEnv environment (proc interpreter (["-I", "-B", e2e, "--config", config] <> arguments)))
          unless (status == ExitSuccess) $ expectationFailure (unwords arguments <> ":\n" <> BC.unpack (BL.toStrict err))
          pure (BC.unpack (BL.toStrict out))
    _ <- e2eRun ["init"]
    template <- BS.readFile config
    BS.writeFile config (TE.encodeUtf8 (T.replace "\"e2e-work\"" (T.pack (show (dir </> "work"))) (TE.decodeUtf8 template)))
    prepare <- e2eRun ["prepare-repos", "--dry-run"]
    prepare `shouldContain` "a83e9223f7ffc6b0af919b0b8261fa2578261b41"
    prepare `shouldContain` "gh repo create seasonedcc/demo-pr-readiness-py --public"
    prepare `shouldContain` "hamster-dan[bot] -> hamster-dan-hs[bot]"
    prepare `shouldContain` "\"required_review_thread_resolution\": true"
    manifests <- e2eRun ["manifests", "--dry-run"]
    manifests `shouldContain` "https://github.com/organizations/seasonedcc/settings/apps/new?state=hamsterdan-e2e-haskell"
    forM_ ["\"issue_comment\"", "\"pull_request_review_thread\"", "\"workflow_run\"", "\"administration\": \"read\"", "\"contents\": \"write\"", "\"pull_requests\": \"write\""] $ \needle ->
      manifests `shouldContain` needle
    convert <- e2eRun ["convert-manifest", "--side", "python", "--code", "abc123", "--dry-run"]
    convert `shouldContain` "https://api.github.com/app-manifests/abc123/conversions"
    hosts <- e2eRun ["start-hosts", "--dry-run"]
    forM_ ["HAMSTERDAN_REMINDER_SECONDS=300", "HAMSTERDAN_GITHUB_PRIVATE_KEY=<redacted>", "HAMSTERDAN_PI_API_KEY=<redacted>", "e2e_host.py validate", "hamsterdan-e2e-host) serve"] $ \needle ->
      hosts `shouldContain` needle
    stop <- e2eRun ["stop-hosts", "--dry-run"]
    stop `shouldContain` "kill -TERM"
    scenarios <- forM ["clean-green", "first-attempt-flake", "hero-review", "draft-ready", "collaboration-approval", "stale-base", "true-conflict"] $ \scenario ->
      e2eRun ["run-scenario", "--scenario", scenario, "--dry-run"]
    concat scenarios `shouldContain` "e2e_operator.py"
    concat scenarios `shouldContain` "hamsterdan-e2e-operator)"
    concat scenarios `shouldContain` "gh pr review '<pr:main>' --repo seasonedcc/demo-pr-readiness-hs --approve"
    captured <- e2eRun ["capture", "--scenario", "hero-review", "--checkpoint", "final", "--dry-run"]
    forM_ ["inspect --pr", "hamsterdan.host.export", "/healthz", "reviewThreads"] $ \needle ->
      captured `shouldContain` needle
    rehearse <- e2eRun ["rehearse", "--dry-run"]
    rehearse `shouldContain` "rehearse_hosts.py"
    let printed = concat ([prepare, manifests, convert, hosts, stop, captured, rehearse] <> scenarios)
    printed `shouldNotContain` secret
    doesPathExist called `shouldReturn` False
    doesPathExist (dir </> "work") `shouldReturn` False

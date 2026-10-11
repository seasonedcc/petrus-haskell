-- | The command line, differentially: every case runs both
-- @python -m hamsterdan.operator@ (the upstream reference, through
-- 'upstreamPythonExecutable') and the @hamsterdan-operator@ binary in two
-- identically laid out side directories whose @PATH@ starts with scripted
-- fakes of @gh@, @git@, @curl@ and @python@ ("Fakes"). The exit code,
-- standard output, standard error (a Python traceback reduced to its last
-- line, which is what the port prints), the external commands each side
-- ran (argument vectors and working directories, in order) and every file
-- left behind (paths, modes and bytes) must be equal once the side's own
-- root, temporary-directory suffixes and UTC time stamps are normalized.
module DifferentialSpec (spec) where

import Control.Monad (forM, forM_, unless)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Fakes (normalizeText, wrapperScript, writeExecutable)
import Hamsterdan.Python.Object (PV (..))
import Hamsterdan.Operator (Completed (..), appBotLogin, authorityReviewFacts)
import OperatorSpec
  ( authorityResponses
  , current
  , inspectionResponses
  , legacy
  , prListKey
  , preflightInventory
  , pullPath
  , repoPath
  , rulesPath
  , sha
  )
import Petrus.Json (Json (..), compact, dumps)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Support (Response (..), bool, encoded, int, list, merge, none, obj, setPath, str)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , listDirectory
  )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getSymbolicLinkStatus, isDirectory, setFileMode)
import System.Posix.Types (FileMode)
import System.Process.Typed (proc, readProcess, setEnv, setStdin, setWorkingDir, nullStream)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Cases

data Case = Case
  { name :: String
  , argv :: [Text]
  -- ^ @<root>@ stands for the side's directory.
  , responses :: [(Text, [Json])]
  -- ^ Normalized command line to the scripted answers, in call order.
  , files :: [(FilePath, BS.ByteString, FileMode)]
  , directories :: [(FilePath, FileMode)]
  , columns :: Text
  , pythonCode :: Int
  -- ^ The reference's exit code: a guard that the case exercises the path
  -- it is meant to (a mis-scripted fake would fail both sides alike).
  }

base :: String -> [Text] -> Int -> Case
base name argv pythonCode =
  Case {name, argv, responses = [], files = [], directories = [], columns = "80", pythonCode}

with :: [(Text, [Json])] -> Case -> Case
with extra c = c {responses = c.responses <> extra}

answer :: Text -> Json
answer out = Object [("stdout", String out), ("returncode", Int 0)]

value :: PV -> Json
value = answer . encoded

failing :: Int -> Json
failing code = Object [("stdout", String "private provider output"), ("stderr", String "private diagnostics"), ("returncode", Int (toInteger code))]

cloned :: Text -> Json
cloned template = Object [("returncode", Int 0), ("template", String template)]

-- | The 'OperatorSpec' fixtures as scripted command lines.
scripted :: [(Text, Response)] -> [(Text, [Json])]
scripted = map \(key, response) -> (commandLine key, [json response])
  where
    commandLine key
      | "/" `T.isPrefixOf` key = "gh api " <> key
      | key == "graphql" = graphqlKey 9
      | otherwise = key
    json = \case
      Value (PStr s) -> answer s
      Value v -> value v
      Done c -> Object [("stdout", String c.stdout), ("stderr", String c.stderr), ("returncode", Int (toInteger c.returncode))]

graphqlKey :: Integer -> Text
graphqlKey number =
  T.unwords
    [ "gh api graphql -f"
    , "query=" <> authorityReviewFacts
    , "-F owner=HBNetwork -F repository=demo-pr-readiness -F"
    , "number=" <> T.pack (show number)
    ]

raw :: Text -> Text
raw path = "gh api " <> repoPath ("/contents/" <> path <> "?ref=main") <> " -H Accept: application/vnd.github.raw+json"

-- ---------------------------------------------------------------------------
-- Argument parsing

parsingCases :: [Case]
parsingCases =
  [ base "no arguments" [] 2
  , base "--help" ["--help"] 0
  , base "-h, narrow" ["-h"] 0 `withColumns` "40"
  , base "unknown command" ["bogus"] 2
  , base "preflight --help" ["preflight", "--help"] 0
  , base "create --help" ["create", "--help"] 0
  , base "inspect --help" ["inspect", "--help"] 0
  , base "inspect-authority --help" ["inspect-authority", "--help"] 0
  , base "qualification-setup --help" ["qualification-setup", "--help"] 0
  , base "prepare-broker --help, wide" ["prepare-broker", "--help"] 0 `withColumns` "200"
  , base "create without --scenario" ["create"] 2
  , base "create with an unsupported scenario" ["create", "--scenario", "bogus"] 2
  , base "inspect with a non-integer --pr" ["inspect", "--pr", "seven"] 2
  , base "inspect with an unsupported readiness" ["inspect", "--pr", "7", "--expect-readiness", "maybe"] 2
  , base "inspect-authority without --expect" ["inspect-authority", "--pr", "9"] 2
  , base "inspect-authority with an unsupported expectation" ["inspect-authority", "--pr", "9", "--expect", "merged"] 2
  , base "qualification-setup without its files" ["qualification-setup"] 2
  , base "preflight with an unknown option" ["preflight", "--verbose"] 2
  , base "preflight --health-url without a value" ["preflight", "--health-url"] 2
  ]
  where
    withColumns c columns = c {columns}

-- ---------------------------------------------------------------------------
-- preflight

inventory :: [(Text, [Json])]
inventory = scripted preflightInventory <> [(raw ".github/workflows/rerun-broker.yml", [answer legacy])]

preflightCases :: [Case]
preflightCases =
  [ with inventory (base "preflight with a legacy broker" ["preflight"] 0)
  , with (replace (raw ".github/workflows/rerun-broker.yml") [answer current] inventory) (base "preflight with the App broker" ["preflight"] 0)
  , with (replace "gh auth status" [failing 1] inventory) (base "preflight without gh authentication" ["preflight"] 1)
  , base "preflight with no provider at all" ["preflight"] 1
  , with
      (replace ("gh api /orgs/HBNetwork") [answer "{not json"] inventory)
      (base "preflight with malformed provider JSON" ["preflight"] 1)
  , with
      (replace ("gh api /orgs/HBNetwork") [answer ""] inventory)
      (base "preflight with an empty organization answer" ["preflight"] 1)
  , with
      (replace ("gh api /orgs/HBNetwork") [value (list [])] inventory)
      (base "preflight with a non-object organization" ["preflight"] 1)
  , with
      ( replace
          ("gh api " <> repoPath "")
          [value (obj [("id", int 1), ("private", bool True), ("default_branch", str "trunk")])]
          (replace ("gh api " <> repoPath "/actions/workflows?per_page=100") [value (obj [("workflows", list [obj [("name", str "ci")], str "x", obj [("name", int 3)]])])] inventory)
      )
      (base "preflight with a wrong repository and missing workflows" ["preflight"] 1)
  , with
      (replace (raw ".github/workflows/rerun-broker.yml") [answer "uses tools/rerun_broker.py\n"] inventory)
      (base "preflight with a delegated broker whose validator is unavailable" ["preflight"] 1)
  , with
      ( replace (raw ".github/workflows/rerun-broker.yml") [answer "uses tools/rerun_broker.py\n"] inventory
          <> [(raw "tools/rerun_broker.py", [answer "validator"])]
      )
      (base "preflight with a delegated broker of the wrong digest" ["preflight"] 1)
  , with
      (inventory <> [(curl "http://host.test/healthz", [value (obj [("status", str "ok")])])])
      (base "preflight with a healthy host" ["preflight", "--health-url", "http://host.test///"] 0)
  , with
      (inventory <> [(curl "http://host.test/healthz", [answer "[]"])])
      (base "preflight with a non-object health answer" ["preflight", "--health-url", "http://host.test"] 1)
  , with
      (inventory <> [(curl "http://host.test/healthz", [answer "nope"])])
      (base "preflight with a malformed health answer" ["preflight", "--health-url", "http://host.test"] 1)
  , with inventory (base "preflight with an unreachable host" ["preflight", "--health-url", "http://host.test"] 1)
  , with inventory (base "preflight with an empty health URL" ["preflight", "--health-url", ""] 0)
  ]
  where
    curl url = "curl --fail --silent --show-error --max-time 10 " <> url

replace :: Text -> [Json] -> [(Text, [Json])] -> [(Text, [Json])]
replace key answers entries = [(k, if k == key then answers else v) | (k, v) <- entries] <> [(key, answers) | key `notElem` map fst entries]

-- ---------------------------------------------------------------------------
-- create

creation :: Text -> [(Text, [Json])]
creation scenario =
  [ ("git clone --origin origin https://github.com/HBNetwork/demo-pr-readiness.git <root>/tmp/hamsterdan-operator-X/demo-pr-readiness", [cloned "template"])
  , ("git fetch origin main", [answer ""])
  , ("git switch --create " <> branch <> " origin/main", [answer ""])
  , ("python tools/scenario_control.py prepare " <> scenario, [value (obj [("admitted_changed_paths", list [str ".pr-lab/scenario.json", str "notes.md"])])])
  , ("python tools/scenario_control.py --attempt 2", [answer "prepared\n"])
  , ("git diff --name-only", [answer ".pr-lab/scenario.json\n"])
  , ("git ls-files --others --exclude-standard", [answer "notes.md\n"])
  , ("git add -- .pr-lab/scenario.json notes.md", [answer ""])
  , ("git commit -m Hamsterdan demo: " <> scenario, [answer ""])
  , ("git diff --name-only origin/main...HEAD", [answer ".pr-lab/scenario.json\nnotes.md\n"])
  , ("git push --set-upstream origin " <> branch, [answer ""])
  , ( "gh pr create --repo HBNetwork/demo-pr-readiness --base main --head " <> branch <> " --title Hamsterdan demo: " <> scenario
        <> " --body Controlled Hamsterdan qualification scenario. Do not merge automatically."
    , [answer "https://github.test/pr/12\n"]
    )
  , ( "gh pr view " <> branch <> " --repo HBNetwork/demo-pr-readiness --json number,url,headRefName"
    , [value (obj [("number", int 12), ("url", str "https://github.test/pr/12"), ("headRefName", str branch)])]
    )
  , ("gh api --method POST " <> repoPath "/pulls/12/requested_reviewers" <> " -f reviewers[]=crisbastos", [answer "{}"])
  , ("git rev-parse HEAD", [answer (sha 'd' <> "\n")])
  ]
  where
    branch = "hamsterdan/" <> scenario <> "-<stamp>"

templateFiles :: [(FilePath, BS.ByteString, FileMode)]
templateFiles = [("template/README.md", "demo\n", 0o644)]

createCases :: [Case]
createCases =
  [ creating "clean-green" (base "create clean-green" ["create", "--scenario", "clean-green"] 0) id
  , creating "hero-review" (base "create hero-review requests the hero reviewer" ["create", "--scenario", "hero-review"] 0) id
  , creating "first-attempt-flake" (base "create first-attempt-flake" ["create", "--scenario", "first-attempt-flake"] 0) id
  , creating "clean-green" (base "create when the clone fails" ["create", "--scenario", "clean-green"] 1) \entries ->
      replace (fst (head' entries)) [failing 128] entries
  , creating "clean-green" (base "create with admitted paths missing the scenario" ["create", "--scenario", "clean-green"] 1) $
      replace "python tools/scenario_control.py prepare clean-green" [value (obj [("admitted_changed_paths", list [str "notes.md"])])]
  , creating "clean-green" (base "create with non-string admitted paths" ["create", "--scenario", "clean-green"] 1) $
      replace "python tools/scenario_control.py prepare clean-green" [value (obj [("admitted_changed_paths", list [str ".pr-lab/scenario.json", int 3])])]
  , creating "clean-green" (base "create with a non-object preparation" ["create", "--scenario", "clean-green"] 1) $
      replace "python tools/scenario_control.py prepare clean-green" [value (list [str ".pr-lab/scenario.json"])]
  , creating "clean-green" (base "create with malformed preparation JSON" ["create", "--scenario", "clean-green"] 1) $
      replace "python tools/scenario_control.py prepare clean-green" [answer "{"]
  , creating "clean-green" (base "create refuses unexpected changed paths" ["create", "--scenario", "clean-green"] 1) $
      replace "git ls-files --others --exclude-standard" [answer "secret.txt\nnotes.md\nété.txt\n"]
  , creating "clean-green" (base "create refuses an empty change" ["create", "--scenario", "clean-green"] 1) $
      replace "git diff --name-only" [answer ""] . replace "git ls-files --others --exclude-standard" [answer ""]
  , creating "clean-green" (base "create refuses a commit that differs from the change" ["create", "--scenario", "clean-green"] 1) $
      replace "git diff --name-only origin/main...HEAD" [answer "notes.md\nother.md\n"]
  , creating "clean-green" (base "create when the pull request cannot be created" ["create", "--scenario", "clean-green"] 1) $
      replace' "gh pr create" [failing 1]
  , creating "clean-green" (base "create with a non-object pull request" ["create", "--scenario", "clean-green"] 1) $
      replace' "gh pr view" [value (list [int 12])]
  , creating "hero-review" (base "create hero-review with a pull request lacking its number" ["create", "--scenario", "hero-review"] 1) $
      replace' "gh pr view" [value (obj [("url", str "https://github.test/pr/12")])]
  , creating "clean-green" (base "create with an empty pull request answer" ["create", "--scenario", "clean-green"] 1) $
      replace' "gh pr view" [answer "  \n"]
  ]
  where
    creating scenario c f = (with (f (creation scenario)) c) {files = templateFiles}
    replace' prefix answers entries = [(k, if prefix `T.isPrefixOf` k then answers else v) | (k, v) <- entries]
    head' = \case
      entry : _ -> entry
      [] -> error "no entries"

-- ---------------------------------------------------------------------------
-- prepare-broker

brokerCases :: [Case]
brokerCases =
  [ with
      [(prListKey, [value (list [obj [("headRefName", str "other")], obj [("number", int 4), ("url", str "https://github.test/pr/4"), ("headRefName", str "hamsterdan/broker-cutover-1")]])])]
      (base "prepare-broker finds a prepared pull request" ["prepare-broker"] 0)
  , brokered (template current) (base "prepare-broker with a current broker" ["prepare-broker"] 0) id
  , brokered (template legacy) (base "prepare-broker transforms a legacy broker" ["prepare-broker"] 0) id
  , brokered (template (legacy <> legacy)) (base "prepare-broker refuses a malformed broker" ["prepare-broker"] 1) id
  , brokered (template "neither\n" <> [("template/tools/rerun_broker.py", "validator\n", 0o644)]) (base "prepare-broker refuses a broker with an unrecognized validator" ["prepare-broker"] 1) id
  , brokered [("template/README.md", "no broker\n", 0o644)] (base "prepare-broker with no broker in the checkout" ["prepare-broker"] 1) id
  , brokered (template "caf\xc3\xa9 \xff\n") (base "prepare-broker with a broker that is not UTF-8" ["prepare-broker"] 1) id
  , brokered (template legacy) (base "prepare-broker when the push fails" ["prepare-broker"] 1) $
      replace "git push --set-upstream origin hamsterdan/broker-cutover-<stamp>" [failing 1]
  , with [(prListKey, [value (obj [("headRefName", str "hamsterdan/broker-cutover-1")])])] (base "prepare-broker with a non-list search answer" ["prepare-broker"] 1)
  , with [(prListKey, [failing 4])] (base "prepare-broker when the search fails" ["prepare-broker"] 1)
  , with [(prListKey, [value (list [obj [("headRefName", str "hamsterdan/broker-cutover-1")]])])] (base "prepare-broker with a prepared pull request lacking its number" ["prepare-broker"] 1)
  ]
  where
    template source = [("template/.github/workflows/rerun-broker.yml", TE.encodeUtf8 source, 0o644)]
    brokered files c f = (with (f preparation) c) {files}
    preparation =
      [ (prListKey, [value (list [obj [("headRefName", str "someone/else")]])])
      , ("git clone --origin origin https://github.com/HBNetwork/demo-pr-readiness.git <root>/tmp/hamsterdan-broker-X/demo-pr-readiness", [cloned "template"])
      , ("git fetch origin main", [answer ""])
      , ("git switch --create hamsterdan/broker-cutover-<stamp> origin/main", [answer ""])
      , ("git add -- .github/workflows/rerun-broker.yml", [answer ""])
      , ("git commit -m Hamsterdan broker identity cutover", [answer ""])
      , ("git diff --name-only origin/main...HEAD", [answer ".github/workflows/rerun-broker.yml\n"])
      , ("git push --set-upstream origin hamsterdan/broker-cutover-<stamp>", [answer ""])
      , ( "gh pr create --repo HBNetwork/demo-pr-readiness --base main --head hamsterdan/broker-cutover-<stamp> --title Hamsterdan broker identity cutover --body Merge only after the Hamsterdan App host is ready; never run legacy and App writers together."
        , [answer ""]
        )
      , ( "gh pr view hamsterdan/broker-cutover-<stamp> --repo HBNetwork/demo-pr-readiness --json number,url,headRefName"
        , [value (obj [("number", int 5), ("url", str "https://github.test/pr/5")])]
        )
      ]

-- ---------------------------------------------------------------------------
-- inspect

inspectCases :: [Case]
inspectCases =
  [ inspecting appBotLogin (base "inspect fresh Hamsterdan evidence" ["inspect", "--pr", "7"] 0) clean
  , inspecting appBotLogin (base "inspect with a legacy marker" ["inspect", "--pr", "7"] 1) id
  , inspecting "human" (base "inspect with comments the App does not own" ["inspect", "--pr", "7"] 1) id
  , inspecting "Bot-Owner" (base "inspect with another, case-folded bot login" ["inspect", "--pr", "7", "--bot-login", "bot-owner"] 0) (cleanOf "Bot-Owner")
  , inspecting appBotLogin (base "inspect expecting the hero review" ["inspect", "--pr", "7", "--expect-hero-review"] 1) id
  , inspecting appBotLogin (base "inspect expecting no readiness advisory" ["inspect", "--pr", "7", "--expect-readiness", "absent"] 1) id
  , base "inspect a non-positive pull request" ["inspect", "--pr", "0"] 1
  , base "inspect a negative pull request" ["inspect", "--pr", "-3"] 1
  , inspecting appBotLogin (base "inspect when the pull request is unavailable" ["inspect", "--pr", "7"] 1) $
      replace ("gh api " <> repoPath "/pulls/7") [failing 1]
  , inspecting appBotLogin (base "inspect with non-list comments" ["inspect", "--pr", "7"] 1) $
      replace ("gh api " <> repoPath "/issues/7/comments?per_page=100") [value (obj [("body", str "x")])]
  , inspecting appBotLogin (base "inspect with inline review comments" ["inspect", "--pr", "7"] 0) $
      replace ("gh api " <> repoPath "/pulls/7/comments?per_page=100") [value (list inline)] . clean
  , inspecting appBotLogin (base "inspect with a hero findings batch" ["inspect", "--pr", "7", "--expect-hero-review"] 0) $
      replace ("gh api " <> repoPath "/pulls/7/comments?per_page=100") [value (list inline)]
        . replace ("gh api " <> issuesPath) [value (list (cleanComments <> [batch]))]
  , inspecting appBotLogin (base "inspect with a hero findings batch posted inline" ["inspect", "--pr", "7", "--expect-hero-review"] 1) $
      replace ("gh api " <> repoPath "/pulls/7/comments?per_page=100") [value (list (batch : inline))] . clean
  , inspecting appBotLogin (base "inspect with a non-object pull request" ["inspect", "--pr", "7"] 1) $
      replace ("gh api " <> repoPath "/pulls/7") [value (list [])]
  , inspecting appBotLogin (base "inspect with a non-integer run attempt" ["inspect", "--pr", "7"] 1) $
      replace ("gh api " <> repoPath ("/actions/runs?event=pull_request&head_sha=" <> sha 'a' <> "&per_page=100")) [value (obj [("workflow_runs", list [obj [("id", int 5), ("run_attempt", str "x")]])])]
  , inspecting appBotLogin (base "inspect with a run lacking its id" ["inspect", "--pr", "7"] 1) $
      replace ("gh api " <> repoPath ("/actions/runs?event=pull_request&head_sha=" <> sha 'a' <> "&per_page=100")) [value (obj [("workflow_runs", list [obj [("name", str "ci")]])])]
  , inspecting appBotLogin (base "inspect with a run on another head" ["inspect", "--pr", "7"] 1) $
      replace ("gh api " <> repoPath ("/actions/runs?event=pull_request&head_sha=" <> sha 'a' <> "&per_page=100")) [value (obj [("workflow_runs", list [obj [("id", int 8), ("run_attempt", PFloat 1.0), ("head_sha", str (sha 'b'))]])])]
        . ((repoPath' "/actions/runs/8/attempts/1/jobs?per_page=100", [value (obj [("jobs", list [])])]) :)
  , inspecting appBotLogin (base "inspect with a commit lacking attribution" ["inspect", "--pr", "7"] 0) $
      replace ("gh api " <> repoPath ("/commits/" <> sha 'a')) [value (obj [("author", none), ("committer", str "x")])] . clean
  ]
  where
    issuesPath = repoPath "/issues/7/comments?per_page=100"
    cleanComments = cleanCommentsOf appBotLogin
    cleanCommentsOf owner = case lookup issuesPath (inspectionResponses owner) of
      Just (Value (PList items)) -> [item | item <- items, not (legacyComment item)]
      _ -> error "no comments fixture"
    legacyComment = \case
      PDict members | Just (PInt 5) <- lookup "id" members -> True
      _ -> False
    clean = cleanOf appBotLogin
    cleanOf owner = replace ("gh api " <> issuesPath) [value (list (cleanCommentsOf owner))]
    inspecting owner c f = with (f (scripted (inspectionResponses owner))) c
    repoPath' path = "gh api " <> repoPath path
    hd = sha 'a'
    inline =
      [ obj
          [ ("id", int 21)
          , ("html_url", str "https://github.test/comments/21")
          , ("body", str ("finding prose\n<!-- hamsterdan:finding operation=review:1 head=" <> hd <> " -->"))
          , ("user", obj [("login", str appBotLogin)])
          , ("path", str "scenario-fixtures/hero_review/gate.py")
          , ("line", none)
          , ("original_line", int 16)
          ]
      , obj
          [ ("id", int 22)
          , ("html_url", str "https://github.test/comments/22")
          , ("body", str ("<!-- hamsterdan:reminder operation=remind:1 head=" <> hd <> " -->"))
          , ("user", obj [("login", str appBotLogin)])
          , ("line", bool True)
          ]
      ]
    batch =
      obj
        [ ("id", int 23)
        , ("html_url", str "https://github.test/comments/23")
        , ("user", obj [("login", str appBotLogin)])
        , ( "body"
          , str $
              T.concat
                [ "## Hamsterdan review findings\n\n"
                , "### `gate-1` \8212 Gate\n**blocking** \183 severity: **high**\n"
                , "Primary location: `scenario-fixtures/hero_review/gate.py:10`\n```suggestion\nfixed\n```\n"
                , "### `gate-2` \8212 Concept\nadvisory \183 severity: **low**\n"
                , "Primary location: `scenario-fixtures/hero_review/gate.py:16`\n"
                , "### `cache-1` \8212 Cache\nadvisory \183 severity: **medium**\n"
                , "Primary location: `scenario-fixtures/hero_review/cache.py:11`\n\nRelated locations:\n- `a.py:1`\n"
                , "<!-- hamsterdan:findings-digest " <> T.replicate 64 "0" <> " -->\n"
                , "<!-- hamsterdan:finding operation=review:2 head=" <> hd <> " -->"
                ]
          )
        ]

-- ---------------------------------------------------------------------------
-- inspect-authority

authority :: [(Text, [Json])]
authority = scripted authorityResponses

authorityCases :: [Case]
authorityCases =
  [ with authority (base ("inspect-authority --expect " <> T.unpack expectation) ["inspect-authority", "--pr", "9", "--expect", expectation] code)
  | (expectation, code) <-
      [ ("non-draft", 0)
      , ("strict-stale", 0)
      , ("conflict", 1)
      , ("review-requested", 0)
      , ("changes-requested", 0)
      , ("required-approval", 1)
      , ("unresolved-thread", 0)
      , ("collaboration-clear", 1)
      ]
  ]
    <> [ base "inspect-authority on a non-positive pull request" ["inspect-authority", "--pr", "0", "--expect", "non-draft"] 1
       , modified "inspect-authority with a non-object pull request" (replace pull [value (list [])])
       , modified "inspect-authority with a short head" (replace pull [value (setPath ["head", "sha"] (str "abc") pullValue)])
       , modified "inspect-authority with indeterminate mergeability" (replace pull [value (merge pullValue [("mergeable", none)])])
       , modified "inspect-authority with non-boolean draft" (replace pull [value (merge pullValue [("draft", str "no")])])
       , modified "inspect-authority when the head moves during collection" (replace pull [value pullValue, value (setPath ["head", "sha"] (str (sha 'e')) pullValue)])
       , modified "inspect-authority with a malformed base reference" (replace ("gh api " <> repoPath "/git/ref/heads/authority-base") [value (obj [("object", obj [])])])
       , modified "inspect-authority with a negative comparison" (replace ("gh api " <> repoPath ("/compare/" <> sha 'b' <> "..." <> sha 'a')) [value (obj [("behind_by", int (-1))])])
       , modified "inspect-authority with a full rules page" (replace ("gh api " <> rulesPath) [value (list (replicate 100 (obj [])))])
       , modified "inspect-authority with malformed rules" (replace ("gh api " <> rulesPath) [value (list [obj [("type", str "pull_request"), ("parameters", obj [("required_approving_review_count", bool True)])]])])
       , modified "inspect-authority with malformed requested reviewers" (replace ("gh api " <> repoPath "/pulls/9/requested_reviewers") [value (obj [("users", list [])])])
       , (modified "inspect-authority with team requests" (replace ("gh api " <> repoPath "/pulls/9/requested_reviewers") [value (obj [("users", list []), ("teams", list [obj [("slug", str "core")], obj [("slug", str "")]])])])) {pythonCode = 0}
       , modified "inspect-authority with a malformed review" (replace ("gh api " <> repoPath "/pulls/9/reviews?per_page=100") [value (list [obj [("id", str "1")]])])
       , modified "inspect-authority with malformed thread evidence" (replace (graphqlKey 9) [value (obj [("data", none)])])
       , modified "inspect-authority with a further thread page" (replace (graphqlKey 9) [value (obj [("data", obj [("repository", obj [("pullRequest", obj [("reviewDecision", none), ("reviewThreads", obj [("nodes", list []), ("pageInfo", obj [("hasNextPage", bool True)])])])])])])])
       , modified "inspect-authority with a non-object comparison" (replace ("gh api " <> repoPath ("/compare/" <> sha 'b' <> "..." <> sha 'a')) [value (list [])])
       , modified "inspect-authority with a non-object final pull request" (replace pull [value pullValue, value (str "gone")])
       ]
  where
    pull = "gh api " <> pullPath
    pullValue = case lookup pullPath authorityResponses of
      Just (Value v) -> v
      _ -> error "no pull fixture"
    modified name f = with (f authority) (base name ["inspect-authority", "--pr", "9", "--expect", "non-draft"] 1)

-- ---------------------------------------------------------------------------
-- qualification-setup

credential, target :: BS.ByteString
credential = "ghs_fixtureOnlyToken"
target = "{\"repository\": \"owner/target\", \"account_id\": 41, \"repository_id\": 42}"

setupArguments :: [Text]
setupArguments =
  [ "qualification-setup"
  , "--credential-file"
  , "<root>/private/credential"
  , "--target-file"
  , "<root>/private/target.json"
  , "--spent-marker"
  , "<root>/private/push-spent"
  ]

git :: [Text] -> Text
git arguments =
  T.unwords $
    [ "git"
    , "-c"
    , "credential.helper="
    , "-c"
    , "credential.helper=!<root>/bin/gh auth git-credential"
    , "-c"
    , "core.hooksPath=/dev/null"
    , "-c"
    , "http.followRedirects=false"
    , "-c"
    , "protocol.file.allow=never"
    ]
      <> arguments

remote :: Text
remote = "https://github.com/owner/target.git"

baseSha, headSha :: Text
baseSha = sha '1'
headSha = sha '2'

refsOutput :: [(Text, Text)] -> Text
refsOutput refs = T.concat [hash <> "\t" <> ref <> "\n" | (ref, hash) <- refs]

setup :: [(Text, [Json])]
setup =
  [ (git ["init", "--quiet", "--initial-branch=main"], [answer ""])
  , (git ["config", "user.name", "Hamsterdan", "Qualification"], [answer ""])
  , (git ["config", "user.email", "qualification@invalid"], [answer ""])
  , (git ["add", "qualification.txt"], [answer ""])
  , (git ["commit", "--quiet", "-m", "base"], [answer ""])
  , (git ["rev-parse", "HEAD"], [answer (baseSha <> "\n"), answer (headSha <> "\n")])
  , (git ["add", "requested-change.txt"], [answer ""])
  , (git ["commit", "--quiet", "-m", "change"], [answer ""])
  , ("gh api /user", [value (obj [("id", int 41), ("login", str "qualifier")])])
  , ("gh api /repos/owner/target", [value targetValue])
  , (git ["ls-remote", "--refs", remote], [answer "", answer exact, answer exact])
  , (git ["push", "--atomic", remote, baseSha <> ":refs/heads/main", headSha <> ":refs/heads/hamsterdan/ds11-live-v4"], [answer ""])
  , (git ["ls-remote", "--refs", remote, "refs/pull/*/head"], [answer (refsOutput [("refs/pull/3/head", sha '9')])])
  , (git ["ls-remote", "--refs", remote, "refs/heads/hamsterdan/ds11-live-v4"], [answer (refsOutput [("refs/heads/hamsterdan/ds11-live-v4", headSha)])])
  ]
  where
    exact = refsOutput [("refs/heads/main", baseSha), ("refs/heads/hamsterdan/ds11-live-v4", headSha)]

targetValue :: PV
targetValue =
  obj
    [ ("full_name", str "owner/target")
    , ("id", int 42)
    , ("private", bool False)
    , ("archived", bool False)
    , ("disabled", bool False)
    , ("size", int 0)
    , ("default_branch", str "main")
    , ("permissions", obj [("push", bool True)])
    ]

setupCases :: [Case]
setupCases =
  [ setting "qualification-setup qualifies the target" 0 id id
  , setting "qualification-setup with relative paths" 1 id \c ->
      c {argv = ["qualification-setup", "--credential-file", "private/credential", "--target-file", "<root>/private/target.json", "--spent-marker", "<root>/private/push-spent"]}
  , setting "qualification-setup with a repeated path" 1 id \c ->
      c {argv = ["qualification-setup", "--credential-file", "<root>/private/credential", "--target-file", "<root>/private/../private/credential", "--spent-marker", "<root>/private/push-spent"]}
  , setting "qualification-setup without its input files" 1 id \c -> c {files = []}
  , setting "qualification-setup with a group-readable credential" 1 id \c ->
      c {files = [("private/credential", credential, 0o640), ("private/target.json", target, 0o600)]}
  , setting "qualification-setup with a whitespace token" 1 id \c ->
      c {files = [("private/credential", credential <> "\n", 0o600), ("private/target.json", target, 0o600)]}
  , setting "qualification-setup with an extra target key" 1 id \c ->
      c {files = [("private/credential", credential, 0o600), ("private/target.json", "{\"repository\": \"owner/target\", \"account_id\": 41, \"repository_id\": 42, \"x\": 1}", 0o600)]}
  , setting "qualification-setup with a boolean account" 1 id \c ->
      c {files = [("private/credential", credential, 0o600), ("private/target.json", "{\"repository\": \"owner/target\", \"account_id\": true, \"repository_id\": 42}", 0o600)]}
  , setting "qualification-setup with a dotted repository" 1 id \c ->
      c {files = [("private/credential", credential, 0o600), ("private/target.json", "{\"repository\": \"owner/..x\", \"account_id\": 41, \"repository_id\": 42}", 0o600)]}
  , setting "qualification-setup with a marker parent that is not private" 1 id \c ->
      c {directories = [("private", 0o750)]}
  , setting "qualification-setup when the fixture cannot be initialized" 1 (replace (git ["init", "--quiet", "--initial-branch=main"]) [failing 1]) id
  , setting "qualification-setup when the identity differs" 1 (replace "gh api /user" [value (obj [("id", int 40)])]) id
  , setting "qualification-setup when the identity is unavailable" 1 (replace "gh api /user" [failing 1]) id
  , setting "qualification-setup when the target is not empty" 1 (replace "gh api /repos/owner/target" [value (merge targetValue [("size", int 3)])]) id
  , setting "qualification-setup when the target already has refs" 1 (replace (git ["ls-remote", "--refs", remote]) [answer (refsOutput [("refs/heads/main", baseSha)])]) id
  , setting "qualification-setup when the push is rejected" 1 (replace (git ["push", "--atomic", remote, baseSha <> ":refs/heads/main", headSha <> ":refs/heads/hamsterdan/ds11-live-v4"]) [failing 1]) id
  , setting "qualification-setup when the readback differs" 1 (replace (git ["ls-remote", "--refs", remote]) [answer "", answer (refsOutput [("refs/heads/main", baseSha)])]) id
  , setting "qualification-setup when the readback is malformed" 1 (replace (git ["ls-remote", "--refs", remote]) [answer "", answer "nonsense\n"]) id
  , setting "qualification-setup when a pull request already advertises the head" 1 (replace (git ["ls-remote", "--refs", remote, "refs/pull/*/head"]) [answer (refsOutput [("refs/pull/3/head", headSha)])]) id
  , setting "qualification-setup with a malformed revision" 1 (replace (git ["rev-parse", "HEAD"]) [answer "HEAD\n"]) id
  , setting "qualification-setup when the push was already spent" 1 id \c ->
      c {files = c.files <> [("private/push-spent", "", 0o600)]}
  ]
  where
    setting name code f g =
      g
        Case
          { name
          , argv = setupArguments
          , responses = f setup
          , files = [("private/credential", credential, 0o600), ("private/target.json", target, 0o600)]
          , directories = [("private", 0o700)]
          , columns = "80"
          , pythonCode = code
          }

-- ---------------------------------------------------------------------------
-- Running both sides

data Outcome = Outcome
  { code :: Int
  , out :: Text
  , err :: Text
  , calls :: [Text]
  , tree :: [(FilePath, String, Maybe Text)]
  }
  deriving stock (Eq, Show)

prepareSide :: FilePath -> FilePath -> Case -> IO ()
prepareSide binary side c = do
  createDirectoryIfMissing True (side </> "bin")
  createDirectoryIfMissing True (side </> "tmp")
  forM_ ["gh", "git", "curl", "python"] \tool -> do
    let path = side </> "bin" </> tool
    writeExecutable path (wrapperScript binary ["--fake-provider", side, tool])
  let entries = Map.toList (Map.fromListWith (flip (<>)) c.responses)
      encodedResponses = either (error . show) id (dumps compact (Object [(k, Array v) | (k, v) <- entries]))
  BS.writeFile (side </> "responses.json") encodedResponses
  forM_ c.directories \(directory, _) -> createDirectoryIfMissing True (side </> directory)
  forM_ c.files \(path, bytes, mode) -> do
    createDirectoryIfMissing True (takeDirectory (side </> path))
    BS.writeFile (side </> path) bytes
    setFileMode (side </> path) mode
  forM_ c.directories \(directory, mode) -> setFileMode (side </> directory) mode

runSide :: FilePath -> [String] -> FilePath -> Case -> IO Outcome
runSide program prefix side c = do
  inherited <- getEnvironment
  let path = side </> "bin" <> maybe "" (":" <>) (lookup "PATH" inherited)
      environment =
        [("PATH", path), ("TMPDIR", side </> "tmp"), ("COLUMNS", T.unpack c.columns)]
          <> [(k, v) | (k, v) <- inherited, k `notElem` ["PATH", "TMPDIR", "COLUMNS", "LINES", "PYTHONPATH", "PYTHONHOME", "GH_TOKEN", "GITHUB_TOKEN"]]
      arguments = map (T.unpack . T.replace "<root>" (T.pack side)) c.argv
  (status, stdoutBytes, stderrBytes) <-
    readProcess (setStdin nullStream (setWorkingDir side (setEnv environment (proc program (prefix <> arguments)))))
  logged <- doesFileExist (side </> "calls.log")
  callLines <- if logged then T.lines . decode <$> BS.readFile (side </> "calls.log") else pure []
  files <- treeOf side
  let normalize = normalizeText (T.pack side)
  pure
    Outcome
      { code = case status of
          ExitSuccess -> 0
          ExitFailure n -> n
      , out = normalize (decode (BL.toStrict stdoutBytes))
      , err = normalize (lastTracebackLine (decode (BL.toStrict stderrBytes)))
      , calls = callLines
      , tree = [(T.unpack (normalize (T.pack p)), m, fmap normalize b) | (p, m, b) <- files]
      }
  where
    decode = TE.decodeUtf8With TEE.lenientDecode

-- | An uncaught Python exception's traceback, reduced to the line naming
-- the exception: what the port prints for the same failure.
lastTracebackLine :: Text -> Text
lastTracebackLine text
  | "Traceback (most recent call last):" `T.isInfixOf` text =
      case reverse (filter (not . T.null) (T.lines text)) of
        line : _ -> line <> "\n"
        [] -> text
  | otherwise = text

-- | Every path under the side except the fakes' own bookkeeping, with its
-- permission bits and, for files, its contents.
treeOf :: FilePath -> IO [(FilePath, String, Maybe Text)]
treeOf root = walk ""
  where
    skipped = ["bin", "calls.log", "responses.json"]
    walk relative = do
      names <- sort <$> listDirectory (root </> relative)
      fmap concat . forM [n | n <- names, relative /= "" || n `notElem` skipped] $ \n -> do
        let path = if null relative then n else relative </> n
        status <- getSymbolicLinkStatus (root </> path)
        let mode = showMode (fileMode status .&. 0o7777)
        if isDirectory status
          then ((path, mode, Nothing) :) <$> walk path
          else (\bytes -> [(path, mode, Just (TE.decodeUtf8With TEE.lenientDecode bytes))]) <$> BS.readFile (root </> path)
    showMode m = let s = showOct' (toInteger m) in replicate (4 - length s) '0' <> s
    showOct' n = if n < 8 then show n else showOct' (n `div` 8) <> show (n `mod` 8)

operatorBinary :: IO FilePath
operatorBinary = do
  override <- lookupEnv "HAMSTERDAN_OPERATOR"
  found <- maybe (findExecutable "hamsterdan-operator") (pure . Just) override
  maybe (fail "hamsterdan-operator is not on PATH (cabal test puts it there; or set HAMSTERDAN_OPERATOR)") pure found

differential :: Case -> Spec
differential c = it c.name do
  python <- upstreamPythonExecutable "hamsterdan"
  port <- operatorBinary
  testBinary <- getExecutablePath
  withSystemTempDirectory "operator-differential" \temporary -> do
    root <- canonicalizePath temporary
    let py = root </> "py"
        hs = root </> "hs"
    prepareSide testBinary py c
    prepareSide testBinary hs c
    reference <- runSide python ["-I", "-B", "-m", "hamsterdan.operator"] py c
    ported <- runSide port [] hs c
    unless (reference.code == c.pythonCode) $
      expectationFailure ("the reference exited " <> show reference.code <> ", not " <> show c.pythonCode <> ": " <> show reference)
    ported `shouldBe` reference
    leftover <- doesDirectoryExist (hs </> "tmp")
    leftover `shouldBe` True

spec :: Spec
spec = describe "Command line, differential against python -m hamsterdan.operator" $ parallel do
  describe "argument parsing" $ mapM_ differential parsingCases
  describe "preflight" $ mapM_ differential preflightCases
  describe "create" $ mapM_ differential createCases
  describe "prepare-broker" $ mapM_ differential brokerCases
  describe "inspect" $ mapM_ differential inspectCases
  describe "inspect-authority" $ mapM_ differential authorityCases
  describe "qualification-setup" $ mapM_ differential setupCases
  it "covers every subcommand" do
    let commands = [a | c <- parsingCases <> preflightCases <> createCases <> brokerCases <> inspectCases <> authorityCases <> setupCases, a : _ <- [c.argv]]
    sort (filter (`elem` subcommands) (unique commands)) `shouldBe` sort subcommands
  where
    subcommands = ["create", "inspect", "inspect-authority", "preflight", "prepare-broker", "qualification-setup"]
    unique = Map.keys . Map.fromList . map (,())


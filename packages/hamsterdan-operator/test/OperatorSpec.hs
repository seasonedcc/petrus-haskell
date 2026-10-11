-- | @tests/unit/test_operator.py@, case for case (same names).
module OperatorSpec
  ( spec
  , legacy
  , current
  , preflightInventory
  , prListKey
  , inspectionResponses
  , authorityResponses
  , repoPath
  , sha
  , rulesPath
  , reviewsPath
  , pullPath
  ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Hamsterdan.Cli.Argparse (Action (..), Behavior (..), Outcome (..), Parser (..), lookupBool, lookupText, parseArgs)
import Hamsterdan.Python.Object (PV (..), pyEq, toJson, truthy)
import Hamsterdan.GitHub.Gateway (derivePolicy)
import Hamsterdan.Operator
import Petrus.Json (Json (..))
import Support
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Fixtures

legacy :: Text
legacy =
  T.unlines
    [ "contains(fromJSON('[\"OWNER\",\"MEMBER\",\"COLLABORATOR\"]'), github.event.comment.author_association) &&"
    , "startsWith(github.event.comment.body, '<!-- impetus-rerun ')"
    , "marker = re.fullmatch(r\"<!-- impetus-rerun run=([1-9][0-9]*) head=x operation=x -->\", body)"
    ]

current :: Text
current = T.replace legacyBrokerAuthorization appBrokerAuthorization (T.replace "impetus-rerun" "hamsterdan-rerun" legacy)

delegatedWorkflow :: Text
delegatedWorkflow =
  T.unlines
    [ "jobs:"
    , "  rerun-broker:"
    , "    if: >-"
    , "      github.event.issue.pull_request != null &&"
    , "      " <> appBrokerAuthorization
    , "      startsWith(github.event.comment.body, '<!-- hamsterdan-rerun ')"
    , "    steps:"
    , "      - name: Validate and request exact PR run rerun"
    , "        run: |"
    , "          request_output=\"$("
    , "            python tools/rerun_broker.py parse-marker --marker \"$COMMENT_BODY\""
    , "          )\""
    , "          readarray -t request <<<\"$request_output\""
    , "          [[ \"${#request[@]}\" -eq 3 ]]"
    , "          run_id=\"${request[0]}\""
    , "          expected_head=\"${request[1]}\""
    , "          operation=\"${request[2]}\""
    , "          run=\"$(gh api \"repos/${REPOSITORY}/actions/runs/${run_id}\")\""
    , "          python tools/rerun_broker.py validate-run \\"
    , "            --run-id \"$run_id\" \\"
    , "            --head \"$expected_head\" \\"
    , "            --operation \"$operation\" \\"
    , "            --repository \"$REPOSITORY\" \\"
    , "            --pr-number \"$PR_NUMBER\" \\"
    , "            <<<\"$run\""
    , "          gh api --method POST \"repos/${REPOSITORY}/actions/runs/${run_id}/rerun\""
    ]

delegatedValidator :: Text
delegatedValidator =
  T.unlines
    [ "MARKER = re.compile("
    , "    r\"<!-- hamsterdan-rerun run=([1-9][0-9]{0,19}) head=([0-9a-f]{40}) \""
    , "    r\"operation=([A-Za-z0-9][A-Za-z0-9._:-]{0,127}) -->\""
    , ")"
    , "WORKFLOW = \".github/workflows/ci.yml\""
    , "match = MARKER.fullmatch(marker)"
    , "valid_pull_request = ("
    , "    and pull_request[\"number\"] == pr_number"
    , ")"
    , "valid = ("
    , "    and run[\"id\"] == request.run_id"
    , "    and run_repository.get(\"full_name\") == repository"
    , "    and run.get(\"event\") == \"pull_request\""
    , "    and run.get(\"path\") == WORKFLOW"
    , "    and run.get(\"head_sha\") == request.head_sha"
    , ")"
    ]

-- | The autouse @delegated_contract_digests@ fixture.
digests :: (Text, Text)
digests = (brokerSourceDigest delegatedWorkflow, brokerSourceDigest delegatedValidator)

testOperator :: Fake -> Operator
testOperator fake = operatorWith (fakeRunner fake) digests

-- | The operator whose broker digests are the fixture's.
digestOperator :: Operator
digestOperator = operatorWith (\_ _ -> fail "no commands") digests

repoPath :: Text -> Text
repoPath suffix = "/repos/" <> repository <> suffix

checkNamed :: Text -> PV -> PV
checkNamed name result = case at "checks" result of
  PList checks -> maybe (error ("no check " <> T.unpack name)) id (find (\c -> pyEq (at "name" c) (str name)) checks)
  _ -> error "checks"

checksOf :: PV -> [PV]
checksOf result = case at "checks" result of
  PList checks -> checks
  _ -> []

isTrue, isFalse :: PV -> Bool
isTrue = \case PBool True -> True; _ -> False
isFalse = \case PBool False -> True; _ -> False

sha :: Char -> Text
sha = T.replicate 40 . T.singleton

subparser :: Text -> Parser
subparser name = case [p | Action {behavior = Subcommands parsers} <- operatorParser.actions, (n, p) <- parsers, n == name] of
  p : _ -> p
  [] -> error "no subparser"

parsed :: [Text] -> (Text -> Maybe Text, Text -> Bool)
parsed argv = case parseArgs 80 operatorParser argv of
  Parsed namespace -> ((`lookupText` namespace), (`lookupBool` namespace))
  Exited {} -> error "parse failed"

preflightInventory :: [(Text, Response)]
preflightInventory =
  [ ("gh auth status", Value (str ""))
  , ("/orgs/HBNetwork", Value (obj [("id", int orgId)]))
  , (repoPath "", Value (obj [("id", int repositoryId), ("private", bool False), ("default_branch", str "main")]))
  , ( repoPath "/actions/workflows?per_page=100"
    , Value (obj [("workflows", list [obj [("name", str "ci")], obj [("name", str "rerun-broker")]])])
    )
  ]

prListKey :: Text
prListKey =
  "gh pr list --repo HBNetwork/demo-pr-readiness --state open --search in:title Hamsterdan broker identity cutover --json number,url,headRefName --limit 10"

-- ---------------------------------------------------------------------------
-- Inspection fixtures

inspectionResponses :: Text -> [(Text, Response)]
inspectionResponses owner =
  [ ( repoPath "/pulls/7"
    , Value
        ( obj
            [ ("html_url", str "https://github.test/pr/7")
            , ("state", str "open")
            , ("draft", bool False)
            , ("head", obj [("sha", str hd), ("ref", str "hamsterdan/demo")])
            , ("base", obj [("ref", str "main"), ("repo", obj [("id", int repositoryId)])])
            ]
        )
    )
  , ( repoPath "/issues/7/comments?per_page=100"
    , Value
        ( list
            [ comment 3 ("SECRET PROSE\n" <> marker) owner
            , comment 6 "dashboard prose\n<!-- hamsterdan:dashboard -->" owner
            , comment 7 ("readiness prose\n" <> readiness) owner
            , comment 4 "private unrelated prose" "human"
            , comment 5 ("<!-- impetus-rerun run=4 head=" <> hd <> " operation=old -->") "human"
            ]
        )
    )
  , (repoPath "/pulls/7/comments?per_page=100", Value (list []))
  , ( repoPath ("/commits/" <> hd)
    , Value
        ( obj
            [ ("commit", obj [("author", obj [("name", str "Explicit Author")]), ("committer", obj [("name", str "Explicit Committer")])])
            , ("author", obj [("login", str "human")])
            , ("committer", obj [("login", str appBotLogin)])
            ]
        )
    )
  , ( repoPath ("/actions/runs?event=pull_request&head_sha=" <> hd <> "&per_page=100")
    , Value
        ( obj
            [ ( "workflow_runs"
              , list
                  [ obj
                      [ ("id", int 5)
                      , ("name", str "ci")
                      , ("run_attempt", int 2)
                      , ("head_sha", str hd)
                      , ("status", str "completed")
                      , ("conclusion", str "success")
                      , ("html_url", str "https://github.test/runs/5")
                      ]
                  ]
              )
            ]
        )
    )
  , ( repoPath "/actions/runs/5/attempts/2/jobs?per_page=100"
    , Value (obj [("jobs", list [obj [("id", int 6), ("name", str "unit"), ("status", str "completed"), ("conclusion", str "success")]])])
    )
  ]
  where
    hd = sha 'a'
    marker = "<!-- hamsterdan-rerun run=5 head=" <> hd <> " operation=rerun:1 -->"
    readiness = "<!-- hamsterdan:readiness operation=readiness:1 head=" <> hd <> " -->"
    comment identifier body login =
      obj
        [ ("id", int identifier)
        , ("html_url", str ("https://github.test/comments/" <> T.pack (show identifier)))
        , ("body", str body)
        , ("user", obj [("login", str login)])
        ]

inspectionRunner :: Text -> IO Fake
inspectionRunner owner = newFake (inspectionResponses owner)

issueComments :: Text
issueComments = repoPath "/issues/7/comments?per_page=100"

reviewComments :: Text
reviewComments = repoPath "/pulls/7/comments?per_page=100"

dropLastComment :: Fake -> IO ()
dropLastComment fake = do
  comments <- getResponse fake issueComments
  case comments of
    PList items -> setResponse fake issueComments (Value (list (take (length items - 1) items)))
    _ -> error "comments"

-- ---------------------------------------------------------------------------
-- Authority fixtures

authorityResponses :: [(Text, Response)]
authorityResponses =
  [ ( repoPath "/pulls/9"
    , Value
        ( obj
            [ ("html_url", str "https://github.test/pr/9")
            , ("state", str "open")
            , ("draft", bool False)
            , ("user", obj [("login", str "Author")])
            , ("head", obj [("sha", str hd), ("ref", str "authority/collaboration"), ("repo", obj [("id", int repositoryId)])])
            , ("base", obj [("sha", str oldBase), ("ref", str "authority-base"), ("repo", obj [("id", int repositoryId)])])
            , ("mergeable", bool True)
            , ("mergeable_state", str "clean")
            ]
        )
    )
  , (repoPath "/git/ref/heads/authority-base", Value (obj [("object", obj [("sha", str base)])]))
  , (repoPath ("/compare/" <> base <> "..." <> hd), Value (obj [("status", str "behind"), ("ahead_by", int 1), ("behind_by", int 1)]))
  , (rulesPath, Value rules)
  , (repoPath "/pulls/9/requested_reviewers", Value (obj [("users", list [obj [("login", str "Reviewer")]]), ("teams", list [])]))
  , ( reviewsPath
    , Value
        ( list
            [ obj [("id", int 1), ("submitted_at", str "2026-08-02T01:00:00Z"), ("state", str "APPROVED"), ("user", obj [("login", str "author")])]
            , obj
                [ ("id", int 2)
                , ("submitted_at", str "2026-08-02T02:00:00Z")
                , ("state", str "CHANGES_REQUESTED")
                , ("user", obj [("login", str "Reviewer")])
                ]
            ]
        )
    )
  , ( "graphql"
    , Value
        ( obj
            [ ( "data"
              , obj
                  [ ( "repository"
                    , obj
                        [ ( "pullRequest"
                          , obj
                              [ ("reviewDecision", str "CHANGES_REQUESTED")
                              , ( "reviewThreads"
                                , obj
                                    [ ("nodes", list [obj [("id", str "thread-1"), ("isResolved", bool False)]])
                                    , ("pageInfo", obj [("hasNextPage", bool False), ("endCursor", none)])
                                    ]
                                )
                              ]
                          )
                        ]
                    )
                  ]
              )
            ]
        )
    )
  ]
  where
    hd = sha 'a'
    base = sha 'b'
    oldBase = sha 'c'

rules :: PV
rules =
  list
    [ obj
        [ ("type", str "pull_request")
        , ("parameters", obj [("required_approving_review_count", int 1), ("required_review_thread_resolution", bool True)])
        ]
    , obj
        [ ("type", str "required_status_checks")
        , ( "parameters"
          , obj [("strict_required_status_checks_policy", bool True), ("required_status_checks", list [obj [("context", str "unit")]])]
          )
        ]
    ]

rulesPath, reviewsPath, pullPath :: Text
rulesPath = repoPath "/rules/branches/authority-base?per_page=100"
reviewsPath = repoPath "/pulls/9/reviews?per_page=100"
pullPath = repoPath "/pulls/9"

authorityRunner :: IO Fake
authorityRunner = newFake authorityResponses

expectedAuthority :: PV
expectedAuthority =
  obj
    [ ("draft", bool False)
    , ("head", str (sha 'a'))
    , ("base", str (sha 'b'))
    , ("base_ref", str "authority-base")
    , ("behind_by", int 1)
    , ("mergeable", bool True)
    , ("mergeable_state", str "clean")
    , ("strict_base", bool True)
    , ("required_approvals", int 1)
    , ("conversation_resolution", bool True)
    , ("requested_reviewers", list [str "Reviewer"])
    , ("requested_teams", list [])
    , ( "latest_reviews"
      , list
          [ obj [("reviewer", str "Reviewer"), ("state", str "CHANGES_REQUESTED")]
          , obj [("reviewer", str "author"), ("state", str "APPROVED")]
          ]
      )
    , ("distinct_approvals", list [])
    , ("changes_requested", list [str "Reviewer"])
    , ("unresolved_threads", int 1)
    , ("review_decision", str "CHANGES_REQUESTED")
    ]

modify :: Fake -> Text -> (PV -> PV) -> IO ()
modify fake key f = getResponse fake key >>= setResponse fake key . Value . f

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "tests/unit/test_operator.py" do
  it "test_qualification_setup_rejects_unsafe_input_and_erases_both_files" do
    withSystemTempDirectory "operator" \tmp -> do
      let credential = tmp </> "credential"
          target = tmp </> "target"
      BS.writeFile credential "secret-canary"
      BS.writeFile target "coordinate-canary"
      setFileMode credential 0o644
      setFileMode target 0o600
      outcome <- qualificationSetup setupSubprocess credential target (tmp </> "spent")
      doesFileExist credential `shouldReturn` False
      doesFileExist target `shouldReturn` False
      at "ok" outcome `shouldSatisfy` isFalse
      atPath ["evidence", "first_cause_phase"] outcome `shouldEqualPy` str "setup_preparation"

  it "test_qualification_setup_parser_exposes_only_private_file_inputs" do
    Set.fromList (map (.dest) (subparser "qualification-setup").actions)
      `shouldBe` Set.fromList ["help", "credential_file", "target_file", "spent_marker"]

  it "test_setup_ref_projection_is_strict_and_exact" do
    let a = sha 'a'
        b = sha 'b'
        c = sha 'c'
        expected = parseSetupRefs (TE.encodeUtf8 (a <> "\trefs/heads/main\n" <> b <> "\trefs/pull/7/head\n"))
    fmap Map.fromList expected `shouldBe` Right (Map.fromList [("refs/heads/main", a), ("refs/pull/7/head", b)])
    let extra = parseSetupRefs (TE.encodeUtf8 (a <> "\trefs/heads/main\n" <> b <> "\trefs/pull/7/head\n" <> c <> "\trefs/tags/extra\n"))
    fmap Map.fromList extra `shouldNotBe` fmap Map.fromList expected

  describe "test_setup_ref_projection_rejects_every_malformed_or_duplicate_line" do
    let a = sha 'a'
        b = sha 'b'
        cases =
          [ "private malformed diagnostic\n"
          , TE.encodeUtf8 (a <> "\trefs/heads/main\n" <> b <> "\trefs/heads/main\n")
          , TE.encodeUtf8 (T.replicate 40 "A" <> "\trefs/heads/main\n")
          , TE.encodeUtf8 (a <> "\trefs/heads/private..branch\n")
          , TE.encodeUtf8 (a <> "\trefs/heads/x/\n")
          , TE.encodeUtf8 (a <> "\trefs/heads/x//y\n")
          , TE.encodeUtf8 (a <> "\trefs/heads/.hidden\n")
          , TE.encodeUtf8 (a <> "\trefs/heads/x.lock\n")
          , TE.encodeUtf8 (a <> "\trefs/heads/main\v" <> b <> "\trefs/heads/other\n")
          , "\xff"
          ]
    forM_ (zip [0 :: Int ..] cases) \(index, raw) ->
      it ("raw" <> show index) do
        parseSetupRefs raw `shouldBe` Left (OperatorError "Git ref observation is malformed")

  describe "test_broker_status_requires_prefix_and_regex" do
    forM_ [(legacy, "legacy"), (current, "hamsterdan"), ("x", "malformed")] \(value, expected) ->
      it (T.unpack expected) do
        brokerStatus digestOperator value Nothing `shouldBe` expected

  it "test_broker_cutover_replaces_human_association_with_exact_app_bot" do
    brokerStatus digestOperator current Nothing `shouldBe` "hamsterdan"
    current `shouldNotSatisfy` T.isInfixOf "author_association"
    current `shouldSatisfy` T.isInfixOf "github.event.comment.user.type == 'Bot'"
    current `shouldSatisfy` T.isInfixOf "github.event.comment.user.login == 'hamster-dan[bot]'"

  it "test_delegated_broker_requires_exact_workflow_and_validator_contract" do
    brokerStatus digestOperator delegatedWorkflow (Just delegatedValidator) `shouldBe` "hamsterdan"
    brokerStatus digestOperator delegatedWorkflow Nothing `shouldBe` "malformed"

  describe "test_delegated_broker_rejects_weakened_binding" do
    let changes =
          [ (Just ("hamster-dan[bot]", "other[bot]"), Nothing)
          , (Just ("hamsterdan-rerun", "other-rerun"), Nothing)
          , (Just ("parse-marker", "parse-other"), Nothing)
          , (Just ("${REPOSITORY}/actions/runs/${run_id}", "${REPOSITORY}/actions/runs/1"), Nothing)
          , (Just ("--repository \"$REPOSITORY\"", "--repository other/repository"), Nothing)
          , (Just ("--pr-number \"$PR_NUMBER\"", "--pr-number 1"), Nothing)
          , (Nothing, Just ("MARKER.fullmatch(marker)", "MARKER.search(marker)"))
          , (Nothing, Just ("run.get(\"path\") == WORKFLOW", "run.get(\"path\") == \"other\""))
          , (Nothing, Just ("run.get(\"head_sha\") == request.head_sha", "run.get(\"head_sha\") == \"other\""))
          , (Nothing, Just ("pull_request[\"number\"] == pr_number", "pull_request[\"number\"] == 1"))
          ]
    forM_ (zip [0 :: Int ..] changes) \(index, (workflowChange, validatorChange)) ->
      it ("change" <> show index) do
        let apply = maybe id (\(old, new) -> T.replace old new)
            workflow = apply workflowChange delegatedWorkflow
            validator = apply validatorChange delegatedValidator
        brokerStatus digestOperator workflow (Just validator) `shouldBe` "malformed"

  it "test_delegated_broker_requires_one_post_after_validation" do
    let post = "gh api --method POST \"repos/${REPOSITORY}/actions/runs/${run_id}/rerun\""
        withoutPost = T.replace post "" delegatedWorkflow
        earlyPost =
          T.replace "python tools/rerun_broker.py parse-marker" (post <> "\npython tools/rerun_broker.py parse-marker") withoutPost
    brokerStatus digestOperator (delegatedWorkflow <> post) (Just delegatedValidator) `shouldBe` "malformed"
    brokerStatus digestOperator earlyPost (Just delegatedValidator) `shouldBe` "malformed"

  it "test_scenarios_are_the_fixture_closed_schema" do
    let value name = either (error . show) id (scenarioValue name)
        clean = value "clean-green"
        flake = value "first-attempt-flake"
        hero = value "hero-review"
    case clean of
      PDict members -> Set.fromList (map fst members) `shouldBe` Set.fromList ["schema_version", "scenario", "behavior", "review_lenses"]
      _ -> expectationFailure "not a dict"
    at "behavior" clean `shouldEqualPy` obj [("kind", str "pass")]
    at "behavior" flake `shouldEqualPy` obj [("kind", str "first_attempt_flake"), ("fingerprint", str "scenario:first-attempt-flake:v1")]
    at "behavior" hero `shouldEqualPy` obj [("kind", str "pass")]
    at "review_lenses" clean `shouldEqualPy` list [str "correctness", str "test-quality", str "risk"]
    fst (parsed ["create", "--scenario", "hero-review"]) "scenario" `shouldBe` Just "hero-review"

  it "test_preflight_exact_inventory_and_legacy_status_pass" do
    fake <- newFake (preflightInventory <> [(repoPath ("/contents/" <> brokerPath <> "?ref=main"), Value (str legacy))])
    result <- preflight (testOperator fake) Nothing
    at "ok" result `shouldSatisfy` isTrue
    at "observed" (checkNamed "default_broker" result) `shouldEqualPy` str "legacy"
    forM_ (checksOf result) \item -> T.toCaseFold (encoded item) `shouldNotSatisfy` T.isInfixOf "token"

  it "test_preflight_accepts_current_delegated_broker_contract" do
    fake <-
      newFake
        ( preflightInventory
            <> [ (repoPath ("/contents/" <> brokerPath <> "?ref=main"), Value (str delegatedWorkflow))
               , (repoPath ("/contents/" <> brokerValidatorPath <> "?ref=main"), Value (str delegatedValidator))
               ]
        )
    result <- preflight (testOperator fake) Nothing
    at "ok" result `shouldSatisfy` isTrue
    at "observed" (checkNamed "default_broker" result) `shouldEqualPy` str "hamsterdan"
    calls <- fakeCalls fake
    any (\(command, _) -> brokerValidatorPath `T.isInfixOf` T.unwords command) calls `shouldBe` True

  it "test_preflight_malformed_broker_and_wrong_repository_fail" do
    fake <-
      newFake
        ( preflightInventory
            <> [ (repoPath "", Value (obj [("id", int 1), ("private", bool False), ("default_branch", str "main")]))
               , (repoPath ("/contents/" <> brokerPath <> "?ref=main"), Value (str "mixed"))
               ]
        )
    result <- preflight (testOperator fake) Nothing
    at "ok" result `shouldSatisfy` isFalse
    Set.fromList [n | item <- checksOf result, not (truthy (at "pass" item)), PStr n <- [at "name" item]]
      `shouldBe` Set.fromList ["repository_identity", "default_broker"]

  it "test_prepared_broker_is_detected_without_clone_or_mutation" do
    fake <-
      newFake
        [ ( prListKey
          , Value (list [obj [("number", int 9), ("url", str "https://github.test/pr/9"), ("headRefName", str "hamsterdan/broker-cutover-1")]])
          )
        ]
    result <- prepareBroker (testOperator fake)
    at "status" result `shouldEqualPy` str "prepared"
    at "changed" result `shouldSatisfy` isFalse
    length <$> fakeCalls fake `shouldReturn` 1

  it "test_delegated_current_broker_is_detected_after_clone_without_mutation" do
    withSystemTempDirectory "operator" \tmp -> do
      let checkout = tmp </> "demo-pr-readiness"
      createDirectoryIfMissing True (checkout </> ".github/workflows")
      createDirectoryIfMissing True (checkout </> "tools")
      TIO.writeFile (checkout </> T.unpack brokerPath) delegatedWorkflow
      TIO.writeFile (checkout </> T.unpack brokerValidatorPath) delegatedValidator
      fake <-
        newFake
          [ (prListKey, Value (list []))
          , ("git clone --origin origin https://github.com/" <> repository <> ".git " <> T.pack checkout, Value (str ""))
          , ("git fetch origin main", Value (str ""))
          ]
      let op = (testOperator fake) {withTemporary = fixedTemporary tmp}
      result <- prepareBroker op
      result
        `shouldEqualPy` obj [("command", str "prepare-broker"), ("ok", bool True), ("status", str "current"), ("changed", bool False)]
      commands <- map fst <$> fakeCalls fake
      any (\command -> take 2 command `elem` [["git", "switch"], ["git", "commit"], ["git", "push"]]) commands `shouldBe` False
      any (\command -> take 3 command == ["gh", "pr", "create"]) commands `shouldBe` False

  it "test_operator_mutation_commands_contain_no_force_merge_or_bypass" do
    -- The reference reads its own source; the port reads its own.
    source <- TIO.readFile "src/Hamsterdan/Operator.hs"
    source `shouldNotSatisfy` T.isInfixOf "\"--force\""
    source `shouldNotSatisfy` T.isInfixOf "\"merge\""
    source `shouldNotSatisfy` T.isInfixOf "\"--admin\""
    source `shouldSatisfy` T.isInfixOf "[\"python\", \"tools/scenario_control.py\", \"prepare\", scenario]"
    source `shouldSatisfy` T.isInfixOf "Set.null changed || not (changed `Set.isSubsetOf` admittedPaths)"
    source `shouldSatisfy` T.isInfixOf "[\"git\", \"ls-files\", \"--others\", \"--exclude-standard\"]"
    source `shouldSatisfy` T.isInfixOf "assertOnly op checkout changed"
    source `shouldSatisfy` T.isInfixOf "assertOnly op checkout (Set.singleton brokerPath)"
    source `shouldSatisfy` T.isInfixOf "\"reviewers[]=\" <> op.fixture.heroReviewer"

  it "test_hero_creation_admits_multiple_fixture_paths_and_requests_cris" do
    let branch = "hamsterdan/hero-review-20260803-010203"
        admitted = [".pr-lab/scenario.json", "src/hero.py", "tests/unit/test_hero.py"]
    fake <-
      newFake
        [ ("git clone --origin origin https://github.com/" <> repository <> ".git /tmp/hero-operator/demo-pr-readiness", Done (completed (str "") 0))
        , ("git fetch origin main", Value (str ""))
        , ("git switch --create " <> branch <> " origin/main", Value (str ""))
        , ("python tools/scenario_control.py prepare hero-review", Value (obj [("admitted_changed_paths", list (map str admitted))]))
        , ("python tools/scenario_control.py --attempt 2", Value (str ""))
        , ("git diff --name-only", Value (str ".pr-lab/scenario.json"))
        , ("git ls-files --others --exclude-standard", Value (str (T.intercalate "\n" (drop 1 admitted))))
        , ("git add -- " <> T.unwords admitted, Value (str ""))
        , ("git commit -m Hamsterdan demo: hero-review", Value (str ""))
        , ("git diff --name-only origin/main...HEAD", Value (str (T.intercalate "\n" admitted)))
        , ("git push --set-upstream origin " <> branch, Value (str ""))
        , ( "gh pr create --repo "
              <> repository
              <> " --base main --head "
              <> branch
              <> " --title Hamsterdan demo: hero-review --body Controlled Hamsterdan qualification scenario. Do not merge automatically."
          , Value (str "")
          )
        , ( "gh pr view " <> branch <> " --repo " <> repository <> " --json number,url,headRefName"
          , Value (obj [("number", int 45), ("url", str "https://github.test/pr/45"), ("headRefName", str branch)])
          )
        , ("--method", Value (obj []))
        , ("git rev-parse HEAD", Value (str (sha 'a')))
        ]
    let op = (testOperator fake) {stamp = pure "20260803-010203", withTemporary = fixedTemporary "/tmp/hero-operator"}
    result <- create op "hero-review"
    at "requested_reviewer" result `shouldEqualPy` str "crisbastos"
    calls <- fakeCalls fake
    any (\(command, _) -> take 4 command == ["gh", "api", "--method", "POST"]) calls `shouldBe` True

  it "test_inspection_redacts_prose_separates_attribution_and_rejects_old_identity" do
    fake <- inspectionRunner appBotLogin
    result <- inspect (testOperator fake) 7 defaultInspectOptions
    at "ok" result `shouldSatisfy` isFalse
    forM_ ["SECRET PROSE", "dashboard prose", "readiness prose", "private unrelated prose"] \prose ->
      encoded result `shouldNotSatisfy` T.isInfixOf prose
    at "attribution" result
      `shouldEqualPy` obj
        [ ("commit_author", obj [("name", str "Explicit Author")])
        , ("commit_committer", obj [("name", str "Explicit Committer")])
        , ("authenticated_author", str "human")
        , ("authenticated_committer", str appBotLogin)
        ]
    case at "markers" result of
      PList markers -> map (at "type") markers `shouldSatisfy` (\types -> pyEq (list types) (list (map str ["hamsterdan-rerun", "readiness", "impetus-rerun"])))
      _ -> expectationFailure "markers"
    checkNamed "legacy_markers_absent" result `shouldEqualPy` obj [("name", str "legacy_markers_absent"), ("pass", bool False), ("observed", int 1)]
    at "pass" (checkNamed "dashboard_present" result) `shouldSatisfy` isTrue
    at "pass" (checkNamed "readiness_advisory_present" result) `shouldSatisfy` isTrue

  it "test_inspection_fails_when_human_owns_hamsterdan_marker" do
    fake <- inspectionRunner "human"
    result <- inspect (testOperator fake) 7 defaultInspectOptions
    at "ok" result `shouldSatisfy` isFalse
    at "pass" (checkNamed "hamsterdan_comment_ownership" result) `shouldSatisfy` isFalse

  it "test_inspection_accepts_complete_fresh_hamsterdan_evidence" do
    fake <- inspectionRunner appBotLogin
    dropLastComment fake
    setResponse
      fake
      reviewComments
      ( Value
          ( list
              [ obj
                  [ ("id", int 8)
                  , ("html_url", str "https://github.test/reviews/8")
                  , ("body", str ("SECRET INLINE PROSE\n<!-- hamsterdan:finding operation=finding:one head=" <> sha 'a' <> " -->"))
                  , ("user", obj [("login", str appBotLogin)])
                  ]
              ]
          )
      )
    result <- inspect (testOperator fake) 7 defaultInspectOptions
    at "ok" result `shouldSatisfy` isTrue
    all (truthy . at "pass") (checksOf result) `shouldBe` True
    encoded result `shouldNotSatisfy` T.isInfixOf "SECRET INLINE PROSE"
    case at "comments" result of
      PList comments -> any (\c -> pyEq (at "type" c) (str "finding") && truthy (at "inline" c)) comments `shouldBe` True
      _ -> expectationFailure "comments"

  it "test_hero_inspection_proves_three_native_shapes_without_exposing_prose" do
    fake <- inspectionRunner appBotLogin
    dropLastComment fake
    let hd = sha 'a'
        finding identifier operation body path line =
          obj
            [ ("id", int identifier)
            , ("html_url", str ("https://github.test/reviews/" <> T.pack (show identifier)))
            , ("body", str (body <> "\n\n<!-- hamsterdan:finding operation=" <> operation <> " head=" <> hd <> " -->"))
            , ("path", str path)
            , ("line", int line)
            , ("user", obj [("login", str appBotLogin)])
            ]
    setResponse
      fake
      reviewComments
      ( Value
          ( list
              [ finding 8 "finding:suggestion" "PRIVATE ONE\n```suggestion\nreplacement\n```" "scenario-fixtures/hero_review/gate.py" 10
              , finding 9 "finding:conceptual" "PRIVATE TWO" "scenario-fixtures/hero_review/gate.py" 16
              , finding
                  10
                  "finding:related"
                  ( "PRIVATE THREE\nRelated locations:\n- [`src/two.py:19`](https://github.com/"
                      <> repository
                      <> "/blob/"
                      <> hd
                      <> "/src/two.py#L19)"
                  )
                  "scenario-fixtures/hero_review/cache.py"
                  11
              ]
          )
      )
    result <- inspect (testOperator fake) 7 defaultInspectOptions {expectHeroReview = True}
    at "ok" result `shouldSatisfy` isTrue
    forM_ ["hero_findings", "hero_suggestion", "hero_conceptual", "hero_related_locations"] \name ->
      at "pass" (checkNamed name result) `shouldSatisfy` isTrue
    forM_ ["PRIVATE ONE", "PRIVATE TWO", "PRIVATE THREE"] \prose -> encoded result `shouldNotSatisfy` T.isInfixOf prose

  it "test_hero_inspection_accepts_one_semantic_v5_batch_while_readiness_is_blocked" do
    fake <- inspectionRunner appBotLogin
    comments <- getResponse fake issueComments
    let hd = sha 'a'
        batch =
          T.intercalate
            "\n"
            [ "## Hamsterdan review findings"
            , ""
            , "### `hero-f01` \x2014 PRIVATE TITLE ONE"
            , "**blocking** \xB7 severity: **medium**"
            , ""
            , "PRIVATE BODY ONE"
            , ""
            , "Primary location: `scenario-fixtures/hero_review/gate.py:10`"
            , ""
            , "Suggested change:"
            , "```suggestion"
            , "replacement"
            , "```"
            , ""
            , "### `hero-f02` \x2014 PRIVATE TITLE TWO"
            , "**blocking** \xB7 severity: **high**"
            , ""
            , "PRIVATE BODY TWO"
            , ""
            , "Primary location: `scenario-fixtures/hero_review/gate.py:16`"
            , ""
            , "### `hero-f03` \x2014 PRIVATE TITLE THREE"
            , "**blocking** \xB7 severity: **medium**"
            , ""
            , "PRIVATE BODY THREE"
            , ""
            , "Primary location: `scenario-fixtures/hero_review/cache.py:11`"
            , ""
            , "Related locations:"
            , "- `scenario-fixtures/hero_review/cache.py:6`"
            , ""
            , "<!-- hamsterdan:findings-digest " <> T.replicate 64 "b" <> " -->"
            , ""
            , "<!-- hamsterdan:finding operation=findings:" <> hd <> ":i1 head=" <> hd <> " -->"
            ]
        kept = case comments of
          PList items -> [c | c@(PDict _) <- items, any (pyEq (at "id" c)) [int 3, int 6]]
          _ -> []
    setResponse
      fake
      issueComments
      ( Value
          ( list
              ( kept
                  <> [ obj
                        [ ("id", int 8)
                        , ("html_url", str "https://github.test/comments/8")
                        , ("body", str batch)
                        , ("user", obj [("login", str appBotLogin)])
                        ]
                     ]
              )
          )
      )
    result <- inspect (testOperator fake) 7 defaultInspectOptions {expectHeroReview = True, expectReadiness = False}
    at "ok" result `shouldSatisfy` isTrue
    all (truthy . at "pass") (checksOf result) `shouldBe` True
    let finding = case at "comments" result of
          PList items -> maybe (error "no finding") id (find (\c -> pyEq (at "type" c) (str "finding")) items)
          _ -> error "comments"
    finding
      `shouldEqualPy` obj
        [ ("id", int 8)
        , ("url", str "https://github.test/comments/8")
        , ("owner", str appBotLogin)
        , ("type", str "finding")
        , ("inline", bool False)
        , ("finding_count", int 3)
        , ("hero_finding_count", int 3)
        , ("suggestion_count", int 1)
        , ("conceptual_count", int 1)
        , ("related_location_count", int 1)
        , ("owned_by_app", bool True)
        ]
    forM_
      ["PRIVATE TITLE ONE", "PRIVATE TITLE TWO", "PRIVATE TITLE THREE", "PRIVATE BODY ONE", "PRIVATE BODY TWO", "PRIVATE BODY THREE"]
      \prose -> encoded result `shouldNotSatisfy` T.isInfixOf prose

  it "test_inspection_parser_exposes_explicit_blocked_readiness_checkpoint" do
    let (text, flag) = parsed ["inspect", "--pr", "59", "--expect-hero-review", "--expect-readiness", "absent"]
    flag "expect_hero_review" `shouldBe` True
    text "expect_readiness" `shouldBe` Just "absent"

  it "test_operator_ignores_embedded_nonfinal_trusted_marker" do
    let hd = sha 'a'
        injected =
          obj
            [ ("id", int 11)
            , ( "body"
              , str
                  ( "<!-- hamsterdan:readiness operation=readiness:old head="
                      <> hd
                      <> " -->\n\n<!-- hamsterdan:finding operation=finding:current head="
                      <> hd
                      <> " -->"
                  )
              )
            , ("user", obj [("login", str appBotLogin)])
            ]
    (safe, markers) <- safeComment injected appBotLogin True
    fmap (at "type") safe `shouldSatisfy` maybe False (pyEq (str "finding"))
    map (at "type") markers `shouldSatisfy` (\types -> pyEq (list types) (list [str "finding"]))

  describe "test_authority_inspection_asserts_real_provider_facts_without_prose" do
    forM_ ["non-draft", "strict-stale", "review-requested", "changes-requested", "unresolved-thread"] \expected ->
      it (T.unpack expected) do
        fake <- authorityRunner
        result <- inspectAuthority (testOperator fake) 9 expected
        at "ok" result `shouldSatisfy` isTrue
        at "authority" result `shouldEqualPy` expectedAuthority
        encoded result `shouldNotSatisfy` T.isInfixOf "submitted_at"
        encoded result `shouldNotSatisfy` T.isInfixOf "thread-1"

  it "test_authority_inspection_distinguishes_approval_and_conflict" do
    approved <- authorityRunner
    modify approved reviewsPath \case
      PList items -> list (take (length items - 1) items <> [merge (last items) [("state", str "APPROVED")]])
      other -> other
    modify approved "graphql" (setPath ["data", "repository", "pullRequest", "reviewDecision"] (str "APPROVED"))
    approvedResult <- inspectAuthority (testOperator approved) 9 "required-approval"
    at "ok" approvedResult `shouldSatisfy` isTrue

    conflict <- authorityRunner
    modify conflict pullPath (`merge` [("mergeable", bool False), ("mergeable_state", str "dirty")])
    conflictResult <- inspectAuthority (testOperator conflict) 9 "conflict"
    at "ok" conflictResult `shouldSatisfy` isTrue

  it "test_authority_inspection_rejects_incomplete_thread_evidence" do
    fake <- authorityRunner
    modify fake "graphql" (setPath ["data", "repository", "pullRequest", "reviewThreads", "pageInfo", "hasNextPage"] (bool True))
    inspectAuthority (testOperator fake) 9 "unresolved-thread" `shouldThrow` throwsOperatorError "exceeds one bounded page"

  it "test_authority_review_folding_preserves_dismissal_tombstone_regardless_of_order" do
    let approved = obj [("id", int 1), ("submitted_at", str "2026-08-02T01:00:00Z"), ("state", str "APPROVED"), ("user", obj [("login", str "Reviewer")])]
        dismissed = merge approved [("id", int 2), ("submitted_at", str "2026-08-02T02:00:00Z"), ("state", str "DISMISSED")]
        reapproved = merge approved [("id", int 3), ("submitted_at", str "2026-08-02T03:00:00Z")]
    latestReviews (list [approved, dismissed]) `shouldBe` Right []
    latestReviews (list [dismissed, approved]) `shouldBe` Right []
    latestReviews (list [dismissed, approved, reapproved]) `shouldBe` Right [("Reviewer", "APPROVED")]

  it "test_authority_policy_evidence_matches_production_normalization" do
    production <- case toJson False rules of
      Right (Array items) -> derivePolicy [members | Object members <- items]
      _ -> fail "rules"
    let (strict, _, approvals, resolution) = production
    authorityPolicy rules `shouldBe` Right (strict, approvals, resolution)

  it "test_authority_inspection_includes_team_requests_and_requires_stable_determinate_basis" do
    team <- authorityRunner
    modify team (repoPath "/pulls/9/requested_reviewers") (`merge` [("users", list []), ("teams", list [obj [("slug", str "maintainers")]])])
    result <- inspectAuthority (testOperator team) 9 "review-requested"
    at "ok" result `shouldSatisfy` isTrue
    atPath ["authority", "requested_teams"] result `shouldEqualPy` list [str "maintainers"]

    indeterminate <- authorityRunner
    modify indeterminate pullPath (`merge` [("mergeable", none)])
    inspectAuthority (testOperator indeterminate) 9 "strict-stale" `shouldThrow` throwsOperatorError "indeterminate"

  it "test_authority_inspection_rejects_provider_basis_change_during_collection" do
    fake <- authorityRunner
    reads' <- newIORef (0 :: Int)
    let moving command cwd = case command of
          ["gh", "api", path] | path == pullPath -> do
            modifyIORef' reads' (+ 1)
            count <- readIORef reads'
            value <- getResponse fake pullPath
            let answer = if count > 1 then merge value [("head", merge (at "head" value) [("sha", str (sha 'd'))])] else value
            pure (completed answer 0)
          _ -> fakeRunner fake command cwd
    inspectAuthority (operatorWith moving digests) 9 "non-draft" `shouldThrow` throwsOperatorError "changed during inspection"

  describe "test_authority_inspection_rejects_full_potentially_incomplete_pages" do
    it "reviews" do
      fake <- authorityRunner
      let review index =
            obj
              [ ("id", int index)
              , ("submitted_at", str ("2026-08-02T00:00:" <> T.justifyRight 2 '0' (T.pack (show index)) <> "Z"))
              , ("state", str "APPROVED")
              , ("user", obj [("login", str ("reviewer-" <> T.pack (show index)))])
              ]
      setResponse fake reviewsPath (Value (list (map review [0 .. 99])))
      inspectAuthority (testOperator fake) 9 "non-draft" `shouldThrow` throwsOperatorError "review authority exceeds"
    it "rules" do
      fake <- authorityRunner
      setResponse fake rulesPath (Value (list (replicate 100 (obj []))))
      inspectAuthority (testOperator fake) 9 "non-draft" `shouldThrow` throwsOperatorError "policy exceeds"

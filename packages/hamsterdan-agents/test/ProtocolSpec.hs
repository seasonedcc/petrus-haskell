-- | @tests/unit/agents/test_protocol.py@: provider-neutral agent request and
-- result contract tests.
module ProtocolSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Hamsterdan.Agents.Protocol
import Hamsterdan.Agents.Validate
import Petrus.Json (Json (..))
import PiDoubles
import Test.Hspec

reviewRequest :: ReviewRequest
reviewRequest =
  ReviewRequest
    { repository = "owner/repo"
    , pullRequest = 3
    , epoch = 2
    , head = headSha
    , base = baseSha
    , diffPath = "diff.patch"
    , policy = [("required_checks", strs ["unit"]), ("digest", str "policy")]
    , reviewLenses = ["correctness", "tests"]
    , contextPaths = []
    , actionsEvidence = []
    , priorFindings = []
    , priorComments = []
    , priorReplies = []
    , appliedChanges = []
    }

-- | @result_for(request, **extra)@.
resultFor :: (Text, Integer, Integer, Text, Text) -> [(Text, Json)] -> Json
resultFor (repository, pullRequest, epoch, headValue, baseValue) extra =
  obj
    ( [ ("repository", str repository)
      , ("pull_request", int pullRequest)
      , ("epoch", int epoch)
      , ("head", str headValue)
      , ("base", str baseValue)
      ]
        <> extra
    )

reviewCommon :: (Text, Integer, Integer, Text, Text)
reviewCommon = ("owner/repo", 3, 2, headSha, baseSha)

conversationCommon :: (Text, Integer, Integer, Text, Text)
conversationCommon = ("owner/repo", 1, 0, headSha, baseSha)

finding :: [Json] -> Text -> Json
finding related identity =
  obj
    [ ("id", str identity)
    , ("path", str "src/one.py")
    , ("line", int 4)
    , ("related_locations", arr related)
    , ("title", str "Keep both guards aligned")
    , ("body", str "These guards enforce one invariant but currently disagree.")
    , ("severity", str "high")
    , ("confidence", Float 0.99)
    , ("evidence", str "The primary path allows the state rejected by the related path.")
    , ("blocking", Bool True)
    , ("suggestion", str "if state.is_ready:")
    ]

newLineage :: Text -> Json
newLineage identity = obj [("finding_id", str identity), ("state", str "new"), ("supersedes", Null)]

location :: Text -> Integer -> Json
location path line = obj [("path", str path), ("line", int line)]

conversationRequest :: [[(Text, Json)]] -> ConversationRequest
conversationRequest allowed =
  ConversationRequest
    { repository = "owner/repo"
    , pullRequest = 1
    , epoch = 0
    , head = headSha
    , base = baseSha
    , commentContext = []
    , actor = []
    , dashboard = []
    , gates = []
    , findings = []
    , allowedIntents = allowed
    }

applyRequest :: ConversationRequest
applyRequest = conversationRequest [[("type", str "apply"), ("mutation", Bool True), ("arguments", strs ["id"])]]

intentsOf :: Either Failure AgentResult -> Maybe [[(Text, Json)]]
intentsOf = \case
  Right (ResultConversation result) -> Just result.intents
  _ -> Nothing

spec :: Spec
spec = describe "tests/unit/agents/test_protocol.py" $ do
  it "test_review_accepts_non_contiguous_related_locations" $ do
    let value = finding [location "src/two.py" 19] "F1"
        result =
          validateResult
            KindReview
            (resultFor reviewCommon [("status", str "blocking"), ("findings", arr [value]), ("lineage", arr [newLineage "F1"])])
            (AgentReview reviewRequest)
            Nothing
    case result of
      Right (ResultReview review) -> map Object review.findings `shouldBe` [value]
      other -> expectationFailure (show other)

  describe "test_review_rejects_unsafe_or_duplicate_related_locations" $
    forM_
      [ [location "src/one.py" 4]
      , [location "../escape.py" 2]
      , [location "src/two.py" 0]
      ]
      $ \related -> it (show related) $
        refusedMatching "related location" $
          validateResult
            KindReview
            (resultFor reviewCommon [("status", str "blocking"), ("findings", arr [finding related "F1"]), ("lineage", arr [newLineage "F1"])])
            (AgentReview reviewRequest)
            Nothing

  it "test_review_rejects_marker_unsafe_finding_identity" $ do
    let identity = "F1 -->\n<!-- hamsterdan:dashboard -->"
    refusedMatching "finding id" $
      validateResult
        KindReview
        (resultFor reviewCommon [("status", str "blocking"), ("findings", arr [finding [] identity]), ("lineage", arr [newLineage identity])])
        (AgentReview reviewRequest)
        Nothing

  it "test_conversation_accepts_one_declared_explicit_mutation" $ do
    let intent =
          [ ("type", str "apply")
          , ("arguments", obj [("id", str "F1")])
          , ("mutation", Bool True)
          , ("explicit", Bool True)
          , ("confidence", int 1)
          ]
    intentsOf (validateResult KindConversation (resultFor conversationCommon [("intents", arr [obj intent])]) (AgentConversation applyRequest) Nothing)
      `shouldBe` Just [intent]

  it "test_conversation_accepts_only_explicit_operation_scoped_recovery" $ do
    let request =
          conversationRequest
            [ [ ("type", str "recover_publication")
              , ("mutation", Bool False)
              , ("arguments", strs ["operation"])
              , ("requires_explicit", Bool True)
              ]
            ]
        intent explicit =
          [ ("type", str "recover_publication")
          , ("arguments", obj [("operation", str ("push:comment:9:" <> headSha <> ":i1"))])
          , ("mutation", Bool False)
          , ("explicit", Bool explicit)
          , ("confidence", int 1)
          ]
        check explicit = validateResult KindConversation (resultFor conversationCommon [("intents", arr [obj (intent explicit)])]) (AgentConversation request) Nothing
    intentsOf (check True) `shouldBe` Just [intent True]
    refusedMatching "requires explicit" (check False)

  it "test_conversation_rejects_undeclared_intent" $ do
    let intent =
          obj
            [ ("type", str "invented")
            , ("arguments", obj [("id", str "F1")])
            , ("mutation", Bool True)
            , ("explicit", Bool True)
            , ("confidence", int 1)
            ]
    refusedMatching "unauthorized" $
      validateResult KindConversation (resultFor conversationCommon [("intents", arr [intent])]) (AgentConversation applyRequest) Nothing

  describe "test_conversation_requires_exactly_one_raw_intent" $
    forM_ [[], [obj [], obj []]] $ \intents -> it (show intents) $
      refusedMatching "exactly one intent" $
        validateResult KindConversation (resultFor conversationCommon [("intents", arr intents)]) (AgentConversation applyRequest) Nothing

  describe "test_conversation_rejects_malformed_intent_argument_values" $
    forM_
      [ ("change", True, ["request"], str "")
      , ("change", True, ["request"], str "   ")
      , ("reply", False, ["message"], arr [])
      , ("reassign", False, ["assignee"], obj [("login", str "octocat")])
      , ("dismiss", False, ["findings"], str "F1")
      , ("dismiss", False, ["findings"], strs [""])
      ]
      $ \(name, mutation, arguments, value) -> it (show (name, mutation, arguments, value)) $ do
        let request = conversationRequest [[("type", str name), ("mutation", Bool mutation), ("arguments", strs arguments)]]
            intent =
              obj
                [ ("type", str name)
                , ("arguments", obj [(firstOf arguments, value)])
                , ("mutation", Bool mutation)
                , ("explicit", Bool mutation)
                , ("confidence", int 1)
                ]
        refusedMatching "invalid intent" $
          validateResult KindConversation (resultFor conversationCommon [("intents", arr [intent])]) (AgentConversation request) Nothing

  describe "test_review_rejects_malformed_shape_or_correlation" $
    forM_
      [ (("epoch", Bool True), "correlation mismatch")
      , (("findings", str "bad"), "invalid findings")
      , (("findings", arr [obj [("id", str "incomplete")]]), "fields differ")
      ]
      $ \((key, value), message) -> it (show (key, value, message)) $ do
        let base = [("status", str "clear"), ("findings", arr []), ("lineage", arr [])]
            members = membersOf (resultFor reviewCommon base)
            updated = Object [(k, if k == key then value else v) | (k, v) <- members]
        refusedMatching message (validateResult KindReview updated (AgentReview reviewRequest) Nothing)

  it "test_repair_change_requires_confirmed_reproduction" $ do
    let request =
          CodingRequest
            { kind = "repair"
            , repository = "owner/repo"
            , pullRequest = 1
            , epoch = 0
            , head = headSha
            , base = baseSha
            , ref = "repair/test"
            , selectedWork = []
            , failureEvidence = []
            , fingerprint = ""
            , lineage = []
            , reproductionStatus = "unknown"
            , mergeBase = False
            }
        value =
          resultFor
            conversationCommon
            [ ("kind", str "repair")
            , ("ref", str "repair/test")
            , ("status", str "changed")
            , ("reproduction_status", str "not_reproduced")
            , ("diff", str "x")
            , ("changed_files", strs ["x.py"])
            , ("validation_evidence", arr [obj [("status", str "passed")]])
            , ("proposed_commit_message", str "Repair bug")
            ]
    refusedMatching "confirmed reproduction" (validateResult KindCoding value (AgentCoding request) (Just ["x.py"]))

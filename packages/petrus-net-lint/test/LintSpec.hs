-- | The lint on small nets: a marking collapsed into one token, a real mutex,
-- and one net for each rule.
module LintSpec (spec) where

import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Petrinet.Schema
import Petrus.Net.Declared
import Petrus.Net.Lint
import Test.Hspec

-- | A net from its places, and its transitions, each with its input arcs
-- (place, mode, filter) and its output places. Every transition has a
-- handler, as Petrus's own nets do.
netOf :: [Text] -> [(Text, [(Text, ArcMode, Maybe FilterDeclaration)], [Text], [GuardDeclaration])] -> Net
netOf places steps =
  either (error . show) id $
    mkNet
      NetSpec
        { places = map (place . path) places
        , transitions = [(transition (path t)) {handler = Just (HandlerSymbol t), guards} | (t, _, _, guards) <- steps]
        , arcs =
            concat
              [ [(arc (path from) (path t)) {mode, filter = f} | (from, mode, f) <- ins]
                  <> [arc (path t) (path to) | to <- outs]
              | (t, ins, outs, _) <- steps
              ]
        , completion = Nothing
        , name = Nothing
        }
  where
    path = either (error . show) id . netPath

takes, peeks, without :: Text -> (Text, ArcMode, Maybe FilterDeclaration)
takes p = (p, Consume, Nothing)
peeks p = (p, Read, Nothing)
without p = (p, Inhibit, Nothing)

by :: Text -> (Text, ArcMode, Maybe FilterDeclaration) -> (Text, ArcMode, Maybe FilterDeclaration)
by f (p, mode, _) = (p, mode, Just (FilterSymbol f))

when' :: Text -> GuardDeclaration
when' = GuardCel . either (error . T.unpack) id . cel

outcome :: Text -> When -> [(Text, Int)] -> Outcome
outcome name when puts = Outcome {name, when, puts = Map.fromList puts}

declaring :: [(Text, [Outcome])] -> Declared
declaring outcomes = noDeclarations {outcomes = Map.fromList outcomes}

rulesOf :: [Finding] -> [(Text, Text)]
rulesOf = map (\f -> (f.rule, f.at))

-- | A builder's run as a state machine: one token through clone, build
-- and publish, with build's handler choosing built or stopped.
builderRun :: Net
builderRun =
  netOf
    ["item", "cloned", "built", "stopped", "published"]
    [ ("arrive", [], ["item"], [])
    , ("clone", [takes "item"], ["cloned"], [])
    , ("build", [takes "cloned"], ["built", "stopped"], [])
    , ("publish", [takes "built"], ["published"], [])
    ]

builderRunDeclared :: Declared
builderRunDeclared =
  (declaring [("build", [outcome "built" OnSuccess [("built", 1)], outcome "stopped" OnSuccess [("stopped", 1)]])])
    {finalPlaces = ["stopped", "published"]}

-- | Requests wait for a lock, work holding it, and give it back.
mutex :: Net
mutex =
  netOf
    ["waiting", "lock", "working", "done"]
    [ ("arrive", [], ["waiting"], [])
    , ("acquire", [takes "waiting", takes "lock"], ["working"], [])
    , ("release", [takes "working"], ["done", "lock"], [])
    ]

mutexDeclared :: Declared
mutexDeclared = noDeclarations {initial = Map.fromList [("lock", 1)], finalPlaces = ["done"], outcomes = Map.fromList [("release", [outcome "released" OnSuccess [("done", 1), ("lock", 1)]])]}

spec :: Spec
spec = describe "the net lint" $ do
  it "finds a marking collapsed into one token, in its shape and its handler's choice" $
    rulesOf (lint builderRun builderRunDeclared [])
      `shouldBe` [("single-token-s-net", "net"), ("no-concurrency", "net"), ("handler-choice", "build")]

  it "speaks of the marking, and says what to do" $ do
    case map (.message) (lint builderRun builderRunDeclared []) of
      [collapsed, _, choice] -> do
        collapsed `shouldSatisfy` ("the marking has collapsed into one token" `T.isPrefixOf`)
        choice `shouldSatisfy` ("build's handler fills built, or stopped, one per firing" `T.isPrefixOf`)
      other -> expectationFailure ("three findings, not " <> show other)

  it "finds nothing in a real mutex" $
    lint mutex mutexDeclared [] `shouldBe` []

  it "asks a handler that fills two places to declare its outcomes" $
    rulesOf (lint mutex mutexDeclared {outcomes = Map.empty} [])
      `shouldBe` [("undeclared-outcomes", "release")]

  it "takes an Activity's failure as the world's answer, not the handler's choice" $
    lint mutex mutexDeclared {outcomes = Map.fromList [("release", [outcome "released" OnSuccess [("done", 1), ("lock", 1)], outcome "failed" OnFailure [("lock", 1)]])]} []
      `shouldBe` []

  it "finds tokens routed by filters, and by a status field compared with constants" $ do
    let routed =
          netOf
            ["jobs", "lock", "a", "b"]
            [ ("arrive", [], ["jobs"], [])
            , ("check", [by "checking" (takes "jobs"), takes "lock"], ["a", "lock"], [when' "token.status == \"checks\""])
            , ("ship", [by "shipping" (takes "jobs"), takes "lock"], ["b", "lock"], [when' "token.status == \"ships\" && token.retries >= 0"])
            ]
        declared =
          noDeclarations
            { initial = Map.fromList [("lock", 1)]
            , finalPlaces = ["a", "b"]
            , outcomes = Map.fromList [(t, [outcome "done" OnSuccess [(p, 1), ("lock", 1)]]) | (t, p) <- [("check", "a"), ("ship", "b")]]
            }
    rulesOf (lint routed declared [])
      `shouldBe` [("status-switch", "jobs"), ("status-switch", "field status"), ("counted-resource", "ship")]

  it "finds a place nothing both fills and empties" $ do
    rulesOf (lint mutex mutexDeclared {finalPlaces = []} []) `shouldBe` [("lonely-place", "done")]
    let inbox = netOf ["inbox", "lock", "done"] [("work", [takes "inbox", takes "lock"], ["done", "lock"], [])]
        declared = noDeclarations {initial = Map.fromList [("lock", 1)], finalPlaces = ["done"], outcomes = Map.fromList [("work", [outcome "worked" OnSuccess [("done", 1), ("lock", 1)]])]}
    rulesOf (lint inbox declared []) `shouldBe` [("lonely-place", "inbox")]
    lint inbox declared {ingress = ["inbox"]} [] `shouldBe` []
    let facts = netOf ["inbox", "lock", "done", "config", "blocked"] [("work", [takes "inbox", takes "lock", peeks "config", without "blocked"], ["done", "lock"], [])]
    rulesOf (lint facts declared {ingress = ["inbox", "config"]} []) `shouldBe` [("lonely-place", "blocked")]

  it "finds a read or an inhibitor trusted while an Activity runs" $ do
    let checking =
          netOf
            ["waiting", "slot", "open", "paused", "done"]
            [ ("arrive", [], ["waiting"], [])
            , ("open-up", [], ["open"], [])
            , ("pause", [], ["paused"], [])
            , ("work", [takes "waiting", takes "slot", peeks "open", without "paused"], ["done", "slot"], [])
            , ("close", [takes "open"], [], [])
            , ("resume", [takes "paused"], [], [])
            ]
        declared =
          noDeclarations
            { initial = Map.fromList [("slot", 1)]
            , finalPlaces = ["done"]
            , outcomes = Map.fromList [("work", [outcome "worked" OnSuccess [("done", 1), ("slot", 1)], outcome "failed" OnFailure [("slot", 1)]])]
            }
    map (\f -> (f.rule, f.at, f.message)) (lint checking declared [])
      `shouldBe` [("checked-once", "work", "work runs an Activity, and checks open (read) and paused (inhibitor) only when it fires. Petrus doesn't hold a read or an inhibitor while the Activity runs, so the condition can change before it ends. Take a token to hold it, or check again where the Activity's outcome joins")]

  it "drops a waived finding, and reports a waiver that matches nothing or can't waive" $ do
    let accepted = Waiver {rule = "handler-choice", at = "build", reason = "decides on the build's exit code", acceptedBy = "a test"}
        stale = Waiver {rule = "lonely-place", at = "item", reason = "no longer lonely", acceptedBy = "a test"}
        wrong = Waiver {rule = "declaration", at = "build", reason = "never", acceptedBy = "a test"}
    rulesOf (lint builderRun builderRunDeclared [accepted, stale, wrong])
      `shouldBe` [("single-token-s-net", "net"), ("no-concurrency", "net"), ("stale-waiver", "item"), ("stale-waiver", "build")]

  it "refuses declarations that name what the net doesn't have" $
    rulesOf (lint mutex mutexDeclared {scenarios = [Scenario "one" (Map.fromList [("arrive", 1), ("release", 1)])], ingress = ["outbox"], initial = Map.fromList [("lock", 1), ("keys", 2)], outcomes = Map.fromList [("release", [outcome "released" OnSuccess [("done", 1), ("waiting", 1)]]), ("nothing", [])]} [])
      `shouldBe` [("declaration", "nothing"), ("declaration", "release"), ("declaration", "keys"), ("declaration", "outbox"), ("declaration", "release")]

  it "reads the declarations and the waivers, and refuses a member it doesn't know" $ do
    parseDeclared declaredFile `shouldBe` Right expected
    parseDeclared "{\"v\": 1, \"outcome\": {}}" `shouldBe` Left "a net's declarations has members it doesn't know: outcome"
    parseDeclared "{\"outcomes\": {}}" `shouldBe` Left "a net's declarations needs \"v\": 1"
    parseWaivers "{\"v\": 1, \"waivers\": [{\"rule\": \"handler-choice\", \"at\": \"revoke\", \"reason\": \"History decides\", \"accepted_by\": \"review 1\"}]}"
      `shouldBe` Right [Waiver {rule = "handler-choice", at = "revoke", reason = "History decides", acceptedBy = "review 1"}]
    parseWaivers "{\"v\": 1, \"waivers\": [{\"rule\": \"handler-choice\", \"at\": \"revoke\", \"reason\": \" \", \"accepted_by\": \"review 1\"}]}"
      `shouldBe` Left "a waiver names its rule, where, why, and who accepted it"
  where
    declaredFile :: ByteString
    declaredFile =
      "{\"v\": 1, \"initial\": {\"key-ring\": 1}, \"ingress\": [\"requests\"],\
      \ \"outcomes\": {\"revoke\": [{\"name\": \"recorded\", \"when\": \"success\", \"puts\": {\"destroying\": 1}},\
      \ {\"name\": \"failed\", \"when\": \"failure\", \"puts\": {\"key-ring\": 1}}]},\
      \ \"final_places\": [\"done\"], \"final_markings\": [{\"key-ring\": 1}],\
      \ \"laws\": [{\"name\": \"the key ring\", \"weights\": {\"key-ring\": 1, \"@revoke\": 1}, \"total\": 1}],\
      \ \"scenarios\": [{\"name\": \"two\", \"deliver\": {\"request\": 2}}]}"
    expected =
      Declared
        { initial = Map.fromList [("key-ring", 1)]
        , ingress = ["requests"]
        , outcomes = Map.fromList [("revoke", [outcome "recorded" OnSuccess [("destroying", 1)], outcome "failed" OnFailure [("key-ring", 1)]])]
        , finalPlaces = ["done"]
        , finalMarkings = [Map.fromList [("key-ring", 1)]]
        , laws = [Law {name = "the key ring", weights = Map.fromList [("key-ring", 1), ("@revoke", 1)], total = 1}]
        , scenarios = [Scenario {name = "two", deliver = Map.fromList [("request", 2)]}]
        }

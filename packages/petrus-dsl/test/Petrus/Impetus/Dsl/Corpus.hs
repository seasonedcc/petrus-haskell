-- | The Haskell twins of every net @differential/dsl_corpus.py@ authors with
-- the reference DSL, case by case and in the same authoring order.
module Petrus.Impetus.Dsl.Corpus
  ( corpus
  , chain
  , stamped
  ) where

import Control.Monad (forM_, void, when)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), TypedArgs, param)
import Petrus.Impetus.Dsl
import Petrus.Impetus.Dsl.Support
import Petrus.Impetus.Petrinet.Schema (handlerUri)

-- | Every case: its name and the reference-equivalent outcome.
corpus :: [(Text, Either DslError BuiltNet)]
corpus =
  [ ("orders", orders)
  , ("multiplicity", multiplicity)
  , ("snapshots.first", snapshots False)
  , ("snapshots.second", snapshots True)
  , ("configuration", configuration)
  , ("configuration.conflict", configurationConflict)
  , ("places.conflict", builtFrom (named "places") (void (p "pending" >>= color "Order" >>= color "Receipt")))
  , ("place-overrides.before", placeOverrides 0)
  , ("place-overrides.changed", placeOverrides 1)
  , ("place-overrides.cleared", placeOverrides 2)
  , ("place-overrides.undeclared", builtFrom (named "place-overrides") (void (p "undeclared" >>= recolor (Just "Order"))))
  , ("transition-overrides.handler", transitionOverrides 1)
  , ("transition-overrides.cleared", transitionOverrides 2)
  , ("invalid-overrides.undeclared", builtFrom (named "invalid-overrides") (void (t "undeclared" >>= override [handler "process"])))
  , ("invalid-overrides.empty", builtFrom (named "invalid-overrides") (void (t "process" >>= configure [handler "process"] >>= override [])))
  , ("atomic-overrides", atomicOverrides)
  , ("callable-specs", callableSpecs)
  , ("late-configuration.before", lateConfiguration False)
  , ("late-configuration.after", lateConfiguration True)
  , ("invalid.weight", builtFrom (named "invalid") (void (p "left" ~> arc {arcWeight = 0} ~> t "right")))
  , ("invalid.color", builtFrom (named "invalid") (void ((p "left" >>= color "Order") ~> arc {arcColor = Just "Receipt"} ~> t "right")))
  , ("typed", typed)
  , ("custom-guard", customGuard)
  , ("exact-bool", exactBool)
  , ("guards", guardForms)
  , ("scalar", scalar)
  , ("typed.untyped-input", untypedInput)
  , ("identity", identity)
  , ("reuse", reuse)
  , ("callable-snapshots.first", callableSnapshots False)
  , ("callable-snapshots.second", callableSnapshots True)
  , ("stamp-rebase", stampRebase)
  , ("flat-and-stamped", flatAndStamped)
  , ("live.first", live False)
  , ("live.second", live True)
  , ("restamp", restamp)
  , ("restamp.kept-override", restampKeptOverride)
  , ("stamp-direct-content.error", directContent False)
  , ("stamp-direct-content.after", directContent True)
  , ("stamp-direct-content.owners", directContentOwners)
  , ("stamp-diagnostics.enclosing", stampDiagnostics "enclosing")
  , ("stamp-diagnostics.missing-transition", stampDiagnostics "missing-transition")
  , ("stamp-diagnostics.missing-place", stampDiagnostics "missing-place")
  , ("stamp-diagnostics.scope-itself", stampDiagnostics "scope-itself")
  , ("root-stamp", builtFrom (named "root") (stamp pendingProcessChild))
  , ("missing-connection", missingConnection)
  , ("nested-stamps", nestedStamps)
  , ("copy", copied)
  , ("copy.stamped", copyStamped)
  , ("inherited-configuration", inheritedConfiguration)
  , ("inherited-configuration.conflict", inheritedConflict (void (t "process" >>= configure [handler "y"])))
  , ("inherited-configuration.color-conflict", inheritedConflict (void (p "done" >>= color "Receipt")))
  , ("stamped-completion", stampedCompletion)
  , ("reserved.p", reserved "p")
  , ("reserved.t", reserved "t")
  , ("reserved.s", reserved "s")
  , ("reserved.stamp", reserved "stamp")
  , ("scope-segment.empty", builtFrom unnamed (scope "" (pure ())))
  , ("scope-segment.nested.scope", builtFrom unnamed (scope "nested.scope" (pure ())))
  , ("apply.flat", builtFrom (named "flat") (void (scope "apply" (p "pending" ~> t "process"))))
  , ("apply.composed", builtFrom (named "composed") (scope "apply" (stamp pendingProcessChild)))
  , ("unnamed", builtFrom unnamed (void (p "pending" ~> t "process")))
  , ("empty-name", builtFrom (named "") (pure ()))
  , ("agent-net", agentNet)
  , ("simulation-scenario", simulationScenario)
  , ("observation-inspection", observationInspection)
  , ("chain-50", netSpec (named "chain-50") (chain 50) >>= build)
  , ("stamped-30", stamped 30 >>= build)
  ]

builtFrom :: Header -> (forall s. Author s ()) -> Either DslError BuiltNet
builtFrom header program = netSpec header program >>= build

orders :: Either DslError BuiltNet
orders = builtFrom (named "orders") $ do
  pending <- p "pending" >>= color "Order"
  receipt <- p "receipt" >>= color "Receipt"
  process <- t "process" >>= configure [handler "process"]
  void $ pending ~> process ~> receipt
  void $ pending ~> readArc {arcWeight = 2, arcColor = Just "Order", arcFilter = Just (FilterSymbol "current")} ~> process

multiplicity :: Either DslError BuiltNet
multiplicity = builtFrom (named "multiplicity") $ do
  let inscription = arc {arcColor = Just "Order"}
  void $ sequence [p "left", p "right"] ~> inscription ~> sequence [t "first", t "second"]
  void $ p "left" ~> inscription ~> t "first"

snapshots :: Bool -> Either DslError BuiltNet
snapshots late = builtFrom (named "snapshots") $ do
  void $ p "pending" ~> t "first"
  if late then void (t "first" ~> p "done") else pure ()

configuration :: Either DslError BuiltNet
configuration = builtFrom (named "configuration") $ do
  let fields = [handler "first", guards ["ready"], timers [Delay (IntNumber 3)]]
  transition <- t "process" >>= configure fields
  void $ (p "pending" >>= color "Order") ~> transition
  void $ configure fields transition
  void $ attempt (configure [handler "second"] transition)
  void $ override [handler "second"] transition

configurationConflict :: Either DslError BuiltNet
configurationConflict = builtFrom (named "configuration") $ do
  transition <- t "process" >>= configure [handler "first", guards ["ready"], timers [Delay (IntNumber 3)]]
  void $ (p "pending" >>= color "Order") ~> transition
  void $ configure [handler "second"] transition

placeOverrides :: Int -> Either DslError BuiltNet
placeOverrides stage = builtFrom (named "place-overrides") $ do
  place <- p "pending" >>= color "Order"
  when (stage >= 1) . void $ recolor (Just "Receipt") place
  when (stage >= 2) . void $ recolor Nothing place

transitionOverrides :: Int -> Either DslError BuiltNet
transitionOverrides stage = builtFrom (named "transition-overrides") $ do
  transition <- t "process" >>= configure [handler "process", guards ["ready"], timers [Delay (IntNumber 3)]]
  void $ (p "pending" >>= color "Order") ~> transition
  void $ override [noHandler] transition
  when (stage >= 2) . void $ override [guards [], timers []] transition

-- | The reference touches @net.t.other@ while evaluating the refused
-- override; the refusal itself (a node used as a guard) does not type-check.
atomicOverrides :: Either DslError BuiltNet
atomicOverrides = builtFrom (named "atomic-overrides") $ do
  transition <- t "process" >>= configure [handler "process", guards ["ready"]]
  void $ (p "pending" >>= color "Order") ~> transition
  void $ t "other"

callableSpecs :: Either DslError BuiltNet
callableSpecs = builtFrom (named "callable-specs") $ do
  transition <- t "publish"
  published <- p "published" >>= color "Receipt"
  audited <- p "audited" >>= color "Receipt"
  void $ configure [handler "publish"] transition
  void $ transition ~> published
  void $ transition ~> audited

lateConfiguration :: Bool -> Either DslError BuiltNet
lateConfiguration late = builtFrom (named "late-configuration") $ do
  transition <- t "publish"
  void $ transition ~> (p "published" >>= color "Receipt")
  if late
    then do
      void $ configure [handler "publish"] transition
      void $ transition ~> (p "audit" >>= color "Receipt")
    else pure ()

typed :: Either DslError BuiltNet
typed = builtFrom (named "typed") $ do
  pending <- p "pending" >>= color "Order"
  receipt <- p "receipt" >>= color "Receipt"
  transition <- t "process" >>= configure [handler (direct "process" processArgs), guards [typedGuard "positive" positiveArgs]]
  void $ pending ~> transition ~> receipt

customGuard :: Either DslError BuiltNet
customGuard = builtFrom (named "custom-guard") $ do
  pending <- p "pending" >>= color "Order"
  configuration' <- p "configuration" >>= color "Config"
  transition <- t "review" >>= configure [guards [typedGuard "within_limit" withinLimitArgs]]
  void $ pending ~> transition
  void $ configuration' ~> readArc ~> transition

exactBool :: Either DslError BuiltNet
exactBool = builtFrom (named "exact-bool") $ do
  pending <- p "pending" >>= color "Order"
  transition <- t "review" >>= configure [guards [typedGuard "truthy" (const True <$> (param "order" :: TypedArgs Order))]]
  void $ pending ~> transition

guardForms :: Either DslError BuiltNet
guardForms = builtFrom (named "guards") $ do
  transition <- t "review"
  let positive = typedGuard "positive" positiveArgs
  void $ configure [guards ["named", positive, celGuard (unsafeCel "true"), positive]] transition
  void $ (p "pending" >>= color "Order") ~> transition

scalar :: Either DslError BuiltNet
scalar = builtFrom (named "scalar") $ do
  void $ t "review" >>= configure [guards ["named"]]
  void $ p "pending" ~> t "review"

untypedInput :: Either DslError BuiltNet
untypedInput = builtFrom (named "typed-refusal") $ do
  transition <- t "process" >>= configure [handler (direct "process" processArgs)]
  void $ p "pending" ~> transition ~> (p "receipt" >>= color "Receipt")

identity :: Either DslError BuiltNet
identity = builtFrom (named "identity") $ do
  transition <- t "process" >>= configure [handler (petriHandler "handler" emptyHandler), guards [petriGuard "guard" trueGuard]]
  void $ p "pending" ~> transition

reuse :: Either DslError BuiltNet
reuse = builtFrom (named "reuse") $ do
  let specification = petriGuard "guard" trueGuard
  void $ t "left" >>= configure [guards [specification]]
  void $ t "right" >>= configure [guards [specification]]
  void $ p "pending" ~> sequence [t "left", t "right"]

callableSnapshots :: Bool -> Either DslError BuiltNet
callableSnapshots second = builtFrom (named "callable-snapshots") $ do
  transition <- t "process" >>= configure [handler (petriHandler "first_handler" emptyHandler)]
  void $ p "pending" ~> transition
  if second then void (override [handler (petriHandler "second_handler" emptyHandler)] transition) else pure ()

reviewLens :: NetSpec
reviewLens = mustRight $ netSpec (named "review-lens") $
  void $
    (p "work" >>= color "Order")
      ~> (t "review" >>= configure [handler (petriHandler "handler" emptyHandler), guards [petriGuard "guard" trueGuard]])
      ~> p "done"

stampRebase :: Either DslError BuiltNet
stampRebase = builtFrom (named "reviews") $ scope "review" $ do
  scope "correctness" (stamp reviewLens)
  scope "risk" (stamp reviewLens)
  void $ scope "correctness" (p "done" >>= color "Receipt")
  void $ scope "risk" (p "done" >>= color "Receipt")
  void $ scope "correctness" (t "review" >>= override [handler "correctness"])

flatAndStamped :: Either DslError BuiltNet
flatAndStamped = builtFrom (named "root") $ scope "review" $ do
  void $ p "context" ~> t "publish"
  scope "correctness" (stamp finishChild)
  void $ scope "correctness" (p "done") ~> t "publish"
  where
    finishChild = mustRight $ netSpec (named "child") $ void $ p "pending" ~> t "finish" ~> p "done"

processChild :: Bool -> NetSpec
processChild audited = mustRight $ netSpec (named "child") $ do
  void $ p "pending" ~> t "process" ~> p "done"
  if audited then void (t "process" ~> p "audit") else pure ()

live :: Bool -> Either DslError BuiltNet
live second = builtFrom (named "root") (scope "worker" (stamp (processChild second)))

restamp :: Either DslError BuiltNet
restamp = builtFrom (named "root") $ scope "worker" $ do
  stamp first
  void $ t "process" >>= override [handler "specialized"]
  stamp second
  where
    first = mustRight $ netSpec (named "first") $ void $ p "pending" ~> (t "process" >>= configure [handler "first"]) ~> p "done"
    second = mustRight $ netSpec (named "second") $ void $ p "ready" ~> (t "process" >>= configure [handler "second"]) ~> p "complete"

restampKeptOverride :: Either DslError BuiltNet
restampKeptOverride = builtFrom (named "root") $ scope "worker" $ do
  stamp first
  void $ t "process" >>= override [handler "specialized"]
  void $ p "done" >>= color "Receipt"
  where
    first = mustRight $ netSpec (named "first") $ void $ p "pending" ~> (t "process" >>= configure [handler "first"]) ~> p "done"

pendingProcessChild :: NetSpec
pendingProcessChild = mustRight $ netSpec (named "child") $ void $ p "pending" ~> t "process"

directContent :: Bool -> Either DslError BuiltNet
directContent recover = builtFrom (named "root") $ scope "worker" $ do
  void $ p "local"
  if recover then void (attempt (stamp pendingProcessChild)) else stamp pendingProcessChild

directContentOwners :: Either DslError BuiltNet
directContentOwners = builtFrom (named "root") $ scope "worker" $ do
  void $ p "local" ~> t "act"
  scope "inner" (stamp pendingProcessChild)
  stamp pendingProcessChild

stampDiagnostics :: Text -> Either DslError BuiltNet
stampDiagnostics which = builtFrom (named "root") $ scope "worker" $ do
  stamp pendingProcessChild
  case which of
    "enclosing" -> scope "nested" (stamp replacement)
    "missing-transition" -> void (t "missing" >>= override [handler "missing"])
    "missing-place" -> void (p "missing" >>= color "Order")
    _ -> void (p "pending" >>= recolor Nothing)
  where
    replacement = mustRight (netSpec unnamed (pure ()))

missingConnection :: Either DslError BuiltNet
missingConnection = builtFrom (named "root") $ do
  scope "worker" (stamp pendingProcessChild)
  void $ scope "worker" (p "missing") ~> t "publish"

nestedStamps :: Either DslError BuiltNet
nestedStamps = builtFrom (named "root") (scope "parent" (stamp outer))
  where
    inner = mustRight $ netSpec (named "inner") $ void $ p "pending" ~> t "process" ~> p "done"
    outer = mustRight (netSpec (named "outer") (scope "child" (stamp inner)))

copied :: Either DslError BuiltNet
copied = do
  root <- netSpec (named "root") (scope "worker" (stamp (processChild False)))
  flatten root >>= build

copyStamped :: Either DslError BuiltNet
copyStamped = do
  let child =
        mustRight $ netSpec (named "child") $ void $
          p "pending" ~> (t "process" >>= configure [handler "x"]) ~> (p "done" >>= color "Order")
  outer <- netSpec (named "outer") $ scope "inner" $ do
    stamp child
    void $ t "process" >>= override [handler "y"]
    void $ p "done" >>= recolor (Just "Receipt")
  flat <- flatten outer
  builtFrom (named "wrapper") $ do
    scope "a" (stamp flat)
    scope "b" (stamp flat)
    void $ scope "a" (scope "inner" (p "done")) ~> t "join"
    void $ t "join" ~> scope "b" (scope "inner" (p "pending"))

inheritedConfiguration :: Either DslError BuiltNet
inheritedConfiguration = builtFrom (named "root") $ scope "worker" $ do
  stamp (processChild False)
  void $ p "pending" >>= color "Order"
  void $ p "pending" >>= color "Order"
  void $ t "process" >>= configure [handler "x", timers [Delay (IntNumber 2)]]
  void $ t "process" >>= configure [handler "x", timers [Delay (IntNumber 2)]]
  void $ t "process" >>= override [guards ["g"]]

inheritedConflict :: (forall s. Author s ()) -> Either DslError BuiltNet
inheritedConflict step = builtFrom (named "root") $ scope "worker" $ do
  stamp child
  step
  where
    child =
      mustRight $ netSpec (named "child") $ void $
        p "pending" ~> (t "process" >>= configure [handler "x"]) ~> (p "done" >>= color "Order")

stampedCompletion :: Either DslError BuiltNet
stampedCompletion = builtFrom (named "root") (scope "worker" (stamp child))
  where
    child = mustRight $ netSpec (withCompletion (CompletionSymbol "complete") (named "child")) $ void $ p "pending" ~> t "process"

reserved :: Text -> Either DslError BuiltNet
reserved segment = builtFrom (named "reserved-scopes") (void (scope segment (p "pending" ~> t "process")))

agentNet :: Either DslError BuiltNet
agentNet = do
  built <- builtFrom (withCompletion (CompletionCel (unsafeCel "size(done) != 0")) (named "agent-as-net")) $ do
    modelPending <- p "model_pending" >>= color "LoopState"
    modelSettled <- p "model_settled" >>= color "ModelSettlement"
    toolPending <- p "tool_pending" >>= color "ToolWork"
    toolSettled <- p "tool_settled" >>= color "HandsSettlement"
    done <- p "done" >>= color "Terminal"
    model <- t "model_phase" >>= configure [handler "model_phase"]
    classify <- t "classify_model" >>= configure [handler (petriHandler "_classify" emptyHandler)]
    execute <- t "execute_tool" >>= configure [handler "hands", guards [petriGuard "_execute" trueGuard]]
    reject <- t "reject_tool" >>= configure [handler (petriHandler "_reject_tool" emptyHandler), guards [petriGuard "_reject" trueGuard]]
    record <- t "record_result" >>= configure [handler (petriHandler "_record" emptyHandler)]
    let colored' c = arc {arcColor = Just c}
    void $ modelPending ~> colored' "LoopState" ~> model ~> colored' "ModelSettlement" ~> modelSettled
    void $ modelSettled ~> colored' "ModelSettlement" ~> classify
    void $ classify ~> colored' "LoopState" ~> modelPending
    void $ classify ~> colored' "ToolWork" ~> toolPending
    void $ classify ~> colored' "Terminal" ~> done
    void $ toolPending ~> colored' "ToolWork" ~> [execute, reject]
    void $ execute ~> colored' "HandsSettlement" ~> toolSettled ~> colored' "HandsSettlement" ~> record
    void $ reject ~> colored' "ToolWork" ~> toolPending
    void $ reject ~> colored' "LoopState" ~> modelPending
    void $ reject ~> colored' "Terminal" ~> done
    void $ record ~> colored' "ToolWork" ~> toolPending
    void $ record ~> colored' "LoopState" ~> modelPending
    void $ record ~> colored' "Terminal" ~> done
  -- The reference binds its two Activity bridges by URI after the build.
  let activities =
        Map.fromList
          [ (uri, ActivityBound (ActivityHandler (\_ -> Left "unused") (\_ _ -> Left "unused") Nothing))
          | at <- [np "model_phase", np "execute_tool"]
          , Just uri <- [handlerUri built.net at]
          ]
  Right built {handlers = Map.union activities built.handlers}

simulationScenario :: Either DslError BuiltNet
simulationScenario = builtFrom (withCompletion (CompletionCel (unsafeCel "size(done) > 0")) (named "bounded-simulation-demo")) $ do
  void $ p "pending" >>= color "SimulationItem"
  void $ p "done" >>= color "SimulationItem"
  void $ t "finish" >>= configure [guards [celGuard (unsafeCel "size(pending) > 0")], timers [Delay (IntNumber 5)]]
  void $ p "pending" ~> arc {arcFilter = Just (FilterCel (unsafeCel "priority >= 1"))} ~> t "finish" ~> p "done"

observationInspection :: Either DslError BuiltNet
observationInspection = do
  lens <- netSpec (named "lens") $ do
    review <-
      t "review"
        >>= configure
          [ handler (petriHandler "handler" emptyHandler)
          , guards ["ready", celGuard (unsafeCel "true")]
          , timers [Delay (IntNumber 3), Until (IntNumber 11)]
          ]
    void $ (p "pending" >>= color "Work") ~> review ~> (p "done" >>= color "Done")
    void $ (p "context" >>= color "Context") ~> readArc {arcFilter = Just (FilterCel (unsafeCel "true"))} ~> review
    void $ (p "blocked" >>= color "Block") ~> inhibitArc {arcFilter = Just (FilterSymbol "same_key")} ~> review
  builtFrom (withCompletion (CompletionCel (unsafeCel "size(review.correctness.done) > 0")) (named "canonical-design")) $ do
    scope "review" (scope "correctness" (stamp lens))
    void $ t "ingest" ~> scope "review" (scope "correctness" (p "pending"))
    void $ scope "review" (scope "correctness" (t "review" ~> p "done"))

-- | A flat chain of @size@ places and @size@ transitions (benchmark
-- workload a).
chain :: Int -> Author s ()
chain size = forM_ [0 .. size - 1] $ \i ->
  void $
    (p ("p" <> showT i) >>= color "Item")
      ~> (t ("t" <> showT i) >>= configure [handler "step"])
      ~> (p ("p" <> showT (i + 1)) >>= color "Item")

-- | A 10-node child stamped at @scopes@ scopes nested to depth 3
-- (benchmark workload b).
stamped :: Int -> Either DslError NetSpec
stamped scopes = do
  unit <- netSpec (named "unit") $ forM_ [0 .. 4 :: Int] $ \i ->
    void $
      (p ("in" <> showT i) >>= color "Item")
        ~> (t ("step" <> showT i) >>= configure [handler "step"])
        ~> (p "out" >>= color "Item")
  netSpec (named ("stamped-" <> showT scopes)) $ forM_ [0 .. scopes - 1] $ \i ->
    scope ("a" <> showT (i `mod` 10)) $
      scope ("b" <> showT (i `div` 10 `mod` 10)) $
        scope ("c" <> showT (i `div` 100)) (stamp unit)

showT :: Int -> Text
showT = T.pack . show

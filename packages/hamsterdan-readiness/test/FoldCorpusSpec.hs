-- | The fold and gate-handler differential corpus
-- (scripts/gen_fold_corpus.py): every handler call the upstream net_v5
-- suite makes, plus perturbed fold bindings, replayed by hand against the
-- Haskell handlers. Each row's binding is fed to the handler wired for its
-- transition, and the produced tokens (or invocation, or error text) must
-- spell byte for byte as the pinned Python's.
module FoldCorpusSpec (spec) where

import Data.IORef (newIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Corpus
import Harness (freshWorld, makeActivities)
import Hamsterdan.Readiness.NetV5.Gating (wireGates)
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5, derived, gates)
import Petrus.Activity
  ( ActivityFailureFields (..)
  , ActivityInvocation
  , ExecutionPolicyFields (..)
  , activityFailure
  , numberFromJson
  , numberJson
  , policyFields
  )
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), HandlerResult (..))
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Petrinet (Binding (..), NetPath, Token (..), netPathText)
import Petrus.Impetus.Petrinet.Schema (handlerUri, netPath, outputs)
import Petrus.Json (Json (..))
import Test.Hspec

spec :: Spec
spec = describe "fold corpus (pinned Python handler calls)" $ do
  rows <- runIO (readCorpus "folds.jsonl")
  handlers <- runIO wired
  let loopOf row = T.takeWhile (/= '.') (text "transition" row)
      kindOf row = if text "call" row == "fold" then "folds" else "gate handlers"
      groups = nub [(loopOf r, kindOf r) | r <- rows]
  it ("covers every loop (" <> show (length rows) <> " rows)") $
    nub (map fst groups) `shouldMatchList` ["ci", "conv", "dash", "esc", "life", "mut", "ready", "rem", "review", "startup"]
  mapM_
    ( \(loop, kind) -> do
        let mine = [r | r <- rows, loopOf r == loop, kindOf r == kind]
        it (T.unpack loop <> " " <> kind <> " (" <> show (length mine) <> " rows)") $
          expectNone (concatMap (check handlers) mine)
    )
    groups

wired :: IO (Map ImplementationRef BoundHandler)
wired = do
  ref <- newIORef freshWorld
  either (fail . T.unpack) pure (wireGates built gates (makeActivities ref) derived)

built :: BuiltNet
built = either (const (error "buildNetV5 failed")) id buildNetV5

path :: Text -> NetPath
path = either (error . T.unpack) id . netPath

tokenOf :: Json -> Token
tokenOf = \case
  Array [String color, payload] -> Token (Just color) payload
  Array [Null, payload] -> Token Nothing payload
  other -> error ("corpus token: " <> show other)

selectionsOf :: Text -> Json -> [(NetPath, [Token])]
selectionsOf key row =
  [ (path place, map tokenOf ts)
  | Array [String place, Array ts] <- array key row
  ]

tokenJson :: Token -> Json
tokenJson t = Array [maybe Null String t.color, t.payload]

producedJson :: HandlerResult -> Json
producedJson r =
  Object [("tokens", Array [Array [String (netPathText p), Array (map tokenJson ts)] | (p, ts) <- r.tokens])]

check :: Map ImplementationRef BoundHandler -> Json -> [String]
check handlers row =
  let transition = path (text "transition" row)
      binding =
        Binding
          { transition
          , consumed = selectionsOf "consumed" row
          , read = selectionsOf "read" row
          , delivered = map tokenOf (array "delivered" row)
          }
      expected = maybe Null id (member "outcome" row)
      handler = handlerUri built.net transition >>= \uri -> Map.lookup (Exact uri) handlers
      actual = case (text "call" row, handler) of
        ("fold", Just (PureHandler f)) -> fmap producedJson (f binding (outputs built.net transition))
        ("prepare", Just (ActivityBound h)) -> fmap invocationJson (h.prepare binding)
        ("project", Just (ActivityBound h)) -> fmap producedJson (h.project binding (field "result"))
        ("project_failure", Just (ActivityBound h)) -> case h.projectFailure of
          Nothing -> Left "<no failure projection>"
          Just projectFailure -> do
            failure <- activityFailure (failureOf (field "failure"))
            fmap producedJson (projectFailure binding failure)
        (call, _) -> Left ("<no " <> call <> " handler>")
      rendered = either (\e -> Object [("error", String e)]) id actual
      field k = maybe Null id (member k row)
   in [ T.unpack (text "call" row <> " " <> text "transition" row)
          <> "\n  binding:  "
          <> T.unpack (T.take 600 (spelled (Object [(k, field k) | k <- ["consumed", "read", "delivered"]])))
          <> "\n  expected: "
          <> T.unpack (spelled expected)
          <> "\n  actual:   "
          <> T.unpack (spelled rendered)
      | spelled rendered /= spelled expected || spelled expected == "<unencodable>" || expected == Null
      ]

invocationJson :: ActivityInvocation -> Json
invocationJson inv =
  Object
    [ ( "invocation"
      , Object
          [ ("activity", String inv.activity)
          , ("input", inv.input)
          , ("policy", policyJson (policyFields inv.policy))
          , ("correlation", maybe Null String inv.correlation)
          , ("idempotency", maybe Null String inv.idempotency)
          ]
      )
    ]

policyJson :: ExecutionPolicyFields -> Json
policyJson f =
  Object
    [ ("attempts", Int f.attempts)
    , ("heartbeat_timeout", Int f.heartbeatTimeout)
    , ("initial_interval", numberJson f.initialInterval)
    , ("coefficient", numberJson f.coefficient)
    , ("max_interval", numberJson f.maxInterval)
    , ("jitter", numberJson f.jitter)
    , ("start_to_close", maybe Null numberJson f.startToClose)
    , ("schedule_to_close", maybe Null numberJson f.scheduleToClose)
    ]

failureOf :: Json -> ActivityFailureFields
failureOf value =
  ActivityFailureFields
    { failureError = text "error" value
    , failureKind = text "kind" value
    , failureDetails = maybe Null id (member "details" value)
    , failureRetryable = member "retryable" value == Just (Bool True)
    , failureRetryAfter = member "retry_after" value >>= numberFromJson
    }

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE MultiWayIf #-}

-- | Shared test harness for the V5 actor-loop topology
-- (@tests/unit/readiness/net_v5/harness.py@).
--
-- Spawns the composed net on the engine and drives host-normalized
-- observations through the ingress doors. The harness plays the HOST: it
-- owns a fake world with the current-authority grant record, moves the
-- world BEFORE the net observes any event, and binds every gate to a
-- world-backed fake activity.
module Harness
  ( -- * The fake world
    World (..)
  , Authority (..)
  , Comment (..)
  , Push (..)
  , freshWorld
  , makeActivities
  , gateDefinitions
    -- * Spawning
  , H (..)
  , spawn
  , spawnWith
  , spawnHeld
  , spawnHeldWith
  , worldOf
  , modifyWorld
  , setWorld
    -- * Driving
  , drive
  , pump
  , pumpHolding
  , releaseOne
  , completeOne
  , pendingWork
  , pendingAll
  , without
  , deliver
  , deliverHeld
    -- * Observation
  , tokens
  , one
  , oneAt
  , commentKeys
  , factsOf
  , projection
  , markingOf
  , recordsOf
  , requested
    -- * Shorthand
  , seeHead
  , seeHeadWith
  , HeadArgs (..)
  , headArgs
  , seeRun
  , seeRunWith
  , RunArgs (..)
  , runArgs
  , comment
  , commentWith
  , commentHeld
  , commentHeldWith
    -- * JSON helpers
  , obj
  , at
  , atPath
  , str
  , int
  , arr
  , texts
  , keys
  , dummyContext
  , callDefinition
  , builtNet
  , engineOptions
  ) where

import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (forM, unless, when)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (Contract, validate)
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.PyLiteral (literalEval, toJson)
import Hamsterdan.Readiness.NetV5.Gating
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5, derived, gates, seedMarking)
import Petrus.Activity
  ( ActivityDefinition (..)
  , ActivityExecutionContext (..)
  , ActivityInvocation (..)
  , activityDeclaration
  , callActivity
  )
import Petrus.Cel.Impetus (celCompilers)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.Binding (BoundHandler)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.History.Records (ActivityRequested (..), Record (..))
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Petrinet (Marking, NetPath, Token (..), deposit, placeTokens)
import Petrus.Impetus.Petrinet.Schema (netPath)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory qualified as InMemory
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)

-- ---------------------------------------------------------------------------
-- JSON helpers

obj :: [(Text, Json)] -> Json
obj = Object

str :: Text -> Json
str = String

int :: Integer -> Json
int = Int

arr :: [Json] -> Json
arr = Array

texts :: [Text] -> Json
texts = Array . map String

-- | @value[key]@ (a missing key fails the test).
at :: Json -> Text -> Json
at value key = case value of
  Object members -> maybe (error ("missing key " <> show key <> " in " <> show value)) id (lookup key members)
  _ -> error ("not an object: " <> show value)

atPath :: Json -> [Text] -> Json
atPath = foldl at

-- | The object without the named members.
without :: [Text] -> Json -> Json
without names = \case
  Object members -> Object [m | m@(k, _) <- members, k `notElem` names]
  other -> other

keys :: Json -> [Text]
keys = \case
  Object members -> map fst members
  _ -> []

-- ---------------------------------------------------------------------------
-- The fake world

data Authority = Authority
  { incarnation :: Integer
  , phase :: Text
  , head :: Text
  , base :: Text
  , policy :: Text
  }
  deriving stock (Eq, Show)

data Comment = Comment
  { key :: Text
  , kind :: Text
  , head :: Text
  , body :: Json
  }
  deriving stock (Eq, Show)

data Push = Push
  { key :: Text
  , op :: Text
  , from :: Text
  , to :: Text
  }
  deriving stock (Eq, Show)

data World = World
  { branchHead :: Text
  , baseHead :: Text
  , policy :: Text
  , prState :: Text
  , authority :: Authority
  , reruns :: [Text]
  , rerunsMode :: Maybe Text
  , runsByHead :: Map Text (Integer, Integer)
  , agentCalls :: Int
  , agentFindings :: Map Text [Json]
  , agentResults :: Map Text (Json, Json)
  , agentMode :: Maybe Text
  , comments :: [Comment]
  , commentsMode :: Maybe Text
  , publicationBlocker :: Maybe Text
  , announceBlocker :: Maybe Text
  , commentAttempts :: Int
  , pushes :: [Push]
  , gitMode :: Maybe Text
  , dashboard :: [Text]
  , dashMode :: Maybe Text
  , dashRequests :: [([Text], Text)]
  , log :: [(Text, Text)]
  }
  deriving stock (Eq, Show)

freshWorld :: World
freshWorld =
  World
    { branchHead = ""
    , baseHead = ""
    , policy = ""
    , prState = "ready"
    , authority = Authority {incarnation = 0, phase = "running", head = "", base = "", policy = ""}
    , reruns = []
    , rerunsMode = Nothing
    , runsByHead = Map.empty
    , agentCalls = 0
    , agentFindings = Map.empty
    , agentResults = Map.empty
    , agentMode = Nothing
    , comments = []
    , commentsMode = Nothing
    , publicationBlocker = Nothing
    , announceBlocker = Nothing
    , commentAttempts = 0
    , pushes = []
    , gitMode = Nothing
    , dashboard = []
    , dashMode = Nothing
    , dashRequests = []
    , log = []
    }

-- | A result variant from its constructor keywords (validated as the
-- reference's pydantic constructor does).
made :: forall a. (Contract a) => [(Text, Json)] -> Variant
made fields = case validate @a (Object fields) of
  Right value -> variantOf value
  Left e -> error ("fake activity built an invalid result: " <> show e <> " from " <> show fields)

-- | Whether the host grant and the provider fields all match the work.
authorityStands :: World -> Integer -> Text -> Text -> Text -> Bool
authorityStands w incarnation h b p =
  w.authority.phase == "running"
    && w.authority.incarnation == incarnation
    && w.branchHead == h
    && w.baseHead == b
    && w.policy == p

lookupText :: Text -> Json -> Maybe Json
lookupText k = \case
  Object members -> lookup k members
  _ -> Nothing

type Gate = IORef World -> Json -> IO Variant

rerunGate :: Gate
rerunGate ref raw = do
  work <- decoded @C.RerunReq raw
  w <- readIORef ref
  let common = [("fingerprint", str work.fingerprint), ("op", str work.op), ("mem", Object work.mem)]
  if
    | work.fingerprint `elem` w.reruns ->
        pure
          ( made @C.RerunLanded
              ( common
                  ++ [ ("run_id", int work.runId)
                     , ("attempt", int work.attempt)
                     , ("disposition", str "existing")
                     , ("cut_run_id", int work.runId)
                     , ("cut_attempt", int work.attempt)
                     ]
              )
          )
    | w.rerunsMode == Just "unknown" ->
        pure
          ( made @C.RerunFault
              ( common
                  ++ [ ("reason", str "unknown provider terminal")
                     , ("fp", str work.fp)
                     , ("head", str work.head)
                     , ("base", str work.base)
                     , ("policy", str work.policy)
                     , ("incarnation", int work.incarnation)
                     , ("run_id", int work.runId)
                     , ("attempt", int work.attempt)
                     ]
              )
          )
    | not (authorityStands w work.incarnation work.head work.base work.policy) ->
        pure
          ( made @C.RerunMoved
              ( common
                  ++ [ ("fp", str work.fp)
                     , ("head", str work.head)
                     , ("base", str work.base)
                     , ("policy", str work.policy)
                     , ("incarnation", int work.incarnation)
                     ]
              )
          )
    | otherwise -> do
        let (cutRun, cutAttempt) = Map.findWithDefault (0, 0) work.head w.runsByHead
        writeIORef ref w {reruns = w.reruns ++ [work.fingerprint], log = w.log ++ [("rerun", work.fingerprint)]}
        pure
          ( made @C.RerunLanded
              ( common
                  ++ [ ("run_id", int work.runId)
                     , ("attempt", int work.attempt)
                     , ("disposition", str "requested")
                     , ("cut_run_id", int cutRun)
                     , ("cut_attempt", int cutAttempt)
                     ]
              )
          )

reviewAgent :: Gate
reviewAgent ref raw = do
  work <- decoded @C.RoundOpen raw
  w <- readIORef ref
  let auth = w.authority
  if not (authorityStands w work.incarnation work.head work.base work.policy)
    then
      pure
        ( made @C.RoundMoved
            [ ("head", str work.head)
            , ("incarnation", int work.incarnation)
            , ("observed", str w.branchHead)
            , ("observed_base", str w.baseHead)
            , ("observed_policy", str w.policy)
            , ("observed_incarnation", int auth.incarnation)
            , ("observed_phase", str auth.phase)
            , ("mem", Object work.mem)
            ]
        )
    else do
      writeIORef ref w {agentCalls = w.agentCalls + 1}
      case w.agentMode of
        Just "deferred" ->
          pure
            ( made @C.RoundDeferred
                [ ("operation", str work.operation)
                , ("head", str work.head)
                , ("base", str work.base)
                , ("policy", str work.policy)
                , ("incarnation", int work.incarnation)
                , ("prior_findings", Array (map Object work.priorFindings))
                , ("prior_lineage", Array (map Object work.priorLineage))
                , ("mem", Object work.mem)
                , ("attempt", int work.attempt)
                , ("blocker", str "9adff0dc-4784-4eed-9c78-047d6952efed")
                ]
            )
        Just "unable" ->
          pure
            ( made @C.RoundUnable
                [ ("head", str work.head)
                , ("incarnation", int work.incarnation)
                , ("category", str "unable")
                , ("mem", Object work.mem)
                ]
            )
        _ -> do
          let (findings, lineage) = case Map.lookup work.head w.agentResults of
                Just (f, l) -> (f, l)
                Nothing ->
                  let fresh =
                        Map.findWithDefault
                          [ obj
                              [ ("id", str ("f-" <> work.head))
                              , ("note", str ("finding:" <> work.head))
                              , ("blocking", Bool True)
                              ]
                          ]
                          work.head
                          w.agentFindings
                      prior = map Object work.priorFindings
                      byId = foldl (\acc finding -> assign (idOf finding) finding acc) [] (prior ++ fresh)
                      priorIds = map idOf prior
                      merged = map snd byId
                      lineage' =
                        [ obj
                            [ ("finding_id", idOf finding)
                            , ("state", str (if idOf finding `elem` priorIds then "still_open" else "new"))
                            , ("supersedes", Null)
                            ]
                        | finding <- merged
                        ]
                   in (Array merged, Array lineage')
          pure
            ( made @C.AgentReview
                [ ("head", str work.head)
                , ("base", str work.base)
                , ("policy", str work.policy)
                , ("incarnation", int work.incarnation)
                , ("findings", findings)
                , ("lineage", lineage)
                , ("mem", Object work.mem)
                ]
            )
  where
    idOf finding = maybe Null id (lookupText "id" finding)
    assign k v acc
      | any ((== k) . fst) acc = [(k', if k' == k then v else v') | (k', v') <- acc]
      | otherwise = acc ++ [(k, v)]

publishGate :: Gate
publishGate ref raw = do
  work <- decoded @C.Publishable raw
  w0 <- readIORef ref
  let findings = Array (map Object work.findings)
      landed =
        made @C.ReviewLanded
          [ ("head", str work.head)
          , ("incarnation", int work.incarnation)
          , ("findings", findings)
          , ("effect", str work.effect)
          , ("mem", Object work.mem)
          ]
  case [c | c <- w0.comments, c.key == work.effect] of
    prior : _
      | prior.body /= findings ->
          pure (made @C.ReviewFault [("reason", str ("effect identity collision: " <> work.effect)), ("mem", Object work.mem)])
      | otherwise -> pure landed
    []
      | Just blocker <- w0.publicationBlocker
      , not (T.null blocker) ->
          pure
            ( made @C.PublicationDeferred
                [ ("operation", str work.op)
                , ("head", str work.head)
                , ("base", str work.base)
                , ("policy", str work.policy)
                , ("incarnation", int work.incarnation)
                , ("findings", findings)
                , ("effect", str work.effect)
                , ("mem", Object work.mem)
                , ("attempt", int 1)
                , ("blocker", str blocker)
                ]
            )
      | otherwise -> attempt (3 :: Int)
      where
        attempt 0 =
          pure
            ( made @C.ReviewBlocked
                [ ("head", str work.head)
                , ("base", str work.base)
                , ("policy", str work.policy)
                , ("incarnation", int work.incarnation)
                , ("findings", findings)
                , ("effect", str work.effect)
                , ("op", str work.op)
                , ("failure_class", str "transport_ambiguity")
                , ("provider_status", Null)
                , ("provider_detail", str "none")
                , ("mem", Object work.mem)
                ]
            )
        attempt n = do
          modifyIORef' ref (\w -> w {commentAttempts = w.commentAttempts + 1})
          w <- readIORef ref
          case w.commentsMode of
            Just "retryable" -> attempt (n - 1)
            Just "unknown" -> pure (made @C.ReviewFault [("reason", str "unknown provider terminal"), ("mem", Object work.mem)])
            _
              | not (authorityStands w work.incarnation work.head work.base work.policy) ->
                  pure
                    ( made @C.ReviewMoved
                        [ ("head", str work.head)
                        , ("observed", str w.branchHead)
                        , ("observed_base", str w.baseHead)
                        , ("observed_policy", str w.policy)
                        , ("observed_incarnation", int w.authority.incarnation)
                        , ("observed_phase", str w.authority.phase)
                        , ("findings", findings)
                        , ("mem", Object work.mem)
                        ]
                    )
              | otherwise -> do
                  unless (null work.findings) $
                    writeIORef
                      ref
                      w
                        { comments = w.comments ++ [Comment {key = work.effect, kind = "findings", head = work.head, body = findings}]
                        , log = w.log ++ [("comment", work.effect)]
                        }
                  pure landed

gitGate :: Gate
gitGate ref raw = do
  work <- decoded @C.MutWork raw
  w <- readIORef ref
  let auth = w.authority
      moved =
        made @C.MovedM
          [ ("op", str work.op)
          , ("op_key", str work.opKey)
          , ("head", str work.head)
          , ("incarnation", int work.incarnation)
          , ("observed", str w.branchHead)
          , ("observed_base", str w.baseHead)
          , ("observed_policy", str w.policy)
          , ("observed_incarnation", int auth.incarnation)
          , ("observed_phase", str auth.phase)
          ]
      pushed newHead =
        made @C.Pushed
          [ ("op", str work.op)
          , ("op_key", str work.opKey)
          , ("head", str work.head)
          , ("new_head", str newHead)
          , ("incarnation", int work.incarnation)
          , ("lineage", str work.lineage)
          ]
      fault reason =
        made @C.FaultM
          [ ("op", str work.op)
          , ("op_key", str work.opKey)
          , ("head", str work.head)
          , ("base", str work.base)
          , ("policy", str work.policy)
          , ("reason", str reason)
          , ("incarnation", int work.incarnation)
          , ("kind", str work.kind)
          , ("instruction", str work.instruction)
          , ("run_id", int work.runId)
          , ("attempt", int work.attempt)
          ]
  case [p | p <- w.pushes, p.key == work.opKey] of
    prior : _ -> pure (pushed prior.to)
    []
      | auth.phase /= "running" || auth.incarnation /= work.incarnation || w.baseHead /= work.base || w.policy /= work.policy ->
          pure moved
      | w.gitMode == Just "unable" ->
          pure
            ( made @C.DeclinedM
                [ ("op", str work.op)
                , ("op_key", str work.opKey)
                , ("head", str work.head)
                , ("incarnation", int work.incarnation)
                , ("category", str "unable")
                , ("reason", str "agent produced no change")
                ]
            )
      | w.branchHead /= work.head -> pure moved
      | w.gitMode == Just "fault" -> pure (fault "unknown provider terminal")
      | otherwise -> do
          let newHead = work.head <> "+" <> work.op
          writeIORef
            ref
            w
              { branchHead = newHead
              , pushes = w.pushes ++ [Push {key = work.opKey, op = work.op, from = work.head, to = newHead}]
              , log = w.log ++ [("push", work.opKey)]
              }
          pure (if w.gitMode == Just "crash" then fault "link lost after push" else pushed newHead)

replyGate :: Gate
replyGate ref raw = do
  work <- decoded @C.ReplyReq raw
  w <- readIORef ref
  let k = "reply:" <> work.id
      replied = made @C.Replied [("id", str work.id), ("text", str work.text)]
      faulted reason = made @C.ReplyFault [("id", str work.id), ("text", str work.text), ("reason", str reason)]
  case [c | c <- w.comments, c.key == k] of
    prior : _
      | prior.body /= str work.text -> pure (faulted ("effect identity collision: " <> k))
      | otherwise -> pure replied
    [] -> case w.commentsMode of
      Just "retryable" -> pure (made @C.ReplyBlocked [("id", str work.id), ("text", str work.text)])
      Just "unknown" -> pure (faulted "unknown provider terminal")
      _ -> do
        writeIORef ref w {comments = w.comments ++ [Comment k "reply" "" (str work.text)], log = w.log ++ [("comment", k)]}
        pure replied

reminderGate :: Gate
reminderGate ref raw = do
  work <- decoded @C.RemReq raw
  w <- readIORef ref
  let k = "reminder:" <> work.timerId
  if any ((== k) . (.key)) w.comments
    then pure (made @C.RemLanded [("timer_id", str work.timerId)])
    else case w.commentsMode of
      Just "retryable" -> pure (made @C.RemBlocked [("timer_id", str work.timerId)])
      Just mode -> pure (made @C.RemFault [("timer_id", str work.timerId), ("reason", str mode)])
      Nothing -> do
        writeIORef ref w {comments = w.comments ++ [Comment k "reminder" "" (str "")], log = w.log ++ [("comment", k)]}
        pure (made @C.RemLanded [("timer_id", str work.timerId)])

announceGate :: Gate
announceGate ref raw = do
  work <- decoded @C.AnnounceReq raw
  w <- readIORef ref
  let k = work.op
      landed = made @C.ALanded [("incarnation", int work.incarnation), ("head", str work.head)]
  if
    | any ((== k) . (.key)) w.comments -> pure landed
    | Just blocker <- w.announceBlocker ->
        pure
          ( made @C.ADeferred
              [ ("op", str work.op)
              , ("incarnation", int work.incarnation)
              , ("head", str work.head)
              , ("base", str work.base)
              , ("policy", str work.policy)
              , ("strict_base", Bool work.strictBase)
              , ("base_current", Bool work.baseCurrent)
              , ("blocker", str blocker)
              ]
          )
    | w.commentsMode == Just "retryable" ->
        pure
          ( made @C.ABlocked
              [("incarnation", int work.incarnation), ("head", str work.head), ("base", str work.base), ("policy", str work.policy)]
          )
    | w.commentsMode == Just "unknown" ->
        pure (made @C.AFault [("op", str work.op), ("incarnation", int work.incarnation), ("reason", str "unknown provider terminal")])
    | (work.strictBase && not work.baseCurrent)
        || not (authorityStands w work.incarnation work.head work.base work.policy) ->
        pure
          ( made @C.AMoved
              [ ("incarnation", int work.incarnation)
              , ("observed_head", str w.branchHead)
              , ("observed_base", str w.baseHead)
              , ("observed_policy", str w.policy)
              , ("observed_incarnation", int w.authority.incarnation)
              , ("observed_phase", str w.authority.phase)
              ]
          )
    | otherwise -> do
        writeIORef ref w {comments = w.comments ++ [Comment k "ready" work.head (str "")], log = w.log ++ [("comment", k)]}
        pure landed

dashGate :: Gate
dashGate ref raw = do
  work <- decoded @C.DashReq raw
  modifyIORef' ref (\w -> w {dashRequests = w.dashRequests ++ [(work.entries, work.digest)]})
  w <- readIORef ref
  let attempted =
        [ ("entries", texts work.entries)
        , ("digest", str work.digest)
        , ("desired_entries", texts work.desiredEntries)
        , ("desired_digest", str work.desiredDigest)
        ]
  if
    | w.authority.phase == "quiescent" ->
        pure
          ( made @C.DashDeferred
              (attempted ++ [("landed", str work.landed), ("blocked", Object work.blocked), ("faulted", Object work.faulted)])
          )
    | w.dashMode == Just "retryable" -> pure (made @C.DashBlocked attempted)
    | w.dashMode == Just "unknown" -> pure (made @C.DashFault (attempted ++ [("reason", str "unknown provider terminal")]))
    | otherwise -> do
        writeIORef ref w {dashboard = work.entries, log = w.log ++ [("dash", work.digest)]}
        pure (made @C.DashLanded attempted)

decoded :: forall a. (Contract a) => Json -> IO a
decoded raw = either (throwIO . ErrorCall . T.unpack) pure (decodeDataclass @a raw)

-- | The eight gate activities over one world, as gate definitions.
makeActivities :: IORef World -> Map Text GateDefinition
makeActivities ref =
  Map.fromList
    [ define "rerun_gate" (annotation @C.RerunReq) ["RerunLanded", "RerunMoved", "RerunFault"] rerunGate
    , define "review_agent" (annotation @C.RoundOpen) ["AgentReview", "RoundDeferred", "RoundMoved", "RoundUnable"] reviewAgent
    , define
        "publish_gate"
        (annotation @C.Publishable)
        ["ReviewLanded", "PublicationDeferred", "ReviewMoved", "ReviewBlocked", "ReviewFault"]
        publishGate
    , define "git_gate" (annotation @C.MutWork) ["Pushed", "MovedM", "FaultM", "DeclinedM"] gitGate
    , define "reply_gate" (annotation @C.ReplyReq) ["Replied", "ReplyBlocked", "ReplyFault"] replyGate
    , define "reminder_gate" (annotation @C.RemReq) ["RemLanded", "RemBlocked", "RemFault"] reminderGate
    , define "announce_gate" (annotation @C.AnnounceReq) ["ALanded", "ADeferred", "ABlocked", "AMoved", "AFault"] announceGate
    , define "dash_gate" (annotation @C.DashReq) ["DashLanded", "DashDeferred", "DashBlocked", "DashFault"] dashGate
    ]
  where
    define name request members gate =
      let declaration = either (error . T.unpack) id (activityDeclaration name Nothing)
          function args _ = do
            v <- gate ref (maybe Null id (lookup "work" args))
            either (throwIO . ErrorCall . T.unpack) pure (encodeVariant members v)
       in ( name
          , GateDefinition
              { activity = ActivityDefinition declaration variantPayloadConverter ["work"] function
              , parameters = [("work", request)]
              , result = members
              }
          )

-- | The gate definitions of a world, for 'wireGates'.
gateDefinitions :: IORef World -> Map Text GateDefinition
gateDefinitions = makeActivities

-- | @definition(invocation, context=None)@: run an activity directly.
callDefinition :: GateDefinition -> ActivityInvocation -> IO Json
callDefinition definition inv = do
  ctx <- dummyContext
  callActivity definition.activity inv ctx >>= either (throwIO . ErrorCall . T.unpack) pure

dummyContext :: IO ActivityExecutionContext
dummyContext =
  pure
    ActivityExecutionContext
      { attemptId = "test"
      , epoch = "1"
      , claimant = "test"
      , instance' = Nothing
      , latestDetails = pure Null
      , heartbeat = \_ -> pure Null
      }

-- ---------------------------------------------------------------------------
-- The host's grant fold

-- | The same deterministic rules as the lifecycle loop's admission folds,
-- applied to the world FIRST.
moveWorld :: Text -> Json -> World -> World
moveWorld door payload w = case door of
  "on_head" ->
    let h = text "head"
        b = text "base"
        p = text "policy"
        moved = w {branchHead = h, baseHead = b, policy = p}
     in case auth.phase of
          "terminal" -> moved
          "quiescent" -> moved {authority = Authority {incarnation = auth.incarnation, phase = auth.phase, head = h, base = b, policy = p}}
          _
            | h == auth.head -> moved {authority = Authority {incarnation = auth.incarnation, phase = auth.phase, head = auth.head, base = b, policy = p}}
            | otherwise ->
                moved {authority = Authority {incarnation = auth.incarnation + 1, phase = "running", head = h, base = b, policy = p}}
  "on_draft" -> w {prState = "draft", authority = if auth.phase == "running" then auth {phase = "quiescent"} else auth}
  "on_ready" ->
    w
      { prState = "ready"
      , authority = if auth.phase == "quiescent" then auth {phase = "running", incarnation = auth.incarnation + 1} else auth
      }
  "on_close" -> w {prState = "closed", authority = auth {phase = "terminal"}}
  "on_runs" ->
    let h = text "head"
        observed = (integer "run_id", integer "attempt")
     in w {runsByHead = Map.insertWith max h observed w.runsByHead}
  _ -> w
  where
    auth = w.authority
    text k = case lookupText k payload of
      Just (String s) -> s
      other -> error ("host fold: " <> show k <> " is " <> show other)
    integer k = case lookupText k payload of
      Just (Int i) -> i
      other -> error ("host fold: " <> show k <> " is " <> show other)

-- ---------------------------------------------------------------------------
-- Spawning

data H = H
  { engine :: Engine.Engine
  , world :: IORef World
  , held :: Maybe InMemory.InMemoryDispatch
  , definitions :: Map Text GateDefinition
  , built :: BuiltNet
  , counter :: IORef Int
  }

worldOf :: H -> IO World
worldOf h = readIORef h.world

modifyWorld :: H -> (World -> World) -> IO ()
modifyWorld h = modifyIORef' h.world

setWorld :: H -> World -> IO ()
setWorld h = writeIORef h.world

builtNet :: BuiltNet
builtNet = either (const (error "buildNetV5 failed")) id buildNetV5

handlersOf :: BuiltNet -> Map Text GateDefinition -> Map ImplementationRef BoundHandler
handlersOf built definitions = either (error . T.unpack) id (wireGates built gates definitions derived)

-- | Spawn with inline dispatch: every gate settles within the drive.
spawn :: IO H
spawn = spawnWith "pr-v5" freshWorld []

spawnWith :: Text -> World -> [(Text, Text, Json)] -> IO H
spawnWith instanceId world0 initialMail = do
  ref <- newIORef world0
  let definitions = makeActivities ref
  seeded <- either (throwIO . ErrorCall . T.unpack) pure (seedMarking ("test:" <> instanceId))
  let marking' = foldl (\m (place, color, payload) -> deposit (fromText place) (Token (Just color) payload) m) seeded initialMail
  store <- inMemoryHistoryStore
  port <- inlineDispatch <$> newInlineDispatch (Map.map (\d inv _ -> callDefinition d inv) definitions)
  engine <-
    Engine.create
      builtNet.net
      instanceId
      store
      port
      (engineOptions definitions marking') {Engine.policy = Engine.conservativePolicy}
  H engine ref Nothing definitions builtNet <$> newIORef 0

-- | Spawn with an explicit worker pool so a test can HOLD a gate's
-- terminal open; cohabited loops require the throughput policy.
spawnHeld :: IO H
spawnHeld = spawnHeldWith "pr-v5" freshWorld

spawnHeldWith :: Text -> World -> IO H
spawnHeldWith instanceId world0 = do
  ref <- newIORef world0
  let definitions = makeActivities ref
  seeded <- either (throwIO . ErrorCall . T.unpack) pure (seedMarking ("test:" <> instanceId))
  store <- inMemoryHistoryStore
  pool <- InMemory.newInMemoryDispatch
  engine <-
    Engine.create
      builtNet.net
      instanceId
      store
      (InMemory.inMemoryDispatch pool)
      (engineOptions definitions seeded) {Engine.policy = Engine.throughputPolicy}
  H engine ref (Just pool) definitions builtNet <$> newIORef 0

engineOptions :: Map Text GateDefinition -> Marking -> Engine.EngineOptions
engineOptions definitions marking' =
  Engine.defaultEngineOptions
    { Engine.marking = marking'
    , Engine.handlers = handlersOf builtNet definitions
    , Engine.guards = Map.fromList [(Exact uri, g) | (uri, g) <- Map.toList builtNet.guards]
    , Engine.celCompilers = celCompilers
    , Engine.activities = [d.activity.declaration | d <- Map.elems definitions]
    }

fromText :: Text -> NetPath
fromText = either (error . T.unpack) id . netPath

-- ---------------------------------------------------------------------------
-- Driving

drive :: H -> IO ()
drive h = go (200 :: Int)
  where
    go 0 = throwIO (ErrorCall "engine did not quiesce in 200 advances")
    go n = do
      outcome <- Engine.advance h.engine
      when outcome.ready (go (n - 1))

-- | Advance and work like a worker pool.
pump :: H -> IO ()
pump h = pumpHolding h []

-- | Advance and work like a worker pool, EXCEPT activities named in
-- @hold@, whose invocations stay pending (in flight).
pumpHolding :: H -> [Text] -> IO ()
pumpHolding h hold = go (400 :: Int)
  where
    pool = maybe (error "pump requires spawnHeld") id h.held
    go 0 = throwIO (ErrorCall "engine did not quiesce in 400 pumps")
    go n = do
      outcome <- Engine.advance h.engine
      work <- InMemory.pending pool
      acted <- fmap or $ mapM (\(occurrence, inv) ->
        if inv.activity `elem` hold
          then pure False
          else do
            value <- callDefinition (h.definitions Map.! inv.activity) inv
            InMemory.completeOccurrence pool occurrence value
            pure True) work
      when (outcome.ready || acted) (go (n - 1))

-- | Complete the single pending invocation of @activity@, then pump.
releaseOne :: H -> Text -> IO ()
releaseOne h activity = completeOne h activity >> pump h

-- | Complete the single pending invocation of @activity@ without pumping
-- (@dispatch.complete(occurrence, definition(invocation))@).
completeOne :: H -> Text -> IO ()
completeOne h activity = do
  let pool = maybe (error "completeOne requires spawnHeld") id h.held
  work <- InMemory.pending pool
  case [(o, i) | (o, i) <- work, i.activity == activity] of
    [(occurrence, inv)] -> do
      value <- callDefinition (h.definitions Map.! inv.activity) inv
      InMemory.completeOccurrence pool occurrence value
    other -> throwIO (ErrorCall ("expected exactly one pending " <> T.unpack activity <> ", got " <> show (length other)))

-- | The pending invocations of @activity@ in a held engine's pool.
pendingWork :: H -> Text -> IO [ActivityInvocation]
pendingWork h activity = do
  let pool = maybe (error "pendingWork requires spawnHeld") id h.held
  work <- InMemory.pending pool
  pure [i | (_, i) <- work, i.activity == activity]

-- | Every pending invocation in a held engine's pool, in occurrence order.
pendingAll :: H -> IO [ActivityInvocation]
pendingAll h = do
  let pool = maybe (error "pendingAll requires spawnHeld") id h.held
  map snd <$> InMemory.pending pool

admit :: H -> Text -> Text -> Json -> IO ()
admit h door color payload0 = do
  n <- atomicModifyIORef' h.counter (\c -> (c + 1, c + 1))
  let payload = case (color, payload0) of
        ("HeadSeen", Object members) ->
          Object
            ( [(k, maybe d id (lookup k members)) | (k, d) <- [("strict_base", Bool True), ("base_current", Bool True)]]
                ++ [m | m@(k, _) <- members, k `notElem` ["strict_base", "base_current"]]
            )
        _ -> payload0
  modifyIORef' h.world (moveWorld door payload)
  _ <- Engine.deliver h.engine (fromText door) [Token (Just color) payload] (door <> "-" <> T.pack (show n)) Nothing
  pure ()

deliver :: H -> Text -> Text -> Json -> IO ()
deliver h door color payload = admit h door color payload >> drive h

deliverHeld :: H -> [Text] -> Text -> Text -> Json -> IO ()
deliverHeld h hold door color payload = admit h door color payload >> pumpHolding h hold

-- ---------------------------------------------------------------------------
-- Observation

markingOf :: H -> IO Marking
markingOf h = Engine.marking h.engine

recordsOf :: H -> IO [Record]
recordsOf h = Engine.records h.engine

-- | The activities of every @ActivityRequested@ record, in order.
requested :: H -> IO [Text]
requested h = do
  rs <- recordsOf h
  pure [r.activity | RActivityRequested r <- rs]

tokens :: H -> Text -> IO [Json]
tokens h place = map (.payload) . toList . placeTokens (fromText place) <$> markingOf h

one :: H -> Text -> IO Json
one h place =
  tokens h place >>= \case
    [x] -> pure x
    other -> throwIO (ErrorCall ("expected one token at " <> T.unpack place <> ", got " <> show (length other)))

-- | @one(engine, place)[key]@.
oneAt :: H -> Text -> Text -> IO Json
oneAt h place key = (`at` key) <$> one h place

-- | The provider's comment keys, in posting order.
commentKeys :: H -> IO [Text]
commentKeys h = map (.key) . (.comments) <$> worldOf h

-- | The facts of one kind the dashboard projection holds.
factsOf :: H -> Text -> IO [Json]
factsOf h kind = map snd . filter ((== kind) . fst) <$> projection h

-- | Every fact the dashboard loop accumulated, parsed back into
-- @(kind, body)@.
projection :: H -> IO [(Text, Json)]
projection h = do
  live <- tokens h "dash.memory"
  memory <- one h (if null live then "dash.done" else "dash.memory")
  forM (case memory `at` "entries" of Array es -> es; _ -> []) $ \case
    String entry -> do
      let (kind, rest) = T.breakOn ":" entry
      case literalEval (T.drop 1 rest) of
        Right value | Just body <- toJson value -> pure (kind, body)
        _ -> throwIO (ErrorCall ("unparsable entry " <> T.unpack entry))
    other -> throwIO (ErrorCall ("entry is not text: " <> show other))

-- ---------------------------------------------------------------------------
-- Shorthand

data HeadArgs = HeadArgs
  { seenBase :: Text
  , seenMergeable :: Bool
  , seenPolicy :: Text
  , seenStrictBase :: Bool
  , seenBaseCurrent :: Bool
  }

headArgs :: HeadArgs
headArgs = HeadArgs {seenBase = "b1", seenMergeable = True, seenPolicy = "p1", seenStrictBase = True, seenBaseCurrent = True}

seeHead :: H -> Text -> IO ()
seeHead h headSha = seeHeadWith h headSha headArgs

seeHeadWith :: H -> Text -> HeadArgs -> IO ()
seeHeadWith h headSha a =
  deliver
    h
    "on_head"
    "HeadSeen"
    ( obj
        [ ("head", str headSha)
        , ("base", str a.seenBase)
        , ("mergeable", Bool a.seenMergeable)
        , ("policy", str a.seenPolicy)
        , ("strict_base", Bool a.seenStrictBase)
        , ("base_current", Bool a.seenBaseCurrent)
        ]
    )

data RunArgs = RunArgs
  { runHead :: Text
  , runId :: Integer
  , runAttempt :: Integer
  , runConclusion :: Text
  , runFingerprint :: Text
  }

runArgs :: RunArgs
runArgs = RunArgs {runHead = "h1", runId = 1, runAttempt = 1, runConclusion = "success", runFingerprint = ""}

seeRun :: H -> IO ()
seeRun h = seeRunWith h runArgs

seeRunWith :: H -> RunArgs -> IO ()
seeRunWith h a =
  deliver
    h
    "on_runs"
    "RunSeen"
    ( obj
        [ ("head", str a.runHead)
        , ("run_id", int a.runId)
        , ("attempt", int a.runAttempt)
        , ("conclusion", str a.runConclusion)
        , ("fingerprint", str a.runFingerprint)
        ]
    )

commentPayload :: Text -> Text -> Text -> Bool -> Json
commentPayload cid kind arg authorized =
  obj [("id", str cid), ("kind", str kind), ("arg", str arg), ("authorized", Bool authorized)]

-- | A human comment: the ONLY ingress for dismiss/recover/snooze and the
-- conversation-sourced committing intents.
comment :: H -> Text -> Text -> IO ()
comment h cid kind = commentWith h cid kind "" True

commentWith :: H -> Text -> Text -> Text -> Bool -> IO ()
commentWith h cid kind arg authorized = deliver h "on_comment" "CommentSeen" (commentPayload cid kind arg authorized)

commentHeld :: H -> [Text] -> Text -> Text -> IO ()
commentHeld h hold cid kind = commentHeldWith h hold cid kind "" True

commentHeldWith :: H -> [Text] -> Text -> Text -> Text -> Bool -> IO ()
commentHeldWith h hold cid kind arg authorized =
  deliverHeld h hold "on_comment" "CommentSeen" (commentPayload cid kind arg authorized)

-- | The conversation loop: the human talks to the PR in ANY phase
-- (@net_v5/conversation.py@).
--
-- Owns the ConvMemory baton and NEVER ends. Lifecycle admits every comment
-- as an IntentFact; @classify@ grades it (pure, note, committing) and
-- routes the side facts. Every classified intent is answered through the
-- reply gate under the stable effect identity @reply:{comment_id}@;
-- replies are deliberately CONCURRENT, with per-id custody as data.
module Hamsterdan.Readiness.NetV5.Conversation
  ( gates
  , declare
  , wire
  , seed
  , classify
  , foldReplied
  , foldBlocked
  , foldFault
  , recover
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

gates :: [(Text, (Text, [Text]))]
gates = [("conv.reply", ("reply_gate", ["Replied", "ReplyBlocked", "ReplyFault"]))]

data Grade = Pure | Note | Committing
  deriving stock (Eq)

grades :: [(Text, Grade)]
grades =
  [ ("reply", Pure)
  , ("status", Pure)
  , ("acknowledge", Note)
  , ("dismiss", Note)
  , ("defer", Note)
  , ("snooze", Note)
  , ("resume", Note)
  , ("reassign", Note)
  , ("recover_publication", Note)
  , ("change", Committing)
  , ("update_base", Committing)
  , ("resolve_conflict", Committing)
  ]

-- | recover_publication: the operation prefix names the owning loop's
-- recovery mailbox and the target the loop's own defense re-checks.
recoverRoutes :: [(Text, (Text, Text))]
recoverRoutes =
  [ ("rerun", ("esc.recover", "esc"))
  , ("findings", ("review.recover", "review"))
  , ("reply", ("conv.recover", "conversation"))
  , ("reminder", ("rem.recover", "reminder"))
  , ("dash", ("dash.recover", "dashboard"))
  , ("ready", ("ready.recover", "readiness"))
  , ("push", ("mut.recover", "mutation"))
  ]

noChangeText, pureFallbackText, terminalText, provisionalText, quiescentText, unknownRecoveryText :: Text
noChangeText = "I can't act on that — nothing in the workflow changed."
pureFallbackText = "Nothing new to report — the summary comment is current."
terminalText = "This PR is closed — nothing changes here anymore."
provisionalText = "My own update is still landing — ask again once it settles."
quiescentText = "This PR is a draft — I hold changes until it's ready for review."
unknownRecoveryText = "I don't recognize that operation, so I can't recover it."

notedText :: [(Text, Text)]
notedText =
  [ ("acknowledge", "Noted.")
  , ("dismiss", "Noted — that finding is dismissed.")
  , ("defer", "Noted — that finding is set aside.")
  , ("snooze", "Noted — reminders are snoozed.")
  , ("resume", "Noted — reminders are back on.")
  , ("reassign", "Noted.")
  , ("recover_publication", "On it — I'm retrying that publication now.")
  ]

startedText :: [(Text, Text)]
startedText =
  [ ("change", "On it — I'm making that change and will push to this PR.")
  , ("update_base", "On it — I'm updating this branch from its base.")
  , ("resolve_conflict", "On it — I'm resolving the conflict and will push the result.")
  ]

strDict :: [(Text, Text)] -> Json
strDict members = Object [(k, String v) | (k, v) <- members]

faultedDict :: [(Text, [(Text, Text)])] -> Json
faultedDict members = Object [(k, strDict v) | (k, v) <- members]

-- | The routed fact for a note intent, or nothing for pure notes.
noteRoutes :: IntentFact -> [Emit]
noteRoutes intent = case intent.kind of
  "dismiss" -> [emit "review.dismiss" [DismissFact {findingId = intent.arg}]]
  "snooze" -> [emit "rem.snoozes" [SnoozeFact {mode = ModeSnooze, arg = intent.arg}]]
  "resume" -> [emit "rem.snoozes" [SnoozeFact {mode = ModeClear, arg = intent.arg}]]
  "defer" -> [emit "review.dismiss" [DismissFact {findingId = intent.arg}]]
  _ -> []

classify :: Fold
classify b outs = do
  (intent, mem) <- values2 @IntentFact @ConvMemory b
  if intent.id `elem` mem.served
    then Right (route outs [emit "conv.memory" [mem]])
    else do
      served <- vupdate mem [("served", texts (mem.served ++ [intent.id]))]
      (text, routes) <- case lookup intent.kind grades of
        Just grade | intent.authorized -> case grade of
          Pure -> Right (if T.null intent.arg then pureFallbackText else intent.arg, [])
          Note
            | intent.phase == PhaseTerminal -> Right (terminalText, [])
            | otherwise -> do
                noted <- maybe (Left (keyError intent.kind)) Right (lookup intent.kind notedText)
                if intent.kind == "recover_publication"
                  then do
                    let prefix = fst (T.breakOn ":" intent.arg)
                    case lookup prefix recoverRoutes of
                      Nothing -> Right (unknownRecoveryText, [])
                      Just (targetPlace, targetName) ->
                        Right (noted, [emit targetPlace [RecoverFact {target = targetName, op = intent.arg}]])
                  else Right (noted, noteRoutes intent)
          Committing
            | intent.phase /= PhaseRunning ->
                Right (if intent.phase == PhaseTerminal then terminalText else quiescentText, [])
            | intent.provisional -> Right (provisionalText, [])
            | otherwise -> do
                started <- maybe (Left (keyError intent.kind)) Right (lookup intent.kind startedText)
                kind <- unspell @MutationKind intent.kind
                let req =
                      MutationRequest
                        { op = intent.kind
                        , rid = "comment:" <> intent.id
                        , head = intent.head
                        , base = intent.base
                        , policy = intent.policy
                        , incarnation = intent.incarnation
                        , source = "conversation"
                        , kind = kind
                        , instruction = intent.arg
                        , runId = 0
                        , attempt = 0
                        }
                Right (started, [emit "mut.requests" [req]])
        _ -> Right (noChangeText, [])
      memory <- vupdate served [("pending", strDict (pairInsert intent.id text served.pending))]
      Right
        ( route
            outs
            (routes ++ [emit "conv.memory" [memory], emit "conv.reply_req" [ReplyReq {id = intent.id, text = text}]])
        )

pairInsert :: Text -> a -> [(Text, a)] -> [(Text, a)]
pairInsert k v members
  | any ((== k) . fst) members = [(k', if k' == k then v else v') | (k', v') <- members]
  | otherwise = members ++ [(k, v)]

foldReplied :: Fold
foldReplied b outs = do
  (out, mem) <- values2 @Replied @ConvMemory b
  updated <-
    vupdate
      mem
      [ ("pending", strDict (without out.id mem.pending))
      , ("blocked", strDict (without out.id mem.blocked))
      , ("faulted", faultedDict (without out.id mem.faulted))
      ]
  let facts =
        [ GateFact
            { kind = "fault"
            , incarnation = 0
            , body = [("where", String "conversation"), ("op", String ("reply:" <> out.id)), ("status", String "resolved")]
            }
        | any ((== out.id) . fst) mem.faulted
        ]
  Right (route outs (emit "conv.memory" [updated] : [emit "dash.facts" facts | not (null facts)]))

foldBlocked :: Fold
foldBlocked b outs = do
  (out, mem) <- values2 @ReplyBlocked @ConvMemory b
  updated <-
    vupdate
      mem
      [ ("pending", strDict (without out.id mem.pending))
      , ("blocked", strDict (pairInsert out.id out.text mem.blocked))
      ]
  Right (route outs [emit "conv.memory" [updated]])

foldFault :: Fold
foldFault b outs = do
  (out, mem) <- values2 @ReplyFault @ConvMemory b
  updated <-
    vupdate
      mem
      [ ("pending", strDict (without out.id mem.pending))
      , ("faulted", faultedDict (pairInsert out.id [("text", out.text), ("reason", out.reason)] mem.faulted))
      ]
  let fact =
        GateFact
          { kind = "fault"
          , incarnation = 0
          , body =
              [ ("where", String "conversation")
              , ("op", String ("reply:" <> out.id))
              , ("status", String "faulted")
              , ("reason", String out.reason)
              ]
          }
  Right (route outs [emit "conv.memory" [updated], emit "dash.facts" [fact]])

recover :: Fold
recover b outs = do
  (fact, mem) <- values2 @RecoverFact @ConvMemory b
  let keep = Right (route outs [emit "conv.memory" [mem]])
  case T.stripPrefix "reply:" fact.op of
    Just replyId
      | fact.target == "conversation" ->
          if any ((== replyId) . fst) mem.pending
            then keep
            else do
              found <- case (lookup replyId mem.blocked, lookup replyId mem.faulted) of
                (Just text, _) -> Right (Just text)
                (Nothing, Just entry) -> maybe (Left (keyError "text")) (Right . Just) (lookup "text" entry)
                _ -> Right Nothing
              case found of
                Nothing -> keep
                Just text -> do
                  updated <-
                    vupdate
                      mem
                      [ ("pending", strDict (pairInsert replyId text mem.pending))
                      , ("blocked", strDict (without replyId mem.blocked))
                      ]
                  Right (route outs [emit "conv.memory" [updated], emit "conv.reply_req" [ReplyReq {id = replyId, text = text}]])
    _ -> keep

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  place "conv.intents" "IntentFact"
  place "conv.recover" "RecoverFact"
  place "conv.memory" "ConvMemory"
  place "conv.reply_req" "ReplyReq"
  place "conv.replied" "Replied"
  place "conv.rblocked" "ReplyBlocked"
  place "conv.rfault" "ReplyFault"

wire :: Author s ()
wire = do
  fold
    "conv.classify"
    "_classify"
    classify
    ["conv.intents", "conv.memory"]
    [ "conv.memory"
    , "conv.reply_req"
    , "conv.recover"
    , "mut.requests"
    , "mut.recover"
    , "review.recover"
    , "review.dismiss"
    , "rem.snoozes"
    , "rem.recover"
    , "dash.recover"
    , "ready.recover"
    , "esc.recover"
    ]
  gate "conv.reply" "reply_gate" ["conv.reply_req"] ["conv.replied", "conv.rblocked", "conv.rfault"]
  fold "conv.fold_replied" "_fold_replied" foldReplied ["conv.replied", "conv.memory"] ["conv.memory", "dash.facts"]
  fold "conv.fold_rblocked" "_fold_blocked" foldBlocked ["conv.rblocked", "conv.memory"] ["conv.memory"]
  fold "conv.fold_rfault" "_fold_fault" foldFault ["conv.rfault", "conv.memory"] ["conv.memory", "dash.facts"]
  fold "conv.recovery" "_recover" recover ["conv.recover", "conv.memory"] ["conv.memory", "conv.reply_req"]

seed :: [(NetPath, [Token])]
seed = [("conv.memory", [seedToken ConvMemory {served = [], pending = [], blocked = [], faulted = []}])]

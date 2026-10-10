-- | The dashboard loop: a mutable singleton projection of the PR's state
-- (@net_v5/dashboard.py@).
--
-- Owns the DashMemory baton. Every sibling loop mails GateFacts here; the
-- fold accumulates them into the projection log and republishes the board
-- on digest drift ONLY. Successful publication releases workflow startup.
-- Custody is a held baton; blocked and faulted upserts retain the EXACT
-- attempted request while memory keeps tracking the desired state.
module Hamsterdan.Readiness.NetV5.Dashboard
  ( gates
  , declare
  , wire
  , seed
  , factDigest
  , factEntry
  , foldFact
  , foldLanded
  , foldDeferred
  , selfheal
  , foldBlocked
  , foldFault
  , recover
  , end
  , drainFact
  , drainRecover
  , drainHeal
  ) where

import Data.Text (Text)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.PyLiteral (dictEntry, sortedItemsDigest)
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

gates :: [(Text, (Text, [Text]))]
gates = [("dash.publish", ("dash_gate", ["DashLanded", "DashDeferred", "DashBlocked", "DashFault"]))]

-- | The fact's projection identity: kind + canonicalized body.
factDigest :: GateFact -> Text
factDigest fact = sortedItemsDigest fact.kind fact.body

-- | The fact's entry in the projection log: @f"{kind}:{body}"@.
factEntry :: GateFact -> Text
factEntry fact = dictEntry fact.kind fact.body

-- | A live publish IS the desired state.
liveReq :: [Text] -> Text -> DashMemory -> DashReq
liveReq entries digest mem =
  DashReq
    { entries = entries
    , digest = digest
    , desiredEntries = entries
    , desiredDigest = digest
    , landed = mem.landed
    , blocked = mem.blocked
    , faulted = mem.faulted
    }

foldFact :: Fold
foldFact b outs = do
  (fact, mem) <- values2 @GateFact @DashMemory b
  let digest = factDigest fact
  if digest == mem.digest
    then Right (route outs [emit "dash.memory" [mem]])
    else do
      let entries = mem.entries ++ [factEntry fact]
      if not (null mem.blocked) || not (null mem.faulted)
        then do
          updated <- vupdate mem [("entries", texts entries), ("digest", String digest)]
          Right (route outs [emit "dash.memory" [updated]])
        else Right (route outs [emit "dash.pub_req" [liveReq entries digest mem]])

foldLanded :: Fold
foldLanded b outs = do
  out <- values1 @DashLanded b
  let mem = DashMemory {entries = out.desiredEntries, digest = out.desiredDigest, landed = out.digest, blocked = [], faulted = []}
      heal = DashHeal {entries = out.desiredEntries, digest = out.desiredDigest}
  Right
    ( route
        outs
        ( [emit "dash.memory" [mem], emit "startup.published" [SummaryPublished {digest = out.digest}]]
            ++ [emit "dash.heal" [heal] | out.desiredDigest /= out.digest || out.desiredEntries /= out.entries]
        )
    )

foldDeferred :: Fold
foldDeferred b outs = do
  out <- values1 @DashDeferred b
  let mem = DashMemory {entries = out.desiredEntries, digest = out.desiredDigest, landed = out.landed, blocked = out.blocked, faulted = out.faulted}
  Right (route outs [emit "dash.memory" [mem]])

selfheal :: Fold
selfheal b outs = do
  (heal, mem) <- values2 @DashHeal @DashMemory b
  if not (null mem.blocked) || not (null mem.faulted) || (mem.entries, mem.digest) /= (heal.entries, heal.digest)
    then Right (route outs [emit "dash.memory" [mem]])
    else Right (route outs [emit "dash.pub_req" [liveReq mem.entries mem.digest mem]])

foldBlocked :: Fold
foldBlocked b outs = do
  out <- values1 @DashBlocked b
  let mem =
        DashMemory
          { entries = out.desiredEntries
          , digest = out.desiredDigest
          , landed = ""
          , blocked = [("entries", texts out.entries), ("digest", String out.digest)]
          , faulted = []
          }
  Right (route outs [emit "dash.memory" [mem]])

foldFault :: Fold
foldFault b outs = do
  out <- values1 @DashFault b
  let mem =
        DashMemory
          { entries = out.desiredEntries
          , digest = out.desiredDigest
          , landed = ""
          , blocked = []
          , faulted = [("entries", texts out.entries), ("digest", String out.digest), ("reason", String out.reason)]
          }
  Right (route outs [emit "dash.memory" [mem]])

recover :: Fold
recover b outs = do
  (fact, mem) <- values2 @RecoverFact @DashMemory b
  let held = if null mem.blocked then mem.faulted else mem.blocked
      keep = Right (route outs [emit "dash.memory" [mem]])
  if fact.target /= "dashboard" || null held
    then keep
    else do
      digest <- getItem (Object held) "digest"
      if fact.op /= "dash:" <> pyStr digest
        then keep
        else do
          entries <- getItem (Object held) "entries" >>= pyList
          digest' <- getItem (Object held) "digest"
          req <-
            construct @DashReq
              [ ("entries", Array entries)
              , ("digest", digest')
              , ("desired_entries", texts mem.entries)
              , ("desired_digest", String mem.digest)
              , ("landed", String mem.landed)
              , ("blocked", Object mem.blocked)
              , ("faulted", Object mem.faulted)
              ]
          Right (route outs [emit "dash.pub_req" [req]])

end :: Fold
end b outs = do
  (close, mem) <- values2 @CloseFact @DashMemory b
  Right (route outs [emit "dash.done" [DashEnded {entries = mem.entries, reason = close.reason}]])

drainFact :: Fold
drainFact b outs = do
  (fact, ended) <- values2 @GateFact @DashEnded b
  updated <- vupdate ended [("entries", texts (ended.entries ++ [factEntry fact]))]
  Right (route outs [emit "dash.done" [updated]])

drainRecover :: Fold
drainRecover b outs = do
  (_, ended) <- values2 @RecoverFact @DashEnded b
  Right (route outs [emit "dash.done" [ended]])

drainHeal :: Fold
drainHeal b outs = do
  (_, ended) <- values2 @DashHeal @DashEnded b
  Right (route outs [emit "dash.done" [ended]])

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  place "dash.facts" "GateFact"
  place "dash.closed" "CloseFact"
  place "dash.recover" "RecoverFact"
  place "dash.memory" "DashMemory"
  place "dash.pub_req" "DashReq"
  place "dash.landed" "DashLanded"
  place "dash.deferred" "DashDeferred"
  place "dash.dblocked" "DashBlocked"
  place "dash.dfault" "DashFault"
  place "dash.heal" "DashHeal"
  place "dash.done" "DashEnded"

wire :: Author s ()
wire = do
  fold "dash.fold" "_fold" foldFact ["dash.facts", "dash.memory"] ["dash.memory", "dash.pub_req"]
  gate "dash.publish" "dash_gate" ["dash.pub_req"] ["dash.landed", "dash.deferred", "dash.dblocked", "dash.dfault"]
  fold "dash.fold_landed" "_fold_landed" foldLanded ["dash.landed"] ["dash.memory", "dash.heal", "startup.published"]
  fold "dash.selfheal" "_selfheal" selfheal ["dash.heal", "dash.memory"] ["dash.memory", "dash.pub_req"]
  fold "dash.fold_deferred" "_fold_deferred" foldDeferred ["dash.deferred"] ["dash.memory"]
  fold "dash.fold_blocked" "_fold_blocked" foldBlocked ["dash.dblocked"] ["dash.memory"]
  fold "dash.fold_fault" "_fold_fault" foldFault ["dash.dfault"] ["dash.memory"]
  fold "dash.recovery" "_recover" recover ["dash.recover", "dash.memory"] ["dash.memory", "dash.pub_req"]
  fold "dash.end" "_end" end ["dash.closed", "dash.memory"] ["dash.done"]
  fold "dash.drain_fact" "_drain_fact" drainFact ["dash.facts", "dash.done"] ["dash.done"]
  fold "dash.drain_recover" "_drain_recover" drainRecover ["dash.recover", "dash.done"] ["dash.done"]
  fold "dash.drain_heal" "_drain_heal" drainHeal ["dash.heal", "dash.done"] ["dash.done"]

seed :: [(NetPath, [Token])]
seed = [("dash.memory", [seedToken DashMemory {entries = [], digest = "", landed = "", blocked = [], faulted = []}])]

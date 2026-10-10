-- | The lifecycle loop: the single admission hub of the V5 topology
-- (@net_v5/life.py@).
--
-- Owns the LifeState baton and every ingress mailbox. Absorbs
-- host-normalized observations through doors and mails typed facts to
-- sibling loop mailboxes. All decisions are pure folds; dormancy,
-- supersession, confirmation, and close fan-out live here and nowhere
-- else.
module Hamsterdan.Readiness.NetV5.Life
  ( declare
  , wire
  , seed
  , admitHead
  , admitDraft
  , admitReady
  , admitClose
  , admitComment
  , admitHuman
  , admitRuns
  , noteProvisional
  ) where

import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

-- -- folds ---------------------------------------------------------------

stateFact :: LifeState -> StateFact
stateFact st =
  StateFact
    { incarnation = st.incarnation
    , body =
        StateFactBody
          { phase = st.phase
          , head = st.head
          , base = st.base
          , mergeable = st.mergeable
          , policy = st.policy
          , strictBase = st.strictBase
          , baseCurrent = st.baseCurrent
          }
    }

admittedStateOutputs :: LifeState -> HeadWork -> [Emit]
admittedStateOutputs st work =
  [ emit "life.state" [st]
  , emit "review.heads" [work]
  , emit "ci.heads" [work]
  , emit "ready.state_facts" [fact]
  , emit "dash.facts" [fact]
  ]
    ++ [ emit "rem.cycles" [ReminderCycleStarted {incarnation = st.incarnation, head = st.head, delayS = st.reminderDelayS}]
       | work.relation /= RelationRefreshed
       ]
  where
    fact = stateFact st

keep :: LifeState -> [Emit]
keep st = [emit "life.state" [st]]

admitHead :: Fold
admitHead b outs = do
  (seen, st) <- values2 @HeadSeen @LifeState b
  case st.phase of
    PhaseTerminal -> Right (route outs (keep st))
    PhaseQuiescent -> do
      -- dormancy absorbs every head observation with no work emission;
      -- resume re-admits under a fresh incarnation
      recorded <-
        vupdate
          st
          [ ("head", String seen.head)
          , ("base", String seen.base)
          , ("mergeable", Bool seen.mergeable)
          , ("policy", String seen.policy)
          , ("strict_base", Bool seen.strictBase)
          , ("base_current", Bool seen.baseCurrent)
          ]
      Right (route outs (keep recorded))
    PhaseRunning
      | seen.head == st.head -> do
          let refreshed =
                seen.base /= st.base
                  || seen.mergeable /= st.mergeable
                  || seen.policy /= st.policy
                  || seen.strictBase /= st.strictBase
                  || seen.baseCurrent /= st.baseCurrent
          if not refreshed
            then Right (route outs (keep st))
            else do
              -- base/policy refresh: same lifetime, no incarnation bump
              current <-
                vupdate
                  st
                  [ ("base", String seen.base)
                  , ("mergeable", Bool seen.mergeable)
                  , ("policy", String seen.policy)
                  , ("strict_base", Bool seen.strictBase)
                  , ("base_current", Bool seen.baseCurrent)
                  ]
              let work =
                    HeadWork
                      { incarnation = current.incarnation
                      , head = current.head
                      , base = current.base
                      , policy = current.policy
                      , relation = RelationRefreshed
                      , lineage = current.lineage
                      }
              Right (route outs (admittedStateOutputs current work))
      | otherwise -> do
          let confirmed = st.expected /= "" && st.expected == seen.head
              relation
                | confirmed = RelationConfirmed
                | st.head == "" = RelationNew
                | otherwise = RelationSuperseded
              lineage = if confirmed then st.lineage else ""
              admitted =
                LifeState
                  { phase = PhaseRunning
                  , incarnation = st.incarnation + 1
                  , head = seen.head
                  , base = seen.base
                  , mergeable = seen.mergeable
                  , policy = seen.policy
                  , expected = ""
                  , expectedOp = ""
                  , lineage = lineage
                  , reminderDelayS = st.reminderDelayS
                  , strictBase = seen.strictBase
                  , baseCurrent = seen.baseCurrent
                  }
              work =
                HeadWork
                  { incarnation = admitted.incarnation
                  , head = seen.head
                  , base = seen.base
                  , policy = seen.policy
                  , relation = relation
                  , lineage = lineage
                  }
          Right (route outs (admittedStateOutputs admitted work))

admitDraft :: Fold
admitDraft b outs = do
  (_, st) <- values2 @DraftSeen @LifeState b
  if st.phase /= PhaseRunning
    then Right (route outs (keep st))
    else do
      quiescent <- vupdate st [("phase", String "quiescent")]
      let fact = stateFact quiescent
      Right $
        route
          outs
          [ emit "life.state" [quiescent]
          , emit "ready.state_facts" [fact]
          , emit "dash.facts" [fact]
          , emit "rem.pauses" [ReminderCyclePaused {incarnation = quiescent.incarnation, head = quiescent.head, reason = "draft"}]
          ]

admitReady :: Fold
admitReady b outs = do
  (_, st) <- values2 @ReadySeen @LifeState b
  if st.phase /= PhaseQuiescent
    then Right (route outs (keep st))
    else do
      -- resume clears any provisional expectation and lineage
      resumed <-
        vupdate
          st
          [ ("phase", String "running")
          , ("incarnation", Int (st.incarnation + 1))
          , ("expected", String "")
          , ("expected_op", String "")
          , ("lineage", String "")
          ]
      let work =
            HeadWork
              { incarnation = resumed.incarnation
              , head = resumed.head
              , base = resumed.base
              , policy = resumed.policy
              , relation = RelationResumed
              , lineage = ""
              }
      Right (route outs (admittedStateOutputs resumed work))

admitClose :: Fold
admitClose b outs = do
  (seen, st) <- values2 @CloseSeen @LifeState b
  if st.phase == PhaseTerminal
    then Right (route outs (keep st))
    else do
      terminal <- vupdate st [("phase", String "terminal")]
      let close = CloseFact {reason = seen.reason}
      Right $
        route
          outs
          ( emit "life.state" [terminal]
              : [ emit target [close]
                | target <- ["review.closed", "ci.closed", "esc.closed", "mut.closed", "dash.closed", "rem.closed", "ready.closed"]
                ]
          )

admitComment :: Fold
admitComment b outs = do
  (seen, st) <- values2 @CommentSeen @LifeState b
  let intent =
        IntentFact
          { id = seen.id
          , kind = seen.kind
          , arg = seen.arg
          , authorized = seen.authorized
          , phase = st.phase
          , provisional = st.expected /= ""
          , incarnation = st.incarnation
          , head = st.head
          , base = st.base
          , policy = st.policy
          }
  Right (route outs [emit "life.state" [st], emit "conv.intents" [intent]])

admitHuman :: Fold
admitHuman b outs = do
  (seen, st) <- values2 @HumanSeen @LifeState b
  if st.phase == PhaseTerminal
    then Right (route outs (keep st))
    else do
      let fact =
            HumanFact
              { incarnation = st.incarnation
              , body =
                  HumanFactBody
                    { approval = seen.approval
                    , changesRequested = seen.changesRequested
                    , unresolved = seen.unresolved
                    }
              }
      Right (route outs [emit "life.state" [st], emit "ready.human_facts" [fact], emit "dash.facts" [fact]])

admitRuns :: Fold
admitRuns b outs = do
  (seen, st) <- values2 @RunSeen @LifeState b
  if st.phase /= PhaseRunning
    then Right (route outs (keep st))
    else do
      let work =
            RunWork
              { incarnation = st.incarnation
              , head = seen.head
              , runId = seen.runId
              , attempt = seen.attempt
              , conclusion = seen.conclusion
              , fingerprint = seen.fingerprint
              }
      Right (route outs [emit "life.state" [st], emit "ci.runs" [work]])

noteProvisional :: Fold
noteProvisional b outs = do
  (note, st) <- values2 @ProvisionalHead @LifeState b
  -- the from_head fence: the note only installs while lifecycle still
  -- stands on the head the push moved FROM
  if st.phase /= PhaseRunning || st.head /= note.fromHead
    then Right (route outs (keep st))
    else do
      noted <- vupdate st [("expected", String note.expected), ("expected_op", String note.op), ("lineage", String note.lineage)]
      Right (route outs (keep noted))

-- -- topology ------------------------------------------------------------

-- | Declare the places this loop owns.
declare :: Author s ()
declare = do
  place "life.heads" "HeadSeen"
  place "life.drafts" "DraftSeen"
  place "life.readies" "ReadySeen"
  place "life.closes" "CloseSeen"
  place "life.comments" "CommentSeen"
  place "life.humans" "HumanSeen"
  place "life.runs" "RunSeen"
  place "life.provisional" "ProvisionalHead"
  place "life.state" "LifeState"

-- | Wire this loop's doors and transitions (sibling places must exist).
wire :: Author s ()
wire = do
  -- ingress doors: the host delivers normalized observations
  door "on_head" "life.heads"
  door "on_draft" "life.drafts"
  door "on_ready" "life.readies"
  door "on_close" "life.closes"
  door "on_comment" "life.comments"
  door "on_human" "life.humans"
  door "on_runs" "life.runs"
  -- admission folds (each: one mailbox + the state baton)
  fold "life.admit_head" "_admit_head" admitHead ["life.heads", "life.state"] admittedTargets
  fold "life.admit_draft" "_admit_draft" admitDraft ["life.drafts", "life.state"] ["life.state", "ready.state_facts", "dash.facts", "rem.pauses"]
  fold "life.admit_ready" "_admit_ready" admitReady ["life.readies", "life.state"] admittedTargets
  fold
    "life.admit_close"
    "_admit_close"
    admitClose
    ["life.closes", "life.state"]
    ["life.state", "review.closed", "ci.closed", "esc.closed", "mut.closed", "dash.closed", "rem.closed", "ready.closed"]
  fold "life.admit_comment" "_admit_comment" admitComment ["life.comments", "life.state"] ["life.state", "conv.intents"]
  fold "life.admit_human" "_admit_human" admitHuman ["life.humans", "life.state"] ["life.state", "ready.human_facts", "dash.facts"]
  fold "life.admit_runs" "_admit_runs" admitRuns ["life.runs", "life.state"] ["life.state", "ci.runs"]
  fold "life.note_provisional" "_note_provisional" noteProvisional ["life.provisional", "life.state"] ["life.state"]
  where
    admittedTargets = ["life.state", "review.heads", "ci.heads", "ready.state_facts", "dash.facts", "rem.cycles"]

-- | This loop's contribution to the newborn Instance marking.
seed :: Integer -> [(NetPath, [Token])]
seed reminderDelayS =
  [ ( "life.state"
    , [ seedToken
          LifeState
            { phase = PhaseRunning
            , incarnation = 0
            , head = ""
            , base = ""
            , mergeable = False
            , policy = ""
            , expected = ""
            , expectedOp = ""
            , lineage = ""
            , reminderDelayS = reminderDelayS
            , strictBase = True
            , baseCurrent = False
            }
      ]
    )
  ]

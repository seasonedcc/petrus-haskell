-- | The CI loop: pure observation of check-run evidence
-- (@net_v5/ci.py@).
--
-- Owns the CiState baton. Adopts each admitted head with a budget
-- lineage, keeps only the newest exact-head run verdict, mails
-- ChecksFailure facts to the escalation loop, and answers escalation
-- MOVED echoes with the park-or-reissue rule.
module Hamsterdan.Readiness.NetV5.Ci
  ( declare
  , wire
  , seed
  , admitHead
  , assess
  , recheck
  , end
  , drainEcho
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Instance.FailureText (PythonArg (..))
import Petrus.Impetus.Petrinet (NetPath, Token)

checksFact :: Integer -> Text -> Py ChecksFact
checksFact incarnation status = do
  s <- unspell @ChecksStatus status
  Right ChecksFact {incarnation = incarnation, body = ChecksFactBody {status = s}}

-- | The escalation mail always carries ONE state's complete authority
-- plus the run EVIDENCE identity.
failureMail :: CiState -> Text -> Integer -> Integer -> ChecksFailure
failureMail st fingerprint runId attempt =
  ChecksFailure
    { fingerprint = fingerprint
    , head = st.head
    , base = st.base
    , policy = st.policy
    , lineage = st.lineage
    , incarnation = st.incarnation
    , runId = runId
    , attempt = attempt
    }

-- | @state.best[0], state.best[1]@.
bestPair :: CiState -> Py (Integer, Integer)
bestPair st = maybe (Left (pyError "IndexError" [PyStr "tuple index out of range"])) Right st.best

admitHead :: Fold
admitHead b outs = do
  (work, st) <- values2 @HeadWork @CiState b
  if work.relation == RelationRefreshed
    then do
      let authorityChanged = (work.base, work.policy) /= (st.base, st.policy)
          adopted = st {base = work.base, policy = work.policy, parked = if authorityChanged then [] else st.parked} :: CiState
      reissue <-
        if authorityChanged && st.status == "failure" && st.fingerprint `elem` st.parked
          then do
            (r, a) <- bestPair st
            Right [emit "esc.failures" [failureMail adopted st.fingerprint r a]]
          else Right []
      Right (route outs (emit "ci.state" [adopted] : reissue))
    else do
      -- budget lineage: new code (new/superseded) gets a fresh ladder
      -- budget; our own confirmed repair and a resume keep the lineage
      let fresh = work.relation `elem` [RelationNew, RelationSuperseded] || st.lineage == ""
          admitted =
            CiState
              { head = work.head
              , base = work.base
              , policy = work.policy
              , lineage = if fresh then "L" <> T.pack (show work.incarnation) else st.lineage
              , incarnation = work.incarnation
              , best = Nothing
              , status = "pending"
              , fingerprint = ""
              , parked = []
              }
      fact <- checksFact work.incarnation "pending"
      Right (route outs [emit "ci.state" [admitted], emit "ready.checks_facts" [fact], emit "dash.facts" [fact]])

-- | @_RANK@: queued → in_progress → success|failure, strictly forward.
rank :: Text -> Py Int
rank = \case
  "queued" -> Right 0
  "in_progress" -> Right 1
  "success" -> Right 2
  "failure" -> Right 2
  other -> Left (keyError other)

assess :: Fold
assess b outs = do
  (run, st) <- values2 @RunWork @CiState b
  let conclusion = spell run.conclusion
      inert = Right (route outs [emit "ci.state" [st]])
      proceed = do
        let updated = st {best = Just (run.runId, run.attempt), status = conclusion, fingerprint = run.fingerprint, parked = []} :: CiState
        fact <- checksFact st.incarnation conclusion
        Right $
          route
            outs
            ( [emit "ci.state" [updated], emit "ready.checks_facts" [fact], emit "dash.facts" [fact]]
                ++ [emit "esc.failures" [failureMail st run.fingerprint run.runId run.attempt] | run.conclusion == RunFailure]
            )
  if run.head /= st.head
    then inert
    else case st.best of
      Nothing -> proceed
      Just best -> do
        let identity = (run.runId, run.attempt)
        if identity < best
          then inert
          else
            if identity == best
              then do
                new <- rank conclusion
                old <- rank st.status
                if new <= old then inert else proceed
              else proceed

recheck :: Fold
recheck b outs = do
  (echo, st) <- values2 @EscMoved @CiState b
  if st.status /= "failure" || st.fingerprint /= echo.fp
    then Right (route outs [emit "ci.state" [st]])
    else do
      let attempted = (echo.head, echo.base, echo.policy, echo.incarnation)
      if attempted == (st.head, st.base, st.policy, st.incarnation)
        then do
          let parked = if echo.fp `elem` st.parked then st.parked else st.parked ++ [echo.fp]
          Right (route outs [emit "ci.state" [st {parked = parked} :: CiState]])
        else do
          (r, a) <- bestPair st
          Right (route outs [emit "ci.state" [st], emit "esc.failures" [failureMail st echo.fp r a]])

end :: Fold
end b outs = do
  (close, st) <- values2 @CloseFact @CiState b
  Right (route outs [emit "ci.done" [CiEnded {status = st.status, reason = close.reason}]])

drainEcho :: Fold
drainEcho b outs = do
  (_, ended) <- values2 @EscMoved @CiEnded b
  Right (route outs [emit "ci.done" [ended]])

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  place "ci.heads" "HeadWork"
  place "ci.runs" "RunWork"
  place "ci.echo" "EscMoved"
  place "ci.closed" "CloseFact"
  place "ci.state" "CiState"
  place "ci.done" "CiEnded"

wire :: Author s ()
wire = do
  fold "ci.admit_head" "_admit_head" admitHead ["ci.heads", "ci.state"] ["ci.state", "ready.checks_facts", "esc.failures", "dash.facts"]
  fold "ci.assess" "_assess" assess ["ci.runs", "ci.state"] ["ci.state", "ready.checks_facts", "esc.failures", "dash.facts"]
  fold "ci.recheck" "_recheck" recheck ["ci.echo", "ci.state"] ["ci.state", "esc.failures"]
  fold "ci.end" "_end" end ["ci.closed", "ci.state"] ["ci.done"]
  -- post-close drain: a late escalation echo is absorbed, never stranded
  fold "ci.drain_echo" "_drain_echo" drainEcho ["ci.echo", "ci.done"] ["ci.done"]

seed :: [(NetPath, [Token])]
seed =
  [ ( "ci.state"
    , [ seedToken
          CiState
            { head = ""
            , base = ""
            , policy = ""
            , lineage = ""
            , incarnation = 0
            , best = Nothing
            , status = "pending"
            , fingerprint = ""
            , parked = []
            }
      ]
    )
  ]

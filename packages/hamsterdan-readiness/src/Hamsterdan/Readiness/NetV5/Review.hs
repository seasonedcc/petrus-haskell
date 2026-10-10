-- | The V5 review actor loop: one durable review memory per PR
-- (@net_v5/review.py@).
--
-- Owns the ReviewMemory baton. Each admitted head opens ONE agent round;
-- the judge replaces retained findings and lineage with the validated
-- agent result, then filters dismissals; the publish gate posts under one
-- stable effect identity @findings:{head}:i{inc}@. A moved publication
-- retains its findings provisionally. The baton is HELD through every
-- in-flight round.
module Hamsterdan.Readiness.NetV5.Review
  ( gates
  , declare
  , wire
  , seed
  , liveFindings
  , markerOperation
  , start
  , judge
  , unable
  , roundMoved
  , wakeDeferred
  , wakePublication
  , foldLanded
  , foldMoved
  , foldBlocked
  , foldFault
  , foldEmpty
  , recover
  , dismiss
  , end
  , endDeferred
  , endPublicationDeferred
  , drainDismiss
  , drainRecover
  , drainWake
  ) where

import Control.Monad (filterM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Char (isAscii, isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Contracts.Codec (Object, dump)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

gates :: [(Text, (Text, [Text]))]
gates =
  [ ("review.agent", ("review_agent", ["AgentReview", "RoundDeferred", "RoundMoved", "RoundUnable"]))
  , ("review.publish", ("publish_gate", ["ReviewLanded", "PublicationDeferred", "ReviewMoved", "ReviewBlocked", "ReviewFault"]))
  ]

-- | @[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z@, matched whole.
markerOperation :: Text -> Bool
markerOperation op = case T.uncons op of
  Just (c, rest) -> asciiAlnum c && T.length rest <= 127 && T.all (\x -> asciiAlnum x || x `elem` ("._:-" :: String)) rest
  Nothing -> False
  where
    asciiAlnum x = isAscii x && isAlphaNum x

-- -- folds ---------------------------------------------------------------

-- | @[f for f in findings if f["id"] not in dismissed]@.
live :: [Object] -> [Text] -> Py [Object]
live findings dismissed = filterM (\f -> (`notElem` map String dismissed) <$> getItem (Object f) "id") findings

-- | The open finding set the human currently sees, read from a
-- review-memory token's data: the last successful round's findings minus
-- every dismissal.
liveFindings :: Json -> Py [Json]
liveFindings memory = do
  findings <- getOr memory "findings" (Array []) >>= pyList
  dismissed <- getOr memory "dismissed" (Array []) >>= pyList
  mapM_ hashableElement dismissed
  kept <-
    filterM
      ( \f -> do
          ident <- getItem f "id"
          hashableElement ident
          Right (ident `notElem` dismissed)
      )
      findings
  mapM (fmap Object . asObject) kept
  where
    hashableElement = \case
      Array _ -> Left (typeError "cannot use 'list' as a set element (unhashable type: 'list')")
      Object _ -> Left (typeError "cannot use 'dict' as a set element (unhashable type: 'dict')")
      _ -> Right ()

status :: [Object] -> [Text] -> Py ReviewStatus
status findings dismissed = do
  open <- live findings dismissed
  blocking <- anyM (\f -> truthy <$> getItem (Object f) "blocking") open
  Right (if blocking then ReviewBlocking else ReviewClear)

anyM :: (a -> Py Bool) -> [a] -> Py Bool
anyM predicate = \case
  [] -> Right False
  x : rest -> do
    hit <- predicate x
    if hit then Right True else anyM predicate rest

reviewFact :: Text -> Integer -> ReviewStatus -> ReviewFact
reviewFact h incarnation s = ReviewFact {incarnation = incarnation, body = BodyReviewStatus ReviewStatusFactBody {head = h, status = s}}

operationOf :: Text -> Text -> Integer -> Py Text
operationOf subject h incarnation
  | BS.length (TE.encodeUtf8 operation) > 1024 = Left (valueError "V5 review operation exceeds the Agenticus identity bound")
  | otherwise = Right operation
  where
    operation = "review:" <> subject <> ":" <> h <> ":i" <> showT incarnation

showT :: Integer -> Text
showT = T.pack . show

objects :: [Object] -> Json
objects = Array . map Object

-- | One publication request with a durable Pending record in its mem (A2).
publishable :: Text -> Text -> Text -> Integer -> [Object] -> ReviewMemory -> Py Publishable
publishable h base policy incarnation findings mem = do
  let plain = "findings:" <> h <> ":i" <> showT incarnation
      op
        | markerOperation plain = plain
        | otherwise =
            let digest = TE.decodeUtf8 (Base16.encode (SHA256.hash (TE.encodeUtf8 (h <> "\0" <> showT incarnation))))
             in "findings:sha256:" <> digest <> ":i" <> showT incarnation
      pending =
        Object
          [ ("phase", String "pending")
          , ("effect", String op)
          , ("op", String op)
          , ("head", String h)
          , ("base", String base)
          , ("policy", String policy)
          , ("incarnation", Int incarnation)
          , ("findings", objects findings)
          ]
  held <- vupdate mem [("provisional", Array []), ("pub", pending)]
  Right
    Publishable
      { head = h
      , base = base
      , policy = policy
      , incarnation = incarnation
      , findings = findings
      , effect = op
      , op = op
      , mem = objectOf (dump held)
      }

objectOf :: Json -> Object
objectOf = \case
  Object members -> members
  _ -> []

start :: Fold
start b outs = do
  (work, mem) <- values2 @HeadWork @ReviewMemory b
  if work.relation == RelationRefreshed
    then do
      open <- live mem.provisional mem.dismissed
      if null open
        then Right (route outs [emit "review.memory" [mem]])
        else do
          pub <- publishable work.head work.base work.policy work.incarnation open mem
          Right (route outs [emit "review.publishable" [pub]])
    else do
      let prior = if null mem.provisional then mem.findings else mem.provisional
      openedMem <- vupdate mem [("head", String work.head), ("incarnation", Int work.incarnation), ("status", String "pending")]
      operation <- operationOf mem.subject work.head work.incarnation
      let opened =
            RoundOpen
              { operation = operation
              , head = work.head
              , base = work.base
              , policy = work.policy
              , incarnation = work.incarnation
              , priorFindings = prior
              , priorLineage = mem.lineage
              , mem = objectOf (dump openedMem)
              , attempt = 1
              }
      Right (route outs [emit "review.round" [opened]])

recordReviewed :: Text -> ReviewMemory -> Py ReviewMemory
recordReviewed h mem
  | h `elem` mem.reviewed = Right mem
  | otherwise = vupdate mem [("reviewed", texts (mem.reviewed ++ [h]))]

judge :: Fold
judge b outs = do
  out <- values1 @AgentReview b
  mem0 <- revive @ReviewMemory (Object out.mem)
  mem1 <- recordReviewed out.head mem0
  s <- status out.findings mem1.dismissed
  mem <- vupdate mem1 [("findings", objects out.findings), ("lineage", objects out.lineage), ("status", String (spell s))]
  open <- live out.findings mem.dismissed
  pub <- publishable out.head out.base out.policy out.incarnation open mem
  Right (route outs [emit "review.publishable" [pub]])

unable :: Fold
unable b outs = do
  out <- values1 @RoundUnable b
  mem0 <- revive @ReviewMemory (Object out.mem)
  mem1 <- recordReviewed out.head mem0
  mem <- vupdate mem1 [("status", String "unable")]
  let fact = ReviewFact {incarnation = out.incarnation, body = BodyReviewUnable ReviewUnableFactBody {head = out.head, category = out.category}}
  Right (route outs [emit "review.memory" [mem], emit "ready.review_facts" [fact], emit "dash.facts" [fact]])

roundMoved :: Fold
roundMoved b outs = do
  out <- values1 @RoundMoved b
  mem <- revive @ReviewMemory (Object out.mem)
  Right (route outs [emit "review.memory" [mem]])

wakeDeferred :: Fold
wakeDeferred b outs = do
  (deferred, wake) <- values2 @RoundDeferred @RoundWake b
  if (wake.operation, wake.attempt, wake.blocker) /= (deferred.operation, deferred.attempt, deferred.blocker)
    then Left (valueError "V5 review wake differs from its deferred round")
    else do
      let reopened =
            RoundOpen
              { operation = deferred.operation
              , head = deferred.head
              , base = deferred.base
              , policy = deferred.policy
              , incarnation = deferred.incarnation
              , priorFindings = deferred.priorFindings
              , priorLineage = deferred.priorLineage
              , mem = deferred.mem
              , attempt = deferred.attempt + 1
              }
      Right (route outs [emit "review.round" [reopened]])

wakePublication :: Fold
wakePublication b outs = do
  (deferred, wake) <- values2 @PublicationDeferred @RoundWake b
  if (wake.operation, wake.attempt, wake.blocker) /= (deferred.operation, deferred.attempt, deferred.blocker)
    then Left (valueError "V5 review wake differs from its deferred publication")
    else do
      let reopened =
            Publishable
              { head = deferred.head
              , base = deferred.base
              , policy = deferred.policy
              , incarnation = deferred.incarnation
              , findings = deferred.findings
              , effect = deferred.effect
              , op = deferred.operation
              , mem = deferred.mem
              }
      Right (route outs [emit "review.publishable" [reopened]])

findingsFact :: Text -> Integer -> [Object] -> [Text] -> Py FindingsFact
findingsFact h incarnation findings dismissed = do
  counted <-
    filterM
      ( \f -> do
          blocking <- getItem (Object f) "blocking"
          if truthy blocking
            then (`notElem` map String dismissed) <$> getItem (Object f) "id"
            else Right False
      )
      findings
  Right
    FindingsFact
      { incarnation = incarnation
      , body = FindingsFactBody {head = h, blocking = fromIntegral (length counted), count = fromIntegral (length findings)}
      }

-- | A review outcome fact, by kind.
data Outcome = OFindings FindingsFact | OReview ReviewFact | OCleared FaultClearedFact

outcomeJson :: Outcome -> Json
outcomeJson = \case
  OFindings f -> dump f
  OReview f -> dump f
  OCleared f -> dump f

settlementFacts :: ReviewMemory -> Text -> Integer -> Py [Outcome]
settlementFacts mem h incarnation = do
  f <- findingsFact h incarnation mem.findings mem.dismissed
  Right (OFindings f : [OReview (reviewFact h incarnation mem.status) | mem.status `elem` [ReviewClear, ReviewBlocking]])

resolution :: Object -> Py (Maybe FaultClearedFact)
resolution pub
  | lookup "was" pub /= Just (String "faulted") = Right Nothing
  | otherwise = do
      op <- getItem (Object pub) "op" >>= strictText
      Right (Just FaultClearedFact {body = FaultClearedFactBody {where_ = FaultReview, op = op, status = FaultResolved}})

factRoutes :: [Outcome] -> [Emit]
factRoutes facts =
  ("dash.facts", map outcomeJson facts)
    : [("ready.findings_facts", fs) | let fs = [dump f | OFindings f <- facts], not (null fs)]
    ++ [("ready.review_facts", fs) | let fs = [dump f | OReview f <- facts], not (null fs)]
    ++ [("ready.fault_cleared_facts", fs) | let fs = [dump f | OCleared f <- facts], not (null fs)]

idlePub :: Json
idlePub = Object [("phase", String "idle")]

foldLanded :: Fold
foldLanded b outs = do
  out <- values1 @ReviewLanded b
  prior <- revive @ReviewMemory (Object out.mem)
  mem <- vupdate prior [("provisional", Array []), ("pub", idlePub)]
  facts <- settlementFacts mem out.head out.incarnation
  resolved <- resolution prior.pub
  Right (route outs (emit "review.memory" [mem] : factRoutes (facts ++ maybe [] (pure . OCleared) resolved)))

foldMoved :: Fold
foldMoved b outs = do
  out <- values1 @ReviewMoved b
  prior <- revive @ReviewMemory (Object out.mem)
  mem <- vupdate prior [("provisional", objects out.findings), ("pub", idlePub)]
  resolved <- resolution prior.pub
  Right
    ( route
        outs
        ( emit "review.memory" [mem]
            : concat [[emit "ready.fault_cleared_facts" [r], emit "dash.facts" [r]] | Just r <- [resolved]]
        )
    )

foldBlocked :: Fold
foldBlocked b outs = do
  out <- values1 @ReviewBlocked b
  prior <- revive @ReviewMemory (Object out.mem)
  mem <-
    vupdate
      prior
      [ ( "pub"
        , Object
            [ ("phase", String "blocked")
            , ("effect", String out.effect)
            , ("op", String out.op)
            , ("head", String out.head)
            , ("base", String out.base)
            , ("policy", String out.policy)
            , ("incarnation", Int out.incarnation)
            , ("findings", objects out.findings)
            , ("failure_class", String (spell out.failureClass))
            , ("provider_status", maybe Null Int out.providerStatus)
            , ("provider_detail", String out.providerDetail)
            ]
        )
      ]
  facts <- settlementFacts mem out.head out.incarnation
  resolved <- resolution prior.pub
  Right (route outs (emit "review.memory" [mem] : factRoutes (facts ++ maybe [] (pure . OCleared) resolved)))

foldFault :: Fold
foldFault b outs = do
  out <- values1 @ReviewFault b
  prior <- revive @ReviewMemory (Object out.mem)
  pub <- merge (Object prior.pub) [("phase", String "faulted"), ("reason", String out.reason)]
  mem <- vupdate prior [("pub", pub)]
  op <- getOr (Object prior.pub) "op" (String "") >>= strictText
  let fact = FaultRaisedFact {body = BodyPublicationFault PublicationFaultBody {op = op, reason = out.reason}}
  Right (route outs [emit "review.memory" [mem], emit "ready.fault_raised_facts" [fact], emit "dash.facts" [fact]])

foldEmpty :: Fold
foldEmpty b outs = do
  out <- values1 @EmptyReview b
  prior <- revive @ReviewMemory (Object out.mem)
  mem <- vupdate prior [("provisional", Array []), ("pub", idlePub)]
  facts <- settlementFacts mem out.head out.incarnation
  Right (route outs (emit "review.memory" [mem] : factRoutes facts))

retainedPhases :: [Json]
retainedPhases = [String "blocked", String "faulted"]

recover :: Fold
recover b outs = do
  (fact, mem) <- values2 @RecoverFact @ReviewMemory b
  let pub = Object mem.pub
  phase <- get pub "phase"
  op <- get pub "op"
  if fact.target /= "review" || phase `notElem` retainedPhases || String fact.op /= op
    then Right (route outs [emit "review.memory" [mem]])
    else do
      let pending = without "reason" mem.pub
      args <-
        traverse
          (\name -> (name,) <$> getItem pub name)
          ["head", "base", "policy", "incarnation"]
      findings <- getItem pub "findings" >>= pyList
      rest <- traverse (\name -> (name,) <$> getItem pub name) ["effect", "op"]
      was <- getItem pub "phase"
      reopenedPub <- merge (Object pending) [("phase", String "pending"), ("was", was)]
      held <- vupdate mem [("pub", reopenedPub)]
      reopened <- construct @Publishable (args ++ [("findings", Array findings)] ++ rest ++ [("mem", dump held)])
      Right (route outs [emit "review.publishable" [reopened]])

dismiss :: Fold
dismiss b outs = do
  (fact, mem) <- values2 @DismissFact @ReviewMemory b
  let pub0 = Object mem.pub
  phase <- get pub0 "phase"
  carried <-
    if phase `elem` retainedPhases
      then do
        findings <- getOr pub0 "findings" (Array []) >>= pyList
        anyM (\f -> (== String fact.findingId) <$> getItem f "id") findings
      else Right False
  (faultFacts, pub) <-
    if carried
      then do
        phase' <- getItem pub0 "phase"
        cleared <-
          if phase' == String "faulted"
            then do
              op <- getItem pub0 "op" >>= strictText
              Right [OCleared FaultClearedFact {body = FaultClearedFactBody {where_ = FaultReview, op = op, status = FaultCancelled}}]
            else Right []
        cancelled <- merge pub0 [("phase", String "cancelled")]
        Right (cleared, cancelled)
      else Right ([], pub0)
  let dismissed = if fact.findingId `elem` mem.dismissed then mem.dismissed else mem.dismissed ++ [fact.findingId]
  updated0 <- vupdate mem [("dismissed", texts dismissed), ("pub", pub)]
  current <- anyM (\f -> (== String fact.findingId) <$> getItem (Object f) "id") updated0.findings
  (updated, facts) <-
    if current
      then do
        ff <- findingsFact updated0.head updated0.incarnation updated0.findings updated0.dismissed
        if updated0.status `elem` [ReviewClear, ReviewBlocking]
          then do
            s <- status updated0.findings updated0.dismissed
            updated1 <- vupdate updated0 [("status", String (spell s))]
            Right (updated1, OFindings ff : OReview (reviewFact updated1.head updated1.incarnation updated1.status) : faultFacts)
          else Right (updated0, OFindings ff : faultFacts)
      else Right (updated0, faultFacts)
  Right (route outs (emit "review.memory" [updated] : factRoutes facts))

ended :: ReviewMemory -> Text -> Py ReviewEnded
ended mem reason = do
  phase <- getItem (Object mem.pub) "phase" >>= strictText
  Right ReviewEnded {reviewed = mem.reviewed, pubPhase = phase, reason = reason}

end :: Fold
end b outs = do
  (close, mem) <- values2 @CloseFact @ReviewMemory b
  done <- ended mem close.reason
  Right (route outs [emit "review.done" [done]])

endDeferred :: Fold
endDeferred b outs = do
  (close, deferred) <- values2 @CloseFact @RoundDeferred b
  mem <- revive @ReviewMemory (Object deferred.mem)
  done <- ended mem close.reason
  Right (route outs [emit "review.done" [done]])

endPublicationDeferred :: Fold
endPublicationDeferred b outs = do
  (close, deferred) <- values2 @CloseFact @PublicationDeferred b
  mem <- revive @ReviewMemory (Object deferred.mem)
  done <- ended mem close.reason
  Right (route outs [emit "review.done" [done]])

drainDismiss :: Fold
drainDismiss b outs = do
  (_, done) <- values2 @DismissFact @ReviewEnded b
  Right (route outs [emit "review.done" [done]])

drainRecover :: Fold
drainRecover b outs = do
  (_, done) <- values2 @RecoverFact @ReviewEnded b
  Right (route outs [emit "review.done" [done]])

drainWake :: Fold
drainWake b outs = do
  (_, done) <- values2 @RoundWake @ReviewEnded b
  Right (route outs [emit "review.done" [done]])

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  place "review.heads" "HeadWork"
  place "review.closed" "CloseFact"
  place "review.recover" "RecoverFact"
  place "review.dismiss" "DismissFact"
  place "review.wakes" "RoundWake"
  place "review.memory" "ReviewMemory"
  place "review.round" "RoundOpen"
  place "review.deferred" "RoundDeferred"
  place "review.output" "AgentReview"
  place "review.round_moved" "RoundMoved"
  place "review.unable" "RoundUnable"
  place "review.publishable" "Publishable"
  place "review.publication_deferred" "PublicationDeferred"
  place "review.empty" "EmptyReview"
  place "review.landed" "ReviewLanded"
  place "review.moved" "ReviewMoved"
  place "review.blocked" "ReviewBlocked"
  place "review.fault" "ReviewFault"
  place "review.done" "ReviewEnded"

wire :: Author s ()
wire = do
  door "on_review_round_wake" "review.wakes"
  fold "review.start" "_start" start ["review.heads", "review.memory"] ["review.memory", "review.round", "review.publishable"]
  gate "review.agent" "review_agent" ["review.round"] ["review.output", "review.deferred", "review.round_moved", "review.unable"]
  fold "review.wake_deferred" "_wake_deferred" wakeDeferred ["review.deferred", "review.wakes"] ["review.round"]
  fold "review.wake_publication" "_wake_publication" wakePublication ["review.publication_deferred", "review.wakes"] ["review.publishable"]
  fold "review.fold_round_moved" "_round_moved" roundMoved ["review.round_moved"] ["review.memory"]
  fold "review.judge" "_judge" judge ["review.output"] ["review.publishable", "review.empty"]
  fold "review.fold_unable" "_unable" unable ["review.unable"] ["review.memory", "ready.review_facts", "dash.facts"]
  gate
    "review.publish"
    "publish_gate"
    ["review.publishable"]
    ["review.landed", "review.publication_deferred", "review.moved", "review.blocked", "review.fault"]
  fold "review.fold_landed" "_fold_landed" foldLanded ["review.landed"] settledTargets
  fold "review.fold_moved" "_fold_moved" foldMoved ["review.moved"] ["review.memory", "ready.fault_cleared_facts", "dash.facts"]
  fold "review.fold_blocked" "_fold_blocked" foldBlocked ["review.blocked"] settledTargets
  fold "review.fold_fault" "_fold_fault" foldFault ["review.fault"] ["review.memory", "ready.fault_raised_facts", "dash.facts"]
  fold "review.fold_empty" "_fold_empty" foldEmpty ["review.empty"] ["review.memory", "ready.findings_facts", "ready.review_facts", "dash.facts"]
  fold "review.recovery" "_recover" recover ["review.recover", "review.memory"] ["review.memory", "review.publishable"]
  fold "review.dismissal" "_dismiss" dismiss ["review.dismiss", "review.memory"] settledTargets
  fold "review.end" "_end" end ["review.closed", "review.memory"] ["review.done"]
  fold "review.end_deferred" "_end_deferred" endDeferred ["review.closed", "review.deferred"] ["review.done"]
  fold
    "review.end_publication_deferred"
    "_end_publication_deferred"
    endPublicationDeferred
    ["review.closed", "review.publication_deferred"]
    ["review.done"]
  fold "review.drain_dismiss" "_drain_dismiss" drainDismiss ["review.dismiss", "review.done"] ["review.done"]
  fold "review.drain_recover" "_drain_recover" drainRecover ["review.recover", "review.done"] ["review.done"]
  fold "review.drain_wake" "_drain_wake" drainWake ["review.wakes", "review.done"] ["review.done"]
  where
    settledTargets = ["review.memory", "ready.findings_facts", "ready.review_facts", "ready.fault_cleared_facts", "dash.facts"]

seed :: Text -> [(NetPath, [Token])]
seed subject =
  [ ( "review.memory"
    , [ seedToken
          ReviewMemory
            { subject = subject
            , head = ""
            , incarnation = 0
            , status = ReviewPending
            , reviewed = []
            , provisional = []
            , findings = []
            , lineage = []
            , dismissed = []
            , pub = [("phase", String "idle")]
            }
      ]
    )
  ]

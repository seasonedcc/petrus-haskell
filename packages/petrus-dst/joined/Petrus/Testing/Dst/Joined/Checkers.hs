{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The joined worlds' independent authority checkers: ports of every
-- @Joined*AuthorityChecker@ of the reference's @tests/dst/joined_*world.py@.
--
-- Each check is a pure function of the observation, with the reference's
-- Python value semantics: dictionary equality ignores key order, @True ==
-- 1@, and @x is True@ admits only the boolean. Detail values echo the
-- observation's raw members where the reference does. Malformed evidence
-- (a missing or non-numeric counter) fails the comparison it appears in
-- instead of raising @KeyError@/@TypeError@ (see DIVERGENCES.md).
module Petrus.Testing.Dst.Joined.Checkers
  ( -- * joined_world.py
    commitAuthorityChecker
  , deliveryAuthorityChecker
  , scopedDropAuthorityChecker
  , acceptedScopedDropAuthorityChecker
  , scopedQuarantineAuthorityChecker
  , acceptedScopedQuarantineAuthorityChecker
  , projectionAuthorityChecker
  , acceptedProjectionAuthorityChecker
  , terminalAuthorityChecker
  , failureAuthorityChecker
  , acceptedFailureAuthorityChecker
  , failureProjectionAuthorityChecker
  , acceptedFailureProjectionAuthorityChecker
  , acceptedTerminalAuthorityChecker
  , acceptedBeginAuthorityChecker
  , resetRefusalAuthorityChecker
  , acceptedResetAuthorityChecker
  , closeRefusalAuthorityChecker
  , acceptedCloseAuthorityChecker
  , openAuthorityChecker
  , cancellationAuthorityChecker
  , acceptedCancellationAuthorityChecker
    -- * joined_registration_world.py
  , registrationProjectionAuthorityChecker
    -- * joined_seal_world.py
  , sealAuthorityChecker
    -- * joined_creation_world.py
  , creationAuthorityChecker
  , sourceCreationAuthorityChecker
    -- * Every checker
  , joinedCheckers
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Common (member)
import Petrus.Testing.Dst.Joined.Identities qualified as Id
import Petrus.Testing.Dst.Joined.Support (listOf, pyCount, pyEq, pyIn, pyNum, strs)

-- ---------------------------------------------------------------------------
-- Python value helpers

-- | A Python number, or 'Nothing' for malformed evidence.
type N = Maybe Rational

num :: Text -> Json -> N
num key value = pyNum (member key value)

n :: Integral a => a -> N
n = Just . fromIntegral

-- | @a == b@ over numbers.
(.==) :: N -> N -> Bool
Just a .== Just b = a == b
_ .== _ = False

-- | @a <= b@ over numbers.
(.<=) :: N -> N -> Bool
Just a .<= Just b = a <= b
_ .<= _ = False

infix 4 .==, .<=

eqs :: [N] -> Bool
eqs xs = and (zipWith (.==) xs (drop 1 xs))

les :: [N] -> Bool
les xs = and (zipWith (.<=) xs (drop 1 xs))

plus :: N -> N -> N
plus a b = (+) <$> a <*> b

-- | A computed count as a detail value.
int :: Integer -> Json
int = Int

-- | Python truthiness of a JSON value.
truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String s -> not (T.null s)
  Array xs -> not (null xs)
  Object ms -> not (null ms)

isTrue, isFalse :: Json -> Bool
isTrue = (== Bool True)
isFalse = (== Bool False)

count :: Text -> [Json] -> Integer
count name = pyCount (String name)

countJ :: Json -> [Json] -> Integer
countJ = pyCount

list :: Text -> Json -> [Json]
list key value = listOf (member key value)

-- | @xs == ys@ over lists.
eqList :: [Json] -> [Json] -> Bool
eqList xs ys = pyEq (Array xs) (Array ys)

-- | @xs in (candidates...)@ over lists.
oneOf :: [Json] -> [[Json]] -> Bool
oneOf xs = any (eqList xs)

-- | @attempts == expected[: len(attempts)]@ with the length bound.
prefixOf :: [Json] -> [Json] -> Bool
prefixOf attempts expected = length attempts <= length expected && eqList attempts (take (length attempts) expected)

len :: [a] -> Integer
len = toInteger . length

transaction :: Bool -> Bool -> [Text] -> Json
transaction accepted dispatched records =
  Object [("accepted", Bool accepted), ("dispatch_attempted", Bool dispatched), ("record_types", strs records)]

lifecycle :: Bool -> Text -> [Text] -> Json
lifecycle accepted phase records =
  Object [("accepted", Bool accepted), ("phase", String phase), ("record_types", strs records)]

task :: Text -> Integer -> Text -> Json
task instanceId occurrence state =
  Object [("idempotency", String (instanceId <> ":occurrence-" <> T.pack (show occurrence))), ("state", String state)]

joinedInstance :: Text
joinedInstance = "dst-world-joined-begin-refusal"

beginBatch :: [Text]
beginBatch = ["CandidateSelected", "FiringBegun", "TokensConsumed", "ActivityRequested"]

begin :: Json
begin = transaction True True beginBatch

taskStates :: [Text] -> [[Json]]
taskStates states = [] : [[task joinedInstance 1 s] | s <- states]

taskState :: [Json] -> Json
taskState = \case
  [] -> Null
  t : _ -> member "state" t

checker :: CheckerIdentity -> Text -> (Json -> CheckResult) -> Checker
checker identity name body =
  Checker
    { identity
    , request = ObservationRequest {name, payload = Object []}
    , check = pureCheck $ \o -> Right (body o.value)
    }

result :: Bool -> [(Text, Json)] -> CheckResult
result passed detail = CheckResult {passed, detail = Object detail}

-- | Rename detail keys (@detail[new] = detail.pop(old)@).
renameDetail :: [(Text, Text)] -> CheckResult -> CheckResult
renameDetail renames r = case r.detail of
  Object members ->
    let renamed = [(maybe k id (lookup k renames), v) | (k, v) <- members]
     in r {detail = Object renamed}
  _ -> r

-- ---------------------------------------------------------------------------
-- joined_world.py

-- | @JoinedCommitAuthorityChecker@.
commitAuthorityChecker :: Checker
commitAuthorityChecker = checker Id.checkerIdentity "engine.joined-commit-authority" $ \value ->
  let records = list "record_types" value
      attempts = list "transaction_attempts" value
      tasks = list "durable_tasks" value
      accepted = len (filter (isTrue . member "accepted") attempts)
      refused = len (filter (isFalse . member "accepted") attempts)
      selected = count "CandidateSelected" records
      begun = count "FiringBegun" records
      requested = count "ActivityRequested" records
      whole = all (\a -> isTrue (member "dispatch_attempted" a) && pyEq (member "record_types" a) (strs beginBatch)) attempts
      tasksExact = oneOf tasks (taskStates ["pending"])
      passed =
        0 <= refused
          && refused <= 1
          && 0 <= accepted
          && accepted <= 1
          && length attempts <= 2
          && whole
          && num "prepare_calls" value .== n (length attempts)
          && eqs [n selected, n begun, n requested, n (length tasks), n accepted]
          && tasksExact
   in result
        passed
        [ ("accepted_joined_begins", int accepted)
        , ("activity_requested", int requested)
        , ("candidate_selected", int selected)
        , ("durable_tasks", int (len tasks))
        , ("firing_begun", int begun)
        , ("joined_attempts_whole", Bool whole)
        , ("prepare_calls", member "prepare_calls" value)
        , ("refused_joined_begins", int refused)
        , ("tasks_exact", Bool tasksExact)
        ]

-- | @JoinedDeliveryAuthorityChecker@.
deliveryAuthorityChecker :: Checker
deliveryAuthorityChecker = checker Id.deliveryCheckerIdentity "engine.joined-delivery-authority" $ \value ->
  let canonical = list "canonical_deliveries" value
      deliveryAttempts = list "delivery_attempts" value
      transactions = list "transaction_attempts" value
      acceptanceBatch = strs ["ExternalEventDelivered", "FiringBegun"]
      completionBatch = strs ["TokensProduced", "FiringCompleted"]
      transactionsExact =
        all
          (\a -> isFalse (member "dispatch_attempted" a) && pyIn (member "record_types" a) [acceptanceBatch, completionBatch])
          transactions
      tally accepted batch = len [() | a <- transactions, member "accepted" a == Bool accepted, pyEq (member "record_types" a) batch]
      acceptedAcceptances = tally True acceptanceBatch
      acceptedCompletions = tally True completionBatch
      refusedAcceptances = tally False acceptanceBatch
      refusalFaults = member "delivery_refusals" value
      ackLosses = member "delivery_ack_losses" value
      reported = map (member "disposition") deliveryAttempts
      refusedAcceptance = Object [("accepted", Bool False), ("dispatch_attempted", Bool False), ("record_types", acceptanceBatch)]
      acceptedAcceptance = Object [("accepted", Bool True), ("dispatch_attempted", Bool False), ("record_types", acceptanceBatch)]
      acceptedCompletion = Object [("accepted", Bool True), ("dispatch_attempted", Bool False), ("record_types", completionBatch)]
      d = String . actionDispositionText
      attemptsN = length deliveryAttempts
      (expectedTransactions, expectedReported)
        | truthy refusalFaults =
            ( [refusedAcceptance] <> (if attemptsN >= 2 then [acceptedAcceptance, acceptedCompletion] else [])
            , [d RefusedExpected] <> (if attemptsN >= 2 then [d Applied] <> [d Idempotent | attemptsN == 3] else [])
            )
        | truthy ackLosses =
            ( [acceptedAcceptance] <> [acceptedCompletion | attemptsN >= 2]
            , [d RefusedExpected] <> (if attemptsN >= 2 then [d Applied] <> [d Idempotent | attemptsN == 3] else [])
            )
        | otherwise = ([], [])
      expectedCanonical = case deliveryAttempts of
        first : _
          | acceptedAcceptances > 0 ->
              [Object [("identity", member "identity" first), ("occurrence", Int 1), ("value", member "value" first)]]
        _ -> []
      expectedValues = case deliveryAttempts of
        first : _ | acceptedCompletions > 0 -> [member "value" first]
        _ -> []
      refusalN = pyNum refusalFaults
      ackN = pyNum ackLosses
      passed =
        transactionsExact
          && eqList transactions expectedTransactions
          && eqList reported expectedReported
          && eqList canonical expectedCanonical
          && eqList (list "produced_values" value) expectedValues
          && num "firing_completed" value .== n acceptedCompletions
          && n refusedAcceptances .== refusalN
          && refusalN .<= n (1 :: Integer)
          && les [ackN, n acceptedAcceptances, n (1 :: Integer)]
          && acceptedCompletions <= acceptedAcceptances
          && plus refusalN ackN .<= n (1 :: Integer)
   in result
        passed
        [ ("accepted_acceptances", int acceptedAcceptances)
        , ("accepted_completions", int acceptedCompletions)
        , ("ack_losses", ackLosses)
        , ("canonical_deliveries", Array canonical)
        , ("expected_deliveries", Array expectedCanonical)
        , ("refused_acceptances", int refusedAcceptances)
        , ("reported_dispositions", Array reported)
        , ("transactions_exact", Bool transactionsExact)
        ]

-- | @_check_scoped_drop@ and @_check_scoped_quarantine@.
checkScoped :: Bool -> Bool -> Json -> CheckResult
checkScoped quarantine acknowledgementLoss value =
  let canonical = list (if quarantine then "canonical_quarantines" else "canonical_drops") value
      deliveryAttempts = list "scoped_delivery_attempts" value
      transactions = list "transaction_attempts" value
      lifecycleAttempts = list "lifecycle_attempts" value
      lifecycleRecords = list "lifecycle_records" value
      recordName = if quarantine then "ScopedDeliveryQuarantined" else "ScopedDeliveryDropped"
      expectedTransaction = Object [("dispatch_attempted", Bool False), ("record_types", strs [recordName])]
      transactionsExact =
        all
          (\a -> pyEq (Object [(k, member k a) | k <- ["dispatch_attempted", "record_types"]]) expectedTransaction)
          transactions
      accepted = len (filter (isTrue . member "accepted") transactions)
      refused = len (filter (isFalse . member "accepted") transactions)
      expectedOpen = lifecycle True "scope_open" ["ScopeOpened"]
      expectedReset = lifecycle True "scope_reset" ["ScopeReset"]
      expectedOpenRecord = Object [("generation", Int 1), ("kind", String "opened"), ("name", String "draft")]
      expectedResetRecord =
        Object
          [ ("closed_generation", Int 1)
          , ("kind", String "reset")
          , ("name", String "draft")
          , ("opened_generation", Int 2)
          ]
      pair a r = Array [Array a, Array r]
      lifecycleOptions
        | quarantine = [pair [] [], pair [expectedOpen] [expectedOpenRecord]]
        | otherwise =
            [ pair [] []
            , pair [expectedOpen] [expectedOpenRecord]
            , pair [expectedOpen, expectedReset] [expectedOpenRecord, expectedResetRecord]
            ]
      lifecycleExact = pyIn (pair lifecycleAttempts lifecycleRecords) lifecycleOptions
      lifecycleReady = eqList lifecycleAttempts (if quarantine then [expectedOpen] else [expectedOpen, expectedReset])
      prefix = if quarantine then "scoped_quarantine" else "scoped_drop"
      refusalFaults = member (prefix <> "_refusals") value
      ackLosses = member (prefix <> "_ack_losses") value
      reported = map (member "disposition") deliveryAttempts
      d = String . actionDispositionText
      attemptsN = length deliveryAttempts
      (expectedAcceptance, expectedReported)
        | acknowledgementLoss =
            ( [Bool True | accepted > 0]
            , [d RefusedExpected | accepted > 0] <> [d Idempotent | attemptsN == 2]
            )
        | otherwise =
            ( [Bool False | refused > 0] <> [Bool True | accepted > 0]
            , [d RefusedExpected | refused > 0]
                <> (if accepted > 0 then [d Applied] <> [d Idempotent | attemptsN == 3] else [])
            )
      identity = if quarantine then "future-draft-3" else "stale-draft-3"
      generation = if quarantine then 2 else 1
      payloadsExact =
        all
          ( \a ->
              pyEq
                (Object [(k, member k a) | k <- ["identity", "scope_generation", "value"]])
                (Object [("identity", String identity), ("scope_generation", Int generation), ("value", Int 3)])
          )
          deliveryAttempts
      expectedCanonical =
        [ Object
            [ ("identity", String identity)
            , ("scope_generation", Int generation)
            , ("scope_name", String "draft")
            , ("source", String "source")
            , ("value", Int 3)
            ]
        | accepted > 0
        ]
      expectedRecords =
        ["InstanceCreated", "DeliveryRegistrationOpened"]
          <> ["ScopeOpened" | not (null lifecycleAttempts)]
          <> ["ScopeReset" | not quarantine, length lifecycleAttempts == 2]
          <> [recordName | accepted > 0]
      transactionAcceptance = map (member "accepted") transactions
      refusalN = pyNum refusalFaults
      ackN = pyNum ackLosses
      lifecycleCounters
        | quarantine = num "scope_opens" value .== n (length lifecycleRecords)
        | otherwise =
            num "scope_opens" value .== n (length (take 1 lifecycleRecords))
              && num "scope_resets" value .== n (length [() | r <- lifecycleRecords, member "kind" r == String "reset"])
      passed =
        lifecycleExact
          && transactionsExact
          && eqList transactionAcceptance expectedAcceptance
          && eqList reported expectedReported
          && payloadsExact
          && eqList canonical expectedCanonical
          && eqList (list "record_types" value) (map String expectedRecords)
          && (null deliveryAttempts || lifecycleReady)
          && n refused .== refusalN
          && refusalN .<= n (1 :: Integer)
          && les [ackN, n accepted, n (1 :: Integer)]
          && plus refusalN ackN .<= n (1 :: Integer)
          && lifecycleCounters
      noun = if quarantine then "quarantines" else "drops"
   in result
        passed
        [ ("accepted_" <> noun, int accepted)
        , ("ack_losses", ackLosses)
        , ("canonical_" <> noun, int (len canonical))
        , ("lifecycle_ready", Bool lifecycleReady)
        , ("refused_" <> noun, int refused)
        , ("reported_dispositions", Array reported)
        , ("transactions_exact", Bool transactionsExact)
        ]

-- | @JoinedScopedDropAuthorityChecker@.
scopedDropAuthorityChecker :: Checker
scopedDropAuthorityChecker =
  checker Id.scopedDropRefusalCheckerIdentity "engine.joined-scoped-drop-authority" (checkScoped False False)

-- | @JoinedAcceptedScopedDropAuthorityChecker@.
acceptedScopedDropAuthorityChecker :: Checker
acceptedScopedDropAuthorityChecker =
  checker Id.scopedDropAckLossCheckerIdentity "engine.joined-accepted-scoped-drop-authority" (checkScoped False True)

-- | @JoinedScopedQuarantineAuthorityChecker@.
scopedQuarantineAuthorityChecker :: Checker
scopedQuarantineAuthorityChecker =
  checker Id.scopedQuarantineRefusalCheckerIdentity "engine.joined-scoped-quarantine-authority" (checkScoped True False)

-- | @JoinedAcceptedScopedQuarantineAuthorityChecker@.
acceptedScopedQuarantineAuthorityChecker :: Checker
acceptedScopedQuarantineAuthorityChecker =
  checker Id.scopedQuarantineAckLossCheckerIdentity "engine.joined-accepted-scoped-quarantine-authority" (checkScoped True True)

-- | The counts shared by the completed-terminal checkers.
data Terminal = Terminal
  { selected, begun, requested, completed, produced, projected :: Integer
  , tasks :: [Json]
  , tasksExact, completedCustody :: Bool
  , workerCompletions :: N
  , workerCompletionsRaw :: Json
  }

terminalFacts :: Json -> Terminal
terminalFacts value =
  let records = list "record_types" value
      tasks = list "durable_tasks" value
      completedTasks = [task joinedInstance 1 "completed"]
   in Terminal
        { selected = count "CandidateSelected" records
        , begun = count "FiringBegun" records
        , requested = count "ActivityRequested" records
        , completed = count "ActivityCompleted" records
        , produced = count "TokensProduced" records
        , projected = count "FiringCompleted" records
        , tasks
        , tasksExact = null tasks || oneOf tasks (taskStates ["pending", "running", "completed"])
        , completedCustody = eqList tasks completedTasks
        , workerCompletions = num "worker_completions" value
        , workerCompletionsRaw = member "worker_completions" value
        }

-- | The terminal conjuncts common to the projection and terminal checkers.
terminalPassed :: Json -> Terminal -> Integer -> Integer -> Integer -> Bool
terminalPassed value t acceptedBegins acceptedTerminals acceptedProjections =
  num "prepare_calls" value .== n acceptedBegins
    && eqs [n t.selected, n t.begun, n t.requested, n acceptedBegins, n (length t.tasks)]
    && n t.completed .== n acceptedTerminals
    && les [n acceptedTerminals, t.workerCompletions, n (1 :: Integer)]
    && eqs [n t.produced, n t.projected, n acceptedProjections]
    && acceptedProjections <= t.completed
    && t.completedCustody == (t.workerCompletions .== n (1 :: Integer))
    && t.tasksExact

terminalDetail :: Terminal -> Integer -> Integer -> Integer -> Bool -> [(Text, Json)]
terminalDetail t acceptedBegins acceptedTerminals acceptedProjections attemptsExact =
  [ ("accepted_begins", int acceptedBegins)
  , ("accepted_projections", int acceptedProjections)
  , ("accepted_terminals", int acceptedTerminals)
  , ("attempts_exact", Bool attemptsExact)
  , ("canonical_projections", int t.projected)
  , ("canonical_terminals", int t.completed)
  , ("completed_custody", Bool t.completedCustody)
  , ("tasks_exact", Bool t.tasksExact)
  , ("worker_completions", t.workerCompletionsRaw)
  ]

terminalTx, projectionTx :: Bool -> Json
terminalTx accepted = transaction accepted False ["ActivityCompleted"]
projectionTx accepted = transaction accepted False ["TokensProduced", "FiringCompleted"]

-- | @JoinedProjectionAuthorityChecker@.
projectionAuthorityChecker :: Checker
projectionAuthorityChecker = checker Id.projectionCheckerIdentity "engine.joined-projection-authority" $ \value ->
  let attempts = list "transaction_attempts" value
      t = terminalFacts value
      attemptsExact =
        oneOf
          attempts
          [[], [begin], [begin, terminalTx True, projectionTx False], [begin, terminalTx True, projectionTx False, projectionTx True]]
      acceptedBegin = countJ begin attempts
      acceptedTerminal = countJ (terminalTx True) attempts
      acceptedProjection = countJ (projectionTx True) attempts
      refusedProjection = countJ (projectionTx False) attempts
      passed =
        attemptsExact
          && terminalPassed value t acceptedBegin acceptedTerminal acceptedProjection
          && n refusedProjection .== num "projection_refusals" value
          && refusedProjection <= 1
   in result passed $
        (terminalDetail t acceptedBegin acceptedTerminal acceptedProjection attemptsExact)
          <> [("refused_projections", int refusedProjection)]

-- | @JoinedAcceptedProjectionAuthorityChecker@.
acceptedProjectionAuthorityChecker :: Checker
acceptedProjectionAuthorityChecker =
  checker Id.projectionAckLossCheckerIdentity "engine.joined-accepted-projection-authority" $ \value ->
    let attempts = list "transaction_attempts" value
        t = terminalFacts value
        attemptsExact = oneOf attempts [[], [begin], [begin, terminalTx True, projectionTx True]]
        acceptedBegins = countJ begin attempts
        acceptedTerminals = countJ (terminalTx True) attempts
        acceptedProjections = countJ (projectionTx True) attempts
        ackLosses = num "projection_ack_losses" value
        passed =
          attemptsExact
            && terminalPassed value t acceptedBegins acceptedTerminals acceptedProjections
            && les [n (0 :: Integer), ackLosses, n acceptedProjections, n (1 :: Integer)]
     in result passed $
          (terminalDetail t acceptedBegins acceptedTerminals acceptedProjections attemptsExact)
            <> [("ack_losses", member "projection_ack_losses" value)]

-- | @JoinedTerminalAuthorityChecker@.
terminalAuthorityChecker :: Checker
terminalAuthorityChecker = checker Id.terminalRefusalCheckerIdentity "engine.joined-terminal-authority" $ \value ->
  let attempts = list "transaction_attempts" value
      t = terminalFacts value
      attemptsExact =
        oneOf
          attempts
          [ []
          , [begin]
          , [begin, terminalTx False]
          , [begin, terminalTx False, terminalTx True]
          , [begin, terminalTx False, terminalTx True, projectionTx True]
          ]
      acceptedBegins = countJ begin attempts
      refusedTerminals = countJ (terminalTx False) attempts
      acceptedTerminals = countJ (terminalTx True) attempts
      acceptedProjections = countJ (projectionTx True) attempts
      refusals = num "terminal_refusals" value
      passed =
        attemptsExact
          && terminalPassed value t acceptedBegins acceptedTerminals acceptedProjections
          && n refusedTerminals .== refusals
          && refusals .<= n (1 :: Integer)
   in result passed $
        (terminalDetail t acceptedBegins acceptedTerminals acceptedProjections attemptsExact)
          <> [("refused_terminals", int refusedTerminals)]

-- | @JoinedAcceptedTerminalAuthorityChecker@.
acceptedTerminalAuthorityChecker :: Checker
acceptedTerminalAuthorityChecker =
  checker Id.terminalAckLossCheckerIdentity "engine.joined-accepted-terminal-authority" $ \value ->
    let attempts = list "transaction_attempts" value
        t = terminalFacts value
        attemptsExact = oneOf attempts [[], [begin], [begin, terminalTx True], [begin, terminalTx True, projectionTx True]]
        acceptedBegins = countJ begin attempts
        acceptedTerminals = countJ (terminalTx True) attempts
        acceptedProjections = countJ (projectionTx True) attempts
        ackLosses = num "terminal_ack_losses" value
        passed =
          attemptsExact
            && terminalPassed value t acceptedBegins acceptedTerminals acceptedProjections
            && les [n (0 :: Integer), ackLosses, n acceptedTerminals, n (1 :: Integer)]
     in result passed $
          (terminalDetail t acceptedBegins acceptedTerminals acceptedProjections attemptsExact)
            <> [("ack_losses", member "terminal_ack_losses" value)]

-- | The counts shared by the failure checkers.
data Failure = Failure
  { selected, begun, requested, failed, firingsFailed, firingCompleted, produced :: Integer
  , tasks :: [Json]
  , tasksExact, failedCustody :: Bool
  , workerFailures :: N
  }

failureFacts :: Json -> Failure
failureFacts value =
  let records = list "record_types" value
      tasks = list "durable_tasks" value
   in Failure
        { selected = count "CandidateSelected" records
        , begun = count "FiringBegun" records
        , requested = count "ActivityRequested" records
        , failed = count "ActivityFailed" records
        , firingsFailed = count "FiringFailed" records
        , firingCompleted = count "FiringCompleted" records
        , produced = count "TokensProduced" records
        , tasks
        , tasksExact = null tasks || oneOf tasks (taskStates ["pending", "running", "failed"])
        , failedCustody = eqList tasks [task joinedInstance 1 "failed"]
        , workerFailures = num "worker_failures" value
        }

failureTx, firingFailedTx :: Bool -> Json
failureTx accepted = transaction accepted False ["ActivityFailed"]
firingFailedTx accepted = transaction accepted False ["FiringFailed"]

failurePassed :: Json -> Failure -> Integer -> Integer -> Integer -> Bool
failurePassed value f acceptedBegins acceptedFailures acceptedFiringsFailed =
  num "prepare_calls" value .== n acceptedBegins
    && eqs [n f.selected, n f.begun, n f.requested, n acceptedBegins, n (length f.tasks)]
    && n f.failed .== n acceptedFailures
    && les [n acceptedFailures, f.workerFailures, n (1 :: Integer)]
    && f.firingsFailed == acceptedFiringsFailed
    && acceptedFiringsFailed <= f.failed
    && f.firingCompleted == f.produced
    && f.produced == 0
    && f.failedCustody == (f.workerFailures .== n (1 :: Integer))
    && f.tasksExact

failureDetail :: Json -> Failure -> Integer -> Integer -> Integer -> Bool -> [(Text, Json)]
failureDetail value f acceptedBegins acceptedFailures acceptedFiringsFailed attemptsExact =
  [ ("accepted_begins", int acceptedBegins)
  , ("accepted_failures", int acceptedFailures)
  , ("accepted_firings_failed", int acceptedFiringsFailed)
  , ("attempts_exact", Bool attemptsExact)
  , ("canonical_failures", int f.failed)
  , ("canonical_firings_failed", int f.firingsFailed)
  , ("failed_custody", Bool f.failedCustody)
  , ("tasks_exact", Bool f.tasksExact)
  , ("worker_failures", member "worker_failures" value)
  ]

-- | @JoinedFailureAuthorityChecker@.
failureAuthorityChecker :: Checker
failureAuthorityChecker = checker Id.failureRefusalCheckerIdentity "engine.joined-failure-authority" $ \value ->
  let attempts = list "transaction_attempts" value
      f = failureFacts value
      attemptsExact =
        oneOf
          attempts
          [ []
          , [begin]
          , [begin, failureTx False]
          , [begin, failureTx False, failureTx True]
          , [begin, failureTx False, failureTx True, firingFailedTx True]
          ]
      acceptedBegins = countJ begin attempts
      refusedFailures = countJ (failureTx False) attempts
      acceptedFailures = countJ (failureTx True) attempts
      acceptedFiringsFailed = countJ (firingFailedTx True) attempts
      refusals = num "terminal_refusals" value
      passed =
        attemptsExact
          && failurePassed value f acceptedBegins acceptedFailures acceptedFiringsFailed
          && n refusedFailures .== refusals
          && refusals .<= n (1 :: Integer)
   in result passed $
        failureDetail value f acceptedBegins acceptedFailures acceptedFiringsFailed attemptsExact
          <> [("refused_failures", int refusedFailures)]

-- | @JoinedAcceptedFailureAuthorityChecker@.
acceptedFailureAuthorityChecker :: Checker
acceptedFailureAuthorityChecker =
  checker Id.failureAckLossCheckerIdentity "engine.joined-accepted-failure-authority" $ \value ->
    let attempts = list "transaction_attempts" value
        f = failureFacts value
        attemptsExact =
          oneOf attempts [[], [begin], [begin, failureTx True], [begin, failureTx True, firingFailedTx True]]
        acceptedBegins = countJ begin attempts
        acceptedFailures = countJ (failureTx True) attempts
        acceptedFiringsFailed = countJ (firingFailedTx True) attempts
        ackLosses = num "terminal_ack_losses" value
        passed =
          attemptsExact
            && failurePassed value f acceptedBegins acceptedFailures acceptedFiringsFailed
            && les [n (0 :: Integer), ackLosses, n acceptedFailures, n (1 :: Integer)]
     in result passed $
          failureDetail value f acceptedBegins acceptedFailures acceptedFiringsFailed attemptsExact
            <> [("ack_losses", member "terminal_ack_losses" value)]

-- | @_check_failure_projection@.
checkFailureProjection :: Bool -> Json -> CheckResult
checkFailureProjection acknowledgementLoss value =
  let attempts = list "transaction_attempts" value
      f = failureFacts value
      failure = failureTx True
      attemptsExact
        | acknowledgementLoss = oneOf attempts [[], [begin], [begin, failure], [begin, failure, firingFailedTx True]]
        | otherwise =
            oneOf
              attempts
              [ []
              , [begin]
              , [begin, failure]
              , [begin, failure, firingFailedTx False]
              , [begin, failure, firingFailedTx False, firingFailedTx True]
              ]
      acceptedBegins = countJ begin attempts
      acceptedFailures = countJ failure attempts
      refusedProjections = countJ (firingFailedTx False) attempts
      acceptedProjections = countJ (firingFailedTx True) attempts
      faultKey = if acknowledgementLoss then "projection_ack_losses" else "projection_refusals"
      faultCount = num faultKey value
      faultExact
        | acknowledgementLoss = les [n (0 :: Integer), faultCount, n acceptedProjections]
        | otherwise = faultCount .== n refusedProjections && refusedProjections <= 1
      passed =
        attemptsExact
          && eqs [n f.selected, n f.begun, n f.requested, n acceptedBegins, n (length f.tasks)]
          && num "prepare_calls" value .== n acceptedBegins
          && f.failed == acceptedFailures
          && les [n acceptedFailures, f.workerFailures, n (1 :: Integer)]
          && f.firingsFailed == acceptedProjections
          && acceptedProjections <= acceptedFailures
          && f.firingCompleted == f.produced
          && f.produced == 0
          && f.failedCustody == (f.workerFailures .== n (1 :: Integer))
          && f.tasksExact
          && faultExact
   in result
        passed
        [ ("accepted_failures", int acceptedFailures)
        , ("accepted_projections", int acceptedProjections)
        , ("attempts_exact", Bool attemptsExact)
        , ("canonical_projections", int f.firingsFailed)
        , ("failed_custody", Bool f.failedCustody)
        , ("fault_count", member faultKey value)
        , ("refused_projections", int refusedProjections)
        ]

-- | @JoinedFailureProjectionAuthorityChecker@.
failureProjectionAuthorityChecker :: Checker
failureProjectionAuthorityChecker =
  checker Id.failureProjectionRefusalCheckerIdentity "engine.joined-failure-projection-authority" (checkFailureProjection False)

-- | @JoinedAcceptedFailureProjectionAuthorityChecker@.
acceptedFailureProjectionAuthorityChecker :: Checker
acceptedFailureProjectionAuthorityChecker =
  checker
    Id.failureProjectionAckLossCheckerIdentity
    "engine.joined-accepted-failure-projection-authority"
    (checkFailureProjection True)

-- | @JoinedAcceptedBeginAuthorityChecker@.
acceptedBeginAuthorityChecker :: Checker
acceptedBeginAuthorityChecker = checker Id.ackLossCheckerIdentity "engine.joined-accepted-begin-authority" $ \value ->
  let records = list "record_types" value
      attempts = list "transaction_attempts" value
      tasks = list "durable_tasks" value
      acceptedBegins = countJ begin attempts
      attemptsExact = oneOf attempts [[], [begin]]
      ackLosses = num "commit_ack_losses" value
      expectedTasks = [task joinedInstance 1 "pending" | acceptedBegins /= 0]
      passed =
        attemptsExact
          && eqs
            [ n (count "CandidateSelected" records)
            , n (count "FiringBegun" records)
            , n (count "ActivityRequested" records)
            , n acceptedBegins
            , n (length tasks)
            ]
          && num "prepare_calls" value .== n acceptedBegins
          && eqList tasks expectedTasks
          && les [n (0 :: Integer), ackLosses, n acceptedBegins, n (1 :: Integer)]
   in result
        passed
        [ ("accepted_begins", int acceptedBegins)
        , ("ack_losses", member "commit_ack_losses" value)
        , ("attempts_exact", Bool attemptsExact)
        , ("durable_tasks", int (len tasks))
        , ("prepare_calls", member "prepare_calls" value)
        ]

sourceAcceptance, sourceCompletion :: Json
sourceAcceptance = transaction True False ["ExternalEventDelivered", "FiringBegun"]
sourceCompletion = transaction True False ["TokensProduced", "FiringCompleted"]

-- | The lifecycle facts shared by the reset, close and cancellation checkers.
data Lifecycle = Lifecycle
  { canonicalSources, canonicalOpens, canonicalResets, requested, completed, failed, firingsFailed :: Integer
  , projected :: Integer
  , tasks :: [Json]
  }

lifecycleFacts :: Json -> Lifecycle
lifecycleFacts value =
  let records = list "record_types" value
      sources = count "ExternalEventDelivered" records
   in Lifecycle
        { canonicalSources = sources
        , canonicalOpens = count "ScopeOpened" records
        , canonicalResets = count "ScopeReset" records
        , requested = count "ActivityRequested" records
        , completed = count "ActivityCompleted" records
        , failed = count "ActivityFailed" records
        , firingsFailed = count "FiringFailed" records
        , projected = count "FiringCompleted" records - sources
        , tasks = list "durable_tasks" value
        }

-- | The second Activity's custody, from the most advanced fact.
custody :: [(Bool, Text)] -> [Json]
custody = \case
  [] -> []
  (True, state) : _ -> [task joinedInstance 2 state]
  _ : rest -> custody rest

-- | @canonical == authored <= 1@ for the scope-open and source counters.
openedAndSourced :: Json -> Lifecycle -> Bool
openedAndSourced value l =
  n l.canonicalOpens .== num "scope_opens" value
    && num "scope_opens" value .<= n (1 :: Integer)
    && n l.canonicalSources .== num "source_deliveries" value
    && num "source_deliveries" value .<= n (1 :: Integer)

-- | @JoinedResetRefusalAuthorityChecker@.
resetRefusalCheck :: Json -> CheckResult
resetRefusalCheck value =
  let attempts = list "transaction_attempts" value
      lifecycleAttempts = list "lifecycle_attempts" value
      l = lifecycleFacts value
      attemptsExact = prefixOf attempts [sourceAcceptance, sourceCompletion, begin, terminalTx True, projectionTx True]
      refusedReset = lifecycle False "scope_reset" ["ScopeReset"]
      lifecycleExact = oneOf lifecycleAttempts [[], [refusedReset]]
      acceptedBegins = countJ begin attempts
      acceptedTerminals = countJ (terminalTx True) attempts
      acceptedProjections = countJ (projectionTx True) (drop 2 attempts)
      resetAttempts = num "scope_resets" value
      resetRefusals = num "reset_refusals" value
      workerClaims = num "worker_claims" value
      workerCompletions = num "worker_completions" value
      expectedTasks =
        custody
          [ (maybe False (/= 0) workerCompletions, "completed")
          , (maybe False (/= 0) workerClaims, "running")
          , (acceptedBegins /= 0, "pending")
          ]
      passed =
        attemptsExact
          && lifecycleExact
          && openedAndSourced value l
          && l.canonicalResets == 0
          && eqs [resetAttempts, resetRefusals, n (countJ refusedReset lifecycleAttempts)]
          && n (countJ refusedReset lifecycleAttempts) .<= n (1 :: Integer)
          && l.requested == acceptedBegins
          && acceptedBegins <= 1
          && num "prepare_calls" value .== n acceptedBegins
          && eqList l.tasks expectedTasks
          && les [n (0 :: Integer), workerCompletions, workerClaims, n acceptedBegins]
          && l.completed == acceptedTerminals
          && n acceptedTerminals .<= workerCompletions
          && l.projected == acceptedProjections
          && acceptedProjections <= l.completed
          && num "cancellation_refusals" value .== n (0 :: Integer)
          && num "stale_worker_refusals" value .== n (0 :: Integer)
          && l.failed == l.firingsFailed
          && l.firingsFailed == 0
   in result
        passed
        [ ("accepted_begins", int acceptedBegins)
        , ("accepted_projections", int acceptedProjections)
        , ("accepted_terminals", int acceptedTerminals)
        , ("attempts_exact", Bool attemptsExact)
        , ("canonical_resets", int l.canonicalResets)
        , ("lifecycle_exact", Bool lifecycleExact)
        , ("reset_refusals", member "reset_refusals" value)
        , ("task_state", taskState l.tasks)
        , ("worker_completions", member "worker_completions" value)
        ]

resetRefusalAuthorityChecker :: Checker
resetRefusalAuthorityChecker =
  checker Id.resetRefusalCheckerIdentity "engine.joined-reset-refusal-authority" resetRefusalCheck

acceptedCancellationLifecycle :: Json
acceptedCancellationLifecycle = lifecycle True "cancellation" []

-- | @JoinedAcceptedResetAuthorityChecker@.
acceptedResetCheck :: Json -> CheckResult
acceptedResetCheck value =
  let attempts = list "transaction_attempts" value
      lifecycleAttempts = list "lifecycle_attempts" value
      l = lifecycleFacts value
      attemptsExact = prefixOf attempts [sourceAcceptance, sourceCompletion, begin]
      acceptedReset = lifecycle True "scope_reset" ["ScopeReset"]
      lifecycleExact = oneOf lifecycleAttempts [[], [acceptedReset], [acceptedReset, acceptedCancellationLifecycle]]
      acceptedBegins = countJ begin attempts
      acceptedResets = countJ acceptedReset lifecycleAttempts
      acceptedCancellations = countJ acceptedCancellationLifecycle lifecycleAttempts
      workerClaims = num "worker_claims" value
      expectedTasks =
        custody
          [ (acceptedCancellations /= 0, "cancelled")
          , (maybe False (/= 0) workerClaims, "running")
          , (acceptedBegins /= 0, "pending")
          ]
      ackLosses = num "reset_ack_losses" value
      staleRefusals = num "stale_worker_refusals" value
      passed =
        attemptsExact
          && lifecycleExact
          && openedAndSourced value l
          && eqs [n l.canonicalResets, num "scope_resets" value, n acceptedResets]
          && acceptedResets <= 1
          && l.requested == acceptedBegins
          && acceptedBegins <= 1
          && num "prepare_calls" value .== n acceptedBegins
          && eqList l.tasks expectedTasks
          && les [n (0 :: Integer), workerClaims, n acceptedBegins]
          && les [n (0 :: Integer), ackLosses, n acceptedResets]
          && acceptedCancellations <= acceptedResets
          && les [n (0 :: Integer), staleRefusals, n acceptedCancellations]
          && num "reset_refusals" value .== n (0 :: Integer)
          && num "cancellation_refusals" value .== n (0 :: Integer)
          && l.completed == l.projected
          && l.projected == 0
          && l.failed == l.firingsFailed
          && l.firingsFailed == 0
   in result
        passed
        [ ("accepted_begins", int acceptedBegins)
        , ("accepted_cancellations", int acceptedCancellations)
        , ("accepted_resets", int acceptedResets)
        , ("ack_losses", member "reset_ack_losses" value)
        , ("attempts_exact", Bool attemptsExact)
        , ("canonical_resets", int l.canonicalResets)
        , ("lifecycle_exact", Bool lifecycleExact)
        , ("stale_worker_refusals", member "stale_worker_refusals" value)
        , ("task_state", taskState l.tasks)
        ]

acceptedResetAuthorityChecker :: Checker
acceptedResetAuthorityChecker =
  checker Id.resetAckLossCheckerIdentity "engine.joined-accepted-reset-authority" acceptedResetCheck

-- | @_close_as_reset_observation@ (over the observation's value).
closeAsReset :: Json -> Json
closeAsReset = \case
  Object members ->
    let rename = \case
          String "ScopeClosed" -> String "ScopeReset"
          other -> other
        attempt = \case
          Object ms ->
            Object
              [ ( k
                , case k of
                    "phase" -> if v == String "scope_close" then String "scope_reset" else v
                    "record_types" -> Array (map rename (listOf v))
                    _ -> v
                )
              | (k, v) <- ms
              ]
          other -> other
        rewritten =
          [ ( k
            , case k of
                "record_types" -> Array (map rename (listOf v))
                "lifecycle_attempts" -> Array (map attempt (listOf v))
                _ -> v
            )
          | (k, v) <- members
          ]
        get k = maybe Null id (lookup k members)
        overrides =
          [("scope_resets", get "scope_closes"), ("reset_refusals", get "close_refusals")]
            <> [("reset_ack_losses", v) | Just v <- [lookup "close_ack_losses" members]]
     in Object ([(k, v) | (k, v) <- rewritten, k `notElem` map fst overrides] <> overrides)
  other -> other

-- | @JoinedCloseRefusalAuthorityChecker@.
closeRefusalAuthorityChecker :: Checker
closeRefusalAuthorityChecker =
  checker Id.closeRefusalCheckerIdentity "engine.joined-close-refusal-authority" $
    renameDetail [("canonical_resets", "canonical_closes"), ("reset_refusals", "close_refusals")]
      . resetRefusalCheck
      . closeAsReset

-- | @JoinedAcceptedCloseAuthorityChecker@.
acceptedCloseAuthorityChecker :: Checker
acceptedCloseAuthorityChecker =
  checker Id.closeAckLossCheckerIdentity "engine.joined-accepted-close-authority" $
    renameDetail [("accepted_resets", "accepted_closes"), ("canonical_resets", "canonical_closes")]
      . acceptedResetCheck
      . closeAsReset

-- | @JoinedOpenAuthorityChecker@.
openAuthorityChecker :: Checker
openAuthorityChecker = checker Id.openCheckerIdentity "engine.joined-open-authority" $ \value ->
  let attempts = list "lifecycle_attempts" value
      refusedAttempt = lifecycle False "scope_open" ["ScopeOpened"]
      acceptedAttempt = lifecycle True "scope_open" ["ScopeOpened"]
      attemptsExact = oneOf attempts [[], [refusedAttempt], [refusedAttempt, acceptedAttempt], [acceptedAttempt]]
      accepted = countJ acceptedAttempt attempts
      refused = countJ refusedAttempt attempts
      canonical = list "canonical_scopes" value
      active = member "active_scopes" value
      expected = [Object [("generation", Int 1), ("name", String "draft")] | accepted /= 0]
      expectedActive = Object [("draft", Int 1) | accepted /= 0]
      ackLosses = num "open_ack_losses" value
      liveCoherent =
        pyEq active expectedActive
          || (active == Null && num "drops" value .== n (0 :: Integer) && num "scope_opens" value .== n (1 :: Integer))
      passed =
        attemptsExact
          && accepted <= 1
          && n refused .== num "open_refusals" value
          && num "open_refusals" value .<= n (1 :: Integer)
          && ackLosses .<= n accepted
          && num "scope_opens" value .== n (length attempts)
          && eqList canonical expected
          && count "ScopeOpened" (list "record_types" value) == accepted
          && num "frontier" value .== n (2 + accepted)
          && liveCoherent
   in result
        passed
        [ ("accepted_opens", int accepted)
        , ("ack_losses", member "open_ack_losses" value)
        , ("active_scopes", active)
        , ("attempts_exact", Bool attemptsExact)
        , ("canonical_scopes", Array canonical)
        , ("live_coherent", Bool liveCoherent)
        , ("refused_opens", int refused)
        ]

-- | @JoinedCancellationAuthorityChecker@ and
-- @JoinedAcceptedCancellationAuthorityChecker@.
checkCancellation :: Bool -> Json -> CheckResult
checkCancellation acknowledgementLoss value =
  let attempts = list "transaction_attempts" value
      lifecycleAttempts = list "lifecycle_attempts" value
      l = lifecycleFacts value
      attemptsExact =
        oneOf
          attempts
          [[], [sourceAcceptance], [sourceAcceptance, sourceCompletion], [sourceAcceptance, sourceCompletion, begin]]
      acceptedBegins = countJ begin attempts
      scopeResets = num "scope_resets" value
      resetsTruthy = truthy (member "scope_resets" value)
      refusedCancellation = lifecycle False "cancellation" []
      acceptedCancellations = countJ acceptedCancellationLifecycle lifecycleAttempts
      acceptedResetLifecycle = lifecycle True "scope_reset" ["ScopeReset"]
      expectedLifecycle
        | acknowledgementLoss = if resetsTruthy then [acceptedResetLifecycle, acceptedCancellationLifecycle] else []
        | otherwise =
            (if resetsTruthy then [acceptedResetLifecycle, refusedCancellation] else [])
              <> [acceptedCancellationLifecycle | acceptedCancellations /= 0]
      lifecycleExact = eqList lifecycleAttempts expectedLifecycle
      workerClaims = num "worker_claims" value
      expectedTasks =
        custody
          [ (acceptedCancellations /= 0, "cancelled")
          , (maybe False (/= 0) workerClaims, "running")
          , (acceptedBegins /= 0, "pending")
          ]
      staleRefusals = num "stale_worker_refusals" value
      cancellationRefusals = num "cancellation_refusals" value
      ackLosses = num "cancellation_ack_losses" value
      variant
        | acknowledgementLoss =
            cancellationRefusals .== n (0 :: Integer)
              && les [n (0 :: Integer), ackLosses, n acceptedCancellations]
        | otherwise = cancellationRefusals .== n (countJ refusedCancellation lifecycleAttempts)
      passed =
        attemptsExact
          && lifecycleExact
          && openedAndSourced value l
          && n l.canonicalResets .== scopeResets
          && scopeResets .<= n (1 :: Integer)
          && l.requested == acceptedBegins
          && acceptedBegins <= 1
          && num "prepare_calls" value .== n acceptedBegins
          && eqList l.tasks expectedTasks
          && les [n (0 :: Integer), workerClaims, n acceptedBegins]
          && variant
          && les [n (0 :: Integer), n acceptedCancellations, scopeResets]
          && les [n (0 :: Integer), staleRefusals, n acceptedCancellations]
          && l.completed == l.projected
          && l.projected == 0
   in result
        passed
        ( [ ("accepted_begins", int acceptedBegins)
          , ("accepted_cancellations", int acceptedCancellations)
          , ("attempts_exact", Bool attemptsExact)
          , ("canonical_resets", int l.canonicalResets)
          , ("lifecycle_exact", Bool lifecycleExact)
          , ("stale_worker_refusals", member "stale_worker_refusals" value)
          , ("task_state", taskState l.tasks)
          ]
            <> if acknowledgementLoss
              then [("ack_losses", member "cancellation_ack_losses" value)]
              else [("cancellation_refusals", member "cancellation_refusals" value)]
        )

cancellationAuthorityChecker :: Checker
cancellationAuthorityChecker =
  checker Id.cancellationCheckerIdentity "engine.joined-cancellation-authority" (checkCancellation False)

acceptedCancellationAuthorityChecker :: Checker
acceptedCancellationAuthorityChecker =
  checker Id.cancellationAckLossCheckerIdentity "engine.joined-accepted-cancellation-authority" (checkCancellation True)

-- ---------------------------------------------------------------------------
-- joined_registration_world.py and joined_seal_world.py

registration :: Text -> Text -> Json -> Json
registration key kind occurrence =
  Object [("key", String key), ("kind", String kind), ("occurrence", occurrence), ("source", String "source")]

armed :: Text -> Json
armed key = Object [("key", String key), ("source", String "source")]

-- | @JoinedRegistrationProjectionAuthorityChecker@.
registrationProjectionAuthorityChecker :: Checker
registrationProjectionAuthorityChecker =
  checker Id.registrationCheckerIdentity "engine.joined-registration-projection-authority" $ \value ->
    let records = list "record_types" value
        attempts = list "transaction_attempts" value
        projectionBatch = ["TokensProduced", "DeliveryRegistrationClosed", "DeliveryRegistrationOpened", "FiringCompleted"]
        refusedProjectionTx = transaction False False projectionBatch
        acceptedProjectionTx = transaction True False projectionBatch
        attemptsExact =
          oneOf
            attempts
            [ []
            , [begin]
            , [begin, terminalTx True, refusedProjectionTx]
            , [begin, terminalTx True, refusedProjectionTx, acceptedProjectionTx]
            , [begin, terminalTx True, acceptedProjectionTx]
            ]
        acceptedBegin = countJ begin attempts
        acceptedTerminal = countJ (terminalTx True) attempts
        acceptedProjection = countJ acceptedProjectionTx attempts
        refusedProjection = countJ refusedProjectionTx attempts
        expectedRecords =
          ["InstanceCreated", "TokensInitialized", "DeliveryRegistrationOpened"]
            <> (if acceptedBegin /= 0 then beginBatch else [])
            <> ["ActivityCompleted" | acceptedTerminal /= 0]
            <> (if acceptedProjection /= 0 then projectionBatch else [])
        expectedRegistrations =
          [registration "default" "opened" Null]
            <> ( if acceptedProjection /= 0
                  then [registration "default" "closed" (Int 1), registration "replacement" "opened" (Int 1)]
                  else []
               )
        expectedArmed = Array [armed (if acceptedProjection /= 0 then "replacement" else "default")]
        status = member "status" value
        engineArmed = member "engine_armed" value
        engineCoherent =
          (status == String "poisoned" && engineArmed == Null)
            || (status /= String "poisoned" && pyEq engineArmed expectedArmed)
        tasks = list "durable_tasks" value
        workerCompletions = num "worker_completions" value
        tasksExact = null tasks || oneOf tasks (taskStates ["pending", "running", "completed"])
        completedCustody = eqList tasks [task joinedInstance 1 "completed"]
        ackLosses = num "projection_ack_losses" value
        refusals = num "projection_refusals" value
        passed =
          attemptsExact
            && eqList records (map String expectedRecords)
            && eqList (list "canonical_registrations" value) expectedRegistrations
            && num "prepare_calls" value .== n acceptedBegin
            && acceptedBegin == len tasks
            && len tasks <= 1
            && les [n acceptedTerminal, workerCompletions, n (1 :: Integer)]
            && acceptedProjection <= acceptedTerminal
            && n refusedProjection .== refusals
            && refusals .<= n (1 :: Integer)
            && les [n (0 :: Integer), ackLosses, n acceptedProjection, n (1 :: Integer)]
            && not (refusedProjection /= 0 && truthy (member "projection_ack_losses" value))
            && completedCustody == (workerCompletions .== n (1 :: Integer))
            && tasksExact
            && engineCoherent
     in result
          passed
          [ ("accepted_projections", int acceptedProjection)
          , ("ack_losses", member "projection_ack_losses" value)
          , ("attempts_exact", Bool attemptsExact)
          , ("canonical_registrations", member "canonical_registrations" value)
          , ("engine_coherent", Bool engineCoherent)
          , ("refused_projections", int refusedProjection)
          , ("tasks_exact", Bool tasksExact)
          ]

-- | @JoinedSealAuthorityChecker@.
sealAuthorityChecker :: Checker
sealAuthorityChecker = checker Id.sealCheckerIdentity "engine.joined-seal-authority" $ \value ->
  let attempts = list "transaction_attempts" value
      lifecycleAttempts = list "lifecycle_attempts" value
      projectionBatch = ["TokensProduced", "DeliveryRegistrationOpened", "FiringCompleted"]
      projection = transaction True False projectionBatch
      attemptsExact = prefixOf attempts [begin, terminalTx True, projection]
      sealBatch = ["DeliveryRegistrationClosed", "DeliveryRegistrationClosed"]
      refusedSeal = lifecycle False "source_seal" sealBatch
      acceptedSeal = lifecycle True "source_seal" sealBatch
      lifecycleExact = oneOf lifecycleAttempts [[], [refusedSeal], [refusedSeal, acceptedSeal], [acceptedSeal]]
      acceptedBegin = countJ begin attempts
      acceptedTerminal = countJ (terminalTx True) attempts
      acceptedProjection = countJ projection attempts
      acceptedSeals = countJ acceptedSeal lifecycleAttempts
      refusedSeals = countJ refusedSeal lifecycleAttempts
      expectedRecords =
        ["InstanceCreated", "TokensInitialized", "DeliveryRegistrationOpened"]
          <> (if acceptedBegin /= 0 then beginBatch else [])
          <> ["ActivityCompleted" | acceptedTerminal /= 0]
          <> (if acceptedProjection /= 0 then projectionBatch else [])
          <> (if acceptedSeals /= 0 then sealBatch else [])
      expectedRegistrations =
        [registration "default" "opened" Null]
          <> [registration "subscription" "opened" (Int 1) | acceptedProjection /= 0]
          <> ( if acceptedSeals /= 0
                then [registration "default" "closed" Null, registration "subscription" "closed" Null]
                else []
             )
      expectedArmed
        | acceptedSeals /= 0 = Array []
        | otherwise = Array (map armed (["default"] <> ["subscription" | acceptedProjection /= 0]))
      tasks = list "durable_tasks" value
      tasksExact = null tasks || oneOf tasks (taskStates ["pending", "running", "completed"])
      completedCustody = eqList tasks [task joinedInstance 1 "completed"]
      workerCompletions = num "worker_completions" value
      status = member "status" value
      engineArmed = member "engine_armed" value
      expectedStatus
        | acceptedSeals /= 0 = "terminated"
        | acceptedProjection /= 0 = "awaiting"
        | otherwise = "running"
      engineCoherent =
        (status == String "poisoned" && engineArmed == Null)
          || (status == String expectedStatus && pyEq engineArmed expectedArmed)
      terminalCoherent = status `elem` [String "poisoned", String expectedStatus]
      sealAckLosses = num "seal_ack_losses" value
      sealRefusals = num "seal_refusals" value
      passed =
        attemptsExact
          && lifecycleExact
          && eqList (list "record_types" value) (map String expectedRecords)
          && eqList (list "canonical_registrations" value) expectedRegistrations
          && num "frontier" value .== n (length expectedRecords)
          && num "prepare_calls" value .== n acceptedBegin
          && acceptedBegin == len tasks
          && len tasks <= 1
          && les [n acceptedTerminal, workerCompletions, n (1 :: Integer)]
          && acceptedProjection <= acceptedTerminal
          && acceptedSeals <= acceptedProjection
          && num "seal_calls" value .== n (length lifecycleAttempts)
          && n refusedSeals .== sealRefusals
          && sealRefusals .<= n (1 :: Integer)
          && les [n (0 :: Integer), sealAckLosses, n acceptedSeals, n (1 :: Integer)]
          && not (refusedSeals /= 0 && truthy (member "seal_ack_losses" value))
          && completedCustody == (workerCompletions .== n (1 :: Integer))
          && tasksExact
          && engineCoherent
          && terminalCoherent
   in result
        passed
        [ ("accepted_seals", int acceptedSeals)
        , ("ack_losses", member "seal_ack_losses" value)
        , ("attempts_exact", Bool attemptsExact)
        , ("canonical_registrations", member "canonical_registrations" value)
        , ("engine_coherent", Bool engineCoherent)
        , ("lifecycle_exact", Bool lifecycleExact)
        , ("refused_seals", int refusedSeals)
        , ("tasks_exact", Bool tasksExact)
        , ("terminal_coherent", Bool terminalCoherent)
        ]

-- ---------------------------------------------------------------------------
-- joined_creation_world.py

-- | @JoinedCreationAuthorityChecker@ and @JoinedSourceCreationAuthorityChecker@.
checkCreation :: Bool -> Json -> CheckResult
checkCreation sourced value =
  let transactions = list "transaction_attempts" value
      creationAttempts = list "creation_attempts" value
      batch = if sourced then ["InstanceCreated", "DeliveryRegistrationOpened"] else ["InstanceCreated", "TokensInitialized"]
      tx isAccepted = Object [("accepted", Bool isAccepted), ("record_types", strs batch)]
      transactionsExact = oneOf transactions [[], [tx False], [tx False, tx True], [tx True]]
      accepted = len (filter (isTrue . member "accepted") transactions)
      refused = len (filter (isFalse . member "accepted") transactions)
      dispositions = map (member "disposition") creationAttempts
      applied = pyCount (String (actionDispositionText Applied)) dispositions
      reportedRefused = pyCount (String (actionDispositionText RefusedExpected)) dispositions
      commitRefusals = num "commit_refusals" value
      ackLosses = num "commit_ack_losses" value
      canonicalTypes = list "record_types" value
      canonicalInstances = list "canonical_instances" value
      canonicalTokens = list "canonical_tokens" value
      enginePresent = truthy (member "engine_present" value)
      drops = num "drops" value
      expectedTypes = if accepted /= 0 then map String batch else []
      instanceId = if sourced then "dst-world-joined-source-creation" else "dst-world-joined-creation"
      expectedInstances = [String instanceId | accepted /= 0]
      expectedTokens = [Int 1 | accepted /= 0]
      expectedRegistrations =
        [Object [("key", String "default"), ("occurrence", Null), ("source", String "source")] | accepted /= 0]
      expectedArmed = [armed "default" | accepted /= 0]
      present
        | sourced =
            eqList (list "engine_record_types" value) expectedTypes
              && eqList (list "engine_armed" value) expectedArmed
              && member "engine_status" value == String "awaiting"
        | otherwise =
            eqList (list "engine_record_types" value) expectedTypes
              && eqList (list "engine_tokens" value) expectedTokens
      engineCoherent =
        (not enginePresent && accepted == 0)
          || (not enginePresent && ackLosses .== n (1 :: Integer) && drops .== n (0 :: Integer))
          || (enginePresent && present)
      canonicalExtra
        | sourced =
            eqList (list "canonical_registrations" value) expectedRegistrations
              && eqList canonicalTokens []
        | otherwise = eqList canonicalTokens expectedTokens
      passed =
        transactionsExact
          && length transactions == length creationAttempts
          && n accepted .== plus (n applied) ackLosses
          && accepted <= 1
          && n refused .== commitRefusals
          && commitRefusals .<= n (1 :: Integer)
          && n reportedRefused .== plus commitRefusals ackLosses
          && plus commitRefusals ackLosses .<= n (1 :: Integer)
          && eqList canonicalTypes expectedTypes
          && eqList canonicalInstances expectedInstances
          && canonicalExtra
          && num "frontier" value .== n (length expectedTypes)
          && engineCoherent
   in result
        passed
        ( [ ("accepted_transactions", int accepted)
          , ("ack_losses", member "commit_ack_losses" value)
          , ("commit_refusals", member "commit_refusals" value)
          , ("engine_coherent", Bool engineCoherent)
          , ("refused_transactions", int refused)
          , ("transactions_exact", Bool transactionsExact)
          ]
            <> if sourced
              then [("canonical_registrations", member "canonical_registrations" value)]
              else [("canonical_instances", Array canonicalInstances)]
        )

creationAuthorityChecker :: Checker
creationAuthorityChecker =
  checker Id.creationCheckerIdentity "engine.joined-creation-authority" (checkCreation False)

sourceCreationAuthorityChecker :: Checker
sourceCreationAuthorityChecker =
  checker Id.creationSourceCheckerIdentity "engine.joined-source-creation-authority" (checkCreation True)

-- | Every joined checker, for the replay registries and checker vectors.
joinedCheckers :: [Checker]
joinedCheckers =
  [ commitAuthorityChecker
  , deliveryAuthorityChecker
  , scopedDropAuthorityChecker
  , acceptedScopedDropAuthorityChecker
  , scopedQuarantineAuthorityChecker
  , acceptedScopedQuarantineAuthorityChecker
  , projectionAuthorityChecker
  , acceptedProjectionAuthorityChecker
  , terminalAuthorityChecker
  , failureAuthorityChecker
  , acceptedFailureAuthorityChecker
  , failureProjectionAuthorityChecker
  , acceptedFailureProjectionAuthorityChecker
  , acceptedTerminalAuthorityChecker
  , acceptedBeginAuthorityChecker
  , resetRefusalAuthorityChecker
  , acceptedResetAuthorityChecker
  , closeRefusalAuthorityChecker
  , acceptedCloseAuthorityChecker
  , openAuthorityChecker
  , cancellationAuthorityChecker
  , acceptedCancellationAuthorityChecker
  , registrationProjectionAuthorityChecker
  , sealAuthorityChecker
  , creationAuthorityChecker
  , sourceCreationAuthorityChecker
  ]

-- | Instance firing values and the occurrence-lifecycle replay folds
-- (@petrus.impetus.instance.firing@).
--
-- A firing is a durable /occurrence/: @begin@ accounts the binding's input
-- tokens (which is what keeps duplicate workers off one consumed token) and
-- @complete@ commits the successful outcome; terminal failure moves no
-- tokens. Between the two an execution runtime runs the handler however it
-- likes. Both halves are history-independent marking transforms in
-- "Petrus.Impetus.Petrinet.Firing"; this module holds the Instance-owned
-- occurrence values and the folds that rebuild them from History.
--
-- Every fold validates the orderings the single writer guarantees and
-- refuses any other shape as @replay divergence@, with the reference's
-- message.
module Petrus.Impetus.Instance.Firing
  ( -- * Values
    FiringOccurrence (..)
  , FiringOutcome (..)
  , TerminalOutcome (..)
  , Scheduler
  , selectConservative
  , terminalFailure
    -- * Replay folds
  , replayInFlight
  , replayFiringOccurrences
  , replayProjectionPending
  , replayTerminalActivity
  , replayQuarantinedActivity
  , replayCancelled
  , replayActivityOccurrences
  ) where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Foldable (toList)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet (IntSet)
import Data.IntSet qualified as IntSet
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Petrus.Activity
import Petrus.Impetus.History.Records
import Petrus.Impetus.Internal.OMap (OMap)
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Internal.Repr
import Petrus.Impetus.Petrinet.Enabledness (Binding (..))
import Petrus.Impetus.Petrinet.Marking (Token)
import Petrus.Impetus.Petrinet.Schema (Instant, NetPath, netPathText)
import Petrus.Impetus.Scope (LifecycleScope)
import Petrus.Json (Json)

-- | A durable firing occurrence: a binding whose begin has been recorded and
-- whose end has not. @records@ is the begin batch after the initiation
-- record; @invocation@ is the frozen Activity request ('Nothing' spells a
-- pure occurrence). In-flight occurrences are a projection of History.
data FiringOccurrence = FiringOccurrence
  { occurrence :: Int
  , binding :: Binding
  , records :: [Record]
  , invocation :: Maybe ActivityInvocation
  , scope :: Maybe LifecycleScope
  }
  deriving stock (Eq, Show)

-- | The outcome of one completed firing: what fired under which occurrence,
-- the tokens it consumed and produced, and the firing's lifecycle records
-- (the initiation record is the initiating site's and is not included).
data FiringOutcome = FiringOutcome
  { transition :: NetPath
  , occurrence :: Int
  , consumed :: [Token]
  , produced :: [(NetPath, Token)]
  , records :: [Record]
  }
  deriving stock (Eq, Show)

-- | A frozen terminal Activity fact: a JSON result, or a classified failure.
data TerminalOutcome = TerminalResult Json | TerminalFailure ActivityFailure
  deriving stock (Eq, Show)

-- | A scheduler policy: choose which enabled candidate begins firing now, or
-- 'Nothing' to decline.
type Scheduler = [Binding] -> Maybe Binding

-- | Conservative deterministic single-step: the first binding.
selectConservative :: Scheduler
selectConservative = \case
  [] -> Nothing
  b : _ -> Just b

-- | The failure an @ActivityFailed@ record spells.
terminalFailure :: ActivityFailed -> Either Text TerminalOutcome
terminalFailure r =
  TerminalFailure <$> activityFailure (ActivityFailureFields r.error r.kind r.details r.retryable r.retryAfter)

-- ---------------------------------------------------------------------------
-- Sorting the lifecycle

data Lifecycle = Lifecycle
  { initiated :: IntMap (NetPath, [Token])
  , begun :: IntMap [Record]
  -- ^ Begin records per occurrence, newest first.
  , begunOrder :: [Int]
  -- ^ Begin order, newest first.
  , ended :: IntSet
  , ending :: IntSet
  , frozen :: IntMap TerminalOutcome
  , scopedOpen :: OMap Int LifecycleScope
  , lifecycleCancelled :: IntSet
  , activeBegin :: Maybe (Int, Instant)
  , previous :: Maybe Record
  }

emptyLifecycle :: Lifecycle
emptyLifecycle = Lifecycle IntMap.empty IntMap.empty [] IntSet.empty IntSet.empty IntMap.empty OMap.empty IntSet.empty Nothing Nothing

divergence :: Text -> Either Text a
divergence message = Left ("replay divergence: " <> message)

occ :: Int -> Text
occ = pyInt

requestedIn :: Lifecycle -> Int -> Bool
requestedIn l o = any isRequest (IntMap.findWithDefault [] o l.begun)
  where
    isRequest = \case
      RActivityRequested _ -> True
      _ -> False

begunTransition :: Lifecycle -> Int -> Maybe NetPath
begunTransition l o = case reverse (IntMap.findWithDefault [] o l.begun) of
  RFiringBegun b : _ -> Just b.transition
  _ -> Nothing

-- | Step 1 of every fold: sort records into the lifecycle buckets, refusing
-- every ordering the single writer cannot produce.
sortedLifecycle :: Foldable f => f Record -> Either Text Lifecycle
sortedLifecycle = fmap finish . foldM step emptyLifecycle . toList
  where
    finish l = l
    step l0 record = do
      let l = case record of
            RTokensConsumed _ -> l0
            RTokensRead _ -> l0
            RActivityRequested _ -> l0
            _ -> l0 {activeBegin = Nothing}
      l' <- visit l record
      Right l' {previous = Just record}
    visit l = \case
      RCandidateSelected r -> initiate l r.occurrence r.transition r.transition []
      RExternalEventDelivered r -> initiate l r.occurrence r.source r.source r.tokens
      RFiringBegun r -> do
        unless (IntMap.member r.occurrence l.initiated) $
          divergence
            ( "firing occurrence " <> occ r.occurrence <> " (" <> netPathText r.transition
                <> ") begun with no initiation record"
            )
        when (IntMap.member r.occurrence l.begun) $
          divergence ("firing occurrence " <> occ r.occurrence <> " has more than one FiringBegun record")
        previousInstant <- case l.previous of
          Just (RCandidateSelected p) | p.occurrence == r.occurrence -> Right p.instant
          Just (RExternalEventDelivered p) | p.occurrence == r.occurrence -> Right p.instant
          _ ->
            divergence
              ( "FiringBegun for occurrence " <> occ r.occurrence
                  <> " does not immediately follow its initiation in the contiguous begin batch"
              )
        when (previousInstant /= r.instant) $
          divergence
            ( "FiringBegun for occurrence " <> occ r.occurrence <> " has instant " <> pyInt r.instant
                <> ", not its initiation instant "
                <> pyInt previousInstant
            )
        Right
          l
            { begun = IntMap.insert r.occurrence [RFiringBegun r] l.begun
            , begunOrder = r.occurrence : l.begunOrder
            , activeBegin = Just (r.occurrence, r.instant)
            , scopedOpen = maybe l.scopedOpen (\s -> OMap.insert r.occurrence s l.scopedOpen) r.scope
            }
      RTokensConsumed r -> beginTail l (RTokensConsumed r) r.occurrence r.instant (Just ("consumed", r.place))
      RTokensRead r -> beginTail l (RTokensRead r) r.occurrence r.instant (Just ("read", r.place))
      RActivityRequested r -> do
        unless (IntMap.member r.occurrence l.begun) $
          divergence
            ( "activity " <> pyStr r.activity <> " requested for firing occurrence " <> occ r.occurrence
                <> " with no begun boundary — the request joins the begin batch"
            )
        activityTransition l "ActivityRequested" r.transition r.occurrence
        when (requestedIn l r.occurrence) $
          divergence
            ( "firing occurrence " <> occ r.occurrence <> " (" <> netPathText r.transition
                <> ") requested a second activity — one impure handler maps to exactly one activity"
            )
        refuseLate l "ActivityRequested" r.occurrence
        positioned l "ActivityRequested" r.occurrence r.instant
        Right l {begun = IntMap.adjust (RActivityRequested r :) r.occurrence l.begun}
      RActivityCompleted r -> do
        unless (requestedIn l r.occurrence) $
          divergence
            ( "activity completed for firing occurrence " <> occ r.occurrence <> " (" <> netPathText r.transition
                <> ") but no activity was requested in its begin batch"
            )
        activityTransition l "ActivityCompleted" r.transition r.occurrence
        when (IntMap.member r.occurrence l.frozen) $
          divergence
            ( "a second terminal activity fact for firing occurrence " <> occ r.occurrence <> " ("
                <> netPathText r.transition
                <> ") — the first one wins, the writer appends no second"
            )
        when (IntSet.member r.occurrence l.lifecycleCancelled) $
          divergence
            ( "activity completed for lifecycle-cancelled firing occurrence " <> occ r.occurrence <> " ("
                <> netPathText r.transition
                <> ") — late terminal reports are quarantined"
            )
        Right l {frozen = IntMap.insert r.occurrence (TerminalResult r.result) l.frozen}
      RActivityFailed r -> do
        unless (requestedIn l r.occurrence) $
          divergence
            ( "activity failed for firing occurrence " <> occ r.occurrence <> " (" <> netPathText r.transition
                <> ") but no activity was requested in its begin batch"
            )
        activityTransition l "ActivityFailed" r.transition r.occurrence
        when (IntMap.member r.occurrence l.frozen) $
          divergence
            ( "a second terminal activity fact for firing occurrence " <> occ r.occurrence <> " ("
                <> netPathText r.transition
                <> ")"
            )
        when (IntSet.member r.occurrence l.lifecycleCancelled) $
          divergence
            ( "activity failed for lifecycle-cancelled firing occurrence " <> occ r.occurrence <> " ("
                <> netPathText r.transition
                <> ") — late terminal reports are quarantined"
            )
        failure <- terminalFailure r
        Right l {frozen = IntMap.insert r.occurrence failure l.frozen}
      RActivityTerminalQuarantined r -> do
        unless (IntMap.member r.occurrence l.begun) $
          divergence
            ("terminal quarantined for firing occurrence " <> occ r.occurrence <> " with no begun boundary")
        activityTransition l "ActivityTerminalQuarantined" r.transition r.occurrence
        Right l
      RScopeClosed r -> closeScope l r.scope r.cancelled
      RScopeReset r -> closeScope l r.closed r.cancelled
      RTokensProduced r -> Right l {ending = IntSet.insert r.occurrence l.ending}
      RDeliveryRegistrationOpened r -> Right (endingOptional l r.occurrence)
      RDeliveryRegistrationClosed r -> Right (endingOptional l r.occurrence)
      RFiringCompleted r -> terminal l "FiringCompleted" r.transition r.occurrence
      RFiringFailed r -> terminal l "FiringFailed" r.transition r.occurrence
      _ -> Right l
    initiate l o path _ delivered = do
      forM_ (IntMap.lookup o l.initiated) $ \(prior, _) ->
        divergence
          ( "firing occurrence " <> occ o <> " initiated more than once (" <> netPathText prior <> " then "
              <> netPathText path
              <> ")"
          )
      Right l {initiated = IntMap.insert o (path, delivered) l.initiated}
    beginTail l record o instant (Just (verb, place)) = do
      unless (IntMap.member o l.begun) $
        divergence
          ( "tokens " <> verb <> " from " <> netPathText place <> " for firing occurrence " <> occ o
              <> " with no begun boundary"
          )
      refuseLate l (recordName record) o
      positioned l (recordName record) o instant
      Right l {begun = IntMap.adjust (record :) o l.begun}
    beginTail l _ _ _ Nothing = Right l
    refuseLate l name o = do
      when (IntSet.member o l.ended) $
        divergence (name <> " for firing occurrence " <> occ o <> " appears after its terminal boundary")
      when (IntSet.member o l.ending) $
        divergence (name <> " for firing occurrence " <> occ o <> " appears after completion began")
    positioned l name o instant = case l.activeBegin of
      Just (active, activeInstant)
        | active == o ->
            when (instant /= activeInstant) $
              divergence
                ( name <> " for firing occurrence " <> occ o <> " has instant " <> pyInt instant
                    <> ", not its begin batch instant "
                    <> pyInt activeInstant
                )
      _ -> divergence (name <> " for firing occurrence " <> occ o <> " does not belong to its contiguous begin batch")
    activityTransition l name t o = forM_ (begunTransition l o) $ \boundary ->
      when (t /= boundary) $
        divergence
          ( name <> " transition " <> netPathText t <> " for firing occurrence " <> occ o
              <> " does not match begun transition "
              <> netPathText boundary
          )
    closeScope l scope cancelled = do
      let expected = [o | (o, provenance) <- OMap.toList l.scopedOpen, provenance == scope]
      when (cancelled /= expected) $
        divergence
          ( "lifecycle close for " <> reprScope scope <> " cancels " <> pyTuple (map occ cancelled)
              <> ", but the exact open occurrence set at this append position is "
              <> pyTuple (map occ expected)
          )
      let pending = [o | o <- expected, IntMap.member o l.frozen]
      unless (null pending) $
        divergence
          ( "lifecycle close for " <> reprScope scope <> " cancels accepted Activity terminal(s) "
              <> pyTuple (map occ pending)
              <> " still awaiting deterministic projection"
          )
      Right
        l
          { scopedOpen = foldr OMap.delete l.scopedOpen expected
          , lifecycleCancelled = foldr IntSet.insert l.lifecycleCancelled expected
          , ended = foldr IntSet.insert l.ended expected
          }
    endingOptional l = maybe l (\o -> l {ending = IntSet.insert o l.ending})
    terminal l name t o = do
      boundary <- case begunTransition l o of
        Just b -> Right b
        Nothing -> divergence ("firing occurrence " <> occ o <> " reached " <> name <> " with no begun boundary")
      when (t /= boundary) $
        divergence
          ( "firing occurrence " <> occ o <> " terminal transition " <> netPathText t
              <> " does not match begun transition "
              <> netPathText boundary
          )
      when (IntSet.member o l.lifecycleCancelled) $
        divergence ("firing occurrence " <> occ o <> " reached " <> name <> " after lifecycle cancellation")
      when (IntSet.member o l.ended) $
        divergence ("firing occurrence " <> occ o <> " has more than one firing terminal")
      Right l {scopedOpen = OMap.delete o l.scopedOpen, ended = IntSet.insert o l.ended}

-- | Begin records of an occurrence, oldest first.
begunRecords :: Lifecycle -> Int -> [Record]
begunRecords l o = reverse (IntMap.findWithDefault [] o l.begun)

begunInOrder :: Lifecycle -> [Int]
begunInOrder l = reverse l.begunOrder

-- | Step 3b: an open occurrence's begin records carry the writer's batch
-- order: boundary, consumes, reads, at most one request.
refuseDisorderedBeginBatch :: Int -> NetPath -> [Record] -> Either Text ()
refuseDisorderedBeginBatch o t records = do
  let ranks = mapMaybe rank records
  when (ranks /= sort ranks) $
    divergence
      ( "firing occurrence " <> occ o <> " (" <> netPathText t
          <> ") carries a disordered begin batch — the live writer accounts consumes, then reads, then freezes at most one activity request"
      )
  where
    rank :: Record -> Maybe Int
    rank = \case
      RFiringBegun _ -> Just 0
      RTokensConsumed _ -> Just 1
      RTokensRead _ -> Just 2
      RActivityRequested _ -> Just 3
      _ -> Nothing

-- | Step 3: an open occurrence with end records is a torn commit batch.
refuseTornBatch :: Int -> NetPath -> IntSet -> Either Text ()
refuseTornBatch o t ending =
  when (IntSet.member o ending) $
    divergence
      ( "firing occurrence " <> occ o <> " (" <> netPathText t
          <> ") carries end records with no terminal boundary — a torn commit batch"
      )

-- | Step 4: rebuild one occurrence from its own records.
rebuiltOccurrence :: Int -> NetPath -> [Token] -> [Record] -> Either Text FiringOccurrence
rebuiltOccurrence o t delivered records = do
  let consumed = [(r.place, r.tokens) | RTokensConsumed r <- records]
      readSel = [(r.place, r.tokens) | RTokensRead r <- records]
      request = case [r | RActivityRequested r <- records] of
        r : _ ->
          Just (ActivityInvocation r.activity r.input r.policy (Just r.correlation) (Just r.idempotency))
        [] -> Nothing
  begun <- case [r | RFiringBegun r <- records] of
    b : _ -> Right b
    [] -> divergence ("firing occurrence " <> occ o <> " has no FiringBegun record")
  when (begun.transition /= t) $
    divergence
      ( "firing occurrence " <> occ o <> " initiation transition " <> netPathText t
          <> " does not match begun transition "
          <> netPathText begun.transition
      )
  let mismatched =
        [ recordName r
        | r <- records
        , isBeginRecord r
        , recordScope r /= begun.scope
        ]
  unless (null mismatched) $
    divergence
      ( "firing occurrence " <> occ o <> " (" <> netPathText t
          <> ") has scope provenance inconsistent with FiringBegun on "
          <> pyTuple (map pyStr mismatched)
      )
  Right (FiringOccurrence o (Binding t consumed readSel delivered) records request begun.scope)
  where
    isBeginRecord = \case
      RFiringBegun _ -> True
      RTokensConsumed _ -> True
      RTokensRead _ -> True
      RActivityRequested _ -> True
      _ -> False

-- | @replay_in_flight@: the occurrences begun and not ended, in begin order,
-- as values a driver can complete or fail.
replayInFlight :: Foldable f => f Record -> Either Text [FiringOccurrence]
replayInFlight history = do
  l <- sortedLifecycle history
  forM [o | o <- begunInOrder l, not (IntSet.member o l.ended)] $ \o -> do
    let (t, delivered) = l.initiated IntMap.! o
        records = begunRecords l o
    refuseTornBatch o t l.ending
    refuseDisorderedBeginBatch o t records
    rebuiltOccurrence o t delivered records

-- | @replay_firing_occurrences@: the named begun occurrences, ended ones
-- included, for authority validation.
replayFiringOccurrences :: Foldable f => f Record -> IntSet -> Either Text [FiringOccurrence]
replayFiringOccurrences history wanted = do
  l <- sortedLifecycle history
  forM [o | o <- begunInOrder l, IntSet.member o wanted] $ \o -> do
    let (t, delivered) = l.initiated IntMap.! o
        records = begunRecords l o
    unless (IntSet.member o l.ended) $ refuseTornBatch o t l.ending
    refuseDisorderedBeginBatch o t records
    rebuiltOccurrence o t delivered records

-- | @replay_projection_pending@: frozen terminal facts of in-flight
-- occurrences (committed alone by design, so never a torn batch).
replayProjectionPending :: Foldable f => f Record -> Either Text (IntMap TerminalOutcome)
replayProjectionPending history = do
  l <- sortedLifecycle history
  Right (IntMap.filterWithKey (\o _ -> IntMap.member o l.begun && not (IntSet.member o l.ended)) l.frozen)

-- | @replay_terminal_activity@: the terminal-result index of ended impure
-- occurrences.
replayTerminalActivity :: Foldable f => f Record -> Either Text (IntMap TerminalOutcome)
replayTerminalActivity history = do
  (ended, terminal) <- foldM step (IntSet.empty, IntMap.empty) (toList history)
  Right (IntMap.filterWithKey (\o _ -> IntSet.member o ended) terminal)
  where
    step (ended, terminal) = \case
      RFiringCompleted r -> Right (IntSet.insert r.occurrence ended, terminal)
      RFiringFailed r -> Right (IntSet.insert r.occurrence ended, terminal)
      RActivityCompleted r -> fact ended terminal r.occurrence r.transition (TerminalResult r.result)
      RActivityFailed r -> terminalFailure r >>= fact ended terminal r.occurrence r.transition
      _ -> Right (ended, terminal)
    fact ended terminal o t value = do
      when (IntMap.member o terminal) $
        divergence
          ( "a second terminal activity fact for firing occurrence " <> occ o <> " (" <> netPathText t
              <> ") — the first one wins, the writer appends no second"
          )
      when (IntSet.member o ended) $
        divergence
          ( "a terminal activity fact for firing occurrence " <> occ o <> " (" <> netPathText t
              <> ") after its firing ended — the live writer freezes the activity fact before the terminal boundary"
          )
      Right (ended, IntMap.insert o value terminal)

cancellations :: Foldable f => f Record -> Either Text (OMap Int LifecycleScope)
cancellations = foldM step OMap.empty . toList
  where
    step cancelled = \case
      RScopeClosed r -> add cancelled r.scope r.cancelled
      RScopeReset r -> add cancelled r.closed r.cancelled
      _ -> Right cancelled
    add cancelled scope = foldM (\acc o -> if OMap.member o acc then divergence ("firing occurrence " <> occ o <> " cancelled twice") else Right (OMap.insert o scope acc)) cancelled

-- | @replay_quarantined_activity@: the first durable late terminal outcome
-- per lifecycle-cancelled occurrence.
replayQuarantinedActivity :: Foldable f => f Record -> Either Text (IntMap Json)
replayQuarantinedActivity history = snd <$> foldM step (OMap.empty, IntMap.empty) (toList history)
  where
    step (cancelled, quarantined) = \case
      RScopeClosed r -> (,quarantined) <$> add cancelled r.scope r.cancelled
      RScopeReset r -> (,quarantined) <$> add cancelled r.closed r.cancelled
      RActivityTerminalQuarantined r -> do
        when (OMap.lookup r.occurrence cancelled /= Just r.scope) $
          divergence
            ( "terminal quarantined for firing occurrence " <> occ r.occurrence
                <> " outside its lifecycle cancellation"
            )
        when (IntMap.member r.occurrence quarantined) $
          divergence ("a second quarantined terminal for firing occurrence " <> occ r.occurrence)
        Right (cancelled, IntMap.insert r.occurrence r.outcome quarantined)
      _ -> Right (cancelled, quarantined)
    add cancelled scope = foldM (\acc o -> if OMap.member o acc then divergence ("firing occurrence " <> occ o <> " cancelled twice") else Right (OMap.insert o scope acc)) cancelled

-- | @replay_cancelled@: the exact occurrences terminalized by lifecycle
-- close/reset, in cancellation order.
replayCancelled :: Foldable f => f Record -> Either Text [FiringOccurrence]
replayCancelled history = do
  l <- sortedLifecycle history
  cancelled <- cancellations history
  forM (OMap.toList cancelled) $ \(o, scope) -> do
    unless (IntMap.member o l.begun && IntMap.member o l.initiated) $
      divergence ("cancelled firing occurrence " <> occ o <> " was not begun")
    let (t, delivered) = l.initiated IntMap.! o
    rebuilt <- rebuiltOccurrence o t delivered (begunRecords l o)
    when (rebuilt.scope /= Just scope) $
      divergence
        ( "firing occurrence " <> occ o <> " belongs to " <> maybe "None" reprScope rebuilt.scope
            <> ", not closing lifecycle scope "
            <> reprScope scope
        )
    Right rebuilt

-- | @replay_activity_occurrences@: every occurrence carrying an Activity
-- request, ended or live.
replayActivityOccurrences :: Foldable f => f Record -> Either Text [FiringOccurrence]
replayActivityOccurrences history = do
  l <- sortedLifecycle history
  forM [o | o <- begunInOrder l, requestedIn l o] $ \o -> do
    (t, delivered) <- case IntMap.lookup o l.initiated of
      Just found -> Right found
      Nothing -> divergence ("Activity occurrence " <> occ o <> " was not initiated")
    let records = begunRecords l o
    refuseDisorderedBeginBatch o t records
    rebuiltOccurrence o t delivered records


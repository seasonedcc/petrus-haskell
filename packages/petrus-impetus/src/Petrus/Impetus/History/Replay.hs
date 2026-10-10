-- | Replay folds over History (@petrus.impetus.history@, replay half).
--
-- Every projection here is a pure fold over records in append order: the
-- per-place queues (and through them the marking and the entry instants),
-- the clock watermark, the next occurrence and queue identities, the
-- recorded identity fact, the accepted delivery identities, the armed
-- delivery registrations, the lifecycle scopes, and cancellation positions.
-- A trace the single writer could not have written fails loud as
-- @replay divergence@, with the reference's message.
--
-- The reference recomputes the greatest present queue identity by scanning
-- every queue on each deposit; here the queue state carries the set of
-- present identities, so a replay of @n@ movements is @O(n log n)@ instead
-- of quadratic. The observable results are identical.
module Petrus.Impetus.History.Replay
  ( -- * Queues
    Queues
  , emptyQueues
  , queuesByPlace
  , queuesFromPlaces
  , presentIdentities
  , nextPresentIdentity
  , applyMovement
  , replayQueueStates
  , replayQueueProjection
  , replayQueues
  , replayMarkings
  , replayMarking
  , queuesMarking
  , queuesEntryInstants
  , entryInstants
  , replayNextQueueIdentity
    -- * Scalars
  , replayWatermark
  , replayNextOccurrence
  , replayInstanceIdentity
    -- * Deliveries and registrations
  , replayAcceptedIdentities
  , replayArmed
  , validateCorrelatedDeliveryRegistrationBatches
    -- * Lifecycle scopes
  , replayScopes
  , replayCancellationPositions
  ) where

import Control.Monad (foldM, forM_, unless, when)
import Data.Foldable (toList)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet (IntSet)
import Data.IntSet qualified as IntSet
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Petrus.Impetus.History.Records
import Petrus.Impetus.Internal.OMap (OMap)
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Internal.Repr
import Petrus.Impetus.Petrinet.Marking
import Petrus.Impetus.Petrinet.Schema (Instant, NetPath, netPathText)
import Petrus.Impetus.Scope

-- ---------------------------------------------------------------------------
-- Queues

-- | Per-place pair-queues in first-touch order (the reference's dict), plus
-- the set of durable identities currently present in any queue. A place
-- whose queue empties stays present (as in the reference); the marking view
-- drops it.
data Queues = Queues
  { places :: OMap NetPath TokenQueue
  , present :: IntSet
  }

instance Eq Queues where
  a == b = a.places == b.places

instance Show Queues where
  show q = show (OMap.toList q.places)

emptyQueues :: Queues
emptyQueues = Queues OMap.empty IntSet.empty

queuesByPlace :: Queues -> OMap NetPath TokenQueue
queuesByPlace q = q.places

-- | Rebuild the state from per-place queues.
queuesFromPlaces :: OMap NetPath TokenQueue -> Queues
queuesFromPlaces m =
  Queues m (IntSet.fromList [i | q <- OMap.elems m, Just i <- toList (queueIdentities q)])

presentIdentities :: Queues -> IntSet
presentIdentities q = q.present

-- | One past the greatest identity present in any queue.
nextPresentIdentity :: Queues -> Int
nextPresentIdentity q = if IntSet.null q.present then 1 else IntSet.findMax q.present + 1

-- | Apply one record to the queues: the single step of the movement fold,
-- shared by replay and the live instance. A non-movement record applies as
-- nothing — and so does @TokensRead@: reads observe, they never move.
-- @inferred@ supplies the identities of an unscoped deposit (replay passes
-- the spent-identity counter's; without it the next present identity is
-- used, as in the reference).
applyMovement :: Maybe [Int] -> Record -> Queues -> Either Text Queues
applyMovement inferred record qs = case record of
  RTokensInitialized r -> depositAll r.place r.tokens r.entries r.scope r.instant
  RTokensProduced r -> depositAll r.place r.tokens r.entries r.scope r.instant
  RTokensConsumed r -> do
    let queue = OMap.findWithDefault emptyQueue r.place qs.places
    (remaining, removed) <- case removeWithEntries r.tokens r.entries queue of
      Left missing ->
        Left ("replay divergence: cannot consume " <> reprToken missing <> " from " <> netPathText r.place <> ": token not present")
      Right ok -> Right ok
    Right
      Queues
        { places = OMap.insert r.place remaining qs.places
        , present = foldr IntSet.delete qs.present [i | Just i <- map (.identity) removed]
        }
  RScopeClosed r -> scopeCleanup r.scope r.discarded qs
  RScopeReset r -> scopeCleanup r.closed r.discarded qs
  _ -> Right qs
  where
    depositAll place tokens recordedEntries scope instant = do
      let next = nextPresentIdentity qs
          entries
            | not (null recordedEntries) = recordedEntries
            | Just xs <- inferred, not (null xs) = xs
            | otherwise = take (length tokens) [next ..]
      when (length entries /= length tokens) $
        Left "movement fold requires one inferred queue-entry identity per token"
      let duplicated = filter (`IntSet.member` qs.present) entries
      unless (null duplicated) $
        Left ("replay divergence: queue-entry identities already present " <> pyList (map pyInt (sort duplicated)))
      let queue = OMap.findWithDefault emptyQueue place qs.places
          queue' = foldl (\q (t, i) -> depositEntry (QueueEntry t (Just instant) (Just i) scope) q) queue (zip tokens entries)
      Right
        Queues
          { places = OMap.insert place queue' qs.places
          , present = foldr IntSet.insert qs.present entries
          }

-- | @TokenQueue.remove(tokens, identities)@ reporting the removed entries.
removeWithEntries :: [Token] -> [Int] -> TokenQueue -> Either Token (TokenQueue, [QueueEntry])
removeWithEntries tokens identities queue = go (queueEntries queue) (zip tokens (map Just identities ++ repeat Nothing)) []
  where
    exact = not (null identities)
    go remaining [] removed = Right (queueFromEntries (toList remaining), reverse removed)
    go remaining ((t, i) : rest) removed =
      case Seq.findIndexL (\e -> e.token == t && (not exact || e.identity == i)) remaining of
        Nothing -> Left t
        Just position -> go (Seq.deleteAt position remaining) rest (Seq.index remaining position : removed)

-- | Discard one close/reset record's exact queue occurrences and prove
-- completeness.
scopeCleanup :: LifecycleScope -> [Int] -> Queues -> Either Text Queues
scopeCleanup closedScope discarded qs = do
  let step (m, remaining) (place, queue) =
        let presentHere =
              [ i
              | e <- toList (queueEntries queue)
              , Just i <- [e.identity]
              , IntSet.member i remaining
              , e.scope == Just closedScope
              ]
         in if null presentHere
              then Right (m, remaining)
              else do
                queue' <- discardIdentities presentHere queue
                Right (OMap.insert place queue' m, foldr IntSet.delete remaining presentHere)
  (places', remaining) <- foldM step (qs.places, IntSet.fromList discarded) (OMap.toList qs.places)
  unless (IntSet.null remaining) $
    Left
      ( "replay divergence: cannot discard queue entries "
          <> pyList (map pyInt (IntSet.toAscList remaining))
          <> " from lifecycle scope "
          <> reprScope closedScope
      )
  let retainedRepr =
        pyTuple
          [ maybe "None" pyInt e.identity
          | q <- OMap.elems places'
          , e <- toList (queueEntries q)
          , e.scope == Just closedScope
          ]
      anyRetained = or [e.scope == Just closedScope | q <- OMap.elems places', e <- toList (queueEntries q)]
  when anyRetained $
    Left ("replay divergence: lifecycle close left queue entries " <> retainedRepr <> " in scope " <> reprScope closedScope)
  let removed = IntSet.difference (IntSet.fromList discarded) remaining
  Right (Queues places' (IntSet.difference qs.present removed))

-- | The fold state behind the queue projections: queues, the next
-- never-spent identity, and the spent identities.
type QueueFold = (Queues, Int, IntSet)

stepQueueFold :: QueueFold -> Record -> Either Text QueueFold
stepQueueFold (qs, next, spent) record = do
  (inferred, next', spent') <- case movementDeposit of
    Just (tokens, recordedEntries) -> do
      let entries = if null recordedEntries then take (length tokens) [next ..] else recordedEntries
          duplicated = filter (`IntSet.member` spent) entries
      unless (null duplicated) $
        Left ("replay divergence: queue-entry identities were already spent " <> pyList (map pyInt (sort duplicated)))
      let advanced = if null entries then next else max next (maximum entries + 1)
      Right (Just entries, advanced, foldr IntSet.insert spent entries)
    Nothing -> Right (Nothing, next, spent)
  qs' <- applyMovement inferred record qs
  Right (qs', next', spent')
  where
    movementDeposit = case record of
      RTokensInitialized r -> Just (r.tokens, r.entries)
      RTokensProduced r -> Just (r.tokens, r.entries)
      _ -> Nothing

-- | The cumulative queue projection (and next never-spent identity) after
-- every record.
replayQueueStates :: Foldable f => f Record -> Either Text [(Queues, Int)]
replayQueueStates records = reverse . snd <$> foldM step ((emptyQueues, 1, IntSet.empty), []) (toList records)
  where
    step (state, acc) record = do
      state'@(qs, next, _) <- stepQueueFold state record
      Right (state', (qs, next) : acc)

-- | The final queues plus the next never-spent durable queue identity.
replayQueueProjection :: Foldable f => f Record -> Either Text (Queues, Int)
replayQueueProjection records = do
  (qs, next, _) <- foldM stepQueueFold (emptyQueues, 1, IntSet.empty) (toList records)
  Right (qs, next)

-- | Fold the recorded token movements, in order, into per-place queues.
replayQueues :: Foldable f => f Record -> Either Text Queues
replayQueues records = fst <$> replayQueueProjection records

-- | The marking view of queues (empty places dropped).
queuesMarking :: Queues -> Marking
queuesMarking qs = markingFromList [(p, toList (queueTokens q)) | (p, q) <- OMap.toList qs.places]

-- | The entry-instant view of queues (empty places dropped).
queuesEntryInstants :: Queues -> Map NetPath (Seq Instant)
queuesEntryInstants qs =
  Map.fromList
    [ (p, fmap (fromMaybe 0) (queueInstants q))
    | (p, q) <- OMap.toList qs.places
    , not (queueNull q)
    ]

-- | The complete marking after each record.
replayMarkings :: Foldable f => f Record -> Either Text [Marking]
replayMarkings records = map (queuesMarking . fst) <$> replayQueueStates records

-- | Rebuild the marking by re-applying recorded token movements, in order.
replayMarking :: Foldable f => f Record -> Either Text Marking
replayMarking records = queuesMarking <$> replayQueues records

-- | Each place-queue token's recorded entry instant, position-aligned with
-- the replayed marking.
entryInstants :: Foldable f => f Record -> Either Text (Map NetPath (Seq Instant))
entryInstants records = queuesEntryInstants <$> replayQueues records

-- | One past every queue occurrence reconstructed from movement order.
replayNextQueueIdentity :: Foldable f => f Record -> Either Text Int
replayNextQueueIdentity records = snd <$> replayQueueProjection records

-- ---------------------------------------------------------------------------
-- Scalars

-- | The clock watermark a history proves: the last record's instant,
-- validated monotone. An empty history proves none.
replayWatermark :: Foldable f => f Record -> Either Text Instant
replayWatermark records = do
  final <- foldM step Nothing (toList records)
  maybe (Left "an empty history proves no watermark") Right final
  where
    step watermark record = do
      let i = recordInstant record
      forM_ watermark $ \w ->
        when (i < w) $
          Left
            ( "replay divergence: instant "
                <> pyInt i
                <> " steps backwards past "
                <> pyInt w
                <> ": the single writer appends monotone instants"
            )
      Right (Just i)

-- | One past the greatest spent occurrence id in the records.
replayNextOccurrence :: Foldable f => f Record -> Int
replayNextOccurrence records = maximum (0 : mapMaybe recordOccurrence (toList records)) + 1

-- | The recorded identity fact: first and exactly once.
replayInstanceIdentity :: Foldable f => f Record -> Either Text (Maybe InstanceCreated)
replayInstanceIdentity records = do
  let rs = toList records
  identity <-
    foldM
      ( \found (position, record) -> case record of
          RInstanceCreated r
            | position /= (0 :: Int) ->
                Left
                  ( "replay divergence: InstanceCreated at position "
                      <> pyInt position
                      <> ": the single writer records identity as the first record, exactly once"
                  )
            | otherwise -> Right (Just r)
          _ -> Right found
      )
      Nothing
      (zip [0 ..] rs)
  when (not (null rs) && isNothing identity) $
    Left "replay divergence: the construction batch requires InstanceCreated as its first record"
  Right identity

-- ---------------------------------------------------------------------------
-- Deliveries and registrations

batchError :: Int -> Text
batchError occurrence =
  "replay divergence: correlated delivery registration effect for occurrence "
    <> pyInt occurrence
    <> " does not belong to a contiguous writer-valid completion batch"

-- | Require every firing-correlated registration effect to end in its
-- contiguous completion batch.
validateCorrelatedDeliveryRegistrationBatches :: [Record] -> Either Text ()
validateCorrelatedDeliveryRegistrationBatches records = do
  let effectOccurrences =
        IntSet.fromList
          [ o
          | record <- records
          , Just o <- [correlatedRegistration record]
          ]
  (_, active) <- foldM (step effectOccurrences) (IntMap.empty, Nothing) records
  forM_ active $ \(o, _, _) -> Left (batchError o)
  where
    correlatedRegistration = \case
      RDeliveryRegistrationOpened r -> r.occurrence
      RDeliveryRegistrationClosed r -> r.occurrence
      _ -> Nothing
    step :: IntSet -> (IntMap NetPath, Maybe (Int, Instant, Int)) -> Record -> Either Text (IntMap NetPath, Maybe (Int, Instant, Int))
    step effects (begun, active) record = case active of
      Just (o, instant, priorRank) -> case record of
        RFiringCompleted r
          | r.occurrence == o && r.instant == instant && Just r.transition == IntMap.lookup o begun -> Right (begun, Nothing)
        _ -> do
          (rank, ro) <- case record of
            RTokensProduced r -> Right (0 :: Int, Just r.occurrence)
            RDeliveryRegistrationClosed r -> Right (1, r.occurrence)
            RDeliveryRegistrationOpened r -> Right (2, r.occurrence)
            _ -> Left (batchError o)
          when (ro /= Just o || recordInstant record /= instant || rank < priorRank) $ Left (batchError o)
          Right (begun, Just (o, instant, rank))
      Nothing -> do
        let begun' = case record of
              RFiringBegun r -> IntMap.insert r.occurrence r.transition begun
              _ -> begun
        active' <- case record of
          RTokensProduced r
            | IntSet.member r.occurrence effects -> do
                unless (IntMap.member r.occurrence begun') $ Left (batchError r.occurrence)
                Right (Just (r.occurrence, r.instant, 0))
          RDeliveryRegistrationOpened r | Just o <- r.occurrence -> do
            unless (IntMap.member o begun') $ Left (batchError o)
            Right (Just (o, r.instant, 2))
          RDeliveryRegistrationClosed r | Just o <- r.occurrence -> do
            unless (IntMap.member o begun') $ Left (batchError o)
            Right (Just (o, r.instant, 1))
          _ -> Right Nothing
        Right (begun', active')

-- | Validate and advance the construction prefix before applying a record.
advanceInitialBatch :: Record -> (Bool, Bool) -> Either Text (Bool, Bool)
advanceInitialBatch record (initialBatch, started) = case record of
  RDeliveryRegistrationOpened r | isNothing r.occurrence -> Right (initialBatch, True)
  RTokensInitialized _
    | not initialBatch || started ->
        Left "replay divergence: TokensInitialized appears outside the contiguous initial construction prefix"
    | otherwise -> Right (initialBatch, started)
  RInstanceCreated _ -> Right (initialBatch, started)
  _ -> Right (False, started)

-- | Apply one registration record with the live writer's preconditions.
applyRegistration :: Bool -> Instant -> Record -> OMap NetPath (Set Text) -> Either Text (OMap NetPath (Set Text))
applyRegistration initialBatch initialInstant record armed = case record of
  RDeliveryRegistrationOpened r -> do
    let keys = OMap.findWithDefault Set.empty r.source armed
        armedWithSource = if OMap.member r.source armed then armed else OMap.insert r.source Set.empty armed
    when (Set.member r.key keys) $
      Left
        ( "replay divergence: delivery registration "
            <> pyStr r.key
            <> " on "
            <> netPathText r.source
            <> " opened while armed"
        )
    when (isNothing r.occurrence) $ do
      unless initialBatch $
        Left
          ( "replay divergence: uncorrelated delivery registration "
              <> pyStr r.key
              <> " on "
              <> netPathText r.source
              <> " opened outside the initial construction batch; the single writer emits an uncorrelated open only in the initial construction batch"
          )
      when (r.key /= "default") $
        Left
          ( "replay divergence: initial delivery registration on "
              <> netPathText r.source
              <> " uses key "
              <> pyStr r.key
              <> "; the single writer uses only 'default'"
          )
      when (r.instant /= initialInstant) $
        Left
          ( "replay divergence: initial delivery registration "
              <> pyStr r.key
              <> " on "
              <> netPathText r.source
              <> " uses instant "
              <> pyInt r.instant
              <> ", not construction instant "
              <> pyInt initialInstant
          )
    Right (OMap.adjust (Set.insert r.key) r.source armedWithSource)
  RDeliveryRegistrationClosed r -> do
    unless (Set.member r.key (OMap.findWithDefault Set.empty r.source armed)) $
      Left
        ( "replay divergence: delivery registration "
            <> pyStr r.key
            <> " on "
            <> netPathText r.source
            <> " closed while not armed"
        )
    Right (OMap.adjust (Set.delete r.key) r.source armed)
  _ -> Right armed

-- | The registration fold shared by 'replayArmed' and
-- 'replayAcceptedIdentities', with a per-record hook.
registrationFold ::
  [Record] ->
  s ->
  (Int -> Record -> OMap NetPath (Set Text) -> s -> Either Text s) ->
  Either Text (OMap NetPath (Set Text), s)
registrationFold records initial hook = do
  validateCorrelatedDeliveryRegistrationBatches records
  let initialInstant = case records of
        (r : _) -> recordInstant r
        [] -> 0
  (armed, _, s) <-
    foldM
      ( \(armed, batch, s) (position, record) -> do
          batch' <- advanceInitialBatch record batch
          armed' <- applyRegistration (fst batch') initialInstant record armed
          s' <- hook position record armed' s
          Right (armed', batch', s')
      )
      (OMap.empty, (True, False), initial)
      (zip [0 ..] records)
  Right (armed, s)

-- | The armed delivery-registration keys per source, by re-applying the
-- recorded opens and closes in order.
replayArmed :: Foldable f => f Record -> Either Text (OMap NetPath (Set Text))
replayArmed records = fst <$> registrationFold (toList records) () (\_ _ _ s -> Right s)

-- | The accepted delivery identities, each mapped to its complete recorded
-- delivery fact.
replayAcceptedIdentities :: Foldable f => f Record -> Either Text (Map Text Record)
replayAcceptedIdentities records = snd <$> registrationFold rs Map.empty hook
  where
    rs = toList records
    indexed = Seq.fromList rs
    hook position record armed accepted = case deliveryFact record of
      Nothing -> Right accepted
      Just (identity, tokens) -> do
        validateDeliveryTokens tokens ("replay divergence: " <> recordName record <> " identity " <> pyStr identity)
        case record of
          RExternalEventDelivered r -> do
            when (Set.null (OMap.findWithDefault Set.empty r.source armed)) $
              Left
                ( "replay divergence: accepted delivery identity "
                    <> pyStr r.identity
                    <> " source "
                    <> netPathText r.source
                    <> " had no armed delivery registration"
                )
            let expected = RFiringBegun (FiringBegun r.source r.occurrence r.scope r.instant)
                following = Seq.lookup (position + 1) indexed
            when (following /= Just expected) $
              Left
                ( "replay divergence: accepted delivery identity "
                    <> pyStr r.identity
                    <> " requires an immediately following matching FiringBegun "
                    <> reprRecord expected
                    <> "; found "
                    <> maybe "None" reprRecord following
                )
          _ -> Right ()
        when (Map.member identity accepted) $
          Left
            ( "replay divergence: delivery identity "
                <> pyStr identity
                <> " accepted twice — the single writer accepts an identity once and answers redelivery from that accepted fact"
            )
        Right (Map.insert identity record accepted)
    deliveryFact = \case
      RExternalEventDelivered r -> Just (r.identity, r.tokens)
      RScopedDeliveryDropped r -> Just (r.identity, r.tokens)
      RScopedDeliveryQuarantined r -> Just (r.identity, r.tokens)
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- Lifecycle scopes

-- | Rebuild the active generations and the greatest generation spent per
-- name.
replayScopes :: Foldable f => f Record -> Either Text (Map Text LifecycleScope, Map Text Integer)
replayScopes = foldM step (Map.empty, Map.empty) . toList
  where
    spent name generations = Map.findWithDefault 0 name generations
    step (active, generations) = \case
      RScopeOpened r -> do
        let s = r.scope
        when (Map.member (scopeName s) active || scopeGeneration s /= spent (scopeName s) generations + 1) $
          Left ("replay divergence: invalid scope open " <> reprScope s)
        Right (Map.insert (scopeName s) s active, Map.insert (scopeName s) (scopeGeneration s) generations)
      RScopeClosed r -> do
        when (Map.lookup (scopeName r.scope) active /= Just r.scope) $
          Left ("replay divergence: scope " <> reprScope r.scope <> " closed while not active")
        Right (Map.delete (scopeName r.scope) active, generations)
      RScopeReset r -> do
        when (Map.lookup (scopeName r.closed) active /= Just r.closed) $
          Left ("replay divergence: scope " <> reprScope r.closed <> " reset while not active")
        Right
          ( Map.insert (scopeName r.opened) r.opened active
          , Map.insert (scopeName r.opened) (scopeGeneration r.opened) generations
          )
      RScopedDeliveryDropped r -> do
        when
          ( Map.lookup (scopeName r.scope) active == Just r.scope
              || spent (scopeName r.scope) generations < scopeGeneration r.scope
          )
          $ Left ("replay divergence: delivery dropped for scope " <> reprScope r.scope <> " without proof it was closed")
        Right (active, generations)
      RScopedDeliveryQuarantined r
        | QuarantineGeneration s <- r.scope -> do
            when (Map.lookup (scopeName s) active == Just s || spent (scopeName s) generations >= scopeGeneration s) $
              Left
                ( "replay divergence: exact delivery target "
                    <> reprScope s
                    <> " was quarantined despite a known disposition"
                )
            Right (active, generations)
      record
        | Just s <- recordScope record -> do
            when (Map.lookup (scopeName s) active /= Just s) $
              Left ("replay divergence: " <> recordName record <> " uses inactive lifecycle scope " <> reprScope s)
            Right (active, generations)
        | otherwise -> Right (active, generations)

-- | Map each lifecycle-cancelled occurrence to its one-based append
-- position.
replayCancellationPositions :: Foldable f => f Record -> Either Text (IntMap Int)
replayCancellationPositions records = foldM step IntMap.empty (zip [1 ..] (toList records))
  where
    step positions (position, record) = do
      let cancelled = case record of
            RScopeClosed r -> r.cancelled
            RScopeReset r -> r.cancelled
            _ -> []
      foldM
        ( \m o -> do
            when (IntMap.member o m) $ Left ("replay divergence: firing occurrence " <> pyInt o <> " cancelled twice")
            Right (IntMap.insert o position m)
        )
        positions
        cancelled

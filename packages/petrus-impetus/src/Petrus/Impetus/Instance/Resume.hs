-- | Resume validation: the pure checks 'Petrus.Impetus.Instance.resume'
-- runs over a recorded History before it rebuilds live state. Each refuses
-- what the live writer could never have appended, with the reference's
-- message; none reads or moves an Instance.
module Petrus.Impetus.Instance.Resume
  ( -- * Construction and resume
    validateInitialTokens
  , validateReplayedInitialization
  , validateConstructionBatch
  , validateBindingShape
  , validateReplayedOccurrence
  , validateAcceptedSourceOccurrences
    -- * Shared spelling
  , reprInts
  , canonical
  , tokensJson
  , deliveryContent
  ) where

import Control.Monad (foldM, forM_, unless, void, when)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet (IntSet)
import Data.IntSet qualified as IntSet
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity.Number (reprNumber)
import Petrus.Impetus.History.Records
import Petrus.Impetus.History.Replay
import Petrus.Impetus.Instance.Firing
import Petrus.Impetus.Petrinet.Enabledness (Binding (..))
import Petrus.Impetus.Petrinet.Marking (Token (..), reprToken, reprTokens)
import Petrus.Impetus.Petrinet.Routing (route)
import Petrus.Impetus.Petrinet.Schema
import Petrus.Impetus.Scope
import Petrus.Json (Json (..), canonicalText)
import Petrus.Json.Python (pythonIntRepr, pythonOptionalStrRepr, pythonStrRepr, pythonTupleRepr)

-- | @_canonical_payload_text@ ('Nothing' for a value with no strict JSON
-- spelling, which never reaches a comparison).
canonical :: Json -> Maybe Text
canonical = either (const Nothing) Just . canonicalText

tokensJson :: [Token] -> Json
tokensJson ts = Array [Object [("color", maybe Null String t.color), ("data", t.payload)] | t <- ts]

-- | @_delivery_content_text@.
deliveryContent :: [Token] -> Maybe Text
deliveryContent = canonical . tokensJson

-- | The initial tokens of one place carry its declared color (shared by
-- construction and the replayed construction batch).
validateInitialTokens :: Net -> NetPath -> [Token] -> Either Text ()
validateInitialTokens net p tokens = case lookupPlace p net of
  Just declared
    | Just c <- declared.color
    , (mismatch : _) <- [t | t <- tokens, t.color /= Just c] ->
        Left
          ( "initial marking for place " <> netPathText p <> " requires color " <> pythonStrRepr c <> ", got "
              <> pythonOptionalStrRepr mismatch.color
              <> " on "
              <> reprToken mismatch
          )
  _ -> Right ()

-- | One initial token record the live constructor could emit.
validateReplayedInitialization :: Net -> TokensInitialized -> Instant -> Set NetPath -> Either Text (Set NetPath)
validateReplayedInitialization net r constructed initialized = do
  let p = netPathText r.place
  unless (hasPlace r.place net) $
    Left
      ( "replay divergence: unknown place " <> p
          <> " in the initial marking; the live constructor initializes only declared places"
      )
  when (Set.member r.place initialized) $
    Left ("replay divergence: initial marking place " <> p <> " must be initialized exactly once")
  when (null r.tokens) $
    Left ("replay divergence: initial marking place " <> p <> " has no tokens; the live constructor omits empty places")
  when (r.instant /= constructed) $
    Left
      ( "replay divergence: initial tokens on " <> p <> " use instant " <> reprNumber r.instant
          <> ", not construction instant "
          <> reprNumber constructed
      )
  when (not (null r.entries) || isJust r.scope) $
    Left
      ( "replay divergence: initial marking place " <> p
          <> " carries queue entries or scope; the live constructor records neither"
      )
  validateInitialTokens net r.place r.tokens
  Right (Set.insert r.place initialized)

-- | The complete prefix emitted by the live constructor.
validateConstructionBatch :: Net -> [Record] -> Maybe InstanceCreated -> Either Text ()
validateConstructionBatch net records identity = do
  created <-
    maybe (Left "replay divergence: the construction batch requires InstanceCreated as its first record") Right identity
  let visit (regs, started, initialized, ended) record
        | ended = case record of
            RTokensInitialized _ ->
              Left "replay divergence: TokensInitialized appears outside the contiguous initial construction prefix"
            _ -> Right (regs, started, initialized, ended)
        | RTokensInitialized r <- record = do
            when started $
              Left
                "replay divergence: initial construction prefix is a construction batch that requires every TokensInitialized record before its source registrations"
            initialized' <- validateReplayedInitialization net r created.instant initialized
            Right (regs, started, initialized', ended)
        | RDeliveryRegistrationOpened r <- record
        , isNothing r.occurrence =
            Right (r : regs, True, initialized, ended)
        | otherwise = Right (regs, started, initialized, True)
  (regsRev, _, _, _) <- foldM visit ([], False, Set.empty, False) (drop 1 records)
  let registrations = reverse regsRev
      expected = [DeliveryRegistrationOpened s "default" Nothing created.instant | s <- sourceTransitions net]
      spell = pythonTupleRepr . map (reprRecord . RDeliveryRegistrationOpened)
  when (registrations /= expected) $
    Left
      ( "replay divergence: initial construction prefix is a construction batch whose source registrations require exactly one ordered default open for every source; expected "
          <> spell expected
          <> ", found "
          <> spell registrations
      )

-- | The begin-batch shape rule, writer and replay alike: one selection per
-- consume (read) arc, in input-arc order, on each arc's place, weight tokens
-- each.
validateBindingShape :: Net -> Binding -> Text -> Either Text ()
validateBindingShape net b rejection =
  forM_ [(Consume, b.consumed, "consume" :: Text), (Read, b.read, "read")] $ \(mode, selections, noun) -> do
    let arcs = [a | a <- inputs net b.transition, a.mode == mode]
    when
      ( map fst selections /= map (.source) arcs
          || or [length ts /= a.weight | (a, (_, ts)) <- zip arcs selections]
      )
      $ Left
        ( rejection <> ": its " <> noun <> " selections do not match the transition's " <> noun
            <> " arcs — a live begin takes one "
            <> noun
            <> " selection per arc, in input-arc order, weight tokens each"
        )

-- | One recorded in-flight occurrence the live 'begin' could have written.
-- The predicate says whether a transition is bound to an ActivityHandler.
validateReplayedOccurrence :: Net -> (NetPath -> Bool) -> FiringOccurrence -> Either Text ()
validateReplayedOccurrence net activityBoundAt o = do
  let t = o.binding.transition
      rejection = "cannot resume firing occurrence " <> pythonIntRepr o.occurrence <> " (" <> netPathText t <> ")"
  unless (hasTransition t net) $ Left (rejection <> ": not a transition of this net")
  when (isSource net t && null o.binding.delivered) $
    Left (rejection <> ": a scheduled selection on a source transition — a source fires only through accept_delivery()")
  when (not (isSource net t) && not (null o.binding.delivered)) $
    Left (rejection <> ": an external event on a transition with input arcs — only a source transition takes delivery")
  validateBindingShape net o.binding rejection
  let activityBound = activityBoundAt t
  when (isJust o.invocation && not activityBound) $
    Left
      ( rejection
          <> ": its begin batch froze an activity request, but the transition is not bound to an ActivityHandler — projection needs the handler that prepared it"
      )
  when (isNothing o.invocation && activityBound) $
    Left
      ( rejection
          <> ": the transition binds an ActivityHandler, but the begin batch froze no ActivityRequested — the live writer always freezes the request at begin"
      )

reprOptScope :: Maybe LifecycleScope -> Text
reprOptScope = maybe "None" (T.pack . show)

reprInts :: [Int] -> Text
reprInts = pythonTupleRepr . map pythonIntRepr

reprProductions :: [(NetPath, [Token])] -> Text
reprProductions xs = pythonTupleRepr [pythonTupleRepr [T.pack (show p), reprTokens ts] | (p, ts) <- xs]

validateAcceptedSourceProduction :: Net -> ExternalEventDelivered -> Text -> TokensProduced -> Set NetPath -> [Int] -> Either Text ()
validateAcceptedSourceProduction net accepted ident r produced expected = do
  let rejection = "cannot resume: accepted delivery identity " <> pythonStrRepr ident <> " source occurrence " <> pythonIntRepr accepted.occurrence
      p = netPathText r.place
  when (null r.tokens) $ Left (rejection <> " contains an empty TokensProduced record")
  when (Set.member r.place produced) $ Left (rejection <> " contains a second TokensProduced record for " <> p)
  when (r.scope /= accepted.scope) $
    Left
      ( rejection <> " production on " <> p <> " has lifecycle scope " <> reprOptScope r.scope
          <> ", not the accepted scope "
          <> reprOptScope accepted.scope
      )
  when (isJust r.scope && r.entries /= expected) $
    Left
      ( rejection <> " production on " <> p <> " has queue-entry identities " <> reprInts r.entries
          <> "; the writer's exact next identities are expected "
          <> reprInts expected
      )
  let outs = outputs net accepted.source
      unadmitted = [t | t <- r.tokens, not (any (\a -> a.target == r.place && arcAdmits a t.color) outs)]
  unless (null unadmitted) $
    Left
      ( rejection <> " production on " <> p <> " carries token(s) " <> reprTokens unadmitted
          <> " not admitted by any output arc of source "
          <> netPathText accepted.source
      )

validateDefaultSourceProductions :: Net -> ExternalEventDelivered -> Text -> [(NetPath, [Token])] -> Either Text ()
validateDefaultSourceProductions net accepted ident actual
  | isJust (handlerUri net accepted.source) = Right ()
  | otherwise = do
      let expected = route accepted.tokens (outputs net accepted.source)
          spelling xs = [(p, deliveryContent ts) | (p, ts) <- xs]
      when (spelling actual /= spelling expected) $
        Left
          ( "cannot resume: accepted delivery identity " <> pythonStrRepr ident <> " source occurrence "
              <> pythonIntRepr accepted.occurrence
              <> " default passthrough requires exact productions "
              <> reprProductions expected
              <> "; found "
              <> reprProductions actual
          )

data SourceFold = SourceFold
  { phases :: IntMap Int
  , phaseNames :: IntMap Text
  , endInstants :: IntMap Instant
  , terminals :: IntMap Text
  , producedPlaces :: IntMap (Set NetPath)
  , productions :: IntMap [(NetPath, [Token])]
  , cancelledSet :: IntSet
  , observed :: IntSet
  , nextEntryF :: Int
  , activeCompletion :: Maybe (Int, Text)
  -- ^ The accepted source occurrence whose completion batch is open, and
  -- its delivery identity.
  }

-- | Every accepted source occurrence has only a writer-valid pure
-- lifecycle: its acceptance pair, then no end; a lone failure; lifecycle
-- cancellation; or one atomic ordered completion batch.
validateAcceptedSourceOccurrences :: Net -> [Record] -> Map Text AcceptedFact -> Either Text ()
validateAcceptedSourceOccurrences net history accepted = void (foldM visit start history)
  where
    sourceOccurrences =
      IntMap.fromList [(r.occurrence, (ident, r)) | (ident, AcceptedDelivered r) <- Map.toList accepted]
    start = SourceFold IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntSet.empty IntSet.empty 1 Nothing
    rankOf = \case
      RTokensProduced _ -> Just (0 :: Int)
      RDeliveryRegistrationClosed _ -> Just 1
      RDeliveryRegistrationOpened _ -> Just 2
      RFiringCompleted _ -> Just 3
      _ -> Nothing
    reprOcc = maybe "None" pythonIntRepr
    visit f0 record = do
      let o = recordOccurrence record
          name = recordName record
          (expected, f) = case record of
            RTokensInitialized r -> entriesStep f0 r.tokens r.entries
            RTokensProduced r -> entriesStep f0 r.tokens r.entries
            _ -> ([], f0)
      forM_ f.activeCompletion $ \(active, ident) -> when (o /= Just active) $
        Left
          ( "cannot resume: accepted delivery identity " <> pythonStrRepr ident <> " source occurrence "
              <> pythonIntRepr active
              <> " completion batch was interrupted by "
              <> name
              <> " for occurrence "
              <> reprOcc o
          )
      case record of
        RScopeClosed r -> cancel f name r.cancelled
        RScopeReset r -> cancel f name r.cancelled
        _ -> case o >>= \n -> (n,) <$> IntMap.lookup n sourceOccurrences of
          Nothing -> Right f
          Just (n, (ident, acceptedRecord)) -> occurrenceStep f record name n ident acceptedRecord expected
    entriesStep f tokens entries =
      let expected = take (length tokens) [f.nextEntryF ..]
          recorded = if null entries then expected else entries
          next = if null recorded then f.nextEntryF else max f.nextEntryF (maximum recorded + 1)
       in (expected, f {nextEntryF = next})
    cancel f name occurrences = foldM (cancelOne name) f occurrences
    cancelOne name f n = case IntMap.lookup n sourceOccurrences of
      Nothing -> Right f
      Just (ident, acceptedRecord) -> do
        let prefix = "cannot resume: accepted delivery identity " <> pythonStrRepr ident <> " source occurrence " <> pythonIntRepr acceptedRecord.occurrence
        unless (IntSet.member n f.observed) $
          Left (prefix <> " contains " <> name <> " cancellation before its acceptance pair")
        when (IntMap.member n f.phases || IntMap.member n f.terminals) $ do
          let prior = fromMaybe "None" (maybe (IntMap.lookup n f.terminals) Just (IntMap.lookup n f.phaseNames))
          Left (prefix <> " was lifecycle-cancelled after " <> prior)
        Right f {cancelledSet = IntSet.insert n f.cancelledSet}
    occurrenceStep f record name n ident acceptedRecord expected = case record of
      RExternalEventDelivered _ -> Right f
      RFiringBegun _ -> Right f {observed = IntSet.insert n f.observed}
      _ -> do
        let rejection = "cannot resume: accepted delivery identity " <> pythonStrRepr ident <> " source occurrence " <> pythonIntRepr n
        unless (IntSet.member n f.observed) $ Left (rejection <> " contains " <> name <> " before its acceptance pair")
        when (IntSet.member n f.cancelledSet) $ Left (rejection <> " contains " <> name <> " after lifecycle cancellation")
        forM_ (IntMap.lookup n f.terminals) $ \terminal -> Left (rejection <> " contains " <> name <> " after " <> terminal)
        when (isActivityOrSelection record) $
          Left
            ( rejection <> " contains " <> name
                <> " — a source delivery is a pure occurrence with no consume, read, or activity records"
            )
        case record of
          RFiringFailed _ -> do
            forM_ (IntMap.lookup n f.phaseNames) $ \prior ->
              Left
                ( rejection <> " contains FiringFailed after " <> prior
                    <> " — a pure source failure batch contains only FiringFailed"
                )
            Right f {terminals = IntMap.insert n name f.terminals}
          _ -> do
            when (isRegistration record && isNothing (handlerUri net acceptedRecord.source)) $
              Left
                ( rejection <> " default passthrough does not permit delivery-registration effects; found " <> name
                )
            rank <- maybe (Left (rejection <> " contains writer-invalid " <> name)) Right (rankOf record)
            let f1 = f {activeCompletion = Just (fromMaybe (n, ident) f.activeCompletion)}
                priorRank = IntMap.findWithDefault (-1) n f1.phases
                instant = recordInstant record
            when (rank < priorRank) $
              Left (rejection <> " contains disordered " <> name <> " after " <> IntMap.findWithDefault "" n f1.phaseNames)
            forM_ (IntMap.lookup n f1.endInstants) $ \endInstant ->
              when (instant /= endInstant) $
                Left
                  ( rejection <> " completion batch changes instant from " <> reprNumber endInstant <> " to "
                      <> reprNumber instant
                  )
            let f2 =
                  f1
                    { endInstants = IntMap.insertWith (\_ old -> old) n instant f1.endInstants
                    , phases = IntMap.insert n rank f1.phases
                    , phaseNames = IntMap.insert n name f1.phaseNames
                    }
            case record of
              RTokensProduced r -> do
                let places = IntMap.findWithDefault Set.empty n f2.producedPlaces
                validateAcceptedSourceProduction net acceptedRecord ident r places expected
                Right
                  f2
                    { producedPlaces = IntMap.insert n (Set.insert r.place places) f2.producedPlaces
                    , productions = IntMap.insertWith (\new old -> old ++ new) n [(r.place, r.tokens)] f2.productions
                    }
              RFiringCompleted _ -> do
                validateDefaultSourceProductions net acceptedRecord ident (IntMap.findWithDefault [] n f2.productions)
                Right f2 {terminals = IntMap.insert n name f2.terminals, activeCompletion = Nothing}
              _ -> Right f2
    isActivityOrSelection = \case
      RTokensConsumed _ -> True
      RTokensRead _ -> True
      RActivityRequested _ -> True
      RActivityCompleted _ -> True
      RActivityFailed _ -> True
      RActivityTerminalQuarantined _ -> True
      _ -> False
    isRegistration = \case
      RDeliveryRegistrationClosed _ -> True
      RDeliveryRegistrationOpened _ -> True
      _ -> False

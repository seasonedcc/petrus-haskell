-- | Enabledness: which transitions can fire, under which bindings, given a
-- marking (@petrus.impetus.petrinet.enabledness@).
--
-- Pure: a function of net structure, the marking, the clock, and the (pure)
-- filter and guard implementations. A 'Binding' names a transition and the
-- exact tokens each input arc would take, so firing has nothing left to
-- decide about token selection.
--
-- Candidate computation enumerates token selections from arcs first, then
-- gates the assembled bindings with the transition's guards, then with its
-- timers. Each consume/read arc contributes every combination of @weight@
-- admitted tokens, enumerated FIFO-lexicographically; the transition's
-- alternatives are the cross product, input-arc-major, so the head selection
-- is always the first binding.
--
-- The reference reports a raising filter or guard as a Python warning (a
-- process-global side effect). Here a filter or guard returns
-- @'Left' message@ for an evaluation error, the token or binding is skipped
-- exactly as in the reference, and the diagnostic is returned explicitly in
-- 'Survey' — never a global side effect.
module Petrus.Impetus.Petrinet.Enabledness
  ( -- * Bindings
    Selection
  , Binding (..)
  , mkBinding
  , selectionBinding
  , deliveredBinding
  , bindingTokens
  , bindingPeeked
  , reprBinding
    -- * Implementations
  , Filter
  , Guard
  , ImplementationKey (..)
  , Implementations (..)
  , noImplementations
  , filterImplementation
  , guardImplementation
    -- * Diagnostics
  , Diagnostic (..)
  , renderDiagnostic
    -- * Offers
  , Offer (..)
  , Alternative (..)
  , offer
    -- * Candidates
  , Clock (..)
  , clockAt
  , Survey (..)
  , EnablednessError (..)
  , survey
  , candidates
  , candidatesWithDiagnostics
  , nextMaturation
  , maturation
  , selection
  , admitted
  , guardsHold
  ) where

import Control.Monad (foldM)
import Control.Monad.Trans.State.Strict (State, modify', runState)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.Python (pythonTupleRepr)
import Petrus.Impetus.Petrinet.Marking
import Petrus.Impetus.Petrinet.Schema

-- ---------------------------------------------------------------------------
-- Bindings

-- | The tokens one arc takes from one place, in FIFO-scan order.
type Selection = (NetPath, [Token])

-- | A transition and the tokens each input arc selects: @consumed@ (removed
-- at firing) and @read@ (selected, left in place), per arc in input-arc
-- order. A source firing selects nothing — @delivered@ carries the external
-- event's tokens instead. Build through 'mkBinding' (or the two specific
-- constructors) to keep the reference's invariant that a delivered binding
-- carries no selections.
data Binding = Binding
  { transition :: NetPath
  , consumed :: [Selection]
  , read :: [Selection]
  , delivered :: [Token]
  }
  deriving stock (Eq, Show)

-- | The reference's @Binding(...)@ constructor with its invariant.
mkBinding :: NetPath -> [Selection] -> [Selection] -> [Token] -> Either Text Binding
mkBinding at c r d
  | not (null d) && (not (null c) || not (null r)) =
      Left
        ( "binding for "
            <> netPathText at
            <> ": a delivered binding is a source firing and selects nothing — it cannot also carry consumed or read selections"
        )
  | otherwise = Right (Binding at c r d)

-- | A binding assembled from arc selections.
selectionBinding :: NetPath -> [Selection] -> [Selection] -> Binding
selectionBinding at c r = Binding at c r []

-- | A source firing's binding.
deliveredBinding :: NetPath -> [Token] -> Binding
deliveredBinding at = Binding at [] []

-- | The tokens the firing forwards by default: consumed selections flattened
-- in input-arc order, then delivered tokens. Read selections are never
-- forwarded.
bindingTokens :: Binding -> [Token]
bindingTokens b = concatMap snd b.consumed ++ b.delivered

-- | Every token the binding holds — what guards see.
bindingPeeked :: Binding -> [Token]
bindingPeeked b = bindingTokens b ++ concatMap snd b.read

-- | The reference's dataclass @repr(binding)@.
reprBinding :: Binding -> Text
reprBinding b =
  "Binding(transition="
    <> T.pack (show b.transition)
    <> ", consumed="
    <> selections b.consumed
    <> ", read="
    <> selections b.read
    <> ", delivered="
    <> reprTokens b.delivered
    <> ")"
  where
    selections xs = pythonTupleRepr [pythonTupleRepr [T.pack (show p), reprTokens ts] | (p, ts) <- xs]

-- ---------------------------------------------------------------------------
-- Implementations

-- | A filter implementation: a pure boolean over one token; 'Left' is an
-- evaluation error (the token is then not admitted).
type Filter = Token -> Either Text Bool

-- | A guard implementation: a pure boolean over the full binding; 'Left' is
-- an evaluation error (the binding is then not satisfied).
type Guard = Binding -> Either Text Bool

-- | How an implementation is keyed: by canonical occurrence identity first,
-- then by its declaration — the reference's @mapping[identity] if identity
-- in mapping else mapping[declaration]@ lookup.
data ImplementationKey
  = ByUri NetUri
  | BySymbol Text
  | ByCel Cel
  | ByAnonymous
  deriving stock (Eq, Ord, Show)

-- | The bound filter and guard implementations.
data Implementations = Implementations
  { filters :: Map ImplementationKey Filter
  , guards :: Map ImplementationKey Guard
  }

noImplementations :: Implementations
noImplementations = Implementations Map.empty Map.empty

filterKey :: FilterDeclaration -> ImplementationKey
filterKey = \case
  FilterSymbol s -> BySymbol s
  FilterCel c -> ByCel c

guardKey :: GuardDeclaration -> ImplementationKey
guardKey = \case
  GuardSymbol s -> BySymbol s
  GuardCel c -> ByCel c
  GuardAnonymous _ -> ByAnonymous

-- | Resolve a filter by identity, then by declaration.
filterImplementation :: Implementations -> Maybe NetUri -> FilterDeclaration -> Either EnablednessError Filter
filterImplementation impls identity declaration =
  case maybe Nothing (\u -> Map.lookup (ByUri u) impls.filters) identity of
    Just f -> Right f
    Nothing -> maybe (Left (MissingFilter identity declaration)) Right (Map.lookup (filterKey declaration) impls.filters)

-- | Resolve a guard by identity, then by declaration.
guardImplementation :: Implementations -> Maybe NetUri -> GuardDeclaration -> Either EnablednessError Guard
guardImplementation impls identity declaration =
  case maybe Nothing (\u -> Map.lookup (ByUri u) impls.guards) identity of
    Just g -> Right g
    Nothing -> maybe (Left (MissingGuard identity declaration)) Right (Map.lookup (guardKey declaration) impls.guards)

-- ---------------------------------------------------------------------------
-- Diagnostics and errors

-- | An evaluation error surfaced by candidate computation: the reference's
-- @FilterEvaluationWarning@ / @GuardEvaluationWarning@, as data.
data Diagnostic
  = -- | A filter failed on a token: declaration, identity, error, token.
    FilterEvaluationFailed FilterDeclaration (Maybe NetUri) Text Token
  | -- | A guard failed on a binding: declaration, identity, transition,
    -- error, peeked tokens.
    GuardEvaluationFailed GuardDeclaration (Maybe NetUri) NetPath Text [Token]
  deriving stock (Eq, Show)

-- | The reference's warning text.
renderDiagnostic :: Diagnostic -> Text
renderDiagnostic = \case
  FilterEvaluationFailed declaration identity failure t ->
    "filter "
      <> reprFilterDeclaration declaration
      <> " at "
      <> maybe (reprFilterDeclaration declaration) (T.pack . show) identity
      <> " raised "
      <> failure
      <> " evaluating "
      <> reprToken t
      <> "; token not admitted"
  GuardEvaluationFailed declaration identity at failure peeked ->
    "guard "
      <> reprGuardDeclaration declaration
      <> " at "
      <> maybe (reprGuardDeclaration declaration) (T.pack . show) identity
      <> " on transition "
      <> netPathText at
      <> " raised "
      <> failure
      <> " over peeked tokens "
      <> reprTokens peeked
      <> "; binding skipped"

-- | A candidate computation the reference refuses loudly.
data EnablednessError
  = -- | A timed net surveyed without the clock.
    ClockRequired
  | -- | A @Delay@'s entry instants do not cover the selection.
    MisalignedInstants NetPath NetPath Int Int
  | MissingFilter (Maybe NetUri) FilterDeclaration
  | MissingGuard (Maybe NetUri) GuardDeclaration
  | InvalidLimit Text
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Offers

-- | One way an arc can select, with the selected tokens' entry instants
-- when a @Delay@ demands anchors.
data Alternative = Alternative
  { selection :: Selection
  , anchors :: [Instant]
  }
  deriving stock (Eq, Show)

-- | An arc's whole answer to a marking.
data Offer
  = -- | The arc gates its transition out.
    Veto
  | -- | An inhibit arc below weight: satisfied, contributing nothing.
    Satisfied
  | -- | Every combination of @weight@ admitted tokens, head first.
    Alternatives Arc [Alternative]
  deriving stock (Eq, Show)

type Diagnose = State [Diagnostic]

diagnose :: Diagnostic -> Diagnose ()
diagnose d = modify' (d :)

-- | The arc's answer to the marking. @anchors@ is each place's entry instants
-- (position-aligned), passed only when the transition's timers demand them.
offer ::
  Arc ->
  Marking ->
  Implementations ->
  Maybe (Map NetPath (Seq Instant)) ->
  Maybe NetUri ->
  Diagnose (Either EnablednessError Offer)
offer a marking impls anchorMap filterIdentity = do
  let queue = timeBlind (placeTokens a.source marking)
  case filterJudgment impls a filterIdentity of
    Left err -> pure (Left err)
    Right admits -> case a.mode of
      Inhibit -> do
        positions <- admittedBy admits (Just a.weight) queue
        pure $ case positions of
          Left err -> Left (InvalidLimit err)
          Right ps
            | length ps >= a.weight -> Right Veto
            | otherwise -> Right Satisfied
      _ -> do
        positions <- admittedBy admits Nothing queue
        pure $ case positions of
          Left err -> Left (InvalidLimit err)
          Right ps
            | length ps < a.weight -> Right Veto
            | otherwise -> do
                let tokens = Seq.fromList (toList (queueTokens queue))
                instants <- case anchorMap of
                  Nothing -> Right Nothing
                  Just m -> do
                    let recorded = Map.findWithDefault Seq.empty a.source m
                        reach = last ps
                    if reach >= Seq.length recorded
                      then Left (MisalignedInstants a.target a.source (Seq.length recorded) reach)
                      else Right (Just recorded)
                Right
                  ( Alternatives
                      a
                      [ Alternative
                          (a.source, map (Seq.index tokens) combination)
                          (maybe [] (\recorded -> map (Seq.index recorded) combination) instants)
                      | combination <- combinations a.weight ps
                      ]
                  )

-- | @itertools.combinations@: lexicographic in input order.
combinations :: Int -> [a] -> [[a]]
combinations 0 _ = [[]]
combinations _ [] = []
combinations k (x : xs) = map (x :) (combinations (k - 1) xs) ++ combinations k xs

-- | The arc's admission judgment, with the filter resolved once.
filterJudgment :: Implementations -> Arc -> Maybe NetUri -> Either EnablednessError (Token -> Diagnose Bool)
filterJudgment impls a filterIdentity = case a.filter of
  Nothing -> Right (\t -> pure (arcAdmits a t.color))
  Just declaration -> do
    implementation <- filterImplementation impls filterIdentity declaration
    Right $ \t ->
      if not (arcAdmits a t.color)
        then pure False
        else case implementation t of
          Right ok -> pure ok
          Left failure -> do
            diagnose (FilterEvaluationFailed declaration filterIdentity failure t)
            pure False

-- | Whether the arc admits the token: the inscription's color narrowed by
-- its optional filter, with any evaluation diagnostic.
admitted :: Arc -> Token -> Implementations -> Maybe NetUri -> Either EnablednessError (Bool, [Diagnostic])
admitted a t impls identity = do
  judge <- filterJudgment impls a identity
  let (ok, ds) = runState (judge t) []
  Right (ok, reverse ds)

-- | The head selection an arc makes from a queue: the first @weight@
-- admitted tokens, front-to-back.
selection :: Arc -> [Token] -> Implementations -> Either EnablednessError ([Token], [Diagnostic])
selection a queue impls = do
  judge <- filterJudgment impls a Nothing
  let scanned = timeBlind queue
      (positions, ds) = runState (admittedBy judge (Just a.weight) scanned) []
  ps <- either (Left . InvalidLimit) Right positions
  let tokens = Seq.fromList queue
  Right (map (Seq.index tokens) ps, reverse ds)

-- | Whether all declared guards hold — conjunction, short-circuiting at the
-- first failure (diagnostics follow declaration order and stop there).
guardsHold :: Transition -> Binding -> Implementations -> [NetUri] -> Either EnablednessError (Diagnose Bool)
guardsHold t b impls identities = do
  resolved <-
    mapM
      ( \(position, declaration) ->
          let identity = if null identities then Nothing else Just (identities !! position)
           in (declaration,identity,) <$> guardImplementation impls identity declaration
      )
      (zip [0 :: Int ..] t.guards)
  Right (go resolved)
  where
    go [] = pure True
    go ((declaration, identity, g) : rest) = case g b of
      Left failure -> do
        diagnose (GuardEvaluationFailed declaration identity b.transition failure (bindingPeeked b))
        pure False
      Right False -> pure False
      Right True -> go rest

-- ---------------------------------------------------------------------------
-- Candidates

-- | The clock a timed survey requires: the watermark and each place
-- queue's recorded entry instants (position-aligned).
data Clock = Clock
  { watermark :: Instant
  , entryInstants :: Map NetPath (Seq Instant)
  }
  deriving stock (Eq, Show)

-- | A clock with a watermark and no recorded instants (enough for nets
-- whose timers are all @Until@).
clockAt :: Instant -> Clock
clockAt w = Clock w Map.empty

-- | One enumeration's results: the enabled bindings, the maturation instants
-- of bindings waiting only on time, and the evaluation diagnostics.
data Survey = Survey
  { enabled :: [Binding]
  , pending :: [Instant]
  , diagnostics :: [Diagnostic]
  }
  deriving stock (Show)

-- | The shared enumeration behind 'candidates' and 'nextMaturation'.
survey :: Net -> Marking -> Implementations -> Maybe Clock -> Either EnablednessError Survey
survey net marking impls clock = do
  let timed = any (\(p, t) -> not (null t.timers) && not (isSource net p)) (Map.toList (netTransitions net))
  case clock of
    Nothing | timed -> Left ClockRequired
    _ -> Right ()
  let (result, ds) = runState (foldM step (Right ([], [])) (Map.toList (netTransitions net))) []
  (enabledRev, pendingRev) <- result
  Right (Survey (reverse enabledRev) (reverse pendingRev) (reverse ds))
  where
    step (Left err) _ = pure (Left err)
    step (Right acc) (at, t)
      | isSource net at = pure (Right acc)
      | otherwise = transitionSurvey at t acc
    transitionSurvey at t (enabledAcc, pendingAcc) = do
      let anchored = or [True | Delay _ <- t.timers]
          anchorMap = if anchored then Just (maybe Map.empty (.entryInstants) clock) else Nothing
      offers <- collectOffers anchorMap (inputPositions net at) []
      case offers of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right (enabledAcc, pendingAcc))
        Right (Just answers) ->
          case guardsHoldPrepared t at of
            Left err -> pure (Left err)
            Right holds ->
              let choose acc choice = do
                    let (consumedSel, readSel, anchors) = assemble (zip answers choice)
                        b = selectionBinding at consumedSel readSel
                    ok <- holds b
                    if not ok
                      then pure acc
                      else
                        let mature = maturation t.timers (if null anchors then Nothing else Just (maximum anchors))
                         in pure $ case mature of
                              Nothing -> addEnabled b acc
                              Just instant
                                | maybe False (\c -> instant <= c.watermark) clock -> addEnabled b acc
                                | otherwise -> addPending instant acc
               in Right <$> foldM choose (enabledAcc, pendingAcc) (sequence [alternatives | (_, alternatives) <- answers])
    addEnabled b (e, p) = (b : e, p)
    addPending i (e, p) = (e, i : p)
    guardsHoldPrepared t at = do
      let identities = guardUris net at
      _ <- mapM (\(position, declaration) -> guardImplementation impls (lookupAt identities position) declaration) (zip [0 :: Int ..] t.guards)
      Right (\b -> either (const (pure False)) id (guardsHold t b impls identities))
    lookupAt xs position = if position < length xs then Just (xs !! position) else Nothing
    collectOffers _ [] acc = pure (Right (Just (reverse acc)))
    collectOffers anchorMap ((position, a, filterUri) : rest) acc = do
      _ <- pure position
      answer <- offer a marking impls anchorMap filterUri
      case answer of
        Left err -> pure (Left err)
        Right Veto -> pure (Right Nothing)
        Right Satisfied -> collectOffers anchorMap rest acc
        Right (Alternatives arcValue alternatives) -> collectOffers anchorMap rest ((arcValue, alternatives) : acc)
    assemble :: [((Arc, [Alternative]), Alternative)] -> ([Selection], [Selection], [Instant])
    assemble = foldr placeOne ([], [], [])
      where
        placeOne ((arcValue, _), alternative) (c, r, i)
          | arcValue.mode == Consume = (alternative.selection : c, r, alternative.anchors ++ i)
          | otherwise = (c, alternative.selection : r, alternative.anchors ++ i)

-- | Enabled firing candidates in stable (path-sorted) order. Source
-- transitions are excluded: they fire only on external delivery.
candidates :: Net -> Marking -> Implementations -> Maybe Clock -> Either EnablednessError [Binding]
candidates net marking impls clock = (.enabled) <$> survey net marking impls clock

-- | Candidates with the evaluation diagnostics the survey surfaced.
candidatesWithDiagnostics :: Net -> Marking -> Implementations -> Maybe Clock -> Either EnablednessError ([Binding], [Diagnostic])
candidatesWithDiagnostics net marking impls clock = (\s -> (s.enabled, s.diagnostics)) <$> survey net marking impls clock

-- | The earliest maturation among bindings enabled but for their timers.
nextMaturation :: Net -> Marking -> Implementations -> Maybe Clock -> Either EnablednessError (Maybe Instant)
nextMaturation net marking impls clock = do
  s <- survey net marking impls clock
  Right (if null s.pending then Nothing else Just (minimum s.pending))

-- | The instant at which every declared timer has matured: the latest of
-- each @Delay@'s @anchor + duration@ and each @Until@'s instant; 'Nothing'
-- without timers. Net validation guarantees a @Delay@ has an anchor; an
-- anchorless @Delay@ (unreachable through a valid net) contributes nothing.
maturation :: [Timer] -> Maybe Instant -> Maybe Instant
maturation [] _ = Nothing
maturation timers anchor =
  let instants = [i | timer <- timers, Just i <- [timerInstant timer]]
   in if null instants then Nothing else Just (maximum instants)
  where
    timerInstant = \case
      Delay duration -> (+ duration) <$> anchor
      Until instant -> Just instant

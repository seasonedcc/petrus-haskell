-- | Instance-scoped selection of one already-enabled firing 'Binding'
-- (@petrus.impetus.selection@).
--
-- Selection is a pure proposal. Policy state moves only when the Engine has
-- committed the corresponding begin, and load reconstructs it from the
-- existing @CandidateSelected@/@FiringBegun@ pairs without adding History
-- facts.
--
-- The reference's policy state is an untyped @object@; here every policy
-- names its state type, so a 'RoundRobin' cursor is an 'Int' and the
-- stateless policies carry @()@. 'SelectionPipeline' is generic in its
-- strategy's state.
module Petrus.Impetus.Selection
  ( -- * Proposals
    SelectionProposal (..)
  , SelectionPolicy (..)
    -- * Strategies
  , first
  , priority
  , RoundRobinState
  , roundRobin
    -- * Pipelines
  , AdmissionFilter
  , StableRanker (..)
  , ranker
  , selectionPipeline
  , defaultPipeline
    -- * Replay
  , foldHistory
  ) where

import Control.Monad (foldM, forM_, unless, when)
import Data.Foldable (toList)
import Data.IntMap.Strict qualified as IntMap
import Data.List (elemIndex, nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Impetus.History.Records
import Petrus.Json.Python (pythonIntRepr)
import Petrus.Impetus.Petrinet.Enabledness (Binding (..))
import Petrus.Impetus.Petrinet.Schema (NetPath, netPathText)

-- | One proposed binding and the state change its commit earns.
data SelectionProposal s = SelectionProposal
  { binding :: Binding
  , priorState :: s
  , nextState :: s
  }
  deriving stock (Eq, Show)

-- | A pure proposal plus reconstruction from one committed transition.
-- Refusals carry the reference's @ValueError@ text.
data SelectionPolicy s = SelectionPolicy
  { propose :: [Binding] -> s -> Either Text (Maybe (SelectionProposal s))
  , foldCommitted :: s -> NetPath -> Either Text s
  }

-- | @First()@: the first binding in Petrinet enumeration order.
first :: SelectionPolicy s
first =
  SelectionPolicy
    { propose = \candidates state -> Right $ case candidates of
        [] -> Nothing
        c : _ -> Just (SelectionProposal c state state)
    , foldCommitted = \state _ -> Right state
    }

-- | @Priority(priorities)@: highest configured transition priority first;
-- original order breaks ties (Python's @max@ keeps the first maximum).
priority :: Map NetPath Integer -> SelectionPolicy s
priority priorities =
  SelectionPolicy
    { propose = \candidates state -> Right $ case candidates of
        [] -> Nothing
        c : cs -> Just (SelectionProposal (foldl better c cs) state state)
    , foldCommitted = \state _ -> Right state
    }
  where
    rank b = Map.findWithDefault 0 b.transition priorities
    better best c = if rank c > rank best then c else best

-- | A round-robin cursor: the index into the ring, or 'Nothing' before the
-- first commit (the reference's @None@).
type RoundRobinState = Maybe Int

-- | @RoundRobin(transitions)@: transition-level rotation; each transition's
-- first binding wins its tie.
roundRobin :: [NetPath] -> Either Text (SelectionPolicy RoundRobinState)
roundRobin ring = do
  when (null ring || length (nub ring) /= length ring) $
    Left "round-robin transitions must be a non-empty unique sequence"
  let size = length ring
      propose' candidates state = case candidates of
        [] -> Right Nothing
        _ -> do
          cursor <- maybe (Right 0) (\c -> if c >= 0 && c < size then Right c else Left ("invalid round-robin state: " <> pythonIntRepr c)) state
          let firstFor t = case [c | c <- candidates, c.transition == t] of
                c : _ -> Just c
                [] -> Nothing
              walk offset
                | offset >= size = Left "offered candidates are outside the round-robin transition ring"
                | otherwise =
                    let index = (cursor + offset) `mod` size
                     in case firstFor (ring !! index) of
                          Just c -> Right (Just (SelectionProposal c state (Just ((index + 1) `mod` size))))
                          Nothing -> walk (offset + 1)
          walk 0
      fold' _ transition = case elemIndex transition ring of
        Just index -> Right (Just ((index + 1) `mod` size))
        Nothing ->
          Left ("committed transition " <> netPathText transition <> " is outside the round-robin transition ring")
  Right (SelectionPolicy propose' fold')

-- | A fixed admission rule over candidate bindings.
type AdmissionFilter = Binding -> Bool

-- | A stable ranking key. The reference's rankers return any mutually
-- orderable key; here the key type is existential with an 'Ord' instance,
-- which makes "mutually orderable" a type guarantee.
data StableRanker = forall k. Ord k => StableRanker (Binding -> k)

-- | Wrap a ranking key function.
ranker :: Ord k => (Binding -> k) -> StableRanker
ranker = StableRanker

-- | @SelectionPipeline(filters=..., rankers=..., strategy=...)@: fixed
-- filters, then stable rankers (the last ranker sorts first, so the first
-- ranker is the primary key), then one strategy. The pipeline refuses a
-- strategy that proposes outside the admitted candidates or that does not
-- carry the pipeline's prior state.
selectionPipeline :: Eq s => [AdmissionFilter] -> [StableRanker] -> SelectionPolicy s -> SelectionPolicy s
selectionPipeline filters rankers strategy =
  SelectionPolicy
    { propose = \candidates state -> do
        let admitted0 = [c | c <- candidates, all ($ c) filters]
            admitted = foldr (\(StableRanker key) acc -> sortOn key acc) admitted0 rankers
        if null admitted
          then Right Nothing
          else do
            proposal <- strategy.propose admitted state
            forM_ proposal $ \p -> do
              unless (p.binding `elem` admitted) $
                Left "selection strategy proposed a binding outside the admitted candidates"
              unless (p.priorState == state) $
                Left "selection strategy proposal does not carry the pipeline's prior state"
            Right proposal
    , foldCommitted = strategy.foldCommitted
    }

-- | @SelectionPipeline()@: no filters, no rankers, 'first'.
defaultPipeline :: Eq s => SelectionPolicy s
defaultPipeline = selectionPipeline [] [] first

-- | @fold_history@: fold exact selected+begun pairs; an orphan selection
-- advances no policy state.
foldHistory :: Foldable f => SelectionPolicy s -> s -> f Record -> Either Text s
foldHistory policy state0 history = do
  (selected, order, begun) <- foldM collect (IntMap.empty, [], IntMap.empty) (toList history)
  foldM (advance selected begun) state0 (reverse order)
  where
    collect (selected, order, begun) = \case
      RCandidateSelected r
        | IntMap.member r.occurrence selected ->
            Left
              ( "selection replay divergence: duplicate CandidateSelected for occurrence "
                  <> pythonIntRepr r.occurrence
              )
        | otherwise -> Right (IntMap.insert r.occurrence r.transition selected, r.occurrence : order, begun)
      RFiringBegun r -> Right (selected, order, IntMap.insertWith (flip (++)) r.occurrence [r.transition] begun)
      _ -> Right (selected, order, begun)
    advance selected begun state occurrence = do
      let transition = selected IntMap.! occurrence
      case IntMap.findWithDefault [] occurrence begun of
        [] -> Right state
        [began]
          | began /= transition ->
              Left
                ( "selection replay divergence: occurrence "
                    <> pythonIntRepr occurrence
                    <> " selected "
                    <> netPathText transition
                    <> " but began "
                    <> netPathText began
                )
          | otherwise -> policy.foldCommitted state transition
        _ -> Left ("selection replay divergence: duplicate FiringBegun for occurrence " <> pythonIntRepr occurrence)

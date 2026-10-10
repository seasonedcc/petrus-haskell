-- | History-independent Petri firing movement transforms
-- (@petrus.impetus.petrinet.firing@).
module Petrus.Impetus.Petrinet.Firing
  ( BeginEffect (..)
  , ProducedTokens (..)
  , beginFiring
  , completeFiring
  ) where

import Control.Monad (foldM)
import Data.Text (Text)
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Petrinet.Enabledness (Binding (..))
import Petrus.Impetus.Petrinet.Marking
import Petrus.Impetus.Petrinet.Schema

-- | One input arc's ordered movement: a consume removes its tokens, a read
-- observes them in place.
data BeginEffect
  = ConsumedTokens NetPath [Token]
  | ReadTokens NetPath [Token]
  deriving stock (Eq, Show)

-- | The ordered tokens deposited at one resolved output place.
data ProducedTokens = ProducedTokens NetPath [Token]
  deriving stock (Eq, Show)

-- | Apply consumes before validating the non-removing reads; return the
-- arc-ordered effects and the resulting marking.
beginFiring :: Marking -> Binding -> Either Text ([BeginEffect], Marking)
beginFiring marking b = do
  afterConsume <- foldM (\m (p, ts) -> consume p ts m) marking b.consumed
  mapM_
    ( \(p, ts) -> case removeTokens ts (timeBlind (placeTokens p afterConsume)) of
        Left missing -> Left ("cannot read " <> reprToken missing <> " from " <> netPathText p <> ": token not present")
        Right _ -> Right ()
    )
    b.read
  Right ([ConsumedTokens p ts | (p, ts) <- b.consumed] ++ [ReadTokens p ts | (p, ts) <- b.read], afterConsume)

-- | Route projected tokens through the transition's output arcs, coalescing
-- repeated destinations in first-seen order; a token no output arc to its
-- destination admits is dropped, and a destination left empty produces no
-- effect.
completeFiring :: Net -> Marking -> NetPath -> [(NetPath, [Token])] -> ([ProducedTokens], Marking)
completeFiring net marking at projected =
  let outs = outputs net at
      emitted = OMap.toList (foldl (\m (p, ts) -> OMap.insertWith (\new old -> old ++ new) p ts m) OMap.empty projected)
      step (effects, m) (p, ts) =
        case [t | t <- ts, any (\a -> a.target == p && arcAdmits a t.color) outs] of
          [] -> (effects, m)
          deposited -> (ProducedTokens p deposited : effects, foldl (flip (deposit p)) m deposited)
      (effectsRev, final) = foldl step ([], marking) emitted
   in (reverse effectsRev, final)

-- | Release effect execution after the initial summary lands
-- (@net_v5/startup.py@).
--
-- Intake and pure folds can accumulate observations and route recovery
-- while startup waits. The pending token is consumed once; later dashboard
-- updates cannot suspend the workflow. Existing Histories have no pending
-- token and retain their already-started workflow.
module Hamsterdan.Readiness.NetV5.Startup
  ( declare
  , wire
  , seed
  , settled
  ) where

import Control.Monad (forM_, unless, void)
import Data.Text (Text)
import Hamsterdan.Contracts.ReadinessV5 (SummaryPending (..))
import Hamsterdan.Readiness.NetV5.Folding (Fold)
import Hamsterdan.Readiness.NetV5.Wiring (inhibit, place, seedToken)
import Petrus.Impetus.Binding (handlerTokens)
import Petrus.Impetus.Dsl (Author, configure, handler, p, petriHandler, t, (~>))
import Petrus.Impetus.Petrinet (NetPath, Token)

-- | @_settled@: consumes its inputs and emits nothing.
settled :: Fold
settled _ _ = Right (handlerTokens [])

declare :: Author s ()
declare = do
  place "startup.pending" "SummaryPending"
  place "startup.published" "SummaryPublished"

-- | Wire startup given the composed gate table (transition path → activity
-- and variants), in the table's order; the dashboard's own gate is exempt.
wire :: [(Text, (Text, [Text]))] -> Author s ()
wire gateTable = do
  pending <- p "startup.pending"
  published <- p "startup.published"
  finish <- t "startup.finish" >>= configure [handler (petriHandler "_settled" settled)]
  void ([pending, published] ~> finish)
  absorb <- t "startup.absorb_update" >>= configure [handler (petriHandler "_settled" settled)]
  void (published ~> absorb)
  inhibit "startup.pending" "startup.absorb_update"
  forM_ gateTable $ \(path, (activity, _)) ->
    unless (activity == "dash_gate") (inhibit "startup.pending" path)

seed :: [(NetPath, [Token])]
seed = [("startup.pending", [seedToken SummaryPending])]

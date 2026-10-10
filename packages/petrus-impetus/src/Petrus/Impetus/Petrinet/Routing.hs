-- | Pure output-arc routing (@petrus.impetus.petrinet.routing@).
module Petrus.Impetus.Petrinet.Routing
  ( route
  ) where

import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Petrinet.Marking (Token (..))
import Petrus.Impetus.Petrinet.Schema

-- | Route each token to every output arc that admits it, preserving order
-- and concatenating per target (targets in first-routed order). Tokens
-- admitted by no output are dropped.
route :: [Token] -> [Arc] -> [(NetPath, [Token])]
route tokens outputArcs =
  OMap.toList $
    foldl
      ( \routed a ->
          case [t | t <- tokens, arcAdmits a t.color] of
            [] -> routed
            admittedTokens -> OMap.insertWith (\new old -> old ++ new) a.target admittedTokens routed
      )
      OMap.empty
      outputArcs

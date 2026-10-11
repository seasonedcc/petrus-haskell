-- | The host's current authority claim for one PR Instance
-- (@host/v5/claim.py@).
module Hamsterdan.Host.V5.Claim
  ( CurrentClaim (..)
  , ClaimReader
  , claimAsMap
  ) where

import Data.Text (Text)
import Petrus.Json (Json (..))

-- | @CurrentClaim(phase, incarnation, head, base, policy)@.
data CurrentClaim = CurrentClaim
  { phase :: Text
  -- ^ @running@, @quiescent@, or @terminal@.
  , incarnation :: Integer
  , head :: Text
  , base :: Text
  , policy :: Text
  }
  deriving stock (Eq, Show)

-- | @ClaimReader = Callable[[], CurrentClaim]@.
type ClaimReader = IO CurrentClaim

-- | @claim.__dict__@.
claimAsMap :: CurrentClaim -> Json
claimAsMap c =
  Object
    [ ("phase", String c.phase)
    , ("incarnation", Int c.incarnation)
    , ("head", String c.head)
    , ("base", String c.base)
    , ("policy", String c.policy)
    ]

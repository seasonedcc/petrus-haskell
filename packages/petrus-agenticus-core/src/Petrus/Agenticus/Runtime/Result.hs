-- | Lifecycle-only candidate results from provider/profile-specific runtimes
-- (@petrus.agenticus.runtime.result@).
module Petrus.Agenticus.Runtime.Result
  ( safeTerminationCode
  , RuntimeTurnSettlement
      ( episodeId
      , turnId
      , outcome
      , acceptedAppends
      , terminationCode
      , outputReference
      , continuationReference
      )
  , mkRuntimeTurnSettlement
  ) where

import Data.Text (Text)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate
import Petrus.Agenticus.Thread.Identity
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))

maxReferenceBytes :: Int
maxReferenceBytes = 512

reference :: Text -> Text -> Either AgenticusError Text
reference label value
  | isBoundedText maxReferenceBytes value = Right value
  | otherwise = Left (valueError (label <> " must be a bounded non-empty opaque reference"))

-- | Validate one machine-safe code suitable for lifecycle evidence.
safeTerminationCode :: Text -> Either AgenticusError Text
safeTerminationCode value
  | isMachineToken value = Right value
  | otherwise = Left (valueError "runtime termination code must be a bounded lowercase machine token")

-- | A candidate host result, not authority to settle a Turn or Episode.
--
-- One accepted append is one complete runtime Turn batch.  Provider
-- messages, prompts, tool bodies, usage bodies, authority, paths, and raw
-- diagnostics remain behind the opaque references and profile-specific
-- custody.  'Show' never renders the two references.
data RuntimeTurnSettlement = RuntimeTurnSettlement
  { episodeId :: EpisodeId
  , turnId :: TurnId
  , outcome :: TurnOutcome
  , acceptedAppends :: Integer
  , terminationCode :: Text
  , outputReference :: Maybe Text
  , continuationReference :: Maybe Text
  }
  deriving stock (Eq)

instance Show RuntimeTurnSettlement where
  showsPrec d r =
    showParen (d > 10) $
      showString "RuntimeTurnSettlement {episodeId = "
        . shows r.episodeId
        . showString ", turnId = "
        . shows r.turnId
        . showString ", outcome = "
        . shows r.outcome
        . showString ", acceptedAppends = "
        . shows r.acceptedAppends
        . showString ", terminationCode = "
        . shows r.terminationCode
        . showString "}"

mkRuntimeTurnSettlement
  :: EpisodeId
  -> TurnId
  -> TurnOutcome
  -> Integer
  -> Text
  -> Maybe Text
  -> Maybe Text
  -> Either AgenticusError RuntimeTurnSettlement
mkRuntimeTurnSettlement e t o a code out cont = do
  require (a == 0 || a == 1) (valueError "runtime result accepted_appends must be zero or one complete Turn batch")
  require
    (not (o == TurnCompleted && a /= 1))
    (valueError "a completed runtime Turn requires its one complete accepted append")
  code' <- safeTerminationCode code
  out' <- traverse (reference "runtime output_reference") out
  cont' <- traverse (reference "runtime continuation_reference") cont
  pure (RuntimeTurnSettlement e t o a code' out' cont')

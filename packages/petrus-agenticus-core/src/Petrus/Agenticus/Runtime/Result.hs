-- | Lifecycle-only candidate results from provider/profile-specific runtimes
-- (@petrus.agenticus.runtime.result@).
module Petrus.Agenticus.Runtime.Result
  ( safeTerminationCode
  , RuntimeTurnSettlement
  , mkRuntimeTurnSettlement
  ) where

import Data.Text (Text)
import GHC.Records (HasField (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate
import Petrus.Agenticus.Thread.Identity
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))

maxReferenceBytes :: Int
maxReferenceBytes = 512

reference :: Text -> Text -> Either AgenticusError Text
reference label = checkedText maxReferenceBytes (valueError (label <> " must be a bounded non-empty opaque reference"))

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
  { _episodeId :: EpisodeId
  , _turnId :: TurnId
  , _outcome :: TurnOutcome
  , _acceptedAppends :: Integer
  , _terminationCode :: Text
  , _outputReference :: Maybe Text
  , _continuationReference :: Maybe Text
  }
  deriving stock (Eq)

instance HasField "episodeId" RuntimeTurnSettlement EpisodeId where
  getField r = r._episodeId

instance HasField "turnId" RuntimeTurnSettlement TurnId where
  getField r = r._turnId

instance HasField "outcome" RuntimeTurnSettlement TurnOutcome where
  getField r = r._outcome

instance HasField "acceptedAppends" RuntimeTurnSettlement Integer where
  getField r = r._acceptedAppends

instance HasField "terminationCode" RuntimeTurnSettlement Text where
  getField r = r._terminationCode

instance HasField "outputReference" RuntimeTurnSettlement (Maybe Text) where
  getField r = r._outputReference

instance HasField "continuationReference" RuntimeTurnSettlement (Maybe Text) where
  getField r = r._continuationReference

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

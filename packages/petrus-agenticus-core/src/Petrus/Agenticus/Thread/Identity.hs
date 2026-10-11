-- | Runtime-distinct identities for Thread lifecycle values
-- (@petrus.agenticus.thread.identity@).
--
-- Upstream subclasses one frozen dataclass four times so that equal text in
-- different roles never compares equal.  Here each role is its own newtype,
-- so mixing them up is a type error rather than a runtime inequality.
module Petrus.Agenticus.Thread.Identity
  ( ThreadId
  , ContinuationId
  , EpisodeId
  , TurnId
  , LifecycleId (lifecycleIdText, lifecycleIdClass)
  , mkLifecycleId
  , lifecycleIdToData
  , lifecycleIdFromData
    -- * Per-role constructors
  , mkThreadId
  , mkContinuationId
  , mkEpisodeId
  , mkTurnId
    -- * Literals (a programming error when invalid)
  , literalThreadId
  , literalContinuationId
  , literalEpisodeId
  , literalTurnId
  ) where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

-- | Durable identity of one Thread lineage.
newtype ThreadId = ThreadId Text
  deriving stock (Eq, Ord, Show)

-- | Identity of one resumable Continuation revision.
newtype ContinuationId = ContinuationId Text
  deriving stock (Eq, Ord, Show)

-- | Identity of one bounded Agent Program execution.
newtype EpisodeId = EpisodeId Text
  deriving stock (Eq, Ord, Show)

-- | Identity of one bounded progression step within an Episode.
newtype TurnId = TurnId Text
  deriving stock (Eq, Ord, Show)

-- | The four lifecycle identity roles.
class (Ord a, Show a) => LifecycleId a where
  -- | The upstream class name, used in refusal messages.
  lifecycleIdClass :: proxy a -> Text

  -- | The validated text (@.value@).
  lifecycleIdText :: a -> Text

  wrapLifecycleId :: Text -> a

instance LifecycleId ThreadId where
  lifecycleIdClass _ = "ThreadId"
  lifecycleIdText (ThreadId t) = t
  wrapLifecycleId = ThreadId

instance LifecycleId ContinuationId where
  lifecycleIdClass _ = "ContinuationId"
  lifecycleIdText (ContinuationId t) = t
  wrapLifecycleId = ContinuationId

instance LifecycleId EpisodeId where
  lifecycleIdClass _ = "EpisodeId"
  lifecycleIdText (EpisodeId t) = t
  wrapLifecycleId = EpisodeId

instance LifecycleId TurnId where
  lifecycleIdClass _ = "TurnId"
  lifecycleIdText (TurnId t) = t
  wrapLifecycleId = TurnId

refusal :: forall a. (LifecycleId a) => Proxy a -> AgenticusError
refusal p =
  valueError (lifecycleIdClass p <> " value must be a non-empty, trimmed string of at most 256 UTF-8 bytes")

-- | @Cls(value)@.
mkLifecycleId :: forall a. (LifecycleId a) => Text -> Either AgenticusError a
mkLifecycleId value = wrapLifecycleId <$> checkedText maxTextBytes (refusal (Proxy @a)) value

-- | @to_data()@: the bare string.
lifecycleIdToData :: (LifecycleId a) => a -> Json
lifecycleIdToData = String . lifecycleIdText

-- | @Cls.from_data(data)@: non-strings are refused with the same message.
lifecycleIdFromData :: forall a. (LifecycleId a) => Json -> Either AgenticusError a
lifecycleIdFromData = \case
  String t -> mkLifecycleId t
  _ -> Left (refusal (Proxy @a))

mkThreadId :: Text -> Either AgenticusError ThreadId
mkThreadId = mkLifecycleId

mkContinuationId :: Text -> Either AgenticusError ContinuationId
mkContinuationId = mkLifecycleId

mkEpisodeId :: Text -> Either AgenticusError EpisodeId
mkEpisodeId = mkLifecycleId

mkTurnId :: Text -> Either AgenticusError TurnId
mkTurnId = mkLifecycleId

literal :: (LifecycleId a) => Text -> a
literal = either (error . T.unpack . errorMessage) id . mkLifecycleId

literalThreadId :: Text -> ThreadId
literalThreadId = literal

literalContinuationId :: Text -> ContinuationId
literalContinuationId = literal

literalEpisodeId :: Text -> EpisodeId
literalEpisodeId = literal

literalTurnId :: Text -> TurnId
literalTurnId = literal

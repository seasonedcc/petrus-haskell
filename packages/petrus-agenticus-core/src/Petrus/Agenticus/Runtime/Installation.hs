-- | Provider-neutral, secret-free Agent Runtime installation probe facts
-- (@petrus.agenticus.runtime.installation@).
module Petrus.Agenticus.Runtime.Installation
  ( -- * Probe dispositions
    ProbeDisposition (..)
  , probeDispositionText
    -- * Installed components
  , InstalledComponent
  , mkInstalledComponent
    -- * Probe issues
  , ProbeIssue
  , mkProbeIssue
    -- * Installations
  , RuntimeInstallation
  , mkRuntimeInstallation
    -- * Probe results
  , RuntimeProbeResult
  , mkRuntimeProbeResult
  ) where

import Data.List (sort)
import Data.Set (Set)
import Data.Text (Text)
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate

text :: Text -> Text -> Either AgenticusError Text
text label = checkedText maxTextBytes (valueError (label <> " must be a bounded non-empty text value"))

runtimeIdentity :: DescriptorIdentity -> Either AgenticusError DescriptorIdentity
runtimeIdentity i
  | i.kind == KindRuntime = Right i
  | otherwise = Left (typeError "runtime installation identity must be a runtime DescriptorIdentity")

capability :: Text -> Text -> Either AgenticusError Text
capability label value
  | isMachineToken value = Right value
  | otherwise = Left (valueError (label <> " must be a bounded lowercase capability token"))

-- | The safe pre-materialization result of probing one exact runtime profile.
data ProbeDisposition
  = ProbeReady
  | ProbeNotInstalled
  | ProbeIncompatible
  | ProbeUnavailable
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum ProbeDisposition where
  enumText = \case
    ProbeReady -> "ready"
    ProbeNotInstalled -> "not-installed"
    ProbeIncompatible -> "incompatible"
    ProbeUnavailable -> "unavailable"

probeDispositionText :: ProbeDisposition -> Text
probeDispositionText = enumText

-- | One observed package/client pin without an executable or home path.
-- Ordered like the @order=True@ dataclass.
data InstalledComponent = InstalledComponent
  { _name :: Text
  , _version :: Text
  , _sourceIdentity :: Text
  }
  deriving stock (Eq, Ord, Show)

instance HasField "name" InstalledComponent Text where
  getField r = r._name

instance HasField "version" InstalledComponent Text where
  getField r = r._version

instance HasField "sourceIdentity" InstalledComponent Text where
  getField r = r._sourceIdentity

mkInstalledComponent :: Text -> Text -> Text -> Either AgenticusError InstalledComponent
mkInstalledComponent n v s =
  InstalledComponent
    <$> text "installed component name" n
    <*> text "installed component version" v
    <*> text "installed component source identity" s

-- | A machine-safe probe issue; raw command or provider diagnostics stay
-- private.  Ordered by @(code, component)@ with an absent component first
-- (see @divergences/thread.md@).
data ProbeIssue = ProbeIssue
  { _code :: Text
  , _component :: Maybe Text
  }
  deriving stock (Eq, Ord, Show)

instance HasField "code" ProbeIssue Text where
  getField r = r._code

instance HasField "component" ProbeIssue (Maybe Text) where
  getField r = r._component

mkProbeIssue :: Text -> Maybe Text -> Either AgenticusError ProbeIssue
mkProbeIssue c comp =
  ProbeIssue
    <$> capability "probe issue code" c
    <*> traverse (text "probe issue component") comp

-- | Exact qualified installation facts, with no authority, content, or path
-- fields.  Components are sorted.
data RuntimeInstallation = RuntimeInstallation
  { _runtime :: DescriptorIdentity
  , _adapterContractVersion :: Integer
  , _components :: [InstalledComponent]
  , _platform :: Text
  , _architecture :: Text
  , _capabilities :: Set Text
  }
  deriving stock (Eq, Show)

instance HasField "runtime" RuntimeInstallation DescriptorIdentity where
  getField r = r._runtime

instance HasField "adapterContractVersion" RuntimeInstallation Integer where
  getField r = r._adapterContractVersion

instance HasField "components" RuntimeInstallation [InstalledComponent] where
  getField r = r._components

instance HasField "platform" RuntimeInstallation Text where
  getField r = r._platform

instance HasField "architecture" RuntimeInstallation Text where
  getField r = r._architecture

instance HasField "capabilities" RuntimeInstallation (Set Text) where
  getField r = r._capabilities

mkRuntimeInstallation
  :: DescriptorIdentity
  -> Integer
  -> [InstalledComponent]
  -> Text
  -> Text
  -> Set Text
  -> Either AgenticusError RuntimeInstallation
mkRuntimeInstallation r v cs p a caps = do
  _ <- runtimeIdentity r
  require (v > 0) (valueError "runtime adapter contract version must be a positive integer")
  require (not (null cs)) (typeError "runtime installation components must contain InstalledComponent values")
  require (not (hasDuplicates [c.name | c <- cs])) (valueError "runtime installation component names must be unique")
  p' <- text "runtime installation platform" p
  a' <- text "runtime installation architecture" a
  mapM_ (capability "runtime installation capability") caps
  pure (RuntimeInstallation r v (sort cs) p' a' caps)

-- | One strict probe verdict produced before Agent Connection
-- materialization.  Issues are unique and sorted.
data RuntimeProbeResult = RuntimeProbeResult
  { _runtime :: DescriptorIdentity
  , _disposition :: ProbeDisposition
  , _installation :: Maybe RuntimeInstallation
  , _issues :: [ProbeIssue]
  }
  deriving stock (Eq, Show)

instance HasField "runtime" RuntimeProbeResult DescriptorIdentity where
  getField r = r._runtime

instance HasField "disposition" RuntimeProbeResult ProbeDisposition where
  getField r = r._disposition

instance HasField "installation" RuntimeProbeResult (Maybe RuntimeInstallation) where
  getField r = r._installation

instance HasField "issues" RuntimeProbeResult [ProbeIssue] where
  getField r = r._issues

mkRuntimeProbeResult
  :: DescriptorIdentity
  -> ProbeDisposition
  -> Maybe RuntimeInstallation
  -> [ProbeIssue]
  -> Either AgenticusError RuntimeProbeResult
mkRuntimeProbeResult r d inst is = do
  _ <- runtimeIdentity r
  require (not (hasDuplicates is)) (valueError "runtime probe issues must be unique")
  let present = inst /= Nothing
      anyIssues = not (null is)
  case d of
    ProbeReady ->
      require (present && not anyIssues) (valueError "a ready runtime probe requires an installation and no issues")
    ProbeIncompatible ->
      require
        (present && anyIssues)
        (valueError "an incompatible runtime probe requires observed installation facts and issues")
    ProbeNotInstalled ->
      require (not present && anyIssues) (valueError "a not-installed runtime probe requires issues and no installation")
    ProbeUnavailable ->
      require anyIssues (valueError "an unavailable runtime probe requires issues")
  case inst of
    Just i | i.runtime /= r -> Left (valueError "runtime probe and installation identities must match exactly")
    _ -> Right ()
  pure (RuntimeProbeResult r d inst (sort is))

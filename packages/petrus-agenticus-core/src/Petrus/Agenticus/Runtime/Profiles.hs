-- | Static runtime profile descriptors and non-vacuous CV16 qualification
-- targets (@petrus.agenticus.runtime.profiles@).
--
-- Upstream places this module under @agenticus.runtime@; it imports nothing
-- but the Catalog, so the port keeps it in the kernel-free core where the
-- Catalog tests can use it.  A profile describes a planned composition only;
-- catalog presence and a binding target do not claim installation, live
-- execution, or product support.
module Petrus.Agenticus.Runtime.Profiles
  ( RuntimeFamily (..)
  , familyText
  , TerritoryProfile (..)
  , territoryText
  , EmbodimentArchetype (..)
  , archetypeText
  , QualificationExpectation (..)
  , expectationText
  , Qualification (..)
  , qualificationExpectation
  , RuntimeTerritoryProfile
  , mkRuntimeTerritoryProfile
  , territoryIdentity
  , runtimeTerritoryProfile
  , runtimeTerritoryProfiles
  , runtimeProfiles
  , cv16HandsTerritoryTargets
    -- * Runtime descriptors
  , ampA1
  , codexA2Local
  , codexA3Gondolin
  , claudeA2Local
  , piNativeA2Local
  , piNativeA4Gondolin
  , piNativeA4E2b
  , piApplicationA5Gondolin
  , piApplicationA5E2b
  , agentAsNetA5Local
  ) where

import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error (AgenticusError, valueError)

data RuntimeFamily = Amp | Codex | Claude | PiNative | PiApplicationOwned | AgentAsNet
  deriving stock (Eq, Ord, Show, Enum, Bounded)

familyText :: RuntimeFamily -> Text
familyText = \case
  Amp -> "amp"
  Codex -> "codex"
  Claude -> "claude"
  PiNative -> "pi.native"
  PiApplicationOwned -> "pi.application-owned"
  AgentAsNet -> "agent-as-net"

-- | The selected Episode Hands territory.
data TerritoryProfile = ProviderManaged | Local | Docker | Gondolin | E2b
  deriving stock (Eq, Ord, Show, Enum, Bounded)

territoryText :: TerritoryProfile -> Text
territoryText = \case
  ProviderManaged -> "amp.provider-managed"
  Local -> "motus.local"
  Docker -> "motus.docker"
  Gondolin -> "motus.gondolin"
  E2b -> "motus.e2b"

data EmbodimentArchetype = A1 | A2 | A3 | A4 | A5
  deriving stock (Eq, Ord, Show, Enum, Bounded)

archetypeText :: EmbodimentArchetype -> Text
archetypeText = T.pack . show

data QualificationExpectation = BindingTarget | Unqualified | Unsupported
  deriving stock (Eq, Ord, Show, Enum, Bounded)

expectationText :: QualificationExpectation -> Text
expectationText = \case
  BindingTarget -> "binding-target"
  Unqualified -> "unqualified"
  Unsupported -> "unsupported"

-- | A cell's qualification. Only a binding target carries an archetype and
-- a runtime descriptor, and it always carries both: upstream's
-- @__post_init__@ refusals "a binding runtime profile needs an archetype
-- and descriptor" and "an unqualified or unsupported cell must not expose a
-- runtime descriptor" cannot arise.
data Qualification
  = BindingCell EmbodimentArchetype CapabilityDescriptor
  | UnqualifiedCell
  | UnsupportedCell
  deriving stock (Eq, Show)

-- | The reference's @expectation@ field.
qualificationExpectation :: Qualification -> QualificationExpectation
qualificationExpectation = \case
  BindingCell _ _ -> BindingTarget
  UnqualifiedCell -> Unqualified
  UnsupportedCell -> Unsupported

-- | One explicit runtime-family × Episode-Hands-territory qualification
-- cell. The constructor is hidden: a value comes from the table or from
-- 'mkRuntimeTerritoryProfile', so its reason is non-empty. The reference's
-- fields read with record dot syntax: @family@, @territory@, @reason@,
-- @qualification@, and, derived from the qualification, @expectation@,
-- @archetype@ and @descriptor@ (Nothing outside binding targets). There are
-- no field names to update a value through.
data RuntimeTerritoryProfile
  = RuntimeTerritoryProfile RuntimeFamily TerritoryProfile Text Qualification
  deriving stock (Eq, Show)

instance HasField "family" RuntimeTerritoryProfile RuntimeFamily where
  getField (RuntimeTerritoryProfile f _ _ _) = f

instance HasField "territory" RuntimeTerritoryProfile TerritoryProfile where
  getField (RuntimeTerritoryProfile _ t _ _) = t

instance HasField "reason" RuntimeTerritoryProfile Text where
  getField (RuntimeTerritoryProfile _ _ r _) = r

instance HasField "qualification" RuntimeTerritoryProfile Qualification where
  getField (RuntimeTerritoryProfile _ _ _ q) = q

instance HasField "expectation" RuntimeTerritoryProfile QualificationExpectation where
  getField cell = qualificationExpectation cell.qualification

instance HasField "archetype" RuntimeTerritoryProfile (Maybe EmbodimentArchetype) where
  getField cell = case cell.qualification of
    BindingCell a _ -> Just a
    _ -> Nothing

instance HasField "descriptor" RuntimeTerritoryProfile (Maybe CapabilityDescriptor) where
  getField cell = case cell.qualification of
    BindingCell _ d -> Just d
    _ -> Nothing

-- | @RuntimeTerritoryProfile(family, territory, expectation, reason,
-- archetype, descriptor)@: refuses an empty reason with the reference's
-- @ValueError@, its one refusal the types leave possible.
mkRuntimeTerritoryProfile
  :: RuntimeFamily -> TerritoryProfile -> Qualification -> Text -> Either AgenticusError RuntimeTerritoryProfile
mkRuntimeTerritoryProfile f t q r
  | T.null r = Left (valueError "runtime profile reason must be non-empty")
  | otherwise = Right (RuntimeTerritoryProfile f t r q)

-- | The exact version-1 Episode Hands territory envelope identity.
territoryIdentity :: TerritoryProfile -> DescriptorIdentity
territoryIdentity t = descriptorIdentity KindTerritory (territoryText t) 1

-- | Inspect one exact static table cell (total: the table covers every pair).
runtimeTerritoryProfile :: RuntimeFamily -> TerritoryProfile -> RuntimeTerritoryProfile
runtimeTerritoryProfile f t = case [cell | cell <- runtimeTerritoryProfiles, cell.family == f, cell.territory == t] of
  cell : _ -> cell
  [] -> error "runtimeTerritoryProfile: the table covers every pair"

capabilityRequirement :: DescriptorKind -> Text -> CompatibilityRequirement
capabilityRequirement k capability = either (error . show) id (mkCompatibilityRequirement k Nothing 1 [capability])

runtimeDescriptor
  :: Text -> EmbodimentArchetype -> TerritoryProfile -> (Text, Text, Text, Text, Text, Text) -> [Text] -> CapabilityDescriptor
runtimeDescriptor n arch terr (connection, program, hands, continuation, loop, topology) additional =
  capabilityDescriptor
    (descriptorIdentity KindRuntime n 1)
    (Set.toList (Set.fromList (["archetype." <> T.toLower (archetypeText arch), loop, topology] <> additional)))
    [ capabilityRequirement KindConnection connection
    , capabilityRequirement KindProgram program
    , capabilityRequirement KindHands hands
    , either (error . show) id (mkCompatibilityRequirement KindTerritory (Just (territoryText terr)) 1 [])
    , capabilityRequirement KindContinuation continuation
    , capabilityRequirement KindEffect "effect.host-fenced"
    ]

ampA1
  , codexA2Local
  , codexA3Gondolin
  , claudeA2Local
  , piNativeA2Local
  , piNativeA4Gondolin
  , piNativeA4E2b
  , piApplicationA5Gondolin
  , piApplicationA5E2b
  , agentAsNetA5Local
    :: CapabilityDescriptor
ampA1 =
  runtimeDescriptor
    "amp.a1.provider-managed"
    A1
    ProviderManaged
    ( "connection.amp"
    , "program.provider-owned"
    , "hands.provider-managed"
    , "continuation.amp-native"
    , "loop.provider-owned"
    , "topology.provider-managed"
    )
    []
codexA2Local =
  runtimeDescriptor
    "codex.a2.local"
    A2
    Local
    ( "connection.codex"
    , "program.provider-owned"
    , "hands.collocated"
    , "continuation.codex-native"
    , "loop.provider-owned"
    , "topology.durable-collocated"
    )
    []
codexA3Gondolin =
  runtimeDescriptor
    "codex.a3.gondolin"
    A3
    Gondolin
    ( "connection.codex"
    , "program.provider-owned"
    , "hands.collocated"
    , "continuation.codex-native"
    , "loop.provider-owned"
    , "topology.ephemeral-collocated"
    )
    ["topology.episode-collocated"]
claudeA2Local =
  runtimeDescriptor
    "claude.a2.local"
    A2
    Local
    ( "connection.claude"
    , "program.provider-owned"
    , "hands.collocated"
    , "continuation.claude-native"
    , "loop.provider-owned"
    , "topology.durable-collocated"
    )
    []
piNativeA2Local =
  runtimeDescriptor
    "pi.native.a2.local"
    A2
    Local
    ( "connection.pi-compatible"
    , "program.harness-owned"
    , "hands.collocated"
    , "continuation.pi-native"
    , "loop.harness-owned"
    , "topology.durable-collocated"
    )
    []
piNativeA4Gondolin =
  runtimeDescriptor
    "pi.native.a4.gondolin"
    A4
    Gondolin
    ( "connection.pi-compatible"
    , "program.harness-owned"
    , "hands.capability-scoped"
    , "continuation.pi-native"
    , "loop.harness-owned"
    , "topology.split"
    )
    []
piNativeA4E2b =
  runtimeDescriptor
    "pi.native.a4.e2b"
    A4
    E2b
    ( "connection.pi-compatible"
    , "program.harness-owned"
    , "hands.capability-scoped"
    , "continuation.pi-native"
    , "loop.harness-owned"
    , "topology.split"
    )
    []
piApplicationA5Gondolin =
  runtimeDescriptor
    "pi.application-owned.a5.gondolin"
    A5
    Gondolin
    ( "connection.pi-compatible"
    , "program.application-owned"
    , "hands.capability-scoped"
    , "continuation.application-owned"
    , "loop.application-owned"
    , "topology.split"
    )
    []
piApplicationA5E2b =
  runtimeDescriptor
    "pi.application-owned.a5.e2b"
    A5
    E2b
    ( "connection.pi-compatible"
    , "program.application-owned"
    , "hands.capability-scoped"
    , "continuation.application-owned"
    , "loop.application-owned"
    , "topology.split"
    )
    []
agentAsNetA5Local =
  runtimeDescriptor
    "agent-as-net.a5.local"
    A5
    Local
    ( "connection.model-call"
    , "program.net-owned"
    , "hands.capability-scoped"
    , "continuation.net-owned"
    , "loop.net-owned"
    , "topology.application-owned"
    )
    []

-- The table's two shapes. Every reason below is a non-empty literal (the
-- table test checks each one), so the cells use the constructor directly.
binding :: RuntimeFamily -> TerritoryProfile -> EmbodimentArchetype -> CapabilityDescriptor -> Text -> RuntimeTerritoryProfile
binding f t a d r = RuntimeTerritoryProfile f t r (BindingCell a d)

open :: RuntimeFamily -> TerritoryProfile -> Qualification -> Text -> RuntimeTerritoryProfile
open f t q r = RuntimeTerritoryProfile f t r q

-- | The complete 6 × 5 table, in upstream order.
runtimeTerritoryProfiles :: [RuntimeTerritoryProfile]
runtimeTerritoryProfiles =
  [ binding Amp ProviderManaged A1 ampA1 "DS9 binding Amp A1 provider-managed cell"
  , open Amp Local UnqualifiedCell "CV10 private evidence is not an independently leased Agenticus profile"
  , open Amp Docker UnqualifiedCell "CV10 private evidence is not an independently leased Agenticus profile"
  , open Amp Gondolin UnqualifiedCell "CV10 cell is credential-blocked and A1 has no external Hands claim"
  , open Amp E2b UnqualifiedCell "CV10 private evidence is not an independently leased Agenticus profile"
  , open Codex ProviderManaged UnqualifiedCell "no provider-managed Codex profile is qualified"
  , binding Codex Local A2 codexA2Local "DS9 binding Codex A2 cell"
  , open Codex Docker UnqualifiedCell "possible A3 cell; not binding"
  , binding Codex Gondolin A3 codexA3Gondolin "DS9 binding Codex A3 cell grounded by ES-049"
  , open Codex E2b UnqualifiedCell "possible A3 cell; not binding"
  , open Claude ProviderManaged UnqualifiedCell "no provider-managed Claude profile is qualified"
  , binding Claude Local A2 claudeA2Local "DS9 binding Claude A2 cell"
  , open Claude Docker UnqualifiedCell "A3 needs provider qualification"
  , open Claude Gondolin UnqualifiedCell "A3 needs provider qualification"
  , open Claude E2b UnqualifiedCell "A3 needs provider qualification"
  , open PiNative ProviderManaged UnqualifiedCell "no provider-managed Pi native profile is qualified"
  , binding PiNative Local A2 piNativeA2Local "DS9 binding Pi A2 cell"
  , open PiNative Docker UnqualifiedCell "possible A4 Hands; not binding"
  , binding PiNative Gondolin A4 piNativeA4Gondolin "DS9 binding Pi A4 Gondolin Hands cell"
  , binding PiNative E2b A4 piNativeA4E2b "DS9 binding Pi A4 E2B Hands cell"
  , open PiApplicationOwned ProviderManaged UnsupportedCell "application-owned progression requires host-owned Hands"
  , open PiApplicationOwned Local UnqualifiedCell "possible A5 Hands; DS9 binds the ES-049 replacement pair"
  , open PiApplicationOwned Docker UnqualifiedCell "possible A5 Hands; DS9 binds the ES-049 replacement pair"
  , binding PiApplicationOwned Gondolin A5 piApplicationA5Gondolin "DS9 binding Pi A5 Gondolin Hands cell"
  , binding PiApplicationOwned E2b A5 piApplicationA5E2b "DS9 binding Pi A5 E2B Hands cell"
  , open AgentAsNet ProviderManaged UnsupportedCell "Net-owned progression requires an Agenticus Hands attachment"
  , binding AgentAsNet Local A5 agentAsNetA5Local "DS10 binding future Net-owned A5 profile"
  , open AgentAsNet Docker UnqualifiedCell "future DS10 pressure"
  , open AgentAsNet Gondolin UnqualifiedCell "future DS10 pressure"
  , open AgentAsNet E2b UnqualifiedCell "future DS10 pressure"
  ]

-- | The binding-target descriptors, in table order.
runtimeProfiles :: [CapabilityDescriptor]
runtimeProfiles = mapMaybe (.descriptor) runtimeTerritoryProfiles

cv16HandsTerritoryTargets :: Set TerritoryProfile
cv16HandsTerritoryTargets = Set.fromList [Local, Docker, Gondolin, E2b]

module Main (main) where

import Petrus.Impetus.ActivitySeamSpec qualified as ActivitySeamSpec
import Petrus.Impetus.ArcFiltersSpec qualified as ArcFiltersSpec
import Petrus.Impetus.AwaitingTerminationSpec qualified as AwaitingTerminationSpec
import Petrus.Impetus.CelGuardsSpec qualified as CelGuardsSpec
import Petrus.Impetus.CompletionSpec qualified as CompletionSpec
import Petrus.Impetus.EnvironmentSignalSpec qualified as EnvironmentSignalSpec
import Petrus.Impetus.FailureTextSpec qualified as FailureTextSpec
import Petrus.Impetus.HandBuiltCorpusSpec qualified as HandBuiltCorpusSpec
import Petrus.Impetus.BoundarySpec qualified as BoundarySpec
import Petrus.Impetus.FiringOccurrencesSpec qualified as FiringOccurrencesSpec
import Petrus.Impetus.GuardBranchSpec qualified as GuardBranchSpec
import Petrus.Impetus.HandlersSpec qualified as HandlersSpec
import Petrus.Impetus.IngressSpec qualified as IngressSpec
import Petrus.Impetus.InstanceFiringSpec qualified as InstanceFiringSpec
import Petrus.Impetus.InstanceReplayPropertiesSpec qualified as InstanceReplayPropertiesSpec
import Petrus.Impetus.LifecycleScopesSpec qualified as LifecycleScopesSpec
import Petrus.Impetus.RegistrationsSpec qualified as RegistrationsSpec
import Petrus.Impetus.ResumeSpec qualified as ResumeSpec
import Petrus.Impetus.TimersSpec qualified as TimersSpec
import Petrus.Impetus.InstanceIdentitySpec qualified as InstanceIdentitySpec
import Petrus.Impetus.RuntimeSpec qualified as RuntimeSpec
import Petrus.Impetus.DotSpec qualified as DotSpec
import Petrus.Impetus.EnablednessSpec qualified as EnablednessSpec
import Petrus.Impetus.FifoQueueSpec qualified as FifoQueueSpec
import Petrus.Impetus.FiringHistorySpec qualified as FiringHistorySpec
import Petrus.Impetus.FiringSpec qualified as FiringSpec
import Petrus.Impetus.HistoryCodecSpec qualified as HistoryCodecSpec
import Petrus.Impetus.HistorySpec qualified as HistorySpec
import Petrus.Impetus.HistoryStoreSpec qualified as HistoryStoreSpec
import Petrus.Impetus.SelectionSpec qualified as SelectionSpec
import Petrus.Impetus.GoldenTracesSpec qualified as GoldenTracesSpec
import Petrus.Impetus.KernelDifferentialSpec qualified as KernelDifferentialSpec
import Petrus.Impetus.KernelPropertiesSpec qualified as KernelPropertiesSpec
import Petrus.Impetus.LiveSpec qualified as LiveSpec
import Petrus.Impetus.MarkingSpec qualified as MarkingSpec
import Petrus.Impetus.JsonSchemaSpec qualified as JsonSchemaSpec
import Petrus.Impetus.NetDefinitionCorpusSpec qualified as NetDefinitionCorpusSpec
import Petrus.Impetus.NetDefinitionPropertiesSpec qualified as NetDefinitionPropertiesSpec
import Petrus.Impetus.NetDefinitionSpec qualified as NetDefinitionSpec
import Petrus.Impetus.NetDocumentLineageSpec qualified as NetDocumentLineageSpec
import Petrus.Impetus.NetDocumentSpec qualified as NetDocumentSpec
import Petrus.Impetus.SchemaSpec qualified as SchemaSpec
import Petrus.Impetus.SpecFixturesSpec qualified as SpecFixturesSpec
import Petrus.Impetus.TypedBindingsSpec qualified as TypedBindingsSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  SchemaSpec.spec
  MarkingSpec.spec
  EnablednessSpec.spec
  ArcFiltersSpec.spec
  FiringSpec.spec
  DotSpec.spec
  FifoQueueSpec.spec
  InstanceFiringSpec.spec
  FiringOccurrencesSpec.spec
  HandlersSpec.spec
  RuntimeSpec.spec
  AwaitingTerminationSpec.spec
  EnvironmentSignalSpec.spec
  InstanceIdentitySpec.spec
  CompletionSpec.spec
  FailureTextSpec.spec
  HandBuiltCorpusSpec.spec
  BoundarySpec.spec
  GuardBranchSpec.spec
  CelGuardsSpec.spec
  IngressSpec.spec
  RegistrationsSpec.spec
  LifecycleScopesSpec.spec
  TimersSpec.spec
  ResumeSpec.spec
  InstanceReplayPropertiesSpec.spec
  ActivitySeamSpec.spec
  TypedBindingsSpec.spec
  SelectionSpec.spec
  HistorySpec.spec
  HistoryCodecSpec.spec
  HistoryStoreSpec.spec
  FiringHistorySpec.spec
  NetDefinitionSpec.spec
  NetDocumentSpec.spec
  NetDocumentLineageSpec.spec
  SpecFixturesSpec.spec
  NetDefinitionPropertiesSpec.spec
  NetDefinitionCorpusSpec.spec
  JsonSchemaSpec.spec
  GoldenTracesSpec.spec
  KernelDifferentialSpec.spec
  KernelPropertiesSpec.spec
  LiveSpec.spec

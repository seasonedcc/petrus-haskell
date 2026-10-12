module Main (main) where

import Petrus.Testing.Dst.Runner (processChildHook)
import Spec.Boundaries qualified
import Spec.Campaigns qualified
import Spec.Choice qualified
import Spec.Codec qualified
import Spec.EngineCheckers qualified
import Spec.EngineWorlds qualified
import Spec.Failure qualified
import Spec.JoinedWorlds qualified
import Spec.LegacyReplay qualified
import Spec.ManualReplay qualified
import Spec.Properties qualified
import Spec.Qualification qualified
import Spec.Runner qualified
import Spec.Stories qualified
import Spec.Surface qualified
import Spec.ToolingInterop qualified
import Spec.Transcript qualified
import Test.Hspec

main :: IO ()
main = do
  processChildHook Spec.Runner.entrypoints
  hspec $ do
    Spec.Choice.spec
    Spec.Codec.spec
    Spec.Stories.spec
    Spec.Surface.spec
    Spec.Runner.spec
    Spec.Transcript.spec
    Spec.EngineWorlds.spec
    Spec.EngineCheckers.spec
    Spec.JoinedWorlds.spec
    Spec.Properties.spec
    Spec.ManualReplay.spec
    Spec.LegacyReplay.spec
    Spec.Qualification.spec
    Spec.Campaigns.spec
    Spec.Failure.spec
    Spec.Boundaries.spec
    Spec.ToolingInterop.spec

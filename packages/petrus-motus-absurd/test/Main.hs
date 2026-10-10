module Main (main) where

import Petrus.Motus.Dispatch.Absurd.BoundarySpec qualified as Boundary
import Petrus.Motus.Dispatch.Absurd.HeartbeatSpec qualified as Heartbeat
import Petrus.Motus.Dispatch.Absurd.InteropSpec qualified as Interop
import Petrus.Motus.Dispatch.AbsurdSpec qualified as Absurd
import Test.Hspec

main :: IO ()
main = hspec $ do
  Absurd.spec
  Heartbeat.spec
  Interop.spec
  Boundary.spec

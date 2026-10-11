-- | Parity: the Worker half of
-- @tests/project/test_package_boundaries.py::test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle@,
-- checked over this repository's package metadata and module imports. (The
-- Codex adapter and runtime service half belongs to
-- @petrus-agenticus-runtime@.)
module Petrus.Motus.BoundarySpec (spec) where

import Data.List (isPrefixOf)
import Petrus.TestSupport.Boundary
import Test.Hspec

spec :: Spec
spec = describe "test_package_boundaries.py (Worker row)" $
  it "activity worker does not own retained territory lifecycle" $ do
    -- The Worker package cannot reach the retention machinery at all: it
    -- depends on no Agenticus package, and no Worker module imports the
    -- retention module (the reference's
    -- @petrus.agenticus.attachment._retention@).
    depends <- libraryDepends "petrus-motus"
    depends `shouldSatisfy` elem "petrus-activity"
    depends `shouldSatisfy` all (not . ("petrus-agenticus" `isPrefixOf`))
    sources <- filter (\p -> any (`isPrefixOf` p) ["packages/petrus-motus/src/Petrus/Motus/Worker"]) <$> haskellSources "petrus-motus"
    sources `shouldSatisfy` elem "packages/petrus-motus/src/Petrus/Motus/Worker.hs"
    imported <- concat <$> mapM importedModules sources
    imported `shouldNotSatisfy` elem "Petrus.Agenticus.Attachment.Retention"
    imported `shouldSatisfy` all (not . ("Petrus.Agenticus" `isPrefixOf`))

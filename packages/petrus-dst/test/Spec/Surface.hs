{-# LANGUAGE OverloadedRecordDot #-}

-- | @test_supported_surface_has_no_root_reexports_or_private_runtime_handles@
-- of @tests/dst/test_world.py@, over this repository's package metadata,
-- module headers and types:
--
-- * no root re-export: no package but @petrus-dst@ exposes a
--   @Petrus.Testing.Dst@ module (and there is no root @Petrus@ module, which
--   the Engine boundary rows check);
-- * no private runtime handle: the main library depends on no Petrus
--   package but @petrus-json@, imports no Petrus runtime module, and no
--   export list names an Engine or a Coordinator;
-- * the scenario context offers only @now@, @stableId@ and @faults@: its
--   module exports no @schedule@, @submit@ or @choices@, and its record has
--   exactly the three fields those services read (checked by the pattern
--   below, which stops compiling if a field is added);
-- * a profile's @apply@ takes a generation, a command and the context (the
--   'Scenario' monad), checked by its type ascription below.
module Spec.Surface (spec) where

import Control.Monad (forM_)
import Data.List (isInfixOf, isPrefixOf)
import Petrus.Testing.Dst
import Petrus.TestSupport.Boundary
import Test.Hspec

-- | The context's fields, positionally: a fourth field fails to compile.
contextArity :: ScenarioContext -> ()
contextArity (ScenarioContext _ _ _) = ()

-- | @apply(self, generation, command, context)@.
applyShape :: Profile m g -> g -> Command -> Scenario m ApplyResult
applyShape profile = profile.apply

mainLibraryModules :: IO [FilePath]
mainLibraryModules = filter ("packages/petrus-dst/src/" `isPrefixOf`) <$> haskellSources "petrus-dst"

spec :: Spec
spec = describe "the supported surface (test_world.py)" $ do
  it "has no re-export of the DST surface outside petrus-dst" $ do
    packages <- filter (/= "petrus-dst") <$> packageNames
    forM_ packages $ \package -> do
      exposed <- exposedModules package
      (package, filter ("Petrus.Testing.Dst" `isPrefixOf`) exposed) `shouldBe` (package, [])

  it "reaches no Petrus runtime from the main library" $ do
    depends <- libraryDepends "petrus-dst"
    filter ("petrus-" `isPrefixOf`) depends `shouldBe` ["petrus-json"]
    sources <- mainLibraryModules
    sources `shouldNotBe` []
    forM_ sources $ \source -> do
      imported <- importedModules source
      let petrus = filter ("Petrus." `isPrefixOf`) imported
          allowed m = "Petrus.Testing.Dst" `isPrefixOf` m || "Petrus.Json" `isPrefixOf` m
      (source, filter (not . allowed) petrus) `shouldBe` (source, [])

  it "exports no Engine or Coordinator handle" $ do
    sources <- mainLibraryModules
    forM_ sources $ \source -> do
      exports <- exportList "petrus-dst" (drop (length ("packages/petrus-dst/" :: String)) source)
      (source, filter (`isInfixOf` exports) ["Engine", "Coordinator"]) `shouldBe` (source, [])

  it "gives the scenario context no schedule, submit or choices service" $ do
    exports <- exportList "petrus-dst" "src/Petrus/Testing/Dst/Profile.hs"
    filter (`isInfixOf` exports) ["schedule", "submit", "choices"] `shouldBe` []
    forM_ ["now", "stableId", "faults"] $ \service ->
      exports `shouldContain` service
    contextArity (ScenarioContext 0 mempty []) `shouldBe` ()
    seq (applyShape :: Profile IO () -> () -> Command -> Scenario IO ApplyResult) () `shouldBe` ()

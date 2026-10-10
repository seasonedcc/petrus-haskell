-- | Port of @tests/petrus/agenticus/program/test_program_descriptor.py@.
module Petrus.Agenticus.ProgramSpec (spec) where

import Control.Monad (forM_)
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Program.Descriptor
import Petrus.Agenticus.Program.Seam
import Petrus.Agenticus.Support
import Petrus.Agenticus.Thread.Identity
import Petrus.Json (Json (..))
import Test.Hspec

ident :: DescriptorKind -> Text -> DescriptorIdentity
ident k n = descriptorIdentity k n 1

spec :: Spec
spec = describe "program/test_program_descriptor.py" $ do
  forM_ allOwnerships $ \ownership ->
    it ("test_each_program_ownership_has_one_exact_serializable_descriptor[" <> show (ownershipText ownership) <> "]") $ do
      let source = ident KindProgram "pi.provider-loop"
          c = ident KindContinuation "pi.native"
          d =
            agentProgramDescriptor
              (ident KindProgram ("example." <> ownershipText ownership))
              ownership
              False
              [continuationRequirement c source]
              (Just c)
              True
              True
      programFromData (programToData d) `shouldBe` Right d
      programToData d
        `shouldBe` Object
          [ ("schema_version", Int 1)
          , ("identity", identityToData d.identity)
          , ("ownership", String (ownershipText ownership))
          , ("accepts_fresh_start", Bool False)
          , ("accepted_continuations", Array [Object [("identity", identityToData c), ("program", identityToData source)]])
          , ("produced_continuation", identityToData c)
          , ("owns_steering", Bool True)
          , ("owns_evaluation", Bool True)
          ]

  it "test_program_owned_seams_preserve_their_native_payload_types" $ do
    let d = agentProgramDescriptor (ident KindProgram "net.guarded-loop") NetOwned True [] Nothing True True
    directives <- newIORef ([] :: [(Text, [Text])])
    let steer _episode given = modifyIORef' directives (<> [given])
        evaluate _episode observed = pure (observed, 1 :: Int)
        directive = ("pause-before-write", ["approval"])
        trace = ["model.called", "guard.passed", "append.accepted"] :: [Text]
    seams <- expectRightIO (mkProgramSeams d (Just steer) (Just evaluate))
    isJust seams.steering `shouldBe` True
    isJust seams.evaluator `shouldBe` True
    forM_ seams.steering $ \s -> s (literalEpisodeId "episode-1") directive
    forM_ seams.evaluator $ \e -> e (literalEpisodeId "episode-1") trace `shouldReturn` (trace, 1)
    readIORef directives `shouldReturn` [directive]

  it "test_program_seam_binding_must_match_descriptor_ownership" $ do
    let d = expectRight (simpleProgram (ident KindProgram "provider.closed-loop") ProviderOwned)
        noEvaluator = Nothing :: Maybe (ProgramEvaluator () ())
    fmap (const ()) (mkProgramSeams d (Just (\_ () -> pure ())) noEvaluator)
      `shouldRaiseMatching` ValueError
      $ "does not own steering"
    let missing = agentProgramDescriptor (ident KindProgram "harness.steerable") HarnessOwned True [] Nothing True False
    fmap (const ()) (mkProgramSeams missing (Nothing :: Maybe (ProgramSteering ())) noEvaluator)
      `shouldRaiseMatching` ValueError
      $ "requires a steering seam"

{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors -Wno-missing-signatures #-}

-- | The Haskell evidence for the processes check whose refusal the port's
-- types enforce (DIVERGENCES.md, "Type-enforced refusals"): this module
-- compiles with deferred type errors, and the example passes only when
-- using the ill-typed value raises a 'TypeError'.
module Petrus.Processes.TypedSpec (spec, liveProvisioner) where

import Control.Exception (TypeError (..))
import Petrus.Json (Json (..))
import Petrus.Processes
import Test.Hspec

-- | A provisioner whose @ensure@ hands back a value (a live host or a
-- credential, in the reference's refusal). Its own top-level binding, with
-- no signature, so the deferred error fires only when it is used and only
-- 'ProcessProvisioner''s field type can make it ill-typed.
liveProvisioner = ProcessProvisioner (\_ -> pure (Object [("credential", String "secret")]))

spec :: Spec
spec = describe "Type-enforced refusals (Haskell port)" $
  it "P-055 a provisioner returning a value does not type-check: ensure returns ()" $
    liveProvisioner.ensure undefined `shouldThrow` \(TypeError _) -> True

-- | Parity: the ZeroMQ row of @tests/project/test_package_boundaries.py@,
-- checked over this repository's package metadata (a Python import graph
-- becomes a Cabal dependency graph; the optional @zeromq@ extra becomes this
-- package, which must be depended on explicitly). No libzmq call needed.
module Petrus.Motus.Transport.ZeroMQ.BoundarySpec (spec) where

import Data.List (isInfixOf, isPrefixOf)
import Petrus.TestSupport.Boundary
import Test.Hspec

spec :: Spec
spec = describe "test_package_boundaries.py (ZeroMQ row)" $
  it "zeromq transport base import is optional and deep import has guidance" $ do
    -- The base: the Dispatch and Worker package links no libzmq, neither
    -- through a Haskell package nor through pkg-config, and nothing outside
    -- this package defines a transport module (the reference's
    -- @petrus.motus.transport@ is an empty namespace).
    base <- libraryDepends "petrus-motus"
    base `shouldSatisfy` elem "petrus-activity"
    base `shouldSatisfy` all (`notElem` ["petrus-motus-zeromq", "zeromq4-haskell"])
    libraryField "petrus-motus" "pkgconfig-depends" `shouldReturn` []
    libraryField "petrus-motus" "extra-libraries" >>= (`shouldSatisfy` notElem "zmq")
    packages <- packageNames
    transportModules <-
      concat <$> mapM (\p -> map ((,) p) . filter ("Petrus.Motus.Transport" `isPrefixOf`) <$> exposedModules p) packages
    [p | (p, _) <- transportModules, p /= "petrus-motus-zeromq"] `shouldBe` []
    [m | (_, m) <- transportModules, m == "Petrus.Motus.Transport"] `shouldBe` []
    -- The deep import: the transport is this package, which requires libzmq
    -- through pkg-config, so a build without the native library stops at
    -- configure naming it; the README carries the install guidance (the
    -- reference's "optional 'zeromq' extra" message).
    exposed <- exposedModules "petrus-motus-zeromq"
    exposed `shouldSatisfy` elem "Petrus.Motus.Transport.ZeroMQ"
    pkgconfig <- libraryField "petrus-motus-zeromq" "pkgconfig-depends"
    take 1 pkgconfig `shouldBe` ["libzmq"]
    readme <- packageFile "petrus-motus-zeromq" "README.md"
    readme `shouldSatisfy` isInfixOf "The library needs libzmq ≥ 4.1 and its headers (`pkg-config libzmq`)"
    readme `shouldSatisfy` isInfixOf "`brew install zeromq`"
    readme `shouldSatisfy` isInfixOf "`apt-get install libzmq3-dev`"

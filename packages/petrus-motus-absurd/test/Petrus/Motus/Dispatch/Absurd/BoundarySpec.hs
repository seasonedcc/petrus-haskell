-- | Parity: the four Absurd rows of @tests/project/test_package_boundaries.py@,
-- checked over this repository's package metadata and module sources (a
-- Python import graph becomes a Cabal dependency graph; an optional extra
-- becomes a package that must be depended on explicitly). No server needed.
module Petrus.Motus.Dispatch.Absurd.BoundarySpec (spec) where

import Data.List (isInfixOf)
import Petrus.TestSupport.Boundary (exportList, libraryDepends, packageFile)
import Test.Hspec

optionalDrivers :: [String]
optionalDrivers = ["petrus-motus-absurd", "petrus-postgres", "postgresql-libpq", "petrus-motus-zeromq", "zeromq4-haskell"]

spec :: Spec
spec = describe "test_package_boundaries.py (Absurd rows)" $ do
  it "dispatch import is optional-dependency safe and absurd is canonical" $ do
    -- The Dispatch facade's package pulls in neither the Absurd Dispatch nor
    -- any database or ZeroMQ driver; the Absurd Dispatch is its own package
    -- and exposes the canonical module.
    libraryDepends "petrus-motus" >>= (`shouldSatisfy` all (`notElem` optionalDrivers))
    cabal <- packageFile "petrus-motus-absurd" "petrus-motus-absurd.cabal"
    cabal `shouldSatisfy` isInfixOf "exposed-modules:  Petrus.Motus.Dispatch.Absurd\n"

  it "absurd dispatch removed name has no deep compatibility alias" $ do
    dispatch <- exportList "petrus-motus-absurd" "src/Petrus/Motus/Dispatch/Absurd.hs"
    dispatch `shouldNotSatisfy` isInfixOf "AbsurdExecutionAdapter"
    dispatch `shouldNotSatisfy` isInfixOf "AbsurdEngine"
    -- create_engine / load_engine return the plain Engine.
    engine <- packageFile "petrus-engine-absurd" "src/Petrus/Engine/Absurd.hs"
    engine `shouldSatisfy` isInfixOf "createEngine :: Connection -> Maybe Connection -> Net -> Text -> AbsurdEngineOptions -> EngineOptions -> IO Engine\n"
    engine `shouldSatisfy` isInfixOf "loadEngine :: Connection -> Maybe Connection -> Net -> Text -> AbsurdEngineOptions -> EngineOptions -> IO Engine\n"

  it "absurd deep import preserves missing extra guidance" $ do
    -- The reference's optional 'absurd' extra is this package: using the
    -- Absurd Dispatch means depending on it, which brings the PostgreSQL
    -- driver layer with it; a program without the dependency cannot import
    -- the module at all (the build says which package is missing).
    libraryDepends "petrus-motus-absurd" >>= (`shouldSatisfy` elem "petrus-postgres")
    libraryDepends "petrus-postgres" >>= (`shouldSatisfy` all (`notElem` ["petrus-motus", "petrus-motus-absurd", "petrus-engine"]))

  it "worker import does not require absurd extra" $ do
    -- The Worker and its CLI live in petrus-motus; the Absurd provider
    -- arrives through the ProviderPlugins slot from this package.
    libraryDepends "petrus-motus" >>= (`shouldSatisfy` all (`notElem` optionalDrivers))
    cli <- packageFile "petrus-motus" "src/Petrus/Motus/Worker/Cli.hs"
    cli `shouldNotSatisfy` isInfixOf "import Petrus.Motus.Dispatch.Absurd"

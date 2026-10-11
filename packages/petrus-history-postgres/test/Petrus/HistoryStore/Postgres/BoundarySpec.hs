-- | Parity: the PostgreSQL rows of @tests/project/test_package_boundaries.py@
-- and the @rules/history-store-postgres-provider-boundary.yml@ convention,
-- checked over this repository's package metadata and module imports (a
-- Python import graph becomes a Cabal dependency graph). No server needed.
module Petrus.HistoryStore.Postgres.BoundarySpec (spec) where

import Data.List (isPrefixOf)
import Petrus.TestSupport.Boundary (importedModules, libraryDepends)
import Test.Hspec

spec :: Spec
spec = describe "package boundaries" $ do
  it "canonical history store facade does not import optional postgres driver" $ do
    -- The kernel (memory store, the HistoryStore contract) and the canonical
    -- store package never pull in the PostgreSQL client.
    mapM_
      ( \package -> do
          depends <- libraryDepends package
          depends `shouldSatisfy` all (`notElem` ["petrus-postgres", "postgresql-libpq", "petrus-history-postgres"])
      )
      ["petrus-impetus", "petrus-history-store"]

  it "postgres history store is explicit and preserves missing extra guidance" $ do
    -- The store is its own package: depending on it is the explicit opt-in
    -- (the reference's optional extra), and the PostgreSQL client layer stays
    -- kernel-free (docs/runtime.md section 14.2).
    libraryDepends "petrus-history-postgres" >>= (`shouldSatisfy` elem "petrus-postgres")
    libraryDepends "petrus-postgres" >>= (`shouldSatisfy` all (`notElem` ["petrus-impetus", "petrus-history-store", "petrus-engine"]))

  it "history store postgres provider boundary (rules/history-store-postgres-provider-boundary.yml)" $ do
    imported <- importedModules "packages/petrus-history-postgres/src/Petrus/HistoryStore/Postgres.hs"
    let forbidden m =
          any
            (`isPrefixOf` m)
            ( ["Petrus.Engine", "Petrus.Fabric", "Petrus.Processes"]
                <> map ("Petrus.Impetus." <>) ["Binding", "Dsl", "Instance", "Petrinet", "Selection"]
                <> map ("Petrus.Motus." <>) ["Activity", "Dispatch", "Transport", "Worker"]
                <> ["Petrus.Activity", "Petrus.Motus"]
            )
    filter forbidden imported `shouldBe` []

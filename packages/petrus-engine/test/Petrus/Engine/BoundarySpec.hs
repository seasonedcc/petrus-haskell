-- | Parity: the Engine rows and the project-wide rows of
-- @tests/project/test_package_boundaries.py@, checked over this repository's
-- package metadata and module sources (a Python import graph becomes a Cabal
-- dependency graph; an optional extra becomes a package that must be
-- depended on explicitly; the empty @petrus@ project namespace becomes the
-- absence of a root @Petrus@ module). No server needed.
module Petrus.Engine.BoundarySpec (spec) where

import Control.Monad (forM, forM_)
import Data.Char (isAlphaNum, isSpace)
import Data.List (isInfixOf, isPrefixOf)
import Data.Set qualified as Set
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Petrus.TestSupport.Boundary
import Test.Hspec

-- | The names a module's export list exports (constructors and fields in
-- parentheses dropped, comments dropped).
exportedNames :: String -> [String]
exportedNames list = filter (not . null) (map name (splitTop (stripComments (drop 1 (dropWhile (/= '(') list)))))
  where
    stripComments = unlines . map (\l -> if "--" `isPrefixOf` dropWhile isSpace l then "" else cut l) . lines
    cut l = case l of
      '-' : '-' : _ -> ""
      c : rest -> c : cut rest
      [] -> []
    -- Split on top-level commas (depth 0), dropping the closing paren.
    splitTop = go (0 :: Int) ""
      where
        go _ acc [] = [reverse acc]
        go d acc (c : cs)
          | c == '(' = go (d + 1) acc cs
          | c == ')' = if d == 0 then [reverse acc] else go (d - 1) acc cs
          | d > 0 = go d acc cs
          | c == ',' = reverse acc : go d "" cs
          | otherwise = go d (c : acc) cs
    name = takeWhile (\c -> isAlphaNum c || c `elem` ("_'" :: String)) . dropWhile isSpace

-- | Packages that carry an optional driver (the reference's optional extras):
-- the PostgreSQL client, and the Absurd and PostgreSQL Engine providers.
optionalDrivers :: [String]
optionalDrivers =
  [ "petrus-postgres"
  , "postgresql-libpq"
  , "petrus-engine-postgres"
  , "petrus-engine-absurd"
  , "petrus-motus-absurd"
  , "petrus-history-postgres"
  , "petrus-motus-zeromq"
  , "zeromq4-haskell"
  ]

-- | The Haskell spelling of the reference's @petrus.engine.__all__@: the
-- 'Action' constructors are exported with their type (@Action (..)@), and
-- @SimulatedClock@ is the 'simulatedClock' constructor of a 'Clock'.
engineAll :: [String]
engineAll =
  [ "AcceptedDelivery"
  , "Action"
  , "Clock"
  , "Delivery"
  , "DriveOutcome"
  , "DrivingPolicy"
  , "Engine"
  , "InFlightView"
  , "Sensor"
  , "simulatedClock"
  , "Snapshot"
  , "chooseConservative"
  , "chooseThroughput"
  ]

-- | The 'Action' constructors the reference exports by name.
actionConstructors :: [String]
actionConstructors = ["AcceptResult", "AcceptDelivery", "BeginCandidate", "AdvanceTime", "Wait", "Stop"]

-- | Names the reference removed from the Dispatch facade and the root.
removedDispatchNames :: [String]
removedDispatchNames = ["ExecutionAdapter", "ExecutionRuntime", "InlineAdapter", "InlineDispatcher", "PendingPoolAdapter"]

-- | Every package's exposed library modules.
allExposedModules :: IO [(String, [String])]
allExposedModules = do
  packages <- packageNames
  forM packages (\p -> (,) p <$> exposedModules p)

spec :: Spec
spec = describe "test_package_boundaries.py (Engine and project-wide rows)" $ do
  it "lazy root surface remains discoverable without optional imports" $ do
    -- The project namespace is empty (@petrus.__all__ == []@): no package
    -- exposes a root @Petrus@ module, so neither the removed coordination
    -- vocabulary nor the kernel or History names, nor any optional driver,
    -- is reachable through it.
    exposed <- allExposedModules
    [(p, m) | (p, ms) <- exposed, m <- ms, m == "Petrus"] `shouldBe` []

  it "implementation and maintained consumers import defining modules, not project root" $ do
    -- Every Haskell source (library, test, bench, app) imports defining
    -- modules; none imports the project root.
    packages <- packageNames
    offenders <- fmap concat . forM packages $ \p -> do
      sources <- haskellSources p
      fmap concat . forM sources $ \path -> do
        imported <- importedModules path
        pure [path | "Petrus" `elem` imported]
    offenders `shouldBe` []

  it "engine is canonical public and optional dependency safe" $ do
    -- @from petrus.engine import Engine@ pulls in no optional driver: the
    -- Engine package depends on none of them.
    depends <- libraryDepends "petrus-engine"
    depends `shouldSatisfy` \names -> all (`elem` names) ["petrus-impetus", "petrus-motus"]
    depends `shouldSatisfy` all (`notElem` optionalDrivers)
    exports <- exportedNames <$> exportList "petrus-engine" "src/Petrus/Engine.hs"
    exports `shouldSatisfy` \names -> all (`elem` names) ["Engine", "create", "load", "wait"]
    exports `shouldNotSatisfy` elem "queueFor"
    -- The Engine is not reachable from the (absent) project root.
    exposed <- exposedModules "petrus-engine"
    exposed `shouldNotSatisfy` elem "Petrus"

  it "removed flat deep modules are not speculative shims" $ do
    -- The reference's removed flat @impetus@ module has no find_spec: no
    -- package exposes an @Impetus@ library module, at the root or below it.
    exposed <- allExposedModules
    [(p, m) | (p, ms) <- exposed, m <- ms, m == "Impetus" || "Impetus." `isPrefixOf` m] `shouldBe` []

  it "dispatch is canonical and coordination remains private" $ do
    -- InlineDispatch and InMemoryDispatch are Dispatches (the reference's
    -- isinstance checks, here by the conversions' types).
    inline <- newInlineDispatch mempty
    memory <- newInMemoryDispatch
    let dispatches = [inlineDispatch inline, inMemoryDispatch memory] :: [Dispatch]
    length dispatches `shouldBe` 2
    -- LocalDispatch is defined in the Local Dispatch module; ActivityAttempt
    -- in the Dispatch facade.
    local <- exportedNames <$> exportList "petrus-motus" "src/Petrus/Motus/Dispatch/Local.hs"
    local `shouldSatisfy` elem "LocalDispatch"
    facadeSource <- packageFile "petrus-motus" "src/Petrus/Motus/Dispatch.hs"
    facadeSource `shouldSatisfy` isInfixOf "\ndata ActivityAttempt = "
    -- The removed names exist nowhere on the Dispatch facade.
    facade <- exportedNames <$> exportList "petrus-motus" "src/Petrus/Motus/Dispatch.hs"
    forM_ removedDispatchNames $ \removed -> facade `shouldNotSatisfy` elem removed
    -- The Engine's public surface is exactly the reference's
    -- @petrus.engine.__all__@, beside the Engine's own doors; neither the
    -- Coordinator nor a Runner is part of it.
    engineSource <- exportList "petrus-engine" "src/Petrus/Engine.hs"
    let engine = exportedNames engineSource
    forM_ engineAll $ \name -> engine `shouldSatisfy` elem name
    engineSource `shouldSatisfy` isInfixOf "Action (..)"
    vocabulary <- packageFile "petrus-engine" "src/Petrus/Engine/Vocabulary.hs"
    forM_ actionConstructors $ \ctor -> vocabulary `shouldSatisfy` isInfixOf ("    " <> ctor)
    engine `shouldNotSatisfy` elem "Coordinator"
    engine `shouldNotSatisfy` elem "Runner"
    -- The coordination machinery lives in the Engine's own module (the
    -- reference's private @petrus.engine._coordination@); there is no root
    -- coordination module.
    exposed <- allExposedModules
    lookup "petrus-engine" exposed `shouldSatisfy` maybe False (elem "Petrus.Engine.Coordinator")
    [(p, m) | (p, ms) <- exposed, m <- ms, m == "Petrus.Coordination" || m == "Petrus.Coordinator"] `shouldBe` []
    -- Nothing in the Engine's public surface is named after the removed
    -- names or the root's former authority export.
    Set.fromList engine `Set.disjoint` Set.fromList (removedDispatchNames <> ["authority", "Authority"]) `shouldBe` True

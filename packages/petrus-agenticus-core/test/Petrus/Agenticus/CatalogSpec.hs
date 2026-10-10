-- | Ports of @tests/petrus/agenticus/catalog/test_descriptor.py@,
-- @catalog/test_resolution.py@ and @runtime/test_profiles.py@, plus the
-- Catalog differential corpus.
module Petrus.Agenticus.CatalogSpec (spec) where

import Control.Exception qualified
import Control.Monad (forM_, when)
import Data.List (permutations, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Resolution
import Petrus.Agenticus.Catalog.Result
import Petrus.Agenticus.Error
import Petrus.Agenticus.Runtime.Profiles
import Petrus.Agenticus.Support
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Hspec
import Test.QuickCheck

descriptorFixture, resultFixture :: FilePath
descriptorFixture = "test/conformance/catalog-descriptor-v1.json"
resultFixture = "test/conformance/catalog-result-v1.json"

fixtureCases :: Json -> [Json]
fixtureCases j = case lookupJ "cases" j of
  Array xs -> xs
  _ -> []

lookupJ :: Text -> Json -> Json
lookupJ key j = fromMaybe Null (J.lookupMember key j)

keysOf :: Json -> Set.Set Text
keysOf = \case
  Object ms -> Set.fromList (map fst ms)
  _ -> Set.empty

desc :: DescriptorKind -> Text -> Integer -> [Text] -> [CompatibilityRequirement] -> CapabilityDescriptor
desc k n v offered reqs = capabilityDescriptor (descriptorIdentity k n v) offered reqs

simple :: DescriptorKind -> Text -> CapabilityDescriptor
simple k n = desc k n 1 [] []

req :: DescriptorKind -> Maybe Text -> Integer -> [Text] -> CompatibilityRequirement
req k n v caps = expectRight (mkCompatibilityRequirement k n v caps)

catalogOf :: Bool -> [CapabilityDescriptor] -> IO Catalog
catalogOf enabledToo ds = do
  c <- newCatalog
  forM_ ds $ \d -> do
    register c d
    when enabledToo (enable c d.identity)
  pure c

request :: [DescriptorIdentity] -> ResolutionRequest
request = expectRight . mkResolutionRequest

-- | @_components_for@: the runtime plus one descriptor per requirement.
componentsFor :: CapabilityDescriptor -> [CapabilityDescriptor]
componentsFor runtime =
  runtime
    : [ desc r.kind (fromMaybe ("test." <> runtime.identity.name <> "." <> kindText r.kind) r.name) 1 (Set.toList r.capabilities) []
      | r <- runtime.requires
      ]

issuePairs :: CompatibilityResult -> Set.Set (Text, Text)
issuePairs r = Set.fromList [(i.code, i.subject) | i <- r.issues]

resultFor :: DescriptorIdentity -> Resolution -> CompatibilityResult
resultFor i r = case [x | x <- r.results, x.candidate == Just i] of
  x : _ -> x
  [] -> error "no result for candidate"

spec :: Spec
spec = do
  describe "catalog/test_descriptor.py" $ do
    it "test_versioned_plain_data_fixture_round_trips_without_concrete_adapters" $ do
      fixture <- loadJson descriptorFixture
      keysOf fixture `shouldBe` Set.fromList ["format", "version", "contract", "cases"]
      lookupJ "format" fixture `shouldBe` String "petrus.agenticus.conformance"
      lookupJ "version" fixture `shouldBe` Int 1
      lookupJ "contract" fixture `shouldBe` String "catalog.descriptor"
      forM_ (fixtureCases fixture) $ \c -> do
        d <- expectRightIO (descriptorFromData (lookupJ "descriptor" c))
        descriptorToData d `shouldSatisfy` J.exactEq (lookupJ "descriptor" c)

    it "test_versioned_result_fixture_round_trips_without_concrete_adapters" $ do
      fixture <- loadJson resultFixture
      keysOf fixture `shouldBe` Set.fromList ["format", "version", "contract", "cases"]
      lookupJ "contract" fixture `shouldBe` String "catalog.result"
      forM_ (fixtureCases fixture) $ \c -> do
        r <- expectRightIO (resultFromData (lookupJ "result" c))
        resultToData r `shouldSatisfy` J.exactEq (lookupJ "result" c)
        Bool (compatible r) `shouldSatisfy` J.exactEq (lookupJ "compatible" c)

    it "test_descriptor_values_are_immutable_normalized_and_exactly_versioned" $ do
      let requirement = req KindHands Nothing 1 ["workspace.write", "workspace.read"]
          d = desc KindRuntime "pi.application-owned" 1 ["continuation.opaque", "program.harness-owned"] [requirement]
      d.offers `shouldBe` Set.fromList ["continuation.opaque", "program.harness-owned"]
      d.requires `shouldBe` [requirement]
      lookupJ "offers" (descriptorToData d)
        `shouldBe` Array [String "continuation.opaque", String "program.harness-owned"]

    -- (immutability is a property of Haskell values)
    fixtureData <- runIO (lookupJ "descriptor" . head' . fixtureCases <$> loadJson descriptorFixture)
    let identityOf = lookupJ "identity" fixtureData
        mutations =
          [ ("unexpected key", setMember "unexpected" (Bool True) fixtureData)
          , ("schema 2", setMember "schema_version" (Int 2) fixtureData)
          , ("bool version", setMember "identity" (setMember "contract_version" (Bool True) identityOf) fixtureData)
          , ("duplicate offer", setMember "offers" (Array [String "workspace.read", String "workspace.read"]) fixtureData)
          ]
    forM_ mutations $ \(caseLabel, mutated) ->
      it ("test_descriptor_decoder_refuses_ambiguous_or_noncanonical_data[" <> caseLabel <> "]") $ do
        case descriptorFromData mutated of
          Left e -> (e `isInstanceOf` TypeError || e `isInstanceOf` ValueError) `shouldBe` True
          Right d -> expectationFailure ("accepted " <> show d)

    it "test_compatibility_result_cannot_claim_success_without_a_candidate" $ do
      let candidate = descriptorIdentity KindRuntime "pi.application-owned" 1
      compatible (expectRight (mkCompatibilityResult (Just candidate) [])) `shouldBe` True
      let issue = compatibilityIssue "missing-capability" "workspace.write"
          blocked = expectRight (mkCompatibilityResult (Just candidate) [issue])
      compatible blocked `shouldBe` False
      blocked.issues `shouldBe` [issue]
      mkCompatibilityResult Nothing [] `shouldRaiseMatching'` (ValueError, "candidate")

  describe "catalog/test_resolution.py" $ do
    it "test_registration_is_disabled_by_default_and_enablement_is_exact" $ do
      let runtime = simple KindRuntime "runtime"
      c <- newCatalog
      register c runtime
      entries <- inspect c
      map (.descriptor) entries `shouldBe` [runtime]
      map (.enabled) entries `shouldBe` [False]
      r <- resolve c (request [runtime.identity])
      map (.code) (concatMap (.issues) (incompatibilities r)) `shouldBe` ["not-enabled"]
      enable c (descriptorIdentity KindRuntime "other" 1) `shouldRaiseIO` UnknownRegistrationError
      enable c runtime.identity
      r' <- resolve c (request [runtime.identity])
      resolutionCompatible r' `shouldBe` True

    it "test_duplicate_and_conflicting_registration_envelopes_are_refused_without_mutation" $ do
      let d = desc KindRuntime "runtime" 1 ["one"] []
          conflict = desc KindRuntime "runtime" 1 ["two"] []
      c <- newCatalog
      register c d
      revision <- catalogRevisionIO c
      register c d `shouldRaiseIO` DuplicateRegistrationError
      register c conflict `shouldRaiseIO` AmbiguousRegistrationError
      catalogRevisionIO c `shouldReturn` revision
      map (.descriptor) <$> inspect c `shouldReturn` [d]

    forM_
      ( zip
          [0 :: Int ..]
          [ [req KindConnection (Just "one") 1 [], req KindConnection (Just "two") 1 []]
          , [req KindConnection Nothing 1 [], req KindConnection Nothing 2 []]
          ]
      )
      $ \(n, requirements) ->
        it ("test_registration_refuses_same_kind_requirements_one_selection_cannot_satisfy[" <> show n <> "]") $ do
          c <- newCatalog
          register c (desc KindRuntime "runtime" 1 [] requirements) `shouldRaiseIO` AmbiguousRegistrationError
          catalogRevisionIO c `shouldReturn` 0
          length <$> inspect c `shouldReturn` 0

    it "test_compatible_same_kind_requirements_share_one_exact_selection" $ do
      let requirements = [req KindConnection Nothing 1 ["provider.codex"], req KindConnection (Just "account") 1 ["authority.ready"]]
          runtime = desc KindRuntime "runtime" 1 [] requirements
          account = desc KindConnection "account" 1 ["provider.codex", "authority.ready"] []
      c <- catalogOf True [runtime, account]
      r <- resolve c (request [runtime.identity, account.identity])
      resolutionCompatible r `shouldBe` True

    it "test_request_refuses_duplicate_and_ambiguous_selections" $ do
      let runtime = descriptorIdentity KindRuntime "one" 1
          other = descriptorIdentity KindRuntime "two" 1
      mkResolutionRequest [runtime, runtime] `shouldRaise` DuplicateSelectionError
      mkResolutionRequest [runtime, other] `shouldRaise` AmbiguousSelectionError
      mkResolutionRequest [descriptorIdentity KindConnection "account" 1] `shouldRaiseMatching'` (SelectionError, "runtime")

    it "test_resolution_reports_every_typed_incompatibility_in_stable_order" $ do
      let requirements =
            [ req KindConnection (Just "expected-account") 1 ["provider.codex"]
            , req KindHands Nothing 1 ["workspace.read", "workspace.write"]
            , req KindTerritory (Just "motus.gondolin") 1 []
            , req KindContinuation (Just "codex.native") 1 []
            , req KindEffect Nothing 1 ["effect.host-fenced"]
            ]
          runtime = desc KindRuntime "codex.a3" 1 [] requirements
          connection = desc KindConnection "wrong-account" 2 [] []
          hands = desc KindHands "hands" 1 ["workspace.read"] []
          territory = simple KindTerritory "motus.e2b"
          continuation = descriptorIdentity KindContinuation "codex.native" 1
      c <- catalogOf True [runtime, connection, hands, territory]
      disable c hands.identity
      r <- resolve c (request [runtime.identity, connection.identity, hands.identity, territory.identity, continuation])
      resolutionCompatible r `shouldBe` False
      isNothing r.snapshot `shouldBe` True
      issuePairs (resultFor runtime.identity r)
        `shouldBe` Set.fromList
          [ ("name-mismatch", "expected-account")
          , ("version-mismatch", "connection@1")
          , ("missing-capability", "provider.codex")
          , ("selection-not-enabled", "hands")
          , ("missing-capability", "workspace.write")
          , ("name-mismatch", "motus.gondolin")
          , ("selection-not-registered", "codex.native")
          , ("missing-selection", "effect")
          ]
      issuePairs (resultFor hands.identity r) `shouldBe` Set.fromList [("not-enabled", "hands")]
      issuePairs (resultFor continuation r) `shouldBe` Set.fromList [("not-registered", "codex.native")]
      let runtimeIssues = (resultFor runtime.identity r).issues
      runtimeIssues `shouldBe` sortOn (\i -> (i.code, i.subject)) runtimeIssues

    it "test_catalog_never_substitutes_enabled_provider_account_runtime_territory_or_continuation" $ do
      let requirements =
            [ req KindConnection Nothing 1 ["provider.codex"]
            , req KindTerritory (Just "motus.gondolin") 1 []
            , req KindContinuation (Just "codex.native") 1 []
            ]
          requestedRuntime = desc KindRuntime "codex" 1 [] requirements
          requestedAccount = desc KindConnection "account-requested" 1 ["provider.other"] []
          requestedTerritory = simple KindTerritory "motus.e2b"
          requestedContinuation = simple KindContinuation "other.native"
      c <-
        catalogOf
          True
          [ requestedRuntime
          , simple KindRuntime "other"
          , requestedAccount
          , desc KindConnection "account-compatible" 1 ["provider.codex"] []
          , requestedTerritory
          , simple KindTerritory "motus.gondolin"
          , requestedContinuation
          , simple KindContinuation "codex.native"
          ]
      r <-
        resolve
          c
          (request [requestedRuntime.identity, requestedAccount.identity, requestedTerritory.identity, requestedContinuation.identity])
      resolutionCompatible r `shouldBe` False
      issuePairs (resultFor requestedRuntime.identity r)
        `shouldBe` Set.fromList
          [("missing-capability", "provider.codex"), ("name-mismatch", "motus.gondolin"), ("name-mismatch", "codex.native")]

    it "test_successful_episode_snapshot_is_immutable_across_later_catalog_changes" $ do
      let components = componentsFor (head' runtimeProfiles)
      c <- catalogOf True components
      let req' = request (map (.identity) components)
      r <- resolve c req'
      snap <- maybe (fail "no snapshot") pure r.snapshot
      let beforeData = snapshotToData snap
          territory = head' [x | x <- components, x.identity.kind == KindTerritory]
      disable c territory.identity
      register c (desc KindConnection "later-account" 1 ["connection.amp"] [])
      snapshotToData snap `shouldSatisfy` J.exactEq beforeData
      snapshotFromData beforeData `shouldBe` Right snap
      revisionNow <- catalogRevisionIO c
      revisionNow `shouldSatisfy` (> snap.catalogRevision)
      r' <- resolve c req'
      resolutionCompatible r' `shouldBe` False

    snapData <-
      runIO $ do
        let runtime = simple KindRuntime "runtime"
        c <- catalogOf True [runtime]
        r <- resolve c (request [runtime.identity])
        pure (maybe Null snapshotToData r.snapshot)
    forM_
      [ ("unexpected", setMember "unexpected" (Bool True) snapData)
      , ("schema 2", setMember "schema_version" (Int 2) snapData)
      , ("bool revision", setMember "catalog_revision" (Bool True) snapData)
      , ("object descriptors", setMember "descriptors" (Object []) snapData)
      ]
      $ \(caseLabel, mutated) ->
        it ("test_resolution_snapshot_decoder_refuses_noncanonical_data[" <> caseLabel <> "]") $
          case snapshotFromData mutated of
            Left e -> (e `isInstanceOf` TypeError || e `isInstanceOf` ValueError) `shouldBe` True
            Right s -> expectationFailure ("accepted " <> show s)

    let orderComponents = componentsFor (head' runtimeProfiles)
    orderReference <- runIO $ do
      c <- catalogOf True orderComponents
      r <- resolve c (request (map (.identity) orderComponents))
      pure (maybe Null snapshotToData r.snapshot)
    it "test_registration_and_selection_order_are_deterministic" $
      let components = orderComponents
          reference = orderReference
       in (length components == 7 .&&.) $
            withNumTests 40 $
          forAll (shuffle [0 .. 6 :: Int]) $ \registrationOrder ->
            forAll (shuffle [0 .. 6 :: Int]) $ \selectionOrder -> ioProperty $ do
              c <- newCatalog
              forM_ registrationOrder $ \i -> register c (components !! i)
              forM_ (reverse registrationOrder) $ \i -> enable c (components !! i).identity
              r <- resolve c (request [(components !! i).identity | i <- selectionOrder])
              entries <- inspect c
              pure $
                resolutionCompatible r
                  && maybe False (J.exactEq reference . snapshotToData) r.snapshot
                  && map (.descriptor.identity) entries == sortOn identityKey (map (.descriptor.identity) entries)

    forM_ runtimeProfiles $ \runtime ->
      it ("test_every_planned_runtime_territory_profile_resolves_from_exact_ds1_envelopes[" <> T.unpack runtime.identity.name <> "]") $ do
        let components = componentsFor runtime
        c <- catalogOf True components
        r <- resolve c (request (map (.identity) (reverse components)))
        resolutionCompatible r `shouldBe` True
        (r.snapshot >>= snapshotDescriptor KindRuntime) `shouldBe` Just runtime

    forM_ runtimeProfiles $ \runtime ->
      it ("test_every_planned_profile_refuses_a_different_explicit_hands_territory[" <> T.unpack runtime.identity.name <> "]") $ do
        let components = componentsFor runtime
            requirement = head' [x | x <- runtime.requires, x.kind == KindTerritory]
            requiredName = fromMaybe "" requirement.name
            alternate = head' [t | t <- [minBound .. maxBound], territoryText t /= requiredName]
            swapped =
              [ if x.identity.kind == KindTerritory then simple KindTerritory (territoryText alternate) else x
              | x <- components
              ]
        c <- catalogOf True swapped
        r <- resolve c (request (map (.identity) swapped))
        issuePairs (resultFor runtime.identity r) `shouldBe` Set.fromList [("name-mismatch", requiredName)]

    it "test_all_permutations_of_inspection_are_canonical_for_a_small_catalog" $ do
      let ds = [simple KindRuntime "runtime", simple KindConnection "connection", simple KindTerritory "territory"]
      observations <- mapM (\order -> map (.descriptor.identity) <$> (catalogOf False order >>= inspect)) (permutations ds)
      Set.size (Set.fromList observations) `shouldBe` 1

  describe "runtime/test_profiles.py" $ do
    it "test_support_table_exhaustively_classifies_every_family_territory_pair" $ do
      let expected = Set.fromList [(f, t) | f <- [minBound .. maxBound], t <- [minBound .. maxBound]]
          observed = Set.fromList [(c.family, c.territory) | c <- runtimeTerritoryProfiles]
      observed `shouldBe` expected
      length runtimeTerritoryProfiles `shouldBe` Set.size expected
      Set.fromList [(c.family, c.territory, c.archetype) | c <- runtimeTerritoryProfiles, c.expectation == BindingTarget]
        `shouldBe` Set.fromList
          [ (Amp, ProviderManaged, Just A1)
          , (Codex, Local, Just A2)
          , (Codex, Gondolin, Just A3)
          , (Claude, Local, Just A2)
          , (PiNative, Local, Just A2)
          , (PiNative, Gondolin, Just A4)
          , (PiNative, E2b, Just A4)
          , (PiApplicationOwned, Gondolin, Just A5)
          , (PiApplicationOwned, E2b, Just A5)
          , (AgentAsNet, Local, Just A5)
          ]
      any (\c -> c.expectation == Unqualified) runtimeTerritoryProfiles `shouldBe` True
      Set.fromList [(c.family, c.territory) | c <- runtimeTerritoryProfiles, c.expectation == Unsupported]
        `shouldBe` Set.fromList [(PiApplicationOwned, ProviderManaged), (AgentAsNet, ProviderManaged)]
      cv16HandsTerritoryTargets `shouldBe` Set.fromList [Local, Docker, Gondolin, E2b]

    it "test_only_binding_target_cells_publish_descriptors_and_none_claims_live_execution" $ do
      [d | c <- runtimeTerritoryProfiles, c.expectation == BindingTarget, Just d <- [c.descriptor]] `shouldBe` runtimeProfiles
      Set.size (Set.fromList (map (.identity) runtimeProfiles)) `shouldBe` 10
      forM_ runtimeTerritoryProfiles $ \c -> do
        T.null c.reason `shouldBe` False
        if c.expectation == BindingTarget
          then do
            d <- maybe (fail "missing descriptor") pure c.descriptor
            d.identity.kind `shouldBe` KindRuntime
            all (\o -> any (`T.isPrefixOf` o) ["archetype.", "loop.", "topology."]) (Set.toList d.offers) `shouldBe` True
          else do
            isNothing c.descriptor `shouldBe` True
            isNothing c.archetype `shouldBe` True

    forM_ runtimeProfiles $ \profile ->
      it ("test_profile_ownership_vocabulary_remains_explicit[" <> T.unpack profile.identity.name <> "]") $ do
        let byKind = Map.fromList [(r.kind, r) | r <- profile.requires]
            caps k = maybe Set.empty (.capabilities) (Map.lookup k byKind)
            (connection, program, hands, continuation, loop, topology) = ownership profile.identity.name
        caps KindConnection `shouldBe` Set.singleton connection
        caps KindProgram `shouldBe` Set.singleton program
        caps KindHands `shouldBe` Set.singleton hands
        caps KindContinuation `shouldBe` Set.singleton continuation
        caps KindEffect `shouldBe` Set.singleton "effect.host-fenced"
        Set.member loop profile.offers `shouldBe` True
        Set.member topology profile.offers `shouldBe` True
        Set.size (Set.filter ("archetype." `T.isPrefixOf`) profile.offers) `shouldBe` 1

    it "test_codex_gondolin_v1_adds_episode_ownership_without_removing_legacy_topology" $
      Set.fromList ["topology.ephemeral-collocated", "topology.episode-collocated"]
        `Set.isSubsetOf` codexA3Gondolin.offers
        `shouldBe` True

    forM_ runtimeTerritoryProfiles $ \cell ->
      it
        ( "test_every_binding_profile_pins_exact_territory_without_interpreting_motus_capability_keys["
            <> T.unpack (familyText cell.family <> "-" <> territoryText cell.territory)
            <> "]"
        )
        $ do
          runtimeTerritoryProfile cell.family cell.territory `shouldBe` cell
          forM_ cell.descriptor $ \d -> do
            let territoryRequirements = [r | r <- d.requires, r.kind == KindTerritory]
            length territoryRequirements `shouldBe` 1
            let r = head' territoryRequirements
            r.name `shouldBe` Just (territoryText cell.territory)
            r.contractVersion `shouldBe` 1
            r.capabilities `shouldBe` Set.empty
            Just (territoryIdentity cell.territory).name `shouldBe` r.name

    it "test_profile_and_catalog_inspection_import_without_optional_provider_sdks" $ do
      -- The package has no provider SDK dependency (enforced by its cabal
      -- file); registering every profile is the observable part.
      c <- newCatalog
      mapM_ (register c) runtimeProfiles
      length <$> inspect c `shouldReturn` 10
      length runtimeTerritoryProfiles `shouldBe` 30

  describe "differential: catalog_corpus.json" $ do
    corpus <- runIO (loadJson "differential/catalog_corpus.json")
    it "every runtime territory profile matches the reference bytes" $ do
      let cells = arrayOf (lookupJ "profiles" corpus)
      length cells `shouldBe` length runtimeTerritoryProfiles
      forM_ (zip cells runtimeTerritoryProfiles) $ \(expected, cell) -> do
        lookupJ "family" expected `shouldBe` String (familyText cell.family)
        lookupJ "territory" expected `shouldBe` String (territoryText cell.territory)
        lookupJ "expectation" expected `shouldBe` String (expectationText cell.expectation)
        lookupJ "reason" expected `shouldBe` String cell.reason
        lookupJ "archetype" expected `shouldBe` maybe Null (String . archetypeText) cell.archetype
        lookupJ "descriptor" expected `shouldBe` maybe Null (String . dumpsDefault . descriptorToData) cell.descriptor
    it "descriptor decoding agrees on every case (bytes and refusals)" $ do
      let cases = arrayOf (lookupJ "descriptors" corpus)
      length cases `shouldSatisfy` (> 200)
      forM_ cases $ \c -> checkOutcome c (descriptorToData <$> descriptorFromData (lookupJ "input" c))
    it "snapshot decoding agrees on every case (bytes and refusals)" $
      forM_ (arrayOf (lookupJ "snapshots" corpus)) $ \c ->
        checkOutcome c (snapshotToData <$> snapshotFromData (lookupJ "input" c))
    it "scripted Catalog sessions agree step by step" $ do
      let sessions = arrayOf (lookupJ "sessions" corpus)
      length sessions `shouldBe` 30
      forM_ sessions $ \session -> do
        c <- newCatalog
        forM_ (arrayOf session) (replayStep c)

-- | Compare one decoded case against @output@ (bytes) or @error@.
checkOutcome :: Json -> Either AgenticusError Json -> Expectation
checkOutcome c outcome = case (lookupJ "output" c, outcome) of
  (String expected, Right value) -> dumpsDefault value `shouldBe` expected
  (Null, Left e) -> errorJson e `shouldBe` lookupJ "error" c
  (expected, got) -> expectationFailure ("input " <> show (lookupJ "input" c) <> ": expected " <> show expected <> ", got " <> show got)

errorJson :: AgenticusError -> Json
errorJson e = Object [("class", String (errorClassName e.errorClass)), ("message", String e.errorMessage)]

replayStep :: Catalog -> Json -> Expectation
replayStep c step = do
  let action = lookupJ "action" step
      expectError outcome = case (lookupJ "error" step, outcome) of
        (Null, Right ()) -> pure ()
        (expected, Left e) | expected /= Null -> errorJson e `shouldBe` expected
        (expected, got) -> expectationFailure ("step " <> show step <> ": expected " <> show expected <> ", got " <> show got)
      attempt io = (Right <$> io) `catchAgenticus` (pure . Left)
  case action of
    String "register" -> do
      d <- expectRightIO (descriptorFromData (lookupJ "descriptor" step))
      attempt (register c d) >>= expectError
    String "enable" -> do
      i <- expectRightIO (identityFromData (lookupJ "identity" step))
      attempt (enable c i) >>= expectError
    String "disable" -> do
      i <- expectRightIO (identityFromData (lookupJ "identity" step))
      attempt (disable c i) >>= expectError
    String "resolve" -> do
      picks <- expectRightIO (traverse identityFromData (arrayOf (lookupJ "selections" step)))
      case mkResolutionRequest picks of
        Left e -> errorJson e `shouldBe` lookupJ "error" step
        Right rq -> do
          r <- resolve c rq
          let expected = lookupJ "resolution" step
          Bool (resolutionCompatible r) `shouldBe` lookupJ "compatible" expected
          String (dumpsDefault (Array (map resultToData r.results))) `shouldBe` lookupJ "results" expected
          maybe Null (String . dumpsDefault . snapshotToData) r.snapshot `shouldBe` lookupJ "snapshot" expected
    String "inspect" -> do
      entries <- inspect c
      Array [Array [String (dumpsDefault (descriptorToData e.descriptor)), Bool e.enabled] | e <- entries]
        `shouldBe` lookupJ "inspect" step
    other -> expectationFailure ("unknown action " <> show other)
  rev <- catalogRevisionIO c
  Int rev `shouldBe` lookupJ "revision" step

catchAgenticus :: IO a -> (AgenticusError -> IO a) -> IO a
catchAgenticus = Control.Exception.catch

arrayOf :: Json -> [Json]
arrayOf = \case
  Array xs -> xs
  _ -> []

dumpsDefault :: Json -> Text
dumpsDefault = either (error . show) id . J.dumpsText J.defaultDumps

identityKey :: DescriptorIdentity -> (Text, Text, Integer)
identityKey i = (kindText i.kind, i.name, i.contractVersion)

head' :: [a] -> a
head' = \case
  x : _ -> x
  [] -> error "empty list"

shouldRaiseMatching' :: (Show a) => Either AgenticusError a -> (ErrorClass, Text) -> Expectation
shouldRaiseMatching' outcome (cls, needle) = shouldRaiseMatching outcome cls needle

ownership :: Text -> (Text, Text, Text, Text, Text, Text)
ownership = \case
  "amp.a1.provider-managed" ->
    ("connection.amp", "program.provider-owned", "hands.provider-managed", "continuation.amp-native", "loop.provider-owned", "topology.provider-managed")
  "codex.a2.local" ->
    ("connection.codex", "program.provider-owned", "hands.collocated", "continuation.codex-native", "loop.provider-owned", "topology.durable-collocated")
  "codex.a3.gondolin" ->
    ("connection.codex", "program.provider-owned", "hands.collocated", "continuation.codex-native", "loop.provider-owned", "topology.episode-collocated")
  "claude.a2.local" ->
    ("connection.claude", "program.provider-owned", "hands.collocated", "continuation.claude-native", "loop.provider-owned", "topology.durable-collocated")
  "pi.native.a2.local" ->
    ("connection.pi-compatible", "program.harness-owned", "hands.collocated", "continuation.pi-native", "loop.harness-owned", "topology.durable-collocated")
  "pi.native.a4.gondolin" ->
    ("connection.pi-compatible", "program.harness-owned", "hands.capability-scoped", "continuation.pi-native", "loop.harness-owned", "topology.split")
  "pi.native.a4.e2b" ->
    ("connection.pi-compatible", "program.harness-owned", "hands.capability-scoped", "continuation.pi-native", "loop.harness-owned", "topology.split")
  "pi.application-owned.a5.gondolin" ->
    ("connection.pi-compatible", "program.application-owned", "hands.capability-scoped", "continuation.application-owned", "loop.application-owned", "topology.split")
  "pi.application-owned.a5.e2b" ->
    ("connection.pi-compatible", "program.application-owned", "hands.capability-scoped", "continuation.application-owned", "loop.application-owned", "topology.split")
  "agent-as-net.a5.local" ->
    ("connection.model-call", "program.net-owned", "hands.capability-scoped", "continuation.net-owned", "loop.net-owned", "topology.application-owned")
  other -> error ("unknown profile " <> T.unpack other)

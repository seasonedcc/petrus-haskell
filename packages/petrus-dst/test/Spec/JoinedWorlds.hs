{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The joined History/Dispatch worlds (@tests/dst/test_joined_*world.py@)
-- through the real Absurd Engine over PostgreSQL History and Absurd
-- Workers.
--
-- * Replay (@test_retained_joined_*_replays_without_the_authored_scenario@):
--   each joined fixture replays through a fresh profile in a fresh
--   PostgreSQL database and must end with the reference's replay result
--   bytes (recorded in @test/data/transcripts.json@).
-- * Authoring (@test_joined_*_is_exact_and_replayable@): each Haskell story
--   must author exactly the fixture's bytes in a fresh database, and the
--   authored artifact must replay through a fresh profile in another fresh
--   database with outcome @pass@, the story's disposition, and every
--   operation consumed.
--
-- Pending without @PETRUS_TEST_POSTGRES@.
module Spec.JoinedWorlds (spec, JoinedCase (..), joinedCases) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.HistoryStore.Postgres (ensureSchema)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.Absurd (ensureAbsurdSchema)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport.Postgres (PostgresTarget (..), lookupPostgresUrl, skipMessage, withScratchDatabase)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Joined.Checkers qualified as C
import Petrus.Testing.Dst.Joined.Creation qualified as Creation
import Petrus.Testing.Dst.Joined.Stories qualified as Stories
import Petrus.Testing.Dst.Joined.World (Family (..), JoinedProfile (..), joinedProfile)
import Spec.Support
import System.FilePath ((</>))
import Test.Hspec

-- | A registry of one fresh profile and its checker over one database.
type Fresh = ByteString -> IO (Registry IO)

-- | One joined fixture, its registry, and its Haskell builder.
data JoinedCase = JoinedCase
  { file :: FilePath
  , registry :: Fresh
  , build :: ByteString -> IO (Either DstFailure AnyArtifact)
  , disposition :: Text
  }

joined :: Family -> Checker -> Fresh
joined family checker dsn = do
  p <- joinedProfile family dsn
  pure (registryOf [SomeProfile p.profile] [checker])

creation :: Creation.Variant -> Checker -> Fresh
creation variant checker dsn = do
  p <- Creation.creationProfile variant dsn
  pure (registryOf [SomeProfile p.profile] [checker])

-- | Every joined fixture of the reference.
joinedCases :: [JoinedCase]
joinedCases =
  [ JoinedCase "joined-begin-commit-refusal-world-v3.json" (joined FBegin C.commitAuthorityChecker) Stories.buildBeginArtifact "external_wait"
  , JoinedCase "joined-dispatch-refusal-world-v3.json" (joined FDispatch C.commitAuthorityChecker) Stories.buildDispatchArtifact "external_wait"
  , JoinedCase "joined-begin-ack-loss-world-v3.json" (joined FBeginAckLoss C.acceptedBeginAuthorityChecker) Stories.buildAckLossArtifact "external_wait"
  , JoinedCase
      "joined-delivery-commit-refusal-world-v3.json"
      (joined FDeliveryRefusal C.deliveryAuthorityChecker)
      Stories.buildDeliveryRefusalArtifact
      "external_wait"
  , JoinedCase
      "joined-delivery-ack-loss-world-v3.json"
      (joined FDeliveryAckLoss C.deliveryAuthorityChecker)
      Stories.buildDeliveryAckLossArtifact
      "external_wait"
  , JoinedCase
      "joined-terminal-commit-refusal-world-v3.json"
      (joined FTerminalRefusal C.terminalAuthorityChecker)
      Stories.buildTerminalRefusalArtifact
      "converged"
  , JoinedCase
      "joined-failure-commit-refusal-world-v3.json"
      (joined FFailureRefusal C.failureAuthorityChecker)
      Stories.buildFailureRefusalArtifact
      "quarantined"
  , JoinedCase
      "joined-failure-ack-loss-world-v3.json"
      (joined FFailureAckLoss C.acceptedFailureAuthorityChecker)
      Stories.buildFailureAckLossArtifact
      "quarantined"
  , JoinedCase
      "joined-terminal-ack-loss-world-v3.json"
      (joined FTerminalAckLoss C.acceptedTerminalAuthorityChecker)
      Stories.buildTerminalAckLossArtifact
      "converged"
  , JoinedCase
      "joined-projection-commit-refusal-world-v3.json"
      (joined FProjection C.projectionAuthorityChecker)
      Stories.buildProjectionArtifact
      "converged"
  , JoinedCase
      "joined-projection-ack-loss-world-v3.json"
      (joined FProjectionAckLoss C.acceptedProjectionAuthorityChecker)
      Stories.buildProjectionAckLossArtifact
      "converged"
  , JoinedCase
      "joined-reset-commit-refusal-world-v3.json"
      (joined FResetRefusal C.resetRefusalAuthorityChecker)
      Stories.buildResetRefusalArtifact
      "quiescent"
  , JoinedCase
      "joined-reset-ack-loss-world-v3.json"
      (joined FResetAckLoss C.acceptedResetAuthorityChecker)
      Stories.buildResetAckLossArtifact
      "quiescent"
  , JoinedCase
      "joined-cancellation-commit-refusal-world-v3.json"
      (joined FCancellation C.cancellationAuthorityChecker)
      Stories.buildCancellationArtifact
      "quiescent"
  , JoinedCase
      "joined-cancellation-ack-loss-world-v3.json"
      (joined FCancellationAckLoss C.acceptedCancellationAuthorityChecker)
      Stories.buildCancellationAckLossArtifact
      "quiescent"
  , JoinedCase
      "joined-close-commit-refusal-world-v3.json"
      (joined FCloseRefusal C.closeRefusalAuthorityChecker)
      Stories.buildCloseRefusalArtifact
      "quiescent"
  , JoinedCase
      "joined-close-ack-loss-world-v3.json"
      (joined FCloseAckLoss C.acceptedCloseAuthorityChecker)
      Stories.buildCloseAckLossArtifact
      "quiescent"
  , JoinedCase "joined-open-commit-refusal-world-v3.json" (joined FOpenRefusal C.openAuthorityChecker) Stories.buildOpenRefusalArtifact "external_wait"
  , JoinedCase "joined-open-ack-loss-world-v3.json" (joined FOpenAckLoss C.openAuthorityChecker) Stories.buildOpenAckLossArtifact "external_wait"
  , JoinedCase
      "joined-failure-projection-commit-refusal-world-v3.json"
      (joined FFailureProjectionRefusal C.failureProjectionAuthorityChecker)
      Stories.buildFailureProjectionRefusalArtifact
      "quarantined"
  , JoinedCase
      "joined-failure-projection-ack-loss-world-v3.json"
      (joined FFailureProjectionAckLoss C.acceptedFailureProjectionAuthorityChecker)
      Stories.buildFailureProjectionAckLossArtifact
      "quarantined"
  , JoinedCase
      "joined-scoped-drop-commit-refusal-world-v3.json"
      (joined FScopedDropRefusal C.scopedDropAuthorityChecker)
      Stories.buildScopedDropRefusalArtifact
      "external_wait"
  , JoinedCase
      "joined-scoped-drop-ack-loss-world-v3.json"
      (joined FScopedDropAckLoss C.acceptedScopedDropAuthorityChecker)
      Stories.buildScopedDropAckLossArtifact
      "external_wait"
  , JoinedCase
      "joined-scoped-quarantine-commit-refusal-world-v3.json"
      (joined FScopedQuarantineRefusal C.scopedQuarantineAuthorityChecker)
      Stories.buildScopedQuarantineRefusalArtifact
      "external_wait"
  , JoinedCase
      "joined-scoped-quarantine-ack-loss-world-v3.json"
      (joined FScopedQuarantineAckLoss C.acceptedScopedQuarantineAuthorityChecker)
      Stories.buildScopedQuarantineAckLossArtifact
      "external_wait"
  , JoinedCase
      "joined-registration-projection-commit-refusal-world-v3.json"
      (joined FRegistrationRefusal C.registrationProjectionAuthorityChecker)
      Stories.buildRegistrationRefusalArtifact
      "external_wait"
  , JoinedCase
      "joined-registration-projection-ack-loss-world-v3.json"
      (joined FRegistrationAckLoss C.registrationProjectionAuthorityChecker)
      Stories.buildRegistrationAckLossArtifact
      "external_wait"
  , JoinedCase "joined-seal-commit-refusal-world-v3.json" (joined FSealRefusal C.sealAuthorityChecker) Stories.buildSealRefusalArtifact "converged"
  , JoinedCase "joined-seal-ack-loss-world-v3.json" (joined FSealAckLoss C.sealAuthorityChecker) Stories.buildSealAckLossArtifact "converged"
  , JoinedCase
      "joined-creation-commit-refusal-world-v3.json"
      (creation Creation.Plain C.creationAuthorityChecker)
      (Creation.buildCreationArtifact Creation.Plain)
      "external_wait"
  , JoinedCase
      "joined-creation-ack-loss-world-v3.json"
      (creation Creation.PlainAckLoss C.creationAuthorityChecker)
      (Creation.buildCreationArtifact Creation.PlainAckLoss)
      "external_wait"
  , JoinedCase
      "joined-source-creation-commit-refusal-world-v3.json"
      (creation Creation.Sourced C.sourceCreationAuthorityChecker)
      (Creation.buildCreationArtifact Creation.Sourced)
      "external_wait"
  , JoinedCase
      "joined-source-creation-ack-loss-world-v3.json"
      (creation Creation.SourcedAckLoss C.sourceCreationAuthorityChecker)
      (Creation.buildCreationArtifact Creation.SourcedAckLoss)
      "external_wait"
  ]

fixtureBytes :: FilePath -> IO BS.ByteString
fixtureBytes name = do
  bytes <- BS.readFile (fixturesDir </> name)
  pure (maybe bytes id (BS.stripSuffix "\n" bytes))

-- | @isolated_absurd_database@: one fresh database with both schemas.
isolated :: ByteString -> (ByteString -> IO a) -> IO a
isolated server action =
  withScratchDatabase server $ \target -> do
    bracket (Pg.connect target.targetUrl True) Pg.close $ \connection -> do
      ensureSchema connection
      ensureAbsurdSchema connection
    action target.targetUrl

expectedOutcomes :: IO [(Text, Json)]
expectedOutcomes = do
  vectors <- memberList "fixtures" <$> readJson (dataFile "transcripts.json")
  pure [(memberText "name" v, member "outcome" v) | v <- vectors]

resultJson :: Either DstFailure AnyReplayResult -> Either Text Json
resultJson = \case
  Left failure -> Left (failureClass failure <> ": " <> failureMessage failure)
  Right result -> loadStrictJson (encodeReplayResult result)

spec :: Spec
spec = describe "Joined History/Dispatch worlds (Absurd Engine over PostgreSQL)" $ do
  server <- runIO lookupPostgresUrl
  let withServer body = case server of
        Nothing -> pendingWith skipMessage
        Just url -> body url
  describe "replay of the reference fixtures" $
    forM_ joinedCases $ \c ->
      it c.file $ withServer $ \url -> do
        expected <- expectedOutcomes
        bytes <- fixtureBytes c.file
        artifact <- either (fail . show) pure (decodeArtifact bytes)
        outcome <- isolated url $ \dsn -> do
          reg <- c.registry dsn
          replay reg artifact
        case lookup (T.pack c.file) expected of
          Nothing -> expectationFailure "fixture missing from transcripts.json"
          Just want -> canonText (replayJson outcome) `shouldBe` canonText want
  describe "authoring (is_exact_and_replayable)" $
    forM_ joinedCases $ \c ->
      it c.file $ withServer $ \url -> do
        want <- fixtureBytes c.file
        authored <- isolated url c.build
        artifact <- either (\f -> fail (T.unpack (failureClass f <> ": " <> failureMessage f))) pure authored
        encoded <- either (fail . T.unpack) pure (encodeArtifact artifact)
        BC.unpack encoded `shouldBe` BC.unpack want
        replayed <- isolated url $ \dsn -> do
          reg <- c.registry dsn
          replay reg artifact
        result <- either (fail . T.unpack) pure (resultJson replayed)
        artifactJson <- either (fail . T.unpack) pure (loadStrictJson encoded)
        member "origin" artifactJson `shouldBe` Null
        member "version" result `shouldBe` Int resultVersion
        member "outcome" result `shouldBe` String "pass"
        member "disposition" result `shouldBe` String c.disposition
        member "operations" result `shouldBe` Int (toInteger (length (memberList "operations" artifactJson)))

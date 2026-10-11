-- | @tests/petrus/agenticus/runtime/test_amp_real.py@: opt-in live
-- acceptance for the exact Amp A1 provider-managed Orb lane.
--
-- The adapter runs with its production options: the official @amp@ CLI and
-- the @amp_sdk@ package through the Amp sidecar.
module Petrus.Agenticus.Runtime.Live.AmpSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody (ConnectionStatus (..), ConnectionView (..), mkConnectionIdentity)
import Petrus.Agenticus.Runtime.Amp
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Live.Support
import Petrus.Agenticus.Runtime.Profiles (ampA1)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Continuation (ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (EpisodeId, mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import System.Environment (lookupEnv)
import Test.Hspec

connection :: ConnectionView
connection = ConnectionView (ok (mkConnectionIdentity "live-amp-platform" "amp" "installation-account" "platform-managed")) StatusReady 1 1 Nothing

attach :: Text -> IO (EpisodeAttachment, AmpProviderManagedBinding, EpisodeId)
attach episode = do
  let episodeId = ok (mkEpisodeId episode)
      selected =
        ok . mkResolutionSnapshot 1 $
          [ ampA1
          , ampConnectionCapabilities
          , ampProgramCapabilities
          , ampProviderManagedHands
          , ampProviderManagedTerritory
          , ampContinuationCapabilities
          , hostFencedEffect
          ]
  binding <- newAmpProviderManagedBinding
  now <- getMonotonicTime
  attachment <- newEpisodeAttachment episodeId selected (ampAttachmentBinding binding) ("attachment-" <> episode) (now + 150) episodeOptions
  pure (attachment, binding, episodeId)

spec :: Spec
spec = describe "test_amp_real" $ do
  live
    "test_amp_a1_new_and_continue_in_provider_managed_orb"
    "PETRUS_RUN_CV16_AMP_A1"
    "the authenticated Amp A1 cell"
    $ do
      project <- maybe "henriquebastos/petrus" T.pack <$> lookupEnv "PETRUS_AMP_PROJECT"
      markerOne <- marker "CV16_A1_" 8
      markerTwo <- marker "CV16_A1_" 8
      continuations <- newStore "live-amp-continuation-" "live Amp Continuation custody conflict"
      turns <- newStore "live-amp-turn-" "live Amp Turn custody conflict"
      adapter <-
        newAmpRuntimeAdapter
          (ampRuntimeConfig project) {mode = "low", visibility = "private", noArchiveAfterExecute = False}
          ( ampContinuationCodec
              AmpContinuationOperations
                { store = remember continuations
                , load = stored continuations . Just
                }
          )
          (AmpTurnOperations (\operationId thread finalText -> remember turns operationId (thread, finalText)))
          ampAdapterOptions
      probe <- probeAmp adapter
      probe.disposition `shouldBe` ProbeReady

      (attachmentOne, bindingOne, episodeOne) <- attach "live-amp-episode-1"
      firstOperation <-
        startAmp adapter . ok $
          newAmpRuntimeInvocation
            "live-amp-operation-1"
            episodeOne
            (ok (mkTurnId "live-amp-turn-1"))
            ("Reply exactly " <> markerOne <> ". Do not call tools or modify files.")
            connection
            attachmentOne
            bindingOne
            Nothing
      first <- waitAmpOperation firstOperation (Just 150)
      (first.outcome, first.acceptedAppends) `shouldBe` (TurnCompleted, 1)
      (T.strip . snd <$> stored turns first.outputReference) `shouldReturn` markerOne
      firstPayload <- stored continuations first.continuationReference
      ("T-" `T.isPrefixOf` payloadThreadId firstPayload) `shouldBe` True
      _ <- settleVerified attachmentOne 30

      (attachmentTwo, bindingTwo, episodeTwo) <- attach "live-amp-episode-2"
      let claimed =
            ok $
              mkContinuation
                (ok (mkContinuationId "live-amp-continuation-1"))
                (ok (mkThreadId "live-agenticus-thread"))
                ampContinuationDescriptor
                (maybe "" id first.continuationReference)
                ContinuationInUse
      secondOperation <-
        startAmp adapter . ok $
          newAmpRuntimeInvocation
            "live-amp-operation-2"
            episodeTwo
            (ok (mkTurnId "live-amp-turn-2"))
            ("Remember the exact prior marker. Reply exactly " <> markerOne <> "|" <> markerTwo <> ". Do not call tools or modify files.")
            connection
            attachmentTwo
            bindingTwo
            (Just claimed)
      second <- waitAmpOperation secondOperation (Just 150)
      (second.outcome, second.acceptedAppends) `shouldBe` (TurnCompleted, 1)
      (T.strip . snd <$> stored turns second.outputReference) `shouldReturn` (markerOne <> "|" <> markerTwo)
      secondPayload <- stored continuations second.continuationReference
      payloadThreadId secondPayload `shouldBe` payloadThreadId firstPayload
      () <$ settleVerified attachmentTwo 30

-- | Parity: @tests/petrus/impetus/instance/test_awaiting_termination.py@ —
-- the @awaiting_termination@ fixture's scenario: quiescent with parked work
-- and an armed source registration is AWAITING, not TERMINATED, until the
-- registration is sealed.
module Petrus.Impetus.AwaitingTerminationSpec (spec) where

import Data.Foldable (toList)
import Data.Text (Text)
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Test.Hspec

start, waiting, progressed, resolution, done, beginT, resolve, finish :: NetPath
start = np "start"
waiting = np "waiting"
progressed = np "progressed"
resolution = np "resolution"
done = np "done"
beginT = np "begin"
resolve = np "resolve"
finish = np "finish"

awaitingNet :: Net
awaitingNet =
  netOf
    [place start, place waiting, place progressed, place resolution, place done]
    [transition beginT, transition resolve, transition finish]
    [ arc start beginT
    , arc beginT waiting
    , arc beginT progressed
    , arc resolve resolution
    , arc waiting finish
    , arc resolution finish
    , arc finish done
    ]

fresh :: IO Instance
fresh = seeded awaitingNet (markingFromList [(start, [black])])

-- | Deliver one black resolution and complete its source occurrence.
resolveWith :: Instance -> Text -> IO ()
resolveWith inst ident = do
  answer <- acceptDelivery inst resolve [black] ident Nothing Nothing >>= expectRight
  case answer of
    DeliveryAccepted accepted -> completeDelivery inst accepted Nothing >>= expectRight >> pure ()
    other -> expectationFailure ("expected an AcceptedDelivery, got " <> show other)

spec :: Spec
spec = describe "Instance awaiting termination" $ do
  -- TestAwaitingTermination.test_quiescent_with_parked_work_is_awaiting_not_terminated
  it "is awaiting, not terminated, when quiescent with parked work" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    marking inst `shouldReturn` markingFromList [(waiting, [black]), (progressed, [black])]
    isQuiescent inst `shouldReturn` True
    status inst `shouldReturn` Awaiting
  -- TestAwaitingTermination.test_external_resolution_reenables_the_join
  it "re-enables the join on external resolution" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    resolveWith inst "resolution-event"
    current <- marking inst
    toList (placeTokens resolution current) `shouldBe` [black]
    enabledTransitions inst `shouldReturn` [finish]
  -- TestAwaitingTermination.test_resolution_drains_the_wait_and_the_seal_terminates
  it "drains the wait on resolution, and the seal terminates" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    resolveWith inst "draining-resolution"
    _ <- run inst >>= expectRight
    marking inst `shouldReturn` markingFromList [(done, [black, black]), (progressed, [black])]
    status inst `shouldReturn` Awaiting
    seal inst resolve Nothing >>= expectRight
    status inst `shouldReturn` Terminated
    records <- historyOf inst
    live <- marking inst
    replayMarking records `shouldBe` Right live

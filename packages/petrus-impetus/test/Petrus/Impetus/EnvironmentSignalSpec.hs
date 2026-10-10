-- | Parity: @tests/petrus/impetus/instance/test_environment_signal.py@ —
-- the @environment_signal@ fixture's scenario: a request parks a token, the
-- outside world delivers a @WebhookEvent@ to the @webhook@ source, and the
-- @settle@ join consumes both, forwarding each consumed token per arc.
module Petrus.Impetus.EnvironmentSignalSpec (spec) where

import Data.Foldable (toList)
import Data.Text (Text)
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec

start, pendingSettlement, event, done, request, webhook, settle :: NetPath
start = np "start"
pendingSettlement = np "pending_settlement"
event = np "event"
done = np "done"
request = np "request"
webhook = np "webhook"
settle = np "settle"

webhookEvent :: Token
webhookEvent = tokD "WebhookEvent" (obj [("event_id", String "evt_001"), ("status", String "succeeded")])

signalNet :: Net
signalNet =
  netOf
    [place start, place pendingSettlement, place event, place done]
    [transition request, transition webhook, transition settle]
    [ arc start request
    , arc request pendingSettlement
    , arc webhook event
    , arc pendingSettlement settle
    , arc event settle
    , arc settle done
    ]

fresh :: IO Instance
fresh = seeded signalNet (markingFromList [(start, [black])])

-- | Deliver the webhook event and complete its source occurrence.
deliverEvent :: Instance -> Text -> IO ()
deliverEvent inst ident = do
  answer <- acceptDelivery inst webhook [webhookEvent] ident Nothing Nothing >>= expectRight
  case answer of
    DeliveryAccepted accepted -> completeDelivery inst accepted Nothing >>= expectRight >> pure ()
    other -> expectationFailure ("expected an AcceptedDelivery, got " <> show other)

spec :: Spec
spec = describe "Instance environment signal" $ do
  -- TestEnvironmentSignal.test_the_net_quiesces_awaiting_the_webhook
  it "quiesces awaiting the webhook" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    marking inst `shouldReturn` markingFromList [(pendingSettlement, [black])]
    status inst `shouldReturn` Awaiting
  -- TestEnvironmentSignal.test_delivery_injects_the_event_and_reenables_the_net
  it "injects the event on delivery and re-enables the net" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    deliverEvent inst "reenable-event"
    current <- marking inst
    toList (placeTokens event current) `shouldBe` [webhookEvent]
    enabledTransitions inst `shouldReturn` [settle]
    status inst `shouldReturn` Running
  -- TestEnvironmentSignal.test_settlement_consumes_the_delivered_event_and_forwards_it
  it "consumes the delivered event at settlement and forwards it" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    deliverEvent inst "settlement-event"
    _ <- run inst >>= expectRight
    marking inst `shouldReturn` markingFromList [(done, [black, webhookEvent])]
  -- TestEnvironmentSignal.test_sealing_the_webhook_lets_the_instance_terminate
  it "terminates once the webhook is sealed" $ do
    inst <- fresh
    _ <- run inst >>= expectRight
    deliverEvent inst "terminal-event"
    _ <- run inst >>= expectRight
    status inst `shouldReturn` Awaiting
    seal inst webhook Nothing >>= expectRight
    status inst `shouldReturn` Terminated
    records <- historyOf inst
    live <- marking inst
    replayMarking records `shouldBe` Right live

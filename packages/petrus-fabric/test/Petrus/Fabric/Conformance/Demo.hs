-- | The Haskell twin of conformance_driver.py's @demo_*@ operations: the
-- CV5 Fabric demo's roles ("Petrus.Fabric.Demo"), opened, driven, drained
-- and inspected one step at a time, so the Engine-level checks are written
-- once and run against both implementations — and across them, since both
-- share one database.
module Petrus.Fabric.Conformance.Demo (demoOps) where

import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import Petrus.Engine qualified as Engine
import Petrus.Fabric (envelopeFromData, orThrow)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Demo
import Petrus.Fabric.Ingress (envelopeToken)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (recordName)
import Petrus.Impetus.Instance (PriorAcknowledgement (..), statusText)
import Petrus.Impetus.Instance.Firing (FiringOccurrence (..), FiringOutcome (..))
import Petrus.Impetus.Petrinet (Binding (..), netPath, netPathText)
import Petrus.Json (Json (..), lookupMember)

demoOps :: Handles -> Ops
demoOps handles =
  Map.fromList
    [ ( "demo_bootstrap"
      , \args -> do
          (dsn, parent, child) <- (,,) <$> argText args "dsn" <*> argText args "parent" <*> argText args "child"
          let credentials = argObject args "credentials"
              credentialOf n = case Map.lookup n credentials of
                Just (String c) -> c
                _ -> ""
          bootstrap (TE.encodeUtf8 dsn) parent child credentialOf
          pure Null
      )
    , ( "demo_open"
      , \args -> do
          dsn <- argText args "dsn"
          role <- argText args "role"
          authority <- argText args "authority"
          parent <- argText args "parent"
          child <- argText args "child"
          credential <- argText args "credential"
          let dropCustody = case argMaybe args "drop_custody" of
                Just (Bool True) -> True
                _ -> False
          live <- openRole (TE.encodeUtf8 dsn) role authority parent child credential (if dropCustody then Just custodyDroppingDispatch else Nothing)
          store handles live
      )
    , ( "demo_drive"
      , \args -> do
          live <- liveOf args
          outcome <- drive live
          s <- Engine.status live.engine
          pure (Object [("waiting", Bool outcome.waiting), ("status", String (statusText s))])
      )
    , ("demo_drain", \args -> liveOf args >>= fmap (Int . toInteger) . drainRole)
    , ( "demo_deliver"
      , \args -> do
          live <- liveOf args
          e <- orThrow (envelopeFromData (arg args "envelope"))
          path <- either (fail . show) pure (netPath e.source)
          Engine.deliver live.engine path [envelopeToken e] e.ingressIdentity Nothing >>= \case
            Engine.DeliveryAccepted outcome -> pure (Object [("kind", "fired"), ("occurrence", Int (toInteger outcome.occurrence))])
            Engine.DeliveryPrior prior -> pure (Object [("kind", "prior"), ("occurrence", Int (toInteger prior.occurrence))])
            Engine.DeliveryScoped _ -> pure (Object [("kind", "scoped")])
      )
    , ( "demo_records"
      , \args -> do
          live <- liveOf args
          records <- Engine.records live.engine
          pure (Array [Array [String (recordName r), identityOf (encodeRecord r)] | r <- records])
      )
    , ("demo_invocations", \args -> liveOf args >>= fmap (Int . toInteger) . invocations)
    , ( "demo_in_flight"
      , \args -> do
          live <- liveOf args
          flight <- Engine.inFlight live.engine
          pure (Array [Array [Int (toInteger o.occurrence), String (netPathText o.binding.transition)] | o <- flight])
      )
    , ("demo_close", \args -> liveOf args >>= closeRole >> pure Null)
    ]
  where
    liveOf args = fetch handles args "live" :: IO LiveRole
    identityOf encoded = maybe Null id (lookupMember "identity" encoded)

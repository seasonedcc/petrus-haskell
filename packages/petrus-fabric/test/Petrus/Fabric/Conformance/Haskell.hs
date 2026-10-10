-- | The Haskell twin of test/interop/conformance_driver.py for Fabric: the
-- same operations, answered by this repository's port.
module Petrus.Fabric.Conformance.Haskell
  ( fabricOps
  , envelopeOut
  , envelopeIn
  , routeIn
  , receiptOut
  , connectionOps
  , invocationIn
  ) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), invocation)
import Petrus.Fabric.Send (sendActivity)
import Petrus.Impetus.History.Records (QuarantineScope (..))
import Petrus.Impetus.Instance (DeliveryDisposition (..), PriorAcknowledgement (..), ScopedDeliveryAcknowledgement (..))
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (Token (..), netPath)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Fabric
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Postgres qualified as Fabric
import Petrus.Json (Json (..))
import Petrus.Postgres (Connection)
import Petrus.Postgres qualified as Pg

envelopeOut :: Envelope -> IO Json
envelopeOut e = do
  canonical <- orThrow (canonicalBytes (envelopeToData e))
  pure
    ( Object
        [ ("data", envelopeToData e)
        , ("digest", String e.digest)
        , ("ingress_identity", String e.ingressIdentity)
        , ("canonical", String (TE.decodeUtf8 canonical))
        ]
    )

routeIn :: Maybe Json -> IO (Maybe ReplyRoute)
routeIn = \case
  Nothing -> pure Nothing
  Just (Array [String i, String s]) -> Just <$> orThrow (replyRoute i s)
  Just other -> error ("bad reply_route argument " <> show other)

envelopeIn :: Map Text Json -> IO Envelope
envelopeIn args = do
  route <- routeIn (argMaybe args "reply_route")
  d <- argText args "delivery_id"
  s <- argText args "sender"
  r <- argText args "recipient"
  o <- argText args "source"
  c <- argText args "correlation"
  orThrow (envelope d s r o c (arg args "payload") route)

record :: Text -> [Token] -> Text -> Json
record source tokens identity =
  Object
    [ ("source", String source)
    , ("colors", Array [maybe Null String t.color | t <- tokens])
    , ("identity", String identity)
    , ("data", Array [t.payload | t <- tokens])
    ]

-- | An invocation as the driver spells it.
invocationIn :: Map Text Json -> IO ActivityInvocation
invocationIn args = do
  name <- argText args "activity"
  let text key = case Map.lookup key args of
        Just (String s) -> Just s
        _ -> Nothing
  pure (invocation name (arg args "input")) {correlation = text "correlation", idempotency = text "idempotency"}

stamp :: Maybe a -> (a -> Json) -> Json
stamp value f = maybe Null f value

receiptOut :: Receipt -> Json
receiptOut r =
  Object
    [ ("sender", String r.sender)
    , ("delivery_id", String r.deliveryId)
    , ("recipient", String r.recipient)
    , ("source", String r.source)
    , ("digest", String r.digest)
    , ("state", String (deliveryStateText r.state))
    , ("occurrence", stamp r.occurrence (Int . fromIntegral))
    , ("accepted_at", stamp r.acceptedAt (String . stampText))
    , ("payload_retained", Bool r.payloadRetained)
    ]

-- | The driver's @error_out@: category, class and message.
errorOut :: SomeException -> Json
errorOut err = case fromException err of
  Just fabric ->
    Object
      [ ("category", String (categoryText (errorCategory fabric)))
      , ("type", String (pythonExceptionName fabric))
      , ("message", String (errorMessage fabric))
      ]
  Nothing -> Object [("category", "other"), ("type", "SomeException"), ("message", String (T.pack (show err)))]

unit :: IO () -> IO Json
unit action = Null <$ action

-- | Connections: connect, close, commit, rollback.
connectionOps :: Handles -> Ops
connectionOps handles =
  Map.fromList
    [ ( "connect"
      , \args -> do
          dsn <- argText args "dsn"
          mode <- argBool args "autocommit"
          Pg.connect (TE.encodeUtf8 dsn) mode >>= store handles
      )
    , ("close", \args -> conn args >>= unit . Pg.close)
    , ("commit", \args -> conn args >>= unit . Pg.commit)
    , ("rollback", \args -> conn args >>= unit . Pg.rollback)
    ]
  where
    conn args = fetch handles args "conn" :: IO Connection

fabricOps :: Handles -> Ops
fabricOps handles =
  Map.union (connectionOps handles) . Map.fromList $
    [ ( "canonical"
      , \args -> do
          bytes <- orThrow (canonicalBytes (arg args "value"))
          pure (Object [("text", String (TE.decodeUtf8 bytes)), ("sha256", String (sha256Hex bytes))])
      )
    , ("envelope", \args -> envelopeIn args >>= envelopeOut)
    , ("envelope_from_data", \args -> orThrow (envelopeFromData (arg args "data")) >>= envelopeOut)
    , ( "envelope_detached"
      , \args -> do
          let payload = Object [("nested", Array [Int 1, Object [("ok", Bool True)]])]
          e <- envelopeIn (Map.insert "payload" payload (argObject args "envelope"))
          -- "Mutating" the caller's value builds a new one; the envelope
          -- keeps its own, and nothing in its API writes to it.
          let _mutated = Object [("nested", Array [Int 1, Object [("ok", Bool False)]])]
          pure (Object [("payload", e.payload), ("mutable", Bool False)])
      )
    , ( "reply_route_from_data"
      , \args -> do
          r <- orThrow (replyRouteFromData (arg args "data"))
          pure (Array [String r.instanceId, String r.source])
      )
    , ( "endpoint"
      , \args -> do
          r <- argText args "recipient"
          s <- argText args "source"
          endpointToData <$> orThrow (endpoint r s (arg args "capabilities"))
      )
    , ("endpoint_from_data", \args -> endpointToData <$> orThrow (endpointFromData (arg args "data")))
    , ("credential_ok", \args -> argText args "credential" >>= orThrow . Fabric.validateCredential >> pure (Bool True))
    , ("issue_credential", \_ -> String <$> Fabric.issueCredential)
    , ("ensure_fabric_schema", \args -> conn args >>= unit . Fabric.ensureFabricSchema)
    , ( "register"
      , \args -> do
          c <- conn args
          i <- argText args "instance"
          k <- argText args "credential"
          unit (Fabric.registerProcess c i k)
      )
    , ( "client"
      , \args -> do
          c <- conn args
          i <- argText args "instance"
          k <- argText args "credential"
          Fabric.postgresFabric c i k >>= store handles
      )
    , ("authenticate", \args -> client args >>= unit . Fabric.authenticate)
    , ("expose", \args -> client args >>= \f -> argText args "source" >>= unit . Fabric.exposeSource f)
    , ( "offer"
      , \args -> do
          f <- client args
          s <- argText args "source"
          v <- argText args "service"
          unit (Fabric.offerService f s v (arg args "capabilities"))
      )
    , ("grant", \args -> twoTexts args "sender" "source" >>= \(f, a, b) -> unit (Fabric.grant f a b))
    , ("revoke", \args -> twoTexts args "sender" "source" >>= \(f, a, b) -> unit (Fabric.revoke f a b))
    , ( "discover"
      , \args -> do
          f <- client args
          s <- argText args "service"
          Array . map endpointToData <$> Fabric.discover f s (argMaybe args "capabilities")
      )
    , ( "submit"
      , \args -> do
          f <- client args
          e <- envelopeIn (argObject args "envelope")
          s <- Fabric.submit f e
          pure
            ( Object
                [ ("sender", String s.sender)
                , ("delivery_id", String s.deliveryId)
                , ("state", String (deliveryStateText s.state))
                , ("duplicate", Bool s.duplicate)
                , ("occurrence", stamp s.occurrence (Int . fromIntegral))
                , ("accepted_at", stamp s.acceptedAt (String . stampText))
                ]
            )
      )
    , ("pending", \args -> client args >>= \f -> argInt args "limit" >>= Fabric.pending f >>= fmap Array . mapM envelopeOut)
    , ( "acknowledge"
      , \args -> do
          f <- client args
          s <- argText args "sender"
          d <- argText args "delivery_id"
          o <- argInt args "occurrence"
          receiptOut <$> Fabric.acknowledge f s d o
      )
    , ("receipt", \args -> client args >>= \f -> argText args "delivery_id" >>= fmap (maybe Null receiptOut) . Fabric.receipt f)
    , ( "drain_fake"
      , \args -> do
          f <- client args
          calls <- newIORef []
          let occurrence = case arg args "occurrence" of
                Int n -> fromIntegral n
                _ -> 7
              failOn = case arg args "fail_on" of
                Array [String how, Int n] -> Just (how, fromIntegral n :: Int)
                _ -> Nothing
              prior = arg args "mode" == String "prior"
              door = DeliveryDoor $ \source tokens identity -> do
                n <- atomicModifyIORef' calls (\cs -> (cs ++ [record source tokens identity], length cs + 1))
                case failOn of
                  Just ("raise", k) | k == n -> throwIO (userError "door refused the delivery")
                  Just ("other", k)
                    | k == n ->
                        pure (DoorScoped (ScopedDeliveryAcknowledgement identity Dropped (QuarantineName "other")))
                  _
                    | prior -> pure (DoorPrior (PriorAcknowledgement identity occurrence))
                    | otherwise -> do
                        path <- either (throwIO . InvalidValue) pure (netPath source)
                        pure (DoorFired (FiringOutcome path occurrence [] [] []))
              limit = case arg args "limit" of
                Int n -> fromIntegral n
                _ -> 100
          result <- try (drain (FabricInbox (Fabric.inboxClient f) door) limit)
          made <- readIORef calls
          case result of
            Right receipts -> pure (Object [("calls", Array made), ("receipts", Array (map receiptOut receipts))])
            Left (err :: SomeException) -> pure (Object [("calls", Array made), ("error", errorOut err)])
      )
    , ( "send_activity"
      , \args -> do
          dsn <- argText args "dsn"
          instance' <- argText args "instance"
          credential <- argText args "credential"
          inv <- invocationIn (argObject args "invocation")
          Pg.withConnection (TE.encodeUtf8 dsn) True $ \connection -> do
            f <- Fabric.postgresFabric connection instance' credential
            sendActivity (Fabric.submit f) inv
      )
    , ( "prune"
      , \args -> do
          f <- client args
          before <- argText args "before"
          cutoff <- maybe (typedCutoff before) pure (parseStamp before)
          Int . fromIntegral <$> Fabric.pruneAccepted f cutoff
      )
    ]
  where
    conn args = fetch handles args "conn" :: IO Connection
    client args = fetch handles args "client" :: IO Fabric.PostgresFabric
    twoTexts args a b = (,,) <$> client args <*> argText args a <*> argText args b
    typedCutoff before = throwIO (InvalidType ("type-enforced: a pruning cutoff is a UTCTime, never a naive " <> before))

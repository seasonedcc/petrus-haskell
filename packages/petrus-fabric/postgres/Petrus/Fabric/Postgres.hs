-- | The trusted-workspace PostgreSQL Fabric (a port of
-- @petrus.fabric.postgres@, spec/fabric.md §6–§8).
--
-- The schema, every SQL statement, and the transaction discipline are the
-- reference's, so Python and Haskell processes share one @impetus_fabric@
-- schema: on an autocommit connection @submit@ and @acknowledge@ own one
-- transaction each, and on a join-mode connection every operation runs in
-- the caller's transaction and never commits it (§8.1). Storage failures
-- surface as 'Petrus.Postgres.PostgresError', refusals as
-- 'Petrus.Fabric.Error.FabricError'.
module Petrus.Fabric.Postgres
  ( -- * Schema (§6)
    ensureFabricSchema
  , fabricSchemaVersion
  , fabricDdl
    -- * Credentials and registration (§7, §8.3)
  , issueCredential
  , validateCredential
  , credentialDigest
  , registerProcess
    -- * The authenticated client (§8)
  , PostgresFabric
  , postgresFabric
  , fabricInstance
  , fabricConnection
  , authenticate
  , exposeSource
  , offerService
  , grant
  , revoke
  , discover
  , submit
  , send
  , pending
  , acknowledge
  , receipt
  , pruneAccepted
  , inboxClient
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM, unless, when)
import Crypto.Random (getRandomBytes)
import Data.Bits (xor, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as Base64
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Unsafe qualified as TU
import Data.Time (UTCTime)
import Petrus.Fabric.Error
import Petrus.Fabric.Ingress (InboxClient (..))
import Petrus.Fabric.Model
import Petrus.Json (Json (..))
import Petrus.Postgres
  ( Connection
  , Sql
  , column
  , decodeBool
  , decodeInt
  , decodeJson
  , decodeText
  , decodeTimestamptz
  , execute
  , execute_
  , intParam
  , jsonbParam
  , nullable
  , query
  , queryFirst
  , textArrayParam
  , textParam
  , timestamptzParam
  , withTransaction
  )
import Petrus.Postgres qualified as Pg
import Petrus.Telemetry (emit, getLogger)
import Petrus.Telemetry qualified as Telemetry

log' :: Telemetry.TelemetryLogger
log' = getLogger "impetus" Nothing

-- ---------------------------------------------------------------------------
-- Schema

-- | @_SCHEMA_VERSION@.
fabricSchemaVersion :: Int
fabricSchemaVersion = 1

-- | @_DDL@, verbatim (§6.1).
fabricDdl :: [Sql]
fabricDdl =
  [ "CREATE SCHEMA IF NOT EXISTS impetus_fabric"
  , "CREATE TABLE IF NOT EXISTS impetus_fabric.schema_metadata (\n        component text PRIMARY KEY, version integer NOT NULL)"
  , "CREATE TABLE IF NOT EXISTS impetus_fabric.processes (\n        instance_id text PRIMARY KEY, credential_digest text NOT NULL,\n        registered_at timestamptz NOT NULL DEFAULT clock_timestamp())"
  , "CREATE TABLE IF NOT EXISTS impetus_fabric.exposed_sources (\n        instance_id text NOT NULL REFERENCES impetus_fabric.processes(instance_id), source text NOT NULL,\n        exposed_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (instance_id, source))"
  , "CREATE TABLE IF NOT EXISTS impetus_fabric.service_offers (\n        instance_id text NOT NULL, source text NOT NULL, service text NOT NULL, capabilities jsonb NOT NULL,\n        offered_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY (instance_id, source, service),\n        FOREIGN KEY (instance_id, source) REFERENCES impetus_fabric.exposed_sources(instance_id, source))"
  , "CREATE TABLE IF NOT EXISTS impetus_fabric.delivery_grants (\n        sender text NOT NULL REFERENCES impetus_fabric.processes(instance_id), recipient text NOT NULL,\n        source text NOT NULL, granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),\n        PRIMARY KEY (sender, recipient, source),\n        FOREIGN KEY (recipient, source) REFERENCES impetus_fabric.exposed_sources(instance_id, source))"
  , "CREATE TABLE IF NOT EXISTS impetus_fabric.deliveries (\n        sender text NOT NULL REFERENCES impetus_fabric.processes(instance_id), delivery_id text NOT NULL,\n        recipient text NOT NULL REFERENCES impetus_fabric.processes(instance_id), source text NOT NULL,\n        correlation text NOT NULL, envelope jsonb, digest text NOT NULL, submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),\n        accepted_occurrence bigint, accepted_at timestamptz,\n        PRIMARY KEY (sender, delivery_id),\n        CHECK ((accepted_occurrence IS NULL) = (accepted_at IS NULL)),\n        CHECK (envelope IS NOT NULL OR accepted_at IS NOT NULL))"
  , "CREATE INDEX IF NOT EXISTS fabric_pending_by_recipient ON impetus_fabric.deliveries (recipient, submitted_at) WHERE accepted_at IS NULL"
  , "CREATE INDEX IF NOT EXISTS fabric_offers_by_service ON impetus_fabric.service_offers (service, instance_id, source)"
  ]

-- | @ensure_fabric_schema(connection)@ (§6.3): provision the versioned
-- schema without committing the caller's transaction; refuse an unversioned
-- known table or any version other than 1.
ensureFabricSchema :: Connection -> IO ()
ensureFabricSchema connection = do
  exists <- queryFirst connection "SELECT 1 FROM pg_namespace WHERE nspname = 'impetus_fabric'" []
  case exists of
    Nothing -> pure ()
    Just _ -> do
      metadata <- queryFirst connection "SELECT to_regclass('impetus_fabric.schema_metadata')" []
      when (maybe True (\row -> all (== Nothing) row) metadata) $ do
        known <-
          queryFirst
            connection
            "SELECT table_name FROM information_schema.tables\n            WHERE table_schema = 'impetus_fabric' AND table_name = ANY(%s) LIMIT 1"
            [textArrayParam ["processes", "exposed_sources", "service_offers", "delivery_grants", "deliveries"]]
        case known of
          Just [Just name] ->
            throwIO
              ( SchemaRefused
                  ( "the impetus_fabric schema contains unversioned table "
                      <> pyRepr (TE.decodeUtf8 name)
                      <> ": refusing to bless an unknown shape \8212 migrate or recreate the fabric schema deliberately"
                  )
              )
          _ -> pure ()
  mapM_ (\statement -> execute_ connection statement []) fabricDdl
  execute_
    connection
    "INSERT INTO impetus_fabric.schema_metadata (component, version) VALUES ('fabric', %s)\n        ON CONFLICT (component) DO NOTHING"
    [intParam (fromIntegral fabricSchemaVersion)]
  version <- queryFirst connection "SELECT version FROM impetus_fabric.schema_metadata WHERE component = 'fabric'" []
  let found = case version of
        Just [Just v] -> either (const Nothing) Just (decodeInt v)
        _ -> Nothing
  unless (found == Just (fromIntegral fabricSchemaVersion)) $
    throwIO
      ( SchemaRefused
          ( "the database speaks impetus_fabric schema version "
              <> maybe "None" (T.pack . show) found
              <> ", but this runtime requires version 1: migrate deliberately rather than upgrading implicitly at boot"
          )
      )

-- ---------------------------------------------------------------------------
-- Credentials

-- | @issue_credential()@: 32 random bytes, base64url without padding (the
-- reference's @secrets.token_urlsafe(32)@), redrawn in the vanishingly rare
-- case it would fail the acceptance rule.
issueCredential :: IO Text
issueCredential = do
  bytes <- getRandomBytes 32 :: IO ByteString
  let credential = TE.decodeLatin1 (Base64.encodeUnpadded bytes)
  either (const issueCredential) pure (validateCredential credential)

-- | @_credential@: at least 32 UTF-8 bytes and 16 distinct code points (§7).
validateCredential :: Text -> Either FabricError Text
validateCredential credential
  | TU.lengthWord8 credential < 32 || Set.size (Set.fromList (T.unpack credential)) < 16 =
      Left (InvalidValue "credential must be a high-entropy opaque token of at least 32 UTF-8 bytes")
  | otherwise = Right credential

-- | The stored form: lowercase SHA-256 hex of the credential's UTF-8.
credentialDigest :: Text -> Text
credentialDigest = sha256Hex . TE.encodeUtf8

-- @hmac.compare_digest@ on the digests' bytes.
sameDigest :: Text -> Text -> Bool
sameDigest a b =
  let x = TE.encodeUtf8 a
      y = TE.encodeUtf8 b
   in BS.length x == BS.length y && foldl' (.|.) 0 (BS.zipWith xor x y) == 0

-- | @register_process(connection, instance, credential)@ (§8.3): store the
-- credential digest; idempotent for the same credential, a conflict for a
-- different one.
registerProcess :: Connection -> Text -> Text -> IO ()
registerProcess connection instance' credential = do
  name <- orThrow (fabricText "instance" instance')
  digest <- credentialDigest <$> orThrow (validateCredential credential)
  inserted <-
    execute
      connection
      "INSERT INTO impetus_fabric.processes (instance_id, credential_digest) VALUES (%s, %s) ON CONFLICT DO NOTHING"
      [textParam name, textParam digest]
  if inserted > 0
    then emit log' "fabric_registered" [("instance", String name)]
    else do
      row <- queryFirst connection "SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = %s" [textParam name]
      let stored = case row of
            Just [Just bytes] -> Just (TE.decodeUtf8 bytes)
            _ -> Nothing
      unless (maybe False (sameDigest digest) stored) $ do
        emit log' "fabric_conflict" [("operation", String "register"), ("instance", String name)]
        throwIO (Conflict ("process " <> pyRepr name <> " is already registered with a different credential"))

-- ---------------------------------------------------------------------------
-- The client

-- | @PostgresFabric(connection, instance, credential)@: a client bound to one
-- process identity, using — never committing — the caller's connection.
data PostgresFabric = PostgresFabric
  { connection :: Connection
  , instanceId :: Text
  , digest :: Text
  }

-- | Validate the instance and the credential (no database access, §8.2).
postgresFabric :: Connection -> Text -> Text -> IO PostgresFabric
postgresFabric connection instance' credential = do
  Telemetry.validateTelemetryEnvironment
  name <- orThrow (fabricText "instance" instance')
  digest <- credentialDigest <$> orThrow (validateCredential credential)
  pure (PostgresFabric connection name digest)

-- | The bound process identity (@client.instance@).
fabricInstance :: PostgresFabric -> Text
fabricInstance client = client.instanceId

fabricConnection :: PostgresFabric -> Connection
fabricConnection client = client.connection

-- | @_auth()@ (§8.2).
authenticate :: PostgresFabric -> IO ()
authenticate client = do
  row <-
    queryFirst
      client.connection
      "SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = %s"
      [textParam client.instanceId]
  let stored = case row of
        Just [Just bytes] -> Just (TE.decodeUtf8 bytes)
        _ -> Nothing
  unless (maybe False (sameDigest client.digest) stored) $ do
    emit log' "fabric_denied" [("operation", String "authenticate"), ("instance", String client.instanceId)]
    throwIO (Denied ("fabric authentication failed for " <> pyRepr client.instanceId))

-- | @expose_source(source)@ (§8.4).
exposeSource :: PostgresFabric -> Text -> IO ()
exposeSource client source' = do
  source <- orThrow (fabricText "source" source')
  authenticate client
  execute_
    client.connection
    "INSERT INTO impetus_fabric.exposed_sources (instance_id, source) VALUES (%s, %s) ON CONFLICT DO NOTHING"
    [textParam client.instanceId, textParam source]
  emit log' "fabric_exposed" [("instance", String client.instanceId), ("source", String source)]

-- | @offer_service(source, service, capabilities)@ (§8.5).
offerService :: PostgresFabric -> Text -> Text -> Json -> IO ()
offerService client source' service' capabilities = do
  source <- orThrow (fabricText "source" source')
  service <- orThrow (fabricText "service" service')
  _ <- orThrow (jsonObject "capabilities" capabilities)
  snapshot <- orThrow (jsonCopy "capabilities" capabilities)
  authenticate client
  execute_
    client.connection
    "INSERT INTO impetus_fabric.service_offers (instance_id, source, service, capabilities)\n            VALUES (%s, %s, %s, %s) ON CONFLICT (instance_id, source, service)\n            DO UPDATE SET capabilities = EXCLUDED.capabilities, offered_at = clock_timestamp()"
    [textParam client.instanceId, textParam source, textParam service, jsonb snapshot]
  emit
    log'
    "fabric_offered"
    [("instance", String client.instanceId), ("source", String source), ("service", String service)]

jsonb :: Json -> Pg.Param
jsonb value = either (error . ("a validated JSON value cannot be refused: " <>) . show) id (jsonbParam value)

-- | @grant(sender, source)@ (§8.6).
grant :: PostgresFabric -> Text -> Text -> IO ()
grant client sender' source' = do
  sender <- orThrow (fabricText "sender" sender')
  source <- orThrow (fabricText "source" source')
  authenticate client
  execute_
    client.connection
    "INSERT INTO impetus_fabric.delivery_grants (sender, recipient, source) VALUES (%s, %s, %s) ON CONFLICT DO NOTHING"
    [textParam sender, textParam client.instanceId, textParam source]
  emit
    log'
    "fabric_granted"
    [("sender", String sender), ("recipient", String client.instanceId), ("source", String source)]

-- | @revoke(sender, source)@ (§8.6).
revoke :: PostgresFabric -> Text -> Text -> IO ()
revoke client sender' source' = do
  sender <- orThrow (fabricText "sender" sender')
  source <- orThrow (fabricText "source" source')
  authenticate client
  execute_
    client.connection
    "DELETE FROM impetus_fabric.delivery_grants WHERE sender = %s AND recipient = %s AND source = %s"
    [textParam sender, textParam client.instanceId, textParam source]

-- | @discover(service, capabilities=None)@ (§8.7): granted offers whose
-- capabilities contain the filter, ordered by @(instance_id, source)@.
discover :: PostgresFabric -> Text -> Maybe Json -> IO [Endpoint]
discover client service' capabilities = do
  service <- orThrow (fabricText "service" service')
  let wanted = maybe (Object []) id capabilities
  _ <- orThrow (jsonObject "capabilities" wanted)
  snapshot <- orThrow (jsonCopy "capabilities" wanted)
  authenticate client
  rows <-
    query
      client.connection
      "SELECT o.instance_id, o.source, o.capabilities FROM impetus_fabric.service_offers o\n            JOIN impetus_fabric.delivery_grants g ON (g.recipient, g.source) = (o.instance_id, o.source)\n            WHERE g.sender = %s AND o.service = %s AND o.capabilities @> %s\n            ORDER BY o.instance_id, o.source"
      [textParam client.instanceId, textParam service, jsonb snapshot]
  forM rows $ \case
    [recipient, source, offered] -> do
      decoded <-
        decodeRow
          ( (,,)
              <$> column decodeText recipient
              <*> column decodeText source
              <*> column decodeJson offered
          )
      let (r, s, c) = decoded
      orThrow (endpoint r s c)
    other -> unexpectedRow other

decodeRow :: Either String a -> IO a
decodeRow = either (\problem -> throwIO (userError ("unexpected impetus_fabric row: " <> problem))) pure

unexpectedRow :: Show r => r -> IO a
unexpectedRow row = throwIO (userError ("unexpected impetus_fabric row: " <> show row))

-- The prior row of a delivery: digest, accepted occurrence, accepted at.
priorRow :: [Maybe ByteString] -> IO (Text, Maybe Int, Maybe UTCTime)
priorRow = \case
  [d, o, a] ->
    decodeRow
      ( (,,)
          <$> column decodeText d
          <*> (fmap (fmap fromIntegral) (nullable decodeInt o))
          <*> nullable decodeTimestamptz a
      )
  other -> unexpectedRow other

priorSubmission :: PostgresFabric -> Envelope -> (Text, Maybe Int, Maybe UTCTime) -> IO Submission
priorSubmission client e (stored, occurrence, acceptedAt) = do
  unless (sameDigest stored e.digest) $ do
    emit log' "fabric_conflict" (("operation", String "submit") : envelopeFields' client e)
    throwIO
      ( Conflict
          ( "fabric delivery identity conflict for ("
              <> pyRepr client.instanceId
              <> ", "
              <> pyRepr e.deliveryId
              <> "): content or address changed"
          )
      )
  let state = maybe Pending (const Accepted) acceptedAt
  emit log' "fabric_redelivered" (envelopeFields' client e ++ [("state", String (deliveryStateText state))])
  pure (Submission client.instanceId e.deliveryId state True occurrence acceptedAt)

envelopeFields' :: PostgresFabric -> Envelope -> [(Text, Json)]
envelopeFields' client e =
  [ ("sender", String client.instanceId)
  , ("recipient", String e.recipient)
  , ("source", String e.source)
  , ("correlation", String e.correlation)
  , ("delivery_id", String e.deliveryId)
  ]

selectPrior :: Sql
selectPrior =
  "SELECT digest, accepted_occurrence, accepted_at FROM impetus_fabric.deliveries\n                WHERE sender = %s AND delivery_id = %s FOR UPDATE"

-- | @submit(envelope)@ (§8.8): an exact retransmission is a duplicate (even
-- after revocation or pruning), changed content a conflict, and a new
-- delivery needs the recipient's exposure and grant.
submit :: PostgresFabric -> Envelope -> IO Submission
submit client e = do
  unless (e.sender == client.instanceId) $
    throwIO (Denied "envelope sender must match the authenticated fabric client")
  authenticate client
  result <- withTransaction client.connection $ do
    prior <- queryFirst client.connection selectPrior [textParam client.instanceId, textParam e.deliveryId]
    case prior of
      Just row -> Just <$> (priorRow row >>= priorSubmission client e)
      Nothing -> do
        allowed <-
          queryFirst
            client.connection
            "SELECT 1 FROM impetus_fabric.exposed_sources e JOIN impetus_fabric.delivery_grants g\n                ON (g.recipient, g.source) = (e.instance_id, e.source)\n                WHERE e.instance_id = %s AND e.source = %s AND g.sender = %s"
            [textParam e.recipient, textParam e.source, textParam client.instanceId]
        case allowed of
          Nothing -> do
            emit log' "fabric_denied" (("operation", String "submit") : envelopeFields' client e)
            throwIO (Denied "recipient source is not exposed and granted to this sender")
          Just _ -> do
            inserted <-
              execute
                client.connection
                "INSERT INTO impetus_fabric.deliveries\n                (sender, delivery_id, recipient, source, correlation, envelope, digest)\n                VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING"
                [ textParam client.instanceId
                , textParam e.deliveryId
                , textParam e.recipient
                , textParam e.source
                , textParam e.correlation
                , jsonb (envelopeToData e)
                , textParam e.digest
                ]
            if inserted == 0
              then do
                -- A concurrent submit won after the first read; PostgreSQL
                -- waited for it here. Verify it exactly as any retry.
                again <- queryFirst client.connection selectPrior [textParam client.instanceId, textParam e.deliveryId]
                case again of
                  Just row -> Just <$> (priorRow row >>= priorSubmission client e)
                  Nothing -> unexpectedRow ([] :: [Maybe ByteString])
              else do
                execute_ client.connection "SELECT pg_notify('impetus_fabric_delivery', %s)" [textParam e.recipient]
                pure Nothing
  case result of
    Just duplicate -> pure duplicate
    Nothing -> do
      emit log' "fabric_submitted" (envelopeFields' client e)
      pure (Submission client.instanceId e.deliveryId Pending False Nothing Nothing)

-- | @send@, the reference's alias of 'submit'.
send :: PostgresFabric -> Envelope -> IO Submission
send = submit

-- | @pending(limit=100)@ (§8.9): this recipient's unaccepted deliveries,
-- oldest first.
pending :: PostgresFabric -> Int -> IO [Envelope]
pending client limit = do
  when (limit < 1) $ throwIO (InvalidValue "limit must be a positive integer")
  authenticate client
  rows <-
    query
      client.connection
      "SELECT envelope FROM impetus_fabric.deliveries WHERE recipient = %s AND accepted_at IS NULL\n            ORDER BY submitted_at, sender, delivery_id LIMIT %s"
      [textParam client.instanceId, intParam (fromIntegral limit)]
  forM rows $ \case
    [stored] -> decodeRow (column decodeJson stored) >>= orThrow . envelopeFromData
    other -> unexpectedRow other

-- | @acknowledge(sender, delivery_id, occurrence)@ (§8.10): record the
-- recipient History occurrence that accepted the delivery, exactly once.
acknowledge :: PostgresFabric -> Text -> Text -> Int -> IO Receipt
acknowledge client sender' deliveryId' occurrence = do
  sender <- orThrow (fabricText "sender" sender')
  deliveryId <- orThrow (fabricText "delivery_id" deliveryId')
  when (occurrence < 1) $ throwIO (InvalidValue "occurrence must be a positive integer")
  authenticate client
  (recipient, source, correlation, digest, acceptedAt, retained) <- withTransaction client.connection $ do
    row <-
      queryFirst
        client.connection
        "SELECT recipient, source, correlation, digest, accepted_occurrence, accepted_at,\n                envelope IS NOT NULL\n                FROM impetus_fabric.deliveries WHERE sender = %s AND delivery_id = %s AND recipient = %s FOR UPDATE"
        [textParam sender, textParam deliveryId, textParam client.instanceId]
    case row of
      Nothing ->
        throwIO
          ( NotFound
              ("pending delivery (" <> pyRepr sender <> ", " <> pyRepr deliveryId <> ") does not exist for this recipient")
          )
      Just [r, s, c, d, o, a, k] -> do
        (recipient, source, correlation, digest, prior, at, retained) <-
          decodeRow
            ( (,,,,,,)
                <$> column decodeText r
                <*> column decodeText s
                <*> column decodeText c
                <*> column decodeText d
                <*> fmap (fmap fromIntegral) (nullable decodeInt o)
                <*> nullable decodeTimestamptz a
                <*> column decodeBool k
            )
        case (prior, at) of
          (Just accepted, _) | accepted /= occurrence -> do
            emit
              log'
              "fabric_conflict"
              [ ("operation", String "acknowledge")
              , ("sender", String sender)
              , ("recipient", String client.instanceId)
              , ("source", String source)
              , ("correlation", String correlation)
              , ("delivery_id", String deliveryId)
              ]
            throwIO
              ( Conflict
                  ( "delivery was already accepted by occurrence "
                      <> T.pack (show accepted)
                      <> ", not "
                      <> T.pack (show occurrence)
                  )
              )
          (Just _, existing) -> pure (recipient, source, correlation, digest, existing, retained)
          (Nothing, _) -> do
            updated <-
              queryFirst
                client.connection
                "UPDATE impetus_fabric.deliveries SET accepted_occurrence = %s, accepted_at = clock_timestamp()\n                    WHERE sender = %s AND delivery_id = %s RETURNING accepted_at"
                [intParam (fromIntegral occurrence), textParam sender, textParam deliveryId]
            stamp <- case updated of
              Just [value] -> decodeRow (nullable decodeTimestamptz value)
              other -> unexpectedRow other
            pure (recipient, source, correlation, digest, stamp, retained)
      Just other -> unexpectedRow other
  emit
    log'
    "fabric_accepted"
    [ ("sender", String sender)
    , ("recipient", String client.instanceId)
    , ("source", String source)
    , ("correlation", String correlation)
    , ("delivery_id", String deliveryId)
    , ("occurrence", Int (fromIntegral occurrence))
    ]
  pure (Receipt sender deliveryId recipient source digest Accepted (Just occurrence) acceptedAt retained)

-- | @receipt(delivery_id)@ (§8.11): the sender's view of one of its own
-- deliveries.
receipt :: PostgresFabric -> Text -> IO (Maybe Receipt)
receipt client deliveryId' = do
  deliveryId <- orThrow (fabricText "delivery_id" deliveryId')
  authenticate client
  row <-
    queryFirst
      client.connection
      "SELECT recipient, source, digest, accepted_occurrence, accepted_at, envelope IS NOT NULL\n            FROM impetus_fabric.deliveries WHERE sender = %s AND delivery_id = %s"
      [textParam client.instanceId, textParam deliveryId]
  case row of
    Nothing -> pure Nothing
    Just [r, s, d, o, a, k] -> do
      (recipient, source, digest, occurrence, acceptedAt, retained) <-
        decodeRow
          ( (,,,,,)
              <$> column decodeText r
              <*> column decodeText s
              <*> column decodeText d
              <*> fmap (fmap fromIntegral) (nullable decodeInt o)
              <*> nullable decodeTimestamptz a
              <*> column decodeBool k
          )
      let state = maybe Pending (const Accepted) acceptedAt
      pure (Just (Receipt client.instanceId deliveryId recipient source digest state occurrence acceptedAt retained))
    Just other -> unexpectedRow other

-- | @prune_accepted(before)@ (§8.12): drop the envelope bytes of this
-- recipient's deliveries accepted before the cutoff; identity, digest, and
-- acceptance stay. A 'UTCTime' is always timezone-aware.
pruneAccepted :: PostgresFabric -> UTCTime -> IO Int
pruneAccepted client before = do
  authenticate client
  pruned <-
    execute
      client.connection
      "UPDATE impetus_fabric.deliveries SET envelope = NULL\n            WHERE recipient = %s AND accepted_at < %s AND envelope IS NOT NULL"
      [textParam client.instanceId, timestamptzParam before]
  emit log' "fabric_pruned" [("instance", String client.instanceId), ("deliveries", Int (fromIntegral pruned))]
  pure pruned

-- | The recipient side of the client, for a 'Petrus.Fabric.Ingress.FabricInbox'.
inboxClient :: PostgresFabric -> InboxClient
inboxClient client = InboxClient {pending = pending client, acknowledge = acknowledge client}


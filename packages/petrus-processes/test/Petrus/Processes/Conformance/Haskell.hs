-- | The Haskell twin of the process-lifecycle operations in
-- ../petrus-fabric/test/interop/conformance_driver.py: the same requests,
-- answered by this repository's port.
module Petrus.Processes.Conformance.Haskell
  ( processOps
  , specOut
  , specIn
  ) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Fabric
import Petrus.Fabric.Conformance.Haskell (envelopeOut, invocationIn, routeIn)
import Petrus.Fabric.Conformance.Impl
import Petrus.Json (Json (..))
import Petrus.Postgres (Connection, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.Processes
import Petrus.Processes.Postgres qualified as Registry

specOut :: SpawnSpec -> IO Json
specOut s = do
  canonical <- orThrow (canonicalBytes (spawnSpecToData s))
  pure
    ( Object
        [ ("data", spawnSpecToData s)
        , ("digest", String s.digest)
        , ("child", String s.child)
        , ("canonical", String (TE.decodeUtf8 canonical))
        ]
    )

specIn :: Map Text Json -> IO SpawnSpec
specIn args = do
  route <- routeIn (argMaybe args "reply_route")
  p <- argText args "parent"
  s <- argText args "spawn_id"
  k <- argText args "process_kind"
  o <- argText args "source"
  orThrow (spawnSpec p s k o (arg args "capabilities") (arg args "config") route)

lineageOut :: Maybe Lineage -> Json
lineageOut = maybe Null (\l -> Array [String l.parent, String l.spawnId, String l.child])

claimOut :: SpawnClaim -> Json
claimOut c = Array [String c.parent, String c.spawnId, String c.child, Bool c.priorClaim]

replyOut :: CallReply -> Json
replyOut = \case
  ReplyResult r -> Object [("kind", "result"), ("data", callResultToData r)]
  ReplyError e -> Object [("kind", "error"), ("data", callErrorToData e)]

-- | The driver's @error_out@.
errorOut :: SomeException -> Json
errorOut err = case fromException err of
  Just fabric ->
    Object
      [ ("category", String (categoryText (errorCategory fabric)))
      , ("type", String (pythonExceptionName fabric))
      , ("message", String (errorMessage fabric))
      ]
  Nothing -> Object [("category", "other"), ("type", "SomeException"), ("message", String (T.pack (show err)))]

-- | The driver's fake registries: "memory" claims the spec's own identity
-- (prior after the first claim); "wrong" answers another identity.
fakeRegistry :: Text -> IORef [Text] -> IO SpawnRegistry
fakeRegistry kind events = do
  prior <- newIORef False
  let claimWith spec = do
        modifyIORef' events (<> ["claim"])
        if kind == "wrong"
          then do
            other <- orThrow (childIdentity "other-parent" "other-spawn")
            orThrow (spawnClaim "other-parent" "other-spawn" other False)
          else do
            p <- atomicModifyIORef' prior (True,)
            orThrow (spawnClaim spec.parent spec.spawnId spec.child p)
  pure
    SpawnRegistry
      { claim = claimWith
      , childOf = \_ _ -> pure Nothing
      , childrenOf = \_ -> pure []
      , parentOf = \_ -> pure Nothing
      }

-- | The driver's fake provisioners ("record", "fail-first", "observe",
-- "reference"); "live" is type-enforced: 'ensure' returns @()@.
fakeProvisioner :: Text -> Map Text Json -> IORef [Text] -> IORef [Json] -> IO ProcessProvisioner
fakeProvisioner kind options events seen = do
  reference <-
    if kind == "reference"
      then do
        dsn <- argText options "dsn"
        credential <- argText options "parent_credential"
        key <- workspaceKey options
        pure (Just (Registry.referenceProvisioner (TE.encodeUtf8 dsn) credential (Registry.hmacChildCredential key)))
      else pure Nothing
  if kind == "live"
    then typeEnforced "a ProcessProvisioner's ensure returns (), never a live host or credential"
    else pure ()
  pure . ProcessProvisioner $ \p -> do
    modifyIORef' events (<> ["ensure"])
    visible <-
      if kind == "observe"
        then do
          dsn <- argText options "dsn"
          n <-
            Pg.withConnection (TE.encodeUtf8 dsn) True $ \c ->
              Pg.queryFirst c "SELECT count(*) FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s" [textParam p.parent, textParam p.spawnId]
          pure [("claim_visible", Int (maybe 0 (read . T.unpack . TE.decodeUtf8) (n >>= \case [Just v] -> Just v; _ -> Nothing)))]
        else pure []
    let entry =
          Object
            ( [ ("parent", String p.parent)
              , ("spawn_id", String p.spawnId)
              , ("child", String p.child)
              , ("process_kind", String p.processKind)
              , ("endpoint", endpointToData p.endpoint)
              , ("config", p.config)
              , ("reply_route", maybe Null replyRouteToData p.replyRoute)
              , ("has_credential", Bool False)
              ]
                <> visible
            )
    count' <- atomicModifyIORef' seen (\xs -> (xs <> [entry], length xs + 1))
    if kind == "fail-first" && count' == 1
      then throwIO (userError "lost after claim")
      else maybe (pure ()) (\r -> r.ensure p) reference

workspaceKey :: Map Text Json -> IO BS.ByteString
workspaceKey args = do
  hex <- argText args "workspace_key"
  either (throwIO . InvalidValue . T.pack) pure (Base16.decode (TE.encodeUtf8 hex))

-- | Run an invocation @times@ times, recording each attempt.
attempts :: Map Text Json -> (ActivityInvocation -> IO Json) -> IO [Json]
attempts args run = do
  inv <- invocationIn (argObject args "invocation")
  let times = case arg args "times" of
        Int n -> fromIntegral n
        _ -> 1 :: Int
  forM [1 .. times] $ \_ ->
    try (run inv) >>= \case
      Right value -> pure (Object [("ok", value)])
      Left err -> pure (Object [("error", errorOut err)])

processOps :: Handles -> Ops
processOps handles =
  Map.fromList
    [ ( "call_request"
      , \args -> do
          c <- argText args "call_id"
          o <- argText args "operation"
          callRequestToData <$> orThrow (callRequest c o (arg args "input"))
      )
    , ("call_request_from_data", \args -> callRequestToData <$> orThrow (callRequestFromData (arg args "data")))
    , ( "call_request_detached"
      , \_ -> do
          r <- orThrow (callRequest "call-1" "answer" (Object [("nested", Array [Int 1])]))
          pure (Object [("input", r.input), ("mutable", Bool False)])
      )
    , ("call_result", \args -> argText args "call_id" >>= \c -> callResultToData <$> orThrow (callResult c (arg args "result")))
    , ("call_result_from_data", \args -> callResultToData <$> orThrow (callResultFromData (arg args "data")))
    , ( "call_error"
      , \args -> do
          c <- argText args "call_id"
          code <- argText args "code"
          m <- argText args "message"
          callErrorToData <$> orThrow (callError c code m (arg args "details"))
      )
    , ("call_error_from_data", \args -> callErrorToData <$> orThrow (callErrorFromData (arg args "data")))
    , ( "request_envelope"
      , \args -> do
          request <- orThrow (callRequestFromData (arg args "request"))
          s <- argText args "sender"
          r <- argText args "recipient"
          o <- argText args "source"
          route <-
            routeIn (argMaybe args "reply_route") >>= \case
              Just route -> pure route
              Nothing -> typeEnforced "request_envelope's reply_route is a ReplyRoute, never None"
          orThrow (requestEnvelope request s r o route (deliveryIdArg args)) >>= envelopeOut
      )
    , ( "result_envelope"
      , \args -> do
          request <- orThrow (envelopeFromData (arg args "request"))
          value <- orThrow (callResultFromData (arg args "result"))
          s <- argText args "sender"
          orThrow (resultEnvelope value request s (deliveryIdArg args)) >>= envelopeOut
      )
    , ( "error_envelope"
      , \args -> do
          request <- orThrow (envelopeFromData (arg args "request"))
          value <- orThrow (callErrorFromData (arg args "error"))
          s <- argText args "sender"
          orThrow (errorEnvelope value request s (deliveryIdArg args)) >>= envelopeOut
      )
    , ( "request_from_envelope"
      , \args -> do
          e <- orThrow (envelopeFromData (arg args "envelope"))
          callRequestToData <$> orThrow (requestFromEnvelope e)
      )
    , ( "reply_from_envelope"
      , \args -> do
          e <- orThrow (envelopeFromData (arg args "envelope"))
          request <- orThrow (envelopeFromData (arg args "request"))
          replyOut <$> orThrow (replyFromEnvelope e request)
      )
    , ("child_identity", \args -> twoTexts args "parent" "spawn_id" >>= \(p, s) -> String <$> orThrow (childIdentity p s))
    , ("spawn_idempotency", \args -> twoTexts args "parent" "spawn_id" >>= \(p, s) -> String <$> orThrow (spawnIdempotency p s))
    , ("spawn_spec", \args -> specIn args >>= specOut)
    , ("spawn_spec_from_data", \args -> orThrow (spawnSpecFromData (arg args "data")) >>= specOut)
    , ( "spawn_spec_detached"
      , \args -> do
          s <- specIn (Map.insert "config" (Object [("nested", Array [Int 1])]) (argObject args "spec"))
          pure (Object [("config", s.config), ("mutable", Bool False)])
      )
    , ( "spawn_outcome"
      , \args -> do
          p <- argText args "parent"
          s <- argText args "spawn_id"
          c <- argText args "child"
          ep <- orThrow (endpointFromData (arg args "endpoint"))
          prior <- argBool args "prior_claim"
          spawnOutcomeToData <$> orThrow (spawnOutcome p s c ep prior)
      )
    , ("spawn_outcome_from_data", \args -> spawnOutcomeToData <$> orThrow (spawnOutcomeFromData (arg args "data")))
    , ( "provisioning"
      , \args -> do
          p <- argText args "parent"
          s <- argText args "spawn_id"
          c <- argText args "child"
          k <- argText args "process_kind"
          ep <- orThrow (endpointFromData (arg args "endpoint"))
          route <- routeIn (argMaybe args "reply_route")
          value <- orThrow (provisioning p s c k ep (arg args "config") route)
          pure (Object [("config", value.config), ("child", String value.child)])
      )
    , ( "spawn_claim"
      , \args -> do
          p <- argText args "parent"
          s <- argText args "spawn_id"
          c <- argText args "child"
          prior <- argBool args "prior_claim"
          claimOut <$> orThrow (spawnClaim p s c prior)
      )
    , ( "lineage"
      , \args -> do
          p <- argText args "parent"
          s <- argText args "spawn_id"
          c <- argText args "child"
          lineageOut . Just <$> orThrow (lineage p s c)
      )
    , ( "fake_spawn"
      , \args -> do
          events <- newIORef []
          seen <- newIORef []
          registryKind <- argText args "registry"
          provisionerKind <- argText args "provisioner"
          registry <- fakeRegistry registryKind events
          provisioner <- fakeProvisioner provisionerKind Map.empty events seen
          made <- attempts args (spawnActivity registry provisioner)
          recorded <- readIORef events
          provisionings <- readIORef seen
          pure (Object [("attempts", Array made), ("events", Array (map String recorded)), ("provisionings", Array provisionings)])
      )
    , ( "child_credential"
      , \args -> do
          key <- workspaceKey args
          c <- argText args "child"
          pure (String (Registry.hmacChildCredential key c))
      )
    , ("ensure_lifecycle_schema", \args -> conn args >>= \c -> Null <$ Registry.ensureLifecycleSchema c)
    , ( "registry"
      , \args -> do
          c <- conn args
          p <- argText args "parent"
          k <- argText args "credential"
          Registry.postgresSpawnRegistry c p k >>= store handles
      )
    , ( "claim"
      , \args -> do
          r <- registryArg args
          s <- orThrow (spawnSpecFromData (arg args "spec"))
          claimOut <$> Registry.claim r s
      )
    , ("child_of", \args -> registryArg args >>= \r -> twoTexts args "parent" "spawn_id" >>= \(p, s) -> lineageOut <$> Registry.childOf r p s)
    , ("children_of", \args -> registryArg args >>= \r -> argText args "parent" >>= \p -> Array . map (lineageOut . Just) <$> Registry.childrenOf r p)
    , ("parent_of", \args -> registryArg args >>= \r -> argText args "child" >>= \c -> lineageOut <$> Registry.parentOf r c)
    , ( "spawn"
      , \args -> do
          r <- registryArg args
          events <- newIORef []
          seen <- newIORef []
          kind <- case arg args "provisioner" of
            String k -> pure k
            _ -> pure "record"
          provisioner <- fakeProvisioner kind (argObject args "options") events seen
          made <- attempts args (spawnActivity (Registry.spawnRegistry r) provisioner)
          provisionings <- readIORef seen
          pure (Object [("attempts", Array made), ("provisionings", Array provisionings)])
      )
    ]
  where
    conn args = fetch handles args "conn" :: IO Connection
    registryArg args = fetch handles args "registry" :: IO Registry.PostgresSpawnRegistry
    twoTexts args a b = (,) <$> argText args a <*> argText args b
    deliveryIdArg args = case arg args "delivery_id" of
      String d -> Just d
      _ -> Nothing

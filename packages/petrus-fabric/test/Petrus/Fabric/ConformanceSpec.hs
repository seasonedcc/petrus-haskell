-- | spec/fabric-conformance.md, checks F-001 … F-099 and F-101: each check
-- written once against the conformance protocol and run against both the
-- Haskell port and the pinned Python reference. The engine check F-100 is in
-- "Petrus.Fabric.EngineSpec"; the interop checks (F-038, F-046, F-102 …
-- F-108) are in "Petrus.Fabric.InteropSpec".
module Petrus.Fabric.ConformanceSpec
  ( spec
  , haskell
  , catalog
  , specDdl
  , specObjectNames
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, poll, wait)
import Control.Exception (try)
import Control.Monad (forM_, replicateM, unless, void, when)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Map.Strict ((!))
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Petrus.Fabric.Conformance.Haskell (fabricOps)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Conformance.Setup
import Petrus.Fabric.Error (Category (..))
import Petrus.Json (Json (..), typeExactEq)
import Petrus.Postgres (Notification (..), PostgresError, hasSqlState, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), repoRoot)
import System.FilePath ((</>))
import Test.Hspec

-- | The Haskell port behind the conformance protocol.
haskell :: Launcher
haskell = haskellLauncher (\h -> [fabricOps h])

spec :: Spec
spec = describe "Fabric conformance (spec/fabric-conformance.md)" $ do
  describe "Haskell port" (checks haskell)
  describe "Python reference" (checks pythonLauncher)

checks :: Launcher -> Spec
checks l = do
  unitGroup l unitChecks
  dbGroup l dbChecks

-- ---------------------------------------------------------------------------
-- Helpers

shouldBeJson :: Json -> Json -> Expectation
shouldBeJson actual expected =
  unless (typeExactEq actual expected) $
    expectationFailure ("expected " <> showJson expected <> "\n but got " <> showJson actual)

-- | A refusal the Haskell API's types make inexpressible: the reference
-- refuses it as invalid; the Haskell twin either refuses it the same way or
-- reports the operation unsupported (a typed spec covers it at compile time,
-- "Petrus.Fabric.TypedSpec").
typedRefusal :: Impl -> Text -> [(Text, Json)] -> Text -> Expectation
typedRefusal i op args fragment
  | i.isHaskell =
      answerOf i op args >>= \case
        Unsupported -> pure ()
        Err Invalid _ _ -> pure ()
        other -> expectationFailure ("expected a typed refusal, got " <> show other)
  | otherwise = refusedWith Invalid fragment i op args

envelopeOk :: Impl -> [(Text, Json)] -> IO Json
envelopeOk i overrides = ok i "envelope" (envelopeArgs overrides)

canonicalOf :: Impl -> Json -> IO (Text, Text)
canonicalOf i value = do
  answer <- ok i "canonical" [("value", value)]
  pure (memberText "text" answer, memberText "sha256" answer)

utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

isDigest :: Text -> Bool
isDigest t = T.length t == 64 && T.all (`elem` ("0123456789abcdef" :: String)) t

routeData :: Json
routeData = obj [("instance_id", "sender-a"), ("source", "replies/finish")]

-- | A delivery's row, as text, for "unchanged" comparisons.
deliveryRow :: Env -> Text -> Text -> IO [[Maybe Text]]
deliveryRow env sender deliveryId =
  rowsOf
    env.admin
    "SELECT row_to_json(d)::text FROM impetus_fabric.deliveries d WHERE sender = %s AND delivery_id = %s"
    [textParam sender, textParam deliveryId]

deliveries :: Env -> IO Int
deliveries env = count env.admin "SELECT count(*) FROM impetus_fabric.deliveries" []

submitBy :: Ctx -> Party -> [(Text, Json)] -> IO Answer
submitBy ctx p overrides = answerOf ctx.impl "submit" [("client", p.client), ("envelope", obj (envelopeArgs overrides))]

submitOk :: Ctx -> Party -> [(Text, Json)] -> IO Json
submitOk ctx p overrides = ok ctx.impl "submit" [("client", p.client), ("envelope", obj (envelopeArgs overrides))]

expectErr :: [Category] -> Answer -> Expectation
expectErr categories = \case
  Err c _ _ | c `elem` categories -> pure ()
  other -> expectationFailure ("expected a refusal in " <> show (map show categories) <> ", got " <> show other)

withRoute :: Ctx -> (Env -> PartyMap -> IO a) -> IO a
withRoute ctx k = withEnv ctx $ \env -> do
  ps <- parties ctx env
  openRoute ctx ps
  k env ps

withParties :: Ctx -> (Env -> PartyMap -> IO a) -> IO a
withParties ctx k = withEnv ctx $ \env -> parties ctx env >>= k env

-- | A client for a registered party on another connection.
clientOn :: Ctx -> Json -> Party -> IO Json
clientOn ctx handle p = ok ctx.impl "client" [("conn", handle), ("instance", String p.name), ("credential", String p.credential)]

pendingOf :: Ctx -> Party -> Int -> IO [Json]
pendingOf ctx p limit =
  ok ctx.impl "pending" [("client", p.client), ("limit", Int (fromIntegral limit))] >>= \case
    Array items -> pure items
    other -> expectationFailure ("pending answered " <> showJson other) >> pure []

acknowledgeOk :: Ctx -> Party -> Text -> Text -> Integer -> IO Json
acknowledgeOk ctx p sender deliveryId occurrence =
  ok ctx.impl "acknowledge" [("client", p.client), ("sender", String sender), ("delivery_id", String deliveryId), ("occurrence", Int occurrence)]

acknowledgeAnswer :: Ctx -> Party -> Text -> Text -> Json -> IO Answer
acknowledgeAnswer ctx p sender deliveryId occurrence =
  answerOf ctx.impl "acknowledge" [("client", p.client), ("sender", String sender), ("delivery_id", String deliveryId), ("occurrence", occurrence)]

receiptOf :: Ctx -> Party -> Text -> IO Json
receiptOf ctx p deliveryId = ok ctx.impl "receipt" [("client", p.client), ("delivery_id", String deliveryId)]

pruneOk :: Ctx -> Env -> Party -> IO Json
pruneOk ctx env p = do
  now <- dbNow env.admin
  ok ctx.impl "prune" [("client", p.client), ("before", isoPlus 1 now)]

identities :: [Json] -> [Text]
identities = map (memberText "ingress_identity")

-- | Wait briefly for one notification on the admin connection.
nextNotification :: Env -> Double -> IO (Maybe Notification)
nextNotification env = Pg.waitForNotification env.admin

-- ---------------------------------------------------------------------------
-- Catalog introspection (F-031, F-032, F-038)

-- | Columns, constraints and indexes of impetus_fabric, in a stable order.
catalog :: Pg.Connection -> IO [[Maybe Text]]
catalog c =
  concat
    <$> sequence
      [ rowsOf
          c
          "SELECT 'column', table_name::text, ordinal_position::text, column_name::text, data_type::text, \
          \is_nullable::text, coalesce(column_default, ''), coalesce(collation_name::text, '') \
          \FROM information_schema.columns WHERE table_schema = 'impetus_fabric' ORDER BY table_name, ordinal_position"
          []
      , rowsOf
          c
          "SELECT 'constraint', conrelid::regclass::text, conname::text, pg_get_constraintdef(oid) \
          \FROM pg_constraint WHERE connamespace = 'impetus_fabric'::regnamespace ORDER BY 2, 3"
          []
      , rowsOf
          c
          "SELECT 'index', tablename::text, indexname::text, indexdef \
          \FROM pg_indexes WHERE schemaname = 'impetus_fabric' ORDER BY 2, 3"
          []
      ]

-- | The statements of spec/fabric.md §6.1's SQL block.
specDdl :: IO [Text]
specDdl = do
  root <- repoRoot
  text <- TIO.readFile (root </> "spec" </> "fabric.md")
  let afterHeading = drop 1 (dropWhile (not . T.isPrefixOf "### 6.1") (T.lines text))
      block = takeWhile (/= "```") (drop 1 (dropWhile (/= "```sql") afterHeading))
  pure (filter (not . T.null) (map T.strip (T.splitOn ";" (T.unlines block))))

-- | The constraint and index names of spec/fabric.md §6.1's object table.
specObjectNames :: IO (Set.Set Text)
specObjectNames = do
  root <- repoRoot
  text <- TIO.readFile (root </> "spec" </> "fabric.md")
  let rows = takeWhile (T.isPrefixOf "|") (drop 2 (dropWhile (not . T.isPrefixOf "| Table |") (T.lines text)))
      name row = case T.splitOn "|" row of
        (_ : _ : cell : _) -> T.dropAround (\ch -> ch == '`' || ch == ' ') cell
        _ -> ""
  pure (Set.fromList (filter (not . T.null) (map name rows)))

-- ---------------------------------------------------------------------------
-- A, B, C: values

unitChecks :: SpecWith Impl
unitChecks = do
  describe "A Text and JSON values" $ do
    it "F-001 a non-string text field is invalid" $ \i ->
      void (refused Invalid i "envelope" (envelopeArgs [("source", Int 3)]))
    it "F-002 an empty text field is invalid" $ \i ->
      forM_ ["delivery_id", "sender", "recipient", "source", "correlation"] $ \field ->
        refused Invalid i "envelope" (envelopeArgs [(field, "")])
    it "F-003 the text limit is 1024 UTF-8 bytes" $ \i -> do
      e <- envelopeOk i [("source", String (T.replicate 512 "é"))]
      memberText "source" (member "data" e) `shouldBe` T.replicate 512 "é"
      void (refused Invalid i "envelope" (envelopeArgs [("source", String (T.replicate 513 "é"))]))
      void (refused Invalid i "reply_route_from_data" [("data", obj [("instance_id", String (T.replicate 1025 "a")), ("source", "s")])])
    it "F-005 a lone surrogate is refused" $ \i ->
      typedRefusal i "envelope_lone_surrogate" [("envelope", obj (envelopeArgs []))] ""
    it "F-006 NaN and infinities anywhere in a payload are invalid" $ \i ->
      forM_ [0 / 0, 1 / 0, -1 / 0 :: Double] $ \bad -> do
        refusedWith Invalid "strict JSON" i "envelope" (envelopeArgs [("payload", obj [("bad", Float bad)])])
        refusedWith Invalid "strict JSON" i "envelope" (envelopeArgs [("payload", obj [("a", arr [obj [("b", Float bad)]])])])
    it "F-007 a non-JSON host value is refused with its path" $ \i ->
      typedRefusal i "envelope_host_value" [("envelope", obj (envelopeArgs [])), ("kind", "object")] "payload.items[0]"
    it "F-008 a non-string payload key is refused" $ \i ->
      typedRefusal i "envelope_host_value" [("envelope", obj (envelopeArgs [])), ("kind", "key")] ""
    it "F-009 {\"n\":2} and {\"n\":2.0} differ in canonical bytes and digest" $ \i -> do
      (intText, _) <- canonicalOf i (obj [("n", Int 2)])
      (floatText, _) <- canonicalOf i (obj [("n", Float 2)])
      intText `shouldBe` "{\"n\":2}"
      floatText `shouldBe` "{\"n\":2.0}"
      a <- envelopeOk i [("payload", obj [("n", Int 2)])]
      b <- envelopeOk i [("payload", obj [("n", Float 2)])]
      memberText "digest" a `shouldNotBe` memberText "digest" b
    it "F-010 a big integer is preserved exactly" $ \i -> do
      let big = 123456789012345678901234567890
      (text, _) <- canonicalOf i (obj [("n", Int big)])
      text `shouldBe` "{\"n\":123456789012345678901234567890}"
      e <- envelopeOk i [("payload", obj [("n", Int big)])]
      member "payload" (member "data" e) `shouldBeJson` obj [("n", Int big)]
    it "F-011 constructed values are detached and immutable" $ \i -> do
      answer <- ok i "envelope_detached" [("envelope", obj (envelopeArgs []))]
      member "payload" answer `shouldBeJson` obj [("nested", arr [Int 1, obj [("ok", Bool True)]])]
      member "mutable" answer `shouldBeJson` Bool False

  describe "B Canonical encoding vectors" $ do
    it "F-012 the mixed vector encodes and digests exactly" $ \i -> do
      let value =
            obj
              [ ("b", Int 1)
              , ("a", arr [Float 1, Int 2, Float 1e16, Float 1.5e-7, Float 0.0001, Float 1e-5, Float (-0.0), Int 123456789012345678901234567890, Bool True, Null])
              , ("ctl", str "\x01\x1f\x7f\x2028\"\\\n\t\b\f\r")
              , ("é", str "é")
              ]
      (text, sha) <- canonicalOf i value
      text `shouldBe` "{\"a\":[1.0,2,1e+16,1.5e-07,0.0001,1e-05,-0.0,123456789012345678901234567890,true,null],\"b\":1,\"ctl\":\"\\u0001\\u001f\x7f\x2028\\\"\\\\\\n\\t\\b\\f\\r\",\"é\":\"é\"}"
      sha `shouldBe` "6fd2734297a8c0790611a64078bb8804ede158440a9e80b130d7df17dd8f88ba"
    it "F-013 keys sort by code point" $ \i -> do
      (text, sha) <- canonicalOf i (obj [("\x1F600", Int 1), ("\xE000", Int 2), ("B", Int 3), ("a", Int 4)])
      text `shouldBe` "{\"B\":3,\"a\":4,\"\xE000\":2,\"\x1F600\":1}"
      sha `shouldBe` "d04cf6929a6673b7534a1bb2cb6b9a46bd31cab8a11b4a9ccfd7b6227ad2dcd3"
    it "F-014 floats are spelled as Python's repr" $ \i ->
      forM_
        [ (0.0, "0.0")
        , (-0.0, "-0.0")
        , (2.0, "2.0")
        , (100.0, "100.0")
        , (0.5, "0.5")
        , (0.001, "0.001")
        , (0.0001, "0.0001")
        , (1e-5, "1e-05")
        , (1.25e-5, "1.25e-05")
        , (12345.678, "12345.678")
        , (9999999999999998.0, "9999999999999998.0")
        , (1e16, "1e+16")
        , (1.2345678901234568e17, "1.2345678901234568e+17")
        , (1e22, "1e+22")
        , (1.5e300, "1.5e+300")
        , (5e-324, "5e-324")
        ]
        $ \(value, spelling) -> do
          (text, _) <- canonicalOf i (obj [("f", Float value)])
          text `shouldBe` ("{\"f\":" <> spelling <> "}")
    it "F-015 strings escape exactly the short forms and other C0 controls" $ \i -> do
      (text, _) <- canonicalOf i (obj [("s", str "\b\f\n\r\t\"\\\x00\x01\x1f/\x7f\x2028\x2029\x1F600é")])
      text `shouldBe` "{\"s\":\"\\b\\f\\n\\r\\t\\\"\\\\\\u0000\\u0001\\u001f/\x7f\x2028\x2029\x1F600é\"}"

  describe "C Envelope, ReplyRoute, and Endpoint" $ do
    it "F-016 ReplyRoute decoding is exact" $ \i -> do
      answer <- ok i "reply_route_from_data" [("data", routeData)]
      answer `shouldBeJson` arr ["sender-a", "replies/finish"]
      forM_
        [ obj [("instance_id", "sender-a")]
        , obj [("instance_id", "sender-a"), ("source", "replies/finish"), ("extra", Bool True)]
        , obj [("instance_id", Int 1), ("source", "replies/finish")]
        , arr ["sender-a", "replies/finish"]
        , Null
        ]
        $ \bad -> refused Invalid i "reply_route_from_data" [("data", bad)]
    it "F-017 envelope JSON has exactly eight members, version integer 1, explicit null route" $ \i -> do
      e <- envelopeOk i []
      let members = case member "data" e of
            Object ms -> ms
            _ -> []
      sort (map fst members) `shouldBe` sort ["version", "delivery_id", "sender", "recipient", "source", "correlation", "payload", "reply_route"]
      member "version" (member "data" e) `shouldBeJson` Int 1
      member "reply_route" (member "data" e) `shouldBeJson` routeData
      bare <- envelopeOk i [("reply_route", Null)]
      member "reply_route" (member "data" bare) `shouldBeJson` Null
    it "F-018 decode . encode is the identity" $ \i ->
      forM_ [[], [("reply_route", Null)], [("payload", obj [("f", Float 2), ("n", Int 123456789012345678901234567890)])]] $ \overrides -> do
        e <- envelopeOk i overrides
        back <- ok i "envelope_from_data" [("data", member "data" e)]
        member "data" back `shouldBeJson` member "data" e
        memberText "digest" back `shouldBe` memberText "digest" e
    it "F-019 version 2 is refused" $ \i -> do
      e <- envelopeOk i []
      void (refused Invalid i "envelope_from_data" [("data", setMember "version" (Int 2) (member "data" e))])
    it "F-020 version 1.0 and true are refused" $ \i -> do
      e <- envelopeOk i []
      forM_ [Float 1, Bool True] $ \v -> refused Invalid i "envelope_from_data" [("data", setMember "version" v (member "data" e))]
    it "F-021 a missing member is refused by name" $ \i -> do
      e <- envelopeOk i []
      refusedWith Invalid "source" i "envelope_from_data" [("data", dropMember "source" (member "data" e))]
    it "F-022 an extra member or a non-string key is refused as unknown" $ \i -> do
      e <- envelopeOk i []
      refusedWith Invalid "extra" i "envelope_from_data" [("data", setMember "extra" (Bool True) (member "data" e))]
      typedRefusal i "envelope_from_data_int_key" [("data", member "data" e)] "unknown"
    it "F-023 a non-object payload is refused" $ \i -> do
      e <- envelopeOk i []
      void (refused Invalid i "envelope_from_data" [("data", setMember "payload" (arr []) (member "data" e))])
      void (refused Invalid i "envelope" (envelopeArgs [("payload", arr [])]))
    it "F-024 the payload limit is 65536 canonical bytes of the payload alone" $ \i -> do
      e <- envelopeOk i [("payload", obj [("x", String (T.replicate 65528 "a"))])]
      utf8Length (memberText "canonical" e) `shouldSatisfy` (> 65536)
      refusedWith Invalid "artifact protocol" i "envelope" (envelopeArgs [("payload", obj [("x", String (T.replicate 65529 "a"))])])
    it "F-025 escapes count by their encoded length" $ \i -> do
      (text, _) <- canonicalOf i (obj [("x", str "\x01")])
      utf8Length text `shouldBe` 14
      let escaped n = obj [("x", String (T.replicate 10921 "\x01" <> T.replicate n "a"))]
      void (envelopeOk i [("payload", escaped 2)])
      void (refused Invalid i "envelope" (envelopeArgs [("payload", escaped 3)]))
    it "F-026 the digest vectors" $ \i -> do
      let base = [("delivery_id", "d-1")]
      routed <- envelopeOk i base
      memberText "digest" routed `shouldBe` "8865b183f1d8b38dbdcd816dcb63368db0323936b2f95ae9a39ba6a1eee3c605"
      bare <- envelopeOk i (base <> [("reply_route", Null)])
      memberText "canonical" bare
        `shouldBe` "{\"correlation\":\"conversation-1\",\"delivery_id\":\"d-1\",\"payload\":{\"command\":\"go\"},\"recipient\":\"recipient\",\"reply_route\":null,\"sender\":\"sender-a\",\"source\":\"commands/start\",\"version\":1}"
      memberText "digest" bare `shouldBe` "4d806f6288ac30a5e88d54e121ccef1f6797a742a0d49cec401ce7578185e6ba"
    it "F-027 a digest is 64 lowercase hex characters" $ \i -> do
      e <- envelopeOk i []
      memberText "digest" e `shouldSatisfy` isDigest
    it "F-028 ingress identity of sender-a / delivery-1" $ \i -> do
      e <- envelopeOk i []
      memberText "ingress_identity" e `shouldBe` "fabric:8:sender-a:delivery-1"
    it "F-029 the identity's length counts code points" $ \i -> do
      e <- envelopeOk i [("sender", "é\x1F600:z"), ("delivery_id", "x:y")]
      memberText "ingress_identity" e `shouldBe` "fabric:4:é\x1F600:z:x:y"
    it "F-030 Endpoint JSON is exact and capabilities is an object" $ \i -> do
      let caps = obj [("model", "large")]
          full = obj [("recipient", "recipient"), ("source", "commands/start"), ("capabilities", caps)]
      made <- ok i "endpoint" [("recipient", "recipient"), ("source", "commands/start"), ("capabilities", caps)]
      made `shouldBeJson` full
      decoded <- ok i "endpoint_from_data" [("data", full)]
      decoded `shouldBeJson` full
      forM_ [setMember "extra" (Bool True) full, dropMember "capabilities" full, setMember "capabilities" (arr []) full, arr []] $ \bad ->
        refused Invalid i "endpoint_from_data" [("data", bad)]
      void (refused Invalid i "endpoint" [("recipient", "recipient"), ("source", "commands/start"), ("capabilities", arr [])])

  describe "E Credentials" $
    it "F-039 credentials need 32 UTF-8 bytes and 16 distinct code points" $ \i -> do
      forM_ [T.replicate 40 "x", T.replicate 20 "ab", T.pack (take 31 (['a' .. 'z'] <> ['A' .. 'Z']))] $ \weak ->
        refused Invalid i "credential_ok" [("credential", String weak)]
      issued <- replicateM 5 (ok i "issue_credential" [])
      forM_ issued $ \c -> ok i "credential_ok" [("credential", c)] >>= (`shouldBeJson` Bool True)
      length (Set.fromList (map showJson issued)) `shouldBe` 5

setMember :: Text -> Json -> Json -> Json
setMember key value = \case
  Object ms -> Object ([(k, v) | (k, v) <- ms, k /= key] <> [(key, value)])
  other -> other

dropMember :: Text -> Json -> Json
dropMember key = \case
  Object ms -> Object [(k, v) | (k, v) <- ms, k /= key]
  other -> other

-- ---------------------------------------------------------------------------
-- D … M: against PostgreSQL

dbChecks :: SpecWith Ctx
dbChecks = do
  describe "A Text and JSON values" $
    it "F-004 U+0000 never reaches storage" $ \ctx -> withRoute ctx $ \env ps -> do
      forM_
        [ [("payload", obj [("x", str "a\x00\&b")])]
        , [("correlation", str "conversation\x00")]
        , [("source", str "commands/\x00start")]
        , [("payload", obj [("key\x00", Int 1)])]
        ]
        $ \overrides -> submitBy ctx (ps ! "sender-a") overrides >>= expectErr [Invalid, Storage]
      deliveries env `shouldReturn` 0

  describe "D Storage schema" $ do
    it "F-031 the provisioned catalog is spec §6.1's, names included" $ \ctx -> withEnv ctx $ \env -> do
      provisioned <- catalog env.admin
      statements <- specDdl
      length statements `shouldBe` 9
      fromSpec <- withFreshDatabase ctx $ \_ fresh -> do
        forM_ statements $ \statement -> exec fresh (Pg.sql statement) []
        catalog fresh
      provisioned `shouldBe` fromSpec
      expected <- specObjectNames
      let names = Set.fromList [n | (Just kind : _ : Just n : _) <- provisioned, kind `elem` ["constraint", "index"]]
      names `shouldBe` expected
      let defaults = [d | (Just "column" : _ : _ : Just column : _ : _ : Just d : _) <- provisioned, "_at" `T.isSuffixOf` column, column /= "accepted_at"]
      defaults `shouldSatisfy` all (== "clock_timestamp()")
      length defaults `shouldBe` 5
    it "F-032 provisioning twice changes nothing" $ \ctx -> withEnv ctx $ \env -> do
      earlier <- catalog env.admin
      _ <- ok ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
      _ <- ok ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
      catalog env.admin `shouldReturn` earlier
      rowsOf env.admin "SELECT component, version::text FROM impetus_fabric.schema_metadata" [] `shouldReturn` [[Just "fabric", Just "1"]]
    it "F-033 provisioning joins and never commits the caller's transaction" $ \ctx -> withBare ctx $ \env -> do
      joined <- connectImpl ctx False
      _ <- ok ctx.impl "ensure_fabric_schema" [("conn", joined)]
      namespaces env `shouldReturn` 0
      _ <- ok ctx.impl "rollback" [("conn", joined)]
      namespaces env `shouldReturn` 0
      void (ok ctx.impl "close" [("conn", joined)])
    it "F-034 an unversioned known table is refused" $ \ctx -> withBare ctx $ \env -> do
      exec env.admin "CREATE SCHEMA impetus_fabric" []
      exec env.admin "CREATE TABLE impetus_fabric.processes (unknown_shape text)" []
      refusedWith SchemaRefusedCategory "refusing" ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
      count env.admin "SELECT count(*) FROM pg_tables WHERE schemaname = 'impetus_fabric'" [] `shouldReturn` 1
    it "F-035 a mismatched version is refused and reported" $ \ctx -> withEnv ctx $ \env -> do
      exec env.admin "UPDATE impetus_fabric.schema_metadata SET version = 999 WHERE component = 'fabric'" []
      refusedWith SchemaRefusedCategory "999" ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
      refusedWith SchemaRefusedCategory "migrate deliberately" ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
    it "F-036 unrelated tables do not block provisioning" $ \ctx -> withBare ctx $ \env -> do
      exec env.admin "CREATE SCHEMA impetus_fabric" []
      exec env.admin "CREATE TABLE impetus_fabric.unrelated (x integer)" []
      _ <- ok ctx.impl "ensure_fabric_schema" [("conn", env.conn)]
      count env.admin "SELECT count(*) FROM pg_tables WHERE schemaname = 'impetus_fabric'" [] `shouldReturn` 7
    it "F-037 schema_metadata is exactly ('fabric', 1)" $ \ctx -> withEnv ctx $ \env ->
      rowsOf env.admin "SELECT component, version::text FROM impetus_fabric.schema_metadata" [] `shouldReturn` [[Just "fabric", Just "1"]]

  describe "E Credentials and registration" $ do
    it "F-040 a weak credential is refused without database access" $ \ctx -> do
      closed <- connectImpl ctx True
      _ <- ok ctx.impl "close" [("conn", closed)]
      void (refused Invalid ctx.impl "client" [("conn", closed), ("instance", "p"), ("credential", String (T.replicate 40 "x"))])
    it "F-041 registration stores the SHA-256 hex only" $ \ctx -> withEnv ctx $ \env -> do
      let credential = "caller-credential-0123456789-abcdefghijklmnop"
      _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", "process"), ("credential", credential)]
      [[Just stored]] <- rowsOf env.admin "SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = 'process'" []
      stored `shouldBe` "f87d0d9624b9288fbcea1554e00abffbd965251aef9d310ca9e63e025cca36a5"
      T.isInfixOf "caller-credential" stored `shouldBe` False
      issued <- ok ctx.impl "issue_credential" []
      _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", "other"), ("credential", issued)]
      [[Just other]] <- rowsOf env.admin "SELECT credential_digest FROM impetus_fabric.processes WHERE instance_id = 'other'" []
      other `shouldSatisfy` isDigest
      T.isInfixOf (memberTextOf issued) other `shouldBe` False
      void (refused Invalid ctx.impl "register" [("conn", env.conn), ("instance", "weak"), ("credential", String (T.replicate 40 "x"))])
    it "F-042 re-registering with the same credential succeeds" $ \ctx -> withEnv ctx $ \env -> do
      issued <- ok ctx.impl "issue_credential" []
      forM_ [1 :: Int, 2] $ \_ -> ok ctx.impl "register" [("conn", env.conn), ("instance", "process"), ("credential", issued)]
      count env.admin "SELECT count(*) FROM impetus_fabric.processes" [] `shouldReturn` 1
    it "F-043 re-registering with another credential conflicts and keeps the digest" $ \ctx -> withEnv ctx $ \env -> do
      issued <- ok ctx.impl "issue_credential" []
      _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", "process"), ("credential", issued)]
      earlier <- rowsOf env.admin "SELECT credential_digest FROM impetus_fabric.processes" []
      other <- ok ctx.impl "issue_credential" []
      refusedWith ConflictCategory "different credential" ctx.impl "register" [("conn", env.conn), ("instance", "process"), ("credential", other)]
      rowsOf env.admin "SELECT credential_digest FROM impetus_fabric.processes" [] `shouldReturn` earlier
    it "F-044 a wrong credential is denied and has no effect" $ \ctx -> withEnv ctx $ \env -> do
      issued <- ok ctx.impl "issue_credential" []
      _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", "process"), ("credential", issued)]
      wrong <- ok ctx.impl "issue_credential" []
      client <- ok ctx.impl "client" [("conn", env.conn), ("instance", "process"), ("credential", wrong)]
      refusedWith DeniedCategory "authentication failed" ctx.impl "discover" [("client", client), ("service", "anything")]
      void (refused DeniedCategory ctx.impl "expose" [("client", client), ("source", "inbox")])
      void (refused DeniedCategory ctx.impl "authenticate" [("client", client)])
      count env.admin "SELECT count(*) FROM impetus_fabric.exposed_sources" [] `shouldReturn` 0
    it "F-045 an unregistered instance is denied" $ \ctx -> withEnv ctx $ \env -> do
      issued <- ok ctx.impl "issue_credential" []
      client <- ok ctx.impl "client" [("conn", env.conn), ("instance", "ghost"), ("credential", issued)]
      void (refused DeniedCategory ctx.impl "authenticate" [("client", client)])
      void (refused DeniedCategory ctx.impl "pending" [("client", client), ("limit", Int 10)])

  describe "F Exposure, offers, grants, and discovery" $ do
    it "F-047 expose_source is idempotent" $ \ctx -> withParties ctx $ \env ps -> do
      forM_ [1 :: Int, 2] $ \_ -> ok ctx.impl "expose" [("client", (ps ! "recipient").client), ("source", "inbox")]
      count env.admin "SELECT count(*) FROM impetus_fabric.exposed_sources" [] `shouldReturn` 1
    it "F-048 offering on an unexposed source fails as storage" $ \ctx -> withParties ctx $ \env ps -> do
      void (refused Storage ctx.impl "offer" [("client", (ps ! "recipient").client), ("source", "inbox"), ("service", "worker"), ("capabilities", obj [])])
      count env.admin "SELECT count(*) FROM impetus_fabric.service_offers" [] `shouldReturn` 0
    it "F-049 re-offering replaces the capabilities" $ \ctx -> withParties ctx $ \env ps -> do
      let r = (ps ! "recipient").client
      _ <- ok ctx.impl "expose" [("client", r), ("source", "inbox")]
      _ <- ok ctx.impl "offer" [("client", r), ("source", "inbox"), ("service", "worker"), ("capabilities", obj [("v", Int 1)])]
      _ <- ok ctx.impl "offer" [("client", r), ("source", "inbox"), ("service", "worker"), ("capabilities", obj [("v", Int 2)])]
      rowsOf env.admin "SELECT capabilities::text FROM impetus_fabric.service_offers" [] `shouldReturn` [[Just "{\"v\": 2}"]]
    it "F-050 granting to an unregistered sender fails as storage" $ \ctx -> withParties ctx $ \env ps -> do
      let r = (ps ! "recipient").client
      _ <- ok ctx.impl "expose" [("client", r), ("source", "inbox")]
      void (refused Storage ctx.impl "grant" [("client", r), ("sender", "ghost"), ("source", "inbox")])
      count env.admin "SELECT count(*) FROM impetus_fabric.delivery_grants" [] `shouldReturn` 0
    it "F-051 granting on an unexposed source fails as storage" $ \ctx -> withParties ctx $ \env ps -> do
      void (refused Storage ctx.impl "grant" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("source", "inbox")])
      count env.admin "SELECT count(*) FROM impetus_fabric.delivery_grants" [] `shouldReturn` 0
    it "F-052 grant is idempotent and revoking an absent grant is a no-op" $ \ctx -> withParties ctx $ \env ps -> do
      let r = (ps ! "recipient").client
      _ <- ok ctx.impl "expose" [("client", r), ("source", "inbox")]
      forM_ [1 :: Int, 2] $ \_ -> ok ctx.impl "grant" [("client", r), ("sender", "sender-a"), ("source", "inbox")]
      count env.admin "SELECT count(*) FROM impetus_fabric.delivery_grants" [] `shouldReturn` 1
      _ <- ok ctx.impl "revoke" [("client", r), ("sender", "sender-b"), ("source", "inbox")]
      _ <- ok ctx.impl "revoke" [("client", r), ("sender", "sender-a"), ("source", "inbox")]
      _ <- ok ctx.impl "revoke" [("client", r), ("sender", "sender-a"), ("source", "inbox")]
      count env.admin "SELECT count(*) FROM impetus_fabric.delivery_grants" [] `shouldReturn` 0
    describe "discovery (test_fabric::test_discovery_and_send_are_deny_by_default_and_capability_filtered)" $ do
      let offered ctx ps = do
            let r = (ps ! "recipient").client
            _ <- ok ctx.impl "expose" [("client", r), ("source", "commands/start")]
            void (ok ctx.impl "offer" [("client", r), ("source", "commands/start"), ("service", "worker"), ("capabilities", obj [("model", "large"), ("region", "eu")])])
          discover ctx p filterArg = ok ctx.impl "discover" ([("client", p.client), ("service", "worker")] <> maybe [] (\f -> [("capabilities", f)]) filterArg)
      it "F-053 discovery is deny-by-default" $ \ctx -> withParties ctx $ \_ ps -> do
        offered ctx ps
        discover ctx (ps ! "sender-a") Nothing >>= (`shouldBeJson` arr [])
      it "F-054 a granted, matching offer is discovered exactly" $ \ctx -> withParties ctx $ \_ ps -> do
        offered ctx ps
        _ <- ok ctx.impl "grant" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("source", "commands/start")]
        found <- discover ctx (ps ! "sender-a") (Just (obj [("model", "large")]))
        found `shouldBeJson` arr [obj [("recipient", "recipient"), ("source", "commands/start"), ("capabilities", obj [("model", "large"), ("region", "eu")])]]
      it "F-055 a non-matching filter discovers nothing" $ \ctx -> withParties ctx $ \_ ps -> do
        offered ctx ps
        _ <- ok ctx.impl "grant" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("source", "commands/start")]
        discover ctx (ps ! "sender-a") (Just (obj [("model", "small")]))  >>= (`shouldBeJson` arr [])
    it "F-056 capability matching is jsonb containment" $ \ctx -> withParties ctx $ \_ ps -> do
      let r = (ps ! "recipient").client
          offers = [("s1", obj [("tools", arr ["shell", "git"])]), ("s2", obj [("n", Float 1)]), ("s3", obj [("tools", arr ["shell"])])]
      forM_ offers $ \(source, caps) -> do
        _ <- ok ctx.impl "expose" [("client", r), ("source", source)]
        _ <- ok ctx.impl "offer" [("client", r), ("source", source), ("service", "worker"), ("capabilities", caps)]
        ok ctx.impl "grant" [("client", r), ("sender", "sender-a"), ("source", source)]
      let sources filterArg = do
            found <- ok ctx.impl "discover" ([("client", (ps ! "sender-a").client), ("service", "worker")] <> maybe [] (\f -> [("capabilities", f)]) filterArg)
            pure (case found of Array items -> map (memberText "source") items; _ -> [])
      sources (Just (obj [("tools", arr ["git"])])) `shouldReturn` ["s1"]
      sources (Just (obj [("n", Int 1)])) `shouldReturn` ["s2"]
      sources (Just (obj [("tools", "shell")])) `shouldReturn` []
      sources (Just (obj [])) `shouldReturn` ["s1", "s2", "s3"]
      sources Nothing `shouldReturn` ["s1", "s2", "s3"]
    it "F-057 discovery is scoped to the calling sender's grants" $ \ctx -> withParties ctx $ \_ ps -> do
      let r = (ps ! "recipient").client
      forM_ [("s1", "sender-a"), ("s2", "sender-b")] $ \(source, sender) -> do
        _ <- ok ctx.impl "expose" [("client", r), ("source", source)]
        _ <- ok ctx.impl "offer" [("client", r), ("source", source), ("service", "worker"), ("capabilities", obj [])]
        ok ctx.impl "grant" [("client", r), ("sender", sender), ("source", source)]
      found <- ok ctx.impl "discover" [("client", (ps ! "sender-a").client), ("service", "worker")]
      found `shouldBeJson` arr [obj [("recipient", "recipient"), ("source", "s1"), ("capabilities", obj [])]]
    it "F-058 discovery is ordered by (instance_id, source)" $ \ctx -> withParties ctx $ \_ ps -> do
      forM_ [("sender-b", "z"), ("recipient", "b"), ("sender-b", "a"), ("recipient", "a")] $ \(owner, source) -> do
        let c = (ps ! owner).client
        _ <- ok ctx.impl "expose" [("client", c), ("source", source)]
        _ <- ok ctx.impl "offer" [("client", c), ("source", source), ("service", "worker"), ("capabilities", obj [])]
        ok ctx.impl "grant" [("client", c), ("sender", "sender-a"), ("source", source)]
      found <- ok ctx.impl "discover" [("client", (ps ! "sender-a").client), ("service", "worker")]
      let pairs = case found of
            Array items -> [(memberText "recipient" e, memberText "source" e) | e <- items]
            _ -> []
      pairs `shouldBe` [("recipient", "a"), ("recipient", "b"), ("sender-b", "a"), ("sender-b", "z")]

  describe "G Submit" $ do
    it "F-059 another sender's envelope is denied earlier database access" $ \ctx -> withParties ctx $ \_ ps -> do
      closed <- connectImpl ctx True
      client <- clientOn ctx closed (ps ! "sender-a")
      _ <- ok ctx.impl "close" [("conn", closed)]
      refusedWith DeniedCategory "sender" ctx.impl "submit" [("client", client), ("envelope", obj (envelopeArgs [("sender", "sender-b")]))]
    it "F-060 an exposed but ungranted source is denied" $ \ctx -> withParties ctx $ \env ps -> do
      _ <- ok ctx.impl "expose" [("client", (ps ! "recipient").client), ("source", "commands/start")]
      refusedWith DeniedCategory "not exposed and granted" ctx.impl "submit" [("client", (ps ! "sender-a").client), ("envelope", obj (envelopeArgs []))]
      deliveries env `shouldReturn` 0
    it "F-061 an unregistered recipient is denied" $ \ctx -> withRoute ctx $ \env ps -> do
      submitBy ctx (ps ! "sender-a") [("recipient", "ghost")] >>= expectErr [DeniedCategory]
      deliveries env `shouldReturn` 0
    it "F-062 a fresh submit and its row" $ \ctx -> withRoute ctx $ \env ps -> do
      e <- envelopeOk ctx.impl []
      submission <- submitOk ctx (ps ! "sender-a") []
      submission
        `shouldBeJson` obj
          [ ("sender", "sender-a")
          , ("delivery_id", "delivery-1")
          , ("state", "pending")
          , ("duplicate", Bool False)
          , ("occurrence", Null)
          , ("accepted_at", Null)
          ]
      rowsOf
        env.admin
        "SELECT recipient, source, correlation, digest, (envelope = %s::jsonb)::text, accepted_occurrence::text, accepted_at::text, \
        \(submitted_at IS NOT NULL)::text FROM impetus_fabric.deliveries WHERE sender = 'sender-a' AND delivery_id = 'delivery-1'"
        [textParam (memberText "canonical" e)]
        `shouldReturn` [[Just "recipient", Just "commands/start", Just "conversation-1", Just (memberText "digest" e), Just "true", Nothing, Nothing, Just "true"]]
    it "F-063 a fresh submit notifies the recipient once, at commit" $ \ctx -> withRoute ctx $ \env ps -> do
      Pg.listen env.admin "impetus_fabric_delivery"
      _ <- submitOk ctx (ps ! "sender-a") []
      first <- nextNotification env 5
      fmap (.notificationPayload) first `shouldBe` Just "recipient"
      fmap (.notificationChannel) first `shouldBe` Just "impetus_fabric_delivery"
      nextNotification env 0.3 >>= (`shouldSatisfy` isNothing) . fmap (.notificationPayload)
    it "F-064 an exact retransmission is a silent duplicate" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      earlier <- deliveryRow env "sender-a" "delivery-1"
      Pg.listen env.admin "impetus_fabric_delivery"
      _ <- Pg.pendingNotifications env.admin
      again <- submitOk ctx (ps ! "sender-a") []
      member "duplicate" again `shouldBeJson` Bool True
      member "state" again `shouldBeJson` "pending"
      deliveryRow env "sender-a" "delivery-1" `shouldReturn` earlier
      nextNotification env 0.3 >>= (`shouldSatisfy` isNothing) . fmap (.notificationPayload)
    it "F-065 an exact retransmission precedes the current grant" $ \ctx -> withRoute ctx $ \_ ps -> do
      first <- submitOk ctx (ps ! "sender-a") []
      member "duplicate" first `shouldBeJson` Bool False
      _ <- ok ctx.impl "revoke" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("source", "commands/start")]
      again <- submitOk ctx (ps ! "sender-a") []
      again `shouldBeJson` obj [("sender", "sender-a"), ("delivery_id", "delivery-1"), ("state", "pending"), ("duplicate", Bool True), ("occurrence", Null), ("accepted_at", Null)]
    it "F-066 a changed payload conflicts and leaves the row unchanged" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      earlier <- deliveryRow env "sender-a" "delivery-1"
      refusedWith ConflictCategory "identity conflict" ctx.impl "submit" [("client", (ps ! "sender-a").client), ("envelope", obj (envelopeArgs [("payload", obj [("command", "changed")])]))]
      deliveryRow env "sender-a" "delivery-1" `shouldReturn` earlier
    it "F-067 a changed recipient or source conflicts" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      earlier <- deliveryRow env "sender-a" "delivery-1"
      forM_ [[("recipient", "sender-b")], [("source", "commands/other")]] $ \overrides ->
        submitBy ctx (ps ! "sender-a") overrides >>= expectErr [ConflictCategory]
      deliveryRow env "sender-a" "delivery-1" `shouldReturn` earlier
    it "F-068 a changed correlation or reply route conflicts" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      earlier <- deliveryRow env "sender-a" "delivery-1"
      forM_ [[("correlation", "conversation-2")], [("reply_route", Null)], [("reply_route", arr ["sender-a", "replies/other"])]] $ \overrides ->
        submitBy ctx (ps ! "sender-a") overrides >>= expectErr [ConflictCategory]
      deliveryRow env "sender-a" "delivery-1" `shouldReturn` earlier
    it "F-069 after revocation a new delivery id is denied" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      _ <- ok ctx.impl "revoke" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("source", "commands/start")]
      submitBy ctx (ps ! "sender-a") [("delivery_id", "delivery-2")] >>= expectErr [DeniedCategory]
      deliveries env `shouldReturn` 1
    it "F-070 one delivery id from two senders is two deliveries" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- ok ctx.impl "grant" [("client", (ps ! "recipient").client), ("sender", "sender-b"), ("source", "commands/start")]
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "same")]
      _ <- submitOk ctx (ps ! "sender-b") [("sender", "sender-b"), ("delivery_id", "same")]
      items <- pendingOf ctx (ps ! "recipient") 100
      Set.fromList (identities items) `shouldBe` Set.fromList ["fabric:8:sender-a:same", "fabric:8:sender-b:same"]
    it "F-071 a duplicate of an accepted delivery reports its acceptance" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      receipt <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 3
      again <- submitOk ctx (ps ! "sender-a") []
      again
        `shouldBeJson` obj
          [ ("sender", "sender-a")
          , ("delivery_id", "delivery-1")
          , ("state", "accepted")
          , ("duplicate", Bool True)
          , ("occurrence", Int 3)
          , ("accepted_at", member "accepted_at" receipt)
          ]
    it "F-072 submit joins the caller's transaction" $ \ctx -> withRoute ctx $ \env ps -> do
      joined <- connectImpl ctx False
      client <- clientOn ctx joined (ps ! "sender-a")
      Pg.listen env.admin "impetus_fabric_delivery"
      _ <- ok ctx.impl "submit" [("client", client), ("envelope", obj (envelopeArgs []))]
      deliveries env `shouldReturn` 0
      _ <- ok ctx.impl "rollback" [("conn", joined)]
      deliveries env `shouldReturn` 0
      nextNotification env 0.3 >>= (`shouldSatisfy` isNothing) . fmap (.notificationPayload)
      _ <- ok ctx.impl "submit" [("client", client), ("envelope", obj (envelopeArgs []))]
      nextNotification env 0.3 >>= (`shouldSatisfy` isNothing) . fmap (.notificationPayload)
      _ <- ok ctx.impl "commit" [("conn", joined)]
      deliveries env `shouldReturn` 1
      nextNotification env 5 >>= (`shouldBe` Just "recipient") . fmap (.notificationPayload)
      void (ok ctx.impl "close" [("conn", joined)])
    it "F-073 concurrent identical submits give one row, one duplicate" $ \ctx -> withRoute ctx $ \env ps ->
      concurrentSubmits ctx env ps [] >>= \case
        Ok second -> member "duplicate" second `shouldBeJson` Bool True
        other -> expectationFailure ("the concurrent duplicate answered " <> show other)
    it "F-074 concurrent differing submits give one row, one conflict" $ \ctx -> withRoute ctx $ \env ps ->
      concurrentSubmits ctx env ps [("payload", obj [("command", "changed")])] >>= expectErr [ConflictCategory]
    it "F-075 the stored digest is the sender's; the reader keeps what jsonb returns" $ \ctx -> withRoute ctx $ \env ps -> do
      e <- envelopeOk ctx.impl [("payload", obj [("f", Float 1e16)])]
      _ <- submitOk ctx (ps ! "sender-a") [("payload", obj [("f", Float 1e16)])]
      rowsOf env.admin "SELECT digest FROM impetus_fabric.deliveries" [] `shouldReturn` [[Just (memberText "digest" e)]]
      [item] <- pendingOf ctx (ps ! "recipient") 10
      member "payload" (member "data" item) `shouldBeJson` obj [("f", Int 10000000000000000)]

  describe "H Pending" $ do
    it "F-076 pending refuses 0, -1 and true" $ \ctx -> withRoute ctx $ \_ ps ->
      forM_ [Int 0, Int (-1), Bool True] $ \limit -> refused Invalid ctx.impl "pending" [("client", (ps ! "recipient").client), ("limit", limit)]
    it "F-077 pending is this recipient's unaccepted deliveries, ordered and capped" $ \ctx -> withRoute ctx $ \_ ps -> do
      let r = (ps ! "recipient").client
          b = (ps ! "sender-b").client
      _ <- ok ctx.impl "grant" [("client", r), ("sender", "sender-b"), ("source", "commands/start")]
      _ <- ok ctx.impl "expose" [("client", b), ("source", "commands/start")]
      _ <- ok ctx.impl "grant" [("client", b), ("sender", "sender-a"), ("source", "commands/start")]
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "d-3")]
      _ <- submitOk ctx (ps ! "sender-b") [("sender", "sender-b"), ("delivery_id", "d-1")]
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "d-2")]
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "d-4")]
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "elsewhere"), ("recipient", "sender-b")]
      _ <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "d-4" 1
      identities <$> pendingOf ctx (ps ! "recipient") 100
        `shouldReturn` ["fabric:8:sender-a:d-3", "fabric:8:sender-b:d-1", "fabric:8:sender-a:d-2"]
      identities <$> pendingOf ctx (ps ! "recipient") 2 `shouldReturn` ["fabric:8:sender-a:d-3", "fabric:8:sender-b:d-1"]
      identities <$> pendingOf ctx (ps ! "sender-b") 100 `shouldReturn` ["fabric:8:sender-a:elsewhere"]
    it "F-078 payloads read back follow the jsonb normalization" $ \ctx -> withRoute ctx $ \_ ps -> do
      let big = 123456789012345678901234567890
          payload = obj [("z", Int 1), ("a", obj [("big", Int big), ("f", Float 1e16), ("neg", Float (-0.0)), ("two", Float 2)])]
      _ <- submitOk ctx (ps ! "sender-a") [("payload", payload)]
      [item] <- pendingOf ctx (ps ! "recipient") 10
      let back = member "payload" (member "data" item)
      back `shouldBeJson` obj [("a", obj [("big", Int big), ("f", Int 10000000000000000), ("neg", Float 0), ("two", Float 2)]), ("z", Int 1)]
      case member "neg" (member "a" back) of
        Float d -> isNegativeZero d `shouldBe` False
        other -> expectationFailure (showJson other)
    it "F-079 pending requires authentication" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      wrong <- ok ctx.impl "issue_credential" []
      client <- ok ctx.impl "client" [("conn", env.conn), ("instance", "recipient"), ("credential", wrong)]
      void (refused DeniedCategory ctx.impl "pending" [("client", client), ("limit", Int 10)])

  describe "I Acknowledge" $ do
    it "F-080 acknowledge refuses 0, negative and true" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      forM_ [Int 0, Int (-3), Bool True] $ \occurrence ->
        acknowledgeAnswer ctx (ps ! "recipient") "sender-a" "delivery-1" occurrence >>= expectErr [Invalid]
      refusedWith Invalid "positive integer" ctx.impl "acknowledge" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("delivery_id", "delivery-1"), ("occurrence", Int 0)]
    it "F-081 acknowledging an unknown delivery is not-found" $ \ctx -> withRoute ctx $ \_ ps ->
      acknowledgeAnswer ctx (ps ! "recipient") "sender-a" "nothing" (Int 1) >>= expectErr [NotFoundCategory]
    it "F-082 acknowledging another process's delivery is not-found" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      acknowledgeAnswer ctx (ps ! "sender-b") "sender-a" "delivery-1" (Int 1) >>= expectErr [NotFoundCategory]
      count env.admin "SELECT count(*) FROM impetus_fabric.deliveries WHERE accepted_at IS NULL" [] `shouldReturn` 1
    it "F-083 a first acknowledgement accepts" $ \ctx -> withRoute ctx $ \env ps -> do
      e <- envelopeOk ctx.impl []
      _ <- submitOk ctx (ps ! "sender-a") []
      receipt <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 4
      member "state" receipt `shouldBeJson` "accepted"
      member "occurrence" receipt `shouldBeJson` Int 4
      member "digest" receipt `shouldBeJson` member "digest" e
      member "payload_retained" receipt `shouldBeJson` Bool True
      member "recipient" receipt `shouldBeJson` "recipient"
      member "source" receipt `shouldBeJson` "commands/start"
      member "accepted_at" receipt `shouldSatisfy` isString
      rowsOf env.admin "SELECT accepted_occurrence::text, (accepted_at IS NOT NULL)::text FROM impetus_fabric.deliveries" []
        `shouldReturn` [[Just "4", Just "true"]]
    it "F-084 re-acknowledging with the same occurrence keeps accepted_at" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      first <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 4
      second <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 4
      second `shouldBeJson` first
    it "F-085 another occurrence conflicts and reports the first" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      _ <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 4
      earlier <- deliveryRow env "sender-a" "delivery-1"
      refusedWith ConflictCategory "already accepted by occurrence 4" ctx.impl "acknowledge" [("client", (ps ! "recipient").client), ("sender", "sender-a"), ("delivery_id", "delivery-1"), ("occurrence", Int 5)]
      deliveryRow env "sender-a" "delivery-1" `shouldReturn` earlier
    it "F-086 acknowledging a pruned delivery reports payload_retained false" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      _ <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 4
      _ <- pruneOk ctx env (ps ! "recipient")
      again <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 4
      member "payload_retained" again `shouldBeJson` Bool False
      member "occurrence" again `shouldBeJson` Int 4
    it "F-087 acknowledge joins the caller's transaction" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      joined <- connectImpl ctx False
      client <- clientOn ctx joined (ps ! "recipient")
      _ <- ok ctx.impl "acknowledge" [("client", client), ("sender", "sender-a"), ("delivery_id", "delivery-1"), ("occurrence", Int 2)]
      _ <- ok ctx.impl "rollback" [("conn", joined)]
      _ <- ok ctx.impl "close" [("conn", joined)]
      identities <$> pendingOf ctx (ps ! "recipient") 10 `shouldReturn` ["fabric:8:sender-a:delivery-1"]

  describe "J Receipt" $ do
    it "F-088 a pending receipt" $ \ctx -> withRoute ctx $ \_ ps -> do
      e <- envelopeOk ctx.impl []
      _ <- submitOk ctx (ps ! "sender-a") []
      receipt <- receiptOf ctx (ps ! "sender-a") "delivery-1"
      receipt
        `shouldBeJson` obj
          [ ("sender", "sender-a")
          , ("delivery_id", "delivery-1")
          , ("recipient", "recipient")
          , ("source", "commands/start")
          , ("digest", member "digest" e)
          , ("state", "pending")
          , ("occurrence", Null)
          , ("accepted_at", Null)
          , ("payload_retained", Bool True)
          ]
    it "F-089 receipts are sender-scoped" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      receiptOf ctx (ps ! "sender-a") "unknown" >>= (`shouldBeJson` Null)
      receiptOf ctx (ps ! "recipient") "delivery-1" >>= (`shouldBeJson` Null)
    it "F-090 an accepted receipt" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      acknowledged <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 6
      receipt <- receiptOf ctx (ps ! "sender-a") "delivery-1"
      member "state" receipt `shouldBeJson` "accepted"
      member "occurrence" receipt `shouldBeJson` Int 6
      member "accepted_at" receipt `shouldBeJson` member "accepted_at" acknowledged

  describe "K Prune" $ do
    it "F-091 a naive cutoff is invalid" $ \ctx -> withRoute ctx $ \_ ps ->
      void (refused Invalid ctx.impl "prune" [("client", (ps ! "recipient").client), ("before", "2026-01-01T00:00:00")])
    it "F-092 pruning removes accepted envelopes only" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "delivery-2")]
      pruneOk ctx env (ps ! "recipient") >>= (`shouldBeJson` Int 0)
      _ <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 1
      pruneOk ctx env (ps ! "recipient") >>= (`shouldBeJson` Int 1)
      rowsOf env.admin "SELECT delivery_id, (envelope IS NULL)::text FROM impetus_fabric.deliveries ORDER BY delivery_id" []
        `shouldReturn` [[Just "delivery-1", Just "true"], [Just "delivery-2", Just "false"]]
    it "F-093 a pruned delivery keeps its receipt, dedup and conflict" $ \ctx -> withRoute ctx $ \env ps -> do
      let payload = obj [("secret-inline-bytes", "do-not-retain")]
      e <- envelopeOk ctx.impl [("payload", payload)]
      _ <- submitOk ctx (ps ! "sender-a") [("payload", payload)]
      _ <- acknowledgeOk ctx (ps ! "recipient") "sender-a" "delivery-1" 9
      pruneOk ctx env (ps ! "recipient") >>= (`shouldBeJson` Int 1)
      receipt <- receiptOf ctx (ps ! "sender-a") "delivery-1"
      receipt
        `shouldBeJson` obj
          [ ("sender", "sender-a")
          , ("delivery_id", "delivery-1")
          , ("recipient", "recipient")
          , ("source", "commands/start")
          , ("digest", member "digest" e)
          , ("state", "accepted")
          , ("occurrence", Int 9)
          , ("accepted_at", member "accepted_at" receipt)
          , ("payload_retained", Bool False)
          ]
      member "accepted_at" receipt `shouldSatisfy` isString
      rowsOf env.admin "SELECT (envelope IS NULL)::text, digest FROM impetus_fabric.deliveries" []
        `shouldReturn` [[Just "true", Just (memberText "digest" e)]]
      again <- submitOk ctx (ps ! "sender-a") [("payload", payload)]
      (member "state" again, member "duplicate" again, member "occurrence" again) `shouldSatisfy` \(s, d, o) ->
        typeExactEq s "accepted" && typeExactEq d (Bool True) && typeExactEq o (Int 9)
      refusedWith ConflictCategory "identity conflict" ctx.impl "submit" [("client", (ps ! "sender-a").client), ("envelope", obj (envelopeArgs [("payload", obj [("secret-inline-bytes", "changed")])]))]
    it "F-094 the database enforces both CHECK constraints" $ \ctx -> withRoute ctx $ \env ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      forM_
        [ "UPDATE impetus_fabric.deliveries SET accepted_occurrence = 1"
        , "UPDATE impetus_fabric.deliveries SET accepted_at = clock_timestamp()"
        , "UPDATE impetus_fabric.deliveries SET envelope = NULL"
        ]
        $ \statement -> do
          result <- try (exec env.admin statement [])
          case result of
            Left (err :: PostgresError) -> hasSqlState "23514" err `shouldBe` True
            Right () -> expectationFailure ("the database accepted " <> show statement)

  describe "L Ingress bridge" $ do
    it "F-095 drain delivers the envelope token under its ingress identity" $ \ctx -> withRoute ctx $ \_ ps -> do
      e <- envelopeOk ctx.impl []
      _ <- submitOk ctx (ps ! "sender-a") []
      answer <- ok ctx.impl "drain_fake" [("client", (ps ! "recipient").client)]
      member "calls" answer
        `shouldBeJson` arr [obj [("source", "commands/start"), ("colors", arr ["FabricEnvelope"]), ("identity", "fabric:8:sender-a:delivery-1"), ("data", arr [member "data" e])]]
    it "F-096 drain acknowledges with the door's occurrence" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      _ <- submitOk ctx (ps ! "sender-a") [("delivery_id", "delivery-2")]
      answer <- ok ctx.impl "drain_fake" [("client", (ps ! "recipient").client), ("occurrence", Int 7)]
      let receipts = case member "receipts" answer of
            Array items -> items
            _ -> []
      map (\r -> (memberText "delivery_id" r, memberText "state" r, member "occurrence" r)) receipts
        `shouldSatisfy` \rs -> map (\(d, s, _) -> (d, s)) rs == [("delivery-1", "accepted"), ("delivery-2", "accepted")] && all (\(_, _, o) -> typeExactEq o (Int 7)) rs
      pendingOf ctx (ps ! "recipient") 10 `shouldReturn` []
    it "F-097 a prior acknowledgement recovers the crash window" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      answer <- ok ctx.impl "drain_fake" [("client", (ps ! "recipient").client), ("mode", "prior"), ("occurrence", Int 7)]
      case member "receipts" answer of
        Array [r] -> (member "state" r, member "occurrence" r) `shouldSatisfy` \(s, o) -> typeExactEq s "accepted" && typeExactEq o (Int 7)
        other -> expectationFailure (showJson other)
      pendingOf ctx (ps ! "recipient") 10 `shouldReturn` []
    it "F-098 a raising door stops the drain; earlier acknowledgements persist" $ \ctx -> withRoute ctx $ \_ ps -> do
      forM_ ["d-1", "d-2", "d-3"] $ \d -> submitOk ctx (ps ! "sender-a") [("delivery_id", d)]
      answer <- ok ctx.impl "drain_fake" [("client", (ps ! "recipient").client), ("fail_on", arr ["raise", Int 2])]
      member "error" answer `shouldSatisfy` isObject
      length (arrayOf (member "calls" answer)) `shouldBe` 2
      member "state" <$> receiptOf ctx (ps ! "sender-a") "d-1" >>= (`shouldBeJson` "accepted")
      identities <$> pendingOf ctx (ps ! "recipient") 10 `shouldReturn` ["fabric:8:sender-a:d-2", "fabric:8:sender-a:d-3"]
    it "F-099 a door answering another type fails the drain" $ \ctx -> withRoute ctx $ \_ ps -> do
      _ <- submitOk ctx (ps ! "sender-a") []
      answer <- ok ctx.impl "drain_fake" [("client", (ps ! "recipient").client), ("fail_on", arr ["other", Int 1])]
      member "error" answer `shouldSatisfy` isObject
      member "receipts" answer `shouldBeJson` Null
      identities <$> pendingOf ctx (ps ! "recipient") 10 `shouldReturn` ["fabric:8:sender-a:delivery-1"]

  describe "M fabric.send activity profile" $
    it "F-101 the executor checks idempotency, answers exactly four members, and dedups" $ \ctx -> withRoute ctx $ \_ ps -> do
      e <- envelopeOk ctx.impl []
      let dsn = String (TE.decodeUtf8 ctx.target.targetUrl)
          send idempotency =
            answerOf
              ctx.impl
              "send_activity"
              [ ("dsn", dsn)
              , ("instance", "sender-a")
              , ("credential", String (ps ! "sender-a").credential)
              , ("invocation", obj [("activity", "fabric.send"), ("input", member "data" e), ("correlation", "conversation-1"), ("idempotency", idempotency)])
              ]
      send (String "fabric:8:sender-a:other") >>= expectErr [Invalid]
      send Null >>= expectErr [Invalid]
      let expected duplicate = obj [("state", "pending"), ("duplicate", Bool duplicate), ("delivery_id", "delivery-1"), ("correlation", "conversation-1")]
      send (member "ingress_identity" e) >>= \case
        Ok first -> first `shouldBeJson` expected False
        other -> expectationFailure (show other)
      send (member "ingress_identity" e) >>= \case
        Ok second -> second `shouldBeJson` expected True
        other -> expectationFailure (show other)
  where
    isString = \case
      String _ -> True
      _ -> False
    isObject = \case
      Object _ -> True
      _ -> False
    arrayOf = \case
      Array items -> items
      _ -> []
    namespaces env = count env.admin "SELECT count(*) FROM pg_namespace WHERE nspname = 'impetus_fabric'" []

-- | Instance A submits on an open transaction; instance B submits the
-- (possibly changed) envelope concurrently and must wait for A's commit.
concurrentSubmits :: Ctx -> Env -> PartyMap -> [(Text, Json)] -> IO Answer
concurrentSubmits ctx env ps overrides = do
  let a = ps ! "sender-a"
  joined <- connectImpl ctx False
  clientA <- clientOn ctx joined a
  first <- ok ctx.impl "submit" [("client", clientA), ("envelope", obj (envelopeArgs []))]
  member "duplicate" first `shouldBeJson` Bool False
  answer <- case ctx.launcher of
    Launcher with -> with $ \other -> do
      handle <- ok other "connect" [("dsn", String (TE.decodeUtf8 ctx.target.targetUrl)), ("autocommit", Bool True)]
      clientB <- ok other "client" [("conn", handle), ("instance", "sender-a"), ("credential", String a.credential)]
      racing <- async (answerOf other "submit" [("client", clientB), ("envelope", obj (envelopeArgs overrides))])
      threadDelay 300000
      blocked <- poll racing
      when (isJust blocked) $ expectationFailure "the second submit did not wait for the first transaction"
      _ <- ok ctx.impl "commit" [("conn", joined)]
      result <- wait racing
      _ <- other.call "close" [("conn", handle)]
      pure result
  _ <- ok ctx.impl "close" [("conn", joined)]
  deliveries env `shouldReturn` 1
  pure answer

memberTextOf :: Json -> Text
memberTextOf = \case
  String s -> s
  other -> T.pack (showJson other)

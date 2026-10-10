-- | spec/fabric-conformance.md §D, §E and §N's interop checks that need only
-- the two stores: the Haskell port and the pinned Python reference against
-- one shared database, each check in both directions. The Engine-level
-- scenarios (F-102's Engine delivery, F-107, F-108) are in
-- "Petrus.Fabric.DemoSpec".
module Petrus.Fabric.InteropSpec (spec) where

import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Petrus.Fabric.Conformance.Haskell (fabricOps)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Conformance.Setup
import Petrus.Fabric.ConformanceSpec (catalog)
import Petrus.Fabric.Error (Category (..))
import Petrus.Json (Json (..), typeExactEq)
import Petrus.Postgres qualified as Pg
import Test.Hspec

spec :: Spec
spec =
  describe "Fabric interop over one database (spec/fabric-conformance.md)" $
    interopGroup (haskellLauncher (\h -> [fabricOps h])) checks

shouldBeJson :: Json -> Json -> Expectation
shouldBeJson actual expected =
  if typeExactEq actual expected
    then pure ()
    else expectationFailure ("expected " <> showJson expected <> "\n but got " <> showJson actual)

ensure :: Side -> IO ()
ensure side = () <$ ok side.impl "ensure_fabric_schema" [("conn", side.conn)]

clientFor :: Side -> Text -> Text -> IO Json
clientFor side n credential = ok side.impl "client" [("conn", side.conn), ("instance", String n), ("credential", String credential)]

submit :: Side -> Json -> [(Text, Json)] -> IO Answer
submit side client overrides = answerOf side.impl "submit" [("client", client), ("envelope", obj (envelopeArgs overrides))]

-- | test_fabric's route: the recipient (registered through @owner@) exposes
-- commands/start and grants sender-a.
route :: Side -> Json -> IO ()
route owner recipient = do
  _ <- ok owner.impl "expose" [("client", recipient), ("source", "commands/start")]
  _ <- ok owner.impl "grant" [("client", recipient), ("sender", "sender-a"), ("source", "commands/start")]
  pure ()

checks :: SpecWith Pair
checks = do
  both "F-038 a schema provisioned by one is a no-op for the other; catalogs are identical" $ \admin a b -> do
    ensure a
    once <- catalog admin
    ensure b
    catalog admin `shouldReturn` once
    Pg.execute_ admin "DROP SCHEMA impetus_fabric CASCADE" []
    ensure b
    catalog admin `shouldReturn` once
    rowsOf admin "SELECT component, version::text FROM impetus_fabric.schema_metadata" [] `shouldReturn` [[Just "fabric", Just "1"]]

  both "F-046 a process registered by one authenticates from the other" $ \_ a b -> do
    ensure a
    (credential, _) <- registerOn a "process-a"
    client <- clientFor b "process-a" credential
    _ <- ok b.impl "authenticate" [("client", client)]
    wrong <- ok b.impl "issue_credential" []
    other <- ok b.impl "client" [("conn", b.conn), ("instance", "process-a"), ("credential", wrong)]
    refusedWith DeniedCategory "" b.impl "authenticate" [("client", other)]

  both "F-102/F-103 one submits, the other drains and acknowledges; the sender's receipt shows that occurrence" $ \_ a b -> do
    ensure a
    (_, sender) <- registerOn a "sender-a"
    (_, recipient) <- registerOn b "recipient"
    route b recipient
    _ <- submit a sender [] >>= expectOk
    drained <- ok b.impl "drain_fake" [("client", recipient), ("mode", "fresh"), ("occurrence", Int 11)]
    map (memberText "identity") (arrayOf (member "calls" drained)) `shouldBe` ["fabric:8:sender-a:delivery-1"]
    map (member "occurrence") (arrayOf (member "receipts" drained)) `shouldBe` [Int 11]
    ok b.impl "pending" [("client", recipient), ("limit", Int 10)] >>= (`shouldBeJson` Array [])
    receipt <- ok a.impl "receipt" [("client", sender), ("delivery_id", "delivery-1")]
    member "state" receipt `shouldBeJson` "accepted"
    member "occurrence" receipt `shouldBeJson` Int 11
    member "accepted_at" receipt `shouldBeJson` maybe Null (member "accepted_at") (listToMaybe (arrayOf (member "receipts" drained)))

  both "F-104 a resubmission by the other is a duplicate; a changed member conflicts" $ \_ a b -> do
    ensure a
    (credential, sender) <- registerOn a "sender-a"
    (_, recipient) <- registerOn a "recipient"
    route a recipient
    first <- submit a sender [] >>= expectOk
    member "duplicate" first `shouldBeJson` Bool False
    again <- clientFor b "sender-a" credential
    second <- submit b again [] >>= expectOk
    member "duplicate" second `shouldBeJson` Bool True
    member "occurrence" second `shouldBeJson` Null
    let changes =
          [ [("payload", obj [("command", "stop")])]
          , [("correlation", "conversation-2")]
          , [("reply_route", Null)]
          , [("payload", obj [("command", "go"), ("extra", Int 1)])]
          ]
    mapM_ (\c -> submit b again c >>= expectCategory ConflictCategory) changes

  both "F-105 offers made by either are discovered identically by both" $ \_ a b -> do
    ensure a
    (_, x) <- registerOn a "worker-x"
    (_, y) <- registerOn b "worker-y"
    (seekerCredential, seekerA) <- registerOn a "seeker"
    seekerB <- clientFor b "seeker" seekerCredential
    let offer side client source service capabilities = do
          _ <- ok side.impl "expose" [("client", client), ("source", source)]
          _ <- ok side.impl "offer" [("client", client), ("source", source), ("service", service), ("capabilities", js capabilities)]
          ok side.impl "grant" [("client", client), ("sender", "seeker"), ("source", source)]
    _ <- offer a x "commands/z" "worker" "{\"model\":\"large\",\"tools\":[\"shell\",\"git\"]}"
    _ <- offer b y "commands/a" "worker" "{\"model\":\"small\"}"
    _ <- offer a x "commands/a" "worker" "{\"model\":\"large\",\"region\":\"eu\"}"
    _ <- offer b y "commands/b" "reviewer" "{}"
    _ <- ok b.impl "expose" [("client", y), ("source", "commands/hidden")]
    _ <- ok b.impl "offer" [("client", y), ("source", "commands/hidden"), ("service", "worker"), ("capabilities", js "{}")]
    let queries =
          [ [("service", "worker")]
          , [("service", "worker"), ("capabilities", js "{\"model\":\"large\"}")]
          , [("service", "worker"), ("capabilities", js "{\"tools\":[\"git\"]}")]
          , [("service", "reviewer")]
          , [("service", "nobody")]
          ]
    mapM_
      ( \q -> do
          fromA <- ok a.impl "discover" (("client", seekerA) : q)
          fromB <- ok b.impl "discover" (("client", seekerB) : q)
          fromB `shouldBeJson` fromA
      )
      queries
    workers <- ok b.impl "discover" [("client", seekerB), ("service", "worker")]
    map (\e -> (memberText "recipient" e, memberText "source" e)) (arrayOf workers)
      `shouldBe` [("worker-x", "commands/a"), ("worker-x", "commands/z"), ("worker-y", "commands/a")]

  both "F-106 deliveries pruned by one are reported identically by the other" $ \admin a b -> do
    ensure a
    (credential, sender) <- registerOn a "sender-a"
    (recipientCredential, recipient) <- registerOn a "recipient"
    route a recipient
    _ <- submit a sender [] >>= expectOk
    _ <- ok a.impl "acknowledge" [("client", recipient), ("sender", "sender-a"), ("delivery_id", "delivery-1"), ("occurrence", Int 4)]
    now <- dbNow admin
    ok a.impl "prune" [("client", recipient), ("before", isoPlus 1 now)] >>= (`shouldBeJson` Int 1)
    fromA <- ok a.impl "receipt" [("client", sender), ("delivery_id", "delivery-1")]
    senderB <- clientFor b "sender-a" credential
    recipientB <- clientFor b "recipient" recipientCredential
    fromB <- ok b.impl "receipt" [("client", senderB), ("delivery_id", "delivery-1")]
    fromB `shouldBeJson` fromA
    member "payload_retained" fromB `shouldBeJson` Bool False
    duplicateA <- submit a sender [] >>= expectOk
    duplicateB <- submit b senderB [] >>= expectOk
    duplicateB `shouldBeJson` duplicateA
    member "state" duplicateB `shouldBeJson` "accepted"
    submit b senderB [("payload", obj [("command", "stop")])] >>= expectCategory ConflictCategory
    ok b.impl "prune" [("client", recipientB), ("before", isoPlus 1 now)] >>= (`shouldBeJson` Int 0)
  where
    expectOk = \case
      Ok v -> pure v
      other -> expectationFailure ("expected a value, got " <> show other) >> pure Null
    expectCategory category = \case
      Err c _ _ | c == category -> pure ()
      other -> expectationFailure ("expected " <> show category <> ", got " <> show other)
    arrayOf = \case
      Array xs -> xs
      _ -> []

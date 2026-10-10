-- | spec/processes-conformance.md's interop checks at the store and Activity
-- level: the Haskell port and the pinned Python reference against one shared
-- database, each check in both directions. The Engine-level scenarios (the
-- lifecycle demo with mixed roles) are in "Petrus.Processes.DemoSpec".
module Petrus.Processes.InteropSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Petrus.Fabric.Conformance.Haskell (fabricOps)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Conformance.Setup
import Petrus.Json (Json (..), typeExactEq)
import Petrus.Processes.Conformance.Haskell (processOps)
import Petrus.Processes.ConformanceSpec (child1, dataArgs, requestData, spawnInvocation, spec15)
import Test.Hspec

spec :: Spec
spec =
  describe "Process lifecycle interop over one database (spec/processes-conformance.md)" $
    interopGroup (haskellLauncher (\h -> [fabricOps h, processOps h])) checks

shouldBeJson :: Json -> Json -> Expectation
shouldBeJson actual expected =
  if typeExactEq actual expected
    then pure ()
    else expectationFailure ("expected " <> showJson expected <> "\n but got " <> showJson actual)

arrayOf :: Json -> [Json]
arrayOf = \case
  Array xs -> xs
  _ -> []

single :: String -> Json -> IO Json
single what value = case arrayOf value of
  [x] -> pure x
  other -> expectationFailure (what <> ": expected one item, got " <> show (length other)) >> pure Null

submitData :: Side -> Json -> Json -> IO Json
submitData side client e = ok side.impl "submit" [("client", client), ("envelope", obj (dataArgs e))]

checks :: SpecWith Pair
checks = do
  both "P-038 a caller in one and a callee in the other complete result and error round trips" $ \_ a b -> do
    _ <- ok a.impl "ensure_fabric_schema" [("conn", a.conn)]
    (_, caller) <- registerOn a "caller"
    (_, callee) <- registerOn b "callee"
    _ <- ok b.impl "expose" [("client", callee), ("source", "calls")]
    _ <- ok b.impl "grant" [("client", callee), ("sender", "caller"), ("source", "calls")]
    _ <- ok a.impl "expose" [("client", caller), ("source", "replies")]
    _ <- ok a.impl "grant" [("client", caller), ("sender", "callee"), ("source", "replies")]
    forM_ (zip [1 :: Integer ..] ["result", "error"]) $ \(occurrence, kind) -> do
      let callId = "call-" <> kind
      -- The caller (a) sends the request.
      payload <- requestData a.impl callId (obj [("question", Int 42)])
      request <- ok a.impl "request_envelope" [("request", payload), ("sender", "caller"), ("recipient", "callee"), ("source", "calls"), ("reply_route", Array ["caller", "replies"])]
      _ <- submitData a caller (member "data" request)
      -- The callee (b) validates the request it reads back and replies.
      item <- ok b.impl "pending" [("client", callee), ("limit", Int 10)] >>= single "callee pending"
      memberText "digest" item `shouldBe` memberText "digest" request
      ok b.impl "request_from_envelope" [("envelope", member "data" item)] >>= (`shouldBeJson` payload)
      reply <-
        if kind == "result"
          then do
            value <- ok b.impl "call_result" [("call_id", String callId), ("result", obj [("answer", Int 42)])]
            ok b.impl "result_envelope" [("request", member "data" item), ("result", value), ("sender", "callee")]
          else do
            value <- ok b.impl "call_error" [("call_id", String callId), ("code", "delegated-refusal"), ("message", "child refused delegated work")]
            ok b.impl "error_envelope" [("request", member "data" item), ("error", value), ("sender", "callee")]
      _ <- submitData b callee (member "data" reply)
      _ <- ok b.impl "acknowledge" [("client", callee), ("sender", "caller"), ("delivery_id", String (memberText "delivery_id" (member "data" item))), ("occurrence", Int occurrence)]
      -- The caller (a) validates the reply against its own request.
      back <- ok a.impl "pending" [("client", caller), ("limit", Int 10)] >>= single "caller pending"
      memberText "digest" back `shouldBe` memberText "digest" reply
      decoded <- ok a.impl "reply_from_envelope" [("envelope", member "data" back), ("request", member "data" request)]
      memberText "kind" decoded `shouldBe` (kind :: Text)
      _ <- ok a.impl "acknowledge" [("client", caller), ("sender", "callee"), ("delivery_id", String (memberText "delivery_id" (member "data" back))), ("occurrence", Int occurrence)]
      receipt <- ok b.impl "receipt" [("client", callee), ("delivery_id", String (memberText "delivery_id" (member "data" reply)))]
      member "state" receipt `shouldBeJson` "accepted"

  both "P-079 the process.spawn Activity's outcome is the same JSON from either implementation" $ \admin a b -> do
    parent <- lifecycle a
    invocation <- spawnInvocation a.impl spec15
    first <- spawnOn a parent invocation "record" 1 >>= single "attempts" . member "attempts"
    exec admin "DELETE FROM impetus_lifecycle.spawns" []
    second <- spawnOn b parent invocation "record" 1 >>= single "attempts" . member "attempts"
    member "ok" second `shouldBeJson` member "ok" first
    showJson (member "ok" second) `shouldBe` showJson (member "ok" first)
    member "prior_claim" (member "ok" second) `shouldBeJson` Bool False

  both "P-080 a spawn attempted in one and retried in the other converges" $ \admin a b -> do
    parent <- lifecycle a
    invocation <- spawnInvocation a.impl spec15
    failed <- spawnOn a parent invocation "fail-first" 1
    attempts <- single "attempts" (member "attempts" failed)
    member "error" attempts `shouldSatisfy` (/= Null)
    count admin "SELECT count(*) FROM impetus_lifecycle.spawns" [] `shouldReturn` 1
    retried <- spawnOn b parent invocation "record" 1
    outcome <- member "ok" <$> single "attempts" (member "attempts" retried)
    member "prior_claim" outcome `shouldBeJson` Bool True
    memberText "child" outcome `shouldBe` child1
    member "endpoint" outcome `shouldBeJson` obj [("recipient", String child1), ("source", "calls"), ("capabilities", obj [("protocol", "call-v1")])]
    count admin "SELECT count(*) FROM impetus_lifecycle.spawns" [] `shouldReturn` 1
    rowsOf admin "SELECT parent, spawn_id, child FROM impetus_lifecycle.spawns" [] `shouldReturn` [[Just "parent", Just "spawn-1", Just child1]]
  where
    lifecycle a = do
      _ <- ok a.impl "ensure_fabric_schema" [("conn", a.conn)]
      _ <- ok a.impl "ensure_lifecycle_schema" [("conn", a.conn)]
      (credential, _) <- registerOn a "parent"
      pure credential
    registryOn side credential = ok side.impl "registry" [("conn", side.conn), ("parent", "parent"), ("credential", String credential)]
    spawnOn side credential invocation provisioner times = do
      registry <- registryOn side credential
      ok side.impl "spawn" [("registry", registry), ("invocation", invocation), ("provisioner", provisioner), ("times", Int times)]

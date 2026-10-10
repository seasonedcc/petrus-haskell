-- | History replay from Petrus observation producers: the mapping of an
-- observation-protocol-v1 snapshot / Net document (upstream/petrus/spec
-- fixtures) to the Temporal shapes the viewer replays, and the @/temporal@
-- routes served from a live producer.
module ObservationSpec (spec) where

import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W
import Network.Wai.Handler.Warp qualified as Warp
import Petrus.Viewer.History.Observation
import Petrus.Viewer.Json
import Petrus.Viewer.Server (ServerConfig (..), ServerHandle (..))
import Test.Hspec
import TestSupport

loadFixture :: FilePath -> IO JsValue
loadFixture name = do
  raw <- B.readFile (fixturePath name)
  either fail pure (parseJs raw)

states :: JsValue -> [JsValue]
states v = case field "history" v >>= field "states" of
  Just (JsArr xs) -> xs
  _ -> []

keysOf :: Maybe JsValue -> [Text]
keysOf v = maybe [] (map jsStringText . objectKeys) (v >>= asObject)

-- | A producer serving the two fixtures over the HTTP profile.
producer :: BL.ByteString -> BL.ByteString -> W.Application
producer snap doc req respond = respond $ case W.rawPathInfo req of
  "/v1/snapshot" -> W.responseLBS H.status200 [("Content-Type", "application/json")] snap
  "/v1/document" -> W.responseLBS H.status200 [("Content-Type", "application/json")] doc
  _ -> W.responseLBS H.status404 [] ""

spec :: Spec
spec = do
  describe "mapping" $ do
    it "turns the head's Timeline path into one viewer state per entry" $ do
      doc <- loadFixture "net-document-v1-observation.json"
      rs <- either (fail . T.unpack) pure (documentToRuntimeState doc)
      length (states rs) `shouldBe` 7
      (field "history" rs >>= field "current") `shouldBe` Just (int 6)
      (field "history" rs >>= textField "net") `shouldBe` Just "canonical-observation"
      -- entry 5's record has no transition, only occurrence 1: it is
      -- attributed to the transition that occurrence belongs to
      map (field "fired") (states rs)
        `shouldBe` map (Just . maybe JsNull (str . ("canonical-observation." <>))) [Nothing, Nothing, Nothing, Just "work", Just "work", Just "work", Just "work"]
      field "terminal" rs `shouldBe` Just (JsBool False)
      field "marking" rs `shouldBe` Just (obj [("canonical-observation.a", int 1)])
      map (field "marking") (states rs) `shouldSatisfy` all (/= Nothing)

    it "turns the definition into a flat viewer net with mapped arc kinds" $ do
      doc <- loadFixture "net-document-v1-observation.json"
      schema <- either (fail . T.unpack) pure (documentToWorkflowSchema doc)
      textField "net" schema `shouldBe` Just "canonical-observation"
      keysOf (field "places" schema) `shouldBe` ["a", "b", "c"]
      keysOf (field "transitions" schema) `shouldBe` ["source", "work"]
      case field "arcs" schema of
        Just (JsArr as) -> map (textField "kind") as `shouldSatisfy` all (== Just "normal")
        _ -> expectationFailure "no arcs"

    it "lists a snapshot as a running workflow execution" $ do
      snap <- loadFixture "engine-snapshot-v1.json"
      let e = snapshotToExecution snap
      (field "execution" e >>= textField "workflowId") `shouldBe` Just "canonical-instance"
      (field "type" e >>= textField "name") `shouldBe` Just "canonical-observation"
      textField "status" e `shouldBe` Just "WORKFLOW_EXECUTION_STATUS_RUNNING"

  describe "/temporal served from an observation producer" $
    it "lists workflows and answers get_state / get_schema, with Temporal errors otherwise" $ do
      snap <- BL.readFile (fixturePath "engine-snapshot-v1.json")
      doc <- BL.readFile (fixturePath "net-document-v1-observation.json")
      Warp.testWithApplication (pure (producer snap doc)) $ \pport ->
        withViewer (\c -> c {serverObservation = ["http://127.0.0.1:" <> T.pack (show pport)]}) $ \h -> do
          let base = "http://localhost:" <> show (handlePort h) <> "/temporal/api/v1/namespaces/default/workflows"
              body = either (const JsNull) id . parseJ . httpBody
          list <- httpRequest "GET" base Nothing
          httpStatus list `shouldBe` 200
          case field "executions" (body list) of
            Just (JsArr [e]) -> (field "execution" e >>= textField "workflowId") `shouldBe` Just "canonical-instance"
            other -> expectationFailure ("executions: " <> show other)
          st <- httpRequest "POST" (base <> "/canonical-instance/query/get_state") (Just "{}")
          case field "queryResult" (body st) of
            Just (JsArr [rs]) -> length (states rs) `shouldBe` 7
            other -> expectationFailure ("get_state: " <> show other)
          sc <- httpRequest "POST" (base <> "/canonical-instance/query/get_schema") (Just "{}")
          case field "queryResult" (body sc) of
            Just (JsArr [s]) -> textField "net" s `shouldBe` Just "canonical-observation"
            other -> expectationFailure ("get_schema: " <> show other)
          missing <- httpRequest "POST" (base <> "/nope/query/get_state") (Just "{}")
          httpStatus missing `shouldNotBe` 200
          textField "message" (body missing) `shouldSatisfy` maybe False (not . T.null)

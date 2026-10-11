-- | The fixtures of @tests/unit/host/test_export.py@: one state directory
-- shaped exactly like @/var/lib/hamsterdan@, built from the real schemas
-- (@pi_a2_bodies@, @pi_operations@, @inbox@, @agent_routes@,
-- @v5_review_requests@) and real schema-5 History record shapes, written
-- the way the reference test writes them (@json.dumps@ with its default
-- separators).
module Fixtures
  ( -- * Constants
    installation
  , repositoryId
  , pullRequest
  , repository
  , instanceName
  , reviewOperation
  , mutationOperation
  , conversationOperation
  , admittedDelivery
  , secondDelivery
  , otherPrDelivery
  , boardEntries

    -- * History
  , record
  , history

    -- * State directories
  , Changes (..)
  , defaults
  , stateDir
  , deliveries
  , rawDelivery
  , SqlValue (..)
  , database

    -- * JSON
  , dumpsDefault
  , dumpsIndent2
  , loadJson
  , member
  ) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 qualified as S
import Hamsterdan.Export (agentOperationId)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, parseJson, pythonLoads)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))

installation, repositoryId, pullRequest :: Integer
installation = 44
repositoryId = 31
pullRequest = 7

repository :: Text
repository = "hbnetwork/demo-pr-readiness"

instanceName :: Text
instanceName = "github:" <> tshow installation <> ":" <> tshow repositoryId <> ":pr:" <> tshow pullRequest

reviewOperation, mutationOperation, conversationOperation :: Text
reviewOperation = "review:" <> instanceName <> ":h1:i1"
mutationOperation = "mutation:" <> repository <> ":pr:" <> tshow pullRequest <> ":push:comment:9001:h1:i1"
conversationOperation = "conversation:" <> repository <> ":pr:" <> tshow pullRequest <> ":delivery:" <> admittedDelivery

admittedDelivery, secondDelivery, otherPrDelivery :: Text
admittedDelivery = "0ad296b0-a66f-11f1-8280-881304021cbb"
secondDelivery = "1be2f540-a66f-11f1-87d6-f8c096b92398"
otherPrDelivery = "2cf30a10-a66f-11f1-9a12-85ad4b6c2d00"

boardEntries :: [Text]
boardEntries =
  [ "state:{'base': 'b1', 'base_current': True, 'head': 'h1', 'mergeable': True, 'phase': 'running', 'policy': 'p1'}"
  , "checks:{'status': 'success'}"
  ]

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | @_record(kind, **fields)@.
record :: Text -> [(Text, Json)] -> Json
record kind fields = Object ([("record", String kind), ("schema", Int 5)] ++ fields)

-- | @_history()@.
history :: [Json]
history =
  [ record "InstanceCreated" [("instance", String instanceName), ("name", String "pr_v5"), ("instant", Int 0)]
  , record
      "ExternalEventDelivered"
      [ ("source", String "on_head")
      , ("identity", String ("v5:" <> admittedDelivery))
      , ("occurrence", Int 1)
      , ("instant", Int 1)
      , ("scope", String "/life")
      , ("tokens", Array [Object [("color", String "HeadSeen"), ("data", Object [("head", String "h1")])]])
      ]
  , reviewRequest 2 2 1
  , record
      "ActivityCompleted"
      [ ("transition", String "review.agent")
      , ("occurrence", Int 2)
      , ("instant", Int 3)
      , ("result", Object [("$variant", String "AgentReview"), ("head", String "h1")])
      ]
  , reviewRequest 3 4 2
  , record
      "ActivityCompleted"
      [ ("transition", String "review.agent")
      , ("occurrence", Int 3)
      , ("instant", Int 5)
      , ("result", Object [("$variant", String "RoundDeferred"), ("head", String "h1")])
      ]
  , record
      "ActivityRequested"
      [ ("transition", String "mut.git_gate")
      , ("activity", String "git_gate")
      , ("occurrence", Int 4)
      , ("instant", Int 5)
      , ("scope", String "/mut")
      , ("correlation", String "push:comment:9001:h1:i1")
      , ("idempotency", String "push:comment:9001:h1:i1")
      , ("policy", Object [("attempts", Int 1)])
      ,
        ( "input"
        , Object
            [ ( "work"
              , Object
                  [ ("op", String "change")
                  , ("op_key", String "push:comment:9001:h1:i1")
                  , ("head", String "h1")
                  , ("attempt", Int 0)
                  ]
              )
            ]
        )
      ]
  , dash 5 6 "DashLanded" boardEntries "d1"
  , dash 6 7 "DashLanded" (take 1 boardEntries) "d2"
  , dash 7 8 "DashDeferred" boardEntries "d3"
  ]
  where
    reviewRequest :: Integer -> Integer -> Integer -> Json
    reviewRequest occurrence instant attempt =
      record
        "ActivityRequested"
        [ ("transition", String "review.agent")
        , ("activity", String "review_agent")
        , ("occurrence", Int occurrence)
        , ("instant", Int instant)
        , ("scope", String "/review")
        , ("correlation", String reviewOperation)
        , ("idempotency", String reviewOperation)
        , ("policy", Object [("attempts", Int 1)])
        ,
          ( "input"
          , Object
              [ ( "work"
                , Object [("operation", String reviewOperation), ("head", String "h1"), ("attempt", Int attempt)]
                )
              ]
          )
        ]
    dash :: Integer -> Integer -> Text -> [Text] -> Text -> Json
    dash occurrence instant variant entries digest =
      record
        "ActivityCompleted"
        [ ("transition", String "dash.publish")
        , ("occurrence", Int occurrence)
        , ("instant", Int instant)
        , ("result", Object [("$variant", String variant), ("entries", Array (map String entries)), ("digest", String digest)])
        ]

-- | @json.dumps(value)@.
dumpsDefault :: Json -> ByteString
dumpsDefault = either (error . show) id . dumps defaultDumps

-- | @json.dumps(value, indent=2)@.
dumpsIndent2 :: Json -> ByteString
dumpsIndent2 = either (error . show) id . dumps defaultDumps {indent = Just 2}

loadJson :: ByteString -> Json
loadJson bytes = either (\e -> error ("not JSON: " <> show e)) id (parseJson pythonLoads bytes)

-- | @value[key]@ on an object.
member :: Text -> Json -> Json
member key = \case
  Object members -> maybe (error ("no member " <> T.unpack key)) id (lookup key members)
  other -> error ("not an object: " <> show other)

-- | A column value as the reference test binds it.
data SqlValue = SqlText Text | SqlInt Integer | SqlNull | SqlBlob ByteString | SqlFloat Double
  deriving stock (Show)

-- | @_database(path, schema, statement, rows)@.
database :: FilePath -> Text -> Text -> [[SqlValue]] -> IO ()
database path schema statement rows = do
  createDirectoryIfMissing True (takeDirectory path)
  db <- S.open (T.pack path)
  S.exec db schema
  S.exec db "BEGIN"
  forM_ rows $ \row -> do
    prepared <- S.prepare db statement
    S.bind prepared (map toSql row)
    _ <- S.step prepared
    S.finalize prepared
  S.exec db "COMMIT"
  S.close db
  where
    toSql = \case
      SqlText t -> S.SQLText t
      SqlInt i -> S.SQLInteger (fromInteger i)
      SqlNull -> S.SQLNull
      SqlBlob b -> S.SQLBlob b
      SqlFloat d -> S.SQLFloat d

-- | The keyword arguments of the reference test's @state_dir@.
data Changes = Changes
  { history :: Maybe [Json]
  , bodies :: [Text]
  , routes :: [Text]
  , sessionless :: [Text]
  , omit :: [Text]
  }

defaults :: Changes
defaults =
  Changes
    { history = Nothing
    , bodies = [agentOperationId reviewOperation 1, agentOperationId mutationOperation 1, agentOperationId conversationOperation 1]
    , routes = [reviewOperation, mutationOperation, conversationOperation]
    , sessionless = []
    , omit = []
    }

-- | @state_dir(tmp_path, **changes)@: the state directory, @tmp/state@.
stateDir :: FilePath -> Changes -> IO FilePath
stateDir tmp changes = do
  let root = tmp </> "state"
      instanceDir = root </> "applications" </> show installation </> show repositoryId </> show pullRequest
  createDirectoryIfMissing True instanceDir
  BS.writeFile
    (instanceDir </> "binding.json")
    ( dumpsDefault
        ( Object
            [ ("instance_id", String instanceName)
            , ("pull_request", Int pullRequest)
            , ("repository", String repository)
            , ("topology", String "v5")
            ]
        )
    )
  let records = maybe history id changes.history
  BS.writeFile (instanceDir </> "history.jsonl") (BS.concat [dumpsDefault r <> "\n" | r <- records])
  let omitted name = name `elem` changes.omit
  if omitted "review-requests"
    then pure ()
    else
      database
        (instanceDir </> "review-requests.sqlite3")
        "CREATE TABLE v5_review_requests (\n                operation TEXT NOT NULL, attempt INTEGER NOT NULL CHECK(attempt >= 1),\n                request_json TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(operation, attempt))"
        "INSERT INTO v5_review_requests VALUES (?,?,?,?)"
        [ [ SqlText reviewOperation
          , SqlInt 1
          , SqlText (decode (dumpsDefault (Object [("repository", String repository), ("head", String "h1")])))
          , SqlText "rq1"
          ]
        ]
  if omitted "webhooks"
    then pure ()
    else
      database
        (root </> "webhooks.sqlite3")
        "CREATE TABLE inbox (\n                delivery_id TEXT PRIMARY KEY, event TEXT NOT NULL, observation TEXT NOT NULL,\n                status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,\n                reason TEXT, error_class TEXT, next_attempt_at REAL NOT NULL DEFAULT 0)"
        "INSERT INTO inbox(delivery_id,event,observation,status,attempts) VALUES (?,?,?,?,?)"
        [ [ SqlText admittedDelivery
          , SqlText "pull_request"
          , SqlText (decode (dumpsDefault (Object [("delivery_id", String admittedDelivery), ("action", String "opened")])))
          , SqlText "terminal"
          , SqlInt 1
          ]
        , [ SqlText secondDelivery
          , SqlText "issue_comment"
          , SqlText (decode (dumpsDefault (Object [("delivery_id", String secondDelivery), ("action", String "created")])))
          , SqlText "terminal"
          , SqlInt 1
          ]
        ]
  if omitted "agent-routes"
    then pure ()
    else
      database
        (root </> "agent-routes.sqlite3")
        "CREATE TABLE agent_routes (\n                operation TEXT PRIMARY KEY, profile TEXT NOT NULL, snapshot TEXT NOT NULL,\n                resolved INTEGER NOT NULL CHECK (resolved IN (0, 1)))"
        "INSERT INTO agent_routes VALUES (?,?,?,?)"
        [[SqlText operation, SqlText "pi-native-a2-local", SqlText "{}", SqlInt 1] | operation <- changes.routes]
  if omitted "bodies"
    then pure ()
    else do
      database
        (root </> "pi-a2" </> "runtime-host" </> "bodies.sqlite3")
        "CREATE TABLE pi_a2_bodies (\n                operation_id TEXT PRIMARY KEY,\n                output_reference TEXT, output_text TEXT,\n                continuation_reference TEXT, session_id TEXT,\n                working_binding TEXT, session_jsonl BLOB,\n                workspace_archive BLOB NOT NULL, workspace_digest TEXT NOT NULL,\n                aggregate_verified INTEGER NOT NULL CHECK (aggregate_verified IN (0, 1)))"
        "INSERT INTO pi_a2_bodies VALUES (?,?,?,?,?,?,?,?,?,?)"
        [ bodyRow operationId (if operationId `elem` changes.sessionless then SqlNull else SqlBlob "{\"role\":\"user\"}\n")
        | operationId <- changes.bodies
        ]
      database
        (root </> "pi-a2" </> "runtime-host" </> "operations.sqlite3")
        "CREATE TABLE pi_operations (\n                sequence INTEGER PRIMARY KEY AUTOINCREMENT,\n                operation_id TEXT NOT NULL UNIQUE, fingerprint TEXT NOT NULL,\n                episode_id TEXT NOT NULL, turn_id TEXT NOT NULL, phase TEXT NOT NULL,\n                outcome TEXT, accepted_appends INTEGER, termination_code TEXT,\n                output_reference TEXT, continuation_reference TEXT,\n                cleanup TEXT NOT NULL, cleanup_code TEXT NOT NULL,\n                acknowledged INTEGER NOT NULL CHECK (acknowledged IN (0, 1)))"
        "INSERT INTO pi_operations(operation_id,fingerprint,episode_id,turn_id,phase,outcome,\n                accepted_appends,termination_code,output_reference,continuation_reference,\n                cleanup,cleanup_code,acknowledged) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
        [piOperationRow operationId (operationId `elem` changes.sessionless) | operationId <- changes.bodies]
  pure root
  where
    decode = T.pack . map (toEnum . fromIntegral) . BS.unpack
    bodyRow operationId session =
      [ SqlText operationId
      , SqlText "out-ref"
      , SqlText "output text"
      , SqlNull
      , SqlText "session-1"
      , SqlNull
      , session
      , SqlBlob "archive"
      , SqlText "wd1"
      , SqlInt 1
      ]
    piOperationRow operationId cancelled =
      let outcome = if cancelled then "cancelled" else "completed"
       in [ SqlText operationId
          , SqlText "fp"
          , SqlText "ep"
          , SqlText "turn"
          , SqlText "settled"
          , SqlText outcome
          , SqlInt (if cancelled then 0 else 1)
          , SqlText (if cancelled then outcome else "turn-completed")
          , if cancelled then SqlNull else SqlText "out-ref"
          , SqlNull
          , SqlText "clean"
          , SqlText "clean"
          , SqlInt 1
          ]

-- | @deliveries(tmp_path, records, name=name)@: a directory of raw GitHub
-- delivery records, keyed by file name.
deliveries :: FilePath -> String -> [(Text, Json)] -> IO FilePath
deliveries tmp name records = do
  let directory = tmp </> name
  createDirectoryIfMissing True directory
  forM_ records $ \(fileName, payload) -> BS.writeFile (directory </> T.unpack fileName) (dumpsIndent2 payload <> "\n")
  pure directory

-- | @raw_delivery(delivery_id, event, action)@.
rawDelivery :: Text -> Text -> Text -> Json
rawDelivery deliveryId event action =
  Object
    [ ("guid", String deliveryId)
    , ("event", String event)
    , ("action", String action)
    , ("status_code", Int 202)
    ,
      ( "request"
      , Object
          [ ("headers", Object [("X-GitHub-Delivery", String deliveryId)])
          , ("payload", Object [("action", String action), ("number", Int 7)])
          ]
      )
    , ("response", Object [("headers", Object [("content-type", String "application/json")]), ("payload", String "accepted")])
    ]

-- | The exporter against the reference, as whole command lines: for every
-- case, @python -m hamsterdan.host.export@ (run in-process by
-- @differential/export_reference.py@ under the pinned upstream
-- interpreter) and the @hamsterdan-export@ binary run from sibling working
-- directories with the same arguments over the same state directory, and
-- must produce the same exit status, the same stdout, the same stderr
-- (the last traceback line, for an exception the reference does not
-- catch) and the same package tree, byte for byte — including the partial
-- package a failure part-way leaves behind.
--
-- The state directories are the upstream test suite's own fixtures (built
-- by the reference's helpers) and hostile variants of them built here:
-- malformed bindings and History, values of the wrong type everywhere the
-- reference reads one, unreadable and mistyped stores, WAL sidecars,
-- undecodable text, credential-named files, symbolic links, and raw
-- delivery directories with every file-name edge the classifier meets.
module DifferentialSpec (spec) where

import Control.Exception (bracket_)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite3 qualified as S
import Fixtures
import Petrus.Json (Json (..), compact, dumps, parseJson, pythonLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , findExecutable
  , listDirectory
  , pathIsSymbolicLink
  , removeFile
  )
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Process.Typed
import Test.Hspec

-- | One differential case: the state it runs over and the argument
-- vector both sides receive (relative to the case's working directories).
data Case = Case
  { name :: String
  , setup :: Setup
  , argv :: [Text]
  , columns :: Maybe Int
  }

data Setup
  = -- | The reference test suite's own fixture, by variant name.
    Upstream String
  | -- | The default fixture, then these changes.
    Built (FilePath -> IO ())
  | -- | Nothing at all.
    Empty

standard :: [Text]
standard = ["--state-dir", "../state", "--out", "pkg", "--repository", repository, "--pull-request", "7"]

upstreamCases :: [Case]
upstreamCases =
  [ Case ("upstream " <> variant) (Upstream variant) standard (Just 80)
  | variant <-
      [ "default"
      , "sessionless"
      , "orphan"
      , "repeated"
      , "newer"
      , "omit-bodies"
      , "omit-webhooks"
      , "omit-agent-routes"
      , "omit-review-requests"
      ]
  ]
    ++ [ Case
           "upstream deliveries, repeated directory spellings and identity files"
           (Upstream "deliveries")
           ( standard
               ++ [ "--webhook-deliveries=../deliveries"
                  , "--webhook-deliveries"
                  , "../deliveries/"
                  , "--identity"
                  , "../state/applications/44/31/7/binding.json"
                  , "--iden=../deliveries/secret.pem"
                  , "--identity"
                  , "../state/applications/44/31/7/history.jsonl"
                  ]
           )
           (Just 80)
       , Case
           "upstream deliveries, missing webhooks store"
           (Upstream "deliveries")
           (standard ++ ["--webhook-deliveries", "../deliveries", "--webhook-deliveries", "../absent"])
           (Just 80)
       ]

-- ---------------------------------------------------------------------------
-- Hostile state directories

instanceDir :: FilePath -> FilePath
instanceDir root = root </> "state" </> "applications" </> "44" </> "31" </> "7"

writeHistory :: FilePath -> [ByteString] -> IO ()
writeHistory root lines' = BS.writeFile (instanceDir root </> "history.jsonl") (BS.concat [l <> "\n" | l <- lines'])

historyWith :: [Json] -> FilePath -> IO ()
historyWith records root = writeHistory root (map dumpsDefault records)

bindingWith :: ByteString -> FilePath -> IO ()
bindingWith bytes root = BS.writeFile (instanceDir root </> "binding.json") bytes

sql :: FilePath -> Text -> IO ()
sql path statement = do
  db <- S.open (T.pack path)
  S.exec db statement
  S.close db

bodiesPath, operationsPath, webhooksPath, routesPath :: FilePath -> FilePath
bodiesPath root = root </> "state" </> "pi-a2" </> "runtime-host" </> "bodies.sqlite3"
operationsPath root = root </> "state" </> "pi-a2" </> "runtime-host" </> "operations.sqlite3"
webhooksPath root = root </> "state" </> "webhooks.sqlite3"
routesPath root = root </> "state" </> "agent-routes.sqlite3"

reviewRequested :: [(Text, Json)] -> Json
reviewRequested work =
  record
    "ActivityRequested"
    [ ("transition", String "review.agent")
    , ("activity", String "review_agent")
    , ("occurrence", Int 2)
    , ("input", Object [("work", Object work)])
    ]

dashLanded :: Json -> Json
dashLanded entries =
  record "ActivityCompleted" [("occurrence", Int 5), ("result", Object [("$variant", String "DashLanded"), ("entries", entries)])]

hostileCases :: [Case]
hostileCases =
  [ hostile "binding is not JSON" (bindingWith "{\"instance_id\": ")
  , hostile "binding is a list" (bindingWith "[1, 2]")
  , hostile "binding repository is an int" (bindingWith "{\"repository\": 5}")
  , hostile "binding names another repository" (bindingWith "{\"repository\": \"other/repo\", \"pull_request\": 7}")
  , hostile "binding pull request disagrees" (bindingWith "{\"repository\": \"HBNETWORK/Demo-PR-Readiness\", \"pull_request\": 8}")
  , hostile
      "binding pull request is a float and True-like spellings"
      (bindingWith "{\"repository\": \"hbnetwork/demo-pr-readiness\", \"pull_request\": 7.0, \"instance_id\": [1, {\"a\": null}], \"topology\": 1e300}")
  , hostile "binding has no instance id" (bindingWith "{\"repository\": \"hbnetwork/demo-pr-readiness\", \"pull_request\": 7}")
  , hostile "binding has a BOM" (bindingWith "\xEF\xBB\xBF{}")
  , hostile "binding is not UTF-8" (bindingWith "{\"repository\": \"\xFF\"}")
  , hostile "binding uses CRLF and a duplicate key" $
      bindingWith
        "{\r\n\"repository\": \"x\", \"repository\": \"hbnetwork/demo-pr-readiness\",\r\n \"pull_request\": 7, \"instance_id\": \"i\\u00e9\"}"
  , hostile "binding is a directory" $ \root -> do
      removeFile (instanceDir root </> "binding.json")
      createDirectoryIfMissing True (instanceDir root </> "binding.json")
  , hostile "binding is a dangling symbolic link" $ \root -> do
      removeFile (instanceDir root </> "binding.json")
      createSymbolicLink "nowhere.json" (instanceDir root </> "binding.json")
  , hostile "two Instances bind the PR" $ \root -> do
      let other = root </> "state" </> "applications" </> "45" </> "31" </> "7"
      createDirectoryIfMissing True other
      BS.readFile (instanceDir root </> "binding.json") >>= BS.writeFile (other </> "binding.json")
  , hostile "an installation directory that is not a number" $ \root -> do
      let other = root </> "state" </> "applications" </> " \x0664\x0665_6 " </> "x1" </> "7"
      createDirectoryIfMissing True other
      BS.readFile (instanceDir root </> "binding.json") >>= BS.writeFile (other </> "binding.json")
  , hostile "Unicode installation digits are a number" $ \root -> do
      let other = root </> "state" </> "applications" </> "\x0664\x0665" </> "+3_1" </> "7"
      createDirectoryIfMissing True other
      BS.readFile (instanceDir root </> "binding.json") >>= BS.writeFile (other </> "binding.json")
      removeFile (instanceDir root </> "binding.json")
  , hostile "a regular file where an installation directory goes" $ \root -> do
      BS.writeFile (root </> "state" </> "applications" </> "46") "not a directory"
  , hostile "History is missing" $ \root -> removeFile (instanceDir root </> "history.jsonl")
  , hostile "History has blank lines and a bad line" $ \root ->
      writeHistory root [dumpsDefault (record "InstanceCreated" []), "", "   ", "{not json"]
  , hostile "History has a line that is not an object" $ \root -> writeHistory root [dumpsDefault (record "InstanceCreated" []), "[1]"]
  , hostile "History has an object with no record kind" $ \root -> writeHistory root ["{\"schema\": 5}"]
  , hostile "History is not UTF-8" $ \root -> writeHistory root ["{\"record\": \"\xC3\x28\"}"]
  , hostile "History uses CR line ends and form feeds" $ \root ->
      BS.writeFile
        (instanceDir root </> "history.jsonl")
        (BS.intercalate "\r" (map dumpsDefault history) <> "\r\n\x0c\r\n" <> dumpsDefault (record "Late" [("x", Int 1)]))
  , hostile "History has an integer past the digit limit" $ \root ->
      writeHistory root ["{\"record\": \"InstanceCreated\", \"n\": " <> BS.replicate 4400 0x37 <> "}"]
  , hostile "History has a schema list" (historyWith (history ++ [Object [("record", String "X"), ("schema", Array [])]]))
  , hostile "History has a list record kind" (historyWith (history ++ [Object [("record", Array [Int 1]), ("schema", Int 5)]]))
  , hostile "History has numeric, null and float schemas" $
      historyWith
        ( history
            ++ [ Object [("record", String "A"), ("schema", Float 5.0)]
               , Object [("record", String "B"), ("schema", Bool True)]
               , Object [("record", String "C")]
               , Object [("record", String "D"), ("schema", Float (0 / 0))]
               , Object [("record", String "E"), ("schema", Float (0 / 0))]
               ]
        )
  , hostile "History has only schema 5.0" $
      historyWith [Object [(k, if k == "schema" then Float 5.0 else v) | (k, v) <- members] | Object members <- history]
  , hostile
      "History kinds with wide characters, fields of every type, and odd tokens"
      ( historyWith
          ( history
              ++ [ record
                     "ExternalEventDelivered"
                     [ ("source", Object [("a", Array [Bool True, Null, Float 1.5, String "q'\"\x1F600"])])
                     , ("identity", Null)
                     , ("occurrence", Float 1e16)
                     , ("tokens", Array [Int 1, Object [], Object [("color", Array [])], String "x"])
                     , ("result", Object [("$variant", Null)])
                     ]
                 , record "\x4E2D\x6587\x7A2E\x985E" [("zeta", Int 1), ("alpha", String "\x00e9"), ("instant", Int 3)]
                 , record "TokensConsumed" [("place", Float (1 / 0)), ("tokens", Object [])]
                 ]
          )
      )
  , hostile "a review attempt spelled as a string, a float and a bool" $
      historyWith
        ( history
            ++ [ reviewRequested [("operation", String "review:x"), ("attempt", String " \x0663_0 ")]
               , reviewRequested [("operation", Int 5), ("attempt", Float 2.9)]
               , reviewRequested [("operation", Null), ("attempt", Bool True)]
               ]
        )
  , hostile "a review attempt that is not a number" (historyWith (history ++ [reviewRequested [("operation", String "r"), ("attempt", String "two")]]))
  , hostile "a review attempt that is a list" (historyWith (history ++ [reviewRequested [("operation", String "r"), ("attempt", Array [])]]))
  , hostile "a review attempt that is infinite" (historyWith (history ++ [reviewRequested [("operation", String "r"), ("attempt", Float (1 / 0))]]))
  , hostile "a review request with no operation" (historyWith (history ++ [reviewRequested [("attempt", Int 1)]]))
  , hostile "a git gate request with no op key" $
      historyWith (history ++ [record "ActivityRequested" [("activity", String "git_gate"), ("input", Object [("work", Object [])])]])
  , hostile "an agent request with no occurrence" $
      historyWith
        ( history
            ++ [ record
                   "ActivityRequested"
                   [("activity", String "git_gate"), ("input", Object [("work", Object [("op_key", Float 1.25)])])]
               ]
        )
  , hostile "terminals keyed by string occurrences and reasons" $
      historyWith
        ( history
            ++ [ record "ActivityFailed" [("occurrence", String "3"), ("reason", String "boom")]
               , record "ActivityTerminalQuarantined" [("occurrence", Float 3.0), ("reason", String "")]
               , record "ActivityCompleted" [("occurrence", Bool True), ("result", Object [("$variant", String "")])]
               ]
        )
  , hostile "a terminal whose occurrence is not a number" $
      historyWith (history ++ [record "ActivityFailed" [("occurrence", String "x")]])
  , hostile "landed boards whose entries are a string, a dict and values" $
      historyWith
        ( history
            ++ [ dashLanded (String "ab:{}")
               , dashLanded (Object [("checks:{'status': 'failure'}", Int 1)])
               , dashLanded (Array [Int 1, Null, Object [("k", String "v")], String "human_needed:{'reason': 'x'}"])
               ]
        )
  , hostile "a landed board whose entries are a number" (historyWith (history ++ [dashLanded (Int 3)]))
  , hostile "a landed board with no entries" $
      historyWith (history ++ [record "ActivityCompleted" [("result", Object [("$variant", String "DashLanded")])]])
  , hostile "a landed board whose entry the renderer refuses" $
      historyWith (history ++ [dashLanded (Array [String "state:{[1]: 2}"])])
  , hostile "agent routes is not a database" $ \root -> BS.writeFile (routesPath root) "this is not SQLite at all, not even close......"
  , hostile "agent routes is empty" $ \root -> BS.writeFile (routesPath root) ""
  , hostile "agent routes is a directory" $ \root -> do
      removeFile (routesPath root)
      createDirectoryIfMissing True (routesPath root)
  , hostile "agent routes lacks a column" $ \root -> do
      sql (routesPath root) "ALTER TABLE agent_routes RENAME COLUMN resolved TO settled"
  , hostile "agent routes holds blob, integer and duplicate operations" $ \root -> do
      sql (routesPath root) "CREATE TABLE r2 AS SELECT * FROM agent_routes; DROP TABLE agent_routes; CREATE TABLE agent_routes (operation, profile, snapshot, resolved)"
      sql (routesPath root) "INSERT INTO agent_routes VALUES (x'6162', 'p', '{}', 1), (7, 'p', '{}', 0), ('conversation:z', 'p', '{}', 1), ('conversation:z', 'p', '{}', 1), (NULL, 'p', '{}', 1), (2.5, 'p', '{}', 1)"
  , hostile "agent routes holds text that is not UTF-8" $ \root ->
      sql (routesPath root) "INSERT INTO agent_routes VALUES (CAST(x'61ff00626364' AS TEXT), 'p', '{}', 1)"
  , hostile "a body whose session is text" $ \root ->
      sql (bodiesPath root) "UPDATE pi_a2_bodies SET session_jsonl = 'text session'"
  , hostile "a body whose session is an empty blob, a zero and a float" $ \root -> do
      sql (bodiesPath root) "CREATE TABLE b2 AS SELECT * FROM pi_a2_bodies; DROP TABLE pi_a2_bodies; CREATE TABLE pi_a2_bodies (operation_id, output_reference, output_text, continuation_reference, session_id, working_binding, session_jsonl, workspace_archive, workspace_digest, aggregate_verified)"
      sql (bodiesPath root) "INSERT INTO pi_a2_bodies SELECT * FROM b2; DROP TABLE b2"
      sql (bodiesPath root) "UPDATE pi_a2_bodies SET session_jsonl = x'' WHERE rowid = 1; UPDATE pi_a2_bodies SET session_jsonl = 0 WHERE rowid = 2; UPDATE pi_a2_bodies SET session_jsonl = 0.0, output_text = 1e308, aggregate_verified = -9223372036854775808 WHERE rowid = 3"
  , hostile "a body whose output is a blob" $ \root ->
      sql (bodiesPath root) "UPDATE pi_a2_bodies SET output_text = x'00ff' WHERE rowid = 2"
  , hostile "a body with a malformed operation id" $ \root ->
      sql (bodiesPath root) "UPDATE pi_a2_bodies SET operation_id = 'pi:has space' WHERE rowid = 3"
  , hostile "a body with an overlong and an empty operation id" $ \root -> do
      sql (bodiesPath root) ("UPDATE pi_a2_bodies SET operation_id = '" <> T.replicate 257 "a" <> "' WHERE rowid = 3")
  , hostile "a body keyed by a blob operation id" $ \root -> do
      sql (bodiesPath root) "CREATE TABLE b2 AS SELECT * FROM pi_a2_bodies; DROP TABLE pi_a2_bodies; CREATE TABLE pi_a2_bodies (operation_id, output_reference, output_text, continuation_reference, session_id, working_binding, session_jsonl, workspace_archive, workspace_digest, aggregate_verified)"
      sql (bodiesPath root) "INSERT INTO pi_a2_bodies SELECT * FROM b2; DROP TABLE b2; UPDATE pi_a2_bodies SET operation_id = x'70693a7a' WHERE rowid = 3"
  , hostile "Pi operations with null outcome and a cancelled turn" $ \root -> do
      sql (operationsPath root) "UPDATE pi_operations SET outcome = NULL WHERE sequence = 1; UPDATE pi_operations SET outcome = 'cancelled', termination_code = NULL, accepted_appends = NULL WHERE sequence = 2"
      sql (bodiesPath root) "UPDATE pi_a2_bodies SET session_jsonl = NULL"
  , hostile "Pi operations lack their table" $ \root -> sql (operationsPath root) "DROP TABLE pi_operations"
  , hostile "review requests hold blob JSON, a BOM and a float attempt" $ \root -> do
      let path = instanceDir root </> "review-requests.sqlite3"
      sql path "CREATE TABLE q2 AS SELECT * FROM v5_review_requests; DROP TABLE v5_review_requests; CREATE TABLE v5_review_requests (operation, attempt, request_json, digest)"
      sql path ("INSERT INTO v5_review_requests VALUES ('" <> reviewOperation <> "', 1.0, x'efbbbf7b2261223a20317d', x'00'), ('" <> reviewOperation <> "', '2', '[1, 2.50, \"\\u00e9\"]', NULL)")
  , hostile "review requests hold JSON that does not parse" $ \root -> do
      let path = instanceDir root </> "review-requests.sqlite3"
      sql path "UPDATE v5_review_requests SET request_json = '{\"a\": tru}'"
  , hostile "review requests hold a non-text JSON column" $ \root -> do
      let path = instanceDir root </> "review-requests.sqlite3"
      sql path "CREATE TABLE q2 AS SELECT * FROM v5_review_requests; DROP TABLE v5_review_requests; CREATE TABLE v5_review_requests (operation, attempt, request_json, digest)"
      sql path ("INSERT INTO v5_review_requests VALUES ('" <> reviewOperation <> "', 1, 42, 'd')")
  , hostile "review requests hold an attempt that is not a number" $ \root -> do
      let path = instanceDir root </> "review-requests.sqlite3"
      sql path "CREATE TABLE q2 AS SELECT * FROM v5_review_requests; DROP TABLE v5_review_requests; CREATE TABLE v5_review_requests (operation, attempt, request_json, digest)"
      sql path "INSERT INTO v5_review_requests VALUES ('r', 'one', '{}', 'd')"
  , hostile "the inbox holds an observation that does not parse" $ \root ->
      sql (webhooksPath root) "INSERT INTO inbox(delivery_id,event,observation,status,attempts) VALUES ('zz', 'push', '{\"broken\": ', 'pending', 0)"
  , hostile "the inbox holds text that is not UTF-8" $ \root ->
      sql (webhooksPath root) "UPDATE inbox SET reason = CAST(x'e282' AS TEXT) WHERE rowid = 2"
  , hostile "the inbox holds a blob event and a null observation" $ \root -> do
      sql (webhooksPath root) "CREATE TABLE i2 AS SELECT * FROM inbox; DROP TABLE inbox; CREATE TABLE inbox (delivery_id, event, observation, status, attempts, reason, error_class)"
      sql (webhooksPath root) "INSERT INTO inbox SELECT delivery_id, event, observation, status, attempts, reason, error_class FROM i2; DROP TABLE i2"
      sql (webhooksPath root) "INSERT INTO inbox VALUES ('ab', x'01', '1', 's', 0, NULL, NULL), ('cd', 'e', NULL, 's', 0, NULL, NULL)"
  , hostile "the inbox holds case-folded and Unicode delivery ids" $ \root -> do
      sql (webhooksPath root) ("UPDATE inbox SET delivery_id = upper(delivery_id) WHERE rowid = 1")
      sql (webhooksPath root) "INSERT INTO inbox(delivery_id,event,observation,status,attempts) VALUES ('\x0391\x03A3 \x03A3x \x0130', 'push', '{\"\\u00e9\": [1e400, -0.0, 1E+2]}', 'pending', 0), ('0aD296B0-A66F-11F1-8280-881304021CBB', 'dup', '{}', 'done', 2)"
  , hostile "the inbox lives in a WAL that was never checkpointed" $ \root -> walInbox root
  , hostile "the webhook store is a directory" $ \root -> do
      removeFile (webhooksPath root)
      createDirectoryIfMissing True (webhooksPath root)
  , hostile "the state directory holds credential-named files, links and hidden directories" $ \root -> do
      let state = root </> "state"
      createDirectoryIfMissing True (state </> ".hidden" </> "deep")
      BS.writeFile (state </> ".hidden" </> "deep" </> "API-KEY.txt") "x"
      BS.writeFile (state </> ".env") "x"
      BS.writeFile (state </> "Cert.PEM") "x"
      BS.writeFile (state </> "my.Secret.json") "x"
      BS.writeFile (state </> "image.txt") "sha-1"
      BS.writeFile (state </> "pins.md") "pins"
      createDirectoryIfMissing True (state </> "tokens.d")
      createDirectoryIfMissing True (root </> "outside")
      BS.writeFile (root </> "outside" </> "privatekey") "x"
      createSymbolicLink (root </> "outside") (state </> "linked-dir")
      createSymbolicLink (root </> "outside" </> "privatekey") (state </> "credential-link")
      createSymbolicLink (state </> "missing") (state </> "token-dangling")
  , hostile "the state directory has an unreadable directory" $ \root -> do
      let locked = root </> "state" </> "locked"
      createDirectoryIfMissing True locked
      BS.writeFile (locked </> "secret") "x"
      setFileMode locked 0o000
  ]
    ++ argvCases
  where
    hostile name change = Case name (Built change) standard (Just 80)

-- | A webhook store whose rows are still in its @-wal@ sidecar.
walInbox :: FilePath -> IO ()
walInbox root = do
  let path = webhooksPath root
      scratch = root </> "wal-scratch.sqlite3"
  BS.readFile path >>= BS.writeFile scratch
  db <- S.open (T.pack scratch)
  S.exec db "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0"
  S.exec db "INSERT INTO inbox(delivery_id,event,observation,status,attempts) VALUES ('wal-row', 'push', '{\"wal\": true}', 'pending', 0)"
  BS.readFile scratch >>= BS.writeFile path
  BS.readFile (scratch <> "-wal") >>= BS.writeFile (path <> "-wal")
  BS.readFile (scratch <> "-shm") >>= BS.writeFile (path <> "-shm")
  S.close db

-- | Argument vectors: help at several widths, every parser error, and the
-- refusals that need no state.
argvCases :: [Case]
argvCases =
  [Case ("help at " <> show width <> " columns") Empty ["--help"] (Just width) | width <- [1, 20, 40, 60, 80, 100, 200]]
    ++ [ Case "no arguments" Empty [] (Just 80)
       , Case "no arguments, narrow" Empty [] (Just 30)
       , Case "a missing required option" Empty ["--state-dir", "s", "--out", "o", "--repository", "r"] (Just 80)
       , Case "an invalid pull request" Empty ["--state-dir", "s", "--out", "o", "--repository", "r", "--pull-request", "7.5"] (Just 80)
       , Case "an ambiguous abbreviation" Empty ["--state-dir", "s", "--out", "o", "--repository", "r", "--pull-request", "7", "--i", "x"] (Just 80)
       , Case "an unrecognized argument" Empty (standard ++ ["extra", "--nope"]) (Just 80)
       , Case "an option missing its value" Empty ["--state-dir"] (Just 80)
       , Case "a negative pull request" (Built (const (pure ()))) ["--state-dir", "../state", "--out", "pkg", "--repository", repository, "--pull-request=-7"] (Just 80)
       , Case "abbreviated options and a spaced pull request" (Built (const (pure ()))) ["--st", "../state//.", "--o=./pkg/", "--rep", T.toUpper repository, "--pull", " 0_7 "] (Just 80)
       , Case "a missing state directory" Empty standard (Just 80)
       , Case "an output path that is a file" (Built (const (pure ()))) ["--state-dir", "../state", "--out", "../state/applications/44/31/7/binding.json", "--repository", repository, "--pull-request", "7"] (Just 80)
       , Case "an output directory with nested parents" (Built (const (pure ()))) ["--state-dir", "../state", "--out", "a/b/c", "--repository", repository, "--pull-request", "7"] (Just 80)
       , Case "a missing identity file" (Built (const (pure ()))) (standard ++ ["--identity", "../absent.txt"]) (Just 80)
       , Case "an identity file named like a credential" (Built (const (pure ()))) (standard ++ ["--identity", "../absent.key", "--identity", "/"]) (Just 80)
       , Case "a delivery directory with every name edge" (Built deliveryEdges) (standard ++ ["--webhook-deliveries", "../d1", "--webhook-deliveries", "../d2"]) (Just 80)
       ]

deliveryEdges :: FilePath -> IO ()
deliveryEdges root = do
  let d1 = root </> "d1"
      d2 = root </> "d2"
      upper = T.toUpper admittedDelivery
  createDirectoryIfMissing True d1
  createDirectoryIfMissing True d2
  let write dir name = BS.writeFile (dir </> name) ("{\"name\": " <> dumpsDefault (String (T.pack name)) <> "}\n")
  write d1 (T.unpack admittedDelivery <> "-pull_request.json")
  write d1 (T.unpack upper <> "-issue_comment.JSON")
  write d1 (T.unpack admittedDelivery <> "-long-\x017F.j\x017Fon")
  write d1 (T.unpack admittedDelivery <> "-line\nbreak.json")
  write d1 (T.unpack admittedDelivery <> "-.json")
  write d1 (T.unpack admittedDelivery <> "-x.json.bak")
  write d1 (T.unpack otherPrDelivery <> "-push.json")
  write d1 "not-a-delivery.json"
  write d1 ".hidden.json"
  createDirectoryIfMissing True (d1 </> T.unpack secondDelivery <> "-dir.json")
  createSymbolicLink (d1 </> T.unpack otherPrDelivery <> "-push.json") (d1 </> T.unpack secondDelivery <> "-linked.json")
  write d2 (T.unpack admittedDelivery <> "-pull_request.json")
  write d2 (T.unpack otherPrDelivery <> "-again.json")

-- ---------------------------------------------------------------------------
-- Running both sides

data Outcome = Outcome {code :: Int, out :: Text, err :: Text}
  deriving stock (Eq, Show)

-- | A directory tree as (relative path, contents) pairs, directories with
-- 'Nothing'.
type Tree = [(FilePath, Maybe ByteString)]

treeOf :: FilePath -> IO Tree
treeOf root = do
  present <- doesDirectoryExist root
  if not present then pure [] else walk ""
  where
    walk relative = do
      names <- sort <$> listDirectory (root </> relative)
      fmap concat . forM names $ \name -> do
        let path = if null relative then name else relative </> name
        link <- pathIsSymbolicLink (root </> path)
        directory <- doesDirectoryExist (root </> path)
        if directory && not link
          then ((path, Nothing) :) <$> walk path
          else (\bytes -> [(path, Just bytes)]) <$> BS.readFile (root </> path)

prepare :: FilePath -> FilePath -> Case -> IO ()
prepare repo caseRoot theCase = do
  createDirectoryIfMissing True (caseRoot </> "py")
  createDirectoryIfMissing True (caseRoot </> "hs")
  case theCase.setup of
    Empty -> pure ()
    Upstream variant -> do
      python <- upstreamPythonExecutable "hamsterdan"
      let script = repo </> "packages" </> "hamsterdan-export" </> "differential" </> "export_reference.py"
      runProcess_ (proc python ["-I", "-B", script, "fixture", caseRoot, variant])
    Built change -> do
      _ <- stateDir caseRoot defaults
      change caseRoot

runReference :: FilePath -> [(FilePath, Case)] -> IO [Outcome]
runReference repo cases = do
  python <- upstreamPythonExecutable "hamsterdan"
  let script = repo </> "packages" </> "hamsterdan-export" </> "differential" </> "export_reference.py"
      input =
        Array
          [ Object
              [ ("cwd", String (T.pack (caseRoot </> "py")))
              , ("argv", Array (map String c.argv))
              , ("columns", maybe Null (Int . toInteger) c.columns)
              ]
          | (caseRoot, c) <- cases
          ]
      payload = either (error . show) id (dumps compact input)
  (status, stdoutBytes, stderrBytes) <-
    readProcess (setStdin (byteStringInput (BL.fromStrict payload)) (proc python ["-I", "-B", script, "run"]))
  unless (status == ExitSuccess) $ expectationFailure ("the reference driver failed: " <> show stderrBytes)
  case parseJson pythonLoads (BL.toStrict stdoutBytes) of
    Right (Array results) -> pure (map outcomeOf results)
    other -> fail ("unreadable reference results: " <> show other)
  where
    outcomeOf = \case
      Object members ->
        Outcome
          { code = case lookup "code" members of
              Just (Int n) -> fromInteger n
              Just Null -> 0
              _ -> -1
          , out = textOf (lookup "stdout" members)
          , err = textOf (lookup "stderr" members)
          }
      _ -> Outcome (-1) "" ""
    textOf = \case
      Just (String text) -> text
      _ -> ""

exportBinary :: IO FilePath
exportBinary = do
  override <- lookupEnv "HAMSTERDAN_EXPORT"
  found <- maybe (findExecutable "hamsterdan-export") (pure . Just) override
  maybe (fail "hamsterdan-export is not on PATH (cabal test puts it there; or set HAMSTERDAN_EXPORT)") pure found

runPort :: FilePath -> FilePath -> Case -> IO Outcome
runPort binary caseRoot theCase = do
  inherited <- getEnvironment
  let environment =
        [(k, v) | (k, v) <- inherited, k /= "COLUMNS", k /= "GHCRTS"]
          ++ [("GHCRTS", "-M2G")]
          ++ [("COLUMNS", show n) | Just n <- [theCase.columns]]
      config =
        setWorkingDir (caseRoot </> "hs") $
          setEnv environment (proc binary (map T.unpack theCase.argv))
  (status, outBytes, errBytes) <- readProcess config
  pure
    Outcome
      { code = case status of
          ExitSuccess -> 0
          ExitFailure n -> n
      , out = TE.decodeUtf8 (BL.toStrict outBytes)
      , err = TE.decodeUtf8 (BL.toStrict errBytes)
      }

-- | Undo what a case did to permissions so the temporary root can go.
unlock :: FilePath -> IO ()
unlock caseRoot = do
  let locked = caseRoot </> "state" </> "locked"
  present <- doesDirectoryExist locked
  when present $ setFileMode locked 0o755

spec :: Spec
spec = describe "differential: python -m hamsterdan.host.export" $ do
  let cases = upstreamCases ++ hostileCases
  it ("matches the reference on " <> show (length cases) <> " command lines, package trees included") $
    withSystemTempDirectory "hamsterdan-export-differential" $ \tmp -> do
      repo <- repoRoot
      binary <- exportBinary
      let rooted = [(tmp </> ("case-" <> show index), c) | (index, c) <- zip [1 :: Int ..] cases]
      bracket_ (pure ()) (mapM_ (unlock . fst) rooted) $ do
        forM_ rooted (uncurry (prepare repo))
        expected <- runReference repo rooted
        failures <- fmap concat . forM (zip rooted expected) $ \((caseRoot, theCase), reference) -> do
          port <- runPort binary caseRoot theCase
          let label = theCase.name <> " (" <> caseRoot <> ")"
          referenceTree <- treeOf (caseRoot </> "py")
          portTree <- treeOf (caseRoot </> "hs")
          pure
            ( [label <> "\n--- reference ---\n" <> show reference <> "\n--- port ---\n" <> show port | port /= reference]
                ++ [label <> ": package trees differ\n" <> treeDiff referenceTree portTree | referenceTree /= portTree]
            )
        unless (null failures) $ expectationFailure (unlines failures)

treeDiff :: Tree -> Tree -> String
treeDiff reference port =
  unlines
    ( [ "only in reference: " <> p | (p, _) <- reference, p `notElem` map fst port]
        ++ ["only in port: " <> p | (p, _) <- port, p `notElem` map fst reference]
        ++ [ "differs: " <> p <> "\n  reference: " <> show (fromMaybe "" a) <> "\n  port:      " <> show (fromMaybe "" b)
           | (p, a) <- reference
           , Just b <- [lookup p port]
           , a /= b
           ]
    )

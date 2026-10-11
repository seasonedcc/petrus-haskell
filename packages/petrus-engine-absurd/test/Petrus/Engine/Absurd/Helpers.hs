-- | Small helpers shared by the Absurd Engine specs.
module Petrus.Engine.Absurd.Helpers
  ( data'
  , deliverIssue
  , deliverApproval
  , completedEvent
  , outcomeIs
  , freshRecords
  , finallyClose
  , raisesMatching
  , inOrder
  , keyFor
  , sqlOf
  , declaration
  , waitFor
  , readJsonFile
  , member
  , connections
  , doors
  , occurrenceOf
  , firstOne
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless, void)
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (activityDeclaration)
import Petrus.Activity qualified as Activity
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd.Support
import Petrus.HistoryStore.Postgres (openPostgresHistoryStore)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (Record)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.Postgres (Connection)
import Petrus.Postgres qualified as Pg
import Test.Hspec

data' :: [(Text, Json)] -> Json
data' = Object

-- | @session.deliver(INGRESS, Token(ISSUE, {"id": issue, **extra}), identity=...)@.
deliverIssue :: Engine -> Text -> [(Text, Json)] -> Text -> IO ()
deliverIssue engine issueId extra identity =
  void (Engine.deliver engine ingress [issue (data' (("id", String issueId) : extra))] identity Nothing)

-- | @session.deliver(OPERATOR, Token(APPROVAL, {"id": issue}), identity=f"approval-{issue}")@.
deliverApproval :: Engine -> Text -> IO ()
deliverApproval engine issueId =
  void (Engine.deliver engine operator [approval (data' [("id", String issueId)])] ("approval-" <> issueId) Nothing)

completedEvent :: Json -> Bool
completedEvent event = lookupMember "activity" event == Just (String "spark_work") && outcomeIs "completed" event

outcomeIs :: Text -> Json -> Bool
outcomeIs o event = lookupMember "outcome" event == Just (String o)

-- | @PostgresHistoryStore(fresh, instance).records@.
freshRecords :: Fixture -> Text -> IO [Record]
freshRecords fixture instanceId = do
  connection <- Pg.connect fixture.dsn True
  (openPostgresHistoryStore connection instanceId >>= Store.records) `finallyClose` connection

-- | Run, then close the connection (re-raising the action's failure).
finallyClose :: IO a -> Connection -> IO a
finallyClose action connection = do
  r <- try @SomeException action
  Pg.close connection
  either (ioError . userError . displayException) pure r

-- | @pytest.raises(..., match=".*".join(pieces))@ over any exception's
-- message.
raisesMatching :: IO a -> [Text] -> Expectation
raisesMatching action pieces =
  try @SomeException action >>= \case
    Right _ -> expectationFailure ("expected an exception matching " <> show pieces)
    Left e ->
      let message = T.pack (displayException e)
       in unless (inOrder pieces message) $ expectationFailure ("exception " <> show message <> " does not match " <> show pieces)

inOrder :: [Text] -> Text -> Bool
inOrder [] _ = True
inOrder (piece : rest) haystack = case T.breakOn piece haystack of
  (_, found)
    | T.null found && not (T.null piece) -> False
    | otherwise -> inOrder rest (T.drop (T.length piece) found)

-- | @f"{instance}:occurrence-{occurrence}"@.
keyFor :: Text -> Int -> Text
keyFor instanceId occurrence = instanceId <> ":occurrence-" <> T.pack (show occurrence)

sqlOf :: [Text] -> Pg.Sql
sqlOf = Pg.sql . T.concat

-- | @ActivityDeclaration(name, heartbeat_timeout=h)@.
declaration :: Text -> Integer -> Activity.ActivityDeclaration
declaration name heartbeat = either (error . T.unpack) id (activityDeclaration name (Just heartbeat))

-- | Poll a condition every 50 ms until it holds or the deadline fails the
-- example.
waitFor :: Double -> String -> IO Bool -> IO ()
waitFor seconds message condition = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop =
        condition >>= \case
          True -> pure ()
          False -> do
            now <- getMonotonicTime
            if now >= deadline then expectationFailure message else threadDelay 50000 >> loop
  loop

readJsonFile :: FilePath -> IO Json
readJsonFile p = do
  bytes <- BC.readFile p
  either (\problem -> expectationFailure problem >> ioError (userError problem)) pure (parseJson pythonLoads bytes)

member :: Text -> Json -> Json
member key value = fromMaybe Null (lookupMember key value)

-- | Fresh joined and listen connections for a raw door call.
connections :: Fixture -> IO (Connection, Connection)
connections fixture = (,) <$> Pg.connect fixture.dsn False <*> Pg.connect fixture.dsn True

-- | Every door and observation of the reference's poison and close tests,
-- as actions.
doors :: Engine -> Double -> [IO ()]
doors session waitSeconds =
  [ void (Engine.advance session)
  , void (Engine.deliver session ingress [issue (data' [("id", String "late")])] "ingress-late" Nothing)
  , Engine.seal session ingress
  , void (Engine.wait session waitSeconds)
  , void (Engine.marking session)
  , void (Engine.status session)
  , void (Engine.inFlight session)
  , void (Engine.records session)
  ]

-- | A record's occurrence, when it has one.
occurrenceOf :: Record -> Maybe Int
occurrenceOf record = case lookupMember "occurrence" (encodeRecord record) of
  Just (Int n) -> Just (fromInteger n)
  _ -> Nothing

-- | The first element (Python's @[0]@); an empty list fails the example.
firstOne :: [a] -> a
firstOne = \case
  (x : _) -> x
  [] -> error "expected at least one element"

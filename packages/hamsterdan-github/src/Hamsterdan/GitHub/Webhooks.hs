{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Authenticated, sanitized, durable webhook inbox
-- (@github_app/webhooks.py@), over the same SQLite schema.
--
-- 'receive' checks the transport envelope, verifies the HMAC-SHA256
-- signature before parsing anything, projects the payload to an
-- 'Observation', and stores only that projection. The stored text is
-- byte-identical to the reference's
-- @json.dumps(asdict(observation), separators=(",", ":"), sort_keys=True)@.
module Hamsterdan.GitHub.Webhooks
  ( -- * Observations
    Observation (..)
  , observation
  , Receipt (..)
  , Disposition (..)
  , dispositionName
  , WebhookRejected (..)
  , observationJson
  , encodeObservation
  , observationFromJson
  , parseObservation

    -- * Conversation admission
  , admitConversation

    -- * Signatures
  , sign
  , verify

    -- * The inbox
  , WebhookCustody
  , CustodyOptions (..)
  , defaultCustodyOptions
  , openCustody
  , closeCustody
  , receive
  , pending
  , hasPending
  , eligible
  , acknowledge
  , retry
  , ErrorClass (..)
  , status
  , counts
  , Failure (..)
  , failures
  , requeue

    -- * Constants
  , maxBodyBytes
  , maxCommentBytes
  , maxDeliveryAttempts
  , maxRetryDelaySeconds
  , supportedEvents
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM, unless, when)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Contracts.Readiness (AdmittedConversation (..))
import Hamsterdan.GitHub.Python
  ( PyClass (..)
  , PyFailure (..)
  , PythonFault (..)
  , canonicalUuid
  , casefold
  , get
  , getOr
  , isAscii
  , isAsciiDecimal
  , iterate'
  , lstrip
  , orEmpty
  , pyClassName
  , pyEqText
  , strip
  , subscript
  , upper
  , utf8Length
  )
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.GitHub.Routing (InstallationRegistry)
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Sqlite (Connection, SQLData (..))
import Hamsterdan.GitHub.Sqlite qualified as Db
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsText, lookupMember, parseJson, pythonLoads)

-- | @MAX_BODY_BYTES@.
maxBodyBytes :: Int
maxBodyBytes = 1048576

-- | @MAX_COMMENT_BYTES@.
maxCommentBytes :: Int
maxCommentBytes = 16384

-- | @MAX_DELIVERY_ATTEMPTS@.
maxDeliveryAttempts :: Int
maxDeliveryAttempts = 20

-- | @MAX_RETRY_DELAY_SECONDS@.
maxRetryDelaySeconds :: Int
maxRetryDelaySeconds = 300

-- | @SUPPORTED_EVENTS@.
supportedEvents :: Set Text
supportedEvents =
  Set.fromList
    [ "installation"
    , "installation_repositories"
    , "pull_request"
    , "issues"
    , "issue_comment"
    , "pull_request_review"
    , "pull_request_review_comment"
    , "pull_request_review_thread"
    , "workflow_run"
    , "check_run"
    , "check_suite"
    , "ping"
    ]

-- | @WebhookRejected@: the delivery is refused with HTTP 400 and this
-- detail.
newtype WebhookRejected = WebhookRejected Text
  deriving stock (Eq, Show)

instance Exception WebhookRejected

-- | The sanitized projection of one delivery.
--
-- Provider-derived members hold the payload's values exactly as given
-- ('Null' for an absent member or JSON @null@), as the reference's
-- unvalidated dataclass does, so the stored projection is byte-identical.
data Observation = Observation
  { deliveryId :: Text
  , event :: Text
  , action :: Json
  , installationId :: Json
  , accountId :: Json
  , repositoryId :: Json
  , repositoryFullName :: Json
  , pullRequestNumber :: Json
  , commentId :: Json
  , commentBody :: Maybe Text
  , actorId :: Json
  , actorLogin :: Json
  , actorType :: Json
  , authorAssociation :: Json
  , repositories :: [(Json, Json)]
  , attempts :: Int
  }
  deriving stock (Eq, Show)

-- | An observation with every optional member absent.
observation :: Text -> Text -> Observation
observation deliveryId event =
  Observation deliveryId event Null Null Null Null Null Null Null Nothing Null Null Null Null [] 0

data Disposition = Accepted | AcceptedTerminal | Duplicate
  deriving stock (Eq, Show)

dispositionName :: Disposition -> Text
dispositionName = \case
  Accepted -> "accepted"
  AcceptedTerminal -> "accepted_terminal"
  Duplicate -> "duplicate"

data Receipt = Receipt
  { deliveryId :: Text
  , disposition :: Disposition
  , observation :: Maybe Observation
  }
  deriving stock (Eq, Show)

-- | @asdict(observation)@ (member order irrelevant: it is stored sorted).
observationJson :: Observation -> Json
observationJson item =
  Object
    [ ("delivery_id", String item.deliveryId)
    , ("event", String item.event)
    , ("action", item.action)
    , ("installation_id", item.installationId)
    , ("account_id", item.accountId)
    , ("repository_id", item.repositoryId)
    , ("repository_full_name", item.repositoryFullName)
    , ("pull_request_number", item.pullRequestNumber)
    , ("comment_id", item.commentId)
    , ("comment_body", maybe Null String item.commentBody)
    , ("actor_id", item.actorId)
    , ("actor_login", item.actorLogin)
    , ("actor_type", item.actorType)
    , ("author_association", item.authorAssociation)
    , ("repositories", Array [Array [a, b] | (a, b) <- item.repositories])
    , ("attempts", Int (toInteger item.attempts))
    ]

-- | The stored spelling: @json.dumps(asdict(o), separators=(",", ":"),
-- sort_keys=True)@ (ASCII-escaped, NaN admitted).
encodeObservation :: Observation -> Text
encodeObservation item =
  either (const (error "observation encoding admits non-finite numbers")) id $
    dumpsText defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True} (observationJson item)

-- | @Observation(**json.loads(raw) | {"repositories": ..., "attempts": n})@.
observationFromJson :: Int -> Json -> Maybe Observation
observationFromJson attempts value = do
  let field key = maybe Null id (lookupMember key value)
  deliveryId <- case field "delivery_id" of String s -> Just s; _ -> Nothing
  event <- case field "event" of String s -> Just s; _ -> Nothing
  commentBody <- case field "comment_body" of
    String s -> Just (Just s)
    Null -> Just Nothing
    _ -> Nothing
  repositories <- case field "repositories" of
    Array items -> traverse (\case Array [a, b] -> Just (a, b); _ -> Nothing) items
    Null -> Just []
    _ -> Nothing
  Just
    Observation
      { deliveryId
      , event
      , action = field "action"
      , installationId = field "installation_id"
      , accountId = field "account_id"
      , repositoryId = field "repository_id"
      , repositoryFullName = field "repository_full_name"
      , pullRequestNumber = field "pull_request_number"
      , commentId = field "comment_id"
      , commentBody
      , actorId = field "actor_id"
      , actorLogin = field "actor_login"
      , actorType = field "actor_type"
      , authorAssociation = field "author_association"
      , repositories
      , attempts
      }

-- | @admit_conversation@: admit one provider comment and return only
-- neutral conversation values, or 'Nothing'.
admitConversation :: Text -> Text -> Observation -> Maybe AdmittedConversation
admitConversation appSlug botLoginValue item = do
  commentId <- optionalInt item.commentId
  actorId <- optionalInt item.actorId
  actorLogin <- optionalStr item.actorLogin
  actorType <- optionalStr item.actorType
  association <- optionalStr item.authorAssociation
  let text = strip (maybe "" id item.commentBody)
      mention = "@" <> appSlug
      folded = casefold text
      foldedMention = casefold mention
  unless
    ( item.event == "issue_comment"
        && pyEqText item.action "created"
        && casefold (strip (maybe "" id actorLogin)) /= casefold (strip botLoginValue)
        && actorType == Just "User"
        && upper (maybe "" id association) `elem` ["OWNER", "MEMBER", "COLLABORATOR"]
        && (folded == foldedMention || T.isPrefixOf (foldedMention <> " ") folded)
    )
    Nothing
  let addressed = if folded == foldedMention then "" else lstrip (T.drop (T.length mention + 1) text)
  Just
    AdmittedConversation
      { deliveryId = item.deliveryId
      , commentId = maybe 0 id commentId
      , actorId = maybe 0 id actorId
      , actorLogin = maybe "" id actorLogin
      , association = maybe "" id association
      , text = addressed
      }
  where
    optionalInt = \case
      Null -> Just Nothing
      Int n -> Just (Just n)
      _ -> Nothing
    optionalStr = \case
      Null -> Just Nothing
      String s -> Just (Just s)
      _ -> Nothing

-- | @"sha256=" + hex(hmac_sha256(secret, body))@.
sign :: Text -> ByteString -> Text
sign secretText body =
  let digest = hmac (TE.encodeUtf8 secretText) body :: HMAC SHA256
   in "sha256=" <> TE.decodeLatin1 (convertToBase Base16 digest)

-- | Constant-time verification of an @X-Hub-Signature-256@ value.
verify :: Text -> ByteString -> Text -> Bool
verify secretText body signature =
  constEq (TE.encodeUtf8 (sign secretText body)) (TE.encodeUtf8 signature)

-- | The project of @receive@'s headers: lowercase names, stripped values;
-- duplicate security headers and any transfer encoding are refused.
projectHeaders :: [(Text, Text)] -> Either WebhookRejected (Map Text Text)
projectHeaders = go Map.empty
  where
    go acc [] =
      if Map.member "transfer-encoding" acc
        then Left (WebhookRejected "transfer encoding is not accepted")
        else Right acc
    go acc ((name, value) : rest) =
      let key = T.toLower name
       in if Set.member key protected && Map.member key acc
            then Left (WebhookRejected "duplicate security header")
            else go (Map.insert key (strip value) acc) rest
    protected =
      Set.fromList
        [ "content-length"
        , "content-type"
        , "transfer-encoding"
        , "x-hub-signature-256"
        , "x-github-delivery"
        , "x-github-event"
        ]

-- | Options for 'openCustody'.
data CustodyOptions = CustodyOptions
  { registry :: Maybe InstallationRegistry
  , maximumBodyBytes :: Int
  , clock :: IO Double
  -- ^ Seconds since the epoch (@time.time@).
  }

defaultCustodyOptions :: IO Double -> CustodyOptions
defaultCustodyOptions = CustodyOptions Nothing maxBodyBytes

-- | @WebhookCustody@.
data WebhookCustody = WebhookCustody
  { secret :: Text
  , options :: CustodyOptions
  , connection :: Connection
  }

-- | Open (and create or migrate) the inbox at a path.
openCustody :: FilePath -> Text -> CustodyOptions -> IO WebhookCustody
openCustody path secretText options = do
  connection <- Db.open (T.pack path)
  Db.script
    connection
    "PRAGMA journal_mode=WAL;\n\
    \CREATE TABLE IF NOT EXISTS inbox (\n\
    \  delivery_id TEXT PRIMARY KEY, event TEXT NOT NULL, observation TEXT NOT NULL,\n\
    \  status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,\n\
    \  reason TEXT, error_class TEXT, next_attempt_at REAL NOT NULL DEFAULT 0);"
  columns <- Db.query connection "PRAGMA table_info(inbox)" []
  let names = [name | _ : SQLText name : _ <- columns]
  unless ("next_attempt_at" `elem` names) $
    Db.transaction connection $
      () <$ Db.execute connection "ALTER TABLE inbox ADD COLUMN next_attempt_at REAL NOT NULL DEFAULT 0" []
  pure WebhookCustody {secret = secretText, options, connection}

closeCustody :: WebhookCustody -> IO ()
closeCustody custody = Db.close custody.connection

-- | Receive one delivery.
--
-- Throws 'WebhookRejected' for every refusal the reference answers with
-- HTTP 400, and 'PythonFault' where the reference raises an uncaught
-- exception (HTTP 500): a provider value of the wrong container type where
-- it calls @.get@, or an unhashable lifecycle action.
receive :: WebhookCustody -> [(Text, Text)] -> ByteString -> IO Receipt
receive custody headers body = do
  projected <- either throwIO pure (projectHeaders headers)
  let header name = Map.lookup name projected
      reject = throwIO . WebhookRejected
  case header "content-length" of
    Just value | isAscii value, isAsciiDecimal value, read (T.unpack value) == toInteger (BS.length body) -> pure ()
    _ -> reject "content length is missing or invalid"
  when (BS.length body > custody.options.maximumBodyBytes) $ reject "request body is too large"
  when (header "content-type" /= Just "application/json") $ reject "content type is missing or unsupported"
  signature <- case header "x-hub-signature-256" of
    Just value | signatureShape value -> pure value
    _ -> reject "sha256 signature is missing or malformed"
  when (any (\name -> maybe 0 T.length (header name) > 256) ["x-github-delivery", "x-github-event", "content-type"]) $
    reject "security header is too large"
  delivery <- case header "x-github-delivery" of
    Just value | not (T.null value) -> maybe (reject "delivery id is malformed") pure (canonicalUuid value)
    _ -> pure ""
  event <- case header "x-github-event" of
    Just value | not (T.null delivery), Set.member value supportedEvents -> pure value
    _ -> reject "delivery or event is missing or unsupported"
  unless (verify custody.secret body signature) $ reject "signature verification failed"
  item <- case parseObservation delivery event body of
    Left (Left ()) -> reject "webhook envelope is malformed"
    Left (Right (PyFailure cls detail)) -> throwIO (PythonFault (pyClassName cls) detail)
    Right value -> pure value
  let encoded = encodeObservation item
  Db.withLock custody.connection $ Db.transaction custody.connection $ do
    existing <- Db.query custody.connection "SELECT 1 FROM inbox WHERE delivery_id=?" [SQLText delivery]
    if not (null existing)
      then pure (Receipt delivery Duplicate Nothing)
      else do
        _ <-
          Db.execute
            custody.connection
            "INSERT INTO inbox(delivery_id,event,observation,status) VALUES(?,?,?,'pending')"
            [SQLText delivery, SQLText event, SQLText encoded]
        if event == "installation" || event == "installation_repositories"
          then do
            applyLifecycle custody item
            _ <-
              Db.execute
                custody.connection
                "UPDATE inbox SET status='terminal',reason='routing lifecycle applied' WHERE delivery_id=?"
                [SQLText delivery]
            pure (Receipt delivery AcceptedTerminal (Just item))
          else pure (Receipt delivery Accepted (Just item))
  where
    signatureShape value =
      T.isPrefixOf "sha256=" value
        && T.length value == 71
        && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (T.drop 7 value)

applyLifecycle :: WebhookCustody -> Observation -> IO ()
applyLifecycle custody item = case custody.options.registry of
  Just registry
    | present item.installationId
    , present item.accountId
    , present item.action ->
        if item.event == "installation"
          then do
            applied <- Routing.installation registry item.action item.installationId item.accountId
            when (applied && pyEqText item.action "created") $
              () <$ Routing.repositories registry (String "added") item.installationId item.accountId item.repositories
          else () <$ Routing.repositories registry item.action item.installationId item.accountId item.repositories
  _ -> pure ()
  where
    present = \case Null -> False; _ -> True

-- | @WebhookCustody._parse@: project one verified payload, failing exactly
-- where the reference fails. 'Left (Left ())' is a refusal (the reference's
-- caught @JSONDecodeError@, @KeyError@, @TypeError@ and @ValueError@);
-- 'Left (Right failure)' is an exception the reference does not catch.
parseObservation :: Text -> Text -> ByteString -> Either (Either () PyFailure) Observation
parseObservation delivery event body = do
  value <- case Py.loadsBytes body of
    Left _ -> refused
    Right parsed@(Object _) -> Right parsed
    Right _ -> refused
  installation <- orEmpty <$> py (get "installation" value)
  repository <- orEmpty <$> py (get "repository" value)
  account <- orEmpty <$> py (get "account" installation)
  pull <- orEmpty <$> py (get "pull_request" value)
  issue <- orEmpty <$> py (get "issue" value)
  comment <- orEmpty <$> py (get "comment" value)
  actor <- do
    user <- py (get "user" comment)
    if Py.truthy user then Right user else orEmpty <$> py (get "sender" value)
  number0 <- py (get "number" pull)
  number <-
    if
      | event == "issue_comment" -> do
          linked <- py (get "pull_request" issue)
          case linked of
            Null -> Right number0
            _ -> py (get "number" issue)
      | event `elem` ["workflow_run", "check_run", "check_suite"] -> do
          container <- orEmpty <$> py (get event value)
          pulls <- py (get "pull_requests" container)
          if Py.truthy pulls
            then do
              first <- py (subscript 0 pulls)
              py (get "number" first)
            else Right Null
      | otherwise -> Right number0
  source <-
    if event == "installation_repositories"
      then do
        actionValue <- py (get "action" value)
        py (getOr (if pyEqText actionValue "added" then "repositories_added" else "repositories_removed") (Array []) value)
      else py (getOr "repositories" (Array []) value)
  items <- py (iterate' source)
  repositories <- forM items $ \item -> do
    repositoryId <- py (key "id" item)
    fullName <- py (key "full_name" item)
    Right (repositoryId, fullName)
  text <-
    if event == "issue_comment"
      then py (get "body" comment)
      else Right Null
  commentBody <- case text of
    Null -> Right Nothing
    String s | utf8Length s <= maxCommentBytes -> Right (Just s)
    _ -> refused
  let issueComment = event == "issue_comment"
      whenComment action = if issueComment then py action else Right Null
  actionValue <- py (get "action" value)
  installationId <- py (get "id" installation)
  accountId <- py (get "id" account)
  repositoryId <- py (get "id" repository)
  repositoryFullName <- py (get "full_name" repository)
  commentId <- whenComment (get "id" comment)
  actorId <- whenComment (get "id" actor)
  actorLogin <- whenComment (get "login" actor)
  actorType <- whenComment (get "type" actor)
  authorAssociation <- whenComment (get "author_association" comment)
  Right
    Observation
      { deliveryId = delivery
      , event
      , action = actionValue
      , installationId
      , accountId
      , repositoryId
      , repositoryFullName
      , pullRequestNumber = number
      , commentId
      , commentBody
      , actorId
      , actorLogin
      , actorType
      , authorAssociation
      , repositories
      , attempts = 0
      }
  where
    refused = Left (Left ())
    -- The reference catches KeyError, TypeError and ValueError as a refusal;
    -- AttributeError (and anything else) propagates.
    py = \case
      Right result -> Right result
      Left failure@(PyFailure cls _)
        | cls `elem` [KeyError, TypeError, ValueError, IndexError] -> Left (Left ())
        | otherwise -> Left (Right failure)
    -- @item[name]@.
    key name = \case
      Object members -> maybe (Left (PyFailure KeyError name)) Right (lookup name members)
      _ -> Left (PyFailure TypeError "indices must be integers")

-- | Stored observations ready for processing, in arrival order.
--
-- With a subject @(installation, repository, pull request)@, processing is
-- strict row order: an earlier deferred failure fences every later
-- observation for that subject until it is due again.
pending :: WebhookCustody -> Int -> Maybe (Integer, Integer, Integer) -> IO [Observation]
pending custody requested subject = do
  let limit = max 1 (min requested 1000)
  now <- custody.options.clock
  rows <- Db.withLock custody.connection $ case subject of
    Nothing ->
      Db.query
        custody.connection
        "SELECT observation,attempts,next_attempt_at FROM inbox WHERE status='pending' AND next_attempt_at<=? ORDER BY rowid LIMIT ?"
        [SQLFloat now, SQLInteger (fromIntegral limit)]
    Just (installationId, repositoryId, number) ->
      Db.query
        custody.connection
        "SELECT observation,attempts,next_attempt_at FROM inbox WHERE status='pending' AND json_extract(observation,'$.installation_id')=?\
        \ AND json_extract(observation,'$.repository_id')=? AND json_extract(observation,'$.pull_request_number')=? ORDER BY rowid LIMIT ?"
        [integer installationId, integer repositoryId, integer number, SQLInteger (fromIntegral limit)]
  let due = case subject of
        Nothing -> rows
        Just _ -> takeWhile (\row -> nextAttempt row <= now) rows
  forM due $ \case
    SQLText raw : SQLInteger attempts : _ ->
      case parseJson pythonLoads (TE.encodeUtf8 raw) >>= maybe (Left "observation") Right . observationFromJson (fromIntegral attempts) of
        Right item -> pure item
        Left _ -> throwIO (PythonFault "TypeError" "stored observation is malformed")
    _ -> throwIO (PythonFault "TypeError" "stored observation is malformed")
  where
    nextAttempt = \case
      [_, _, SQLFloat at] -> at
      [_, _, SQLInteger at] -> fromIntegral at
      _ -> 0

integer :: Integer -> SQLData
integer = SQLInteger . fromInteger

subjectQuery :: Text
subjectQuery =
  " AND json_extract(observation,'$.installation_id')=?\
  \ AND json_extract(observation,'$.repository_id')=?\
  \ AND json_extract(observation,'$.pull_request_number')=?"

-- | Whether the subject has any pending delivery.
hasPending :: WebhookCustody -> (Integer, Integer, Integer) -> IO Bool
hasPending custody (installationId, repositoryId, number) = Db.withLock custody.connection $ do
  rows <-
    Db.query
      custody.connection
      ("SELECT 1 FROM inbox WHERE status='pending'" <> subjectQuery <> " LIMIT 1")
      [integer installationId, integer repositoryId, integer number]
  pure (not (null rows))

-- | Whether a custodied delivery is the due head of its subject's row
-- order. Uncustodied deliveries remain eligible; a terminal or later pending
-- delivery never bypasses the earliest pending row.
eligible :: WebhookCustody -> Text -> (Integer, Integer, Integer) -> IO Bool
eligible custody deliveryId (installationId, repositoryId, number) = do
  now <- custody.options.clock
  Db.withLock custody.connection $ do
    target <- Db.query custody.connection "SELECT status FROM inbox WHERE delivery_id=?" [SQLText deliveryId]
    case target of
      [] -> pure True
      [SQLText "pending"] : _ -> do
        earliest <-
          Db.query
            custody.connection
            ("SELECT delivery_id,next_attempt_at FROM inbox WHERE status='pending'" <> subjectQuery <> " ORDER BY rowid LIMIT 1")
            [integer installationId, integer repositoryId, integer number]
        pure $ case earliest of
          [SQLText first, at] : _ -> first == deliveryId && real at <= now
          _ -> False
      _ -> pure False
  where
    real = \case
      SQLFloat at -> at
      SQLInteger at -> fromIntegral at
      _ -> 0

-- | Mark a delivery processed.
acknowledge :: WebhookCustody -> Text -> Text -> IO ()
acknowledge custody deliveryId reason = Db.withLock custody.connection $ Db.transaction custody.connection $ do
  _ <-
    Db.execute
      custody.connection
      "UPDATE inbox SET status='terminal',reason=?,error_class=NULL WHERE delivery_id=?"
      [SQLText (T.take 256 reason), SQLText deliveryId]
  pure ()

-- | The class name of a processing failure (@type(error).__name__@).
newtype ErrorClass = ErrorClass Text
  deriving stock (Eq, Show)

-- | Schedule another attempt with exponential backoff, or park the
-- delivery as failed after 'maxDeliveryAttempts'.
retry :: WebhookCustody -> Text -> ErrorClass -> IO ()
retry custody deliveryId (ErrorClass className) = Db.withLock custody.connection $ Db.transaction custody.connection $ do
  rows <- Db.query custody.connection "SELECT attempts FROM inbox WHERE delivery_id=? AND status='pending'" [SQLText deliveryId]
  case rows of
    [SQLInteger previous] : _ -> do
      let attempts = fromIntegral previous + 1 :: Int
          errorClass = SQLText (T.take 128 className)
      if attempts >= maxDeliveryAttempts
        then
          () <$ Db.execute
            custody.connection
            "UPDATE inbox SET status='failed',attempts=?,reason='attempts exhausted',error_class=? WHERE delivery_id=? AND status='pending'"
            [SQLInteger (fromIntegral attempts), errorClass, SQLText deliveryId]
        else do
          now <- custody.options.clock
          let delay = min (2 ^ (attempts - 1)) maxRetryDelaySeconds
          () <$ Db.execute
            custody.connection
            "UPDATE inbox SET attempts=?,next_attempt_at=?,error_class=? WHERE delivery_id=? AND status='pending'"
            [SQLInteger (fromIntegral attempts), SQLFloat (now + fromIntegral delay), errorClass, SQLText deliveryId]
    _ -> pure ()

-- | A delivery's status, if custodied.
status :: WebhookCustody -> Text -> IO (Maybe Text)
status custody deliveryId = Db.withLock custody.connection $ do
  rows <- Db.query custody.connection "SELECT status FROM inbox WHERE delivery_id=?" [SQLText deliveryId]
  pure $ case rows of
    [SQLText value] : _ -> Just value
    _ -> Nothing

-- | Deliveries per status.
counts :: WebhookCustody -> IO (Map Text Int)
counts custody = Db.withLock custody.connection $ do
  rows <- Db.query custody.connection "SELECT status,count(*) FROM inbox GROUP BY status" []
  pure (Map.fromList [(name, fromIntegral n) | [SQLText name, SQLInteger n] <- rows])

-- | One parked delivery.
data Failure = Failure
  { deliveryId :: Text
  , event :: Text
  , attempts :: Int
  , errorClass :: Maybe Text
  , reason :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Parked deliveries in arrival order.
failures :: WebhookCustody -> Int -> IO [Failure]
failures custody requested = do
  let limit = max 1 (min requested 1000)
  rows <-
    Db.withLock custody.connection $
      Db.query
        custody.connection
        "SELECT delivery_id,event,attempts,error_class,reason FROM inbox WHERE status='failed' ORDER BY rowid LIMIT ?"
        [SQLInteger (fromIntegral limit)]
  pure
    [ Failure deliveryId event (fromIntegral attempts) (optionalText errorClass) (optionalText reason)
    | [SQLText deliveryId, SQLText event, SQLInteger attempts, errorClass, reason] <- rows
    ]
  where
    optionalText = \case
      SQLText value -> Just value
      _ -> Nothing

-- | Return a parked delivery to the pending queue with a fresh schedule.
requeue :: WebhookCustody -> Text -> IO Bool
requeue custody deliveryId
  | canonicalUuid deliveryId /= Just deliveryId = pure False
  | otherwise = Db.withLock custody.connection $ Db.transaction custody.connection $ do
      changed <-
        Db.execute
          custody.connection
          "UPDATE inbox SET status='pending',attempts=0,next_attempt_at=0,reason=NULL,error_class=NULL WHERE delivery_id=? AND status='failed'"
          [SQLText deliveryId]
      pure (changed == 1)

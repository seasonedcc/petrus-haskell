-- | The History record family (@petrus.impetus.history@, records half).
--
-- History is the append-only record of how an instance evolves. Token
-- consumption and production are explicit records, so the marking is
-- derivable by replaying movements alone and replay never re-runs a handler.
--
-- Each record is its own plain data type, named and laid out like the
-- reference's dataclass (field order is the schema-5 wire order), and
-- 'Record' is their closed sum. The reference validates a record in its
-- constructor (@__post_init__@) and again, field by field, at the replay
-- door. Here records are plain values and both rule sets are explicit
-- functions — 'recordInvariants' (the constructor rules) and
-- 'recordFieldRules' (the replay-door rules) — applied at every door: the
-- codec, the writer, and replay. Everything the reference checks with
-- @type(x) is ...@ is enforced by the Haskell types instead.
module Petrus.Impetus.History.Records
  ( -- * Records
    InstanceCreated (..)
  , TokensInitialized (..)
  , ScopeOpened (..)
  , ScopeClosed (..)
  , ScopeReset (..)
  , CandidateSelected (..)
  , ExternalEventDelivered (..)
  , ScopedDeliveryDropped (..)
  , QuarantineScope (..)
  , ScopedDeliveryQuarantined (..)
  , DeliveryRegistration (..)
  , DeliveryRegistrationOpened (..)
  , DeliveryRegistrationClosed (..)
  , TimerMatured (..)
  , FiringBegun (..)
  , TokensConsumed (..)
  , TokensRead (..)
  , ActivityRequested (..)
  , ActivityCompleted (..)
  , ActivityFailed (..)
  , ActivityTerminalQuarantined (..)
  , TokensProduced (..)
  , FiringCompleted (..)
  , FiringFailed (..)
  , Record (..)
    -- * Generic views
  , FieldValue (..)
  , recordName
  , recordFields
  , recordInstant
  , recordOccurrence
  , recordScope
  , reprRecord
  , reprFieldValue
  , encodeFieldValue
    -- * Validation
  , recordInvariants
  , recordFieldRules
  , validateHistoryRecords
  , validateDeliveryTokens
  , reprScope
  ) where

import Control.Monad (forM_, unless, when)
import Data.IntSet qualified as IntSet
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json.Python (pythonIntRepr, pythonOptionalStrRepr, pythonRepr, pythonStrRepr, pythonTupleRepr)
import Petrus.Impetus.Petrinet.Marking (Token (..), reprTokens)
import Petrus.Impetus.Petrinet.Schema (Instant, NetPath, netPathText)
import Petrus.Impetus.Scope
import Petrus.Json

-- ---------------------------------------------------------------------------
-- Records

-- | The instance's identity fact — the first record of every history:
-- @instance@ (here 'instanceId', since @instance@ is a Haskell keyword) is
-- the unique instance id, @name@ the net definition's optional human name.
data InstanceCreated = InstanceCreated
  { instanceId :: Text
  , name :: Maybe Text
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | Initial-marking tokens entering a place before any firing.
data TokensInitialized = TokensInitialized
  { place :: NetPath
  , tokens :: [Token]
  , instant :: Instant
  , entries :: [Int]
  , scope :: Maybe LifecycleScope
  }
  deriving stock (Eq, Show)

-- | One exact lifecycle generation became active.
data ScopeOpened = ScopeOpened
  { scope :: LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | One generation closed, discarding exact queued entries and cancelling
-- exact firings.
data ScopeClosed = ScopeClosed
  { scope :: LifecycleScope
  , discarded :: [Int]
  , cancelled :: [Int]
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | Atomic close of one generation and open of its immediate successor.
data ScopeReset = ScopeReset
  { closed :: LifecycleScope
  , opened :: LifecycleScope
  , discarded :: [Int]
  , cancelled :: [Int]
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | The scheduler chose this transition's binding — the selected firing
-- occurrence's initiation record, minting its id.
data CandidateSelected = CandidateSelected
  { transition :: NetPath
  , occurrence :: Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | An external event delivered to a source transition entered the
-- history; its initiation record mints the firing occurrence's id.
data ExternalEventDelivered = ExternalEventDelivered
  { source :: NetPath
  , tokens :: [Token]
  , identity :: Text
  , occurrence :: Int
  , scope :: Maybe LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | An identified delivery proved to target a closed generation and was
-- acknowledged without firing.
data ScopedDeliveryDropped = ScopedDeliveryDropped
  { source :: NetPath
  , tokens :: [Token]
  , identity :: Text
  , scope :: LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | A quarantined delivery's target: an exact generation, or only a name.
data QuarantineScope = QuarantineGeneration LifecycleScope | QuarantineName Text
  deriving stock (Eq, Show)

-- | An identified delivery named a scope but could not prove its
-- generation.
data ScopedDeliveryQuarantined = ScopedDeliveryQuarantined
  { source :: NetPath
  , tokens :: [Token]
  , identity :: Text
  , scope :: QuarantineScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | A delivery registration's identity: a source and a caller-chosen key.
data DeliveryRegistration = DeliveryRegistration
  { source :: NetPath
  , key :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | The runtime may deliver external events to this source under this
-- registration. @occurrence@ correlates a handler-opened registration to its
-- firing; 'Nothing' is an instantiation open.
data DeliveryRegistrationOpened = DeliveryRegistrationOpened
  { source :: NetPath
  , key :: Text
  , occurrence :: Maybe Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | This registration closed. @occurrence@ 'Nothing' is runtime policy (a
-- seal).
data DeliveryRegistrationClosed = DeliveryRegistrationClosed
  { source :: NetPath
  , key :: Text
  , occurrence :: Maybe Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | A time-based enablement condition became true, observed at @instant@.
data TimerMatured = TimerMatured
  { maturationInstant :: Instant
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | The firing occurrence boundary was recorded.
data FiringBegun = FiringBegun
  { transition :: NetPath
  , occurrence :: Int
  , scope :: Maybe LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | Tokens taken from a place at begin firing.
data TokensConsumed = TokensConsumed
  { place :: NetPath
  , tokens :: [Token]
  , occurrence :: Int
  , entries :: [Int]
  , scope :: Maybe LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | Tokens a read arc selected at begin firing — observed, left in place.
-- Replay-inert for the marking.
data TokensRead = TokensRead
  { place :: NetPath
  , tokens :: [Token]
  , occurrence :: Int
  , entries :: [Int]
  , scope :: Maybe LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | An impure firing froze its exact activity request (the outbox).
data ActivityRequested = ActivityRequested
  { transition :: NetPath
  , activity :: Text
  , input :: Json
  , policy :: ExecutionPolicy
  , correlation :: Text
  , idempotency :: Text
  , occurrence :: Int
  , scope :: Maybe LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | The activity's frozen typed external result.
data ActivityCompleted = ActivityCompleted
  { transition :: NetPath
  , result :: Json
  , occurrence :: Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | The execution adapter exhausted its resolved policy.
data ActivityFailed = ActivityFailed
  { transition :: NetPath
  , error :: Text
  , kind :: Text
  , details :: Json
  , retryable :: Bool
  , retryAfter :: Maybe Number
  , occurrence :: Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | A terminal report arrived after lifecycle cancellation.
data ActivityTerminalQuarantined = ActivityTerminalQuarantined
  { transition :: NetPath
  , outcome :: Json
  , scope :: LifecycleScope
  , occurrence :: Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | Tokens deposited into a place at end firing.
data TokensProduced = TokensProduced
  { place :: NetPath
  , tokens :: [Token]
  , occurrence :: Int
  , entries :: [Int]
  , scope :: Maybe LifecycleScope
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | The firing committed its output and marking evolution.
data FiringCompleted = FiringCompleted
  { transition :: NetPath
  , occurrence :: Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | The firing occurrence ended in terminal failure.
data FiringFailed = FiringFailed
  { transition :: NetPath
  , error :: Text
  , occurrence :: Int
  , instant :: Instant
  }
  deriving stock (Eq, Show)

-- | Every record the kernel emits — the reference's @Record@ union.
data Record
  = RInstanceCreated InstanceCreated
  | RTokensInitialized TokensInitialized
  | RScopeOpened ScopeOpened
  | RScopeClosed ScopeClosed
  | RScopeReset ScopeReset
  | RCandidateSelected CandidateSelected
  | RExternalEventDelivered ExternalEventDelivered
  | RScopedDeliveryDropped ScopedDeliveryDropped
  | RScopedDeliveryQuarantined ScopedDeliveryQuarantined
  | RDeliveryRegistrationOpened DeliveryRegistrationOpened
  | RDeliveryRegistrationClosed DeliveryRegistrationClosed
  | RTimerMatured TimerMatured
  | RFiringBegun FiringBegun
  | RTokensConsumed TokensConsumed
  | RTokensRead TokensRead
  | RActivityRequested ActivityRequested
  | RActivityCompleted ActivityCompleted
  | RActivityTerminalQuarantined ActivityTerminalQuarantined
  | RTokensProduced TokensProduced
  | RFiringCompleted FiringCompleted
  | RActivityFailed ActivityFailed
  | RFiringFailed FiringFailed
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Generic views

-- | One field's value, typed by its wire family.
data FieldValue
  = FPath NetPath
  | FTokens [Token]
  | FNumber Number
  | FOccurrence (Maybe Int)
  | FText Text
  | FOptText (Maybe Text)
  | FIds [Int]
  | FOptScope (Maybe LifecycleScope)
  | FScope LifecycleScope
  | FQuarantine QuarantineScope
  | FJson Json
  | FPolicy ExecutionPolicy
  | FBool Bool
  | FOptNumber (Maybe Number)

-- | The record's type name (its wire discriminator).
recordName :: Record -> Text
recordName = \case
  RInstanceCreated _ -> "InstanceCreated"
  RTokensInitialized _ -> "TokensInitialized"
  RScopeOpened _ -> "ScopeOpened"
  RScopeClosed _ -> "ScopeClosed"
  RScopeReset _ -> "ScopeReset"
  RCandidateSelected _ -> "CandidateSelected"
  RExternalEventDelivered _ -> "ExternalEventDelivered"
  RScopedDeliveryDropped _ -> "ScopedDeliveryDropped"
  RScopedDeliveryQuarantined _ -> "ScopedDeliveryQuarantined"
  RDeliveryRegistrationOpened _ -> "DeliveryRegistrationOpened"
  RDeliveryRegistrationClosed _ -> "DeliveryRegistrationClosed"
  RTimerMatured _ -> "TimerMatured"
  RFiringBegun _ -> "FiringBegun"
  RTokensConsumed _ -> "TokensConsumed"
  RTokensRead _ -> "TokensRead"
  RActivityRequested _ -> "ActivityRequested"
  RActivityCompleted _ -> "ActivityCompleted"
  RActivityTerminalQuarantined _ -> "ActivityTerminalQuarantined"
  RTokensProduced _ -> "TokensProduced"
  RFiringCompleted _ -> "FiringCompleted"
  RActivityFailed _ -> "ActivityFailed"
  RFiringFailed _ -> "FiringFailed"

-- | The record's fields in dataclass (= wire) order.
recordFields :: Record -> [(Text, FieldValue)]
recordFields = \case
  RInstanceCreated r -> [("instance", FText r.instanceId), ("name", FOptText r.name), ("instant", FNumber r.instant)]
  RTokensInitialized r -> movement r.place r.tokens Nothing r.entries r.scope r.instant True
  RScopeOpened r -> [("scope", FScope r.scope), ("instant", FNumber r.instant)]
  RScopeClosed r ->
    [("scope", FScope r.scope), ("discarded", FIds r.discarded), ("cancelled", FIds r.cancelled), ("instant", FNumber r.instant)]
  RScopeReset r ->
    [ ("closed", FScope r.closed)
    , ("opened", FScope r.opened)
    , ("discarded", FIds r.discarded)
    , ("cancelled", FIds r.cancelled)
    , ("instant", FNumber r.instant)
    ]
  RCandidateSelected r -> [("transition", FPath r.transition), ("occurrence", occ r.occurrence), ("instant", FNumber r.instant)]
  RExternalEventDelivered r ->
    [ ("source", FPath r.source)
    , ("tokens", FTokens r.tokens)
    , ("identity", FText r.identity)
    , ("occurrence", occ r.occurrence)
    , ("scope", FOptScope r.scope)
    , ("instant", FNumber r.instant)
    ]
  RScopedDeliveryDropped r ->
    [ ("source", FPath r.source)
    , ("tokens", FTokens r.tokens)
    , ("identity", FText r.identity)
    , ("scope", FScope r.scope)
    , ("instant", FNumber r.instant)
    ]
  RScopedDeliveryQuarantined r ->
    [ ("source", FPath r.source)
    , ("tokens", FTokens r.tokens)
    , ("identity", FText r.identity)
    , ("scope", FQuarantine r.scope)
    , ("instant", FNumber r.instant)
    ]
  RDeliveryRegistrationOpened r -> registration r.source r.key r.occurrence r.instant
  RDeliveryRegistrationClosed r -> registration r.source r.key r.occurrence r.instant
  RTimerMatured r -> [("maturation_instant", FNumber r.maturationInstant), ("instant", FNumber r.instant)]
  RFiringBegun r ->
    [("transition", FPath r.transition), ("occurrence", occ r.occurrence), ("scope", FOptScope r.scope), ("instant", FNumber r.instant)]
  RTokensConsumed r -> movement r.place r.tokens (Just r.occurrence) r.entries r.scope r.instant False
  RTokensRead r -> movement r.place r.tokens (Just r.occurrence) r.entries r.scope r.instant False
  RActivityRequested r ->
    [ ("transition", FPath r.transition)
    , ("activity", FText r.activity)
    , ("input", FJson r.input)
    , ("policy", FPolicy r.policy)
    , ("correlation", FText r.correlation)
    , ("idempotency", FText r.idempotency)
    , ("occurrence", occ r.occurrence)
    , ("scope", FOptScope r.scope)
    , ("instant", FNumber r.instant)
    ]
  RActivityCompleted r ->
    [("transition", FPath r.transition), ("result", FJson r.result), ("occurrence", occ r.occurrence), ("instant", FNumber r.instant)]
  RActivityTerminalQuarantined r ->
    [ ("transition", FPath r.transition)
    , ("outcome", FJson r.outcome)
    , ("scope", FScope r.scope)
    , ("occurrence", occ r.occurrence)
    , ("instant", FNumber r.instant)
    ]
  RTokensProduced r -> movement r.place r.tokens (Just r.occurrence) r.entries r.scope r.instant False
  RFiringCompleted r -> [("transition", FPath r.transition), ("occurrence", occ r.occurrence), ("instant", FNumber r.instant)]
  RActivityFailed r ->
    [ ("transition", FPath r.transition)
    , ("error", FText r.error)
    , ("kind", FText r.kind)
    , ("details", FJson r.details)
    , ("retryable", FBool r.retryable)
    , ("retry_after", FOptNumber r.retryAfter)
    , ("occurrence", occ r.occurrence)
    , ("instant", FNumber r.instant)
    ]
  RFiringFailed r ->
    [("transition", FPath r.transition), ("error", FText r.error), ("occurrence", occ r.occurrence), ("instant", FNumber r.instant)]
  where
    occ = FOccurrence . Just
    -- TokensInitialized orders instant before entries/scope; the firing
    -- movements order occurrence, entries, scope, then instant.
    movement p ts o es s i initialized
      | initialized = [("place", FPath p), ("tokens", FTokens ts), ("instant", FNumber i), ("entries", FIds es), ("scope", FOptScope s)]
      | otherwise =
          [("place", FPath p), ("tokens", FTokens ts)]
            ++ maybe [] (\n -> [("occurrence", FOccurrence (Just n))]) o
            ++ [("entries", FIds es), ("scope", FOptScope s), ("instant", FNumber i)]
    registration s k o i = [("source", FPath s), ("key", FText k), ("occurrence", FOccurrence o), ("instant", FNumber i)]

-- | Every record's append instant.
recordInstant :: Record -> Instant
recordInstant = \case
  RInstanceCreated r -> r.instant
  RTokensInitialized r -> r.instant
  RScopeOpened r -> r.instant
  RScopeClosed r -> r.instant
  RScopeReset r -> r.instant
  RCandidateSelected r -> r.instant
  RExternalEventDelivered r -> r.instant
  RScopedDeliveryDropped r -> r.instant
  RScopedDeliveryQuarantined r -> r.instant
  RDeliveryRegistrationOpened r -> r.instant
  RDeliveryRegistrationClosed r -> r.instant
  RTimerMatured r -> r.instant
  RFiringBegun r -> r.instant
  RTokensConsumed r -> r.instant
  RTokensRead r -> r.instant
  RActivityRequested r -> r.instant
  RActivityCompleted r -> r.instant
  RActivityTerminalQuarantined r -> r.instant
  RTokensProduced r -> r.instant
  RFiringCompleted r -> r.instant
  RActivityFailed r -> r.instant
  RFiringFailed r -> r.instant

-- | The occurrence correlation of records that carry one ('Nothing' for
-- the occurrence-less categories and for uncorrelated registrations).
recordOccurrence :: Record -> Maybe Int
recordOccurrence = \case
  RInstanceCreated _ -> Nothing
  RTokensInitialized _ -> Nothing
  RScopeOpened _ -> Nothing
  RScopeClosed _ -> Nothing
  RScopeReset _ -> Nothing
  RCandidateSelected r -> Just r.occurrence
  RExternalEventDelivered r -> Just r.occurrence
  RScopedDeliveryDropped _ -> Nothing
  RScopedDeliveryQuarantined _ -> Nothing
  RDeliveryRegistrationOpened r -> r.occurrence
  RDeliveryRegistrationClosed r -> r.occurrence
  RTimerMatured _ -> Nothing
  RFiringBegun r -> Just r.occurrence
  RTokensConsumed r -> Just r.occurrence
  RTokensRead r -> Just r.occurrence
  RActivityRequested r -> Just r.occurrence
  RActivityCompleted r -> Just r.occurrence
  RActivityTerminalQuarantined r -> Just r.occurrence
  RTokensProduced r -> Just r.occurrence
  RFiringCompleted r -> Just r.occurrence
  RActivityFailed r -> Just r.occurrence
  RFiringFailed r -> Just r.occurrence

-- | The optional lifecycle scope of the provenance-carrying records.
recordScope :: Record -> Maybe LifecycleScope
recordScope = \case
  RTokensInitialized r -> r.scope
  RExternalEventDelivered r -> r.scope
  RFiringBegun r -> r.scope
  RTokensConsumed r -> r.scope
  RTokensRead r -> r.scope
  RActivityRequested r -> r.scope
  RTokensProduced r -> r.scope
  _ -> Nothing

-- | @repr(scope)@.
reprScope :: LifecycleScope -> Text
reprScope = T.pack . show

-- | A field's Python @repr@.
reprFieldValue :: FieldValue -> Text
reprFieldValue = \case
  FPath p -> T.pack (show p)
  FTokens ts -> reprTokens ts
  FNumber i -> reprNumber i
  FOccurrence o -> maybe "None" pythonIntRepr o
  FText t -> pythonStrRepr t
  FOptText t -> pythonOptionalStrRepr t
  FIds is -> pythonTupleRepr (map pythonIntRepr is)
  FOptScope s -> maybe "None" reprScope s
  FScope s -> reprScope s
  FQuarantine (QuarantineGeneration s) -> reprScope s
  FQuarantine (QuarantineName n) -> pythonStrRepr n
  FJson j -> pythonRepr j
  FPolicy p -> reprPolicy p
  FBool b -> if b then "True" else "False"
  FOptNumber n -> maybe "None" (pythonRepr . numberJson) n

reprPolicy :: ExecutionPolicy -> Text
reprPolicy policy =
  let f = policyFields policy
      num = pythonRepr . numberJson
   in "ExecutionPolicy(attempts="
        <> pythonIntRepr f.attempts
        <> ", heartbeat_timeout="
        <> pythonIntRepr f.heartbeatTimeout
        <> ", initial_interval="
        <> num f.initialInterval
        <> ", coefficient="
        <> num f.coefficient
        <> ", max_interval="
        <> num f.maxInterval
        <> ", jitter="
        <> num f.jitter
        <> ", start_to_close="
        <> maybe "None" num f.startToClose
        <> ", schedule_to_close="
        <> maybe "None" num f.scheduleToClose
        <> ")"

-- | The reference's dataclass @repr(record)@, which replay diagnostics embed.
reprRecord :: Record -> Text
reprRecord r = recordName r <> "(" <> T.intercalate ", " [k <> "=" <> reprFieldValue v | (k, v) <- recordFields r] <> ")"

-- | A field's schema-5 JSON spelling.
encodeFieldValue :: FieldValue -> Json
encodeFieldValue = \case
  FPath p -> String (netPathText p)
  FTokens ts -> Array [Object [("color", maybe Null String t.color), ("data", t.payload)] | t <- ts]
  FNumber i -> numberJson i
  FOccurrence o -> maybe Null (Int . fromIntegral) o
  FText t -> String t
  FOptText t -> maybe Null String t
  FIds is -> Array (map (Int . fromIntegral) is)
  FOptScope s -> maybe Null scopeJson s
  FScope s -> scopeJson s
  FQuarantine (QuarantineGeneration s) -> scopeJson s
  FQuarantine (QuarantineName n) -> String n
  FJson j -> j
  FPolicy p ->
    let f = policyFields p
     in Object
          [ ("attempts", Int f.attempts)
          , ("heartbeat_timeout", Int f.heartbeatTimeout)
          , ("initial_interval", numberJson f.initialInterval)
          , ("coefficient", numberJson f.coefficient)
          , ("max_interval", numberJson f.maxInterval)
          , ("jitter", numberJson f.jitter)
          , ("start_to_close", maybe Null numberJson f.startToClose)
          , ("schedule_to_close", maybe Null numberJson f.scheduleToClose)
          ]
  FBool b -> Bool b
  FOptNumber n -> maybe Null numberJson n
  where
    scopeJson s = Object [("name", String (scopeName s)), ("generation", Int (scopeGeneration s))]

-- ---------------------------------------------------------------------------
-- Validation

validateEntries :: [Token] -> [Int] -> Maybe LifecycleScope -> Text -> Either Text ()
validateEntries tokens entries scope noun = do
  when (not (null entries) && length entries /= length tokens) $
    Left (noun <> " requires one queue-entry identity per token")
  when (any (< 1) entries) $ Left (noun <> " queue-entry identities must be positive integers")
  when (IntSet.size (IntSet.fromList entries) /= length entries) $
    Left (noun <> " queue-entry identities must be unique")
  when (maybe False (const True) scope && length entries /= length tokens) $
    Left (noun <> " scoped movements require one queue-entry identity per token")
  when (not (null entries) && scope == Nothing) $
    Left (noun <> " queue-entry identities require lifecycle scope provenance")

validatePositiveIds :: [Int] -> Text -> Either Text ()
validatePositiveIds values noun = do
  when (any (< 1) values) $ Left (noun <> " must use exact positive integers")
  when (IntSet.size (IntSet.fromList values) /= length values) $ Left (noun <> " must be unique")

validateOccurrence :: Int -> Text -> Either Text ()
validateOccurrence value noun = when (value < 1) $ Left (noun <> " must be a positive integer, got " <> pythonIntRepr value)

validateDeliveryIdentity :: Text -> Text -> Either Text ()
validateDeliveryIdentity identity record =
  when (T.null identity) $ Left (record <> " requires an exact non-empty string identity, got " <> pythonStrRepr identity)

-- | The delivery records' token rules: a non-empty tuple of tokens whose
-- data is strict JSON (finite numbers).
validateDeliveryTokens :: [Token] -> Text -> Either Text ()
validateDeliveryTokens tokens record = do
  when (null tokens) $ Left (record <> " tokens must be a non-empty tuple of canonical Tokens")
  forM_ (zip [0 :: Int ..] tokens) $ \(position, t) ->
    unless (allFinite t.payload) $
      Left (record <> " token data at position " <> pythonIntRepr position <> " must be strict JSON")

-- | The reference's constructor (@__post_init__@) rules for one record.
recordInvariants :: Record -> Either Text ()
recordInvariants = \case
  RInstanceCreated _ -> Right ()
  RTokensInitialized r -> validateEntries r.tokens r.entries r.scope "TokensInitialized"
  RScopeOpened _ -> Right ()
  RScopeClosed r -> do
    validatePositiveIds r.discarded "ScopeClosed discarded queue entries"
    validatePositiveIds r.cancelled "ScopeClosed cancelled occurrences"
  RScopeReset r -> do
    when (scopeName r.opened /= scopeName r.closed || scopeGeneration r.opened /= scopeGeneration r.closed + 1) $
      Left "ScopeReset must open the immediate next generation of the same name"
    validatePositiveIds r.discarded "ScopeReset discarded queue entries"
    validatePositiveIds r.cancelled "ScopeReset cancelled occurrences"
  RCandidateSelected r -> validateOccurrence r.occurrence "CandidateSelected occurrence"
  RExternalEventDelivered r -> do
    validateOccurrence r.occurrence "ExternalEventDelivered occurrence"
    validateDeliveryIdentity r.identity "ExternalEventDelivered"
    validateDeliveryTokens r.tokens "ExternalEventDelivered"
  RScopedDeliveryDropped r -> do
    validateDeliveryIdentity r.identity "ScopedDeliveryDropped"
    validateDeliveryTokens r.tokens "ScopedDeliveryDropped"
  RScopedDeliveryQuarantined r -> do
    validateDeliveryIdentity r.identity "ScopedDeliveryQuarantined"
    validateDeliveryTokens r.tokens "ScopedDeliveryQuarantined"
    case r.scope of
      QuarantineName n
        | not (validScopeName n) -> Left "ScopedDeliveryQuarantined requires a non-empty scope name without NUL"
      _ -> Right ()
  RDeliveryRegistrationOpened r -> registration "DeliveryRegistrationOpened" r.key r.occurrence
  RDeliveryRegistrationClosed r -> registration "DeliveryRegistrationClosed" r.key r.occurrence
  RTimerMatured r ->
    when (r.instant < r.maturationInstant) $
      Left
        ( "timer maturation observed at "
            <> reprNumber r.instant
            <> ", before its maturation instant "
            <> reprNumber r.maturationInstant
            <> ": a wakeup cannot precede what it observes"
        )
  RFiringBegun r -> validateOccurrence r.occurrence "FiringBegun occurrence"
  RTokensConsumed r -> validateEntries r.tokens r.entries r.scope "TokensConsumed"
  RTokensRead r -> validateEntries r.tokens r.entries r.scope "TokensRead"
  RActivityRequested r ->
    forM_ [("activity", r.activity), ("correlation", r.correlation), ("idempotency", r.idempotency)] $ \(n, v) ->
      when (T.null v) $ Left ("ActivityRequested requires a non-empty string " <> n <> ", got ''")
  RActivityCompleted _ -> Right ()
  RActivityFailed _ -> Right ()
  RActivityTerminalQuarantined _ -> Right ()
  RTokensProduced r -> do
    validateOccurrence r.occurrence "TokensProduced occurrence"
    validateEntries r.tokens r.entries r.scope "TokensProduced"
  RFiringCompleted r -> validateOccurrence r.occurrence "FiringCompleted occurrence"
  RFiringFailed r -> do
    validateOccurrence r.occurrence "FiringFailed occurrence"
    when (T.null r.error || T.length r.error > 4096) $
      Left "FiringFailed error must be a non-empty string of at most 4096 characters"
  where
    registration noun k o = do
      when (T.null k) $
        Left (noun <> " requires a non-empty string key of the exact built-in type, got " <> pythonStrRepr k)
      forM_ o $ \n -> validateOccurrence n (noun <> " occurrence")

-- | The replay door's field-by-field rules
-- (@validate_history_record_values@), in field order.
recordFieldRules :: Record -> Either Text ()
recordFieldRules r = mapM_ (uncurry rule) (recordFields r)
  where
    typeName = recordName r
    noun n = typeName <> " " <> n
    delivery = case r of
      RExternalEventDelivered _ -> True
      RScopedDeliveryDropped _ -> True
      RScopedDeliveryQuarantined _ -> True
      _ -> False
    activityPayload n = case (r, n) of
      (RActivityRequested _, "input") -> True
      (RActivityCompleted _, "result") -> True
      (RActivityFailed _, "details") -> True
      (RActivityTerminalQuarantined _, "outcome") -> True
      _ -> False
    rule n = \case
      FOccurrence (Just o) | n == "occurrence" -> validateOccurrence o (noun n)
      FTokens ts | delivery -> validateDeliveryTokens ts typeName
      FIds is -> validatePositiveIds is (noun n)
      FText t
        | n == "instance" -> when (T.null t) $ Left ("Instance identity must be a non-empty string, got " <> pythonStrRepr t)
        | n == "identity" -> validateDeliveryIdentity t typeName
        | n == "error", RFiringFailed _ <- r ->
            when (T.null t || T.length t > 4096) $
              Left "FiringFailed error must be a non-empty string of at most 4096 characters"
        | n `elem` ["activity", "correlation", "error", "idempotency", "key", "kind"] ->
            when (T.null t) $ Left (noun n <> " must be a non-empty string")
      FJson j | activityPayload n -> unless (allFinite j) $ Left (noun n <> " must be strict JSON")
      _ -> Right ()

-- | The replay door: every record's field rules, then every record's
-- constructor rules — the reference's validate-then-reconstruct order.
validateHistoryRecords :: Foldable f => f Record -> Either Text ()
validateHistoryRecords records = do
  mapM_ recordFieldRules records
  mapM_ recordInvariants records

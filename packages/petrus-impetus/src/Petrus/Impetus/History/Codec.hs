-- | Canonical codec for schema-5 History records
-- (@petrus.impetus.history.codec@).
--
-- 'encodeRecord' spells a record as @{"record": Name, "schema": 5, ...}@
-- with every field in dataclass order. 'decodeRecord' accepts exactly the
-- canonical spelling: after reconstructing the record it re-encodes it and
-- requires the result to equal the payload (as a mapping, with the
-- reference's value equality), so a missing default, an extra member, or a
-- non-canonical value is refused.
--
-- The reference decodes leniently by type (any Python value passes into an
-- unvalidated dataclass field, e.g. a string @instant@) and leaves type
-- errors to the replay door. The Haskell record fields are typed, so such a
-- payload is refused at decode instead; every payload the reference's whole
-- load path (decode, then replay validation) accepts is accepted here, and
-- vice versa.
module Petrus.Impetus.History.Codec
  ( schemaVersion
  , encodeRecord
  , decodeRecord
  , encodeHistory
  ) where

import Control.Monad (forM_, unless)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Impetus.History.Records
import Petrus.Impetus.Internal.Repr
import Petrus.Impetus.Petrinet.Marking (Token (..))
import Petrus.Impetus.Petrinet.Schema (Instant, NetPath, netPath)
import Petrus.Impetus.Scope
import Petrus.Json

-- | The only schema this kernel writes and reads.
schemaVersion :: Integer
schemaVersion = 5

-- | Encode one field-complete record.
encodeRecord :: Record -> Json
encodeRecord r =
  Object (("record", String (recordName r)) : ("schema", Int schemaVersion) : [(k, encodeFieldValue v) | (k, v) <- recordFields r])

-- | Encode a whole history, in order.
encodeHistory :: Foldable f => f Record -> [Json]
encodeHistory = foldr ((:) . encodeRecord) []

-- | The field layout of each record type: name, and whether the reference's
-- constructor has a default for it (and if keyword-only).
data Param = Param Text Kind

data Kind = Positional | PositionalDefault | KeywordOnly | KeywordDefault

layouts :: [(Text, [Param])]
layouts =
  [ ("InstanceCreated", [Param "instance" Positional, Param "name" PositionalDefault, Param "instant" PositionalDefault])
  , ("TokensInitialized", [pos "place", pos "tokens", Param "instant" PositionalDefault, kwd "entries", kwd "scope"])
  , ("ScopeOpened", [pos "scope", Param "instant" PositionalDefault])
  , ("ScopeClosed", [pos "scope", posd "discarded", posd "cancelled", posd "instant"])
  , ("ScopeReset", [pos "closed", pos "opened", posd "discarded", posd "cancelled", posd "instant"])
  , ("CandidateSelected", [pos "transition", kw "occurrence", kwd "instant"])
  , ("ExternalEventDelivered", [pos "source", pos "tokens", kw "identity", kw "occurrence", kwd "scope", kwd "instant"])
  , ("ScopedDeliveryDropped", [pos "source", pos "tokens", kw "identity", kw "scope", kwd "instant"])
  , ("ScopedDeliveryQuarantined", [pos "source", pos "tokens", kw "identity", kw "scope", kwd "instant"])
  , ("DeliveryRegistrationOpened", [pos "source", pos "key", kw "occurrence", kwd "instant"])
  , ("DeliveryRegistrationClosed", [pos "source", pos "key", kw "occurrence", kwd "instant"])
  , ("TimerMatured", [kw "maturation_instant", kw "instant"])
  , ("FiringBegun", [pos "transition", kw "occurrence", kwd "scope", kwd "instant"])
  , ("TokensConsumed", movement)
  , ("TokensRead", movement)
  , ( "ActivityRequested"
    , [ pos "transition"
      , kw "activity"
      , kw "input"
      , kw "policy"
      , kw "correlation"
      , kw "idempotency"
      , kw "occurrence"
      , kwd "scope"
      , kwd "instant"
      ]
    )
  , ("ActivityCompleted", [pos "transition", pos "result", kw "occurrence", kwd "instant"])
  , ("ActivityTerminalQuarantined", [pos "transition", pos "outcome", pos "scope", kw "occurrence", kwd "instant"])
  , ("TokensProduced", movement)
  , ("FiringCompleted", [pos "transition", kw "occurrence", kwd "instant"])
  , ( "ActivityFailed"
    , [ pos "transition"
      , pos "error"
      , posd "kind"
      , posd "details"
      , posd "retryable"
      , posd "retry_after"
      , kw "occurrence"
      , kwd "instant"
      ]
    )
  , ("FiringFailed", [pos "transition", pos "error", kw "occurrence", kwd "instant"])
  ]
  where
    pos n = Param n Positional
    posd n = Param n PositionalDefault
    kw n = Param n KeywordOnly
    kwd n = Param n KeywordDefault
    movement = [pos "place", pos "tokens", kw "occurrence", kwd "entries", kwd "scope", kwd "instant"]

v1Successors :: [(Text, Text)]
v1Successors =
  [ ("RegistrationOpened", "DeliveryRegistrationOpened")
  , ("RegistrationClosed", "DeliveryRegistrationClosed")
  , ("ExternalEventRecorded", "ExternalEventDelivered")
  ]

-- | Decode one field-complete schema-5 record, refusing every spelling but
-- the canonical one.
decodeRecord :: Json -> Either Text Record
decodeRecord payload = do
  members <- case payload of
    Object ms -> Right ms
    other -> Left ("cannot decode event history record: payload must be a mapping, got " <> pyJson other)
  nameValue <- maybe (Left "cannot decode event history record: payload has no 'record' discriminator") Right (lookup "record" members)
  schema <-
    maybe
      ( Left
          ( "cannot decode event history record "
              <> pyJson nameValue
              <> ": payload has no 'schema' version — this kernel writes schema 5, reads schema 5 only, and has no converter for older durable data"
          )
      )
      Right
      (lookup "schema" members)
  case schema of
    Int 5 -> Right ()
    _ ->
      Left
        ( "cannot decode event history record "
            <> pyJson nameValue
            <> ": 'schema' is "
            <> pyJson schema
            <> ", and this kernel reads schema 5 only — no migration or converter exists"
        )
  (typeName, layout) <- case nameValue of
    String n | Just l <- Map.lookup n layoutIndex -> Right (n, l)
    String n
      | Just successor <- lookup n v1Successors ->
          Left
            ( "cannot decode event history record: "
                <> pyStr n
                <> " is a schema-1 discriminator — the CV3 schema-2 migration renamed it to "
                <> pyStr successor
                <> ", and no v1 converter exists (no production histories predate the migration)"
            )
    other ->
      Left
        ( "cannot decode event history record: unknown 'record' discriminator "
            <> pyJson other
            <> " — not a record type the kernel emits"
        )
  fields <- case members of
    -- The canonical payload: the discriminators first, then exactly the
    -- constructor's parameters in field order. Every argument is present
    -- and none is unexpected, so the constructor's argument check cannot
    -- refuse; only the name-driven conversions run, in payload order.
    ("record", _) : ("schema", _) : rest
      | alignedParams layout.params rest -> do
          sequence_ (zipWith ($) layout.converters (map snd rest))
          Right rest
    _ -> do
      let fields = [(k, v) | (k, v) <- members, k /= "record", k /= "schema"]
      -- The reference converts each present field by its name first, in
      -- payload order, before the constructor sees any argument.
      forM_ fields (uncurry preconvert)
      checkArguments typeName layout.params fields
      Right fields
  record <- layout.build (Reader typeName fields)
  recordInvariants record
  unless (isCanonicalSpelling record payload) $
    Left ("cannot decode event history record " <> pyStr typeName <> ": payload is not its exact canonical schema-5 spelling")
  Right record

-- | Whether the payload is the record's canonical spelling: exactly
-- @encodeRecord record == payload@ (the reference's mapping equality), but
-- decided without building the encoding when, as on every canonical
-- payload, the members arrive in the canonical order.
--
-- Both sides have unique keys (the canonical encoding by construction, a
-- payload because a parsed object has unique members). So while the keys
-- line up position by position, a value that differs at an aligned key
-- decides the mapping comparison (the same key holds a different value on
-- each side), and keys that line up to the end with equal values are the
-- same mapping. The first misaligned key (another order, a missing or an
-- extra member) hands the whole decision to the full comparison.
isCanonicalSpelling :: Record -> Json -> Bool
isCanonicalSpelling record payload = case payload of
  Object (("record", String name) : ("schema", Int 5) : members)
    | name == recordName record -> aligned (recordFields record) members
  _ -> fullComparison
  where
    fullComparison = encodeRecord record == payload
    aligned ((key, value) : fields) ((key', value') : members)
      | key == key' = encodeFieldValue value == value' && aligned fields members
    aligned [] [] = True
    aligned _ _ = fullComparison

-- | What decoding needs to know about one record type, indexed by its
-- discriminator: its constructor parameters, the name-driven conversion of
-- each parameter, and its builder. The conversions and the builder are
-- selected by name once, here, not once per decoded record.
data Layout = Layout
  { params :: [Param]
  , converters :: [Json -> Either Text ()]
  , build :: Reader -> Either Text Record
  }

layoutIndex :: Map Text Layout
layoutIndex =
  Map.fromList
    [(name, Layout ps [preconvert key | Param key _ <- ps] (builderFor name)) | (name, ps) <- layouts]

-- | Whether a payload's members are exactly the constructor's parameters in
-- order (the canonical spelling).
alignedParams :: [Param] -> [(Text, Json)] -> Bool
alignedParams (Param name _ : ps) ((key, _) : members) = name == key && alignedParams ps members
alignedParams [] [] = True
alignedParams _ _ = False

-- | The reference's name-driven conversions (@_decoded@), run for their
-- errors.
preconvert :: Text -> Json -> Either Text ()
preconvert name
  | name `elem` ["place", "transition", "source"] = \value -> () <$ pathValue value
  | name == "tokens" = \value -> () <$ tokensValue value
  | name `elem` ["entries", "discarded", "cancelled"] = \value -> () <$ idsValue name value
  | name == "scope" = \case
      Null -> Right ()
      String _ -> Right ()
      value -> () <$ scopeValue value
  | name `elem` ["closed", "opened"] = \value -> () <$ scopeValue value
  | name == "policy" = \value -> () <$ policyValue value
  | otherwise = \_ -> Right ()

-- | The constructor's argument check: unexpected and missing arguments.
checkArguments :: Text -> [Param] -> [(Text, Json)] -> Either Text ()
checkArguments typeName params fields = do
  forM_ fields $ \(k, _) ->
    unless (any (\(Param n _) -> n == k) params) $
      Left (typeName <> ".__init__() got an unexpected keyword argument " <> pyStr k)
  let present n = isJust (lookup n fields)
      missingPositional = [n | Param n Positional <- params, not (present n)]
      missingKeyword = [n | Param n KeywordOnly <- params, not (present n)]
  unless (null missingPositional) $
    Left (typeName <> ".__init__() missing " <> countArguments missingPositional "positional")
  unless (null missingKeyword) $
    Left (typeName <> ".__init__() missing " <> countArguments missingKeyword "keyword-only")
  where
    countArguments names kindNoun =
      let quoted = map pyStr names
          listed = case quoted of
            [one] -> one
            [a, b] -> a <> " and " <> b
            _ -> T.intercalate ", " (init quoted) <> ", and " <> last quoted
          plural = if length names == 1 then "argument" else "arguments"
       in T.pack (show (length names)) <> " required " <> kindNoun <> " " <> plural <> ": " <> listed

-- ---------------------------------------------------------------------------
-- Field readers

pathValue :: Json -> Either Text NetPath
pathValue = \case
  String s -> netPath s
  other -> Left ("NetPath requires a non-empty dotted string or a NetPath, got " <> pyJson other)

tokensValue :: Json -> Either Text [Token]
tokensValue = \case
  Array items -> mapM tokenValue items
  other -> Left ("event history tokens must be a list of token mappings, got " <> pyJson other)
  where
    tokenValue = \case
      Object members -> do
        forM_ members $ \(k, _) ->
          unless (k `elem` ["color", "data"]) $ Left ("Token.__init__() got an unexpected keyword argument " <> pyStr k)
        color <- case lookup "color" members of
          Nothing -> Right Nothing
          Just Null -> Right Nothing
          Just (String c) -> Right (Just c)
          Just other -> Left ("event history token color must be a string or None, got " <> pyJson other)
        Right (Token color (maybe Null id (lookup "data" members)))
      other -> Left ("Token() argument after ** must be a mapping, not " <> jsonTypeName other)

idsValue :: Text -> Json -> Either Text [Int]
idsValue name = \case
  Array items -> mapM idValue items
  other -> Left ("event history " <> name <> " must be a list of integers, got " <> pyJson other)
  where
    idValue = \case
      Int i | i >= fromIntegral (minBound :: Int) && i <= fromIntegral (maxBound :: Int) -> Right (fromIntegral i)
      other -> Left ("event history " <> name <> " must use exact integers, got " <> pyJson other)

scopeValue :: Json -> Either Text LifecycleScope
scopeValue = \case
  Object members -> do
    forM_ members $ \(k, _) ->
      unless (k `elem` ["name", "generation"]) $
        Left ("LifecycleScope.__init__() got an unexpected keyword argument " <> pyStr k)
    nameValue <- maybe (Left "LifecycleScope.__init__() missing 1 required positional argument: 'name'") Right (lookup "name" members)
    generationValue <-
      maybe (Left "LifecycleScope.__init__() missing 1 required positional argument: 'generation'") Right (lookup "generation" members)
    n <- case nameValue of
      String s -> Right s
      _ -> Left scopeNameError
    g <- case generationValue of
      Int i -> Right i
      _ -> Left "LifecycleScope generation must be a positive integer of the exact built-in type"
    lifecycleScope n g
  other -> Left ("LifecycleScope() argument after ** must be a mapping, not " <> jsonTypeName other)

policyNames :: [Text]
policyNames =
  ["attempts", "heartbeat_timeout", "initial_interval", "coefficient", "max_interval", "jitter", "start_to_close", "schedule_to_close"]

policyValue :: Json -> Either Text ExecutionPolicy
policyValue value = do
  let refuse :: Either Text a
      refuse = Left ("cannot decode ExecutionPolicy: policy must be exactly the current exact policy fields, got " <> pyJson value)
  members <- case value of
    Object ms -> Right ms
    _ -> refuse
  unless (length members == length policyNames && all (\n -> isJust (lookup n members)) policyNames) refuse
  let member n = maybe Null id (lookup n members)
  attempts <- case member "attempts" of
    Int i -> Right i
    _ -> refuse
  heartbeat <- case member "heartbeat_timeout" of
    Int i -> Right i
    _ -> refuse
  let number n = maybe (Left ("ExecutionPolicy " <> n <> " must be a number")) Right (numberFromJson (member n))
      optionalNumber n = case member n of
        Null -> Right Nothing
        other -> maybe (Left ("ExecutionPolicy " <> n <> " must be a positive number or None")) (Right . Just) (numberFromJson other)
  initialInterval <- number "initial_interval"
  coefficient <- number "coefficient"
  maxInterval <- number "max_interval"
  jitter <- number "jitter"
  startToClose <- optionalNumber "start_to_close"
  scheduleToClose <- optionalNumber "schedule_to_close"
  executionPolicy
    ExecutionPolicyFields
      { attempts = attempts
      , heartbeatTimeout = heartbeat
      , initialInterval = initialInterval
      , coefficient = coefficient
      , maxInterval = maxInterval
      , jitter = jitter
      , startToClose = startToClose
      , scheduleToClose = scheduleToClose
      }

-- | Typed access to the decoded members of one record.
data Reader = Reader Text [(Text, Json)]

raw :: Reader -> Text -> Maybe Json
raw (Reader _ fields) n = lookup n fields

noun :: Reader -> Text -> Text
noun (Reader typeName _) n = typeName <> " " <> n

path :: Reader -> Text -> Either Text NetPath
path r n = maybe (Left (noun r n <> " is missing")) pathValue (raw r n)

tokens :: Reader -> Either Text [Token]
tokens r = maybe (Right []) tokensValue (raw r "tokens")

ids :: Reader -> Text -> Either Text [Int]
ids r n = maybe (Right []) (idsValue n) (raw r n)

instant :: Reader -> Text -> Either Text Instant
instant r n = case raw r n of
  Nothing -> Right 0
  Just (Int i) -> Right (IntNumber i)
  Just (Float d) -> Right (FloatNumber d)
  Just other -> Left (noun r n <> " must be a JSON number instant, got " <> pyJson other)

occurrenceValue :: Reader -> Either Text Int
occurrenceValue r = case raw r "occurrence" of
  Just (Int i) | i >= 1 && i <= fromIntegral (maxBound :: Int) -> Right (fromIntegral i)
  Just other -> Left (noun r "occurrence" <> " must be a positive integer, got " <> pyJson other)
  Nothing -> Left (noun r "occurrence" <> " is missing")

optionalOccurrence :: Reader -> Either Text (Maybe Int)
optionalOccurrence r = case raw r "occurrence" of
  Just Null -> Right Nothing
  Nothing -> Right Nothing
  Just _ -> Just <$> occurrenceValue r

text :: Reader -> Text -> Text -> Either Text Text
text r n fallback = case raw r n of
  Just (String s) -> Right s
  Nothing -> Right fallback
  Just other -> Left (stringError r n other)

stringError :: Reader -> Text -> Json -> Text
stringError r@(Reader typeName _) n other = case n of
  "identity" -> typeName <> " requires an exact non-empty string identity, got " <> pyJson other
  "key" -> typeName <> " requires a non-empty string key of the exact built-in type, got " <> pyJson other
  "instance" -> "Instance identity must be a non-empty string, got " <> pyJson other
  "error" | typeName == "FiringFailed" -> "FiringFailed error must be a non-empty string of at most 4096 characters"
  _ | typeName == "ActivityRequested" -> "ActivityRequested requires a non-empty string " <> n <> ", got " <> pyJson other
  _ -> noun r n <> " must use the exact built-in string type"

optionalText :: Reader -> Text -> Either Text (Maybe Text)
optionalText r n = case raw r n of
  Just Null -> Right Nothing
  Nothing -> Right Nothing
  Just (String s) -> Right (Just s)
  Just other -> Left (stringError r n other)

optionalScope :: Reader -> Either Text (Maybe LifecycleScope)
optionalScope r@(Reader typeName _) = case raw r "scope" of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just (String _) -> Left (typeName <> " requires an exact LifecycleScope generation")
  Just other -> Just <$> scopeValue other

requiredScope :: Reader -> Text -> Either Text LifecycleScope
requiredScope r@(Reader typeName _) n = case raw r n of
  Just (Object ms) -> scopeValue (Object ms)
  Just Null -> Left (exactScopeError typeName n)
  Just (String _) -> Left (exactScopeError typeName n)
  Just other -> scopeValue other
  Nothing -> Left (noun r n <> " is missing")
  where
    exactScopeError t field = case (t, field) of
      ("ScopeReset", f) -> "ScopeReset " <> f <> " requires an exact LifecycleScope generation"
      _ -> t <> " requires an exact LifecycleScope generation"

json :: Reader -> Text -> Json
json r n = maybe Null id (raw r n)

builderFor :: Text -> Reader -> Either Text Record
builderFor typeName = case typeName of
  "InstanceCreated" -> \r -> do
    identity <- text r "instance" ""
    name <- optionalText r "name"
    RInstanceCreated . InstanceCreated identity name <$> instant r "instant"
  "TokensInitialized" -> \r -> do
    p <- path r "place"
    ts <- tokens r
    i <- instant r "instant"
    es <- ids r "entries"
    s <- optionalScope r
    Right (RTokensInitialized (TokensInitialized p ts i es s))
  "ScopeOpened" -> \r -> do
    s <- requiredScope r "scope"
    RScopeOpened . ScopeOpened s <$> instant r "instant"
  "ScopeClosed" -> \r -> do
    s <- requiredScope r "scope"
    d <- ids r "discarded"
    c <- ids r "cancelled"
    RScopeClosed . ScopeClosed s d c <$> instant r "instant"
  "ScopeReset" -> \r -> do
    c <- requiredScope r "closed"
    o <- requiredScope r "opened"
    d <- ids r "discarded"
    x <- ids r "cancelled"
    RScopeReset . ScopeReset c o d x <$> instant r "instant"
  "CandidateSelected" -> \r -> do
    t <- path r "transition"
    o <- occurrenceValue r
    RCandidateSelected . CandidateSelected t o <$> instant r "instant"
  "ExternalEventDelivered" -> \r -> do
    s <- path r "source"
    ts <- tokens r
    identity <- text r "identity" ""
    o <- occurrenceValue r
    sc <- optionalScope r
    RExternalEventDelivered . ExternalEventDelivered s ts identity o sc <$> instant r "instant"
  "ScopedDeliveryDropped" -> \r -> do
    s <- path r "source"
    ts <- tokens r
    identity <- text r "identity" ""
    sc <- requiredScope r "scope"
    RScopedDeliveryDropped . ScopedDeliveryDropped s ts identity sc <$> instant r "instant"
  "ScopedDeliveryQuarantined" -> \r -> do
    s <- path r "source"
    ts <- tokens r
    identity <- text r "identity" ""
    sc <- case raw r "scope" of
      Just (String n) -> Right (QuarantineName n)
      Just Null -> Left "ScopedDeliveryQuarantined requires a non-empty scope name without NUL"
      Just other -> QuarantineGeneration <$> scopeValue other
      Nothing -> Left "ScopedDeliveryQuarantined requires a non-empty scope name without NUL"
    RScopedDeliveryQuarantined . ScopedDeliveryQuarantined s ts identity sc <$> instant r "instant"
  "DeliveryRegistrationOpened" -> \r -> do
    s <- path r "source"
    k <- text r "key" ""
    o <- optionalOccurrence r
    RDeliveryRegistrationOpened . DeliveryRegistrationOpened s k o <$> instant r "instant"
  "DeliveryRegistrationClosed" -> \r -> do
    s <- path r "source"
    k <- text r "key" ""
    o <- optionalOccurrence r
    RDeliveryRegistrationClosed . DeliveryRegistrationClosed s k o <$> instant r "instant"
  "TimerMatured" -> \r -> do
    m <- instant r "maturation_instant"
    RTimerMatured . TimerMatured m <$> instant r "instant"
  "FiringBegun" -> \r -> do
    t <- path r "transition"
    o <- occurrenceValue r
    sc <- optionalScope r
    RFiringBegun . FiringBegun t o sc <$> instant r "instant"
  "TokensConsumed" -> movement (\p ts o es sc i -> RTokensConsumed (TokensConsumed p ts o es sc i))
  "TokensRead" -> movement (\p ts o es sc i -> RTokensRead (TokensRead p ts o es sc i))
  "TokensProduced" -> movement (\p ts o es sc i -> RTokensProduced (TokensProduced p ts o es sc i))
  "ActivityRequested" -> \r -> do
    t <- path r "transition"
    a <- text r "activity" ""
    p <- policyValue (json r "policy")
    c <- text r "correlation" ""
    k <- text r "idempotency" ""
    o <- occurrenceValue r
    sc <- optionalScope r
    RActivityRequested . ActivityRequested t a (json r "input") p c k o sc <$> instant r "instant"
  "ActivityCompleted" -> \r -> do
    t <- path r "transition"
    o <- occurrenceValue r
    RActivityCompleted . ActivityCompleted t (json r "result") o <$> instant r "instant"
  "ActivityTerminalQuarantined" -> \r -> do
    t <- path r "transition"
    sc <- requiredScope r "scope"
    o <- occurrenceValue r
    RActivityTerminalQuarantined . ActivityTerminalQuarantined t (json r "outcome") sc o <$> instant r "instant"
  "FiringCompleted" -> \r -> do
    t <- path r "transition"
    o <- occurrenceValue r
    RFiringCompleted . FiringCompleted t o <$> instant r "instant"
  "ActivityFailed" -> \r -> do
    t <- path r "transition"
    e <- text r "error" ""
    k <- text r "kind" "ActivityError"
    retryable <- case raw r "retryable" of
      Nothing -> Right False
      Just (Bool b) -> Right b
      Just _ -> Left (noun r "retryable" <> " must use the exact built-in boolean type")
    retryAfter <- case raw r "retry_after" of
      Nothing -> Right Nothing
      Just Null -> Right Nothing
      Just other -> maybe (Left (noun r "retry_after" <> " must use an exact built-in number or None")) (Right . Just) (numberFromJson other)
    o <- occurrenceValue r
    RActivityFailed . ActivityFailed t e k (json r "details") retryable retryAfter o <$> instant r "instant"
  "FiringFailed" -> \r -> do
    t <- path r "transition"
    e <- text r "error" ""
    o <- occurrenceValue r
    RFiringFailed . FiringFailed t e o <$> instant r "instant"
  other -> \_ -> Left ("cannot decode event history record: unknown 'record' discriminator " <> pyStr other <> " — not a record type the kernel emits")
  where
    movement mk r = do
      p <- path r "place"
      ts <- tokens r
      o <- occurrenceValue r
      es <- ids r "entries"
      sc <- optionalScope r
      mk p ts o es sc <$> instant r "instant"


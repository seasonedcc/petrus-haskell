-- | Version-1 bounded Hands tool request and result contracts
-- (@petrus.agenticus.hands.contract@).
--
-- This module owns the exact request/result/error envelopes for the five
-- earned workspace tools.  Every rendered error stays within a fixed
-- secret-safe vocabulary; raw provider output and exception text never enter
-- a result.
--
-- Bounds counted in characters are code points (Python @len(str)@); bounds
-- counted in bytes are UTF-8 bytes (@len(str.encode())@).
module Petrus.Agenticus.Hands.Contract
  ( -- * Methods
    ToolMethod (..)
  , allToolMethods
  , toolMethodText
  , parseToolMethod
    -- * Bounds
  , toolSchemaVersion
  , maxPathChars
  , maxQueryChars
  , maxArgvPartChars
  , maxArgvParts
  , maxContentChars
  , maxCwdChars
  , maxDataTextBytes
    -- * Descriptor
  , capabilityScopedHands
    -- * Rejection vocabulary
  , RejectionCategory (..)
  , allRejectionCategories
  , rejectionCategoryText
  , parseRejectionCategory
  , ToolRequestRejected
  , mkToolRequestRejected
  , rejectedMessage
  , rejectedError
  , toolCallConflict
    -- * Requests
  , ReadParams (..)
  , SearchParams (..)
  , ShellParams (..)
  , WriteParams (..)
  , ToolParams (..)
  , paramsMethod
  , ToolRequest
  , mkToolRequest
  , parseToolRequest
  , toolRequestToData
    -- * Results
  , ToolError
  , mkToolError
  , toolErrorToData
  , ToolResult
  , mkToolResult
  , toolResultToData
  , toolResultToModelData
    -- * Unparsed-request salvage
  , unparsedCallId
  , salvagedIdentity
  ) where

import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

toolSchemaVersion :: Integer
toolSchemaVersion = 1

maxPathChars, maxQueryChars, maxArgvPartChars, maxArgvParts, maxContentChars, maxCwdChars, maxDataTextBytes :: Int
maxPathChars = 64
maxQueryChars = 64
maxArgvPartChars = 64
maxArgvParts = 4
maxContentChars = 1024
maxCwdChars = 8
maxDataTextBytes = 4096

maxIdentityBytes, maxDetailBytes :: Int
maxIdentityBytes = 256
maxDetailBytes = 128

-- | The five earned version-1 workspace tools; the set is exact and closed.
data ToolMethod
  = WorkspaceRead
  | WorkspaceSearch
  | WorkspaceShell
  | WorkspaceWrite
  | WorkspaceTest
  deriving stock (Eq, Show, Enum, Bounded)

-- | Python @StrEnum@ ordering: by value.
instance Ord ToolMethod where
  compare a b = compare (toolMethodText a) (toolMethodText b)

-- | In declaration order (Python's @for method in ToolMethod@).
allToolMethods :: [ToolMethod]
allToolMethods = [minBound .. maxBound]

toolMethodText :: ToolMethod -> Text
toolMethodText = \case
  WorkspaceRead -> "workspace_read"
  WorkspaceSearch -> "workspace_search"
  WorkspaceShell -> "workspace_shell"
  WorkspaceWrite -> "workspace_write"
  WorkspaceTest -> "workspace_test"

parseToolMethod :: Text -> Maybe ToolMethod
parseToolMethod = \case
  "workspace_read" -> Just WorkspaceRead
  "workspace_search" -> Just WorkspaceSearch
  "workspace_shell" -> Just WorkspaceShell
  "workspace_write" -> Just WorkspaceWrite
  "workspace_test" -> Just WorkspaceTest
  _ -> Nothing

capabilityScopedHands :: CapabilityDescriptor
capabilityScopedHands =
  capabilityDescriptor
    (descriptorIdentity KindHands "agenticus.capability-scoped" 1)
    [ "hands.capability-scoped"
    , "workspace.read"
    , "workspace.search"
    , "workspace.shell"
    , "workspace.write"
    , "workspace.test"
    ]
    []

-- | Complete secret-safe error vocabulary rendered by the Hands gateway.
--
-- The first ten categories are the required ES-049-equivalent classes.
-- 'CategorySchema' names a malformed or non-exact envelope and
-- 'CategoryAuthority' names a stale, revoked, or removed Agent Connection
-- admission fence.
data RejectionCategory
  = CategoryCapability
  | CategoryPath
  | CategoryArgv
  | CategoryWrite
  | CategoryUnknown
  | CategoryDeadline
  | CategoryAborted
  | CategoryStaleEpoch
  | CategoryPostFence
  | CategoryProvider
  | CategorySchema
  | CategoryAuthority
  | CategoryBudget
  deriving stock (Eq, Show, Enum, Bounded)

-- | Python @StrEnum@ ordering: by value.
instance Ord RejectionCategory where
  compare a b = compare (rejectionCategoryText a) (rejectionCategoryText b)

-- | In declaration order (Python's @for category in RejectionCategory@).
allRejectionCategories :: [RejectionCategory]
allRejectionCategories = [minBound .. maxBound]

rejectionCategoryText :: RejectionCategory -> Text
rejectionCategoryText = \case
  CategoryCapability -> "capability"
  CategoryPath -> "path"
  CategoryArgv -> "argv"
  CategoryWrite -> "write"
  CategoryUnknown -> "unknown"
  CategoryDeadline -> "deadline"
  CategoryAborted -> "aborted"
  CategoryStaleEpoch -> "stale_epoch"
  CategoryPostFence -> "post_fence"
  CategoryProvider -> "provider"
  CategorySchema -> "schema"
  CategoryAuthority -> "authority"
  CategoryBudget -> "budget"

-- | @RejectionCategory(value)@.
parseRejectionCategory :: Text -> Maybe RejectionCategory
parseRejectionCategory value = lookup value [(rejectionCategoryText c, c) | c <- allRejectionCategories]

-- | A request failed its exact schema or bound before any policy check.
--
-- Upstream this is the @ToolRequestRejected@ exception (a @ValueError@
-- subclass carrying @category@ and @detail@).  Here it is a value, so the
-- parser stays pure and the gateway maps it to a result without exception
-- plumbing; 'rejectedError' gives the exception form.
data ToolRequestRejected = ToolRequestRejectedValue
  { _category :: RejectionCategory
  , _detail :: Text
  }
  deriving stock (Eq, Show)

instance HasField "category" ToolRequestRejected RejectionCategory where
  getField r = r._category

instance HasField "detail" ToolRequestRejected Text where
  getField r = r._detail

-- | @_detail@: the fixed safe vocabulary bounds (an @AssertionError@ upstream).
checkDetail :: Text -> Either AgenticusError Text
checkDetail value
  | T.null value || not (isTrimmed value) || utf8Length value > maxDetailBytes || hasControl value =
      Left (agenticusError (OtherError "AssertionError") "rejection detail must stay within the fixed safe vocabulary bounds")
  | otherwise = Right value

mkToolRequestRejected :: RejectionCategory -> Text -> Either AgenticusError ToolRequestRejected
mkToolRequestRejected c d = ToolRequestRejectedValue c <$> checkDetail d

-- | Every detail this module raises is a fixed literal within the bounds.
rejected :: RejectionCategory -> Text -> Either ToolRequestRejected a
rejected c d = Left (ToolRequestRejectedValue c d)

-- | @str(error)@: @"<category>: <detail>"@.
rejectedMessage :: ToolRequestRejected -> Text
rejectedMessage r = rejectionCategoryText r.category <> ": " <> r.detail

-- | The rejection as the exception it is upstream (a @ValueError@ subclass).
rejectedError :: ToolRequestRejected -> AgenticusError
rejectedError r = agenticusError ToolRequestRejected (rejectedMessage r)

-- | A call identity was reused for a materially different request.
toolCallConflict :: AgenticusError
toolCallConflict = agenticusError ToolCallConflict "tool call identity conflicts with its immutable request"

identityField :: Text -> Json -> Either ToolRequestRejected Text
identityField name = \case
  String value | isBoundedText maxIdentityBytes value -> Right value
  _ -> rejected CategorySchema (name <> " must be a bounded non-empty identity string")

positiveField :: Text -> Json -> Either ToolRequestRejected Integer
positiveField name = \case
  Int value | value > 0 -> Right value
  _ -> rejected CategorySchema (name <> " must be a positive integer")

boundedField :: Text -> Int -> RejectionCategory -> Json -> Either ToolRequestRejected Text
boundedField name limit c = \case
  String value -> boundedValue name limit c value
  _ -> rejected CategorySchema (name <> " must be a string")

boundedValue :: Text -> Int -> RejectionCategory -> Text -> Either ToolRequestRejected Text
boundedValue name limit c value
  | hasControlOrDel value = rejected c (name <> " must not contain control characters")
  | T.null value || T.length value > limit =
      rejected c (name <> " must be 1.." <> T.pack (show limit) <> " characters")
  | otherwise = Right value

-- | Absolute, backslashed, or with an empty, @.@ or @..@ segment.
badRelative :: Text -> Bool
badRelative path =
  "/" `T.isPrefixOf` path || T.any (== '\\') path || any (`elem` ["", ".", ".."]) (T.splitOn "/" path)

relativePath :: Text -> Json -> Either ToolRequestRejected Text
relativePath name value = do
  path <- boundedField name maxPathChars CategoryPath value
  if badRelative path
    then rejected CategoryPath (name <> " must be a normalized relative path")
    else Right path

newtype ReadParams = ReadParams {path :: Text}
  deriving stock (Eq, Show)

data SearchParams = SearchParams {query :: Text, path :: Text}
  deriving stock (Eq, Show)

data ShellParams = ShellParams {argv :: [Text], cwd :: Text}
  deriving stock (Eq, Show)

data WriteParams = WriteParams {path :: Text, content :: Text}
  deriving stock (Eq, Show)

-- | The method-specific arguments; 'ParamsTest' is the exact empty
-- @workspace_test@ argument set (@TestParams()@).
data ToolParams
  = ParamsRead ReadParams
  | ParamsSearch SearchParams
  | ParamsShell ShellParams
  | ParamsWrite WriteParams
  | ParamsTest
  deriving stock (Eq, Show)

paramsMethod :: ToolParams -> ToolMethod
paramsMethod = \case
  ParamsRead _ -> WorkspaceRead
  ParamsSearch _ -> WorkspaceSearch
  ParamsShell _ -> WorkspaceShell
  ParamsWrite _ -> WorkspaceWrite
  ParamsTest -> WorkspaceTest

paramsTypeName :: ToolMethod -> Text
paramsTypeName = \case
  WorkspaceRead -> "ReadParams"
  WorkspaceSearch -> "SearchParams"
  WorkspaceShell -> "ShellParams"
  WorkspaceWrite -> "WriteParams"
  WorkspaceTest -> "TestParams"

-- | One parsed, bound-checked version-1 tool call with full call identity.
data ToolRequest = ToolRequest
  { _callId :: Text
  , _episodeId :: Text
  , _attachmentId :: Text
  , _attachmentEpoch :: Integer
  , _grantEpoch :: Integer
  , _method :: ToolMethod
  , _params :: ToolParams
  }
  deriving stock (Eq, Show)

instance HasField "callId" ToolRequest Text where
  getField r = r._callId

instance HasField "episodeId" ToolRequest Text where
  getField r = r._episodeId

instance HasField "attachmentId" ToolRequest Text where
  getField r = r._attachmentId

instance HasField "attachmentEpoch" ToolRequest Integer where
  getField r = r._attachmentEpoch

instance HasField "grantEpoch" ToolRequest Integer where
  getField r = r._grantEpoch

instance HasField "method" ToolRequest ToolMethod where
  getField r = r._method

instance HasField "params" ToolRequest ToolParams where
  getField r = r._params

-- | @ToolRequest(...)@: identities and epochs are validated (failing as
-- @ToolRequestRejected@ with category @schema@, as upstream), and the params
-- must belong to the method (@TypeError@).
mkToolRequest :: Text -> Text -> Text -> Integer -> Integer -> ToolMethod -> ToolParams -> Either AgenticusError ToolRequest
mkToolRequest call episode attachment attachmentEpoch' grantEpoch' method' params' = do
  let schema = either (Left . rejectedError) Right
  c <- schema (identityField "call_id" (String call))
  e <- schema (identityField "episode_id" (String episode))
  a <- schema (identityField "attachment_id" (String attachment))
  ae <- schema (positiveField "attachment_epoch" (Int attachmentEpoch'))
  ge <- schema (positiveField "grant_epoch" (Int grantEpoch'))
  if paramsMethod params' /= method'
    then Left (typeError ("tool request params must be " <> paramsTypeName method'))
    else Right (ToolRequest c e a ae ge method' params')

envelopeFields :: [Text]
envelopeFields = sortedUnique ["version", "call_id", "episode_id", "attachment_id", "attachment_epoch", "grant_epoch", "method", "params"]

paramFields :: ToolMethod -> [Text]
paramFields = \case
  WorkspaceRead -> ["path"]
  WorkspaceSearch -> ["path", "query"]
  WorkspaceShell -> ["argv", "cwd"]
  WorkspaceWrite -> ["content", "path"]
  WorkspaceTest -> []

-- | Python's @repr(sorted(fields))@.
sortedFieldsRepr :: ToolMethod -> Text
sortedFieldsRepr m = "[" <> T.intercalate ", " ["'" <> f <> "'" | f <- paramFields m] <> "]"

-- | @set(members) == expected@ (@expected@ sorted and unique).
sameKeys :: [Text] -> Fields -> Bool
sameKeys expected members = length members == length expected && sortedUnique (map fst members) == expected

field :: Text -> Fields -> Json
field key members = maybe Null id (lookup key members)

parseShell :: Fields -> Either ToolRequestRejected ToolParams
parseShell raw = do
  argvItems <- case field "argv" raw of
    Array items@(_ : _)
      | Just texts <- traverse jsonString items -> Right texts
    _ -> rejected CategorySchema "argv must be a non-empty JSON array of strings"
  if length argvItems > maxArgvParts
    then rejected CategoryArgv ("argv must have at most " <> T.pack (show maxArgvParts) <> " parts")
    else Right ()
  parts <-
    sequence
      [ boundedValue ("argv[" <> T.pack (show index) <> "]") maxArgvPartChars CategoryArgv part
      | (index, part) <- zip [0 :: Int ..] argvItems
      ]
  if any (\part -> T.any (== '\\') part || any (`elem` [".", ".."]) (T.splitOn "/" part)) parts
    then rejected CategoryArgv "argv must not contain backslash or traversal segments"
    else Right ()
  cwd' <- boundedField "cwd" maxCwdChars CategoryArgv (field "cwd" raw)
  if cwd' /= "." && badRelative cwd'
    then rejected CategoryArgv "cwd must be '.' or a bounded relative directory"
    else Right (ParamsShell (ShellParams parts cwd'))

parseWrite :: Fields -> Either ToolRequestRejected ToolParams
parseWrite raw = do
  path' <- relativePath "path" (field "path" raw)
  content' <- case field "content" raw of
    String value | not (T.any (== '\0') value) -> Right value
    _ -> rejected CategorySchema "content must be a string without NUL characters"
  if T.length content' > maxContentChars
    then rejected CategoryWrite ("content must be at most " <> T.pack (show maxContentChars) <> " characters")
    else Right (ParamsWrite (WriteParams path' content'))

parseParams :: ToolMethod -> Fields -> Either ToolRequestRejected ToolParams
parseParams m raw = case m of
  WorkspaceRead -> ParamsRead . ReadParams <$> relativePath "path" (field "path" raw)
  WorkspaceSearch -> do
    q <- boundedField "query" maxQueryChars CategorySchema (field "query" raw)
    p <- relativePath "path" (field "path" raw)
    Right (ParamsSearch (SearchParams q p))
  WorkspaceShell -> parseShell raw
  WorkspaceWrite -> parseWrite raw
  WorkspaceTest -> Right ParamsTest

-- | @parse_tool_request@: parse one exact version-1 envelope, rejecting extra
-- fields and types.  @schema@ for malformed shape, @unknown@ for an
-- unsupported method, and the exact bound category for an oversize or
-- malformed field.  Nothing here touches an adapter or provider.
parseToolRequest :: Json -> Either ToolRequestRejected ToolRequest
parseToolRequest data' = do
  envelope <- case data' of
    Object members -> Right members
    _ -> rejected CategorySchema "request envelope must be a JSON object"
  if sameKeys envelopeFields envelope
    then Right ()
    else rejected CategorySchema "request requires its exact version-1 envelope fields"
  case field "version" envelope of
    Int v | v == toolSchemaVersion -> Right ()
    _ -> rejected CategorySchema ("request version must be integer " <> T.pack (show toolSchemaVersion))
  m <- case field "method" envelope of
    String value -> maybe (rejected CategoryUnknown "method is not a supported version-1 tool") Right (parseToolMethod value)
    _ -> rejected CategorySchema "method must be a string"
  raw <- case field "params" envelope of
    Object members -> Right members
    _ -> rejected CategorySchema (toolMethodText m <> " params must be a JSON object")
  if sameKeys (paramFields m) raw
    then Right ()
    else rejected CategorySchema (toolMethodText m <> " params must have exact fields " <> sortedFieldsRepr m)
  params' <- parseParams m raw
  c <- identityField "call_id" (field "call_id" envelope)
  e <- identityField "episode_id" (field "episode_id" envelope)
  a <- identityField "attachment_id" (field "attachment_id" envelope)
  ae <- positiveField "attachment_epoch" (field "attachment_epoch" envelope)
  ge <- positiveField "grant_epoch" (field "grant_epoch" envelope)
  Right (ToolRequest c e a ae ge m params')

-- | The request's canonical version-1 envelope, in the field order the
-- upstream tests write it (a Haskell addition; upstream has no encoder).
toolRequestToData :: ToolRequest -> Json
toolRequestToData r =
  Object
    [ ("version", Int toolSchemaVersion)
    , ("call_id", String r.callId)
    , ("episode_id", String r.episodeId)
    , ("attachment_id", String r.attachmentId)
    , ("attachment_epoch", Int r.attachmentEpoch)
    , ("grant_epoch", Int r.grantEpoch)
    , ("method", String (toolMethodText r.method))
    , ("params", paramsData r.params)
    ]
  where
    paramsData = \case
      ParamsRead p -> Object [("path", String p.path)]
      ParamsSearch p -> Object [("query", String p.query), ("path", String p.path)]
      ParamsShell p -> Object [("argv", Array (map String p.argv)), ("cwd", String p.cwd)]
      ParamsWrite p -> Object [("path", String p.path), ("content", String p.content)]
      ParamsTest -> Object []

-- | One rendered secret-safe error with a fixed category and bounded detail.
data ToolError = ToolError
  { _category :: RejectionCategory
  , _detail :: Text
  }
  deriving stock (Eq, Show)

instance HasField "category" ToolError RejectionCategory where
  getField r = r._category

instance HasField "detail" ToolError Text where
  getField r = r._detail

mkToolError :: RejectionCategory -> Text -> Either AgenticusError ToolError
mkToolError c d = ToolError c <$> checkDetail d

toolErrorToData :: ToolError -> Json
toolErrorToData e = Object [("category", String (rejectionCategoryText e.category)), ("detail", String e.detail)]

-- | The exact @{version, ok, data, error, epoch}@ envelope plus correlation
-- identity.  @resultData@ is upstream's @data@ and @resultError@ its
-- @error@.
data ToolResult = ToolResult
  { _callId :: Text
  , _attachmentId :: Text
  , _epoch :: Integer
  , _ok :: Bool
  , _resultData :: Maybe Fields
  , _resultError :: Maybe ToolError
  }
  deriving stock (Eq, Show)

instance HasField "callId" ToolResult Text where
  getField r = r._callId

instance HasField "attachmentId" ToolResult Text where
  getField r = r._attachmentId

instance HasField "epoch" ToolResult Integer where
  getField r = r._epoch

instance HasField "ok" ToolResult Bool where
  getField r = r._ok

instance HasField "resultData" ToolResult (Maybe Fields) where
  getField r = r._resultData

instance HasField "resultError" ToolResult (Maybe ToolError) where
  getField r = r._resultError

-- | @_strict_data@: only null, strings of at most 4096 UTF-8 bytes, booleans,
-- integers, arrays and objects, checked depth-first in order.
strictData :: Text -> Json -> Either AgenticusError ()
strictData name = \case
  Null -> Right ()
  Bool _ -> Right ()
  Int _ -> Right ()
  String s
    | utf8Length s > maxDataTextBytes -> Left (valueError (name <> " text exceeds the bounded result size"))
    | otherwise -> Right ()
  Array items -> mapM_ (strictData name) items
  Object members -> mapM_ (strictData name . snd) members
  Float _ -> Left (typeError (name <> " must contain only bounded strict JSON values"))

-- | @ToolResult(...)@ with the upstream validation order.
mkToolResult :: Text -> Text -> Integer -> Bool -> Maybe Fields -> Maybe ToolError -> Either AgenticusError ToolResult
mkToolResult call attachment epoch' ok' data' error' = do
  let schema = either (Left . rejectedError) Right
  c <- schema (identityField "call_id" (String call))
  a <- schema (identityField "attachment_id" (String attachment))
  e <- schema (positiveField "epoch" (Int epoch'))
  if ok' /= null error' || ok' /= not (null data')
    then Left (valueError "a tool result carries exactly data when ok and exactly an error when not")
    else Right ()
  mapM_ (strictData "tool result data" . Object) data'
  Right (ToolResult c a e ok' data' error')

modelFields :: ToolResult -> [(Text, Json)]
modelFields r =
  [ ("version", Int toolSchemaVersion)
  , ("ok", Bool r.ok)
  , ("data", maybe Null Object r.resultData)
  , ("error", maybe Null toolErrorToData r.resultError)
  ]

toolResultToData :: ToolResult -> Json
toolResultToData r =
  Object
    (modelFields r <> [("epoch", Int r.epoch), ("call_id", String r.callId), ("attachment_id", String r.attachmentId)])

-- | Project semantic result data without host custody coordinates.
toolResultToModelData :: ToolResult -> Json
toolResultToModelData = Object . modelFields

-- | The identity an unparsed request is correlated under when nothing
-- better can be salvaged.
unparsedCallId :: Text
unparsedCallId = "unparsed-request"

-- | @_salvaged_identity@: the @(call_id, episode_id)@ of a rejected
-- envelope, each kept only when it is a 1..64 code point, trimmed string
-- without code points below 32.
salvagedIdentity :: Json -> (Text, Text)
salvagedIdentity = \case
  Object members -> (salvage (lookup "call_id" members), salvage (lookup "episode_id" members))
  _ -> (unparsedCallId, unparsedCallId)
  where
    salvage = \case
      Just (String value)
        | not (T.null value)
        , T.length value <= 64
        , isTrimmed value
        , T.all (\ch -> ord ch >= 32) value ->
            value
      _ -> unparsedCallId

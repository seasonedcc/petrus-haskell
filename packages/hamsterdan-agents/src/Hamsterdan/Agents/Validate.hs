-- | The credential-free protocol validators of @hamsterdan.agents.protocol@:
-- @_validate_request@, @_validate_result@ and their helpers.
--
-- Upstream these walk untyped Python objects decoded by @json.loads@. Here
-- the result is a 'Json' value with CPython's equality and duplicate-key
-- semantics, and every check runs in the reference's order, so the first
-- refusal (and its text) is the reference's.
--
-- Some malformed values make the reference fail with a built-in error
-- rather than 'AgentProtocolError': testing an unhashable value for set
-- membership (@TypeError@), sorting mixed types (@TypeError@), indexing the
-- parts of @PurePosixPath(".")@ (@IndexError@), or reading @kind@ from a
-- non-coding request (@AttributeError@). Those are 'Foreign' failures, which
-- the Pi runner sanitizes exactly as the reference's @except Exception@
-- does.
module Hamsterdan.Agents.Validate
  ( -- * Failures
    Failure (..)
  , V
  , refuse
  , foreignFailure
  , throwFailure

    -- * Field sets and vocabularies
  , commonResultFields
  , reviewResultFields
  , conversationResultFields
  , codingResultFields
  , findingFields
  , relatedLocationFields
  , lineageFields
  , intentFields
  , reviewStatuses
  , findingSeverities
  , lineageStates
  , codingStatuses
  , reproductionStatuses
  , findingIdPattern

    -- * Validation
  , ResultKind (..)
  , validateRequest
  , validateResult
  , text
  , safePath
  , pythonList
  , dictMembers
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (foldlM)
import Data.List (nubBy, sort, sortBy)
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Enumeration (..), pythonDict, unspelling)
import Hamsterdan.Python.Exception (PythonException (..), pythonExceptionStr)
import Hamsterdan.Python.Text (strip, utf8Encode)
import Hamsterdan.PyLiteral (PyValue (..), repr)
import Petrus.Impetus.Instance.FailureText qualified as FT
import Petrus.Json (Json (..), defaultDumps, dumps)
import Data.ByteString qualified as BS
import Hamsterdan.Python.Value (truthy)

-- | Why validation stopped.
data Failure
  = -- | The reference's 'AgentProtocolError'.
    Refused AgentProtocolError
  | -- | A built-in Python failure the reference does not anticipate: its
    -- class name and message.
    Foreign Text Text
  deriving stock (Eq, Show)

type V = Either Failure

-- | @_fail(message)@.
refuse :: Text -> V a
refuse = Left . Refused . protocolError

foreignFailure :: Text -> Text -> V a
foreignFailure cls message = Left (Foreign cls message)

-- | Raise a failure as the exception the reference raises.
throwFailure :: Failure -> IO a
throwFailure = \case
  Refused failure -> throwIO failure
  Foreign cls message -> throwIO (FT.PythonException cls [FT.PyStr message])

-- ---------------------------------------------------------------------------
-- Field sets

commonResultFields :: [Text]
commonResultFields = ["repository", "pull_request", "epoch", "head", "base"]

reviewResultFields, conversationResultFields, codingResultFields :: Set.Set Text
reviewResultFields = Set.fromList (commonResultFields <> ["status", "findings", "lineage"])
conversationResultFields = Set.fromList (commonResultFields <> ["intents"])
codingResultFields =
  Set.fromList
    ( commonResultFields
        <> [ "kind"
           , "ref"
           , "status"
           , "reproduction_status"
           , "diff"
           , "changed_files"
           , "validation_evidence"
           , "proposed_commit_message"
           ]
    )

findingFields, relatedLocationFields, lineageFields, intentFields :: Set.Set Text
findingFields =
  Set.fromList
    [ "id"
    , "path"
    , "line"
    , "related_locations"
    , "title"
    , "body"
    , "severity"
    , "confidence"
    , "evidence"
    , "blocking"
    , "suggestion"
    ]
relatedLocationFields = Set.fromList ["path", "line"]
lineageFields = Set.fromList ["finding_id", "state", "supersedes"]
intentFields = Set.fromList ["type", "arguments", "mutation", "explicit", "confidence"]

reviewStatuses, findingSeverities, lineageStates, codingStatuses, reproductionStatuses :: Set.Set Text
reviewStatuses = spellings [minBound .. maxBound :: ReviewVerdict]
findingSeverities = Set.fromList ["low", "medium", "high", "critical"]
lineageStates = Set.fromList ["new", "still_open", "resolved", "superseded", "withdrawn"]
codingStatuses = spellings [minBound .. maxBound :: CodingOutcome]
reproductionStatuses = Set.fromList ["unknown", "confirmed", "not_reproduced", "not_attempted"]

-- | Every spelling of a closed vocabulary.
spellings :: (Enumeration a) => [a] -> Set.Set Text
spellings = Set.fromList . map spelling

-- | @_FINDING_ID_PATTERN@.
findingIdPattern :: Text
findingIdPattern = "[A-Za-z0-9][A-Za-z0-9._-]{0,47}"

maxItems, maxText, maxPath :: Int
maxItems = 100
maxText = 20000
maxPath = 1024

-- ---------------------------------------------------------------------------
-- Patterns (all ASCII classes, matched in full)

alnum :: Char -> Bool
alnum c = isAsciiLower c || isAsciiUpper c || isDigit c

-- | @_SHA.fullmatch@: @[0-9a-f]{40,64}@.
shaMatch :: Text -> Bool
shaMatch value = T.length value >= 40 && T.length value <= 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) value

-- | @_REPOSITORY.fullmatch@: @[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@.
repositoryMatch :: Text -> Bool
repositoryMatch value = case T.splitOn "/" value of
  [owner, name] -> part owner && part name
  _ -> False
  where
    part segment = not (T.null segment) && T.all (\c -> alnum c || c `elem` ("_.-" :: String)) segment

-- | @_REF.fullmatch@: @[A-Za-z0-9][A-Za-z0-9._/-]{0,254}@.
refMatch :: Text -> Bool
refMatch value = case T.uncons value of
  Just (c, rest) -> alnum c && T.length rest <= 254 && T.all (\x -> alnum x || x `elem` ("._/-" :: String)) rest
  Nothing -> False

-- | @_FINDING_ID.fullmatch@.
findingIdMatch :: Text -> Bool
findingIdMatch value = case T.uncons value of
  Just (c, rest) -> alnum c && T.length rest <= 47 && T.all (\x -> alnum x || x `elem` ("._-" :: String)) rest
  Nothing -> False

-- | @_LOGIN.fullmatch@: @[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?@.
loginMatch :: Text -> Bool
loginMatch value =
  let n = T.length value
   in n >= 1
        && n <= 39
        && alnum (T.head value)
        && alnum (T.last value)
        && T.all (\c -> alnum c || c == '-') value

-- ---------------------------------------------------------------------------
-- Helpers

-- | @_text(value, name, empty=..., limit=...)@.
text :: Json -> Text -> Bool -> Int -> V Text
text value name empty limit = case value of
  String s
    | empty || not (T.null s) -> do
        size <- measured s
        if size <= limit && not (T.elem '\0' s) then Right s else invalid
  _ -> invalid
  where
    invalid = refuse ("invalid " <> name)

-- | @len(value.encode())@: the @UnicodeEncodeError@ a lone surrogate (kept
-- from a JSON escape) raises propagates, a built-in failure.
measured :: Text -> V Int
measured value = case utf8Encode value of
  Right bytes -> Right (BS.length bytes)
  Left failure@(PythonException cls _) -> foreignFailure cls (pythonExceptionStr failure)

-- | @_safe_path(value)@. @PurePosixPath(".").parts[0]@ raises
-- @IndexError@, so a relative path with no parts is a foreign failure.
safePath :: Json -> V Bool
safePath = \case
  String value
    | T.null value -> Right False
    | otherwise -> measured value >>= \size -> checked value size
  _ -> Right False
  where
    checked value size
      | size > maxPath || T.elem '\\' value || T.elem '\0' value = Right False
      | "/" `T.isPrefixOf` value = Right False
      | otherwise =
          let parts = filter (`notElem` ["", "."]) (T.splitOn "/" value)
           in if ".." `elem` parts
                then Right False
                else case parts of
                  first : _ -> Right (first `notElem` [".git", ".impetus"])
                  [] -> foreignFailure "IndexError" "tuple index out of range"

-- | @_list(value, name)@.
pythonList :: Json -> Text -> V [Json]
pythonList value name = case value of
  Array items | length items <= maxItems -> Right items
  _ -> refuse ("invalid " <> name)

-- | The members of a dict, as the Python object holds them.
dictMembers :: Json -> Maybe [(Text, Json)]
dictMembers = \case
  Object members -> Just (pythonDict members)
  _ -> Nothing

-- | @data[name]@ on a dict whose key set was checked.
(!) :: [(Text, Json)] -> Text -> Json
members ! name = maybe Null id (lookup name members)

-- | @_exact(data, names)@.
exact :: [(Text, Json)] -> Set.Set Text -> V ()
exact members names =
  let keys = Set.fromList (map fst members)
   in unless (keys == names) $
        refuse
          ( "result fields differ: expected "
              <> strList (Set.toAscList names)
              <> ", got "
              <> strList (sort (map fst members))
          )
  where
    strList = repr . PyList . map PyStr

-- | @value in VOCABULARY@ for a closed vocabulary: the member the value
-- spells, if any. An unhashable value raises, as 'memberOf'.
spelledMember :: (Enumeration a) => Json -> V (Maybe a)
spelledMember = \case
  String s -> Right (unspelling s)
  Array _ -> unhashable "list"
  Object _ -> unhashable "dict"
  _ -> Right Nothing

-- | @value in frozenset_of_strings@: an unhashable value raises.
memberOf :: Set.Set Text -> Json -> V Bool
memberOf names = \case
  String s -> Right (Set.member s names)
  Array _ -> unhashable "list"
  Object _ -> unhashable "dict"
  _ -> Right False

unhashable :: Text -> V a
unhashable name = foreignFailure "TypeError" ("cannot use '" <> name <> "' as a set element (unhashable type: '" <> name <> "')")

isBool :: Json -> Bool
isBool = \case
  Bool _ -> True
  _ -> False

-- | @_confidence(value)@.
confidence :: Json -> Bool
confidence = \case
  Int i -> i >= 0 && i <= 1
  Float d -> d >= 0 && d <= 1
  _ -> False

-- | @value.get(name, fallback)@ on a request dict.
getOr :: [(Text, Json)] -> Text -> Json -> Json
getOr members name fallback = maybe fallback id (lookup name (pythonDict members))

-- ---------------------------------------------------------------------------
-- Requests

-- | @_validate_request(request)@.
validateRequest :: AgentRequest -> V ()
validateRequest request = do
  let (repository, pullRequest, epoch, headSha, baseSha) = common request
  unless (repositoryMatch repository) $ refuse "invalid repository"
  when (pullRequest < 1) $ refuse "invalid pull request"
  when (epoch < 0) $ refuse "invalid epoch"
  forM_ [("head", headSha), ("base", baseSha)] $ \(name, value) ->
    unless (shaMatch value) $ refuse ("invalid " <> name <> " SHA")
  case request of
    AgentReview r -> do
      diffSafe <- safePath (String r.diffPath)
      contextSafe <-
        if diffSafe
          then do
            paths <- pythonList (Array (map String r.contextPaths)) "context paths"
            allM safePath paths
          else Right False
      unless (diffSafe && contextSafe) $ refuse "invalid review path"
      when (length (pythonDict r.policy) > maxItems) $ refuse "invalid review policy"
      when (any (\lens -> T.null lens || T.length lens > 100) r.reviewLenses) $ refuse "invalid review lenses"
    AgentConversation _ -> pure ()
    AgentCoding r ->
      when
        ( isNothing (unspelling @CodingRequestKind r.kind)
            || not (refMatch r.ref)
            || ".." `T.isInfixOf` r.ref
            || "@{" `T.isInfixOf` r.ref
        )
        $ refuse "invalid coding kind/ref"

allM :: (a -> V Bool) -> [a] -> V Bool
allM check = foldlM (\ok item -> if ok then check item else Right False) True

common :: AgentRequest -> (Text, Integer, Integer, Text, Text)
common = \case
  AgentReview r -> (r.repository, r.pullRequest, r.epoch, r.head, r.base)
  AgentConversation r -> (r.repository, r.pullRequest, r.epoch, r.head, r.base)
  AgentCoding r -> (r.repository, r.pullRequest, r.epoch, r.head, r.base)

-- | @getattr(request, name)@ for the correlated fields.
requestField :: AgentRequest -> Text -> V Json
requestField request name =
  let (repository, pullRequest, epoch, headSha, baseSha) = common request
   in case name of
        "repository" -> Right (String repository)
        "pull_request" -> Right (Int pullRequest)
        "epoch" -> Right (Int epoch)
        "head" -> Right (String headSha)
        "base" -> Right (String baseSha)
        _ -> case request of
          AgentCoding r
            | name == "kind" -> Right (String r.kind)
            | name == "ref" -> Right (String r.ref)
          AgentReview _ -> missing "ReviewRequest"
          AgentConversation _ -> missing "ConversationRequest"
          AgentCoding _ -> missing "CodingRequest"
  where
    missing cls = foreignFailure "AttributeError" ("'" <> cls <> "' object has no attribute '" <> name <> "'")

sameType :: Json -> Json -> Bool
sameType a b = case (a, b) of
  (String _, String _) -> True
  (Int _, Int _) -> True
  _ -> False

-- | @_correlate(data, request, fields)@.
correlate :: [(Text, Json)] -> AgentRequest -> [Text] -> V ()
correlate members request names = forM_ names $ \name -> do
  expected <- requestField request name
  case lookup name members of
    Just actual | sameType actual expected ->
      unless (actual == expected) $
        Left (Refused (retainResultCategory Correlation (protocolError ("result correlation mismatch: " <> name))))
    _ -> refuse ("result correlation mismatch: " <> name)

-- ---------------------------------------------------------------------------
-- Results

-- | The @kind@ argument of @_validate_result@.
data ResultKind = KindReview | KindConversation | KindCoding
  deriving stock (Eq, Show)

-- | @_validate_result(kind, data, request, changed)@.
validateResult :: ResultKind -> Json -> AgentRequest -> Maybe [Text] -> V AgentResult
validateResult kind value request changed = do
  members <- maybe (refuse "result must be a JSON object") Right (dictMembers value)
  correlate members request commonResultFields
  case kind of
    KindReview -> do
      exact members reviewResultFields
      ResultReview <$> validateReview members request
    KindConversation -> do
      exact members conversationResultFields
      case request of
        AgentConversation r -> ResultConversation <$> validateConversation members r
        _ -> Left (Refused (retainResultCategory Correlation (protocolError "request kind differs from result kind")))
    KindCoding -> do
      exact members codingResultFields
      correlate members request ["kind", "ref"]
      case request of
        AgentCoding r -> ResultCoding <$> validateCoding members r (maybe [] id changed)
        _ -> Left (Refused (retainResultCategory Correlation (protocolError "request kind differs from result kind")))

-- | @_validate_review(data)@.
validateReview :: [(Text, Json)] -> AgentRequest -> V ReviewResult
validateReview members request = do
  status <- spelledMember @ReviewVerdict (members ! "status") >>= maybe (refuse "invalid review status") pure
  findings <- pythonList (members ! "findings") "findings"
  lineage <- pythonList (members ! "lineage") "lineage"
  findingMembers <- validateFindings findings
  validateLineage lineage (Set.fromList [identity | (identity, _) <- findingMembers])
  let blocking = any (\(_, finding) -> truthy (finding ! "blocking")) findingMembers
  when ((status == VerdictClear && blocking) || (status == VerdictBlocking && not blocking)) $
    refuse "review status inconsistent with findings"
  let (repository, pullRequest, epoch, headSha, baseSha) = common request
  pure
    ReviewResult
      { repository
      , pullRequest
      , epoch
      , head = headSha
      , base = baseSha
      , status = spelling status
      , findings = map snd findingMembers
      , lineage = [item | Just item <- map dictMembers lineage]
      }

validateFindings :: [Json] -> V [(Text, [(Text, Json)])]
validateFindings = go Set.empty []
  where
    go _ acc [] = Right (reverse acc)
    go ids acc (value : rest) = do
      finding <- maybe (refuse "finding must be an object") Right (dictMembers value)
      exact finding findingFields
      identity <- text (finding ! "id") "finding id" False 200
      when (not (findingIdMatch identity) || Set.member identity ids) $ refuse "invalid or duplicate finding id"
      validateFindingShape finding
      validateRelated finding
      forM_ ["title", "body", "evidence", "suggestion"] $ \name ->
        text (finding ! name) name (name == "suggestion") maxText
      case finding ! "suggestion" of
        String s | "```" `T.isInfixOf` s -> refuse "invalid suggestion"
        _ -> pure ()
      go (Set.insert identity ids) ((identity, finding) : acc) rest

validateFindingShape :: [(Text, Json)] -> V ()
validateFindingShape finding = do
  pathSafe <- safePath (finding ! "path")
  bad <-
    if not pathSafe
      then Right True
      else case finding ! "line" of
        Int line | line >= 1 -> do
          severityKnown <- memberOf findingSeverities (finding ! "severity")
          pure (not severityKnown || not (confidence (finding ! "confidence")) || not (isBool (finding ! "blocking")))
        _ -> Right True
  when bad $ refuse "invalid or inconsistent finding"

validateRelated :: [(Text, Json)] -> V ()
validateRelated finding = do
  locations <- pythonList (finding ! "related_locations") "related locations"
  let primary = (finding ! "path", finding ! "line")
  _ <- foldlM step [primary] locations
  pure ()
  where
    step seen value = do
      location <- maybe (refuse "related location must be an object") Right (dictMembers value)
      exact location relatedLocationFields
      let key = (location ! "path", location ! "line")
      pathSafe <- safePath (location ! "path")
      let bad = case location ! "line" of
            Int line -> not pathSafe || line < 1 || key `elem` seen
            _ -> True
      when bad $ refuse "invalid or duplicate related location"
      pure (key : seen)

validateLineage :: [Json] -> Set.Set Text -> V ()
validateLineage items ids = foldlM step Set.empty items >> pure ()
  where
    step seen value = do
      item <- maybe (refuse "lineage must be an object") Right (dictMembers value)
      exact item lineageFields
      identity <- text (item ! "finding_id") "lineage finding id" False 200
      let supersedes = item ! "supersedes"
          state = item ! "state"
      invalid <-
        if Set.member identity seen
          then Right True
          else not <$> memberOf lineageStates state
      when invalid $ refuse "invalid lineage"
      case supersedes of
        Null -> pure ()
        other -> () <$ text other "supersedes" False 200
      when (state `elem` [String "new", String "still_open"] && not (Set.member identity ids)) $
        refuse "open lineage has no finding"
      when (state == String "new" && supersedes /= Null) $ refuse "new lineage cannot supersede"
      when (state == String "superseded" && supersedes == Null) $ refuse "superseded lineage lacks predecessor"
      pure (Set.insert identity seen)

-- | @_allowed_intents(request)@.
allowedIntents :: ConversationRequest -> V [(Text, [(Text, Json)])]
allowedIntents request = do
  declarations <- pythonList (Array (map Object request.allowedIntents)) "allowed intents"
  foldlM add [] declarations
  where
    add allowed value = do
      let declaration = maybe [] id (dictMembers value)
      name <- case lookup "type" declaration of
        Just (String s) -> Right s
        _ -> refuse "invalid allowed intent declaration"
      when (name `elem` map fst allowed) $ refuse "duplicate allowed intent"
      pure (allowed <> [(name, declaration)])

-- | @_validate_intent_arguments(arguments, mutation)@.
validateIntentArguments :: [(Text, Json)] -> Bool -> V ()
validateIntentArguments arguments mutation = do
  forM_ arguments $ \(name, value) -> case name of
    _
      | name `elem` ["request", "message"] -> do
          s <- text value ("intent " <> name) False maxText
          when (T.null (strip s)) $ refuse ("invalid intent " <> name)
      | name == "assignee" -> do
          assignee <- text value "intent assignee" False 39
          unless (loginMatch assignee) $ refuse "invalid intent assignee"
      | name `elem` ["id", "finding_id"] -> do
          identity <- text value ("intent " <> name) False 48
          unless (findingIdMatch identity) $ refuse ("invalid intent " <> name)
      | name == "findings" -> do
          findings <- pythonList value "intent findings"
          let valid = \case
                String s -> findingIdMatch s
                _ -> False
          when (null findings || not (all valid findings)) $ refuse "invalid intent findings"
      | name == "target" -> do
          known <- memberOf (Set.fromList ["conversation", "dashboard", "readiness"]) value
          unless known $ refuse "invalid publication recovery target"
      | name == "operation" -> do
          s <- text value "intent operation" False 256
          when (T.null (strip s)) $ refuse "invalid publication recovery operation"
      | otherwise -> pure ()
  when (mutation && null arguments) $ refuse "mutation intent lacks concrete scope"

-- | @set(keys) != set(expected)@ where @expected@ is a request list.
argumentSetDiffers :: [Text] -> [Json] -> V Bool
argumentSetDiffers keys expected = do
  forM_ expected $ \case
    Array _ -> unhashable "list"
    Object _ -> unhashable "dict"
    _ -> pure ()
  let strings = [s | String s <- expected]
  pure (length strings /= length expected || Set.fromList strings /= Set.fromList keys)

-- | @_validate_conversation(data, request)@.
validateConversation :: [(Text, Json)] -> ConversationRequest -> V ConversationResult
validateConversation members request = do
  allowed <- allowedIntents request
  intents <- pythonList (members ! "intents") "intents"
  when (length intents /= 1) $ refuse "conversation must select exactly one intent"
  forM_ intents $ \value -> do
    intent <- maybe (refuse "intent must be an object") Right (dictMembers value)
    exact intent intentFields
    declared <- case intent ! "type" of
      String s -> Right (lookup s allowed)
      Array _ -> unhashable "list"
      Object _ -> unhashable "dict"
      _ -> Right Nothing
    (declaration, arguments) <- case (declared, intent ! "arguments") of
      (Just declaration, Object raw)
        | let arguments = pythonDict raw
        , length arguments <= maxItems ->
            Right (declaration, arguments)
      _ -> refuse "unauthorized intent or arguments"
    let mutationValue = getOr declaration "mutation" (Bool False)
    mutation <- case (mutationValue, intent ! "mutation") of
      (Bool declaredMutation, Bool actual)
        | actual == declaredMutation && confidence (intent ! "confidence") -> Right declaredMutation
      _ -> refuse "intent metadata differs from declaration"
    let keys = map fst arguments
    differs <- case getOr declaration "arguments" Null of
      Array expected -> argumentSetDiffers keys expected
      Object expected -> pure (Set.fromList (map fst (pythonDict expected)) /= Set.fromList keys)
      _ -> pure False
    when differs $ refuse "intent arguments differ from declaration"
    explicit <- case intent ! "explicit" of
      Bool b -> Right b
      _ -> refuse "invalid intent authorization flags"
    when (mutation && not explicit) $ refuse "mutation intent was not explicit"
    when (truthy (getOr declaration "requires_explicit" (Bool False)) && not explicit) $
      refuse "intent requires explicit request"
    validateIntentArguments arguments mutation
  pure
    ConversationResult
      { repository = request.repository
      , pullRequest = request.pullRequest
      , epoch = request.epoch
      , head = request.head
      , base = request.base
      , intents = [intent | Just intent <- map dictMembers intents]
      }

-- | @sorted(set(values))@ over JSON values, with the reference's failures.
sortedSet :: [Json] -> V [Json]
sortedSet values = do
  forM_ values $ \case
    Array _ -> unhashable "list"
    Object _ -> unhashable "dict"
    _ -> pure ()
  let distinct = nubBy (==) values
      strings = [s | String s <- distinct]
      numbers = [v | v <- distinct, numeric v]
  if
    | length distinct <= 1 -> Right distinct
    | length strings == length distinct -> Right (map String (sort strings))
    | length numbers == length distinct -> Right (sortBy numericOrder numbers)
    | otherwise -> foreignFailure "TypeError" "'<' not supported between instances of different types"
  where
    numeric = \case
      Int _ -> True
      Float _ -> True
      Bool _ -> True
      _ -> False
    asDouble = \case
      Int i -> fromInteger i
      Float d -> d
      Bool b -> if b then 1 else 0
      _ -> 0 :: Double
    numericOrder a b = compare (asDouble a) (asDouble b)

-- | @_validate_coding(data, request, changed)@.
validateCoding :: [(Text, Json)] -> CodingRequest -> [Text] -> V CodingResult
validateCoding members request changed = do
  outcome <- spelledMember @CodingOutcome (members ! "status")
  reproductionKnown <- maybe (Right False) (const (memberOf reproductionStatuses (members ! "reproduction_status"))) outcome
  status <- case outcome of
    Just status | reproductionKnown -> Right status
    _ -> refuse "invalid coding status/reproduction status"
  let isChanged = status == CodingChanged
  when (isChanged /= not (null changed) || (status == CodingUnchanged && not (null changed))) $
    Left (Refused (retainResultCategory WorkspaceReconciliation (protocolError "coding status differs from host worktree")))
  when (unspelling request.kind == Just RequestRepair && not (null changed) && members ! "reproduction_status" /= String "confirmed") $
    refuse "repair changed result requires confirmed reproduction"
  diff <- text (members ! "diff") "diff" True 4000000
  files <- pythonList (members ! "changed_files") "changed files"
  canonical <- sortedSet files
  invalidFiles <-
    if files /= canonical || files /= map String changed
      then Right True
      else not <$> allM safePath files
  when invalidFiles $ refuse "invalid changed files"
  message <- text (members ! "proposed_commit_message") "proposed commit message" (not isChanged) 1000
  when (isChanged && ("\n\n\n" `T.isInfixOf` message || T.length (firstLine message) > 72)) $
    refuse "invalid proposed commit message"
  evidence <- pythonList (members ! "validation_evidence") "validation evidence"
  when (isChanged && null evidence) $ refuse "changed result lacks validation evidence"
  items <- traverse evidenceItem evidence
  pure
    CodingResult
      { kind = request.kind
      , repository = request.repository
      , pullRequest = request.pullRequest
      , epoch = request.epoch
      , head = request.head
      , base = request.base
      , ref = request.ref
      , status = spelling status
      , reproductionStatus = case members ! "reproduction_status" of
          String s -> s
          _ -> ""
      , diff
      , changedFiles = changed
      , validationEvidence = items
      , proposedCommitMessage = message
      }
  where
    evidenceItem value = case dictMembers value of
      Just item
        | not (null item) && length item <= 20 -> do
            size <- either (const (foreignFailure "ValueError" "validation evidence cannot be encoded")) (Right . BS.length) (dumps defaultDumps (Object item))
            when (size > maxText) $ refuse "validation evidence too large"
            pure item
      _ -> refuse "invalid validation evidence"

-- | @message.splitlines()[0]@ for a non-empty message.
firstLine :: Text -> Text
firstLine = T.takeWhile (`notElem` ("\n\r\v\f\x1c\x1d\x1e\x85\x2028\x2029" :: String))


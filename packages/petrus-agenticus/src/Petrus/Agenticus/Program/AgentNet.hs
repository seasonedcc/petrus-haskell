-- | The provider-free static Net that owns the bounded Pi-style agent loop
-- (@petrus.agenticus.program.agent_net@).
--
-- Agent-as-a-Net is a five-place, five-transition Net authored with the
-- Petrus DSL. Exactly two transitions are Activity bridges — one model
-- phase ('modelPhaseActivity') and one Hands call ('handsActivity') — and
-- every other step (classifying a model phase, refusing an unsupported or
-- ungranted tool, recording a Hands result, routing to a terminal) is a
-- pure handler, so the loop is replayable from History alone.
--
-- The token payloads are the reference's envelopes, byte for byte:
-- 'LoopState', 'ModelSettlement', 'ToolWork', 'HandsSettlement' and
-- 'Terminal', each with the reference's exact key order (a 'LoopState'
-- writes @version@ last, as @dataclasses.asdict@ followed by
-- @data["version"] = VERSION@ does) and the reference's exact refusals.
--
-- This module depends on no provider, runtime, or SDK: it is pure Net
-- definition plus pure envelope validation.
module Petrus.Agenticus.Program.AgentNet
  ( -- * Bounds
    agentNetVersion
  , maxProposals
  , maxPhases
  , maxTools
  , maxJsonBytes
    -- * Places, transitions, Activities
  , modelPending
  , modelSettled
  , toolPending
  , toolSettled
  , done
  , modelPhase
  , classifyModel
  , executeTool
  , rejectTool
  , recordResult
  , modelPhaseActivity
  , handsActivity
    -- * Program and Continuation descriptors
  , agentAsNetContinuationDescriptor
  , agentAsNetProgram
  , agentAsNetProgramCapabilities
  , agentAsNetContinuationCapabilities
    -- * Vocabulary
  , StopReason (..)
  , stopReasonText
  , parseStopReason
  , TerminalCode (..)
  , terminalCodeText
  , parseTerminalCode
  , errorCategories
    -- * Proposals
  , Proposal (id, method, params)
  , mkProposal
  , proposalToData
  , proposalFromData
    -- * Model results
  , ModelResult (id, ok, payload, failure)
  , mkModelResult
  , succeeded
  , failed
  , failureCategory
  , modelResultToData
  , modelResultToModelData
  , modelResultFromData
  , modelResultFromModelData
    -- * Loop state
  , LoopState (episodeId, turnId, phase, phaseLimit, toolCount, toolLimit, outputRef, continuationRef, grantEpoch, capabilities, results)
  , mkLoopState
  , loopStateToData
  , loopStateFromData
    -- * Model settlements
  , ModelSettlement (state, stop, assistantDigest, outputRef, continuationRef, proposals)
  , mkModelSettlement
  , modelSettlementToData
  , modelSettlementFromData
    -- * Tool work
  , ToolWork (state, assistantDigest, proposals, index)
  , mkToolWork
  , toolWorkProposal
  , toolWorkToData
  , toolWorkFromData
    -- * Hands settlements
  , HandsSettlement (work, result)
  , mkHandsSettlement
  , handsSettlementToData
  , handsSettlementFromData
    -- * Terminals
  , Terminal (episodeId, turnId, code, phases, tools, outputRef, continuationRef)
  , mkTerminal
  , terminalToData
  , terminalFromData
    -- * The Net
  , initialMarking
  , agentNet
  , agentNetBuilt
  , agentNetHandlers
  , agentNetGuards
  , agentNetHandlersByUri
  , agentNetGuardsByUri
  , agentNetOptions
    -- * Pure implementations (exposed for tests)
  , classifyHandler
  , rejectHandler
  , recordHandler
  , executeGuard
  , rejectGuard
  , modelActivityHandler
  , handsActivityHandler
  , failureText
  ) where

import Control.Monad (forM, unless, void, when)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (defaultInvocationFields)
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor, DescriptorIdentity, DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (allRejectionCategories, rejectionCategoryText)
import Petrus.Agenticus.Program.Descriptor (AgentProgramDescriptor, ProgramOwnership (..), agentProgramDescriptor, continuationRequirement)
import Petrus.Agenticus.Thread.Continuation (ContinuationDescriptor, continuationDescriptor)
import Petrus.Agenticus.Internal.Validate (encodeRefusal, hasDuplicates, isTrimmed, sortedUnique, utf8Length)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), Handler, HandlerResult, handlerTokens, prepareInvocation)
import Petrus.Impetus.Dsl
  ( BuiltNet (..)
  , CompletionDeclaration (..)
  , arc
  , build
  , color
  , configure
  , guards
  , handler
  , named
  , netSpec
  , p
  , petriGuard
  , petriHandler
  , t
  , unsafeCel
  , withCompletion
  , (~>)
  )
import Petrus.Impetus.Dsl qualified as Dsl
import Petrus.Cel.Impetus qualified as Cel
import Petrus.Engine qualified as Engine
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Json.Python (pythonRepr, pythonStrRepr)
import Petrus.Impetus.Petrinet (Binding, Guard, Marking, Net, NetPath, NetUri, Token (..), bindingTokens, handlerUri, markingFromList, netPath)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J


-- ---------------------------------------------------------------------------
-- Bounds

agentNetVersion :: Integer
agentNetVersion = 1

maxProposals, maxPhases, maxTools, maxJsonBytes :: Integer
maxProposals = 16
maxPhases = 16
maxTools = 64
maxJsonBytes = 4096

textLimit, errorDetailLimit :: Int
textLimit = 256
errorDetailLimit = 128

-- ---------------------------------------------------------------------------
-- Paths

path :: Text -> NetPath
path = either (error . T.unpack) id . netPath

modelPending, modelSettled, toolPending, toolSettled, done :: NetPath
modelPending = path "model_pending"
modelSettled = path "model_settled"
toolPending = path "tool_pending"
toolSettled = path "tool_settled"
done = path "done"

modelPhase, classifyModel, executeTool, rejectTool, recordResult :: NetPath
modelPhase = path "model_phase"
classifyModel = path "classify_model"
executeTool = path "execute_tool"
rejectTool = path "reject_tool"
recordResult = path "record_result"

modelPhaseActivity, handsActivity :: Text
modelPhaseActivity = "agenticus.net.model-phase"
handsActivity = "agenticus.net.hands"

-- ---------------------------------------------------------------------------
-- Program and Continuation descriptors

programId, continuationId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "agenticus.net-owned" agentNetVersion
continuationId = descriptorIdentity KindContinuation "agenticus.net-owned" agentNetVersion

agentAsNetContinuationDescriptor :: ContinuationDescriptor
agentAsNetContinuationDescriptor = continuationDescriptor continuationId programId

-- | The Net-owned Agent Program: it accepts a fresh start or its own
-- Continuation, produces that Continuation, and owns neither steering nor
-- evaluation.
agentAsNetProgram :: AgentProgramDescriptor
agentAsNetProgram =
  agentProgramDescriptor programId NetOwned True [continuationRequirement continuationId programId] (Just continuationId) False False

agentAsNetProgramCapabilities :: CapabilityDescriptor
agentAsNetProgramCapabilities = capabilityDescriptor programId ["program.net-owned"] []

agentAsNetContinuationCapabilities :: CapabilityDescriptor
agentAsNetContinuationCapabilities = capabilityDescriptor continuationId ["continuation.net-owned"] []

-- ---------------------------------------------------------------------------
-- Vocabulary

data StopReason = Stop | ToolUse | Length | ErrorStop | Aborted
  deriving stock (Eq, Ord, Show, Enum, Bounded)

stopReasonText :: StopReason -> Text
stopReasonText = \case
  Stop -> "stop"
  ToolUse -> "toolUse"
  Length -> "length"
  ErrorStop -> "error"
  Aborted -> "aborted"

-- | @StopReason(value)@.
parseStopReason :: Json -> Either AgenticusError StopReason
parseStopReason = enumFrom' "StopReason" stopReasonText

data TerminalCode = Completed | Failed | Cancelled | PhaseBudget | ToolBudget
  deriving stock (Eq, Ord, Show, Enum, Bounded)

terminalCodeText :: TerminalCode -> Text
terminalCodeText = \case
  Completed -> "completed"
  Failed -> "failed"
  Cancelled -> "cancelled"
  PhaseBudget -> "phase-budget-exhausted"
  ToolBudget -> "tool-budget-exhausted"

-- | @TerminalCode(value)@.
parseTerminalCode :: Json -> Either AgenticusError TerminalCode
parseTerminalCode = enumFrom' "TerminalCode" terminalCodeText

enumFrom' :: (Enum a, Bounded a) => Text -> (a -> Text) -> Json -> Either AgenticusError a
enumFrom' cls render value = case [c | c <- [minBound .. maxBound], String (render c) == value, isString value] of
  c : _ -> Right c
  [] -> Left (valueError (pythonRepr value <> " is not a valid " <> cls))
  where
    isString = \case
      String _ -> True
      _ -> False

-- | The model-visible error vocabulary: exactly the Hands contract's
-- rejection categories (@RejectionCategory@ values).
errorCategories :: Set.Set Text
errorCategories = Set.fromList (map rejectionCategoryText allRejectionCategories)

-- ---------------------------------------------------------------------------
-- Shared rules

-- | @_text(value, name)@. A lone surrogate fails @value.encode()@, after
-- the emptiness and strip checks and before the length bound; one scan
-- finds a surrogate or a control character.
text :: Text -> Json -> Either AgenticusError Text
text name = \case
  String s
    | not (T.null s) && isTrimmed s -> case encodeRefusal s of
        _ | not (T.any (\c -> c < ' ' || (c >= '\xD800' && c <= '\xDFFF')) s) -> bounded s
        Just refusal -> Left refusal
        Nothing -> bounded s >> Left (valueError (name <> " must not contain control characters"))
  _ -> boundedError
  where
    bounded s = if utf8Length s <= textLimit then Right s else boundedError
    boundedError = Left (valueError (name <> " must be bounded non-empty text"))

-- | @_json(value, name)@: JSON-faithful (no non-finite floats) and at most
-- 'maxJsonBytes' in the reference's default @json.dumps@ spelling with
-- compact separators (@ensure_ascii=True@).
faithful :: Text -> Json -> Either AgenticusError Json
faithful name value = case J.dumps J.compact {J.ensureAscii = True} value of
  Left (J.NonFiniteNumber d) ->
    Left (valueError (name <> " must be JSON-faithful: Out of range float values are not JSON compliant: " <> pythonRepr (Float d)))
  Left err -> Left (valueError (name <> " must be JSON-faithful: " <> T.pack (J.encodeErrorMessage err)))
  Right bytes
    | toInteger (BS.length bytes) > maxJsonBytes ->
        Left (valueError (name <> " exceeds the " <> showT maxJsonBytes <> "-byte bound"))
    | otherwise -> Right value

-- | @_exact(data, fields, name)@.
exact :: [Text] -> Text -> Json -> Either AgenticusError [(Text, Json)]
exact fields name = \case
  Object members
    | sort (map fst members) == sort fields ->
        case lookup "version" members of
          Just (Int v) | v == agentNetVersion -> Right members
          _ -> Left (valueError (name <> " version must be integer " <> showT agentNetVersion))
  _ -> Left (valueError (name <> " requires exact fields [" <> T.intercalate ", " (map pythonStrRepr (sort fields)) <> "]"))

at :: Text -> [(Text, Json)] -> Json
at key members = maybe Null id (lookup key members)

array :: Json -> Maybe [Json]
array = \case
  Array items -> Just items
  _ -> Nothing

int :: Json -> Maybe Integer
int = \case
  Int i -> Just i
  _ -> Nothing

isDigest :: Text -> Bool
isDigest s = T.length s == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) s

pyTypeName :: Json -> Text
pyTypeName = \case
  Null -> "NoneType"
  Bool _ -> "bool"
  Int _ -> "int"
  Float _ -> "float"
  String _ -> "str"
  Array _ -> "list"
  Object _ -> "dict"

showT :: Show a => a -> Text
showT = T.pack . show

optional :: Maybe Text -> Json
optional = maybe Null String

-- ---------------------------------------------------------------------------
-- Proposal

-- | One model-proposed tool call: an identity unique within its model
-- phase, a method, and a JSON object of parameters.
data Proposal = Proposal
  { id :: Text
  , method :: Text
  , params :: Json
  }
  deriving stock (Eq, Show)

-- | @Proposal(id, method, params)@.
mkProposal :: Text -> Text -> Json -> Either AgenticusError Proposal
mkProposal i m = proposalFrom (String i) (String m)

proposalFrom :: Json -> Json -> Json -> Either AgenticusError Proposal
proposalFrom i m ps = do
  identity <- text "proposal id" i
  name <- text "proposal method" m
  parameters <- faithful "proposal params" ps
  case parameters of
    Object _ -> Right (Proposal identity name parameters)
    _ -> Left (valueError "proposal params must be an object")

proposalToData :: Proposal -> Json
proposalToData v =
  Object [("version", Int agentNetVersion), ("id", String v.id), ("method", String v.method), ("params", v.params)]

proposalFromData :: Json -> Either AgenticusError Proposal
proposalFromData d = do
  v <- exact ["version", "id", "method", "params"] "proposal" d
  proposalFrom (at "id" v) (at "method" v) (at "params" v)

-- ---------------------------------------------------------------------------
-- ModelResult

-- | One model-visible tool result: either successful object data, or the
-- exact @{"category", "detail"}@ error object (kept as given, so its key
-- order survives a round trip).
data ModelResult = ModelResult
  { id :: Text
  , ok :: Bool
  , payload :: Json
  -- ^ The object data when 'ok', otherwise @null@.
  , failure :: Maybe Json
  -- ^ The exact error object when not 'ok'.
  }
  deriving stock (Eq, Show)

-- | @ModelResult(id, ok, data, error)@ ('Nothing' is @None@).
mkModelResult :: Text -> Bool -> Json -> Maybe Json -> Either AgenticusError ModelResult
mkModelResult i o d e = modelResultFrom (String i) (Bool o) d (maybe Null id e)

-- | A successful result carrying object data.
succeeded :: Text -> Json -> Either AgenticusError ModelResult
succeeded i d = mkModelResult i True d Nothing

-- | A failed result with a category and a bounded detail.
failed :: Text -> Text -> Text -> Either AgenticusError ModelResult
failed i category detail = mkModelResult i False Null (Just (Object [("category", String category), ("detail", String detail)]))

modelResultFrom :: Json -> Json -> Json -> Json -> Either AgenticusError ModelResult
modelResultFrom i o d e = do
  identity <- text "result id" i
  isOk <- case o of
    Bool b | b == isNull e -> Right b
    _ -> Left (valueError "model result carries exactly an error when not ok")
  value <- faithful "model result data" d
  err <- faithful "model result error" e
  if isOk
    then case (value, err) of
      (Object _, Null) -> Right (ModelResult identity True value Nothing)
      _ -> Left (valueError "successful model result requires object data and null error")
    else case (value, err) of
      (Null, Object members)
        | sort (map fst members) == ["category", "detail"] -> do
            case at "category" members of
              String c | c `Set.member` errorCategories -> Right ()
              Array _ -> Left (unhashable "list")
              Object _ -> Left (unhashable "dict")
              _ -> Left (valueError "model result error category is unsupported")
            detail <- text "model result error detail" (at "detail" members)
            when (utf8Length detail > errorDetailLimit) $
              Left (valueError ("model result error detail exceeds the " <> showT errorDetailLimit <> "-byte bound"))
            Right (ModelResult identity False Null (Just err))
      _ -> Left (valueError "failed model result requires null data and an exact category/detail error")
  where
    unhashable kind = typeError ("cannot use '" <> kind <> "' as a set element (unhashable type: '" <> kind <> "')")
    isNull = \case
      Null -> True
      _ -> False

-- | The error category of a failed result.
failureCategory :: ModelResult -> Maybe Text
failureCategory r = case r.failure of
  Just (Object members) | String c <- at "category" members -> Just c
  _ -> Nothing

modelResultToData :: ModelResult -> Json
modelResultToData r = Object [("version", Int agentNetVersion), ("id", String r.id), ("result", modelResultToModelData r)]

-- | The exact model-visible Agenticus result projection.
modelResultToModelData :: ModelResult -> Json
modelResultToModelData r =
  Object [("version", Int agentNetVersion), ("ok", Bool r.ok), ("data", r.payload), ("error", maybe Null id r.failure)]

modelResultFromData :: Json -> Either AgenticusError ModelResult
modelResultFromData d = do
  v <- exact ["version", "id", "result"] "model result" d
  modelResultFromModelData (at "id" v) (at "result" v)

modelResultFromModelData :: Json -> Json -> Either AgenticusError ModelResult
modelResultFromModelData identity d = do
  v <- exact ["version", "ok", "data", "error"] "model result projection" d
  i <- text "result id" identity
  modelResultFrom (String i) (at "ok" v) (at "data" v) (at "error" v)

-- ---------------------------------------------------------------------------
-- LoopState

-- | The loop's durable state between transitions.
data LoopState = LoopState
  { episodeId :: Text
  , turnId :: Text
  , phase :: Integer
  , phaseLimit :: Integer
  , toolCount :: Integer
  , toolLimit :: Integer
  , outputRef :: Maybe Text
  , continuationRef :: Maybe Text
  , grantEpoch :: Integer
  , capabilities :: [Text]
  -- ^ Sorted and unique.
  , results :: [ModelResult]
  }
  deriving stock (Eq, Show)

-- | @LoopState(episode_id, turn_id, phase, phase_limit, tool_count,
-- tool_limit, output_ref, continuation_ref, grant_epoch, capabilities,
-- results)@.
mkLoopState
  :: Text -> Text -> Integer -> Integer -> Integer -> Integer -> Maybe Text -> Maybe Text -> Integer -> [Text] -> [ModelResult] -> Either AgenticusError LoopState
mkLoopState e tu ph pl tc tl o c g caps rs =
  loopStateFrom (String e) (String tu) (Int ph) (Int pl) (Int tc) (Int tl) (optional o) (optional c) (Int g) (map String caps) rs

loopStateFrom :: Json -> Json -> Json -> Json -> Json -> Json -> Json -> Json -> Json -> [Json] -> [ModelResult] -> Either AgenticusError LoopState
loopStateFrom e tu ph pl tc tl o c g caps rs = do
  episode <- text "episode_id" e
  turn <- text "turn_id" tu
  output <- nullable "output_ref" o
  continuation <- nullable "continuation_ref" c
  when ((output == Nothing) /= (continuation == Nothing)) $
    Left (valueError "output_ref and continuation_ref must both be absent or both be present")
  (phaseN, limitN) <- case (int ph, int pl) of
    (Just a, Just b) | 1 <= a && a <= b && b <= maxPhases -> Right (a, b)
    _ -> Left (valueError "phase ordinal and bound are invalid")
  (countN, toolN) <- case (int tc, int tl) of
    (Just a, Just b) | 0 <= a && a <= b && b <= maxTools -> Right (a, b)
    _ -> Left (valueError "tool count and bound are invalid")
  epoch <- case int g of
    Just n | n > 0 -> Right n
    _ -> Left (valueError "grant_epoch must be positive")
  names <- forM caps (text "capability")
  when (toInteger (length rs) > maxProposals || hasDuplicates [r.id | r <- rs]) $
    Left (valueError "results must be one bounded unique-identity model batch")
  Right (LoopState episode turn phaseN limitN countN toolN output continuation epoch (sortedUnique names) rs)
  where
    nullable name = \case
      Null -> Right Nothing
      value -> Just <$> text name value

-- | @to_data()@: @asdict@ order with @version@ appended last.
loopStateToData :: LoopState -> Json
loopStateToData s =
  Object
    [ ("episode_id", String s.episodeId)
    , ("turn_id", String s.turnId)
    , ("phase", Int s.phase)
    , ("phase_limit", Int s.phaseLimit)
    , ("tool_count", Int s.toolCount)
    , ("tool_limit", Int s.toolLimit)
    , ("output_ref", optional s.outputRef)
    , ("continuation_ref", optional s.continuationRef)
    , ("grant_epoch", Int s.grantEpoch)
    , ("capabilities", Array (map String s.capabilities))
    , ("results", Array (map modelResultToData s.results))
    , ("version", Int agentNetVersion)
    ]

loopStateFromData :: Json -> Either AgenticusError LoopState
loopStateFromData d = do
  v <- exact loopStateFields "loop state" d
  (caps, items) <- case (array (at "capabilities" v), array (at "results" v)) of
    (Just a, Just b) -> Right (a, b)
    _ -> Left (valueError "loop state capabilities and results must be arrays")
  rs <- mapM modelResultFromData items
  loopStateFrom
    (at "episode_id" v)
    (at "turn_id" v)
    (at "phase" v)
    (at "phase_limit" v)
    (at "tool_count" v)
    (at "tool_limit" v)
    (at "output_ref" v)
    (at "continuation_ref" v)
    (at "grant_epoch" v)
    caps
    rs

loopStateFields :: [Text]
loopStateFields =
  [ "version"
  , "episode_id"
  , "turn_id"
  , "phase"
  , "phase_limit"
  , "tool_count"
  , "tool_limit"
  , "output_ref"
  , "continuation_ref"
  , "grant_epoch"
  , "capabilities"
  , "results"
  ]

-- | Copy a state with replaced counters, references, and results, through
-- the validating constructor (the reference rebuilds @LoopState(...)@).
rebuild :: LoopState -> Integer -> Integer -> Maybe Text -> Maybe Text -> [ModelResult] -> Either AgenticusError LoopState
rebuild s ph tc o c =
  mkLoopState s.episodeId s.turnId ph s.phaseLimit tc s.toolLimit o c s.grantEpoch s.capabilities

-- ---------------------------------------------------------------------------
-- ModelSettlement

-- | A settled model phase: the state it ran on, the stop reason, the
-- assistant message digest, the new output and Continuation references,
-- and the ordered proposals.
data ModelSettlement = ModelSettlement
  { state :: LoopState
  , stop :: StopReason
  , assistantDigest :: Text
  , outputRef :: Text
  , continuationRef :: Text
  , proposals :: [Proposal]
  }
  deriving stock (Eq, Show)

mkModelSettlement :: LoopState -> StopReason -> Text -> Text -> Text -> [Proposal] -> Either AgenticusError ModelSettlement
mkModelSettlement s r dg o c = modelSettlementFrom s r (String dg) (String o) (String c)

modelSettlementFrom :: LoopState -> StopReason -> Json -> Json -> Json -> [Proposal] -> Either AgenticusError ModelSettlement
modelSettlementFrom s r dg o c ps = do
  digest <- case dg of
    String x | isDigest x -> Right x
    _ -> Left (valueError "assistant_digest must be a lowercase sha256 digest")
  output <- text "output_ref" o
  continuation <- text "continuation_ref" c
  when (toInteger (length ps) > maxProposals) $ Left (valueError "proposals exceed the bounded batch")
  when (hasDuplicates [x.id | x <- ps]) $
    Left (valueError "proposal identities must be unique within one model phase")
  Right (ModelSettlement s r digest output continuation ps)

modelSettlementToData :: ModelSettlement -> Json
modelSettlementToData m =
  Object
    [ ("version", Int agentNetVersion)
    , ("state", loopStateToData m.state)
    , ("stop", String (stopReasonText m.stop))
    , ("assistant_digest", String m.assistantDigest)
    , ("output_ref", String m.outputRef)
    , ("continuation_ref", String m.continuationRef)
    , ("proposals", Array (map proposalToData m.proposals))
    ]

modelSettlementFromData :: Json -> Either AgenticusError ModelSettlement
modelSettlementFromData d = do
  v <-
    exact
      ["version", "state", "stop", "assistant_digest", "output_ref", "continuation_ref", "proposals"]
      "model settlement"
      d
  items <- maybe (Left (valueError "model settlement proposals must be an array")) Right (array (at "proposals" v))
  s <- loopStateFromData (at "state" v)
  r <- parseStopReason (at "stop" v)
  ps <- mapM proposalFromData items
  modelSettlementFrom s r (at "assistant_digest" v) (at "output_ref" v) (at "continuation_ref" v) ps

-- ---------------------------------------------------------------------------
-- ToolWork

-- | One position in a proposal batch, with the state carrying exactly the
-- results of the preceding proposals.
data ToolWork = ToolWork
  { state :: LoopState
  , assistantDigest :: Text
  , proposals :: [Proposal]
  , index :: Int
  , indexSpelling :: Json
  -- ^ The index as the wire spelled it: an integer, or a boolean the
  -- reference accepts as one (@0 <= True@) and writes back unchanged.
  }
  deriving stock (Eq, Show)

mkToolWork :: LoopState -> Text -> [Proposal] -> Int -> Either AgenticusError ToolWork
mkToolWork s dg ps i = toolWorkFrom s (String dg) ps (Int (toInteger i))

-- | @ToolWork.__post_init__@, including how the reference's comparisons and
-- slicing treat an index that is not an integer.
toolWorkFrom :: LoopState -> Json -> [Proposal] -> Json -> Either AgenticusError ToolWork
toolWorkFrom s dg ps i = do
  let size = length ps
      positionError = valueError "tool work requires a valid non-empty batch position"
      inRange n = 0 <= n && n < toInteger size
      incomparable kind = Left (typeError ("'<=' not supported between instances of 'int' and '" <> kind <> "'"))
  position <-
    if null ps
      then Left positionError
      else case i of
        Int n | inRange n -> Right (Just (fromInteger n))
        Bool b | inRange (if b then 1 else 0) -> Right (Just (if b then 1 else 0))
        Float f | 0 <= f && f < fromIntegral size -> Right Nothing
        Null -> incomparable "NoneType"
        String _ -> incomparable "str"
        Array _ -> incomparable "list"
        Object _ -> incomparable "dict"
        _ -> Left positionError
  when (toInteger size > maxProposals || hasDuplicates [x.id | x <- ps]) $
    Left (valueError "tool work requires one bounded unique-identity proposal batch")
  digest <- case dg of
    String x
      | isDigest x -> Right x
      | otherwise -> Left (valueError "assistant_digest must be a lowercase sha256 digest")
    other -> Left (typeError ("expected string or bytes-like object, got '" <> pyTypeName other <> "'"))
  case position of
    Nothing -> Left (typeError "slice indices must be integers or None or have an __index__ method")
    Just n -> do
      unless ([r.id | r <- s.results] == [x.id | x <- take n ps]) $
        Left (valueError "tool work state must contain exactly the preceding ordered results")
      Right (ToolWork s digest ps n i)

-- | The proposal at this position.
toolWorkProposal :: ToolWork -> Proposal
toolWorkProposal w = w.proposals !! w.index

toolWorkToData :: ToolWork -> Json
toolWorkToData w =
  Object
    [ ("version", Int agentNetVersion)
    , ("state", loopStateToData w.state)
    , ("assistant_digest", String w.assistantDigest)
    , ("proposals", Array (map proposalToData w.proposals))
    , ("index", w.indexSpelling)
    ]

toolWorkFromData :: Json -> Either AgenticusError ToolWork
toolWorkFromData d = do
  v <- exact ["version", "state", "assistant_digest", "proposals", "index"] "tool work" d
  items <- maybe (Left (valueError "tool work proposals must be an array")) Right (array (at "proposals" v))
  s <- loopStateFromData (at "state" v)
  ps <- mapM proposalFromData items
  toolWorkFrom s (at "assistant_digest" v) ps (at "index" v)

-- ---------------------------------------------------------------------------
-- HandsSettlement

data HandsSettlement = HandsSettlement
  { work :: ToolWork
  , result :: ModelResult
  }
  deriving stock (Eq, Show)

mkHandsSettlement :: ToolWork -> ModelResult -> Either AgenticusError HandsSettlement
mkHandsSettlement w r
  | r.id /= (toolWorkProposal w).id = Left (valueError "Hands result id must match the proposal")
  | otherwise = Right (HandsSettlement w r)

handsSettlementToData :: HandsSettlement -> Json
handsSettlementToData h =
  Object [("version", Int agentNetVersion), ("work", toolWorkToData h.work), ("result", modelResultToData h.result)]

handsSettlementFromData :: Json -> Either AgenticusError HandsSettlement
handsSettlementFromData d = do
  v <- exact ["version", "work", "result"] "Hands settlement" d
  w <- toolWorkFromData (at "work" v)
  r <- modelResultFromData (at "result" v)
  mkHandsSettlement w r

-- ---------------------------------------------------------------------------
-- Terminal

data Terminal = Terminal
  { episodeId :: Text
  , turnId :: Text
  , code :: TerminalCode
  , phases :: Integer
  , tools :: Integer
  , outputRef :: Text
  , continuationRef :: Text
  }
  deriving stock (Eq, Show)

mkTerminal :: Text -> Text -> TerminalCode -> Integer -> Integer -> Text -> Text -> Either AgenticusError Terminal
mkTerminal e tu c ph tl o co = terminalFrom (String e) (String tu) c (Int ph) (Int tl) (String o) (String co)

terminalFrom :: Json -> Json -> TerminalCode -> Json -> Json -> Json -> Json -> Either AgenticusError Terminal
terminalFrom e tu c ph tl o co = do
  episode <- text "terminal episode_id" e
  turn <- text "terminal turn_id" tu
  phasesN <- case int ph of
    Just n | 1 <= n && n <= maxPhases -> Right n
    _ -> Left (valueError "terminal phases must be a bounded positive integer")
  toolsN <- case int tl of
    Just n | 0 <= n && n <= maxTools -> Right n
    _ -> Left (valueError "terminal tools must be a bounded nonnegative integer")
  output <- text "terminal output_ref" o
  continuation <- text "terminal continuation_ref" co
  Right (Terminal episode turn c phasesN toolsN output continuation)

terminalToData :: Terminal -> Json
terminalToData x =
  Object
    [ ("version", Int agentNetVersion)
    , ("episode_id", String x.episodeId)
    , ("turn_id", String x.turnId)
    , ("code", String (terminalCodeText x.code))
    , ("phases", Int x.phases)
    , ("tools", Int x.tools)
    , ("output_ref", String x.outputRef)
    , ("continuation_ref", String x.continuationRef)
    ]

terminalFromData :: Json -> Either AgenticusError Terminal
terminalFromData d = do
  v <-
    exact
      ["version", "episode_id", "turn_id", "code", "phases", "tools", "output_ref", "continuation_ref"]
      "terminal"
      d
  c <- parseTerminalCode (at "code" v)
  terminalFrom (at "episode_id" v) (at "turn_id" v) c (at "phases" v) (at "tools" v) (at "output_ref" v) (at "continuation_ref" v)

-- ---------------------------------------------------------------------------
-- Tokens and routing

-- | @initial_marking(state)@.
initialMarking :: LoopState -> Marking
initialMarking s = markingFromList [(modelPending, [Token (Just "LoopState") (loopStateToData s)])]

-- | The recorded failure text of a raised error: Python's @repr(error)@.
failureText :: AgenticusError -> Text
failureText e = errorClassName e.errorClass <> "(" <> pythonStrRepr e.errorMessage <> ")"

-- | Run a validation inside a handler: a refusal is the handler raising.
raise :: Either AgenticusError a -> Either Text a
raise = either (Left . failureText) Right

terminalToken :: LoopState -> TerminalCode -> Either AgenticusError Token
terminalToken s c = case (s.outputRef, s.continuationRef) of
  (Just o, Just co) ->
    Token (Just "Terminal") . terminalToData <$> mkTerminal s.episodeId s.turnId c s.phase s.toolCount o co
  _ -> Left (valueError "terminal state requires settled output and Continuation references")

firstToken :: Binding -> Either Text Token
firstToken b = case bindingTokens b of
  x : _ -> Right x
  [] -> Left "IndexError('tuple index out of range')"

onlyToken :: Binding -> Either Text Token
onlyToken b = case bindingTokens b of
  [x] -> Right x
  [] -> Left "ValueError('not enough values to unpack (expected 1, got 0)')"
  xs -> Left ("ValueError('too many values to unpack (expected 1, got " <> showT (length xs) <> ")')")

emit :: NetPath -> Token -> HandlerResult
emit place tok = handlerTokens [(place, [tok])]

toDone :: LoopState -> TerminalCode -> Either AgenticusError HandlerResult
toDone s c = emit done <$> terminalToken s c

toModel :: LoopState -> HandlerResult
toModel s = emit modelPending (Token (Just "LoopState") (loopStateToData s))

toTools :: ToolWork -> HandlerResult
toTools w = emit toolPending (Token (Just "ToolWork") (toolWorkToData w))

-- | @_classify@: route a settled model phase.
classifyHandler :: Handler
classifyHandler b _ = do
  tok <- firstToken b
  raise $ do
    settled <- modelSettlementFromData tok.payload
    let s0 = settled.state
    s <- rebuild s0 s0.phase s0.toolCount (Just settled.outputRef) (Just settled.continuationRef) []
    case settled.stop of
      ErrorStop -> toDone s Failed
      Aborted -> toDone s Cancelled
      _
        | null settled.proposals -> toDone s Completed
        | settled.stop == Length -> do
            rejected <- forM settled.proposals $ \x -> failed x.id "provider" "proposal rejected after length stop"
            s' <- rebuild s s.phase s.toolCount s.outputRef s.continuationRef (s.results <> rejected)
            if s'.phase >= s'.phaseLimit
              then toDone s' PhaseBudget
              else toModel <$> rebuild s' (s'.phase + 1) s'.toolCount s'.outputRef s'.continuationRef s'.results
        | s.toolCount >= s.toolLimit -> toDone s ToolBudget
        | otherwise -> toTools <$> mkToolWork s settled.assistantDigest settled.proposals 0

-- | @_next@: append one result, optionally counting a Hands call.
next :: LoopState -> ModelResult -> Bool -> Either AgenticusError LoopState
next s r counted = rebuild s s.phase (s.toolCount + (if counted then 1 else 0)) s.outputRef s.continuationRef (s.results <> [r])

-- | @_continue@: the next proposal, the phase budget, or the next phase.
continue :: ToolWork -> LoopState -> Either AgenticusError HandlerResult
continue w s
  | w.index + 1 < length w.proposals = toTools <$> mkToolWork s w.assistantDigest w.proposals (w.index + 1)
  | s.phase >= s.phaseLimit = toDone s PhaseBudget
  | otherwise = toModel <$> rebuild s (s.phase + 1) s.toolCount s.outputRef s.continuationRef s.results

-- | @_reject_tool@: a pure, ordered refusal of an unsupported, ungranted,
-- or over-budget proposal.
rejectHandler :: Handler
rejectHandler b _ = do
  tok <- firstToken b
  raise $ do
    w <- toolWorkFromData tok.payload
    let budget = w.state.toolCount >= w.state.toolLimit
        (category, detail)
          | budget = ("budget", "tool budget exhausted")
          | otherwise = ("capability", "tool is unsupported or not granted")
    r <- failed (toolWorkProposal w).id category detail
    s <- next w.state r False
    if budget then toDone s ToolBudget else continue w s

-- | @_record@: fold one Hands result into the state.
recordHandler :: Handler
recordHandler b _ = do
  tok <- firstToken b
  raise $ do
    settled <- handsSettlementFromData tok.payload
    s <- next settled.work.state settled.result True
    if failureCategory settled.result == Just "aborted"
      then toDone s Cancelled
      else continue settled.work s

allowed :: ToolWork -> Bool
allowed w = (toolWorkProposal w).method `elem` w.state.capabilities && w.state.toolCount < w.state.toolLimit

-- | @_execute@: the proposal is granted and within the tool budget.
executeGuard :: Guard
executeGuard b = firstToken b >>= \tok -> raise (allowed <$> toolWorkFromData tok.payload)

-- | @_reject@: the complement of 'executeGuard'.
rejectGuard :: Guard
rejectGuard b = firstToken b >>= \tok -> raise (not . allowed <$> toolWorkFromData tok.payload)

-- | The model-phase Activity bridge (@_ModelActivity@).
modelActivityHandler :: ActivityHandler
modelActivityHandler =
  ActivityHandler
    { prepare = \b -> do
        tok <- onlyToken b
        void (raise (loopStateFromData tok.payload))
        prepareInvocation (defaultInvocationFields modelPhaseActivity tok.payload)
    , project = \b value -> do
        tok <- onlyToken b
        raise $ do
          expected <- loopStateFromData tok.payload
          settled <- modelSettlementFromData value
          when (settled.state /= expected) $
            Left (valueError "model activity result does not match its recorded loop state")
          Right (emit modelSettled (Token (Just "ModelSettlement") (modelSettlementToData settled)))
    , projectFailure = Nothing
    }

-- | The Hands Activity bridge (@_HandsActivity@).
handsActivityHandler :: ActivityHandler
handsActivityHandler =
  ActivityHandler
    { prepare = \b -> do
        tok <- onlyToken b
        w <- raise (toolWorkFromData tok.payload)
        prepareInvocation
          ( defaultInvocationFields
              handsActivity
              ( Object
                  [ ("version", Int agentNetVersion)
                  , ("proposal", proposalToData (toolWorkProposal w))
                  , ("grant_epoch", Int w.state.grantEpoch)
                  ]
              )
          )
    , project = \b value -> do
        tok <- onlyToken b
        raise $ do
          w <- toolWorkFromData tok.payload
          v <- exact ["version", "result"] "Hands activity result" value
          r <- modelResultFromData (at "result" v)
          settled <- mkHandsSettlement w r
          Right (emit toolSettled (Token (Just "HandsSettlement") (handsSettlementToData settled)))
    , projectFailure = Nothing
    }

-- ---------------------------------------------------------------------------
-- The Net

-- | The authored Net with its pure implementations, before the two Activity
-- bridges are bound by URI.
authored :: BuiltNet
authored = either (error . show) id $ do
  spec <- netSpec (withCompletion (CompletionCel (unsafeCel "size(done) != 0")) (named "agent-as-net")) $ do
    pending <- p "model_pending" >>= color "LoopState"
    settled <- p "model_settled" >>= color "ModelSettlement"
    work <- p "tool_pending" >>= color "ToolWork"
    handsSettled <- p "tool_settled" >>= color "HandsSettlement"
    finished <- p "done" >>= color "Terminal"
    model <- t "model_phase" >>= configure [handler "model_phase"]
    classify <- t "classify_model" >>= configure [handler (petriHandler "_classify" classifyHandler)]
    execute <- t "execute_tool" >>= configure [handler "hands", guards [petriGuard "_execute" executeGuard]]
    reject <-
      t "reject_tool"
        >>= configure [handler (petriHandler "_reject_tool" rejectHandler), guards [petriGuard "_reject" rejectGuard]]
    record <- t "record_result" >>= configure [handler (petriHandler "_record" recordHandler)]
    let colored c = arc {Dsl.arcColor = Just c}
    void $ pending ~> colored "LoopState" ~> model ~> colored "ModelSettlement" ~> settled
    void $ settled ~> colored "ModelSettlement" ~> classify
    void $ classify ~> colored "LoopState" ~> pending
    void $ classify ~> colored "ToolWork" ~> work
    void $ classify ~> colored "Terminal" ~> finished
    void $ work ~> colored "ToolWork" ~> [execute, reject]
    void $ execute ~> colored "HandsSettlement" ~> handsSettled ~> colored "HandsSettlement" ~> record
    void $ reject ~> colored "ToolWork" ~> work
    void $ reject ~> colored "LoopState" ~> pending
    void $ reject ~> colored "Terminal" ~> finished
    void $ record ~> colored "ToolWork" ~> work
    void $ record ~> colored "LoopState" ~> pending
    void $ record ~> colored "Terminal" ~> finished
  build spec

-- | The built Net with every implementation, the Activity bridges bound by
-- canonical URI as the reference binds them after its build.
agentNetBuilt :: BuiltNet
agentNetBuilt =
  authored
    { handlers =
        Map.union
          ( Map.fromList
              [ (uri, ActivityBound bridge)
              | (at', bridge) <- [(modelPhase, modelActivityHandler), (executeTool, handsActivityHandler)]
              , Just uri <- [handlerUri authored.net at']
              ]
          )
          authored.handlers
    }

-- | The static immutable Agent-as-Net topology (@AGENT_AS_NET@).
agentNet :: Net
agentNet = agentNetBuilt.net

agentNetHandlersByUri :: Map NetUri BoundHandler
agentNetHandlersByUri = agentNetBuilt.handlers

agentNetGuardsByUri :: Map NetUri Guard
agentNetGuardsByUri = agentNetBuilt.guards

-- | @agent_net_handlers()@, keyed for an Engine or Instance.
agentNetHandlers :: Map ImplementationRef BoundHandler
agentNetHandlers = Map.mapKeys Exact agentNetHandlersByUri

-- | @agent_net_guards()@, keyed for an Engine or Instance.
agentNetGuards :: Map ImplementationRef Guard
agentNetGuards = Map.mapKeys Exact agentNetGuardsByUri

-- | Engine options hosting Agent-as-Net: the Net's handlers and guards and
-- the CEL compilers its completion condition (@size(done) != 0@) needs
-- (the reference Engine compiles CEL by default).
agentNetOptions :: Engine.EngineOptions -> Engine.EngineOptions
agentNetOptions options =
  options
    { Engine.handlers = Map.union agentNetHandlers options.handlers
    , Engine.guards = Map.union agentNetGuards options.guards
    , Engine.celCompilers = Cel.celCompilers
    }

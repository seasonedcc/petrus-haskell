-- | The Hamsterdan protocol adapter over an injected Pi native A2 runtime
-- lifecycle (@hamsterdan.agents.pi@): the canonical prompt envelope, the
-- result admission, and 'PiNativeRunner'.
module Hamsterdan.Agents.Pi
  ( -- * Prompts
    PromptKind (..)
  , promptKindText
  , encodePrompt
  , responseContract
  , semantics
  , maxResultBytes

    -- * Workspaces
  , PiWorkspaceError (..)
  , PreparedPiWorkspace (..)
  , PiWorkspaceProvider (..)

    -- * The runtime seam
  , PiOperation (..)
  , PiRuntime (..)
  , piA2Runtime

    -- * The runner
  , PiNativeRunner
  , PiRunnerOptions (..)
  , defaultPiRunnerOptions
  , newPiNativeRunner
  , runPi
  , piAgentRunner
  , unavailablePiRunner
  , piOperationId
  , parseResult
  ) where

import Control.Exception
  ( Exception
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (void, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.IORef
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Agents.Protocol
import Hamsterdan.Agents.Url qualified as Url
import Hamsterdan.Agents.Validate
import Hamsterdan.Contracts.Codec (contract, encode)
import Hamsterdan.PyText (utf8Length)
import Hamsterdan.PyLiteral (PyValue (..), repr)
import Petrus.Agenticus.Error (AgenticusError, ErrorClass (RuntimeProtocolError, TimeoutError), isInstanceOf)
import Petrus.Agenticus.Runtime.Operation (RuntimeOperationCleanup (..), cleanupVerified)
import Petrus.Agenticus.Runtime.PiA2Host
  ( PiA2RuntimeHost
  , PiA2RuntimePolicy
  , PiA2RuntimeStart (..)
  , cancelPiA2
  , closePiA2
  , loadOutput
  , loadWorkspaceArchive
  , newPiA2RuntimeStart
  , piA2OperationId
  , startHost
  , waitPiA2
  )
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Identity (literalEpisodeId, literalTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsText, parseJson, pythonLoads)

-- ---------------------------------------------------------------------------
-- Prompts

-- | The three request kinds.
data PromptKind = ReviewKind | ConversationKind | CodingKind
  deriving stock (Eq, Show)

promptKindText :: PromptKind -> Text
promptKindText = \case
  ReviewKind -> "review"
  ConversationKind -> "conversation"
  CodingKind -> "coding"

resultKind :: PromptKind -> ResultKind
resultKind = \case
  ReviewKind -> KindReview
  ConversationKind -> KindConversation
  CodingKind -> KindCoding

-- | @_SEMANTICS[kind]@.
semantics :: PromptKind -> Text
semantics = \case
  ReviewKind ->
    "Review the exact supplied PR generation using the supplied policy, evidence, prior findings, and lenses. "
      <> "Read request.diff_path and its companion request.diff_path + '.lines', which lists changed head files "
      <> "with exact one-based line numbers including blank lines. Copy primary and related anchors from those "
      <> "numbered statements; never estimate line numbers or anchor a code suggestion on an adjacent docstring. "
      <> "For other related files, count every source line from one, including blank lines. "
      <> "Return only evidenced actionable findings with consistent lineage."
  ConversationKind ->
    "Interpret the supplied comment against the current dashboard, gates, findings, and allowed intents. "
      <> "Select exactly one declared intent and never invent workflow state or authorization."
  CodingKind ->
    "Propose the smallest conservative change for the supplied work and report bounded validation evidence. "
      <> "Never claim a changed repair without confirmed reproduction."

promptFields :: Set.Set Text
promptFields = Set.fromList ["instructions", "kind", "prompt_version", "repository_url", "request", "response_contract"]

maxResultBytes :: Int
maxResultBytes = 1000000

-- | @f"one of {sorted(values)}"@.
oneOf :: Set.Set Text -> Text
oneOf values = "one of " <> repr (PyList (map PyStr (Set.toAscList values)))

-- | @_contract_fields(names, descriptions)@. The descriptions below cover
-- the validator's field sets exactly (the reference checks this at run
-- time; the test suite checks it here).
contractFields :: [(Text, Text)] -> Json
contractFields descriptions = Object [(name, String description) | (name, description) <- descriptions]

-- | @_response_contract(kind)@.
responseContract :: PromptKind -> Json
responseContract kind =
  Object
    [ ("return_format", String "Return exactly one JSON object and nothing else; no Markdown or prose.")
    , ("exact_fields", contractFields (exactCommon <> exactKind))
    , ("nested", nested)
    , ("invariants", Array (map String invariants))
    , ("forbidden_envelope_fields", Array (map String (Set.toAscList (Set.difference promptFields resultFields))))
    ]
  where
    exactCommon =
      [ ("repository", "string; copy request.repository exactly")
      , ("pull_request", "integer; copy request.pull_request exactly")
      , ("epoch", "integer; copy request.epoch exactly")
      , ("head", "string; copy request.head exactly")
      , ("base", "string; copy request.base exactly")
      ]
    (exactKind, nested, invariants, resultFields) = case kind of
      ReviewKind ->
        ( [ ("status", oneOf reviewStatuses)
          , ("findings", "array of finding objects; use [] when none")
          , ("lineage", "array of lineage objects; use [] when none")
          ]
        , Object
            [ ( "finding_exact_fields"
              , contractFields
                  [ ("id", "unique 1-48 ASCII-character identifier matching " <> findingIdPattern <> "; colon and whitespace are forbidden")
                  , ("path", "repository-relative path")
                  , ("line", "positive integer line number")
                  , ("related_locations", "array of related-location objects; primary location must not repeat")
                  , ("title", "non-empty string")
                  , ("body", "non-empty actionable explanation")
                  , ("severity", oneOf findingSeverities)
                  , ("confidence", "number from 0 through 1")
                  , ("evidence", "non-empty evidenced observation")
                  , ("blocking", "boolean")
                  , ("suggestion", "string; empty when absent; no Markdown code fence")
                  ]
              )
            ,
              ( "related_location_exact_fields"
              , contractFields [("path", "repository-relative path"), ("line", "positive integer line number")]
              )
            ,
              ( "lineage_exact_fields"
              , contractFields
                  [
                    ( "finding_id"
                    , "unique within lineage; for new and still_open copy an exact returned finding.id matching "
                        <> findingIdPattern
                    )
                  , ("state", oneOf lineageStates)
                  , ("supersedes", "prior finding identifier or null")
                  ]
              )
            ]
        ,
          [ "status clear has no blocking finding; status blocking has at least one blocking finding"
          , "new and still_open lineage references a returned finding"
          , "new lineage has null supersedes; superseded lineage has a non-null predecessor"
          ]
        , reviewResultFields
        )
      ConversationKind ->
        ( [("intents", "array containing exactly one intent object")]
        , Object
            [
              ( "intent_exact_fields"
              , contractFields
                  [ ("type", "copy one type declared in request.allowed_intents")
                  , ("arguments", "object with exactly the argument keys declared for that type")
                  , ("mutation", "boolean equal to that declaration's mutation value")
                  , ("explicit", "boolean; true for mutations and declarations requiring explicit intent")
                  , ("confidence", "number from 0 through 1")
                  ]
              )
            ]
        ,
          [ "return exactly one declared intent and never invent an intent or argument key"
          , "mutation intents require concrete non-empty arguments"
          ]
        , conversationResultFields
        )
      CodingKind ->
        (
          [ ("kind", "string; copy request.kind exactly")
          , ("ref", "string; copy request.ref exactly")
          , ("status", oneOf codingStatuses)
          , ("reproduction_status", oneOf reproductionStatuses)
          , ("diff", "string; empty unless status is changed")
          , ("changed_files", "sorted unique array of repository-relative paths changed in the workspace")
          , ("validation_evidence", "array of non-empty bounded JSON objects; non-empty when status is changed")
          , ("proposed_commit_message", "string; non-empty when changed, with a first line of at most 72 characters")
          ]
        , Object []
        ,
          [ "status changed only when the workspace changed; otherwise use unchanged or unable"
          , "a changed repair requires reproduction_status confirmed"
          , "report only validation actually performed"
          ]
        , codingResultFields
        )

-- | @asdict(request)@.
requestData :: AgentRequest -> Json
requestData = \case
  AgentReview r -> encode contract r
  AgentConversation r -> encode contract r
  AgentCoding r -> encode contract r

sortedCompact :: EncodeOptions
sortedCompact = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True}

-- | @encode_prompt(kind, repository_url, request)@: one canonical bounded
-- Pi prompt without execution authority. A @ValueError@ from @urlsplit@ is
-- a 'Foreign' failure, as upstream.
encodePrompt :: PromptKind -> Text -> AgentRequest -> V Text
encodePrompt kind repositoryUrl request = do
  validateRequest request
  url <- text (String repositoryUrl) "repository URL" False 4096
  parsed <- either (foreignFailure "ValueError") Right (Url.urlsplit url)
  when
    ( parsed.scheme `notElem` ["http", "https"]
        || maybe False (not . T.null) (Url.username parsed)
        || maybe False (not . T.null) (Url.password parsed)
        || not (T.null parsed.query)
        || not (T.null parsed.fragment)
    )
    $ refuse "repository URL contains credentials or noncanonical data"
  let payload =
        Object
          [ ("instructions", String (semantics kind))
          , ("kind", String (promptKindText kind))
          , ("prompt_version", Int (if kind == ReviewKind then 3 else 2))
          , ("repository_url", String (Url.urlunsplit parsed {Url.query = "", Url.fragment = ""}))
          , ("request", requestData request)
          , ("response_contract", responseContract kind)
          ]
  prompt <- either (const (foreignFailure "ValueError" "Out of range float values are not JSON compliant")) Right (dumpsText sortedCompact payload)
  when (utf8Length prompt > 64 * 1024) $ refuse "Pi prompt exceeded limit"
  pure prompt

-- ---------------------------------------------------------------------------
-- Workspaces

-- | @PiWorkspaceError@ and its @PiWorkspaceCleanupError@ subclass.
data PiWorkspaceError
  = PiWorkspaceError Text
  | -- | @PiWorkspaceCleanupError(preparation_failed=...)@.
    PiWorkspaceCleanupError Bool
  deriving stock (Eq, Show)

instance Exception PiWorkspaceError

-- | @PreparedPiWorkspace@.
data PreparedPiWorkspace = PreparedPiWorkspace
  { archive :: ByteString
  , digest :: Text
  , correlation :: Text
  , policy :: PiA2RuntimePolicy
  , reconcile :: ByteString -> IO (Text, [Text])
  }

-- | @PiWorkspaceProvider.open(kind, repository_url, request, operation_id)@
-- as a bracket: preparation, the body, then cleanup (which may throw
-- 'PiWorkspaceCleanupError').
newtype PiWorkspaceProvider = PiWorkspaceProvider
  { open :: forall a. PromptKind -> Text -> AgentRequest -> Text -> (PreparedPiWorkspace -> IO a) -> IO a
  }

-- ---------------------------------------------------------------------------
-- The runtime seam

-- | One started Pi operation. 'operationId' is an action because the
-- reference reads a property that an injected operation may fail.
data PiOperation = PiOperation
  { operationId :: IO Text
  , wait :: Maybe Double -> IO RuntimeTurnSettlement
  , cancel :: Text -> IO ()
  , close :: IO RuntimeOperationCleanup
  }

-- | The part of @PiA2RuntimeHost@ the runner uses.
data PiRuntime = PiRuntime
  { start :: PiA2RuntimeStart -> IO PiOperation
  , loadOutput :: Text -> IO Text
  , loadWorkspaceArchive :: Text -> IO ByteString
  }

-- | The Petrus host as a 'PiRuntime'.
piA2Runtime :: PiA2RuntimeHost -> PiRuntime
piA2Runtime host =
  PiRuntime
    { start = \s -> do
        operation <- startHost host s
        pure
          PiOperation
            { operationId = pure (piA2OperationId operation)
            , wait = waitPiA2 operation
            , cancel = void . cancelPiA2 operation
            , close = closePiA2 operation
            }
    , loadOutput = loadOutput host
    , loadWorkspaceArchive = loadWorkspaceArchive host
    }

-- ---------------------------------------------------------------------------
-- The runner

-- | @PiNativeRunner(runtime, workspaces, timeout=..., poll_interval=...,
-- clock=...)@ options.
data PiRunnerOptions = PiRunnerOptions
  { timeout :: Maybe Double
  , pollInterval :: Double
  , clock :: IO Double
  }

defaultPiRunnerOptions :: PiRunnerOptions
defaultPiRunnerOptions = PiRunnerOptions {timeout = Nothing, pollInterval = 0.1, clock = getMonotonicTime}

data PiNativeRunner = PiNativeRunner
  { runtime :: PiRuntime
  , workspaces :: PiWorkspaceProvider
  , options :: PiRunnerOptions
  }

finite :: Double -> Bool
finite d = not (isNaN d || isInfinite d)

-- | The constructor's validation; 'Left' is the @ValueError@ message.
newPiNativeRunner :: PiRuntime -> PiWorkspaceProvider -> PiRunnerOptions -> Either Text PiNativeRunner
newPiNativeRunner runtime workspaces options
  | not (finite options.pollInterval) || options.pollInterval <= 0 = invalid
  | Just t <- options.timeout, not (finite t) || t <= 0 || options.pollInterval > t = invalid
  | otherwise = Right PiNativeRunner {runtime, workspaces, options}
  where
    invalid = Left "Pi runner timeout and poll interval must be positive and ordered"

sha256Hex :: Text -> Text
sha256Hex = TE.decodeUtf8 . Base16.encode . SHA256.hash . TE.encodeUtf8

-- | @pi:{sha256(f"{operation}\0{attempt}")}@.
piOperationId :: Text -> Integer -> Text
piOperationId operation attempt = "pi:" <> sha256Hex (operation <> "\0" <> T.pack (show attempt))

agentError :: Text -> AgentResultCategory -> AgentProtocolError
agentError reason category = (protocolError reason) {resultCategory = Just category}

superseded :: AgentProtocolError
superseded = (protocolError "agent attempt superseded") {canceled = True}

-- | Catch what @except Exception@ catches (not asynchronous exceptions).
trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left e | isJust (fromException @SomeAsyncException e) -> throwIO e
    other -> pure other

agenticusIs :: ErrorClass -> SomeException -> Bool
agenticusIs cls e = case fromException @AgenticusError e of
  Just err -> err `isInstanceOf` cls
  Nothing -> False

notCurrent :: Maybe (IO Bool) -> IO Bool
notCurrent = maybe (pure False) (fmap not)

-- | @PiNativeRunner._run(kind, repository_url, request, operation,
-- attempt, is_current)@.
runPi :: PiNativeRunner -> PromptKind -> Text -> AgentRequest -> Invocation -> IO AgentResult
runPi runner kind repositoryUrl request invocation = do
  logical <- either throwFailure pure (text (String invocation.operation) "operation" False 1024)
  when (invocation.attempt < 1) $ throwIO (agentError "invalid agent attempt" Correlation)
  let operationId = piOperationId logical invocation.attempt
  prompt <- case encodePrompt kind repositoryUrl request of
    Right prompt -> pure prompt
    Left (Refused failure) -> throwIO (retainResultCategory Correlation failure)
    Left other -> throwFailure other
  stale <- notCurrent invocation.isCurrent
  when stale $ throwIO superseded
  resultRef <- newIORef Nothing
  failureRef <- newIORef Nothing
  let PiWorkspaceProvider openWorkspace = runner.workspaces
  outcome <- try $ openWorkspace kind repositoryUrl request operationId $ \workspace -> do
    attempt <- try $ do
      staleAgain <- notCurrent invocation.isCurrent
      when staleAgain $ throwIO superseded
      runWorkspace runner kind prompt request operationId invocation.isCurrent workspace
    case attempt of
      Right result -> writeIORef resultRef (Just result)
      Left failure -> writeIORef failureRef (Just failure)
  case outcome of
    Right () -> pure ()
    Left (PiWorkspaceCleanupError preparationFailed) ->
      readIORef failureRef >>= \case
        Nothing ->
          writeIORef failureRef . Just $
            AgentProtocolError
              { reason = "Pi workspace cleanup is unverified"
              , canceled = False
              , timedOut = False
              , resultCategory = if preparationFailed then Just WorkspaceReconciliation else Nothing
              , cleanupCategory = Just CleanupUnverified
              }
        Just failure -> writeIORef failureRef (Just (retainCleanupCategory CleanupUnverified failure))
    Left (PiWorkspaceError _) ->
      readIORef failureRef >>= \case
        Nothing -> writeIORef failureRef (Just (agentError "Pi workspace proof failed" WorkspaceReconciliation))
        Just _ -> pure ()
  readIORef failureRef >>= maybe (pure ()) throwIO
  readIORef resultRef >>= maybe (throwIO (agentError "Pi operation result is unavailable" RuntimeLifecycle)) pure

-- | @PiNativeRunner._run_workspace(...)@.
runWorkspace
  :: PiNativeRunner -> PromptKind -> Text -> AgentRequest -> Text -> Maybe (IO Bool) -> PreparedPiWorkspace -> IO AgentResult
runWorkspace runner kind prompt request operationId isCurrent workspace = do
  let identity = sha256Hex operationId
  started <- trySync $ do
    start <-
      newPiA2RuntimeStart
        PiA2RuntimeStart
          { operationId
          , episodeId = literalEpisodeId ("episode-" <> identity)
          , turnId = literalTurnId ("turn-" <> identity)
          , prompt
          , workspaceArchive = workspace.archive
          , workspaceDigest = workspace.digest
          , workspaceCorrelation = workspace.correlation
          , policy = workspace.policy
          , continuation = Nothing
          }
    operation <- runner.runtime.start start
    pure (start, operation)
  (start, operation) <- case started of
    Right value -> pure value
    Left e
      | Just (failure :: AgentProtocolError) <- fromException e -> throwIO failure
      | otherwise -> throwIO (agentError "Pi operation could not start" RuntimeLifecycle)
  startedRef <- newIORef Nothing
  attempt <- trySync $ do
    startedId <- operation.operationId
    writeIORef startedRef (Just startedId)
    when (startedId /= operationId) $ do
      cancelQuietly operation "operation-mismatch"
      throwIO (agentError "Pi operation identity mismatched its route" Correlation)
    settlement <- waitFor runner operation isCurrent
    when (settlement.episodeId /= start.episodeId || settlement.turnId /= start.turnId) $
      throwIO (agentError "Pi settlement identity mismatched its route" Correlation)
    reference <- case settlement.outputReference of
      Just reference
        | settlement.outcome == TurnCompleted && settlement.acceptedAppends == 1 -> pure reference
      _
        | settlement.outcome == TurnCancelled ->
            throwIO (agentError "agent attempt canceled" RuntimeLifecycle) {canceled = True}
        | otherwise -> throwIO (agentError "Pi operation did not produce a completed result" RuntimeLifecycle)
    raw <- runner.runtime.loadOutput reference
    parsed <- case parseResult raw of
      Right members -> pure members
      Left (Refused failure) -> throwIO (retainResultCategory OutputSchema failure)
      Left other -> throwFailure other
    (members, changed) <- case kind of
      CodingKind -> do
        loaded <- trySync (runner.runtime.loadWorkspaceArchive operationId)
        archive <- case loaded of
          Left e
            | agenticusIs RuntimeProtocolError e ->
                throwIO (agentError "Pi coding workspace archive is unavailable" WorkspaceReconciliation)
            | otherwise -> throwIO e
          Right archive -> pure archive
        when (BS.null archive) $
          throwIO (agentError "Pi coding workspace archive is unavailable" WorkspaceReconciliation)
        reconciled <- try (workspace.reconcile archive)
        (diff, changed) <- case reconciled of
          Left (_ :: PiWorkspaceError) -> throwIO (agentError "Pi workspace proof failed" WorkspaceReconciliation)
          Right value -> pure value
        pure (setMember "changed_files" (Array (map String changed)) (setMember "diff" (String diff) parsed), Just changed)
      _ -> pure (parsed, Nothing)
    case validateResult (resultKind kind) (Object members) request changed of
      Right result -> pure result
      Left (Refused failure) -> throwIO (retainResultCategory OutputSchema failure)
      Left other -> throwFailure other
  failure0 <- case attempt of
    Right result -> pure (Right result)
    Left e
      | Just (failure :: AgentProtocolError) <- fromException e -> pure (Left failure)
      | Just (_ :: PiWorkspaceError) <- fromException e ->
          pure (Left (agentError "Pi workspace proof failed" WorkspaceReconciliation))
      | agenticusIs RuntimeProtocolError e -> pure (Left (agentError "Pi operation lifecycle failed" RuntimeLifecycle))
      | otherwise -> pure (Left (agentError "Pi operation result is unavailable" RuntimeLifecycle))
  startedId <- readIORef startedRef
  closed <- trySync operation.close
  let verified = case (closed, startedId) of
        (Right cleanup, Just identity') -> cleanupVerified cleanup && cleanup.operationId == identity'
        _ -> False
  let outcome
        | verified = failure0
        | otherwise = case failure0 of
            Right _ ->
              Left (protocolError "Pi operation cleanup is unverified") {cleanupCategory = Just CleanupUnverified}
            Left failure -> Left (retainCleanupCategory CleanupUnverified failure)
  either throwIO pure outcome

-- | @dict(data)[name] = value@: an existing key keeps its position.
setMember :: Text -> Json -> [(Text, Json)] -> [(Text, Json)]
setMember name value members
  | any ((== name) . fst) members = [(key, if key == name then value else old) | (key, old) <- members]
  | otherwise = members <> [(name, value)]

-- | @PiNativeRunner._cancel(operation, reason)@.
cancelQuietly :: PiOperation -> Text -> IO ()
cancelQuietly operation reason = void (trySync (operation.cancel reason))

-- | @PiNativeRunner._wait(operation, is_current)@.
waitFor :: PiNativeRunner -> PiOperation -> Maybe (IO Bool) -> IO RuntimeTurnSettlement
waitFor runner operation isCurrent = do
  deadline <- case runner.options.timeout of
    Nothing -> pure Nothing
    Just t -> Just . (+ t) <$> runner.options.clock
  let loop = do
        stale <- notCurrent isCurrent
        when stale $ do
          cancelQuietly operation "stale-authority"
          throwIO superseded
        bound <- case deadline of
          Nothing -> pure runner.options.pollInterval
          Just limit -> do
            now <- runner.options.clock
            let remaining = limit - now
            when (remaining <= 0) $ do
              cancelQuietly operation "host-timeout"
              throwIO (agentError "agent execution timed out" RuntimeLifecycle) {timedOut = True}
            pure (min runner.options.pollInterval remaining)
        waited <- trySync (operation.wait (Just bound))
        case waited of
          Left e
            | agenticusIs TimeoutError e -> loop
            | otherwise -> throwIO e
          Right settlement -> do
            staleAfter <- notCurrent isCurrent
            when staleAfter $ do
              cancelQuietly operation "stale-authority"
              throwIO superseded
            pure settlement
  loop

-- | @_parse_result(raw)@.
parseResult :: Text -> V [(Text, Json)]
parseResult raw = do
  let bytes = TE.encodeUtf8 raw
  when (BS.length bytes > maxResultBytes) $ refuse "Pi result exceeded limit"
  value <- case parseJson pythonLoads bytes of
    Right value -> Right value
    Left message
      | "maximum nesting depth" `isPrefixOf` message -> foreignFailure "RecursionError" "maximum recursion depth exceeded"
      | "Exceeds the limit" `isPrefixOf` message -> foreignFailure "ValueError" (T.pack message)
      | otherwise -> Left (Refused (protocolError "result is malformed JSON"))
  case value of
    Object members -> Right members
    _ -> refuse "result must be a JSON object"

-- | The runner as Hamsterdan's 'AgentRunner'.
piAgentRunner :: PiNativeRunner -> AgentRunner
piAgentRunner runner =
  AgentRunner
    { review = \url request invocation ->
        runPi runner ReviewKind url (AgentReview request) invocation >>= \case
          ResultReview result -> pure result
          _ -> unavailable
    , converse = \url request invocation ->
        runPi runner ConversationKind url (AgentConversation request) invocation >>= \case
          ResultConversation result -> pure result
          _ -> unavailable
    , code = \url request invocation ->
        runPi runner CodingKind url (AgentCoding request) invocation >>= \case
          ResultCoding result -> pure result
          _ -> unavailable
    }
  where
    unavailable :: IO a
    unavailable = throwIO (agentError "Pi operation result is unavailable" RuntimeLifecycle)

-- | @UnavailablePiRunner@: fail closed when the exact Pi installation or
-- collaborators are unavailable.
unavailablePiRunner :: AgentRunner
unavailablePiRunner =
  AgentRunner
    { review = \_ _ _ -> notReady
    , converse = \_ _ _ -> notReady
    , code = \_ _ _ -> notReady
    }
  where
    notReady :: IO a
    notReady = throwIO (protocolError "Pi native A2 runtime is not ready")

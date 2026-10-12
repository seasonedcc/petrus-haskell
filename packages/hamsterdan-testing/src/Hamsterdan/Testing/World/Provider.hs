{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE MultiWayIf #-}

-- | Modeled external truth and boundary-faithful adapters for readiness
-- DST (@host/testing/_readiness_provider.py@).
--
-- The reference's mutable @ReadinessProviderTruth@ object is one 'Truth'
-- value behind an 'IORef'; its methods mutate it in the reference's order,
-- so a method that raises leaves exactly the partial changes the
-- reference's leaves. The adapters (transport, Git publisher, agent
-- runner) raise the host's own exception types under the reference's
-- class names, so the host classifies their failures as the reference's
-- host does.
--
-- The reference reads the World's @ScenarioContext@ from these adapters
-- through a holder the profile fills only while one command applies;
-- 'ContextHolder' is that holder. Consuming a fault from inside a host
-- callback updates the held context, which the profile hands back to the
-- World when the command's door ends.
module Hamsterdan.Testing.World.Provider
  ( -- * Truth
    Truth (..)
  , Effect (..)
  , Emitted (..)
  , GitPublication (..)
  , CiCheck (..)
  , ciCheckJson
  , HumanReviewState (..)
  , TruthRef
  , newTruth
  , initialAuthority
  , setAuthority
  , bindEffectAuthority
  , admit
  , nextSemanticOrder
  , setHumanComment
  , admittedRecoveries
  , recoveryIdentity
  , emitted
  , request
  , pages
  , retainedBytes
  , observation

    -- * The scenario context, held
  , ContextHolder
  , newContextHolder
  , contextNow
  , contextFaults

    -- * Adapters
  , modeledGitPublisher
  , providerTransport
  , providerClients
  , agentRunner
  , webhookBody

    -- * Raising Python exceptions
  , throwPy
  , pyException
  ) where

import Control.Exception (Exception (..), SomeException, throwIO)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol
  ( AgentRunner (..)
  , CodingRequest (..)
  , CodingResult (..)
  , ConversationRequest (..)
  , ConversationResult (..)
  , Invocation (..)
  , ReviewRequest (..)
  , ReviewResult (..)
  , protocolError
  )
import Hamsterdan.Agents.Protocol qualified as Protocol
import Hamsterdan.GitHub.Config (HostConfig)
import Hamsterdan.GitHub.Models (InstallationInventory (..), RegistrationInventory (..), Transport (..), WireResponse (..), boundary)
import Hamsterdan.Host.GitPublish (GitPublishError (..), GitPublishResult (..), GitReconciliation (..), OperationDisposition (..), PublicationCategory (..))
import Hamsterdan.Host.ExceptionClass (exceptionClass)
import Hamsterdan.Host.Python (RuntimeError (..), pattern TypeError, ValueError (..))
import Hamsterdan.Host.Service (HostClients (..))
import Hamsterdan.Host.V5.Mutation (MutationPublisher (..))
import Hamsterdan.Testing.Readiness (AuthorityClaim (..), CheckStatus (..), Lifecycle (..), ReviewStatus (..), Spelled (..), dump)
import Hamsterdan.Testing.World.Contract
import Petrus.Impetus.Instance.FailureText (PythonArg (..))
import Petrus.Json (Json (..), lookupMember)
import Petrus.Testing.Dst (Fault (..), ProfileError (..), ScenarioContext (..), faults, runScenario)

-- ---------------------------------------------------------------------------
-- Python exceptions

-- | Raise the reference's exception class with a message, as the host's
-- own type for the built-in classes the host distinguishes.
throwPy :: Text -> Text -> IO a
throwPy cls message = case cls of
  "ValueError" -> throwIO (ValueError message)
  "RuntimeError" -> throwIO (RuntimeError message)
  "TypeError" -> throwIO (TypeError message)
  _ -> throwIO (PythonException cls [PyStr message])

-- | The reference class and @str()@ of a raised exception.
pyException :: SomeException -> (Text, Text)
pyException e
  | Just (PythonException cls args) <- fromException e = (cls, case args of [PyStr m] -> m; _ -> "")
  | otherwise = (exceptionClass e, T.pack (displayException e))

assertion :: TruthRef -> Text -> IO a
assertion ref message = do
  modifyIORef' ref (\t -> t {harnessErrors = t.harnessErrors <> [message]})
  throwPy "AssertionError" message

-- ---------------------------------------------------------------------------
-- Truth

data Effect = Effect
  { kind :: Text
  , operation :: Text
  , head :: Text
  , contentDigest :: Text
  , authority :: AuthorityClaim
  , providerAuthorityAtAcceptance :: AuthorityClaim
  , body :: Text
  , acceptedAt :: Integer
  , semanticOrder :: Integer
  , visible :: Bool
  , responseLost :: Bool
  , recovered :: Bool
  , reference :: Integer
  }
  deriving stock (Eq, Show)

-- | The effect with its lost response recovered.
markRecovered :: Effect -> Effect
markRecovered (Effect k o h c a p b at so v lost _ r) = Effect k o h c a p b at so v lost True r

-- | The claim at another head.
withHead :: AuthorityClaim -> Text -> AuthorityClaim
withHead (AuthorityClaim i r p _ b pol l s bc m) h = AuthorityClaim i r p h b pol l s bc m

-- | @_Emitted@.
data Emitted = Emitted
  { delivery :: Text
  , event :: Text
  , action :: Text
  , authority :: AuthorityClaim
  , comment :: Maybe Json
  , sourceIdentity :: Text
  , instant :: Integer
  , semanticOrder :: Integer
  }
  deriving stock (Eq, Show)

-- | @_Emitted(delivery, event, action, authority, comment)@ with the
-- reference's defaults.
emitted :: Text -> Text -> Text -> AuthorityClaim -> Maybe Json -> Emitted
emitted delivery event action authority comment =
  Emitted {delivery, event, action, authority, comment, sourceIdentity = "", instant = 0, semanticOrder = 0}

data GitPublication = GitPublication
  { operation :: Text
  , payloadDigest :: Text
  , expectedHead :: Text
  , resultHead :: Text
  , authority :: AuthorityClaim
  , acceptedAt :: Integer
  , semanticOrder :: Integer
  , responseLost :: Bool
  , recovered :: Bool
  , recoveryIdentity :: Text
  }
  deriving stock (Eq, Show)

-- | One CI check of @readiness.github.ci.set@, as its @strict_object@
-- admits it.
data CiCheck = CiCheck
  { name :: Text
  , run :: Integer
  , attempt :: Integer
  , status :: CheckStatus
  }
  deriving stock (Eq, Show)

-- | The check's dict.
ciCheckJson :: CiCheck -> Json
ciCheckJson c = Object [("name", String c.name), ("run", Int c.run), ("attempt", Int c.attempt), ("status", String (spell c.status))]

-- | A human review's state.
data HumanReviewState = HumanApproved | HumanChangesRequested | HumanDismissed
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled HumanReviewState where
  spell = \case
    HumanApproved -> "APPROVED"
    HumanChangesRequested -> "CHANGES_REQUESTED"
    HumanDismissed -> "DISMISSED"

-- | @ReadinessProviderTruth@'s attributes.
data Truth = Truth
  { authority :: AuthorityClaim
  , authorities :: [AuthorityClaim]
  , requiredChecks :: [Text]
  , checks :: [CiCheck]
  , reviewHead :: Text
  , reviewStatus :: ReviewStatus
  , findings :: [Json]
  , humanReviews :: Map Text (Text, HumanReviewState)
  , reviewThreads :: Map Text Bool
  , comments :: [Json]
  , humanComments :: [Json]
  , effects :: [Effect]
  , effectAuthorities :: Map (Text, Text) AuthorityClaim
  , collisions :: [Text]
  , emittedDeliveries :: Map Text Emitted
  , custodied :: [Text]
  , admitted :: [Emitted]
  , activeAdmission :: Maybe Emitted
  , custodyActions :: [Json]
  , deliveryAttempts :: Map Text Integer
  , agentCalls :: [Json]
  , agentTerminals :: Map Text Json
  , reviewTerminal :: Maybe Json
  , gitPublications :: [GitPublication]
  , gitReconciliations :: Integer
  , gitProofUnavailable :: Set Text
  , calls :: [Json]
  , harnessErrors :: [Text]
  , providerTruthChanges :: Integer
  , semanticCounter :: Integer
  }

type TruthRef = IORef Truth

-- | The authority @ReadinessProviderTruth()@ starts with.
initialAuthority :: AuthorityClaim
initialAuthority = AuthorityClaim 44 31 7 headSha baseSha readinessPolicyDigest Active True True True

-- | @ReadinessProviderTruth()@.
newTruth :: IO TruthRef
newTruth =
  newIORef
    Truth
      { authority = initialAuthority
      , authorities = [initialAuthority]
      , requiredChecks = ["build"]
      , checks = []
      , reviewHead = ""
      , reviewStatus = ReviewPending
      , findings = []
      , humanReviews = Map.empty
      , reviewThreads = Map.empty
      , comments = []
      , humanComments = []
      , effects = []
      , effectAuthorities = Map.empty
      , collisions = []
      , emittedDeliveries = Map.empty
      , custodied = []
      , admitted = []
      , activeAdmission = Nothing
      , custodyActions = []
      , deliveryAttempts = Map.empty
      , agentCalls = []
      , agentTerminals = Map.empty
      , reviewTerminal = Nothing
      , gitPublications = []
      , gitReconciliations = 0
      , gitProofUnavailable = Set.empty
      , calls = []
      , harnessErrors = []
      , providerTruthChanges = 0
      , semanticCounter = 0
      }

-- | @set_authority(authority)@.
setAuthority :: TruthRef -> AuthorityClaim -> IO ()
setAuthority ref claim = modifyIORef' ref $ \t ->
  t {authority = claim, authorities = if Just claim /= lastMaybe t.authorities then t.authorities <> [claim] else t.authorities}

lastMaybe :: [a] -> Maybe a
lastMaybe xs = if null xs then Nothing else Just (last xs)

-- | @bind_effect_authority(kind, operation, authority)@.
bindEffectAuthority :: TruthRef -> Text -> Text -> AuthorityClaim -> IO ()
bindEffectAuthority ref kind operation claim = do
  t <- readIORef ref
  case Map.lookup (kind, operation) t.effectAuthorities of
    Just existing
      | existing /= claim
      , any (\e -> e.kind == kind && e.operation == operation) t.effects ->
          throwPy "ValueError" "stable provider operation was reused under different authored authority"
    _ -> writeIORef ref t {effectAuthorities = Map.insert (kind, operation) claim t.effectAuthorities}

-- | @_next_semantic_order()@.
nextSemanticOrder :: TruthRef -> IO Integer
nextSemanticOrder ref = atomicModifyIORef' ref (\t -> let n = t.semanticCounter + 1 in (t {semanticCounter = n}, n))

-- | @admit(emitted, instant, authority)@.
admit :: TruthRef -> Emitted -> Integer -> Maybe AuthorityClaim -> IO ()
admit ref event at claim = do
  current <- (.authority) <$> readIORef ref
  order <- nextSemanticOrder ref
  let entry = event {authority = fromMaybe current claim, instant = at, semanticOrder = order}
  modifyIORef' ref (\t -> t {admitted = t.admitted <> [entry]})

-- | @set_human_comment(identity, author, fixture)@.
setHumanComment :: TruthRef -> Integer -> Text -> Text -> IO ()
setHumanComment ref identity author fixture = do
  t <- readIORef ref
  when (any (\c -> lookupMember "id" c == Just (Int identity)) t.humanComments) $
    throwPy "ValueError" "human comment identity was reused"
  body <-
    if
      | fixture == "change" -> pure "@hamsterdan-test Apply the deterministic readiness change."
      | Just operation <- T.stripPrefix "recover:" fixture -> pure ("@hamsterdan-test Recover publication " <> operation <> ".")
      | otherwise -> throwPy "ValueError" "unsupported human comment fixture"
  let comment =
        Object
          [ ("id", Int identity)
          , ("body", String body)
          , ("author", String author)
          , ("fixture", String fixture)
          , ("user", Object [("id", Int 701), ("login", String author), ("type", String "User")])
          , ("author_association", String "OWNER")
          ]
      visibleComment =
        Object
          [ ("id", Int identity)
          , ("html_url", String ("https://example.test/comments/" <> showT identity))
          , ("body", String body)
          , ("user", Object [("login", String author)])
          , ("visible", Bool True)
          ]
  writeIORef ref t {humanComments = t.humanComments <> [comment], comments = t.comments <> [visibleComment]}

-- | @admitted_recoveries()@.
admittedRecoveries :: Truth -> [Json]
admittedRecoveries t =
  [ Object [("operation", String operation), ("identity", String (identityOf event))]
  | event <- t.admitted
  , Just (String fixture) <- [event.comment >>= lookupMember "fixture"]
  , Just operation <- [T.stripPrefix "recover:" fixture]
  ]

identityOf :: Emitted -> Text
identityOf event = if T.null event.sourceIdentity then "github-delivery:" <> event.delivery else event.sourceIdentity

-- | @recovery_identity(operation, include_active=...)@.
recoveryIdentity :: Truth -> Text -> Bool -> Text
recoveryIdentity t operation includeActive
  | includeActive
  , Just active <- t.activeAdmission
  , Just c <- active.comment
  , lookupMember "fixture" c == Just (String ("recover:" <> operation)) =
      identityOf active
  | otherwise =
      fromMaybe "" $
        lastMaybe
          [ identity
          | Object members <- admittedRecoveries t
          , lookup "operation" members == Just (String operation)
          , Just (String identity) <- [lookup "identity" members]
          ]

showT :: (Show a) => a -> Text
showT = T.pack . show

-- ---------------------------------------------------------------------------
-- The scenario context, held

-- | The profile's @context_holder@: the World's context while one command
-- applies, 'Nothing' otherwise.
type ContextHolder = IORef (Maybe ScenarioContext)

newContextHolder :: IO ContextHolder
newContextHolder = newIORef Nothing

-- | @context.now()@ of the held context.
contextNow :: ContextHolder -> IO (Maybe Integer)
contextNow holder = fmap (.instant) <$> readIORef holder

-- | @context.faults(target)@ of the held context; 'Nothing' without one.
contextFaults :: ContextHolder -> Text -> IO (Maybe [Fault])
contextFaults holder target =
  readIORef holder >>= \case
    Nothing -> pure Nothing
    Just context -> do
      (result, context') <- runScenario (faults target) context
      writeIORef holder (Just context')
      either (\(ProfileError cls message) -> throwPy cls message) (pure . Just) result

faultCut :: Fault -> Maybe Json
faultCut f = lookupMember "cut" f.payload

-- ---------------------------------------------------------------------------
-- Requests

root :: Text
root = "/repos/owner/repo"

providerCall :: TruthRef -> Text -> Text -> IO ()
providerCall ref method path = do
  t <- readIORef ref
  let limit = profileLimit ProviderCalls
  when (toInteger (length t.calls) >= limit) $
    throwPy "RuntimeError" ("readiness profile bound provider_calls exhausted at " <> showT limit)
  writeIORef ref t {calls = t.calls <> [Object [("method", String method), ("path", String path)]]}

ok :: Int -> Json -> IO WireResponse
ok status body = pure (WireResponse status body Nothing)

textOf :: Json -> Text
textOf = \case
  String s -> s
  Int i -> showT i
  Bool True -> "True"
  Bool False -> "False"
  Null -> "None"
  other -> T.pack (show other)

-- | A positive decimal path segment (@[1-9][0-9]*@) and what follows it.
positive :: Text -> Maybe (Integer, Text)
positive t = case T.span isDigit t of
  (digits, rest) | Just (c, _) <- T.uncons digits, c /= '0' -> Just (read (T.unpack digits), rest)
  _ -> Nothing

-- | @request(method, path, body, context=context)@.
request :: TruthRef -> ContextHolder -> Text -> Text -> Maybe Json -> IO WireResponse
request ref holder method path body = do
  providerCall ref method path
  t <- readIORef ref
  let claim = t.authority
      member key = body >>= lookupMember key
      isObject = case body of Just (Object _) -> True; _ -> False
  if
    | method == "GET" && path == root <> "/pulls/7" ->
        ok 200 $
          Object
            [ ("state", String (if claim.lifecycle `elem` [Closed, Merged] then "closed" else "open"))
            , ("draft", Bool (claim.lifecycle == Draft))
            , ("mergeable", Bool claim.mergeable)
            , ("mergeable_state", String (if claim.mergeable then "clean" else "dirty"))
            , ("merged", Bool (claim.lifecycle == Merged))
            , ("html_url", String "https://example.test/owner/repo/pull/7")
            , ("user", Object [("login", String "author")])
            , ("head", Object [("sha", String claim.head), ("ref", String "feature"), ("repo", Object [("full_name", String "owner/repo")])])
            , ("base", Object [("sha", String claim.base), ("ref", String "main")])
            ]
    | method == "GET" && path == root <> "/git/ref/heads/main" ->
        ok 200 (Object [("object", Object [("sha", String claim.base)])])
    | method == "GET" && path == root <> "/rules/branches/main" ->
        ok 200 $
          Array
            [ Object
                [ ("type", String "required_status_checks")
                ,
                  ( "parameters"
                  , Object
                      [ ("strict_required_status_checks_policy", Bool claim.strictBase)
                      , ("required_status_checks", Array [Object [("context", String name)] | name <- t.requiredChecks])
                      ]
                  )
                ]
            , Object
                [ ("type", String "pull_request")
                , ("parameters", Object [("required_approving_review_count", Int 0), ("required_review_thread_resolution", Bool False)])
                ]
            ]
    | method == "GET" && path == root <> "/compare/" <> claim.base <> "..." <> claim.head ->
        ok 200 (Object [("status", String "ahead"), ("behind_by", Int (if claim.baseCurrent then 0 else 1))])
    | method == "GET" && path == root <> "/pulls/7/requested_reviewers" ->
        ok 200 (Object [("users", Array [])])
    | method == "GET"
    , (root <> "/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?event=pull_request&head_sha=") `T.isPrefixOf` path -> do
        let grouped = Map.fromListWith (flip (<>)) [((c.run, c.attempt), [c.status]) | c <- t.checks]
            run ((runId, attempt), statuses) =
              let completed = all (`elem` [Success, Failure, Canceled]) statuses
                  conclusion
                    | Failure `elem` statuses || Canceled `elem` statuses = String "failure"
                    | completed = String "success"
                    | otherwise = Null
               in Object
                    [ ("id", Int runId)
                    , ("run_attempt", Int attempt)
                    , ("head_sha", String (if T.null t.reviewHead then claim.head else t.reviewHead))
                    , ("event", String "pull_request")
                    , ("path", String ".github/workflows/ci.yml")
                    , ("status", String (if completed then "completed" else "in_progress"))
                    , ("conclusion", conclusion)
                    , ("pull_requests", Array [Object [("number", Int 7)]])
                    ]
            values = map run (Map.toAscList grouped)
        ok 200 (Object [("total_count", Int (toInteger (length values))), ("workflow_runs", Array values)])
    | method == "GET"
    , Just rest <- T.stripPrefix (root <> "/actions/runs/") path
    , Just (runId, rest') <- positive rest
    , Just rest'' <- T.stripPrefix "/attempts/" rest'
    , Just (attempt, rest''') <- positive rest''
    , rest''' == "/jobs?per_page=100" -> do
        let job (index, c) =
              Object
                [ ("id", Int (runId * 100 + index))
                , ("name", String c.name)
                , ("status", String (if c.status `elem` [Success, Failure, Canceled] then "completed" else "in_progress"))
                ,
                  ( "conclusion"
                  , case c.status of
                      Success -> String "success"
                      Failure -> String "failure"
                      Canceled -> String "failure"
                      _ -> Null
                  )
                ]
            values =
              [ job (index, c)
              | (index, c) <- zip [1 ..] t.checks
              , c.run == runId
              , c.attempt == attempt
              ]
        ok 200 (Object [("total_count", Int (toInteger (length values))), ("jobs", Array values)])
    | method == "POST"
    , path == "/graphql"
    , isObject
    , "reviewThreads" `T.isInfixOf` maybe "None" textOf (member "query") ->
        ok 200 $
          Object
            [
              ( "data"
              , Object
                  [
                    ( "repository"
                    , Object
                        [
                          ( "pullRequest"
                          , Object
                              [
                                ( "reviewThreads"
                                , Object
                                    [ ("nodes", Array [Object [("id", String identity), ("isResolved", Bool resolved)] | (identity, resolved) <- Map.toAscList t.reviewThreads])
                                    , ("pageInfo", Object [("hasNextPage", Bool False), ("endCursor", Null)])
                                    ]
                                )
                              ]
                          )
                        ]
                    )
                  ]
              )
            ]
    | method == "POST" && path == root <> "/issues/7/comments" && isObject ->
        acceptComment ref holder (maybe "" textOf (member "body"))
    | method == "PATCH"
    , isObject
    , Just rest <- T.stripPrefix (root <> "/issues/comments/") path
    , Just (identifier, "") <- positive rest ->
        case break (\c -> lookupMember "id" c == Just (Int identifier)) t.comments of
          (_, []) -> ok 404 (Object [])
          (before, c : after) -> do
            let updated = setMember "body" (String (maybe "" textOf (member "body"))) c
            writeIORef ref t {comments = before <> (updated : after)}
            ok 200 updated
    | otherwise -> assertion ref ("undeclared provider request: " <> method <> " " <> path)

setMember :: Text -> Json -> Json -> Json
setMember key value = \case
  Object members
    | any ((== key) . fst) members -> Object [(k, if k == key then value else v) | (k, v) <- members]
    | otherwise -> Object (members <> [(key, value)])
  other -> other

-- | @pages(path)@.
pages :: TruthRef -> Text -> IO [[(Text, Json)]]
pages ref path = do
  providerCall ref "PAGES" path
  t <- readIORef ref
  if
    | path == root <> "/issues/7/comments?per_page=100" -> do
        let recover e = if e.responseLost && e.visible && not e.recovered then markRecovered e else e
        writeIORef ref t {effects = map recover t.effects}
        pure [members | c@(Object members) <- t.comments, lookupMember "visible" c /= Just (Bool False)]
    | path == root <> "/pulls/7/comments?per_page=100" -> pure []
    | path == root <> "/pulls/7/reviews?per_page=100" ->
        pure
          [ [ ("id", Int index)
            , ("submitted_at", String submitted)
            , ("state", String (spell state))
            , ("user", Object [("login", String reviewer)])
            ]
          | (index, (reviewer, (submitted, state))) <- zip [1 ..] (Map.toAscList t.humanReviews)
          ]
    | otherwise -> assertion ref ("undeclared provider pages request: " <> path)

-- | @_EFFECT_MARKER.fullmatch(marker)@: kind, operation, head.
effectMarker :: Text -> Maybe (Text, Text, Text)
effectMarker marker = do
  rest <- T.stripPrefix "<!-- hamsterdan:" marker
  let (kind, rest') = T.breakOn " " rest
  unless (kind `elem` ["conversation", "finding", "readiness", "reminder"]) Nothing
  rest'' <- T.stripPrefix " operation=" rest'
  let (operation, rest''') = T.span operationChar rest''
  when (T.null operation) Nothing
  tailText <- T.stripPrefix " head=" rest'''
  let (sha, closing) = T.splitAt 40 tailText
  unless (isSha sha && closing == " -->") Nothing
  pure (kind, operation, sha)
  where
    operationChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._:-" :: String)

-- | @_accept_comment(payload, context)@.
acceptComment :: TruthRef -> ContextHolder -> Text -> IO WireResponse
acceptComment ref holder payload = do
  let marker = snd (T.breakOnEnd "\n\n" payload)
      digest = strictDigest (String payload)
  t <- readIORef ref
  (kind, operation, effectHead) <- case effectMarker marker of
    Just found -> pure found
    Nothing
      | marker == "<!-- hamsterdan:dashboard -->" || "<!-- hamsterdan-rerun " `T.isPrefixOf` marker ->
          pure ("dashboard", "dashboard:" <> T.take 24 digest, t.authority.head)
      | otherwise -> assertion ref "undeclared provider comment payload"
  attempted <- case Map.lookup (kind, operation) t.effectAuthorities of
    Just claim -> pure claim
    Nothing
      | kind == "readiness" -> assertion ref "readiness provider effect has no exact authored authority binding"
      | otherwise -> pure (fromMaybe t.authority (find (\a -> a.head == effectHead) (reverse t.authorities)))
  case find (\e -> e.operation == operation) t.effects of
    Just existing -> do
      when (existing.contentDigest /= digest || existing.authority /= attempted) $
        throwPy "ValueError" "stable provider operation collided with different content"
      case find (\c -> lookupMember "id" c == Just (Int existing.reference)) t.comments of
        Just c -> ok 201 c
        Nothing -> throwPy "StopIteration" ""
    Nothing -> do
      matched <- fromMaybe [] <$> contextFaults holder ("effect:" <> kind)
      let cut = foldl' (\_ f -> faultCut f) Nothing matched
      if
        | cut == Just (String "before_acceptance") -> ok 422 (Object [])
        | cut == Just (String "identity_collision") -> do
            modifyIORef' ref (\t' -> t' {collisions = t'.collisions <> [operation]})
            throwPy "ValueError" "modeled provider operation identity collision"
        | otherwise -> do
            t' <- readIORef ref
            let limit = profileLimit Effects
            when (toInteger (length t'.effects) >= limit) $
              throwPy "RuntimeError" ("readiness profile bound effects exhausted at " <> showT limit)
            let identifier = toInteger (length t'.comments) + 1
                lost = cut == Just (String "after_acceptance_before_response")
                shown = cut /= Just (String "before_visibility")
            acceptedAt <- fromMaybe 0 <$> contextNow holder
            order <- nextSemanticOrder ref
            let effect =
                  Effect
                    { kind
                    , operation
                    , head = effectHead
                    , contentDigest = digest
                    , authority = attempted
                    , providerAuthorityAtAcceptance = t'.authority
                    , body = payload
                    , acceptedAt
                    , semanticOrder = order
                    , visible = shown
                    , responseLost = lost
                    , recovered = False
                    , reference = identifier
                    }
                comment =
                  Object
                    [ ("id", Int identifier)
                    , ("html_url", String ("https://example.test/comments/" <> showT identifier))
                    , ("body", String payload)
                    , ("user", Object [("login", String bot)])
                    , ("visible", Bool shown)
                    ]
            modifyIORef' ref (\u -> u {effects = u.effects <> [effect], comments = u.comments <> [comment]})
            when lost $ throwIO (boundary "modeled provider accepted but response was lost")
            ok 201 comment

-- ---------------------------------------------------------------------------
-- Detached views

emittedJson :: Emitted -> Json
emittedJson e =
  Object
    [ ("delivery", String e.delivery)
    , ("event", String e.event)
    , ("action", String e.action)
    , ("authority", dump e.authority)
    , ("comment", fromMaybe Null e.comment)
    , ("source_identity", String e.sourceIdentity)
    , ("instant", Int e.instant)
    , ("semantic_order", Int e.semanticOrder)
    ]

gitPublicationJson :: GitPublication -> Json
gitPublicationJson p =
  Object
    [ ("operation", String p.operation)
    , ("payload_digest", String p.payloadDigest)
    , ("expected_head", String p.expectedHead)
    , ("result_head", String p.resultHead)
    , ("authority", dump p.authority)
    , ("accepted_at", Int p.acceptedAt)
    , ("semantic_order", Int p.semanticOrder)
    , ("response_lost", Bool p.responseLost)
    , ("recovered", Bool p.recovered)
    , ("recovery_identity", String p.recoveryIdentity)
    ]

-- | @retained_bytes()@: the canonical size of all modeled provider truth.
retainedBytes :: Truth -> Integer
retainedBytes t =
  toInteger . BS.length . canonical $
    Object
      [ ("authority", dump t.authority)
      , ("authorities", Array (map dump t.authorities))
      , ("required_checks", Array (map String t.requiredChecks))
      , ("checks", Array (map ciCheckJson t.checks))
      , ("review_head", String t.reviewHead)
      , ("review_status", String (spell t.reviewStatus))
      , ("findings", Array t.findings)
      , ("human_reviews", Object [(k, Array [String a, String (spell b)]) | (k, (a, b)) <- Map.toAscList t.humanReviews])
      , ("review_threads", Object [(k, Bool v) | (k, v) <- Map.toAscList t.reviewThreads])
      , ("comments", Array t.comments)
      , ("human_comments", Array t.humanComments)
      ,
        ( "effects"
        , Array
            [ Object
                [ ("kind", String e.kind)
                , ("operation", String e.operation)
                , ("head", String e.head)
                , ("content_digest", String e.contentDigest)
                , ("authority", dump e.authority)
                , ("provider_authority_at_acceptance", dump e.providerAuthorityAtAcceptance)
                , ("body", String e.body)
                , ("accepted_at", Int e.acceptedAt)
                , ("semantic_order", Int e.semanticOrder)
                , ("visible", Bool e.visible)
                , ("response_lost", Bool e.responseLost)
                , ("recovered", Bool e.recovered)
                , ("reference", Int e.reference)
                ]
            | e <- t.effects
            ]
        )
      ,
        ( "effect_authorities"
        , Array [Object [("kind", String k), ("operation", String o), ("authority", dump a)] | ((k, o), a) <- Map.toAscList t.effectAuthorities]
        )
      , ("collisions", Array (map String t.collisions))
      , ("emitted", Array (map emittedJson (Map.elems t.emittedDeliveries)))
      , ("custodied", Array (map String t.custodied))
      , ("admitted", Array (map emittedJson t.admitted))
      , ("custody_actions", Array t.custodyActions)
      , ("delivery_attempts", Object [(k, Int v) | (k, v) <- Map.toAscList t.deliveryAttempts])
      , ("agent_calls", Array t.agentCalls)
      , ("agent_terminals", Object (Map.toAscList t.agentTerminals))
      , ("review_terminal", fromMaybe Null t.reviewTerminal)
      , ("git_publications", Array (map gitPublicationJson t.gitPublications))
      , ("git_reconciliations", Int t.gitReconciliations)
      , ("git_proof_unavailable", Array (map String (Set.toAscList t.gitProofUnavailable)))
      , ("calls", Array t.calls)
      , ("harness_errors", Array (map String t.harnessErrors))
      , ("provider_truth_changes", Int t.providerTruthChanges)
      ]

-- | @observation()@.
observation :: Truth -> Json
observation t =
  Object
    [ ("accepted_by_kind", Object [(k, Int n) | (k, n) <- Map.toAscList (Map.fromListWith (+) [(e.kind, 1) | e <- t.effects])])
    ,
      ( "effects"
      , Array
          [ Object
              [ ("kind", String e.kind)
              , ("operation", String e.operation)
              , ("head", String e.head)
              , ("authority", dump e.authority)
              , ("content_digest", String e.contentDigest)
              , ("provider_authority_at_acceptance", dump e.providerAuthorityAtAcceptance)
              , ("accepted_at", Int e.acceptedAt)
              , ("semantic_order", Int e.semanticOrder)
              , ("visible", Bool e.visible)
              , ("response_lost", Bool e.responseLost)
              , ("recovered", Bool e.recovered)
              ]
          | e <- t.effects
          ]
      )
    , ("response_losses", Array (map String (Set.toAscList (Set.fromList [e.kind | e <- t.effects, e.responseLost]))))
    , ("lookup_recoveries", Int (toInteger (length (filter (.recovered) t.effects))))
    , ("provider_calls", Int (toInteger (length t.calls)))
    , ("agent_calls", Int (toInteger (length t.agentCalls)))
    , ("agent_call_log", Array t.agentCalls)
    , ("git_publications", Array (map gitPublicationJson t.gitPublications))
    , ("git_reconciliations", Int t.gitReconciliations)
    , ("admitted_recoveries", Array (admittedRecoveries t))
    , ("collisions", Array (map String (sortOn id t.collisions)))
    , ("custody_actions", Array t.custodyActions)
    ]

-- ---------------------------------------------------------------------------
-- Adapters

-- | @ModeledGitPublisher(truth, context)@.
modeledGitPublisher :: TruthRef -> ContextHolder -> MutationPublisher
modeledGitPublisher ref holder =
  MutationPublisher
    { reconcile = \operation digest expected _baseHead _mergeBase -> do
        t <- readIORef ref
        let limit = profileLimit GitReconciliations
        when (t.gitReconciliations >= limit) $
          throwPy "RuntimeError" ("readiness profile bound git_reconciliations exhausted at " <> showT limit)
        writeIORef ref t {gitReconciliations = t.gitReconciliations + 1}
        case find (\p -> p.operation == operation) t.gitPublications of
          Nothing -> pure (GitReconciliation OperationAbsent t.authority.head "" [])
          Just existing -> do
            when (existing.payloadDigest /= digest || existing.expectedHead /= expected) $
              throwIO (GitPublishError Idempotency "modeled Git operation identity collided")
            when (Set.member operation t.gitProofUnavailable) $ do
              modifyIORef' ref (\u -> u {gitProofUnavailable = Set.delete operation u.gitProofUnavailable})
              throwIO (GitPublishError BoundaryUnavailable "modeled Git proof is unavailable")
            u <- readIORef ref
            let identity = if existing.responseLost then recoveryIdentity u operation True else existing.recoveryIdentity
                updated = existing {recovered = existing.responseLost || existing.recovered, recoveryIdentity = identity}
            writeIORef ref u {gitPublications = map (\p -> if p.operation == operation then updated else p) u.gitPublications}
            pure (GitReconciliation OperationExisting u.authority.head existing.resultHead [existing.expectedHead])
    , publish = \result operation digest expected baseHead _mergeBase -> do
        held <- readIORef holder
        when (isNothing held) $ throwPy "RuntimeError" "modeled Git publication escaped its atomic profile operation"
        t <- readIORef ref
        when
          ( result.status /= "changed"
              || result.head /= expected
              || result.base /= baseHead
              || t.authority.head /= expected
              || t.authority.base /= baseHead
          )
          $ throwIO (GitPublishError Correlation "modeled Git publication is stale")
        when (any (\p -> p.operation == operation) t.gitPublications) $
          throwIO (GitPublishError Idempotency "modeled Git operation was accepted twice")
        let limit = profileLimit GitPublications
        when (toInteger (length t.gitPublications) >= limit) $
          throwPy "RuntimeError" ("readiness profile bound git_publications exhausted at " <> showT limit)
        let resultHead = T.take 40 (sha256Hex (TE.encodeUtf8 (expected <> "\0" <> operation <> "\0" <> digest)))
        matched <- fromMaybe [] <$> contextFaults holder ("git:" <> operation)
        let lost = foldl' (\_ f -> faultCut f == Just (String "ref_cas")) False matched
        at <- fromMaybe 0 <$> contextNow holder
        order <- nextSemanticOrder ref
        u <- readIORef ref
        let publication =
              GitPublication
                { operation
                , payloadDigest = digest
                , expectedHead = expected
                , resultHead
                , authority = u.authority
                , acceptedAt = at
                , semanticOrder = order
                , responseLost = lost
                , recovered = False
                , recoveryIdentity = ""
                }
        writeIORef ref u {gitPublications = u.gitPublications <> [publication]}
        setAuthority ref (withHead u.authority resultHead)
        when lost $ do
          modifyIORef' ref (\v -> v {gitProofUnavailable = Set.insert operation v.gitProofUnavailable})
          throwIO (GitPublishError RefCas "modeled Git ref update response was lost")
        pure (GitPublishResult resultHead False)
    }

-- | @ProviderTransport(truth, context)@.
providerTransport :: TruthRef -> ContextHolder -> Transport
providerTransport ref holder =
  Transport
    { request = \method path body -> request ref holder method path (Object <$> body)
    , pages = pages ref
    }

-- | @ProviderClients()@ composed with the profile's transport factory.
providerClients :: Transport -> HostClients
providerClients transport =
  HostClients
    { registrationInventory = \(_ :: HostConfig) -> pure (RegistrationInventory [InstallationInventory 44 23 [(31, "owner/repo")]])
    , installation = \installationId repositoryIds -> do
        unless (installationId == 44 && repositoryIds == [31]) $
          throwPy "AssertionError" "readiness world received undeclared installation authority"
        pure transport
    , close = pure ()
    }

-- | @AgentRunner(truth)@.
agentRunner :: TruthRef -> AgentRunner
agentRunner ref =
  AgentRunner
    { review = \_ request' invocation -> do
        current <- maybe (pure True) id invocation.isCurrent
        unless current $ throwIO (protocolError "modeled agent authority moved") {Protocol.canceled = True}
        t <- readIORef ref
        let terminal = maybe t.reviewTerminal Just (Map.lookup invocation.operation t.agentTerminals)
        case terminal of
          Just value | lookupMember "kind" value == Just (String "review") -> do
            let status = maybe "None" textOf (lookupMember "status" value)
                found = case lookupMember "findings" value of
                  Just (Array items) -> [members | Object members <- items]
                  _ -> []
            appendCall
              [ ("kind", String "review")
              , ("operation", String invocation.operation)
              , ("attempt", Int invocation.attempt)
              , ("head", String request'.head)
              , ("status", String status)
              ]
            when (status == "unable") $ throwIO (protocolError "modeled agent unavailable")
            pure
              ReviewResult
                { repository = request'.repository
                , pullRequest = request'.pullRequest
                , epoch = request'.epoch
                , head = request'.head
                , base = request'.base
                , status
                , findings = found
                , lineage =
                    [ [("finding_id", String (maybe "None" textOf (lookup "id" f))), ("state", String "new"), ("supersedes", Null)]
                    | f <- found
                    ]
                }
          _ -> assertion ref "undeclared agent review operation"
    , converse = \_ request' invocation -> do
        t <- readIORef ref
        terminal <- case Map.lookup invocation.operation t.agentTerminals of
          Just value | lookupMember "kind" value `elem` map (Just . String) ["conversation_change", "conversation_recover"] -> pure value
          _ -> assertion ref "undeclared agent conversation operation"
        requireTerminal terminal invocation
        appendCall
          [ ("kind", String "conversation")
          , ("operation", String invocation.operation)
          , ("attempt", Int invocation.attempt)
          , ("head", String request'.head)
          ]
        intents <-
          if lookupMember "kind" terminal == Just (String "conversation_change")
            then
              pure
                [
                  [ ("type", String "change")
                  , ("arguments", Object [("request", String "Apply the deterministic readiness change.")])
                  , ("mutation", Bool True)
                  , ("explicit", Bool True)
                  , ("confidence", Float 1.0)
                  ]
                ]
            else case recoverPublication (maybe "None" textOf (lookup "body" request'.commentContext)) of
              Nothing -> throwPy "AssertionError" "modeled recovery conversation has no exact publication operation"
              Just operation ->
                pure
                  [
                    [ ("type", String "recover_publication")
                    , ("arguments", Object [("operation", String operation)])
                    , ("mutation", Bool False)
                    , ("explicit", Bool True)
                    , ("confidence", Float 1.0)
                    ]
                  ]
        pure
          ConversationResult
            { repository = request'.repository
            , pullRequest = request'.pullRequest
            , epoch = request'.epoch
            , head = request'.head
            , base = request'.base
            , intents
            }
    , code = \_ request' invocation -> do
        t <- readIORef ref
        terminal <- case Map.lookup invocation.operation t.agentTerminals of
          Just value | lookupMember "kind" value == Just (String "coding") -> pure value
          _ -> assertion ref "undeclared agent coding operation"
        requireTerminal terminal invocation
        appendCall
          [ ("kind", String "coding")
          , ("operation", String invocation.operation)
          , ("attempt", Int invocation.attempt)
          , ("head", String request'.head)
          ]
        let status = maybe "None" textOf (lookupMember "status" terminal)
            changed = status == "changed"
        pure
          CodingResult
            { kind = request'.kind
            , repository = request'.repository
            , pullRequest = request'.pullRequest
            , epoch = request'.epoch
            , head = request'.head
            , base = request'.base
            , ref = request'.ref
            , status
            , reproductionStatus = "not_attempted"
            , diff =
                if changed
                  then "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n"
                  else ""
            , changedFiles = ["README.md" | changed]
            , validationEvidence = []
            , proposedCommitMessage = if changed then "Apply deterministic readiness change" else ""
            }
    }
  where
    appendCall entry = modifyIORef' ref (\t -> t {agentCalls = t.agentCalls <> [Object entry]})
    requireTerminal terminal invocation =
      unless (lookupMember "operation" terminal == Just (String invocation.operation) && lookupMember "attempt" terminal == Just (Int invocation.attempt)) $
        throwPy "AssertionError" "modeled agent terminal differs from the exact operation attempt"

-- | @re.search(r"Recover publication ([A-Za-z0-9._:-]+)\.", body).group(1)@.
recoverPublication :: Text -> Maybe Text
recoverPublication body = case T.breakOn needle body of
  (_, rest) | T.null rest -> Nothing
  (_, rest) ->
    let after = T.drop (T.length needle) rest
        run = T.takeWhile operationChar after
        dots = [i | (i, c) <- zip [0 :: Int ..] (T.unpack run), c == '.', i >= 1]
     in case dots of
          [] -> recoverPublication (T.drop 1 rest)
          _ -> Just (T.take (last dots) run)
  where
    needle = "Recover publication "
    operationChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._:-" :: String)

-- | @webhook_body(emitted)@.
webhookBody :: Emitted -> ByteString
webhookBody e =
  canonical . Object $
    [ ("action", String e.action)
    , ("installation", Object [("id", Int 44), ("account", Object [("id", Int 23)])])
    , ("repository", Object [("id", Int 31), ("full_name", String "owner/repo")])
    , ("pull_request", Object [("number", Int 7)])
    ]
      <> case e.comment of
        Just c
          | e.event == "issue_comment" ->
              [ ("issue", Object [("number", Int 7), ("pull_request", Object [("url", String "https://api.example.test/repos/owner/repo/pulls/7")])])
              , ("comment", c)
              ]
        _ -> []


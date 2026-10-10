{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Lookup-first, fenced pull-request comment effects
-- (@github_app/effects.py@): stable-marker comments, the readiness
-- dashboard, inline and batched review findings, reminders, and the
-- same-head rerun broker.
--
-- Every effect first looks for its marker among the App's own comments,
-- calls the caller's fence immediately before the provider request, and
-- reconciles by marker after an ambiguous outcome. Retries of transient
-- inline rejections wait through the injectable 'retryDelay' (60 s, then
-- 120 s, in production).
module Hamsterdan.GitHub.Effects
  ( -- * Publisher
    Fence
  , EffectFault
  , CommentPublisher (..)
  , commentPublisher
  , sleepSeconds
  , marker
  , dashboardMarker
  , transientRetrySeconds

    -- * Publications
  , immutable
  , immutableOperation
  , reminderOperation
  , findPublication
  , dashboard
  , publishFinding
  , publishFindings
  , findingContent
  , FindingContent (..)
  , findingFind
  , reminder
  , reviewerAssignmentAvailable

    -- * Rerun broker
  , CommentRerunBroker (..)
  , rerunMarker
  , held
  , issue
  , requestRerun

    -- * Shared helpers
  , reference
  , lenientReference
  , finalMarker
  , login
  , inlineProviderDetail
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (catch, throwIO, try)
import Control.Monad (forM, unless, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Gateway (GitHubAuthority, pullRequest, workflowRuns)
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Python (PyFailure (..), PythonFault (..))
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.GitHub.Transport (pyFault)
import Hamsterdan.GitHub.Url qualified as Url
import Petrus.Json (Json (..))

-- | @Fence(repository, pr_number, epoch, head, operation)@: raises to
-- refuse a stale effect.
type Fence = Text -> Integer -> Integer -> Text -> Text -> IO ()

-- | @EffectFault(phase, repository, pr_number, kind, operation)@: a fault
-- injection hook called around each effect request.
type EffectFault = Text -> Text -> Integer -> Text -> Text -> IO ()

-- | @CommentPublisher@.
data CommentPublisher = CommentPublisher
  { transport :: Transport
  , repository :: Text
  , prNumber :: Integer
  , botLogin :: Text
  -- ^ Stripped and casefolded.
  , fence :: Fence
  , fault :: Maybe EffectFault
  , retryDelay :: Double -> IO ()
  , root :: Text
  , editRoot :: Text
  , reviewRoot :: Text
  , reviewBatchRoot :: Text
  }

-- | @time.sleep@.
sleepSeconds :: Double -> IO ()
sleepSeconds seconds = threadDelay (round (seconds * 1000000))

-- | @_TRANSIENT_RETRY_SECONDS@.
transientRetrySeconds :: [Double]
transientRetrySeconds = [60, 120]

-- | @CommentPublisher(transport, repository, pr_number, bot_login, fence,
-- fault, retry_delay=retry_delay)@.
commentPublisher ::
  Transport -> Text -> Integer -> Text -> Fence -> Maybe EffectFault -> (Double -> IO ()) -> Either InvalidRequest CommentPublisher
commentPublisher transport repository prNumber botLogin fence fault retryDelay =
  let normalized = Py.casefold (Py.strip botLogin)
      number = T.pack (show prNumber)
   in if T.null normalized || not ("[bot]" `T.isSuffixOf` normalized)
        then Left (InvalidRequest "bot login must be the configured GitHub App bot login")
        else
          Right
            CommentPublisher
              { transport
              , repository
              , prNumber
              , botLogin = normalized
              , fence
              , fault
              , retryDelay
              , root = "/repos/" <> repository <> "/issues/" <> number <> "/comments"
              , editRoot = "/repos/" <> repository <> "/issues/comments"
              , reviewRoot = "/repos/" <> repository <> "/pulls/" <> number <> "/comments"
              , reviewBatchRoot = "/repos/" <> repository <> "/pulls/" <> number <> "/reviews"
              }

-- | @CommentPublisher.marker(kind, operation, head)@.
marker :: Text -> Text -> Text -> Either InvalidRequest Text
marker kind operation head'
  | kind `notElem` ["conversation", "finding", "readiness", "reminder"] || not (validOperation operation) || not (lowerSha head') =
      Left (InvalidRequest "publication marker identity is malformed")
  | otherwise = Right ("<!-- hamsterdan:" <> kind <> " operation=" <> operation <> " head=" <> head' <> " -->")
  where
    validOperation text = case T.uncons text of
      Just (first, rest) -> alnum first && T.length rest <= 127 && T.all (\c -> alnum c || c `elem` ['.', '_', ':', '-']) rest
      Nothing -> False
    alnum c = isAsciiUpper c || isAsciiLower c || isDigit c

lowerSha :: Text -> Bool
lowerSha text = T.length text == 40 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) text

-- | The dashboard's marker.
dashboardMarker :: Text
dashboardMarker = "<!-- hamsterdan:dashboard -->"

markerIO :: Text -> Text -> Text -> IO Text
markerIO kind operation head' = either throwIO pure (marker kind operation head')

type Item = [(Text, Json)]

-- | @value.get("body")@.
bodyOf :: Item -> Json
bodyOf item = fromMaybe Null (lookup "body" item)

-- | @_login(value)@: the stripped, casefolded author login.
login :: Item -> Maybe Text
login value = case lookup "user" value of
  Just (Object user) | Just (String name) <- lookup "login" user -> Just (Py.casefold (Py.strip name))
  _ -> Nothing

-- | @_final_marker(body, marker)@.
finalMarker :: Text -> Text -> Bool
finalMarker body wanted = body == wanted || ("\n\n" <> wanted) `T.isSuffixOf` body

-- | @_find_marked(comments, bot_login, marker)@.
findMarked :: [Item] -> Text -> Text -> Maybe Item
findMarked items botLogin wanted =
  find (\item -> login item == Just botLogin && finalMarker (Py.str (fromMaybe (String "") (lookup "body" item))) wanted) items

-- | @_reference(value)@.
reference :: Json -> Either PyFailure CommentReference
reference = \case
  Object members -> case lookup "id" members of
    Nothing -> Left (PyFailure Py.KeyError "'id'")
    Just identifier -> do
      number <- Py.intOf identifier
      pure CommentReference {id = number, url = Py.str (fromMaybe (String "") (lookup "html_url" members))}
  Array _ -> Left (PyFailure Py.TypeError "list indices must be integers or slices, not str")
  String _ -> Left (PyFailure Py.TypeError "string indices must be integers, not 'str'")
  Null -> Left (PyFailure Py.TypeError "'NoneType' object is not subscriptable")
  Bool _ -> Left (PyFailure Py.TypeError "'bool' object is not subscriptable")
  Int _ -> Left (PyFailure Py.TypeError "'int' object is not subscriptable")
  Float _ -> Left (PyFailure Py.TypeError "'float' object is not subscriptable")

-- | @_reference(value)@ where the reference lets the failure propagate.
referenceIO :: Item -> IO CommentReference
referenceIO item = either pyFault pure (reference (Object item))

-- | @_lenient_reference(value)@.
lenientReference :: Json -> Maybe CommentReference
lenientReference = either (const Nothing) Just . reference

existing :: Maybe CommentReference -> PublicationResult
existing = publication "existing"

collision :: IO a
collision = throwIO PublicationCollision

comments :: CommentPublisher -> IO [Item]
comments publisher = publisher.transport.pages (publisher.root <> "?per_page=100")

reviewComments :: CommentPublisher -> IO [Item]
reviewComments publisher = publisher.transport.pages (publisher.reviewRoot <> "?per_page=100")

-- | @_find(marker)@.
findIssue :: CommentPublisher -> Text -> IO (Maybe Item)
findIssue publisher wanted = (\items -> findMarked items publisher.botLogin wanted) <$> comments publisher

-- | @_find_review(marker)@.
findReview :: CommentPublisher -> Text -> IO (Maybe Item)
findReview publisher wanted = (\items -> findMarked items publisher.botLogin wanted) <$> reviewComments publisher

-- | Whether a held body is the payload or one of the compatible payloads.
heldBody :: Item -> Text -> [Text] -> Bool
heldBody item payload compatible = case bodyOf item of
  String body -> body == payload || body `elem` compatible
  _ -> False

callFault :: CommentPublisher -> Text -> Text -> Text -> IO ()
callFault publisher phase kind operation = case publisher.fault of
  Just hook -> hook phase publisher.repository publisher.prNumber kind operation
  Nothing -> pure ()

-- | @authority_operation or operation@.
orOperation :: Maybe Text -> Text -> Text
orOperation authorityOperation operation = case authorityOperation of
  Just value | not (T.null value) -> value
  _ -> operation

-- | @immutable(kind, operation, epoch, head, body, authority_operation=…,
-- compatible_bodies=…)@.
immutable :: CommentPublisher -> Text -> Text -> Integer -> Text -> Text -> Maybe Text -> [Text] -> IO PublicationResult
immutable publisher kind operation epoch head' body authorityOperation compatibleBodies = do
  wanted <- markerIO kind operation head'
  let payload = body <> "\n\n" <> wanted
      compatible = [value <> "\n\n" <> wanted | value <- compatibleBodies]
  found <- findIssue publisher wanted
  case found of
    Just item -> do
      unless (heldBody item payload compatible) collision
      existing . Just <$> referenceIO item
    Nothing -> attempt wanted payload (0 :: Int)
  where
    attempt wanted payload n = do
      publisher.fence publisher.repository publisher.prNumber epoch head' (orOperation authorityOperation operation)
      outcome <- try $ do
        callFault publisher "before_call" kind operation
        response <- publisher.transport.request "POST" publisher.root (Just [("body", String payload)])
        callFault publisher "after_call" kind operation
        pure response
      case outcome of
        Left (failure :: GitHubBoundaryError) -> do
          recovered <- recover publisher wanted payload
          case recovered of
            Just result -> pure result
            Nothing
              | n > 0 -> throwIO failure
              | otherwise -> attempt wanted payload (n + 1)
        Right response -> do
          let created
                | response.status == 201 = either (const Nothing) Just (reference response.body)
                | otherwise = Nothing
          case created of
            Just ref -> pure (publication "created" (Just ref))
            Nothing -> do
              recovered <- recover publisher wanted payload
              case recovered of
                Just result -> pure result
                Nothing -> do
                  when (response.status == 201) (throwIO (boundary "GitHub did not prove comment publication"))
                  commentRejection response.status "comment publication" Nothing

-- | @_recover(marker, payload)@.
recover :: CommentPublisher -> Text -> Text -> IO (Maybe PublicationResult)
recover publisher wanted payload = do
  found <- findIssue publisher wanted
  case found of
    Nothing -> pure Nothing
    Just item -> do
      unless (bodyOf item == String payload) collision
      Just . existing . Just <$> referenceIO item

-- | @_find_operation(kind, operation)@: the App's final marker for the
-- operation under any head.
findOperation :: CommentPublisher -> Text -> Text -> IO (Maybe (Item, Text))
findOperation publisher kind operation = do
  items <- comments publisher
  pure (firstJust items)
  where
    prefix = "<!-- hamsterdan:" <> kind <> " operation=" <> operation <> " head="
    firstJust = \case
      [] -> Nothing
      item : rest
        | login item /= Just publisher.botLogin -> firstJust rest
        | otherwise ->
            let body = Py.str (fromMaybe (String "") (lookup "body" item))
                tailText = snd (T.breakOnEnd "\n\n" body)
             in case T.stripPrefix prefix tailText >>= T.stripSuffix " -->" of
                  Just held' | lowerSha held' -> Just (item, held')
                  _ -> firstJust rest

-- | @immutable_operation(kind, operation, body, context=…,
-- compatible_bodies=…)@: reconcile the operation under any earlier head
-- before consulting the current context.
immutableOperation :: CommentPublisher -> Text -> Text -> Text -> IO (Integer, Text) -> [Text] -> IO PublicationResult
immutableOperation publisher kind operation body context compatibleBodies = do
  found <- findOperation publisher kind operation
  case found of
    Just (item, heldHead) -> do
      wanted <- markerIO kind operation heldHead
      let payload = body <> "\n\n" <> wanted
          compatible = [value <> "\n\n" <> wanted | value <- compatibleBodies]
      unless (heldBody item payload compatible) collision
      existing . Just <$> referenceIO item
    Nothing -> do
      (epoch, head') <- context
      immutable publisher kind operation epoch head' body Nothing compatibleBodies

-- | @reminder_operation(operation, context=…)@: presence of the reminder
-- marker under any head proves the nudge landed.
reminderOperation :: CommentPublisher -> Text -> IO (Integer, Text, Maybe Text, Text) -> IO PublicationResult
reminderOperation publisher operation context = do
  found <- findOperation publisher "reminder" operation
  case found of
    Just (item, _) -> existing . Just <$> referenceIO item
    Nothing -> do
      (epoch, head', reviewer, author) <- context
      reminder publisher operation epoch head' reviewer author Nothing

-- | @find(kind, operation, head, body, compatible_bodies=…)@:
-- reconciliation without an effect.
findPublication :: CommentPublisher -> Text -> Text -> Text -> Text -> [Text] -> IO (Maybe PublicationResult)
findPublication publisher kind operation head' body compatibleBodies = do
  wanted <- markerIO kind operation head'
  let payload = body <> "\n\n" <> wanted
      compatible = [value <> "\n\n" <> wanted | value <- compatibleBodies]
  found <- findIssue publisher wanted
  case found of
    Nothing -> pure Nothing
    Just item -> do
      unless (heldBody item payload compatible) collision
      Just . existing . Just <$> referenceIO item

-- | @dashboard(operation, epoch, head, body)@: create or update the one
-- readiness dashboard comment.
dashboard :: CommentPublisher -> Text -> Integer -> Text -> Text -> IO PublicationResult
dashboard publisher operation epoch head' body = do
  found <- findIssue publisher dashboardMarker
  let payload = body <> "\n\n" <> dashboardMarker
      fenceNow = publisher.fence publisher.repository publisher.prNumber epoch head' operation
  case found of
    Nothing -> do
      fenceNow
      outcome <- try (publisher.transport.request "POST" publisher.root (Just [("body", String payload)]))
      case outcome of
        Left (failure :: GitHubBoundaryError) ->
          recover publisher dashboardMarker payload >>= maybe (throwIO failure) pure
        Right response -> do
          early <-
            if response.status == 201
              then pure (publication "created" . Just <$> either (const Nothing) Just (reference response.body))
              else do
                recovered <- recover publisher dashboardMarker payload
                case recovered of
                  Just result -> pure (Just result)
                  Nothing -> Just <$> commentRejection response.status "dashboard publication" Nothing
          case early of
            Just result -> pure result
            Nothing ->
              recover publisher dashboardMarker payload
                >>= maybe (throwIO (boundary "GitHub did not prove dashboard publication")) pure
    Just item
      | bodyOf item == String payload -> existing . Just <$> referenceIO item
      | otherwise -> do
          fenceNow
          identifier <- maybe (throwIO (PythonFault "KeyError" "'id'")) pure (lookup "id" item)
          outcome <-
            try (publisher.transport.request "PATCH" (publisher.editRoot <> "/" <> Py.str identifier) (Just [("body", String payload)]))
          case outcome of
            Left (failure :: GitHubBoundaryError) ->
              recoverDashboard publisher payload >>= maybe (throwIO failure) pure
            Right response -> do
              early <-
                if response.status == 200
                  then pure (publication "updated" . Just <$> either (const Nothing) Just (reference response.body))
                  else do
                    recovered <- recoverDashboard publisher payload
                    case recovered of
                      Just result -> pure (Just result)
                      Nothing -> do
                        held' <- referenceIO item
                        Just <$> commentRejection response.status "dashboard update" (Just held')
              case early of
                Just result -> pure result
                Nothing ->
                  recoverDashboard publisher payload
                    >>= maybe (throwIO (boundary "GitHub did not prove dashboard update")) pure

-- | @_recover_dashboard(marker, payload)@.
recoverDashboard :: CommentPublisher -> Text -> IO (Maybe PublicationResult)
recoverDashboard publisher payload = do
  found <- findIssue publisher dashboardMarker
  case found of
    Just item | bodyOf item == String payload -> Just . existing . Just <$> referenceIO item
    _ -> pure Nothing

-- | @_comment_rejection(status, operation, reference=…)@.
commentRejection :: Int -> Text -> Maybe CommentReference -> IO PublicationResult
commentRejection status operation held'
  | status == 403 || status == 404 = pure (PublicationResult "capability_unavailable" held' False False)
  | status == 429 || status >= 500 = throwIO (boundary ("GitHub did not prove " <> operation))
  | otherwise = throwIO (PublicationRejected operation)

-- | @_FindingContent@.
data FindingContent = FindingContent
  { marker :: Text
  , inlineDetail :: Text
  , inlinePayload :: Text
  , fallbackDetail :: Text
  , fallbackPayload :: Text
  , legacyPayload :: Text
  }
  deriving stock (Eq, Show)

-- | @_finding_content(finding, head)@.
findingContent :: CommentPublisher -> FindingPublication -> Text -> Either InvalidRequest FindingContent
findingContent publisher item head' = do
  wanted <- marker "finding" item.operation head'
  let number = T.pack (show item.line)
      location = if not (T.null item.path) && item.line > 0 then "`" <> item.path <> ":" <> number <> "`" else ""
      related
        | null item.relatedLocations = ""
        | otherwise =
            "Related locations:\n"
              <> T.intercalate
                "\n"
                [ "- [`"
                    <> relatedPath
                    <> ":"
                    <> T.pack (show relatedLine)
                    <> "`](https://github.com/"
                    <> publisher.repository
                    <> "/blob/"
                    <> head'
                    <> "/"
                    <> Url.quote "/" relatedPath
                    <> "#L"
                    <> T.pack (show relatedLine)
                    <> ")"
                | (relatedPath, relatedLine) <- item.relatedLocations
                ]
      suggestionBlock = if T.null item.suggestion then "" else "```suggestion\n" <> item.suggestion <> "\n```"
      linkLine = if T.null item.link then "" else "Link: " <> item.link
      joinWith separator = T.intercalate separator . filter (not . T.null)
      inline = joinWith "\n\n" [item.text, related, suggestionBlock, linkLine]
      fallback =
        joinWith "\n\n" [item.text, if T.null location then "" else "Primary location: " <> location, related, suggestionBlock, linkLine]
      legacy = joinWith "\n" [item.text, if T.null location then "" else "Location: " <> item.path <> ":" <> number, linkLine]
  pure
    FindingContent
      { marker = wanted
      , inlineDetail = inline
      , inlinePayload = inline <> "\n\n" <> wanted
      , fallbackDetail = fallback
      , fallbackPayload = fallback <> "\n\n" <> wanted
      , legacyPayload = legacy <> "\n\n" <> wanted
      }

-- | @finding(operation, epoch, head, text, path=…, line=…, …)@: an inline
-- review comment where the location allows, else the issue-comment
-- fallback.
publishFinding :: CommentPublisher -> FindingPublication -> Integer -> Text -> Maybe Text -> IO PublicationResult
publishFinding publisher item epoch head' authorityOperation = do
  content <- either throwIO pure (findingContent publisher item head')
  let location = not (T.null item.path) && item.line > 0
  heldReview <- if location then findReview publisher content.marker else pure Nothing
  case heldReview of
    Just review -> do
      unless (bodyOf review `elem` [String content.inlinePayload, String content.fallbackPayload]) collision
      ref <- referenceIO review
      pure (publication "existing" (Just ref)) {inline = True}
    Nothing -> do
      heldIssue <- findIssue publisher content.marker
      case heldIssue of
        Just held' -> do
          let compatibleLegacy =
                T.null item.suggestion && null item.relatedLocations && bodyOf held' == String content.legacyPayload
          when (bodyOf held' /= String content.fallbackPayload && not compatibleLegacy) collision
          ref <- referenceIO held'
          pure (publication "existing" (Just ref)) {inline = False}
        Nothing -> do
          inlineResult <-
            if location
              then Just <$> inlineFinding publisher item.operation epoch head' content.inlineDetail item.path item.line authorityOperation
              else pure Nothing
          case inlineResult of
            Just result | result.capabilityAvailable -> pure result
            _ -> do
              result <- immutable publisher "finding" item.operation epoch head' content.fallbackDetail authorityOperation []
              pure result {inline = False}

-- | @findings(epoch, head, findings, authority_operation=…)@: one native
-- review carrying every anchored finding not already landed.
publishFindings :: CommentPublisher -> Integer -> Text -> [FindingPublication] -> Text -> IO [PublicationResult]
publishFindings publisher epoch head' items authorityOperation = do
  when (null items || any (\item -> T.null item.path || item.line <= 0) items) $
    throwIO (InvalidRequest "a native review batch requires anchored findings")
  when (Set.size (Set.fromList (map (.operation) items)) /= length items) $
    throwIO (InvalidRequest "a native review batch requires unique finding operations")
  contents <- either throwIO pure (mapM (\item -> findingContent publisher item head') items)
  results <- newIORef Map.empty
  pending <- reconcileBatch publisher (zip items contents) results
  let final = do
        landed <- readIORef results
        pure [landed Map.! item.operation | item <- items]
      retries = length transientRetrySeconds
      loop attempt current reconciliationRequired = do
        current' <- if reconciliationRequired then reconcileBatch publisher current results else pure current
        if null current'
          then final
          else do
            publisher.fence publisher.repository publisher.prNumber epoch head' authorityOperation
            outcome <- try $ do
              callFault publisher "before_call" "finding" authorityOperation
              response <-
                publisher.transport.request
                  "POST"
                  publisher.reviewBatchRoot
                  ( Just
                      [ ("body", String "I found review issues on this head; details are attached to the relevant lines.")
                      , ("commit_id", String head')
                      , ("event", String "COMMENT")
                      ,
                        ( "comments"
                        , Array
                            [ Object
                                [ ("body", String content.inlinePayload)
                                , ("path", String item.path)
                                , ("line", Int item.line)
                                , ("side", String "RIGHT")
                                ]
                            | (item, content) <- current'
                            ]
                        )
                      ]
                  )
              callFault publisher "after_call" "finding" authorityOperation
              pure response
            case outcome of
              Left (failure :: GitHubBoundaryError) -> do
                reconciled <- try (reconcileBatch publisher current' results)
                let (next, required) = case reconciled of
                      Right remaining -> (remaining, False)
                      Left (_ :: GitHubBoundaryError) -> (current', True)
                if
                  | null next -> final
                  | attempt == retries -> throwIO failure
                  | otherwise -> do
                      publisher.retryDelay (transientRetrySeconds !! attempt)
                      loop (attempt + 1) next required
              Right response
                | response.status == 200 -> do
                    let ref = lenientReference response.body
                    mapM_
                      (\(item, _) -> modifyIORef' results (Map.insert item.operation (publication "created" ref) {inline = True}))
                      current'
                    final
                | otherwise -> do
                    next <- reconcileBatch publisher current' results
                    if
                      | null next -> final
                      | transientInlineRejection response ->
                          if attempt < retries
                            then do
                              publisher.retryDelay (transientRetrySeconds !! attempt)
                              loop (attempt + 1) next False
                            else inlineRejection response TransientHttpRejection
                      | otherwise -> inlineRejection response (inlineFailureClass response)
  loop 0 pending False

-- | @_reconcile_finding_batch(findings, contents, results)@: record every
-- landed finding and return the rest.
reconcileBatch ::
  CommentPublisher ->
  [(FindingPublication, FindingContent)] ->
  IORef (Map.Map Text PublicationResult) ->
  IO [(FindingPublication, FindingContent)]
reconcileBatch publisher pending results = do
  reviews <- reviewComments publisher
  issues <- comments publisher
  fmap concat . forM pending $ \(item, content) ->
    case findMarked reviews publisher.botLogin content.marker of
      Just review -> do
        unless (bodyOf review `elem` [String content.inlinePayload, String content.fallbackPayload]) collision
        ref <- referenceIO review
        modifyIORef' results (Map.insert item.operation (publication "existing" (Just ref)) {inline = True})
        pure []
      Nothing -> case findMarked issues publisher.botLogin content.marker of
        Just held' -> do
          unless (bodyOf held' == String content.fallbackPayload) collision
          ref <- referenceIO held'
          modifyIORef' results (Map.insert item.operation (publication "existing" (Just ref)) {inline = False})
          pure []
        Nothing -> pure [(item, content)]

-- | @finding_find(operation, head)@: presence-only lookup of one landed
-- finding.
findingFind :: CommentPublisher -> Text -> Text -> IO (Maybe PublicationResult)
findingFind publisher operation head' = do
  wanted <- markerIO "finding" operation head'
  review <- findReview publisher wanted
  case review of
    Just item -> Just . (\ref -> (publication "existing" (Just ref)) {inline = True}) <$> referenceIO item
    Nothing -> do
      held' <- findIssue publisher wanted
      case held' of
        Just item -> Just . (\ref -> (publication "existing" (Just ref)) {inline = False}) <$> referenceIO item
        Nothing -> pure Nothing

-- | @_inline_finding(…)@.
inlineFinding :: CommentPublisher -> Text -> Integer -> Text -> Text -> Text -> Integer -> Maybe Text -> IO PublicationResult
inlineFinding publisher operation epoch head' body path line authorityOperation = do
  wanted <- markerIO "finding" operation head'
  let payload = body <> "\n\n" <> wanted
      retries = length transientRetrySeconds
      recovered = do
        found <- findReview publisher wanted
        case found of
          Nothing -> pure Nothing
          Just item -> do
            unless (bodyOf item == String payload) collision
            ref <- referenceIO item
            pure (Just (publication "existing" (Just ref)) {inline = True})
      loop attempt = do
        publisher.fence publisher.repository publisher.prNumber epoch head' (orOperation authorityOperation operation)
        outcome <- try $ do
          callFault publisher "before_call" "finding" operation
          response <-
            publisher.transport.request
              "POST"
              publisher.reviewRoot
              ( Just
                  [ ("body", String payload)
                  , ("commit_id", String head')
                  , ("path", String path)
                  , ("line", Int line)
                  , ("side", String "RIGHT")
                  ]
              )
          callFault publisher "after_call" "finding" operation
          pure response
        case outcome of
          Left (failure :: GitHubBoundaryError) ->
            recovered >>= \case
              Just result -> pure result
              Nothing
                | attempt == retries -> throwIO failure
                | otherwise -> do
                    publisher.retryDelay (transientRetrySeconds !! attempt)
                    loop (attempt + 1)
          Right response
            | response.status == 201, Object members <- response.body -> do
                ref <- referenceIO members
                pure (publication "created" (Just ref)) {inline = True}
            | otherwise ->
                recovered >>= \case
                  Just result -> pure result
                  Nothing
                    | inlineUnavailable response -> pure (PublicationResult "inline_unavailable" Nothing False False)
                    | transientInlineRejection response ->
                        if attempt < retries
                          then do
                            publisher.retryDelay (transientRetrySeconds !! attempt)
                            loop (attempt + 1)
                          else inlineRejection response TransientHttpRejection
                    | otherwise -> inlineRejection response (inlineFailureClass response)
  loop (0 :: Int)

-- | @reminder(operation, epoch, head, reviewer=…, author=…,
-- maintainer=…)@.
reminder :: CommentPublisher -> Text -> Integer -> Text -> Maybe Text -> Text -> Maybe Text -> IO PublicationResult
reminder publisher operation epoch head' reviewer author maintainer = do
  let present = \case
        Just value | not (T.null value) -> Just value
        _ -> Nothing
      target = fromMaybe author (maybe (present maintainer) Just (present reviewer))
      reviewing = not (isNothing (present reviewer))
      action = if reviewing then "Please review this PR" else "Please assign a reviewer for this PR"
      addressee = "@" <> T.dropWhile (== '@') target
  dashboardItem <- findIssue publisher dashboardMarker
  let state = maybe "" (\item -> Py.str (fromMaybe (String "") (lookup "html_url" item))) dashboardItem
      link = if T.null state then "" else " [See current readiness state.](" <> state <> ")"
      legacy =
        addressee <> ", " <> (if reviewing then "please review this PR" else "please assign a reviewer for this PR") <> "." <> link
  immutable
    publisher
    "reminder"
    operation
    epoch
    head'
    (addressee <> ", this PR and I have gotten to know each other quite well. " <> action <> "." <> link)
    Nothing
    [legacy]

-- | @reviewer_assignment_available@.
reviewerAssignmentAvailable :: CommentPublisher -> Bool
reviewerAssignmentAvailable _ = False

-- | @_inline_unavailable(response)@.
inlineUnavailable :: WireResponse -> Bool
inlineUnavailable response = case response.body of
  Object members
    | response.status == 422
    , Just (String message) <- lookup "message" members ->
        Py.casefold (Py.strip message) `elem` ["line is not in diff", "pull request review thread line must be part of the diff"]
  _ -> False

-- | @_transient_inline_rejection(response)@.
transientInlineRejection :: WireResponse -> Bool
transientInlineRejection response
  | response.status == 429 || response.status >= 500 = True
  | otherwise = case response.body of
      Object members | Just (String message) <- lookup "message" members ->
        let normalized = Py.casefold (Py.strip message)
         in if response.status == 403
              then "secondary rate limit" `T.isInfixOf` normalized || "abuse detection" `T.isInfixOf` normalized
              else
                response.status == 422
                  && normalized == "validation failed"
                  && not (maybe False Py.truthy (lookup "errors" members))
      _ -> False

-- | @_inline_failure_class(response)@.
inlineFailureClass :: WireResponse -> FailureClass
inlineFailureClass response
  | response.status == 403 || response.status == 404 = CapabilityDenial
  | response.status == 422 = PayloadRejection
  | otherwise = ProviderRejection

-- | @raise _inline_rejection(response, failure_class)@.
inlineRejection :: WireResponse -> FailureClass -> IO a
inlineRejection response failureClass = do
  unless (response.status >= 100 && response.status <= 599) $
    throwIO (PythonFault "ValueError" "provider status must be an HTTP status")
  throwIO
    GitHubBoundaryError
      { kind = Boundary
      , message = "GitHub did not prove inline finding publication"
      , failureClass
      , providerStatus = Just response.status
      , providerDetail = inlineProviderDetail response.body
      }

-- | @_inline_provider_detail(response)@: the bounded error-shape atom.
inlineProviderDetail :: Json -> Text
inlineProviderDetail = \case
  Object members -> case lookup "errors" members of
    Just (Array errors@(_ : _)) -> T.take 96 (T.intercalate "." (map shape (take 4 errors)))
    _ -> "no_structured_errors"
  _ -> "non_object_body"
  where
    shape = \case
      Object error' ->
        atom (lookup "field" error') ["body", "commit_id", "line", "path", "pull_request_review_thread.line", "side"] "unknown_field"
          <> ":"
          <> atom (lookup "code" error') ["already_exists", "custom", "invalid", "missing", "unprocessable"] "unknown_code"
      _ -> "non_object_error"
    atom value allowed fallback = case value of
      Just (String text) ->
        let normalized = T.replace "/" "." (Py.casefold (Py.strip text))
         in if normalized `elem` allowed then normalized else fallback
      _ -> fallback

-- | @CommentRerunBroker(authority, publisher)@: requests, but never claims
-- observation of, a same-head whole-run rerun.
data CommentRerunBroker = CommentRerunBroker
  { authority :: GitHubAuthority
  , publisher :: CommentPublisher
  }

-- | @CommentRerunBroker.marker(run_id, head, operation)@.
rerunMarker :: Integer -> Text -> Text -> Text
rerunMarker runId head' operation =
  "<!-- hamsterdan-rerun run=" <> T.pack (show runId) <> " head=" <> head' <> " operation=" <> operation <> " -->"

-- | @held(run_id, head, operation)@: operation lookup with no currency
-- requirement.
held :: CommentRerunBroker -> Integer -> Text -> Text -> IO (Maybe PublicationResult)
held broker runId head' operation = do
  found <- findIssue broker.publisher (rerunMarker runId head' operation)
  pure (existing . lenientReference . Object <$> nonEmpty found)

-- | A held comment, when CPython would find it truthy.
nonEmpty :: Maybe Item -> Maybe Item
nonEmpty = \case
  Just item | not (null item) -> Just item
  _ -> Nothing

-- | @issue(run, epoch=…, operation=…)@: one rerun issuance and its
-- pre-request evidence cut.
issue :: CommentRerunBroker -> ActionsRunSnapshot -> Integer -> Text -> IO RerunIssue
issue broker run epoch operation = do
  pull <- pullRequest broker.authority
  known <- workflowRuns broker.authority run.workflow pull.head
  when (pull.head /= run.head || all (\candidate -> candidate.id /= run.id) known) $
    throwIO (RerunRefused "rerun request does not belong to the configured repository and exact head")
  let (cutId, cutAttempt) = maximum [(candidate.id, candidate.attempt) | candidate <- known]
      wanted = rerunMarker run.id run.head operation
      publisher = broker.publisher
  found <- findIssue publisher wanted
  case nonEmpty found of
    Just item -> pure (RerunIssue (existing (lenientReference (Object item))) cutId cutAttempt)
    Nothing -> do
      publisher.fence publisher.repository publisher.prNumber epoch run.head operation
      response <- publisher.transport.request "POST" publisher.root (Just [("body", String wanted)])
      case response.body of
        Object _ | response.status == 201 ->
          pure (RerunIssue (publication "requested" (lenientReference response.body)) cutId cutAttempt)
        _ -> throwIO (boundary "GitHub did not prove rerun broker publication")

-- | @request(run, epoch=…, operation=…)@: 'issue', with a refusal raised as
-- a boundary failure.
requestRerun :: CommentRerunBroker -> ActionsRunSnapshot -> Integer -> Text -> IO PublicationResult
requestRerun broker run epoch operation =
  ((.result) <$> issue broker run epoch operation)
    `catch` \(RerunRefused message) -> throwIO (boundary message)

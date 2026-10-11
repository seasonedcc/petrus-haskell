{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The bounded, fixed-origin REST and GraphQL capabilities
-- (@github_app/transport.py@): 'githubTransport' and 'githubDownloads' over
-- one authenticated client, and 'githubGraphQL' over any 'Transport'.
--
-- Every refusal and failure is the reference's: a request outside
-- @GET@/@POST@/@PATCH@ or the API origin, a body that is not finite JSON or
-- exceeds 64 KiB, a redirect, a response over 1 MiB, and pagination that
-- leaves the origin, repeats, or runs past twenty pages. Failures without a
-- proven outcome carry the reference's diagnostic atom
-- (@http_transport@, @github_exception@, @response_json@, …).
module Hamsterdan.GitHub.Transport
  ( -- * REST
    githubTransport
  , githubDownloads
  , request
  , download
  , pages
  , nextPath
  , maxBodyBytes
  , maxRequestBytes
  , maxPages

    -- * GraphQL
  , githubGraphQL
  , digest
  , reviewThreadsQuery
  , resolveThreadMutation
  , repositoryQuery
  , updateRefsMutation

    -- * Python faults
  ) where

import Control.Exception (throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Client (ClientResponse (..), GitHubClient, sendRequest)
import Hamsterdan.GitHub.Http
import Hamsterdan.GitHub.Models
import Hamsterdan.Python (PythonException (..), pythonError, pythonExceptionStr, raise)
import Hamsterdan.Python qualified as Py
import Hamsterdan.GitHub.Url qualified as Url
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps)

-- | @MAX_BODY_BYTES@.
maxBodyBytes :: Int
maxBodyBytes = 1048576

-- | @MAX_REQUEST_BYTES@.
maxRequestBytes :: Int
maxRequestBytes = 65536

-- | @MAX_PAGES@.
maxPages :: Int
maxPages = 20

-- | @GitHubKitTransport(client)@ as the REST capability.
githubTransport :: GitHubClient -> Transport
githubTransport client = Transport {request = request client, pages = pages client}

-- | @GitHubKitTransport(client)@ as the download capability.
githubDownloads :: GitHubClient -> BinaryTransport
githubDownloads client = BinaryTransport {download = download client}

-- | The origin test shared by 'request' and 'download': the path starts
-- with one @/@ and @urlsplit@ finds no network location (its @ValueError@
-- propagates).
foreignPath :: Text -> IO Bool
foreignPath path
  | not ("/" `T.isPrefixOf` path) || "//" `T.isPrefixOf` path = pure True
  | otherwise = case Url.urlsplit path of
      Left message -> throwIO (pythonError "ValueError" message)
      Right split -> pure (not (T.null split.netloc))

-- | @GitHubKitTransport.request@.
request :: GitHubClient -> Text -> Text -> Maybe [(Text, Json)] -> IO WireResponse
request client method path body = do
  outside <- if method `notElem` ["GET", "POST", "PATCH"] then pure True else foreignPath path
  when outside (throwIO (boundary "GitHub request is outside the admitted origin or methods"))
  when (method == "GET" && isJust body) (throwIO (boundary "GitHub GET request cannot contain a body"))
  wireBody <- case body of
    Nothing -> pure Nothing
    Just members -> do
      let document = Object (dictOf members)
      if tooLongInteger document
        then throwIO (boundary "GitHub request body is not finite JSON")
        else case dumps compact {ensureAscii = True} document of
          Left _ -> throwIO (boundary "GitHub request body is not finite JSON")
          Right encoded -> do
            when (BS.length encoded > maxRequestBytes) (throwIO (boundary "GitHub request body exceeds its bound"))
            either (const (throwIO (boundary "GitHub request body is not finite JSON"))) (pure . Just) (dumps compact document)
  outcome <- try $ sendRequest client method path wireBody $ \response -> do
    when (response.status >= 300 && response.status < 400) (throwIO (boundary "GitHub returned an unadmitted redirect"))
    decoder <- contentDecoder response.headers response.chunks
    raw <- readBounded maxBodyBytes (throwIO (boundary "GitHub response exceeds its bound")) decoder
    value <-
      if BS.null raw
        then pure Null
        else case Py.loadsBytes raw of
          Right value -> pure value
          -- @UnicodeDecodeError@, @JSONDecodeError@ and the digit-limit
          -- @ValueError@ are value failures; @RecursionError@ is a
          -- @RuntimeError@.
          Left failure@(PythonException cls _) ->
            throwIO (ClientError (if cls == "RecursionError" then RuntimeKind else ValueKind) cls (pythonExceptionStr failure))
    next <- nextPath (lookupHeader "link" response.headers)
    pure WireResponse {status = response.status, body = value, nextPath = next}
  case outcome of
    Right response -> pure response
    Left (failure :: ClientError) -> case failure.kind of
      UncaughtKind -> throwIO (pythonError failure.pythonClass failure.detail)
      _ -> throwIO (boundaryWith "GitHub request failed without a proven outcome" (requestDetail failure))

-- | @_transport_failure_detail@.
requestDetail :: ClientError -> Text
requestDetail failure = case failure.kind of
  TransportKind -> "http_transport"
  GitHubKind -> "github_exception"
  OsKind -> "os_error"
  RuntimeKind -> "runtime_error"
  _
    | failure.pythonClass == "UnicodeDecodeError" -> "response_encoding"
    | failure.pythonClass == "JSONDecodeError" -> "response_json"
    | otherwise -> "value_error"

-- | @dict(body)@: the last value of a repeated key, at its first position.
dictOf :: [(Text, Json)] -> [(Text, Json)]
dictOf members =
  let lastValues = Map.fromList members
      firstKeys = go Set.empty members
      go _ [] = []
      go seen ((key, _) : rest)
        | Set.member key seen = go seen rest
        | otherwise = key : go (Set.insert key seen) rest
   in [(key, lastValues Map.! key) | key <- firstKeys]

-- | An integer @json.dumps@ refuses to spell (over 4300 digits).
tooLongInteger :: Json -> Bool
tooLongInteger = \case
  Int i -> abs i >= 10 ^ (4300 :: Int)
  Array items -> any tooLongInteger items
  Object members -> any (tooLongInteger . snd) members
  _ -> False

-- | @GitHubKitTransport.download@.
download :: GitHubClient -> Text -> Int -> IO ByteString
download client path limit = do
  outside <- if limit <= 0 then pure True else foreignPath path
  when outside (throwIO (boundary "GitHub download is outside the admitted origin or bound"))
  outcome <- try $ sendRequest client "GET" path Nothing $ \response -> do
    unless (response.status == 200) (throwIO (boundary "GitHub download did not succeed"))
    decoder <- contentDecoder response.headers response.chunks
    readBounded limit (throwIO (boundary "GitHub response exceeds its bound")) decoder
  case outcome of
    Right bytes -> pure bytes
    Left (failure :: ClientError) -> case failure.kind of
      TransportKind -> throwIO (boundaryWith "GitHub download failed without a proven outcome" "http_transport")
      HttpKind -> throwIO (boundaryWith "GitHub download failed without a proven outcome" "value_error")
      GitHubKind -> throwIO (boundaryWith "GitHub download failed without a proven outcome" "github_exception")
      _ -> throwIO (pythonError failure.pythonClass failure.detail)

-- | @GitHubKitTransport.pages@.
pages :: GitHubClient -> Text -> IO [[(Text, Json)]]
pages client start = go Set.empty (Just start) []
  where
    go _ Nothing acc = pure (concat (reverse acc))
    go seen (Just current) acc = do
      when (Set.member current seen || Set.size seen >= maxPages) $
        throwIO (boundary "GitHub pagination is cyclic or exceeds its bound")
      response <- request client "GET" current Nothing
      objects <- case response.body of
        Array items | response.status == 200, Just objects <- traverse asObject items -> pure objects
        _ -> throwIO (boundary "GitHub paginated response is not a successful object list")
      go (Set.insert current seen) response.nextPath (objects : acc)
    asObject = \case
      Object members -> Just members
      _ -> Nothing

-- | @_next@: the admitted @rel="next"@ path and query of a @Link@ header.
nextPath :: Maybe Text -> IO (Maybe Text)
nextPath = \case
  Nothing -> pure Nothing
  Just link | T.null link -> pure Nothing
  Just link -> go Nothing (T.splitOn "," link)
  where
    go found [] = pure found
    go found (part : rest) =
      case T.splitOn ";" (Py.strip part) of
        target0 : parameters
          | any ((== "rel=\"next\"") . Py.strip) parameters -> do
              let target = Py.strip target0
              when (isJust found || T.length target < 3 || not ("<" `T.isPrefixOf` target) || not (">" `T.isSuffixOf` target)) $
                throwIO (boundary "GitHub pagination evidence is malformed or ambiguous")
              case admitted (T.drop 1 (T.dropEnd 1 target)) of
                Nothing -> throwIO (boundary "GitHub pagination escaped the admitted origin")
                Just next -> go (Just next) rest
        _ -> go found rest
    admitted url = case Url.urlsplit url of
      Left _ -> Nothing
      Right parsed ->
        let invalid =
              parsed.scheme /= "https"
                || Url.hostname parsed /= Just Url.apiHost
                || either (const True) isJust (Url.port parsed)
                || isJust (Url.username parsed)
                || isJust (Url.password parsed)
                || not (T.null parsed.fragment)
                || not ("/" `T.isPrefixOf` parsed.path)
         in if invalid then Nothing else Just (parsed.path <> (if T.null parsed.query then "" else "?" <> parsed.query))

-- | @_digest@: SHA-256 of the sorted, compact, ASCII JSON spelling.
digest :: Json -> Text
digest value = case dumps compact {ensureAscii = True, sortKeys = True, allowNan = True} value of
  Right bytes -> T.pack (show (hashWith SHA256 bytes))
  Left _ -> ""

reviewThreadsQuery, resolveThreadMutation, repositoryQuery, updateRefsMutation :: Text
reviewThreadsQuery = "\n        query($owner:String!,$repository:String!,$number:Int!,$after:String) {\n          repository(owner:$owner,name:$repository) {\n            pullRequest(number:$number) {\n              reviewThreads(first:100,after:$after) {\n                nodes { id isResolved comments(first:1) { nodes { viewerDidAuthor body } } }\n                pageInfo { hasNextPage endCursor }\n              }\n            }\n          }\n        }\n        "
resolveThreadMutation = "\n        mutation($thread:ID!) {\n          resolveReviewThread(input:{threadId:$thread}) { thread { id isResolved } }\n        }\n        "
repositoryQuery = "\n        query($owner:String!,$repository:String!) {\n          repository(owner:$owner,name:$repository) { id }\n        }\n        "
updateRefsMutation = "\n        mutation($input:UpdateRefsInput!) {\n          updateRefs(input:$input) { clientMutationId }\n        }\n        "

-- | @GitHubGraphQL(transport)@.
githubGraphQL :: Transport -> GraphQLTransport
githubGraphQL transport =
  GraphQLTransport
    { reviewThreads = reviewThreads transport
    , resolveReviewThread = resolveReviewThread transport
    , compareAndSwapRef = compareAndSwapRef transport
    }

-- | @body[k1][k2]…@: 'Nothing' where CPython raises @KeyError@ or
-- @TypeError@.
subscripts :: [Text] -> Json -> Maybe Json
subscripts keys value = case keys of
  [] -> Just value
  key : rest -> case value of
    Object members -> lookup key members >>= subscripts rest
    _ -> Nothing

-- | The common GraphQL response test: a 200 whose body is an object
-- without truthy @errors@.
graphQLAccepted :: WireResponse -> Bool
graphQLAccepted response = case response.body of
  Object members -> response.status == 200 && not (maybe False Py.truthy (lookup "errors" members))
  _ -> False

reviewThreads :: Transport -> Text -> Text -> Integer -> IO [Json]
reviewThreads transport owner repository number = go (0 :: Int) Null []
  where
    go attempt cursor acc
      | attempt >= maxPages = throwIO (boundary "GitHub review-thread pagination exceeds its bound")
      | otherwise = do
          response <-
            transport.request
              "POST"
              "/graphql"
              ( Just
                  [ ("query", String reviewThreadsQuery)
                  , ("variables", Object [("owner", String owner), ("repository", String repository), ("number", Int number), ("after", cursor)])
                  ]
              )
          unless (graphQLAccepted response) (throwIO (boundary "GitHub review-thread evidence is unavailable"))
          (nodes, page) <- case subscripts ["data", "repository", "pullRequest", "reviewThreads"] response.body of
            Just threads
              | Just (Array nodes) <- subscripts ["nodes"] threads
              , Just (Object pageMembers) <- subscripts ["pageInfo"] threads
              , all validNode nodes
              , Just (Bool _) <- lookup "hasNextPage" pageMembers ->
                  pure (nodes, pageMembers)
            _ -> throwIO (boundary "GitHub review-thread evidence is malformed")
          let acc' = acc <> nodes
          case lookup "hasNextPage" page of
            Just (Bool False) -> pure acc'
            _ -> case lookup "endCursor" page of
              Just next@(String text) | not (T.null text) -> go (attempt + 1) next acc'
              _ -> throwIO (boundary "GitHub review-thread pagination is malformed")
    validNode = \case
      Object members -> case (lookup "id" members, lookup "isResolved" members) of
        (Just (String _), Just (Bool _)) -> True
        _ -> False
      _ -> False

resolveReviewThread :: Transport -> Text -> IO ()
resolveReviewThread transport threadId = do
  response <-
    transport.request
      "POST"
      "/graphql"
      (Just [("query", String resolveThreadMutation), ("variables", Object [("thread", String threadId)])])
  let refused = throwIO (boundary "GitHub did not prove review-thread resolution")
  unless (graphQLAccepted response) refused
  case subscripts ["data", "resolveReviewThread", "thread"] response.body of
    Nothing -> refused
    Just thread -> do
      identifier <- either raise pure (Py.get "id" thread)
      unless (Py.pyEqText identifier threadId) refused
      resolved <- either raise pure (Py.get "isResolved" thread)
      unless (resolved == Bool True) refused

compareAndSwapRef :: Transport -> Text -> Text -> Text -> Text -> IO ()
compareAndSwapRef transport repository ref expectedHead commit = do
  let (owner, rest) = T.breakOn "/" repository
      name = T.drop 1 rest
  when
    ( T.null rest
        || T.null owner
        || T.null name
        || T.any (== '/') name
        || not (validRef ref)
        || ".." `T.isInfixOf` ref
        || "@{" `T.isInfixOf` ref
        || not (validSha expectedHead)
        || not (validSha commit)
    )
    $ throwIO (boundary "GitHub ref compare-and-swap input is malformed")
  identity <-
    transport.request
      "POST"
      "/graphql"
      (Just [("query", String repositoryQuery), ("variables", Object [("owner", String owner), ("repository", String name)])])
  let unavailable = throwIO (boundary "GitHub repository identity is unavailable for ref compare-and-swap")
  unless (graphQLAccepted identity) unavailable
  repositoryId <- case subscripts ["data", "repository", "id"] identity.body of
    Just (String text) -> pure text
    _ -> unavailable
  let clientId =
        digest
          ( Object
              [ ("repository", String repository)
              , ("ref", String ref)
              , ("expected_head", String expectedHead)
              , ("commit", String commit)
              ]
          )
  response <-
    transport.request
      "POST"
      "/graphql"
      ( Just
          [ ("query", String updateRefsMutation)
          ,
            ( "variables"
            , Object
                [
                  ( "input"
                  , Object
                      [ ("repositoryId", String repositoryId)
                      , ("refUpdates", Array [Object [("name", String ref), ("beforeOid", String expectedHead), ("afterOid", String commit), ("force", Bool False)]])
                      , ("clientMutationId", String clientId)
                      ]
                  )
                ]
            )
          ]
      )
  let rejected = throwIO (boundary "GitHub rejected or did not prove the exact ref compare-and-swap")
  unless (graphQLAccepted response) rejected
  case subscripts ["data", "updateRefs", "clientMutationId"] response.body of
    Just observed | Py.pyEqText observed clientId -> pure ()
    _ -> rejected
  where
    validSha text = T.length text == 40 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) text
    validRef text = case T.stripPrefix "refs/heads/" text of
      Just branch -> case T.uncons branch of
        Just (first, more) -> alnum first && T.length more <= 254 && T.all (\c -> alnum c || c `elem` ['.', '_', '/', '-']) more
        Nothing -> False
      Nothing -> False
    alnum c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')


-- | Opt-in history source for @petrus_trace_import@.
--
-- Upstream's @petrus_trace_import@ sends @{source, workflowId, runId}@ to the
-- browser, whose @trace.import@ handler requires a @runtimeState@ payload
-- that the tool never supplies, so the import always fails with
-- "trace.import requires runtimeState payload". When @PETRUS_HISTORY_URL@
-- is set (a Temporal HTTP API base, e.g. @http://localhost:5173/temporal@,
-- which @petrus@ serves from Petrus observation producers), the MCP server
-- fetches the workflow's @get_state@ query exactly as the browser's
-- Temporal client does and attaches it as @runtimeState@. Without the
-- variable, or when the fetch fails, the request is sent unchanged.
module Petrus.Viewer.Mcp.History
  ( HistorySource (..)
  , historySourceFromEnv
  , fetchRuntimeState
  , decodeQueryResult
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client qualified as HC
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types qualified as H
import Network.HTTP.Types.URI (urlEncode)
import Petrus.Viewer.Json
import System.Environment (lookupEnv)

data HistorySource = HistorySource
  { historyBase :: Text
  -- ^ Temporal HTTP API base URL (no trailing slash)
  , historyNamespace :: Text
  , historyManager :: HC.Manager
  }

-- | @PETRUS_HISTORY_URL@ and @PETRUS_HISTORY_NAMESPACE@ (default
-- @"default"@).
historySourceFromEnv :: IO (Maybe HistorySource)
historySourceFromEnv = do
  url <- lookupEnv "PETRUS_HISTORY_URL"
  ns <- lookupEnv "PETRUS_HISTORY_NAMESPACE"
  case url of
    Just u
      | not (null u) -> do
          mgr <- newTlsManager
          pure
            ( Just
                HistorySource
                  { historyBase = T.dropWhileEnd (== '/') (T.pack u)
                  , historyNamespace = maybe "default" T.pack (mfilter' ns)
                  , historyManager = mgr
                  }
            )
    _ -> pure Nothing
  where
    mfilter' = \case
      Just s | not (null s) -> Just s
      _ -> Nothing

-- | POST @…/api/v1/namespaces/{ns}/workflows/{id}/query/get_state@ with an
-- empty JSON body and decode the query result.
fetchRuntimeState :: HistorySource -> Text -> IO (Either Text JsValue)
fetchRuntimeState src workflowId = do
  let url =
        historyBase src
          <> "/api/v1/namespaces/"
          <> component (historyNamespace src)
          <> "/workflows/"
          <> component workflowId
          <> "/query/get_state"
  r <- try @SomeException $ do
    req0 <- HC.parseRequest (T.unpack url)
    let req =
          req0
            { HC.method = "POST"
            , HC.requestHeaders = [("Content-Type", "application/json")]
            , HC.requestBody = HC.RequestBodyBS "{}"
            }
    resp <- HC.httpLbs req (historyManager src)
    pure (H.statusCode (HC.responseStatus resp), BL.toStrict (HC.responseBody resp))
  pure $ case r of
    Left e -> Left (T.pack (show e))
    Right (code, body)
      | code >= 200 && code < 300 -> case parseJs (decodeLenient body) of
          Left e -> Left (T.pack e)
          Right v -> decodeQueryResult v
      | otherwise -> Left ("HTTP " <> T.pack (show code) <> ": " <> TE.decodeUtf8Lenient (B.take 500 body))
  where
    component = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

-- | The viewer's @decodeQueryResult@: @queryResult@ (or @query_result@) is
-- either an array of decoded values or @{payloads: [{data: base64}]}@.
decodeQueryResult :: JsValue -> Either Text JsValue
decodeQueryResult v = case v of
  JsObj o -> case (lookupKey "queryResult" o, lookupKey "query_result" o) of
    (Just qr, _) | truthy qr -> fromResult qr
    (_, Just qr) | truthy qr -> fromResult qr
    _ -> Left "Missing queryResult in response"
  _ -> Left "Missing queryResult in response"
  where
    fromResult = \case
      JsArr [] -> Left "Empty queryResult array"
      JsArr (x : _) -> Right x
      JsObj q -> case lookupKey "payloads" q of
        Just (JsArr (JsObj p : _)) -> case lookupKey "data" p >>= asText of
          Just b64 | not (T.null b64) ->
            let raw = TE.encodeUtf8 b64
                decoded = either (const raw) id (B64.decode raw)
             in either (Left . T.pack) Right (parseJs (decodeLenient decoded))
          _ -> Left "Empty payload data"
        _ -> Left "No payloads in queryResult"
      _ -> Left "No payloads in queryResult"

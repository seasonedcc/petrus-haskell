-- | A recording fake GitHub REST API on a local port, for comparing the
-- exact provider calls the reference and the port make. Both sides point
-- their GitHub client at it (the reference through an injected httpx
-- transport, the port through 'Hamsterdan.GitHub.Http.newPlainExchangeAt').
module FakeGitHub
  ( Recorded (..)
  , Route
  , withFakeGitHub
  , takeCalls
  , comparableCall
  , registrationRoutes
  , appEvents
  , appPermissions
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.IORef
import Data.List (sortOn)
import Network.HTTP.Types (mkStatus)
import Network.Wai (rawPathInfo, rawQueryString, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp

-- | One request as the fake received it.
data Recorded = Recorded
  { method :: ByteString
  , target :: ByteString
  , headers :: [(ByteString, ByteString)]
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | A canned answer for a method and target: status, headers, body.
type Route = ByteString -> ByteString -> Maybe (Int, [(ByteString, ByteString)], ByteString)

withFakeGitHub :: Route -> (Int -> IORef [Recorded] -> IO a) -> IO a
withFakeGitHub routes action = do
  calls <- newIORef []
  let app request respond = do
        payload <- BL.toStrict <$> strictRequestBody request
        let target = rawPathInfo request <> rawQueryString request
            recorded =
              Recorded
                { method = requestMethod request
                , target
                , headers = [(CI.foldedCase name, value) | (name, value) <- requestHeaders request]
                , body = payload
                }
        atomicModifyIORef' calls (\known -> (known <> [recorded], ()))
        respond $ case routes (requestMethod request) target of
          Just (status, extra, content) ->
            responseLBS (mkStatus status "") ([("content-type", "application/json; charset=utf-8")] <> map (\(n, v) -> (CI.mk n, v)) extra) (BL.fromStrict content)
          Nothing -> responseLBS (mkStatus 404 "") [("content-type", "application/json; charset=utf-8")] "{\"message\":\"Not Found\"}"
  Warp.testWithApplication (pure app) (\port -> action port calls)

-- | The calls so far, emptying the record.
takeCalls :: IORef [Recorded] -> IO [Recorded]
takeCalls calls = atomicModifyIORef' calls ([],)

-- | A call without what legitimately differs between two clients of the
-- same fake: the @host@ (the reference still names @api.github.com@; the
-- port names the fake's address), connection management, and the
-- credential itself (only its scheme is kept: tokens and JWTs carry
-- clock-dependent signatures). Headers are sorted by name.
comparableCall :: Recorded -> Recorded
comparableCall call =
  call
    { headers =
        sortOn
          fst
          [ (name, if name == "authorization" then BS.takeWhile (/= 32) value else value)
          | (name, value) <- call.headers
          , name `notElem` ["host", "connection"]
          ]
    }

appEvents :: [ByteString]
appEvents = ["issue_comment", "pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_review_thread", "workflow_run"]

appPermissions :: ByteString
appPermissions = "{\"actions\":\"read\",\"administration\":\"read\",\"contents\":\"write\",\"issues\":\"write\",\"pull_requests\":\"write\",\"metadata\":\"read\"}"

-- | The registration evidence @validate@ reads: App 17
-- (@hamsterdan-test@, client @Iv1.test@), installation 44 for account 23
-- (@Owner@), and a two-page repository inventory (31 @owner/one@, 32
-- @owner/two@) linked by a @Link@ header.
registrationRoutes :: Route
registrationRoutes method target = case (method, target) of
  ("GET", "/app") ->
    ok
      ( "{\"id\":17,\"slug\":\"hamsterdan-test\",\"client_id\":\"Iv1.test\",\"permissions\":"
          <> appPermissions
          <> ",\"events\":["
          <> BS.intercalate "," ["\"" <> e <> "\"" | e <- appEvents]
          <> "]}"
      )
  ("GET", "/app/installations?per_page=100") ->
    ok ("[{\"id\":44,\"account\":{\"id\":23,\"login\":\"Owner\"},\"suspended_at\":null,\"permissions\":" <> appPermissions <> "}]")
  ("POST", "/app/installations/44/access_tokens") ->
    Just (201, [], "{\"token\":\"ghs_installation44\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"repository_selection\":\"selected\"}")
  ("GET", "/installation/repositories?per_page=100") ->
    Just
      ( 200
      , [("link", "<https://api.github.com/installation/repositories?per_page=100&page=2>; rel=\"next\", <https://api.github.com/installation/repositories?per_page=100&page=2>; rel=\"last\"")]
      , "{\"total_count\":2,\"repositories\":[{\"id\":31,\"full_name\":\"owner/one\"}]}"
      )
  ("GET", "/installation/repositories?per_page=100&page=2") ->
    ok "{\"total_count\":2,\"repositories\":[{\"id\":32,\"full_name\":\"owner/two\"}]}"
  _ -> Nothing
  where
    ok content = Just (200, [], content)

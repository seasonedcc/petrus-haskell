-- | Python clients against the Haskell server: the upstream test module's
-- own @request@ helper (@urllib.request@) and assertions, run by the
-- pinned upstream interpreter against this package's server, with the
-- expected views computed by an upstream Engine built the same way.
module PythonClientSpec (spec) where

import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import Support
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "Python urllib clients against the Haskell server" $ do
  it "see the views, headers and refusals the upstream tests assert, equal to an upstream Engine's" $ do
    engine <- makeEngine
    withObservation engine $ \port -> runClient live [show port]
    Engine.close engine
  it "see 503 from a closed Engine" $ do
    engine <- makeEngine
    Engine.close engine
    withObservation engine $ \port -> runClient closed [show port]

runClient :: Text -> [String] -> IO ()
runClient code args = do
  result <- runPython (prelude <> code) args ""
  case resultExit result of
    ExitSuccess -> BC.unpack (resultStdout result) `shouldBe` "ok\n"
    ExitFailure _ -> expectationFailure (BC.unpack (resultStdout result <> resultStderr result))

prelude :: Text
prelude =
  T.unlines
    [ "import json, sys"
    , "from urllib.error import HTTPError"
    , "from urllib.request import Request, urlopen"
    , "sys.path.insert(0, 'tests/petrus/engine')"
    , "from test_observation_http import make_engine, request"
    , "from petrus.engine.observation_http import MAX_HISTORY_PAGE_LIMIT"
    , "base = f'http://127.0.0.1:{sys.argv[1]}'"
    ]

live :: Text
live =
  T.unlines
    [ "engine = make_engine()"
    , "expected_snapshot = engine.snapshot()"
    , "expected_document = engine.net_document()"
    , "expected_history = engine.history_page(0, 100)"
    , "status, headers, snapshot = request(f'{base}/v1/snapshot')"
    , "assert (status, snapshot) == (200, expected_snapshot), snapshot"
    , "assert headers['Content-Type'] == 'application/json; charset=utf-8'"
    , "assert headers['Cache-Control'] == 'no-store'"
    , "assert headers['Access-Control-Allow-Origin'] == '*'"
    , "assert headers['Access-Control-Allow-Methods'] == 'GET, OPTIONS'"
    , "assert headers['Access-Control-Allow-Headers'] == 'Content-Type'"
    , "encoded = json.dumps(snapshot, allow_nan=False, separators=(',', ':'), sort_keys=True).encode()"
    , "assert int(headers['Content-Length']) == len(encoded)"
    , "assert request(f'{base}/v1/document')[::2] == (200, expected_document)"
    , "assert request(f'{base}/v1/history?after=0&limit=100')[::2] == (200, expected_history)"
    , "for query in ['', 'after=0', 'limit=1', 'after=0&after=1&limit=1', 'after=0&limit=1&extra=1', 'after=&limit=1',"
    , "              'after=+1&limit=1', 'after=%201&limit=1', 'after=-1&limit=1', 'after=1.0&limit=1',"
    , "              f'after=0&limit={MAX_HISTORY_PAGE_LIMIT + 1}', 'after=999&limit=1']:"
    , "    status, _, payload = request(f'{base}/v1/history?{query}')"
    , "    assert (status, payload['error']['code']) == (400, 'invalid_request'), (query, status, payload)"
    , "try:"
    , "    engine.history_page(999, 1)"
    , "    raise AssertionError('the upstream Engine accepted a future cursor')"
    , "except ValueError as error:"
    , "    future = str(error)"
    , "assert request(f'{base}/v1/history?after=999&limit=1')[2]['error']['message'] == future"
    , "before = engine.history_page(0, 100)"
    , "for method in ['POST', 'PUT', 'PATCH', 'DELETE']:"
    , "    status, headers, payload = request(f'{base}/v1/snapshot', method=method)"
    , "    assert (status, headers['Allow'], payload['error']['code']) == (405, 'GET, OPTIONS', 'method_not_allowed')"
    , "assert request(f'{base}/v1/history?after=0&limit=100')[2] == before"
    , "assert request(f'{base}/unknown')[0] == 404"
    , "status, headers, body = request(f'{base}/v1/snapshot', method='OPTIONS')"
    , "assert (status, body, headers['Allow']) == (204, None, 'GET, OPTIONS')"
    , "assert headers['Access-Control-Allow-Origin'] == '*'"
    , "engine.close()"
    , "print('ok')"
    ]

closed :: Text
closed =
  T.unlines
    [ "status, _, payload = request(f'{base}/v1/snapshot')"
    , "assert (status, payload) == (503, {'error': {'code': 'engine_unavailable', 'message': 'Engine is unavailable'}}), payload"
    , "print('ok')"
    ]

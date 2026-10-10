-- | End to end: the viewer backend (@petrus --observation <url>@ from
-- petrus-viewer-server) replays History from this package's server, and
-- answers exactly as it does when pointed at the upstream server.
module ViewerSpec (spec) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (isInfixOf)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.TestSupport.Python (readLine, withPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.IO (hGetLine)
import System.Process.Typed
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "petrus --observation (the viewer backend)" $
  it "lists the Instance and answers get_state and get_schema as it does for the upstream server" $ do
    engine <- makeEngine
    _ <- Engine.advance engine
    withObservation engine $ \haskell -> do
      ours <- withViewer haskell viewerQueries
      root <- repoRoot
      script <- T.pack <$> readFile (root <> "/packages/petrus-observation-http/test/reference_observation.py")
      theirs <- withPython script ["advanced"] $ \process -> do
        python <- read . BC.unpack <$> readLine process
        withViewer python viewerQueries
      let (list, state, schema, missing) = ours
      replyStatus list `shouldBe` 200
      executions (replyBody list) `shouldBe` Just ["http-instance"]
      replyStatus state `shouldBe` 200
      (json (replyBody state) >>= lookupMember "queryResult") `shouldSatisfy` \case
        Just (Array [Object _]) -> True
        _ -> False
      replyStatus schema `shouldBe` 200
      (json (replyBody schema) >>= lookupMember "queryResult") `shouldSatisfy` \case
        Just (Array [s]) -> lookupMember "net" s == Just (String "http-observation")
        _ -> False
      replyStatus missing `shouldNotBe` 200
      let same (Reply s1 _ b1) (Reply s2 _ b2) = (s1, json b1) == (s2, json b2)
          (list', state', schema', missing') = theirs
      [same list list', same state state', same schema schema', same missing missing'] `shouldBe` [True, True, True, True]
    Engine.close engine
  where
    json = either (const Nothing) Just . parseJson pythonLoads
    executions body = case json body >>= lookupMember "executions" of
      Just (Array items) -> Just [w | item <- items, Just (String w) <- [lookupMember "execution" item >>= lookupMember "workflowId"]]
      _ -> Nothing

-- The list, get_state, get_schema and an unknown workflow.
viewerQueries :: Int -> IO (Reply, Reply, Reply, Reply)
viewerQueries port = do
  let base = "/temporal/api/v1/namespaces/default/workflows"
  list <- requestWith port ("GET " <> base <> " HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
  state <- post port (base <> "/http-instance/query/get_state")
  schema <- post port (base <> "/http-instance/query/get_schema")
  missing <- post port (base <> "/nope/query/get_state")
  pure (list, state, schema, missing)

post :: Int -> ByteString -> IO Reply
post port target =
  requestWith port ("POST " <> target <> " HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")

-- | Run @petrus --no-open --strict-port --port 0 --host 127.0.0.1
-- --observation http://127.0.0.1:PORT@ for the duration of an action,
-- which receives the viewer's port; the process is terminated afterwards.
withViewer :: Int -> (Int -> IO x) -> IO x
withViewer observationPort action = do
  exe <- viewerExecutable
  let args = ["--no-open", "--strict-port", "--port", "0", "--host", "127.0.0.1", "--observation", "http://127.0.0.1:" <> show observationPort]
      config = setStdin nullStream (setStdout createPipe (setStderr inherit (proc exe args)))
  withProcessTerm config $ \process -> do
    let awaitPort = do
          line <- hGetLine (getStdout process)
          case BS.breakSubstring "http://localhost:" (BC.pack line) of
            (_, rest)
              | not (BS.null rest) -> pure (read (BC.unpack (BC.takeWhile (/= '/') (BS.drop (BS.length "http://localhost:") rest))))
              | otherwise -> awaitPort
    found <- timeout 30000000 awaitPort
    case found of
      Just port -> action port
      Nothing -> throwIO (userError "petrus did not report its port within 30 s")

-- | The petrus-viewer-server @petrus@ executable: @PETRUS_VIEWER_EXE@, or
-- the build tool cabal puts on the test's @PATH@
-- (@build-tool-depends: petrus-viewer-server:petrus@).
viewerExecutable :: IO FilePath
viewerExecutable = do
  override <- lookupEnv "PETRUS_VIEWER_EXE"
  case override of
    Just path | not (null path) -> pure path
    _ -> do
      found <- findExecutable "petrus"
      case found of
        Just path | "petrus-viewer-server" `isInfixOf` path -> pure path
        _ ->
          throwIO . userError $
            "petrus-viewer-server's petrus executable is not on PATH (found "
              <> show found
              <> "); run the suite with `cabal test petrus-observation-http` or set PETRUS_VIEWER_EXE"

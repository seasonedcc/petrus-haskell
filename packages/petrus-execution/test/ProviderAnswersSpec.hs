{-# LANGUAGE RecordWildCards #-}

-- | What each side makes of a provider's answer, against the pinned
-- reference (@test/interop/provider_answers.py@).
--
-- Docker: @lookup@ over a @docker@ that answers @ps@ and @inspect@ with
-- the case's bytes (malformed or undecodable JSON, values of the wrong
-- type, CRLF, a failing status). Gondolin: @_request@ over a Unix socket
-- that answers the case's frame (error values of every JSON type, frames
-- that are not JSON or not UTF-8), and @_read@ of registry files that do
-- not decode. Each must give the same value, or raise the same class with
-- the same text.
module ProviderAnswersSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Exception (bracket, finally, try)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket (Family (AF_UNIX), SockAddr (SockAddrUnix), Socket, SocketType (Stream), accept, bind, close, defaultProtocol, listen, socket)
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Json (Json (..), lookupMember)
import Petrus.Json.Python (loadsBytes)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Providers.Docker (DockerConfig (..), defaultDockerConfig, dockerProvider, newDockerEnvironmentWith)
import Petrus.Motus.Execution.Providers.Gondolin (Identity (..), Registry (..), gondolinConfig, newGondolinEnvironment, readRegistry, sidecarRequest)
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
import System.Directory (createDirectory, makeAbsolute, removeDirectoryRecursive)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Temp (mkdtemp)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | A value, or the raised class (the reference: every class of its MRO)
-- and @str(e)@.
data Outcome
  = Value Json
  | Raised [Text] Json
  deriving stock (Show)

-- | The port raised one of the reference's classes, with its text.
matches :: Outcome -> Outcome -> Bool
matches (Value port) (Value expected) = canonical port == canonical expected
matches (Raised [kind] port) (Raised classes expected) = kind `elem` classes && port == expected
matches _ _ = False

-- | Objects with sorted keys (the reference prints @sort_keys=True@).
canonical :: Json -> Json
canonical = \case
  Object members -> Object (sortOn fst [(key, canonical value) | (key, value) <- members])
  Array items -> Array (map canonical items)
  other -> other

portOutcome :: IO Json -> IO Outcome
portOutcome action =
  try action >>= \case
    Right value -> pure (Value value)
    Left (failure :: ExecutionError) -> pure (Raised [kindName (errorKind failure)] (String (errorMessage failure)))
  where
    kindName = \case
      OtherError name -> name
      kind -> T.pack (show kind)

reference :: [(String, String)] -> String -> String -> IO Outcome
reference environment command argument = do
  python <- pythonExecutable
  script <- makeAbsolute ("test" </> "interop" </> "provider_answers.py")
  root <- upstreamPetrus
  (code, out, err) <- readCreateProcessWithExitCode (proc python ["-I", script, command, argument]) {cwd = Just root, env = Just environment} ""
  unless (code == ExitSuccess) $ expectationFailure ("reference " <> command <> " exited with " <> show code <> ":\n" <> err)
  case loadsBytes (BC.pack out) of
    Right answer@(Object [(key, value)])
      | key /= "raised" -> pure (Value value)
      | otherwise -> error ("unexpected reference answer " <> show answer)
    Right answer -> case (lookupMember "raised" answer, lookupMember "message" answer) of
      (Just (Array classes), Just message) -> pure (Raised [name | String name <- classes] message)
      _ -> error ("unexpected reference answer " <> show answer)
    Left problem -> error ("reference printed " <> show out <> ": " <> show problem)

-- | A short private directory (a Unix socket path must fit in 104 bytes).
withShortDirectory :: (FilePath -> IO a) -> IO a
withShortDirectory = bracket (mkdtemp "/tmp/petrus-answers-") removeDirectoryRecursive

-- ---------------------------------------------------------------------------
-- Docker

-- | @ps@'s stdout, @inspect@'s stdout, stderr and status.
data DockerCase = DockerCase
  { dockerName :: String
  , psOut :: ByteString
  , inspectOut :: ByteString
  , inspectErr :: ByteString
  , inspectStatus :: Int
  }

dockerCase :: String -> ByteString -> DockerCase
dockerCase name inspected = DockerCase name "c1\n" inspected "" 0

running :: ByteString
running = "[{\"Mounts\": [], \"State\": {\"Running\": true}}]"

dockerCases :: [DockerCase]
dockerCases =
  [ (dockerCase "no container" running) {psOut = ""}
  , (dockerCase "two containers" running) {psOut = "c1\nc2\n"}
  , (dockerCase "a container between Unicode spaces" running) {psOut = "\xe2\x80\x83\&c1\xe2\x80\x83\n"}
  , (dockerCase "ps output that is not UTF-8" running) {psOut = "c\xff\n"}
  , dockerCase "a running container" running
  , dockerCase "CRLF line ends" (running <> "\r\n")
  , dockerCase "malformed JSON" "[{\"Mounts\": ]"
  , dockerCase "malformed JSON after a CR" "[\r{\"Mounts\" []}]"
  , dockerCase "empty output" ""
  , dockerCase "output that is not UTF-8" "[\xff]"
  , dockerCase "a UTF-8 BOM" ("\xef\xbb\xbf" <> running)
  , dockerCase "an empty list" "[]"
  , dockerCase "an object" "{}"
  , dockerCase "a string" "\"abc\""
  , dockerCase "an empty string" "\"\""
  , dockerCase "a lone surrogate" "\"\\ud800\""
  , dockerCase "a number" "[1]"
  , dockerCase "NaN" "NaN"
  , dockerCase "null" "null"
  , dockerCase "no Mounts" "[{}]"
  , dockerCase "null Mounts" "[{\"Mounts\": null}]"
  , dockerCase "Mounts as an object" "[{\"Mounts\": {\"Type\": \"bind\"}}]"
  , dockerCase "a mount that is a list" "[{\"Mounts\": [[]]}]"
  , dockerCase "a bind mount after a volume" "[{\"Mounts\": [{\"Type\": \"volume\"}, {\"Type\": \"bind\"}]}]"
  , dockerCase "a bind mount before a malformed one" "[{\"Mounts\": [{\"Type\": \"bind\"}, 3]}]"
  , dockerCase "State as a list" "[{\"Mounts\": [], \"State\": []}]"
  , dockerCase "no Running" "[{\"Mounts\": [], \"State\": {}}]"
  , dockerCase "Running 0" "[{\"Mounts\": [], \"State\": {\"Running\": 0}}]"
  , dockerCase "Running as text" "[{\"Mounts\": [], \"State\": {\"Running\": \"no\"}}]"
  , dockerCase "Running as an empty object" "[{\"Mounts\": [], \"State\": {\"Running\": {}}}]"
  , (dockerCase "a failing inspect" "") {inspectStatus = 1}
  , (dockerCase "a failing inspect with undecodable output" "\xff") {inspectStatus = 1}
  , (dockerCase "stderr that is not UTF-8" running) {inspectErr = "warning \xc3\n"}
  , (dockerCase "both streams undecodable" "[\xe9]") {inspectErr = "\xff"}
  ]

-- | A @docker@ that prints the case's files.
writeDocker :: FilePath -> FilePath -> IO ()
writeDocker executable answers = do
  B.writeFile executable $
    BC.pack $
      unlines
        [ "#!/bin/sh"
        , "case \"$1\" in"
        , "  ps) cat '" <> answers </> "ps" <> "' ;;"
        , "  inspect) cat '" <> answers </> "inspect" <> "'; cat '" <> answers </> "stderr" <> "' >&2; exit \"$(cat '" <> answers </> "status" <> "')\" ;;"
        , "  *) exit 64 ;;"
        , "esac"
        ]
  setFileMode executable 0o755

dockerSpec :: Spec
dockerSpec = describe "Docker lookup reads docker's answers as the reference does" $
  forM_ dockerCases $ \DockerCase {..} -> it dockerName $ withShortDirectory $ \directory -> do
    let bin = directory </> "bin"
        answers = directory </> "answers"
    mapM_ createDirectory [bin, answers]
    writeDocker (bin </> "docker") answers
    B.writeFile (answers </> "ps") psOut
    B.writeFile (answers </> "inspect") inspectOut
    B.writeFile (answers </> "stderr") inspectErr
    writeFile (answers </> "status") (show inspectStatus)
    inherited <- getEnvironment
    let path = maybe bin ((bin <> ":") <>) (lookup "PATH" inherited)
    expected <- reference (("PATH", path) : [entry | entry@(key, _) <- inherited, key /= "PATH"]) "docker" "op-1"
    env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = bin </> "docker"}
    got <- portOutcome (leaseAnswer <$> providerLookup (dockerProvider env) "op-1")
    unless (matches got expected) $ expectationFailure ("port: " <> show got <> "\nreference: " <> show expected)
  where
    leaseAnswer = maybe Null (\lease -> Array [String (leaseId lease), String (leaseStateText (leaseState lease))])

-- ---------------------------------------------------------------------------
-- Gondolin

frames :: [(String, ByteString)]
frames =
  [ ("an ok response", "{\"ok\": true, \"x\": [1, 2.5]}\n")
  , ("an ok response with CRLF", "{\"ok\": 1}\r\n")
  , ("an error text", "{\"ok\": false, \"error\": \"boom\"}\n")
  , ("an error object", "{\"ok\": false, \"error\": {\"a\": [1, 2.5, null, true, \"it's\"]}}\n")
  , ("an error null", "{\"ok\": false, \"error\": null}\n")
  , ("an error number", "{\"ok\": 0, \"error\": -0.0}\n")
  , ("an error infinity", "{\"ok\": false, \"error\": 1e400}\n")
  , ("an error list", "{\"ok\": [], \"error\": [\"x\", false]}\n")
  , ("an error with a lone surrogate", "{\"ok\": false, \"error\": \"\\udc80!\"}\n")
  , ("no error", "{\"ok\": false}\n")
  , ("a list", "[1]\n")
  , ("a string", "\"ok\"\n")
  , ("malformed JSON", "{\"ok\": tru}\n")
  , ("an empty line", "\n")
  , ("bytes that are not UTF-8", "{\"ok\": \"\xff\"}\n")
  , ("a UTF-8 BOM", "\xef\xbb\xbf{\"ok\": true}\n")
  , ("no line end before the close", "{\"ok\": true}")
  ]

-- | Answer one connection: read the request line, send the frame, close.
serveOnce :: Socket -> ByteString -> IO ()
serveOnce listener frame = do
  (connection, _) <- accept listener
  let request received = do
        chunk <- recv connection 65536
        unless (B.null chunk || BC.elem '\n' (received <> chunk)) (request (received <> chunk))
  (request "" >> sendAll connection frame) `finally` close connection

withSidecar :: FilePath -> ByteString -> IO a -> IO a
withSidecar path frame action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 2
    _ <- forkIO (serveOnce listener frame >> serveOnce listener frame)
    action

record :: FilePath -> Registry
record path =
  Registry
    { registryOperationId = "op-1"
    , registryLeaseId = "lease"
    , registrySpecFingerprint = ""
    , registryBootToken = "token"
    , registryPid = 0
    , registryPgid = 0
    , registryStartIdentity = Identity "missing" Nothing Nothing
    , registrySocket = T.pack path
    , registryRuntime = ""
    , registryWorkspace = ""
    , registrySdkModule = ""
    , registrySdkVersion = ""
    , registryImage = ""
    , registryGroupIdentities = Nothing
    , registryPrivateFileTransfer = False
    }

registries :: [(String, ByteString)]
registries =
  [ ("malformed JSON", "{\"lease_id\": }")
  , ("malformed JSON after CRLF", "{\r\n\"lease_id\" 1}")
  , ("malformed JSON after a CR", "{\r\r\"lease_id\": [}")
  , ("an empty file", "")
  , ("bytes that are not UTF-8", "{\"lease_id\": \"\xc3(\"}")
  , ("a truncated sequence", "{\"lease_id\": \"\xe2\x82")
  , ("a UTF-8 BOM", "\xef\xbb\xbf{}")
  , ("a control character in a string", "{\"lease_id\": \"a\rb\"}")
  ]

gondolinSpec :: Spec
gondolinSpec = do
  describe "Gondolin sidecar requests read the answer as the reference does" $
    forM_ frames $ \(name, frame) -> it name $ withShortDirectory $ \directory -> do
      let path = directory </> "s"
      withSidecar path frame $ do
        inherited <- getEnvironment
        expected <- reference inherited "request" path
        env <- newGondolinEnvironment (directory </> "root") (gondolinConfig "sdk.mjs")
        got <- portOutcome (sidecarRequest env (record path) [("action", String "status")] 2)
        unless (matches got expected) $ expectationFailure ("port: " <> show got <> "\nreference: " <> show expected)
  describe "Gondolin registries that do not decode fail as the reference's do" $ do
    forM_ registries $ \(name, contents) -> it name $ withShortDirectory $ \directory -> do
      B.writeFile (directory </> "registry.json") contents
      inherited <- getEnvironment
      expected <- reference inherited "read" directory
      got <- portOutcome (maybe Null (const (String "a registry")) <$> readRegistry directory)
      unless (matches got expected) $ expectationFailure ("port: " <> show got <> "\nreference: " <> show expected)
    it "a missing registry" $ withShortDirectory $ \directory -> do
      inherited <- getEnvironment
      expected <- reference inherited "read" directory
      got <- portOutcome (maybe Null (const (String "a registry")) <$> readRegistry directory)
      unless (matches got expected) $ expectationFailure ("port: " <> show got <> "\nreference: " <> show expected)

spec :: Spec
spec = describe "ProviderAnswers" $ do
  dockerSpec
  gondolinSpec

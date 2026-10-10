-- | Cross-implementation evidence for the ZeroMQ Dispatch transport, both
-- directions, against the pinned reference (@upstream/petrus@):
--
-- * the reference's synchronous client and native asynchronous access
--   drive this server (IPC, and CURVE TCP with certificates this package
--   wrote);
-- * this package's clients drive the reference's server module (IPC, and
--   CURVE TCP with certificates @zmq.auth@ wrote);
-- * a corpus of raw requests (malformed JSON, widened and narrowed
--   envelopes, refused custody, mis-typed failures) is answered
--   byte-for-byte alike by both servers.
--
-- The process-death and redelivery cases of the transport spec also run
-- against the reference's server.
module Petrus.Motus.Transport.ZeroMQ.InteropSpec (spec) where

import Control.Exception (bracket, finally)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity hiding (invocation)
import Data.Map.Strict qualified as Map
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityAttempt (..), ActivityOutcome (..), AttemptFailure (..), activityAttempt)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Transport.ZeroMQ
  ( ClientOptions (..)
  , defaultClientOptions
  , localServer
  , newAsyncZeroMQWorkerAccess
  , newZeroMQWorkerDispatch
  )
import Petrus.Motus.Transport.ZeroMQ qualified as Z
import Petrus.Motus.Transport.ZeroMQ.Support
import Petrus.Motus.Transport.ZeroMQ.Wire (encodeAttempt)
import Petrus.Motus.Worker qualified as W
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec hiding (context)

-- | The driver's @scenario_call()@.
scenarioCall :: ActivityInvocation
scenarioCall =
  ActivityInvocation
    { activity = "work"
    , input =
        obj
          [ ("nested", Array [Int 1, obj [("faithful", Bool True)]])
          , ("text", String "caf\233 \9731")
          , ("float", Float 1.5)
          ]
    , policy =
        policyOf
          (policyFields defaultExecutionPolicy)
            { attempts = 3
            , heartbeatTimeout = 4
            , initialInterval = 5
            , coefficient = 3
            , maxInterval = 20
            , startToClose = Just 40
            , scheduleToClose = Just 90
            }
    , correlation = Just "correlation"
    , idempotency = Just "idempotency"
    }

invalid :: ActivityFailure
invalid = failureOf (ActivityFailureFields "invalid" "InvalidRequest" (obj [("field", String "name")]) False (Just 7))

firstResult :: Json
firstResult = obj [("completed", Array [Bool True]), ("text", String "\9731")]

-- | The outcomes either direction's scenario leaves behind: occurrence 4
-- failed retryably with attempts to spare, so it waits out its backoff
-- (5 s) instead of settling — which is also why the last claims find
-- nothing.
expectedOutcomes :: [(Int, ActivityOutcome)]
expectedOutcomes =
  [ (1, Succeeded firstResult)
  , (2, Failed invalid)
  , (3, Succeeded (obj [("async", Bool True)]))
  ]

prepare :: FilePath -> IO Local.LocalDispatch
prepare path = do
  dispatch <- localDispatch path "interop" [("work", "cpu")]
  forM_ [1 .. 4] $ \occurrence -> Local.dispatch dispatch occurrence scenarioCall
  pure dispatch

at :: [Text] -> Json -> Json
at path v = foldl (\current key -> member key current) v path
  where
    member key = \case
      Object members -> maybe Null id (lookup key members)
      _ -> Null

spec :: Spec
spec = do
  describe "the reference's clients against this server" $
    forM_ [False, True] $ \curve ->
      it (if curve then "CURVE TCP, certificates written here" else "IPC") $ withReference $ \python -> withScratch $ \tmp -> do
        let path = tmp </> "dispatch.sqlite3"
        dispatch <- prepare path
        certificates <- if curve then Just <$> curveCertificates tmp else pure Nothing
        let make = case certificates of
              Just c -> localServer "tcp://127.0.0.1:*" path ["cpu", "io"] (Just c.serverSecret) (Just c.allowed)
              Nothing -> localServer (ipcEndpoint tmp "dispatch.sock") path ["cpu", "io"] Nothing Nothing
        withRunning make $ \running -> do
          report <-
            runInterop python $
              ["client", T.unpack running.endpoint]
                ++ maybe ["-", "-"] (\c -> [c.clientSecret, c.serverPublic]) certificates
          at ["first", "invocation_equal"] report `shouldBe` Bool True
          at ["first", "queue"] report `shouldBe` String "cpu"
          at ["first", "instance"] report `shouldBe` String "interop"
          at ["first", "epoch"] report `shouldBe` String "1"
          at ["first", "claimant"] report `shouldSatisfy` isText
          at ["heartbeats"] report
            `shouldBe` Array [progress, progress, Null]
          at ["stale", "type"] report `shouldBe` String "ValueError"
          at ["stale", "message"] report `shouldSatisfy` textMatching "stale Activity attempt"
          at ["conflict", "type"] report `shouldBe` String "ValueError"
          at ["conflict", "message"] report `shouldSatisfy` textMatching "conflicting terminal report"
          at ["second", "invocation_equal"] report `shouldBe` Bool True
          at ["native", "third", "invocation_equal"] report `shouldBe` Bool True
          at ["native", "heartbeat"] report `shouldBe` obj [("cursor", Int 1)]
          at ["native", "fourth", "queue"] report `shouldBe` String "cpu"
          at ["native", "empty"] report `shouldBe` Bool True
          at ["drained"] report `shouldBe` Bool True
          unless (null certificates) $ do
            at ["stranger", "type"] report `shouldBe` String "ConnectionError"
            at ["stranger", "message"] report `shouldBe` String "ZeroMQ Dispatch request 'claim' was not acknowledged"
          Local.collect dispatch `shouldReturn` expectedOutcomes

  describe "this package's clients against the reference's server" $
    forM_ [False, True] $ \curve ->
      it (if curve then "CURVE TCP, certificates written by zmq.auth" else "IPC") $ withReference $ \python -> withScratch $ \tmp -> do
        let path = tmp </> "dispatch.sqlite3"
        dispatch <- prepare path
        certificates <-
          if curve
            then Just <$> runInterop python ["certs", tmp]
            else pure Nothing
        let file key = maybe "" (\c -> case at [key] c of String p -> T.unpack p; _ -> "") certificates
            bind = if curve then "tcp://127.0.0.1:*" else T.unpack (ipcEndpoint tmp "dispatch.sock")
            arguments =
              ["--path", path, "--bind", bind, "--queue", "cpu", "--queue", "io", "--drain-timeout", "0.1"]
                ++ if curve then ["--server-secret-certificate", file "server_secret", "--allowed-client-keys", file "allowed"] else []
        server <- startServerProcess (Right python) arguments
        let endpoint = case at ["endpoint"] server.readiness of
              String e -> e
              _ -> error "no endpoint"
            keyed secret o =
              if curve then o {clientSecretCertificate = Just (file secret), serverPublicCertificate = Just (file "server_public")} else o
            options = keyed "client_secret" defaultClientOptions {queues = ["cpu"], workerId = Just "haskell-remote", requestTimeout = 2}
        ( do
            bracket (newZeroMQWorkerDispatch endpoint options) Z.close $ \client -> do
              first <- Z.claim client >>= requireAttempt
              first.invocation `shouldBe` scenarioCall
              first.queue `shouldBe` "cpu"
              first.instance' `shouldBe` Just "interop"
              first.epoch `shouldBe` "1"
              Z.heartbeat client first (Just progress) `shouldReturn` progress
              Z.heartbeat client first Nothing `shouldReturn` progress
              Z.heartbeat client first (Just Null) `shouldReturn` Null
              Z.complete client first firstResult
              Z.complete client first firstResult
              Z.heartbeat client first Nothing `shouldThrow` valueErrorMatching "stale Activity attempt"
              Z.complete client first (obj [("completed", Array [Bool False])])
                `shouldThrow` valueErrorMatching "conflicting terminal report"
              second <- Z.claim client >>= requireAttempt
              second.invocation `shouldBe` scenarioCall
              Z.fail client second (FailureClassified invalid)
              access <- newAsyncZeroMQWorkerAccess endpoint options {workerId = Just "haskell-async"}
              let port = Z.toWorkerAccess access
              ( do
                  third <- port.claim 0 >>= requireAttempt
                  port.heartbeat 0 third (Just (obj [("cursor", Int 1)])) `shouldReturn` obj [("cursor", Int 1)]
                  port.complete 0 third (obj [("async", Bool True)])
                  fourth <- port.claim 0 >>= requireAttempt
                  port.fail 0 fourth (FailureMessage "boom")
                  port.claim 0 >>= (`shouldSatisfy` null)
                )
                `finally` Z.closeAccess access
              Z.claim client >>= (`shouldSatisfy` null)
            unlessNull certificates $
              bracket (newZeroMQWorkerDispatch endpoint (keyed "stranger_secret" options) {requestTimeout = 0.2}) Z.close $ \stranger ->
                Z.claim stranger `shouldThrow` notAcknowledged "claim"
            Local.collect dispatch `shouldReturn` expectedOutcomes
          )
          `finally` (stopServerProcess server.handle >>= (`shouldBe` ExitSuccess))

  it "both servers answer a raw request corpus byte for byte alike" $ withReference $ \python -> withScratch $ \tmp -> do
    let ours = ipcEndpoint tmp "ours.sock"
        theirs = ipcEndpoint tmp "theirs.sock"
    reference <-
      startServerProcess (Right python) ["--path", tmp </> "theirs.sqlite3", "--bind", T.unpack theirs, "--queue", "default", "--drain-timeout", "0.1"]
    ( withRunning (localServer ours (tmp </> "ours.sqlite3") ["default"] Nothing Nothing) $ \_ -> do
        expected <- withRawDealer theirs $ \exchange -> forM corpus exchange
        actual <- withRawDealer ours $ \exchange -> forM corpus exchange
        forM_ (zip3 corpus expected actual) $ \(request, reply, ours') ->
          (request, ours') `shouldBe` (request, reply)
        -- The corpus reaches every answer class, not just the parser.
        let outcome frames = case frames of
              [frame] | Right v <- parseJson pythonLoads frame -> case (at ["ok"] v, at ["error", "kind"] v) of
                (Bool True, _) -> "ok"
                (_, String kind) -> kind
                _ -> "?"
              _ -> "?"
        Map.toList (Map.fromListWith (+) [(outcome reply, 1 :: Int) | reply <- expected])
          `shouldBe` [("ok", 2), ("protocol", 70), ("refused", 7), ("service", 1)]
      )
      `finally` (stopServerProcess reference.handle >>= (`shouldBe` ExitSuccess))

  -- The server CLI under the reference's program name: help and usage
  -- errors byte for byte (exit 2); a refused configuration exits 1 with
  -- the last line of the reference's traceback (DIVERGENCES.md 6).
  describe "the server CLI answers as python -m petrus.motus.transport.zeromq" $ do
    let both python arguments = do
          self <- getExecutablePath
          environment <- getEnvironment
          let ours = (proc self arguments) {env = Just ((serverModeVariable, "server") : filter ((/= serverModeVariable) . fst) environment)}
              theirs = (proc (fst python) ("-m" : "petrus.motus.transport.zeromq" : arguments)) {cwd = Just (snd python)}
          (,) <$> readCreateProcessWithExitCode ours "" <*> readCreateProcessWithExitCode theirs ""
        same arguments = withReference $ \python -> do
          (ours, theirs) <- both python arguments
          ours `shouldBe` theirs
    it "help" $ same ["--help"]
    it "missing required options" $ same []
    it "an invalid float" $ same ["--path", "x.db", "--bind", "ipc:///tmp/x", "--drain-timeout", "soon"]
    it "an unrecognized argument" $ same ["--path", "x.db", "--bind", "ipc:///tmp/x", "--bogus"]
    it "an ambiguous or abbreviated option" $ same ["--pa", "x.db", "--bi"]
    it "a refused configuration exits 1 with the same final line" $ withReference $ \python -> withScratch $ \tmp -> do
      let arguments = ["--path", tmp </> "d.sqlite3", "--bind", "tcp://127.0.0.1:0"]
      ((ourCode, ourOut, ourErr), (theirCode, theirOut, theirErr)) <- both python arguments
      (ourCode, ourOut, lastLine ourErr) `shouldBe` (theirCode, theirOut, lastLine theirErr)
      ourCode `shouldBe` ExitFailure 1
  where
    lastLine = reverse . takeWhile (/= '\n') . dropWhile (== '\n') . reverse
    progress = obj [("progress", Array [Int 1, Int 2]), ("note", String "\233")]
    isText = \case
      String _ -> True
      _ -> False
    textMatching fragment = \case
      String m -> matches fragment m
      _ -> False
    requireAttempt = maybe (expectationFailure "expected an Attempt" >> error "unreachable") pure
    unlessNull m action = maybe (pure ()) (const action) m

-- | Requests whose answers involve no generated identity: every protocol
-- refusal the parser and envelope checks produce, custody refusals for a
-- fabricated Attempt, and claims with no work.
corpus :: [[ByteString]]
corpus =
  map pure raw
    ++ map (pure . encoded) envelopes
    ++ [[encoded (Object base), "extra"], ["{}", ""]]
  where
    raw =
      [ ""
      , "\xff"
      , "\xc3\x28"
      , "\xef\xbb\xbf{}"
      , "{"
      , "{\"a\""
      , "{\"a\":"
      , "{\"a\":1,}"
      , "[1,]"
      , "[1 2]"
      , "nul"
      , "tru"
      , "01"
      , "1.e5"
      , "-"
      , "\"\\x\""
      , "\"\\u12\""
      , "\"abc"
      , "\"a\tb\""
      , "{} x"
      , "[]"
      , "1"
      , "NaN"
      , "null"
      , "\"text\""
      , "{\"version\":2}"
      , "{\"version\":2,\"version\":2}"
      , BC.pack ("{\"version\":" <> replicate 5000 '1' <> "}")
      ]
    envelopes =
      [ Object (base ++ [("extra", Bool True)])
      , with "version" (Int 1)
      , with "version" (Bool True)
      , with "version" (Float 2.0)
      , with "version" (String "2")
      , with "version" Null
      , with "request_id" (Int 5)
      , with "request_id" (String "")
      , with "request_id" (String (T.replicate 300 "r"))
      , with "client_id" (String "")
      , with "client_id" (Array [])
      , with "worker_id" (String "")
      , with "worker_id" (String "w\0")
      , with "queues" (Array [])
      , with "queues" (String "default")
      , with "queues" (Array [Int 1])
      , with "queues" (Array [String "default", String "default"])
      , with "queues" (Array [String "admin"])
      , with "queues" (Array [String (T.pack (show n)) | n <- [1 .. 33 :: Int]])
      , with "operation" (String (T.replicate 300 "x"))
      , with "operation" (String "wait")
      , with "operation" (Int 1)
      , Object base
      , Object (base ++ [("attempt", Null)])
      , operation "heartbeat" []
      , operation "heartbeat" [("attempt", Null)]
      , operation "heartbeat" [("attempt", Object [])]
      , operation "heartbeat" [("attempt", fabricated)]
      , operation "heartbeat" [("attempt", fabricated), ("details", Object [("x", Int 1)])]
      , operation "heartbeat" [("attempt", fabricated), ("details", Float (0 / 0))]
      , operation "heartbeat" [("attempt", fabricated), ("extra", Null)]
      , operation "complete" [("attempt", fabricated)]
      , operation "complete" [("attempt", fabricated), ("result", Object [("ok", Bool True)])]
      , operation "fail" [("attempt", fabricated), ("failure", String "boom")]
      , operation "fail" [("attempt", fabricated), ("failure", Object [])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("retryable", Int 1)])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("type", String "other")])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("error", Int 5)])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("error", String "")])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("kind", Null)])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("retry_after", String "soon")])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("retry_after", Int (-1))])]
      , operation "fail" [("attempt", fabricated), ("failure", failure [("details", Float (1 / 0))])]
      , operation "complete" [("attempt", fabricated), ("result", Float (1 / 0))]
      , operation "complete" [("attempt", replaceIn fabricated "latest_details" (Float (0 / 0))), ("result", Null)]
      , operation "complete" [("attempt", replaceIn fabricated "instance" (String "")), ("result", Null)]
      , operation "complete" [("attempt", replaceIn fabricated "attempt_id" (String "")), ("result", Null)]
      , operation "complete" [("attempt", replaceIn fabricated "epoch" (Int 1)), ("result", Null)]
      , operation "complete" [("attempt", replaceIn fabricated "invocation" (Object [])), ("result", Null)]
      ]
    base =
      [ ("version", Int 2)
      , ("request_id", String "request")
      , ("client_id", String "client")
      , ("worker_id", String "worker")
      , ("queues", Array [String "default"])
      , ("operation", String "claim")
      ]
    with key v = Object [(k, if k == key then v else x) | (k, x) <- base]
    operation name fields = Object ([(k, if k == "operation" then String name else x) | (k, x) <- base] ++ fields)
    fabricated =
      encodeAttempt
        ( either (error . T.unpack) id $
            activityAttempt "[\"interop\", 1]" "1" "worker" "default" invocation Null (Just "interop")
        )
    failure changes =
      replaceAll changes $
        Object
          [ ("type", String "activity_failure")
          , ("error", String "boom")
          , ("kind", String "Boom")
          , ("details", Null)
          , ("retryable", Bool True)
          , ("retry_after", Null)
          ]
    replaceAll changes v = foldl (\current (key, new) -> replaceIn current key new) v changes
    replaceIn v key new = case v of
      Object members -> Object [(k, if k == key then new else x) | (k, x) <- members]
      other -> other

encoded :: Json -> ByteString
encoded v = case dumps defaultDumps v of
  Right bytes -> bytes
  Left _ -> BS.empty

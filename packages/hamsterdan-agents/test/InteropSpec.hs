-- | On-disk interop with the reference agent stores, both ways.
--
-- The reference side is @differential/agents_reference.py@ under the
-- pinned upstream Python. Two stores cross the language boundary:
--
-- * the sealed connection keys of @pi-a2/keys@ (@PersistentKeyOperations@):
--   state sealed by one implementation opens in the other, over a key file
--   either one created, and a wrong context is refused the same way;
-- * the agent route database (@agent-routes.sqlite3@): a journey of claims
--   and settlements runs in two phases, each phase in either language, and
--   every pairing reports the same routes and leaves the same database
--   (schema text and rows, as the reference reads it back);
-- * the Instance Histories route repair reads: byte-for-byte the same
--   files give the same terminal operations or the same refusal.
module InteropSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM_, unless)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Host.Agenticus
import Hamsterdan.Host.PiA2 (persistentKeyOperations)
import Petrus.Agenticus.Catalog.Resolution (snapshotToData)
import Petrus.Agenticus.Connection.Key (KeyOperations (..), ScrubbedBytes, mkKeyContext)
import Petrus.Agenticus.Error (AgenticusError (..), errorClassName, throwLeft)
import Petrus.Json (EncodeOptions (..), Json (..), compact, defaultDumps, dumpsText, parseJson, surrogateRefusingLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Hamsterdan.Python.Exception (PythonException (..), pythonExceptionStr)
import System.Posix.Files (createSymbolicLink, fileMode, fileSize, getFileStatus, setFileMode)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "agents-interop"

-- | One reference command; its JSON document.
reference :: [String] -> String -> IO Json
reference arguments input = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-agents" </> "differential" </> "agents_reference.py"
  (_, out, err) <- readCreateProcessWithExitCode (proc executable (["-I", "-B", script] <> arguments)) input
  case parseJson surrogateRefusingLoads (TE.encodeUtf8 (T.pack out)) of
    Right value -> pure value
    Left problem -> expectationFailure ("the reference agents driver failed: " <> problem <> "\n" <> err) >> pure Null

hex :: ByteString -> String
hex = BC.unpack . B16.encode

unhex :: Text -> ByteString
unhex = either error id . B16.decode . TE.encodeUtf8

member :: Text -> Json -> Maybe Json
member name = \case
  Object members -> lookup name members
  _ -> Nothing

connection :: String
connection = "hamsterdan-pi-a2"

-- | @{"opened": hex}@ or the refusal, as the reference reports it.
haskellOpen :: FilePath -> Integer -> ByteString -> IO Json
haskellOpen root epoch sealed = do
  keys <- persistentKeyOperations root
  keyContext <- throwLeft (mkKeyContext (T.pack connection) epoch 1)
  outcome <- try (keys.open keyContext sealed)
  pure $ case outcome of
    Right (plain :: ScrubbedBytes) -> Object [("opened", String (T.pack (hex (BA.convert plain))))]
    Left (failure :: AgenticusError) -> Object [("message", String failure.errorMessage), ("refused", String (errorClassName failure.errorClass))]

haskellSeal :: FilePath -> ByteString -> IO ByteString
haskellSeal root plain = do
  keys <- persistentKeyOperations root
  keyContext <- throwLeft (mkKeyContext (T.pack connection) 1 1)
  keys.seal keyContext (BA.convert plain)

pythonSeal :: FilePath -> ByteString -> IO ByteString
pythonSeal root plain = do
  sealed <- reference ["seal", root, connection, "1", "1", hex plain] ""
  case member "sealed" sealed of
    Just (String value) -> pure (unhex value)
    other -> expectationFailure ("no sealed state: " <> show other) >> pure ""

pythonOpen :: FilePath -> Integer -> ByteString -> IO Json
pythonOpen root epoch sealed = reference ["open", root, connection, show epoch, "1", hex sealed] ""

data Side = Python | Haskell
  deriving stock (Eq, Show)

data Step = Claim Text | Settle [Text]

stepJson :: Step -> Json
stepJson = \case
  Claim operation -> Object [("claim", String operation)]
  Settle operations -> Object [("settle", Array (map String operations))]

-- | One phase of claims and settlements on a route database.
routes :: Side -> FilePath -> [Step] -> IO Json
routes Python root steps = reference ["routes", root] (T.unpack (either (error . show) id (dumpsText compact (Array (map stepJson steps)))))
routes Haskell root steps = do
  composition <- composeAgent Nothing Nothing Nothing
  store <- openAgentRouteStore (root </> "agent-routes.sqlite3")
  activateRoutes store composition (root </> "applications")
  reports <- traverse (run store composition) steps
  closeRoutes store
  pure (Array reports)
  where
    run store composition step = do
      outcome <- try @SomeException $ case step of
        Claim operation -> do
          route <- claimRoute store operation composition
          pure $
            Object
              [ ("operation", String route.operation)
              , ("profile", String route.profile)
              , ("snapshot", snapshotToData route.snapshot)
              , ("resolved", Bool route.resolved)
              ]
        Settle operations -> do
          settleRoutes store operations
          pure (Object [("settled", Array (map String operations))])
      pure $ case outcome of
        Right report -> report
        Left e
          | Just (AgentCompositionError message) <- fromException e ->
              Object [("message", String message), ("refused", String "AgentCompositionError")]
          | otherwise -> Object [("message", String (T.pack (show e))), ("refused", String "Exception")]

phaseOne, phaseTwo :: [Step]
phaseOne = [Claim "review:one", Claim "change:two", Settle ["review:one"], Claim "review:one"]
phaseTwo = [Claim "review:one", Claim "change:two", Claim "conversation:three", Settle ["change:two", "absent"], Claim "change:two"]

sameJson :: String -> Json -> Json -> Expectation
sameJson label expected actual = do
  let canonical value = either (error . show) id (dumpsText defaultDumps {sortKeys = True, indent = Just 1} value)
  unless (canonical expected == canonical actual) $
    expectationFailure (label <> "\n  reference: " <> T.unpack (canonical expected) <> "\n  haskell:   " <> T.unpack (canonical actual))

spec :: Spec
spec = describe "on-disk interop with the reference agent stores" $ do
  it "opens sealed connection state across languages, both ways, over either side's key" . withTmp $ \tmp -> do
    let plain = "opaque connection state \0\255"
        expected = Object [("opened", String (T.pack (hex plain)))]
    -- The reference creates the key and seals; the port opens.
    let pythonKeys = tmp </> "python-keys"
    fromPython <- pythonSeal pythonKeys plain
    haskellOpen pythonKeys 1 fromPython `shouldReturn` expected
    -- The port seals over the reference's key; the reference opens.
    fromHaskell <- haskellSeal pythonKeys plain
    pythonOpen pythonKeys 1 fromHaskell >>= sameJson "reference opens the port's state" expected
    -- The port creates the key; the reference opens and seals over it.
    let haskellKeys = tmp </> "haskell-keys"
    created <- haskellSeal haskellKeys plain
    pythonOpen haskellKeys 1 created >>= sameJson "reference opens over the port's key" expected
    resealed <- pythonSeal haskellKeys plain
    haskellOpen haskellKeys 1 resealed `shouldReturn` expected
    -- Both create the same key file: one per connection, 0600, 32 bytes.
    forM_ [pythonKeys, haskellKeys] $ \root -> do
      [name] <- listDirectory root
      status <- getFileStatus (root </> name)
      (fileSize status, fileMode status `mod` 0o1000) `shouldBe` (32, 0o600)
    listDirectory pythonKeys >>= \names -> listDirectory haskellKeys `shouldReturn` names
    -- A wrong context is refused the same way on both sides.
    refusedHere <- haskellOpen pythonKeys 2 fromPython
    refusedThere <- pythonOpen pythonKeys 2 fromHaskell
    sameJson "a wrong context" refusedThere refusedHere
    member "refused" refusedHere `shouldBe` Just (String "KeyOperationError")
    let tampered = BS.init fromPython <> BS.singleton (BS.last fromPython + 1)
    tamperedHere <- haskellOpen pythonKeys 1 tampered
    tamperedThere <- pythonOpen pythonKeys 1 tampered
    sameJson "tampered state" tamperedThere tamperedHere

  it "resumes each other's route database: every pairing of the two phases agrees with Python" . withTmp $ \tmp -> do
    let run first second = do
          let root = tmp </> (show first <> "-" <> show second)
          one <- routes first root phaseOne
          dumpOne <- reference ["dump", root] ""
          two <- routes second root phaseTwo
          dumpTwo <- reference ["dump", root] ""
          pure (one, dumpOne, two, dumpTwo)
    (pOne, pDumpOne, pTwo, pDumpTwo) <- run Python Python
    case pTwo of
      Array reports@(settled : resumed : _) -> do
        length reports `shouldBe` length phaseTwo
        -- Settled work stays fenced across the restart; open work resumes.
        member "message" settled `shouldBe` Just (String "resolved agent work cannot be redispatched")
        member "operation" resumed `shouldBe` Just (String "change:two")
      other -> expectationFailure ("no reports: " <> show other)
    member "tables" pDumpTwo `shouldSatisfy` (/= Nothing)
    forM_ [(Haskell, Haskell), (Python, Haskell), (Haskell, Python)] $ \(first, second) -> do
      (one, dumpOne, two, dumpTwo) <- run first second
      let label = show first <> " then " <> show second
      sameJson (label <> ": phase one") pOne one
      sameJson (label <> ": database after phase one") pDumpOne dumpOne
      sameJson (label <> ": phase two") pTwo two
      sameJson (label <> ": database after phase two") pDumpTwo dumpTwo

  it "reads route-repair Histories as str.splitlines() does: every line boundary, and a record one splits" . withTmp $ \tmp -> do
    let operation = "review:github:1:2:pr:3:" <> T.replicate 40 "a" <> ":i1"
        line record = TE.encodeUtf8 (either (error . show) id (dumpsText defaultDumps {ensureAscii = False} record))
        request = line (repairRequest operation)
        terminal note = line (repairTerminal note)
        boundaries = ["\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\x85", "\x2028", "\x2029"]
        cases =
          [("joined by " <> show boundary, request <> TE.encodeUtf8 boundary <> terminal "plain" <> TE.encodeUtf8 boundary) | boundary <- boundaries]
            <> [ ("non-boundary multi-byte text", request <> "\n" <> terminal "\8364\169\128\233\8224\8231\8234" <> "\n")
               , ("no final boundary", request <> "\n" <> terminal "plain")
               , ("a U+2028 inside a record", request <> "\n" <> terminal "split\8232here" <> "\n")
               , ("a U+0085 inside a record", request <> "\n" <> terminal "split\133here" <> "\n")
               , ("an empty line", request <> "\r\r\n" <> terminal "plain" <> "\n")
               , ("invalid UTF-8", request <> "\n" <> terminal "plain" <> "\255\n")
               , -- @json.loads@ keeps a lone surrogate escape.
                 ("a lone surrogate escape", request <> "\n" <> escaped "\\ud800" <> "\n")
               , ("a reversed surrogate pair", request <> "\n" <> escaped "\\udc00\\ud800x" <> "\n")
               ]
        -- The terminal with its note spelled as the given JSON escapes.
        escaped spelling =
          let (prefix, rest) = BS.breakSubstring "LONE" (terminal "LONE")
           in prefix <> spelling <> BS.drop 4 rest
    forM_ (zip [1 :: Int ..] cases) $ \(index, (label, bytes)) -> do
      let root = tmp </> ("histories-" <> show index)
          directory = root </> "1" </> "2" </> "3"
      createDirectoryIfMissing True directory
      BS.writeFile (directory </> "history.jsonl") bytes
      sameTerminal label root

  it "reads route-repair History paths that are not plain files as the reference does" . withTmp $ \tmp -> do
    let operation = "review:github:1:2:pr:3:" <> T.replicate 40 "b" <> ":i1"
        line record = TE.encodeUtf8 (either (error . show) id (dumpsText defaultDumps record)) <> "\n"
        history = line (repairRequest operation) <> line (repairTerminal "plain")
        layouts :: [(String, FilePath -> IO ())]
        layouts =
          [ ("a dangling symbolic link", \directory -> createSymbolicLink (directory </> "missing.jsonl") (directory </> "history.jsonl"))
          , ("a symbolic link loop", \directory -> createSymbolicLink (directory </> "history.jsonl") (directory </> "history.jsonl"))
          , ("a symbolic link to a History", \directory -> BS.writeFile (directory </> "real.jsonl") history >> createSymbolicLink (directory </> "real.jsonl") (directory </> "history.jsonl"))
          , ("a directory", \directory -> createDirectoryIfMissing True (directory </> "history.jsonl"))
          , ("an unreadable file", \directory -> BS.writeFile (directory </> "history.jsonl") history >> setFileMode (directory </> "history.jsonl") 0)
          ]
    forM_ (zip [1 :: Int ..] layouts) $ \(index, (label, layout)) -> do
      let root = tmp </> ("layout-" <> show index)
          directory = root </> "1" </> "2" </> "3"
      createDirectoryIfMissing True directory
      layout directory
      sameTerminal label root

-- | The reference's @_terminal_operations(root)@ against the port's: the
-- operations, or the exception's class and @str()@.
sameTerminal :: String -> FilePath -> Expectation
sameTerminal label root = do
  expected <- reference ["terminal", root] ""
  outcome <- try @SomeException (terminalOperations root)
  let actual = case outcome of
        Right operations -> Object [("operations", Array (map String (Set.toAscList operations)))]
        Left e
          | Just (AgentCompositionError message) <- fromException e ->
              Object [("message", String message), ("refused", String "AgentCompositionError")]
          | Just failure@(PythonException name _) <- fromException e ->
              Object [("message", String (pythonExceptionStr failure)), ("refused", String name)]
          | otherwise -> Object [("message", String (T.pack (show e))), ("refused", String "Exception")]
  sameJson label expected actual

-- | A review-agent request for route repair.
repairRequest :: Text -> Json
repairRequest operation =
  Object
    [ ("record", String "ActivityRequested")
    , ("schema", Int 5)
    , ("transition", String "review.agent")
    , ("activity", String "review_agent")
    , ("input", Object [("work", Object [("operation", String operation)])])
    , ( "policy"
      , Object
          [ ("attempts", Int 1)
          , ("heartbeat_timeout", Int 300)
          , ("initial_interval", Int 0)
          , ("coefficient", Int 2)
          , ("max_interval", Int 60)
          , ("jitter", Int 0)
          , ("start_to_close", Null)
          , ("schedule_to_close", Null)
          ]
      )
    , ("correlation", String operation)
    , ("idempotency", String operation)
    , ("occurrence", Int 1)
    , ("scope", Null)
    , ("instant", Int 0)
    ]

-- | Its known terminal, carrying a free-text note.
repairTerminal :: Text -> Json
repairTerminal note =
  Object
    [ ("record", String "ActivityCompleted")
    , ("schema", Int 5)
    , ("transition", String "review.agent")
    , ("result", Object [("$variant", String "RoundUnable"), ("note", String note)])
    , ("occurrence", Int 1)
    , ("instant", Int 0)
    ]

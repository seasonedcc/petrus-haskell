-- | Pi native runtime hot paths; the twin of @bench/python_pi.py@.
--
-- * @pi-start-frame-encode@: the resumed, all-tools @start@ frame of
--   @differential/pi_corpus.json@ to its wire bytes (@_SubprocessClient._write@).
-- * @pi-tool-call-decode@: one @tool_call@ frame line through the frame
--   reader's strict loader.
-- * @pi-session-validate@: @_validate_session@ over a 200-entry session.
-- * @pi-fingerprint@: @pi_durable_work_fingerprint@.
-- * @pi-ledger-cycle@: one durable operation through a SQLite ledger:
--   @admit@, @settle@, @upgrade_cleanup@, @acknowledge@ and @lookup@,
--   timed with the twin's protocol (see "Twin": the ledger is fsync-bound).
module PiBench (piBenchmarks) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Connection.Custody (mkConnectionIdentity)
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), mkRuntimeOperationCleanup)
import Petrus.Agenticus.Runtime.Pi
import Petrus.Agenticus.Runtime.PiRecovery
import Petrus.Agenticus.Runtime.Result (mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.FilePath ((</>))
import Test.Tasty.Bench
import Twin (twin)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe (error (T.unpack key)) id (lookup key members)
  other -> error (show other)

-- | Walks the whole value, forcing it (the twin returns a built @dict@).
size :: Json -> Int
size = \case
  Array xs -> 1 + sum (map size xs)
  Object members -> 1 + sum [T.length k + size v | (k, v) <- members]
  String t -> T.length t
  _ -> 1

-- | The resumed, all-tools api-key @start@ frame of the corpus, as sent.
startFrameValue :: IO Json
startFrameValue = do
  corpus <- either fail pure . J.parseJson J.pythonLoads =<< B.readFile "differential/pi_corpus.json"
  let start = case member "starts" (member "frames" corpus) of
        Array (_ : resumed : _) -> resumed
        other -> error (show other)
      encoded = case member "ok" (member "frame" start) of
        String t -> t
        other -> error (show other)
      bytes = ok (pyB64DecodeStrict (B.pack (map (fromIntegral . fromEnum) (T.unpack encoded))))
  either fail pure (J.parseJson J.pythonLoads (B.init bytes))

toolCall :: ByteString
toolCall = "{\"type\":\"tool_call\",\"id\":\"call-1\",\"method\":\"workspace_read\",\"params\":{\"path\":\"README.md\"}}"

sessionId :: Text
sessionId = "11111111-1111-4111-8111-111111111111"

-- | A version-3 header and 199 message entries.
sessionBytes :: ByteString
sessionBytes =
  B.concat $
    ("{\"type\":\"session\",\"version\":3,\"id\":\"" <> encode sessionId <> "\"}\n")
      : [ "{\"type\":\"message\",\"id\":\"m" <> encode (T.pack (show i)) <> "\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello \\u00e9 world\"}]}\n"
        | i <- [1 :: Int .. 199]
        ]
  where
    encode = B.pack . map (fromIntegral . fromEnum) . T.unpack

fingerprint :: Text -> Text
fingerprint prompt =
  ok
    ( piDurableWorkFingerprint
        (piRuntimeConfig "provider" "model" "/working" "/private")
        (ok (mkEpisodeId "episode"))
        (ok (mkTurnId "turn"))
        prompt
        (ok (mkConnectionIdentity "connection" "provider" "account" "api-key"))
        Nothing
    )

-- | One operation from admission to acknowledgement, then a lookup.
ledgerCycle :: SqlitePiOperationLedger -> IORef Int -> IO ()
ledgerCycle ledger counter = do
  n <- atomicModifyIORef' counter (\i -> (i + 1, i))
  let operation = "op-" <> T.pack (show n)
      episode = ok (mkEpisodeId "episode")
      turn = ok (mkTurnId ("turn-" <> T.pack (show n)))
  _ <- ledgerAdmit ledger operation (T.replicate 64 "a") episode turn
  settlement <- either throwIO pure (mkRuntimeTurnSettlement episode turn TurnCompleted 1 "turn-completed" (Just "output") (Just "continuation"))
  _ <- ledgerSettle ledger operation settlement
  evidence <- either throwIO pure (mkRuntimeOperationCleanup operation RuntimeCleanupClean "cleanup-verified" False)
  _ <- ledgerUpgradeCleanup ledger operation evidence
  _ <- ledgerAcknowledge ledger operation
  found <- ledgerLookup ledger operation
  maybe (fail "lost operation") (const (pure ())) found

piBenchmarks :: FilePath -> IO [Benchmark]
piBenchmarks tmp = do
  start <- startFrameValue
  ledger <- openSqlitePiOperationLedger (tmp </> "ledger" </> "operations.sqlite3")
  counter <- newIORef 0
  pure
    [ bench "pi-start-frame-encode" (nf (ok . frameBytes) start)
    , bench "pi-tool-call-decode" (whnf (size . ok . strictFrameLoad) toolCall)
    , bench "pi-session-validate" (nf (\s -> ok (validateSession s sessionId 4000000 10000)) sessionBytes)
    , bench "pi-fingerprint" (nf fingerprint "pi-prompt-canary-never-render")
    , twin "pi-ledger-cycle" 200 (ledgerCycle ledger counter)
    ]

-- | Pi A2 host hot paths; the twin of @bench/python_pi_a2.py@.
--
-- * @pi-a2-fingerprint@: @_pi_a2_durable_fingerprint@ over an all-tools
--   policy and a fixed inner fingerprint.
-- * @pi-a2-scripted-turn@: one scripted operation on one host: @start@ (a
--   fresh operation id, so admission, a Local territory, the Episode
--   Attachment and the grant), @wait@ (the body commit, the ledger
--   settlement and publication), then @close@. Authority is supplied once,
--   on the first iteration.
--
--   A turn's cost grows with the turns before it on the same host, in both
--   implementations (closing evicts handles up to the acknowledged
--   watermark, which reads every ledger record), so tasty-bench's doubling
--   of iterations never settles on it. This row therefore runs the twin's
--   exact protocol instead ('twin'): one warm-up turn, then 7 batches of 20
--   turns on one host, reporting the median batch's time per turn.
module PiA2Bench (piA2Benchmarks) where

import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Connection.Custody (mkConnectionIdentity)
import Petrus.Agenticus.Connection.Key (KeyOperations (..), mkKeyErasureEvidence)
import Petrus.Agenticus.Hands.Contract (allToolMethods)
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import Petrus.Agenticus.Runtime.PiA2Host
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Motus.Execution.Archive (workspaceArchive)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Tasty.Bench
import Twin (twin)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- | Reversible stand-in keys shared with the twin; the bench measures the
-- host, not the cipher.
keys :: KeyOperations
keys =
  KeyOperations
    { seal = \_ plaintext -> pure ("sealed:" <> BA.convert plaintext)
    , open = \_ sealed -> pure (BA.convert (B.drop 7 sealed))
    , erase = \connectionId -> either (fail . show) pure (mkKeyErasureEvidence connectionId True)
    }

hostConfigFor :: FilePath -> PiA2RuntimeHostConfig
hostConfigFor tmp =
  PiA2RuntimeHostConfig
    { stateRoot = tmp </> "state"
    , workingDirectory = tmp </> "working"
    , provider = "anthropic"
    , model = "claude-sonnet-4-5"
    , hostId = "bench-host"
    , capabilities = Set.fromList allToolMethods
    , allowedArgv = Set.fromList [["/usr/bin/true"]]
    , testCommand = ["/usr/bin/true"]
    , maxToolCalls = 8
    , attachmentTimeout = 20
    , commandTimeout = 5
    , credentialTtl = 30
    , wallTimeout = 10
    , cancellationGrace = 1
    , cliPath = Nothing
    , nodePath = Nothing
    , packageRoot = Nothing
    }

startFor :: ByteString -> Text -> PiA2RuntimeStart
startFor archive name =
  PiA2RuntimeStart
    { operationId = name
    , episodeId = ok (mkEpisodeId ("episode-" <> name))
    , turnId = ok (mkTurnId ("turn-" <> name))
    , prompt = "prompt"
    , workspaceArchive = archive
    , workspaceDigest = sha256Hex archive
    , workspaceCorrelation = "bench-tree-" <> sha256Hex archive
    , policy = ok (mkPiA2RuntimePolicy allToolMethods ["output.txt"] 8 [])
    , continuation = Nothing
    }

scriptedTurn :: PiA2RuntimeHost -> ByteString -> IORef Int -> IO ()
scriptedTurn host archive counter = do
  n <- atomicModifyIORef' counter (\i -> (i + 1, i))
  operation <- startHost host (startFor archive ("op-" <> T.pack (show n)))
  settlement <- waitPiA2 operation (Just 5)
  _ <- closePiA2 operation
  if settlement.outcome == TurnCompleted then pure () else fail (show settlement)

-- | The benchmarks and the host to close once they have run.
piA2Benchmarks :: FilePath -> IO ([Benchmark], IO ())
piA2Benchmarks tmp = do
  createDirectoryIfMissing True (tmp </> "working")
  B.writeFile (tmp </> "working" </> "input.txt") "input"
  archive <- workspaceArchive (tmp </> "working")
  let config = hostConfigFor tmp
      authority =
        ok (mkPiA2DirectAuthority (ok (mkConnectionIdentity "direct" "anthropic" "account" "api-key")) keys (pure (BA.convert ("bench-api-key" :: ByteString))))
      inner = T.replicate 64 "a"
  validated <- newPiA2RuntimeHostConfig config
  factory <- piA2ScriptedFactory (repeat (piA2ScriptedTurn "answer"))
  host <- composePiA2ScriptedClientRuntime config authority factory Nothing getMonotonicTime
  _ <- scriptedReadiness host
  counter <- newIORef 0
  pure
    ( [ bench "pi-a2-fingerprint" (nf (\s -> ok (piA2DurableFingerprint validated s inner)) (startFor archive "operation"))
      , twin "pi-a2-scripted-turn" 20 (scriptedTurn host archive counter)
      ]
    , () <$ closeHost host
    )

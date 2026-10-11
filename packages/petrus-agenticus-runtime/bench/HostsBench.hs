-- | Codex, Claude and Amp host hot paths; the twin of @bench/python_hosts.py@.
--
-- * @codex-jsonl-parse@: @_parse_jsonl@ over one completed @codex exec
--   --json@ stream: @thread.started@, @turn.started@, 100 reasoning items
--   (started and completed), two agent messages and @turn.completed@.
-- * @codex-helper-parse@: @_parse_helper@ over a @collect@ reply.
-- * @codex-terminal-encode@: @_json_bytes@ of one A3 success terminal.
-- * @codex-terminal-parse@: @_parse_terminal@ of that frame, correlated.
-- * @claude-transcript-encode@: @_encode_transcript@ of 200 entries.
-- * @claude-transcript-decode@: @_decode_transcript@ of those bytes.
-- * @claude-canonical-input@: @_canonical_input@ of one tool input.
-- * @claude-sanitize@: @_sanitize@ of a 4 KB result with ANSI escapes.
-- * @amp-stream-admit@: @_read_stream@ over @system/init@, 200 assistant
--   events and a success @result@, sizing every event from its compact JSON.
-- * @amp-final-text@: @_safe_final_text@ of the same 4 KB text.
module HostsBench (hostsBenchmarks) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Runtime.Amp.Internal
import Petrus.Agenticus.Runtime.Claude (canonicalInput, decodeTranscript, encodeTranscript, sanitize)
import Petrus.Agenticus.Runtime.Codex (Candidate (..), parseHelper, parseJsonl)
import Petrus.Agenticus.Runtime.CodexGondolin (jsonBytes, parseTerminal)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkTurnId)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Tasty.Bench

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

thread :: Text
thread = "11111111-1111-4111-8111-111111111111"

compact :: Json -> ByteString
compact = ok . J.dumps J.defaultDumps {J.itemSeparator = Just ", ", J.keySeparator = ": "}

codexStream :: ByteString
codexStream =
  B.intercalate "\n" . map compact $
    [ Object [("type", String "thread.started"), ("thread_id", String thread)]
    , Object [("type", String "turn.started")]
    ]
      <> concat
        [ [ Object [("type", String "item.started"), ("item", Object [("id", String ("r" <> n)), ("type", String "reasoning"), ("text", String "thinking")])]
          , Object [("type", String "item.completed"), ("item", Object [("id", String ("r" <> n)), ("type", String "reasoning"), ("text", String "thinking about it")])]
          ]
        | i <- [1 .. 100 :: Int]
        , let n = T.pack (show i)
        ]
      <> [ Object [("type", String "item.completed"), ("item", Object [("id", String "m1"), ("type", String "agent_message"), ("text", String "first \x1b[31manswer\x1b[0m")])]
         , Object [("type", String "item.completed"), ("item", Object [("id", String "m2"), ("type", String "agent_message"), ("text", String "final answer \233")])]
         , Object [("type", String "turn.completed"), ("usage", Object [("input_tokens", Int 10), ("output_tokens", Int 20)])]
         ]

terminal :: Json
terminal =
  Object
    [ ("ok", Bool True)
    , ( "result"
      , Object
          [ ("version", Int 1)
          , ("operation_id", String "operation-bench")
          , ("episode_id", String "episode-bench")
          , ("turn_id", String "turn-bench")
          , ("outcome", String "completed")
          , ("accepted_appends", Int 1)
          , ("termination_code", String "turn-completed")
          , ("output_reference", String "codex-turn-operation-bench")
          , ("continuation_reference", String "codex-continuation-operation-bench")
          , ("cleanup", Object [("disposition", String "clean"), ("code", String "client-closed")])
          ]
      )
    ]

transcript :: Json
transcript =
  Array
    [ Object
        [ ("uuid", String ("entry-" <> T.pack (show i)))
        , ("type", String (if even i then "assistant" else "user"))
        , ("message", Object [("role", String "assistant"), ("content", Array [Object [("type", String "text"), ("text", String "hello \233 world")]])])
        , ("parentUuid", if i == 0 then Null else String ("entry-" <> T.pack (show (i - 1))))
        ]
    | i <- [0 .. 199 :: Int]
    ]

toolInput :: Json
toolInput = Object [("path", String "src/Main.hs"), ("pattern", String "TODO"), ("limit", Int 50), ("flags", Array [String "i", String "n"])]

resultText :: Text
resultText = T.concat (replicate 128 "\x1b[32mok\x1b[0m line \233\t with text\n")

ampEvents :: [[(Text, Json)]]
ampEvents =
  [("type", String "system"), ("subtype", String "init"), ("session_id", String ampThread)]
    : [ [("type", String "assistant"), ("session_id", String ampThread), ("message", Object [("content", String ("step " <> T.pack (show i)))])]
      | i <- [1 .. 200 :: Int]
      ]
      <> [[("type", String "result"), ("subtype", String "success"), ("is_error", Bool False), ("session_id", String ampThread), ("result", String "done")]]
  where
    ampThread = "T-0123abcd-4567-89ef"

-- | Walks the whole value, forcing it (the twin returns a built value).
size :: Json -> Int
size = \case
  Object members -> sum [T.length k + size v | (k, v) <- members] + 1
  Array values -> sum (map size values) + 1
  String t -> T.length t
  Int n -> fromInteger (n `mod` 7)
  _ -> 1

hostsBenchmarks :: [Benchmark]
hostsBenchmarks =
  let frame = ok (jsonBytes terminal) <> "\n"
      encoded = ok (encodeTranscript 10000 4000000 transcript)
      helper = "{\"ok\": true, \"rollout_path\": \"sessions/2026/08/03/rollout-2026-08-03T00-00-00-" <> B.pack (map (fromIntegral . fromEnum) (T.unpack thread)) <> ".jsonl\"}\n"
      episode = ok (mkEpisodeId "episode-bench")
      turn = ok (mkTurnId "turn-bench")
      config = ampRuntimeConfig "project"
   in [ bench "codex-jsonl-parse" (nf (\raw -> (\c -> (c.threadId, c.completed, c.text)) (ok (parseJsonl raw 0))) codexStream)
      , bench "codex-helper-parse" (whnf (\raw -> maybe 0 size (ok (parseHelper raw True))) helper)
      , bench "codex-terminal-encode" (nf (ok . jsonBytes) terminal)
      , bench "codex-terminal-parse" (whnf (\raw -> size (ok (parseTerminal raw (Just "operation-bench") (Just episode) (Just turn)))) frame)
      , bench "claude-transcript-encode" (nf (ok . encodeTranscript 10000 4000000) transcript)
      , bench "claude-transcript-decode" (whnf (sum . map size . ok . decodeTranscript 10000 4000000) encoded)
      , bench "claude-canonical-input" (nf (ok . canonicalInput) toolInput)
      , bench "claude-sanitize" (nf (ok . sanitize 1000000) resultText)
      , bench "amp-stream-admit" (nf (\events -> (\c -> (c.terminationCode, c.finalText)) (ok (admitEvents config Nothing (map jsonEvent events)))) ampEvents)
      , bench "amp-final-text" (nf (ok . safeFinalText 1000000) resultText)
      ]

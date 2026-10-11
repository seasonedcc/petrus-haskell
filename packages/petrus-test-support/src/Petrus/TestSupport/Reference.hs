-- | Live round trips through the pinned reference's own parsers and
-- serializers.
--
-- A committed differential corpus pins what the reference produced once; it
-- cannot say whether the reference accepts what /Haskell/ produces today.
-- These helpers hand Haskell-produced bytes to the pinned
-- @petrus.impetus@ in one interpreter run and require each payload back
-- byte for byte:
--
-- * a Net definition through @serialize_net_definition(parse_net_definition(b))@;
-- * a Net document through @serialize_net_document(parse_net_document(b))@;
-- * a History record (one JSON document as @json.dumps@ spells it with its
--   defaults: ASCII, @", "@ and @": "@ separators) through
--   @json.dumps(encode_record(decode_record(json.loads(b))))@.
--
-- The reference environment is provisioned by @scripts/upstream-python@ on
-- first use; when it cannot be, the expectation fails (it never skips).
module Petrus.TestSupport.Reference
  ( Subject (..)
  , Verdict (..)
  , referenceRoundTrips
  , shouldRoundTripThroughReference
  ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.TestSupport.Python (PythonFailure (..), PythonResult (..), runPython)
import System.Exit (ExitCode (..))
import Test.Hspec (Expectation, expectationFailure)

-- | What the reference parses and re-serializes.
data Subject
  = -- | @parse_net_definition@, then @serialize_net_definition@.
    NetDefinitionSubject
  | -- | @parse_net_document@, then @serialize_net_document@.
    NetDocumentSubject
  | -- | @json.loads@, @decode_record@, @encode_record@, then @json.dumps@.
    HistoryRecordSubject
  deriving stock (Eq, Show)

-- | The reference's answer for one payload.
data Verdict
  = -- | The reference accepted the payload and wrote these bytes.
    Reserialized ByteString
  | -- | The reference refused it: @"ExceptionClass: message"@.
    Refused Text
  deriving stock (Eq, Show)

-- | Ask the pinned reference about every payload, in one interpreter run;
-- the verdicts come back in order. A reference that cannot be started, or
-- that answers out of protocol, raises 'PythonFailure'.
referenceRoundTrips :: [(Subject, ByteString)] -> IO [Verdict]
referenceRoundTrips [] = pure []
referenceRoundTrips payloads = do
  result <- runPython roundTripper [] (BC.unlines (map request payloads))
  unless (resultExit result == ExitSuccess) $
    throwIO (PythonFailure "the reference round-tripper failed" (resultStdout result) (resultStderr result))
  let answers = BC.lines (resultStdout result)
  unless (length answers == length payloads) $
    throwIO
      ( PythonFailure
          ("the reference answered " <> show (length answers) <> " of " <> show (length payloads) <> " payloads")
          (resultStdout result)
          (resultStderr result)
      )
  traverse verdict answers
  where
    request (subject, payload) =
      "{\"kind\": \"" <> kind subject <> "\", \"payload\": \"" <> B64.encode payload <> "\"}"
    kind = \case
      NetDefinitionSubject -> "definition"
      NetDocumentSubject -> "document"
      HistoryRecordSubject -> "record"
    verdict line = case parseJson pythonLoads line of
      Right value
        | Just (String encoded) <- lookupMember "ok" value
        , Right bytes <- B64.decode (TE.encodeUtf8 encoded) ->
            pure (Reserialized bytes)
        | Just (String problem) <- lookupMember "error" value -> pure (Refused problem)
      _ -> throwIO (PythonFailure "the reference answered out of protocol" line "")

-- | Every labelled payload is accepted by the reference and re-serialized
-- to exactly its own bytes. The failure lists every disagreement (the first
-- ten in full).
shouldRoundTripThroughReference :: [(String, Subject, ByteString)] -> Expectation
shouldRoundTripThroughReference cases = do
  verdicts <- referenceRoundTrips [(subject, payload) | (_, subject, payload) <- cases]
  let problems =
        [ problem
        | ((label, _, payload), answer) <- zip cases verdicts
        , Just problem <- [disagreement label payload answer]
        ]
  unless (null problems) $
    expectationFailure
      ( show (length problems)
          <> " of "
          <> show (length cases)
          <> " payloads did not round-trip through the reference:\n"
          <> unlines (take 10 problems)
      )
  where
    disagreement label payload = \case
      Reserialized bytes
        | bytes == payload -> Nothing
        | otherwise ->
            Just
              ( label
                  <> ": the reference re-serialized it differently\n  sent:     "
                  <> excerpt payload
                  <> "\n  received: "
                  <> excerpt bytes
              )
      Refused problem -> Just (label <> ": the reference refused it: " <> T.unpack problem <> "\n  sent: " <> excerpt payload)
    excerpt bytes =
      let shown = BC.unpack (BC.take 600 bytes)
       in show shown <> (if BC.length bytes > 600 then " …" else "")

-- | The round-tripper: one JSON request per stdin line, one JSON answer per
-- stdout line, ASCII both ways.
roundTripper :: Text
roundTripper =
  T.unlines
    [ "import base64, json, sys"
    , "from petrus.impetus.net_definition import parse_net_definition, serialize_net_definition"
    , "from petrus.impetus.net_document import parse_net_document, serialize_net_document"
    , "from petrus.impetus.history.codec import decode_record, encode_record"
    , "ROUND = {"
    , "    'definition': lambda payload: serialize_net_definition(parse_net_definition(payload)),"
    , "    'document': lambda payload: serialize_net_document(parse_net_document(payload)),"
    , "    'record': lambda payload: json.dumps(encode_record(decode_record(json.loads(payload)))).encode('ascii'),"
    , "}"
    , "answers = []"
    , "for line in sys.stdin.buffer:"
    , "    request = json.loads(line)"
    , "    payload = base64.b64decode(request['payload'], validate=True)"
    , "    try:"
    , "        answer = {'ok': base64.b64encode(ROUND[request['kind']](payload)).decode('ascii')}"
    , "    except Exception as error:"
    , "        answer = {'error': f'{type(error).__name__}: {error}'}"
    , "    answers.append(json.dumps(answer))"
    , "sys.stdout.write(''.join(answer + '\\n' for answer in answers))"
    ]

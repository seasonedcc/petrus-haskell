-- | Pi review results through @_parse_result@ and @_validate_result@ of the
-- pinned reference (@differential/agents_reference.py results@) and through
-- the port's 'parseResult' and 'validateResult': each must be accepted,
-- refused with the same reason and category, or raise the same built-in
-- exception.
--
-- The cases are a valid result with one value replaced, many of them by a
-- JSON string holding lone surrogate escapes, which @json.loads@ keeps in
-- the @str@ and which fail only where the reference encodes the string.
module ResultDifferentialSpec (spec) where

import Control.Monad (forM_, unless)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Pi (parseResult)
import Hamsterdan.Agents.Protocol
import Hamsterdan.Agents.Validate (Failure (..), ResultKind (..), validateResult)
import Hamsterdan.Contracts.Codec (contract, encode)
import Petrus.Json (EncodeOptions (..), Json (..), compact, defaultDumps, dumps, dumpsText, parseJson, pythonLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import PiDoubles (baseSha, headSha)
import ProtocolSpec (reviewRequest)
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | A review result, as Pi's JSON text, with @hole@ (JSON source text) as
-- the value of one finding field (or of a top-level one).
result :: [(Text, Text)] -> [(Text, Text)] -> Text
result top findingFields =
  object
    ( override
        top
        [ ("repository", "\"owner/repo\"")
        , ("pull_request", "3")
        , ("epoch", "2")
        , ("head", quoted headSha)
        , ("base", quoted baseSha)
        , ("status", "\"blocking\"")
        , ("findings", "[" <> object (override findingFields finding) <> "]")
        , ("lineage", "[{\"finding_id\": \"F1\", \"state\": \"new\", \"supersedes\": null}]")
        ]
    )
  where
    finding =
      [ ("id", "\"F1\"")
      , ("path", "\"src/one.py\"")
      , ("line", "4")
      , ("related_locations", "[]")
      , ("title", "\"Keep both guards aligned\"")
      , ("body", "\"These guards disagree.\"")
      , ("severity", "\"high\"")
      , ("confidence", "0.9")
      , ("evidence", "\"The primary path allows it.\"")
      , ("blocking", "true")
      , ("suggestion", "\"\"")
      ]
    override replacements fields =
      [(name, maybe value id (lookup name replacements)) | (name, value) <- fields]
        <> [(name, value) | (name, value) <- replacements, name `notElem` map fst fields]
    object fields = "{" <> T.intercalate ", " [quoted name <> ": " <> value | (name, value) <- fields] <> "}"
    quoted value = "\"" <> value <> "\""

cases :: [(String, Text)]
cases =
  [ ("a valid result", result [] [])
  , ("a surrogate pair, which json.loads joins", result [] [("title", "\"Keep \\ud83d\\ude00 aligned\"")])
  , ("a lone surrogate in a finding title", result [] [("title", "\"Keep \\ud800 aligned\"")])
  , ("a lone surrogate in a finding body", result [] [("body", "\"\\udcff\"")])
  , ("a lone surrogate in the empty-allowed suggestion", result [] [("suggestion", "\"\\udfff\"")])
  , ("a lone surrogate in a finding id", result [] [("id", "\"F\\ud800\"")])
  , ("a lone surrogate in a finding path", result [] [("path", "\"src/\\udcff.py\"")])
  , ("a lone surrogate in a related location", result [] [("related_locations", "[{\"path\": \"\\ud800\", \"line\": 2}]")])
  , ("a lone surrogate in a lineage id", result [("lineage", "[{\"finding_id\": \"\\ud800\", \"state\": \"new\", \"supersedes\": null}]")] [])
  , ("a lone surrogate as the status", result [("status", "\"\\ud800\"")] [])
  , ("a lone surrogate in the head", result [("head", "\"\\ud800\"")] [])
  , ("a lone surrogate in the repository", result [("repository", "\"owner/\\udc80\"")] [])
  , ("a lone surrogate as an extra result key", result [("\\ud800", "1")] [])
  , ("a lone surrogate as an extra finding key", result [] [("\\udc00x", "1")])
  , ("an empty title before a lone surrogate elsewhere", result [] [("title", "\"\""), ("body", "\"\\ud800\"")])
  , ("a lone surrogate in an oversized body", result [] [("body", "\"" <> T.replicate 70000 "x" <> "\\ud800\"")])
  ]

-- | What the port does with one raw result, as the reference reports it.
ported :: Text -> Json
ported raw = case parseResult raw >>= \members -> validateResult KindReview (Object members) (AgentReview reviewRequest) Nothing of
  Right _ -> Object [("accepted", Bool True)]
  Left (Refused failure) -> Object [("category", maybe Null (encode contract) failure.resultCategory), ("refused", String failure.reason)]
  Left (Foreign cls message) -> Object [("message", String message), ("raised", String cls)]

spec :: Spec
spec = describe "Pi review results against the reference's _parse_result and _validate_result" $
  it "accepts, refuses and raises as the reference does" $ do
    executable <- upstreamPythonExecutable "hamsterdan"
    repo <- repoRoot
    let script = repo </> "packages" </> "hamsterdan-agents" </> "differential" </> "agents_reference.py"
        request = encode contract reviewRequest
        input = Array [Object [("raw", String raw), ("request", request)] | (_, raw) <- cases]
        encoded = either (error . show) id (dumps compact input)
    (_, out, err) <- readCreateProcessWithExitCode (proc executable ["-I", "-B", script, "results", "-"]) (T.unpack (TE.decodeUtf8 encoded))
    reports <- case parseJson pythonLoads (TE.encodeUtf8 (T.pack out)) of
      Right (Array reports) | length reports == length cases -> pure reports
      other -> fail ("the reference driver failed: " <> show other <> "\n" <> err)
    forM_ (zip cases reports) $ \((label, raw), expected) -> do
      let canonical value = either (error . show) id (dumpsText defaultDumps {sortKeys = True} value)
          actual = ported raw
      unless (canonical expected == canonical actual) $
        expectationFailure (label <> "\n  reference: " <> T.unpack (canonical expected) <> "\n  haskell:   " <> T.unpack (canonical actual))

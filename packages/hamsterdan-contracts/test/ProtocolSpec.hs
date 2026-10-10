{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The agent protocol types against protocol.jsonl
-- (scripts/gen_protocol_corpus.py): every value spells exactly as
-- @json.dumps(dataclasses.asdict(value), ...)@ does in the pinned Python.
module ProtocolSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Contract (..), DecodeError, codecFields, dump, renderDecodeError, spelling, validateJson)
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps)
import Test.Hspec

import CorpusSpec (member, readCorpus)

spec :: Spec
spec = describe "agent protocol (hamsterdan.agents.protocol)" $ do
  rows <- runIO (readCorpus "protocol.jsonl")
  let grouped = Map.fromListWith (flip (<>)) [(field' "type" row, [row]) | row <- rows]
  it "covers the six protocol dataclasses" $
    Map.keys grouped `shouldBe` ["CodingRequest", "CodingResult", "ConversationRequest", "ConversationResult", "ReviewRequest", "ReviewResult"]
  forM_ (Map.toList grouped) $ \(name, cases) ->
    it ("spells " <> T.unpack name <> " as asdict + json.dumps (" <> show (length cases) <> " values)") $
      concatMap (check name) cases `shouldBe` []
  it "declares the upstream field order" $ do
    codecFields (contract @CodingRequest)
      `shouldBe` [ "kind", "repository", "pull_request", "epoch", "head", "base", "ref", "selected_work"
                 , "failure_evidence", "fingerprint", "lineage", "reproduction_status", "merge_base"
                 ]
    take 6 (codecFields (contract @ReviewRequest)) `shouldBe` ["repository", "pull_request", "epoch", "head", "base", "diff_path"]
  it "spells the closed failure vocabularies" $ do
    map spelling [minBound .. maxBound :: AgentResultCategory]
      `shouldBe` ["runtime_lifecycle", "output_schema", "correlation", "unchanged", "unable", "workspace_reconciliation"]
    spelling CleanupUnverified `shouldBe` "cleanup_unverified"
  it "retains only the first category (retain_result_category / retain_cleanup_category)" $ do
    let failure = retainResultCategory Unable (retainResultCategory Correlation (protocolError "x"))
    failure.resultCategory `shouldBe` Just Correlation
    (retainCleanupCategory CleanupUnverified failure).cleanupCategory `shouldBe` Just CleanupUnverified
    failure.canceled `shouldBe` False
  it "decodes strictly" $ do
    let refused :: Either DecodeError CodingResult -> Bool
        refused = either (const True) (const False)
    refused (validateJson "{}") `shouldBe` True
    (either (Left . renderDecodeError) Right (validateJson "{\"kind\":\"change\",\"repository\":\"o/r\",\"pull_request\":1,\"epoch\":0,\"head\":\"h\",\"base\":\"b\",\"ref\":\"r\",\"extra\":1}" :: Either DecodeError CodingRequest) >>= const (Right ()))
      `shouldBe` Left "extra: extra inputs are not permitted"
  where
    field' key row = case member key row of
      Just (String value) -> value
      other -> error ("protocol corpus: " <> show key <> ": " <> show other)
    check :: Text -> Json -> [String]
    check name row = case validateInput name (TE.encodeUtf8 (field' "input" row)) of
      Left problem -> [T.unpack name <> " refused " <> T.unpack (field' "input" row) <> ": " <> T.unpack problem]
      Right value ->
        let spelled options = either (const "<unencodable>") id (dumps options value)
            expectedPlain = TE.encodeUtf8 (field' "asdict" row)
            expectedIdentity = TE.encodeUtf8 (field' "identity" row)
         in [ "asdict " <> show (spelled compact) <> " /= " <> show expectedPlain | spelled compact /= expectedPlain]
              <> [ "identity " <> show (spelled identity) <> " /= " <> show expectedIdentity
                 | spelled identity /= expectedIdentity
                 ]
    identity = compact {sortKeys = True, ensureAscii = True}
    validateInput :: Text -> BS.ByteString -> Either Text Json
    validateInput name bytes = case name of
      "ReviewRequest" -> through @ReviewRequest bytes
      "ReviewResult" -> through @ReviewResult bytes
      "ConversationRequest" -> through @ConversationRequest bytes
      "ConversationResult" -> through @ConversationResult bytes
      "CodingRequest" -> through @CodingRequest bytes
      "CodingResult" -> through @CodingResult bytes
      _ -> Left ("unknown type " <> name)
    through :: forall a. (Contract a) => BS.ByteString -> Either Text Json
    through bytes = either (Left . renderDecodeError) (Right . dump) (validateJson bytes :: Either DecodeError a)

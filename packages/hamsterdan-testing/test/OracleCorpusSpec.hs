-- | The oracle against the pinned Python, row by row
-- (scripts/gen_oracle_corpus.py): admission or refusal of each encoded
-- facts document (with the exact @__post_init__@ rule when one refused
-- it), the facts' strict dump (by SHA-256 of its compact spelling), the
-- expectation's dump byte for byte, and the liveness verdict under six
-- environments times both budget flags.
module OracleCorpusSpec (spec) where

import Control.Monad (unless, (<=<))
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Testing.Readiness
import Petrus.Json (Json (..), compact, dumps, parseJson, pythonLoads)
import Test.Hspec

-- | The six environments of the generator: every condition declared, then
-- each one withheld in turn.
environments :: [FairEnvironment]
environments =
  [ FairEnvironment (off /= 0) (off /= 1) (off /= 2) (off /= 3) (off /= 4)
  | off <- [-1 .. 4 :: Int]
  ]

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

spelled :: Json -> BS.ByteString
spelled = either (const "<unencodable>") id . dumps compact

data Row = Row
  { input :: Text
  , outcome :: Either (Maybe Text) (Text, Json, [Text])
  }

decodeRow :: Json -> Either String Row
decodeRow row = case (member "input" row, member "refused" row) of
  (Just (String input), Just (Bool True)) -> Right (Row input (Left rule))
   where
    rule = case member "rule" row of
      Just (String found) -> Just found
      _ -> Nothing
  (Just (String input), _)
    | Just (String digest) <- member "facts_sha256" row
    , Just expectation <- member "expectation" row
    , Just (Array liveness) <- member "liveness" row ->
        Right (Row input (Right (digest, expectation, [found | String found <- liveness])))
  _ -> Left ("oracle corpus row: " <> show row)

judge :: Row -> Maybe String
judge row = case (load (TE.encodeUtf8 row.input) :: Either Text ReadinessFacts, row.outcome) of
  (Left refusal, Left rule)
    | maybe True (`T.isInfixOf` refusal) rule -> Nothing
    | otherwise -> mismatch ("refused for another rule " <> show rule) refusal
  (Left refusal, Right _) -> mismatch ("accepted" :: String) refusal
  (Right facts, Left rule) -> mismatch ("refused " <> show rule) (dump facts)
  (Right facts, Right (digest, expectation, liveness))
    | factsDigest /= digest -> mismatch ("facts dump " <> show digest) factsDigest
    | spelled verdict /= spelled expectation -> mismatch (BS8.unpack (spelled expectation)) (BS8.unpack (spelled verdict))
    | judged /= liveness -> mismatch liveness judged
    | otherwise -> Nothing
   where
    factsDigest = TE.decodeUtf8 (Base16.encode (SHA256.hash (spelled (dump facts))))
    expected = evaluate facts
    verdict = dump expected
    judged = [spell (evaluateLiveness expected environment budget) | environment <- environments, budget <- [False, True]]
 where
  mismatch :: (Show a, Show b) => a -> b -> Maybe String
  mismatch want got = Just (T.unpack row.input <> "\n  expected " <> show want <> "\n  got      " <> show got)

spec :: Spec
spec = describe "oracle corpus" $ do
  rows <- runIO $ do
    bytes <- BS.readFile "test/corpus/oracle.jsonl"
    traverse (either fail pure . (decodeRow <=< parseJson pythonLoads)) (filter (not . BS.null) (BS8.split '\n' bytes))
  let refused = [() | Row _ (Left _) <- rows]
      ruled = [() | Row _ (Left (Just _)) <- rows]
  it ("admission, facts dump, expectation, and liveness match every row (" <> show (length rows) <> ")") $ do
    let mismatches = [problem | row <- rows, Just problem <- [judge row]]
    unless (null mismatches) $
      expectationFailure (show (length mismatches) <> " mismatches, first:\n" <> unlines (take 8 mismatches))
  it "covers refusals, construction rules, and every disposition" $ do
    length refused `shouldSatisfy` (> 0)
    length ruled `shouldSatisfy` (> 0)
    let dispositions = [found | Row _ (Right (_, expectation, _)) <- rows, Just (String found) <- [member "disposition" expectation]]
    mapM_ (\d -> spell d `shouldSatisfy` (`elem` dispositions)) [minBound .. maxBound :: ReadinessDisposition]

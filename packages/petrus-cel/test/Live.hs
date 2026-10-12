-- | Live round trips through the pinned reference (not in the reference's
-- suite; the audit's IMP-4).
--
-- For every end-to-end case of @test/corpus/cel-instance.json@ (nets whose
-- guards, arc filters and completion conditions are inline CEL), the Net
-- definition and Net document Haskell projects from the compiled net, and
-- the History Haskell writes running the case on 'Petrus.Cel.Impetus.celCompilers',
-- are handed to the reference's own @parse_net_definition@,
-- @parse_net_document@ and @decode_record@, which must accept them and
-- serialize them back byte for byte ("Petrus.TestSupport.Reference").
--
-- The time-zone differential (the final audit's FA-K-1) hands
-- @test/tz-differential.py@ a random seed: the reference reads every tzdata
-- key, and keys mutated from zone names, at random instants and on both
-- sides of DST transitions, and Haskell must answer each one exactly as
-- cel-python did (values, or the whole rendered error).
--
-- The reference must be available: without it the group fails.
module Live
  ( spec
  ) where

import Control.Monad (forM, replicateM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec
import Test.QuickCheck (choose, generate)

import Impetus (caseSteps, celInstanceCases, startCelCase)
import Petrus.Cel (compile, evaluateJson, excReprStrict, valueRepr)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.NetDocument (projectNetDocument, serializeNetDocument)
import Petrus.Json
import Petrus.TestSupport.Python (python)
import Petrus.TestSupport.Reference

spec :: Spec
spec = do
  roundTripSpec
  timeZoneSpec

roundTripSpec :: Spec
roundTripSpec = describe "live round trip through the pinned reference" $
  it "accepts and rewrites byte for byte the CEL nets and the History Haskell writes running them" $ do
    cases <- celInstanceCases
    payloads <- fmap concat . forM cases $ \c -> do
      let name = case lookupMember "name" c of
            Just (String n) -> T.unpack n
            _ -> error "cel-instance case without a name"
      (net, inst) <- startCelCase c
      replicateM_ (length (caseSteps c)) (step inst Nothing >>= either (fail . T.unpack . renderInstanceError) (const (pure ())))
      history <- Store.records (instanceHistory inst)
      definition <- expectRight (projectNetDefinition net >>= serializeNetDefinition)
      document <- expectRight (projectNetDocument net Nothing Nothing >>= serializeNetDocument)
      records <- forM (zip [0 :: Int ..] history) $ \(i, r) ->
        (name <> " record " <> show i,HistoryRecordSubject,) <$> recordBytes (encodeRecord r)
      pure ((name <> " definition", NetDefinitionSubject, definition) : (name <> " document", NetDocumentSubject, document) : records)
    length payloads `shouldSatisfy` (> length cases * 3)
    shouldRoundTripThroughReference payloads

-- | One record as @json.dumps(encode_record(record))@ spells it.
recordBytes :: Json -> IO ByteString
recordBytes = either (fail . encodeErrorMessage) pure . dumps defaultDumps

expectRight :: Either Text a -> IO a
expectRight = either (fail . T.unpack) pure

timeZoneSpec :: Spec
timeZoneSpec = describe "time zones against the pinned reference" $
  it "reads every tzdata key and mutated keys at random instants and DST transitions as cel-python does" $ do
    seed <- generate (choose (0, 2 ^ (31 :: Int) - 1)) :: IO Int
    code <- TIO.readFile "test/tz-differential.py"
    out <- python code [show seed]
    program <- either (fail . show) pure (compile expression)
    let rows = BC.lines out
        disagreements =
          [ (key, at, want, got)
          | line <- rows
          , let (key, at, want) = row line
          , let got = case evaluateJson program [("s", String at), ("z", String key)] of
                  Right value -> valueRepr value
                  Left exc -> either (const "<repr raises>") id (excReprStrict exc)
          , got /= want
          ]
    length rows `shouldSatisfy` (> 15000)
    unless (null disagreements) $
      expectationFailure
        ( "seed "
            <> show seed
            <> ": "
            <> show (length disagreements)
            <> " of "
            <> show (length rows)
            <> " readings differ; the first ones (key, instant, reference, Haskell):\n"
            <> unlines (map show (take 10 disagreements))
        )
  where
    expression = "[timestamp(s).getFullYear(z), timestamp(s).getDayOfYear(z), timestamp(s).getHours(z), timestamp(s).getMinutes(z), timestamp(s).getSeconds(z)]"
    row line = case parseJson pythonJsonLoads line of
      Right (Array [String key, String at, String want]) -> (key, at, want)
      other -> error ("tz-differential.py printed an unexpected line: " <> show (BC.unpack line) <> " " <> show (fmap (const ()) other))

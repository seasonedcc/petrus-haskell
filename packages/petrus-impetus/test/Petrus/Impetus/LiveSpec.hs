-- | Live round trips through the pinned reference (not in the reference's
-- suite; the audit's IMP-4).
--
-- The committed corpora pin what the reference wrote once and check that
-- Haskell reads it. This group checks the other direction, live: what
-- /Haskell/ writes today, the reference's own
-- @parse_net_definition@, @parse_net_document@ and @decode_record@ accept,
-- and the reference's serializers write back byte for byte
-- ("Petrus.TestSupport.Reference"). The payloads are:
--
-- * Net definitions and Net documents Haskell projects and serializes from
--   generated nets (the round-trip properties' generators, a fixed seed),
--   with generated views;
-- * the Haskell re-serialization of every definition and document the
--   committed corpus admits (fixtures, mutations and fuzz), and of every
--   kernel-corpus net;
-- * the History every kernel-corpus script leaves when Haskell drives it,
--   the reference's @every_record_category@, and records whose token data
--   holds lone surrogates (IMP-2), each encoded by
--   'Petrus.Impetus.History.Codec.encodeRecord' and spelled as
--   @json.dumps@ spells it.
--
-- The reference must be available: without it the group fails.
module Petrus.Impetus.LiveSpec (spec) where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.History
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Impetus.Instance (instanceHistory)
import Petrus.Impetus.KernelDifferentialSpec (kernelCases, perform, startCase)
import Petrus.Impetus.NetDefinition
import Petrus.Impetus.NetDefinitionCorpusSpec (admittedPayloads)
import Petrus.Impetus.NetDefinitionPropertiesSpec (coordinate, nets, nodePaths)
import Petrus.Impetus.NetDocument
import Petrus.Impetus.Petrinet (Net, Number)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json
import Petrus.TestSupport.Reference
import Test.Hspec
import Test.QuickCheck (Gen, sublistOf, vectorOf)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)

spec :: Spec
spec = describe "live round trip through the pinned reference" $ do
  it "accepts and rewrites byte for byte the definitions and documents Haskell writes for generated nets" $ do
    let generated = unGen (vectorOf 200 viewed) (mkQCGen 20261011) 30
    payloads <- fmap concat . forM (zip [0 :: Int ..] generated) $ \(i, (net, view)) -> do
      definition <- expectRight (projectNetDefinition net >>= serializeNetDefinition)
      document <- expectRight (projectNetDocument net (Just view) Nothing >>= serializeNetDocument)
      pure
        [ ("generated net " <> show i <> " definition", NetDefinitionSubject, definition)
        , ("generated net " <> show i <> " document", NetDocumentSubject, document)
        ]
    shouldRoundTripThroughReference payloads

  it "accepts and rewrites byte for byte Haskell's rewrite of every definition and document the corpus admits" $ do
    admitted <- admittedPayloads
    length admitted `shouldSatisfy` (>= 150)
    payloads <- forM admitted $ \(name, kind, bytes) -> case kind of
      "definition" -> (T.unpack name,NetDefinitionSubject,) <$> expectRight (parseNetDefinition bytes >>= serializeNetDefinition)
      _ -> (T.unpack name,NetDocumentSubject,) <$> expectRight (parseNetDocument bytes >>= serializeNetDocument)
    shouldRoundTripThroughReference payloads

  it "accepts and rewrites byte for byte every kernel-corpus net and the History Haskell writes driving it" $ do
    cases <- kernelCases
    payloads <- fmap concat . forM cases $ \c -> do
      let name = T.unpack (caseName c)
      (net, inst) <- startCase c
      mapM_ (perform inst) [action | Object step <- walkOf c, Just action <- [lookup "action" step]]
      history <- Store.records (instanceHistory inst)
      definition <- definitionBytes net
      records <- forM (zip [0 :: Int ..] history) $ \(i, r) -> (name <> " record " <> show i,HistoryRecordSubject,) <$> recordBytes r
      pure ((name <> " definition", NetDefinitionSubject, definition) : records)
    length payloads `shouldSatisfy` (> length cases * 3)
    shouldRoundTripThroughReference payloads

  it "accepts and rewrites byte for byte every record category and lone-surrogate token data" $ do
    payloads <- forM (zip [0 :: Int ..] (everyRecordCategory <> surrogateRecords)) $ \(i, r) ->
      ("record " <> show i <> " (" <> T.unpack (recordName r) <> ")",HistoryRecordSubject,) <$> recordBytes r
    shouldRoundTripThroughReference payloads

-- | A generated net and a view over some of its nodes.
viewed :: Gen (Net, [(Text, (Number, Number))])
viewed = do
  net <- nets
  nodes <- sublistOf (nodePaths net)
  xys <- vectorOf (length nodes) ((,) <$> coordinate <*> coordinate)
  pure (net, zip nodes xys)

caseName :: Json -> Text
caseName c = case lookupMember "name" c of
  Just (String name) -> name
  _ -> error "kernel corpus case without a name"

walkOf :: Json -> [Json]
walkOf c = case lookupMember "walk" c of
  Just (Array steps) -> steps
  _ -> []

definitionBytes :: Net -> IO ByteString
definitionBytes net = expectRight (projectNetDefinition net >>= serializeNetDefinition)

-- | One record as @json.dumps(encode_record(record))@ spells it.
recordBytes :: Record -> IO ByteString
recordBytes r = either (fail . encodeErrorMessage) pure (dumps defaultDumps (encodeRecord r))

-- | Token data holding lone surrogates in a string and in a member name
-- (WTF-8 'Text', "Petrus.Json.Wtf8"), which History keeps as the
-- reference does.
surrogateRecords :: [Record]
surrogateRecords =
  [ RTokensProduced (TokensProduced (np "p") [tokD "A" (String (fromCodePoints "a\xD800"))] 1 [] Nothing 2)
  , RTokensProduced (TokensProduced (np "p") [tokD "A" (Object [(fromCodePoints "\xDC00z", Int 1)])] 1 [] Nothing 2)
  , RExternalEventDelivered
      (ExternalEventDelivered (np "t") [tokD "A" (Array [String (fromCodePoints "\xDBFF"), String "😀"])] "occurrence-s" 1 Nothing 1)
  ]

expectRight :: Either Text a -> IO a
expectRight = either (fail . T.unpack) pure

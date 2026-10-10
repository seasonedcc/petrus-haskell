-- | Loaded nets as kernel nets ("Petrus.EngineFile.Kernel").
module Petrus.EngineFile.KernelSpec (spec) where

import Control.Monad (forM, forM_)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.EngineFile
import Petrus.EngineFile.Corpus (Case (..), Op (..), readCorpus)
import Petrus.EngineFile.CorpusSpec (corpusPath)
import Petrus.EngineFile.LiveSpec (repoRoot)
import Petrus.Impetus.Petrinet.Schema qualified as K
import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | A one-file net through @from_dict@, @to_schema@ and 'toKernel'.
kernelOf :: BS.ByteString -> Either KernelError KernelNet
kernelOf bytes = case loads bytes >>= \v -> loadDict v [] >>= toSchema of
  Left e -> Left (LoadError e)
  Right schema -> either (Left . KernelError) Right (toKernel schema)

refusal :: Either KernelError KernelNet -> Maybe Text
refusal = \case
  Left (KernelError message) -> Just message
  _ -> Nothing

accepted :: Either KernelError KernelNet -> KernelNet
accepted = \case
  Right k -> k
  Left e -> error ("refused: " <> show e)

spec :: Spec
spec = describe "kernel nets" $ do
  it "converts the viewer's sample net" $ do
    root <- maybe (fail "no repository root") pure =<< repoRoot
    result <- loadKernelFile (T.pack (root </> "upstream/petrus-viewer/examples/sample-net.json"))
    let k = accepted result
    K.netName k.net `shouldBe` Just "order_system"
    length (K.netPlaceOrder k.net) `shouldBe` 11
    length (K.netTransitionOrder k.net) `shouldBe` 8
    length (K.netArcs k.net) `shouldBe` 20
    k.marking
      `shouldBe` [ ("order_system.fulfillment.stock", 3)
                 , ("order_system.fulfillment.waiting", 1)
                 , ("order_system.payment.pending", 1)
                 ]
    let pick = "order_system.fulfillment.pick_items"
    map (\a -> (a.source, a.mode, a.weight)) (K.inputs k.net pick)
      `shouldBe` [ ("order_system.fulfillment.stock", K.Consume, 2)
                 , ("order_system.fulfillment.waiting", K.Consume, 1)
                 , ("order_system.payment.authorized", K.Read, 1)
                 , ("order_system.payment.failed", K.Inhibit, 1)
                 ]
    map (\a -> a.target) (K.outputs k.net pick) `shouldBe` ["order_system.fulfillment.items_ready"]
    fmap (\t -> t.handler) (K.lookupTransition pick k.net) `shouldBe` Just (Just (K.HandlerSymbol "pick_items"))
    fmap (\t -> t.guards) (K.lookupTransition "order_system.payment.on_approved" k.net)
      `shouldBe` Just [K.GuardSymbol "is_approved"]

  it "keeps the schema's absolute paths, refs inlined" $ withSystemTempDirectory "petrus-kernel" $ \dir -> do
    BS.writeFile (dir </> "sub.json") "{\"net\": \"sub\", \"places\": {\"q\": {\"initial\": 2}}, \"transitions\": {\"t\": {\"handler\": \"h\"}}, \"arcs\": [{\"source\": \"q\", \"target\": \"t\"}]}"
    BS.writeFile (dir </> "main.json") "{\"net\": \"m\", \"refs\": {\"a\": {\"ref\": \"sub.json\"}}, \"places\": {\"p\": {}}, \"arcs\": [{\"source\": \"a.t\", \"target\": \"p\"}]}"
    k <- accepted <$> loadKernelFile (T.pack (dir </> "main.json"))
    K.netPlaceOrder k.net `shouldBe` ["m.p", "m.a.q"]
    K.netTransitionOrder k.net `shouldBe` ["m.a.t"]
    k.marking `shouldBe` [("m.a.q", 2)]

  it "turns delays into seconds" $ do
    let k = accepted (kernelOf "{\"net\": \"m\", \"places\": {\"p\": {}}, \"transitions\": {\"t\": {\"delay\": 90}, \"u\": {\"delay\": \"PT1.5S\"}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\"}, {\"source\": \"p\", \"target\": \"u\"}]}")
    fmap (\t -> t.timers) (K.lookupTransition "m.t" k.net) `shouldBe` Just [K.Delay (K.IntNumber 90)]
    fmap (\t -> t.timers) (K.lookupTransition "m.u" k.net) `shouldBe` Just [K.Delay (K.FloatNumber 1.5)]

  it "collapses repeated arcs as the schema's (source, target) dict does" $ do
    let k = accepted (kernelOf "{\"net\": \"m\", \"places\": {\"p\": {}}, \"transitions\": {\"t\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\"}, {\"source\": \"p\", \"target\": \"t\", \"weight\": 3}]}")
    map (\a -> a.weight) (K.netArcs k.net) `shouldBe` [3]

  describe "refuses what the kernel refuses, with its messages" $ do
    let refused input = refusal (kernelOf input)
    it "an inhibitor output arc" $
      refused "{\"net\": \"m\", \"places\": {\"p\": {}, \"q\": {}}, \"transitions\": {\"t\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\"}, {\"source\": \"t\", \"target\": \"q\", \"kind\": \"inhibitor\"}]}"
        `shouldBe` Just "mode on output arc m.t -> m.q: modes are input inscriptions"
    it "an arc between two places" $
      fmap (T.isPrefixOf "arc must connect a place and a transition") (refused "{\"net\": \"m\", \"places\": {\"p\": {}, \"q\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"q\"}]}")
        `shouldBe` Just True
    it "a zero weight" $
      fmap (T.isPrefixOf "arc weight must be an integer >= 1, got 0") (refused "{\"net\": \"m\", \"places\": {\"p\": {}}, \"transitions\": {\"t\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\", \"weight\": 0}]}")
        `shouldBe` Just True
    it "a weight beyond Int" $
      refused "{\"net\": \"m\", \"places\": {\"p\": {}}, \"transitions\": {\"t\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\", \"weight\": 100000000000000000000}]}"
        `shouldBe` Just "arc weight 100000000000000000000 does not fit the kernel's Int: m.p -> m.t"
    it "a handlerless transition that only reads" $
      fmap (T.isInfixOf "would fire forever") (refused "{\"net\": \"m\", \"places\": {\"p\": {}}, \"transitions\": {\"t\": {}}, \"arcs\": [{\"source\": \"p\", \"target\": \"t\", \"kind\": \"read\"}]}")
        `shouldBe` Just True
    it "a guard on a source transition" $
      fmap (T.isInfixOf "guards on a source transition") (refused "{\"net\": \"m\", \"transitions\": {\"t\": {\"guard\": \"g\"}}}")
        `shouldBe` Just True

  it "keeps petrus-engine's refusals" $
    either (\case LoadError e -> e.exceptionClass; KernelError _ -> "kernel") (const "accepted") (kernelOf "{\"net\": 5}")
      `shouldBe` "ValidationError"

  it "every corpus net petrus-engine loads is a kernel net with its nodes and arcs, or a kernel refusal" $ do
    cases <- corpusPath >>= readCorpus
    converted <- newIORef (0 :: Int)
    results <- forM cases $ \c -> do
      let loadPaths = [p | LoadOp p <- c.ops]
      if null loadPaths
        then pure Nothing
        else withSystemTempDirectory "petrus-kernel-corpus" $ \dir -> do
          forM_ c.dirs $ \d -> createDirectoryIfMissing True (dir </> T.unpack d)
          forM_ c.files $ \(path, bytes) -> do
            let target = dir </> T.unpack path
            createDirectoryIfMissing True (takeDirectory target)
            BS.writeFile target bytes
          withCurrentDirectory dir $ fmap (Just . concat) $ forM loadPaths $ \path -> do
            schema <- fmap (>>= toSchema) (loadFile path)
            kernel <- loadKernelFile path
            case (schema, kernel) of
              (Left e, Left (LoadError e')) | e == e' -> pure []
              (Right s, Right k) -> do
                modifyIORef' converted (+ 1)
                let same =
                      length (K.netPlaceOrder k.net) == length s.places
                        && length (K.netTransitionOrder k.net) == length s.transitions
                        && length (K.netArcs k.net) == length s.arcs
                        && length k.marking == length [() | (_, d) <- s.places, d.initial > 0]
                pure [c.name <> ": nodes or arcs differ" | not same]
              (Right _, Left (KernelError message)) | not (T.null message) -> pure []
              _ -> pure [c.name <> ": the kernel path disagrees with the loader"]
    concat (catMaybes results) `shouldBe` []
    readIORef converted >>= (`shouldSatisfy` (> 50))

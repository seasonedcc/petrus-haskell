-- | JSONL interop with the pinned reference: files written by either
-- implementation load in the other value-equal and byte-stable, and an
-- Instance begun in one resumes and completes in the other.
--
-- Runs @test/interop/jsonl_interop.py@ under @upstream/petrus/.venv@; the
-- examples are pending when that environment is not synced.
module Petrus.HistoryStore.InteropSpec (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Activity (invocation)
import Petrus.HistoryStore.Jsonl
import Petrus.HistoryStore.Support
import Petrus.Impetus.Binding
import Petrus.Impetus.History (Record)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.TestSupport (expectRight, field, netOf, np, tokD)
import Petrus.Json (Json (..), lookupMember)
import System.FilePath ((</>))
import Test.Hspec

script :: FilePath
script = "test/interop/jsonl_interop.py"

intake, queue, work, out :: NetPath
intake = np "intake"
queue = np "queue"
work = np "work"
out = np "out"

-- | The reference's @Charge@ ActivityHandler, with a prepare that refuses
-- if consulted when the record must supply the invocation.
charge :: Bool -> ActivityHandler
charge mayPrepare =
  ActivityHandler
    { prepare = \b ->
        if not mayPrepare
          then Left "prepare re-ran: the record should have supplied the invocation"
          else case bindingTokens b of
            [issue] -> do
              amount <- field "amount" issue
              Right (invocation "charge_card" (Object [("amount", amount)]))
            other -> Left ("expected one issue, got " <> T.pack (show other))
    , project = \_ result -> case lookupMember "status" result of
        Just s -> Right (handlerTokens [(out, [tokD "Receipt" (Object [("status", s)])])])
        Nothing -> Left "KeyError('status')"
    , projectFailure = Nothing
    }

config :: Bool -> InstanceConfig
config mayPrepare = defaultInstanceConfig {handlerImplementations = Map.fromList [(Symbol "charge", ActivityBound (charge mayPrepare))]}

activityNet :: Net
activityNet =
  netOf
    [place queue, place out]
    [transition intake, Transition work (Just (HandlerSymbol "charge")) [] []]
    [arc intake queue, arc queue work, arc work out]

receipt :: Marking
receipt = markingFromList [(out, [tokD "Receipt" (Object [("status", String "captured")])])]

reencoded :: [Record] -> BS.ByteString
reencoded = BS.concat . map (\r -> either (error . T.unpack) (<> "\n") (encodeLine r))

spec :: Spec
spec = describe "JSONL interop with the reference" $ do
  it "a file the reference wrote loads value-equal and re-encodes byte-identical" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let path = dir </> "history.jsonl"
    _ <- runPython python script ["write-every", path]
    loaded <- openJsonlHistoryStore path >>= Store.records
    loaded `shouldBe` everyRecordCategory
    BS.readFile path `shouldReturn` reencoded loaded

  it "a file Haskell wrote loads value-equal in the reference and re-encodes byte-identical" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let path = dir </> "history.jsonl"
    openJsonlHistoryStore path >>= \s -> s.extend everyRecordCategory
    _ <- runPython python script ["verify-every", path]
    pure ()

  it "an Instance the reference began resumes in Haskell and the reference reads the result" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let path = dir </> "history.jsonl"
    _ <- runPython python script ["begin", path]
    store <- openJsonlHistoryStore path
    resumed <- resume activityNet store (config False) >>= expectRight
    [occurrence] <- inFlight resumed
    _ <- recordActivityCompletion resumed occurrence (Object [("status", String "captured")]) (Just 3) >>= expectRight
    _ <- complete resumed occurrence Nothing (Just 4) >>= expectRight
    marking resumed `shouldReturn` receipt
    count <- Store.size (instanceHistory resumed)
    out' <- runPython python script ["inspect", path]
    words out' `shouldBe` [show count]
    _ <- runPython python script ["verify-bytes", path]
    pure ()

  it "an Instance Haskell began resumes in the reference and Haskell reads the result" $ pythonOrPending $ \python -> withScratch $ \dir -> do
    let path = dir </> "history.jsonl"
    store <- openJsonlHistoryStore path
    inst <- newInstance activityNet (config True) {historyStore = Just store, suppliedIdentity = Just "interop-1"} >>= expectRight
    DeliveryAccepted accepted <- acceptDelivery inst intake [tokD "Payment" (Object [("amount", Int 100)])] "evt_123" Nothing (Just 1) >>= expectRight
    _ <- completeDelivery inst accepted (Just 1) >>= expectRight
    (b : _) <- candidates inst
    _ <- begin inst b (Just 2) >>= expectRight
    _ <- runPython python script ["finish", path]
    back <- openJsonlHistoryStore path >>= \s -> resume activityNet s (config False) >>= expectRight
    marking back `shouldReturn` receipt
    watermark back `shouldReturn` 4
    inFlight back `shouldReturn` []
    loaded <- Store.records (instanceHistory back)
    BS.readFile path `shouldReturn` reencoded loaded

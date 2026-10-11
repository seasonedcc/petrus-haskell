{-# LANGUAGE OverloadedRecordDot #-}

-- | Replays @test/corpus/webhooks.jsonl@ (scripts/gen_webhook_corpus.py):
-- webhook receipt, the inbox lifecycle and the routing registry, step by
-- step, then compares every stored SQLite row byte for byte.
module WebhookCorpusSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM_, zipWithM_)
import Data.ByteString.Base64 qualified as B64
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Corpus
import Hamsterdan.Contracts.Codec (dump)
import Hamsterdan.GitHub.Config (AccountConfig (..))
import Hamsterdan.GitHub.Models (InstallationInventory (..))
import Hamsterdan.GitHub.Python (PythonFault (..))
import Hamsterdan.GitHub.Routing (InventoryMismatch (..), Route (..))
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.Sqlite (SQLData (..))
import Hamsterdan.Sqlite qualified as Db
import Hamsterdan.GitHub.Webhooks
import Petrus.Json (Json (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec = describe "webhook, inbox and routing corpus" $ do
  rows <- runIO (readCorpus "webhooks.jsonl")
  let byKind kind = filter (\row -> field "kind" row == String kind) rows
  forM_ ["receive", "inbox", "routing"] $ \kind ->
    it (T.unpack kind <> " cases reproduce every outcome and stored row (" <> show (length (byKind kind)) <> " cases)") $ do
      mismatches <- newIORef []
      forM_ (zip [0 :: Int ..] (byKind kind)) $ \(index, row) -> replay mismatches (T.unpack kind <> " #" <> show index) row
      readIORef mismatches >>= expectNone

accountsOf :: Json -> [AccountConfig]
accountsOf row =
  [ AccountConfig (intOf a) (textOf login) [(intOf i, textOf n) | Array [i, n] <- listOf repos]
  | Array [a, login, repos] <- listOf (field "accounts" row)
  ]

replay :: Mismatches -> String -> Json -> IO ()
replay mismatches context row = withSystemTempDirectory "webhooks" $ \directory -> do
  now <- newIORef (100 :: Double)
  registry <-
    if boolOf (field "registry" row)
      then Just <$> Routing.openRegistry (directory </> "r.db") (accountsOf row)
      else pure Nothing
  custody <-
    openCustody
      (directory </> "w.db")
      (textOf (field "secret" row))
      CustodyOptions {registry, maximumBodyBytes = fromInteger (intOf (field "maximum" row)), clock = readIORef now}
  let steps = listOf (field "steps" row)
      expected = listOf (field "results" row)
  zipWithM_
    ( \(index, step) result -> do
        actual <- apply custody registry (writeIORef now) step
        checkJson mismatches (context <> " step " <> show (index :: Int) <> " " <> T.unpack (canonical step)) result actual
    )
    (zip [0 ..] steps)
    expected
  closeCustody custody
  mapM_ Routing.closeRegistry registry
  inbox <- dumpRows (directory </> "w.db") "SELECT delivery_id,event,observation,status,attempts,reason,error_class,next_attempt_at FROM inbox ORDER BY rowid"
  checkJson mismatches (context <> " inbox rows") (field "inbox" row) inbox
  case registry of
    Nothing -> pure ()
    Just _ -> do
      installations <- dumpRows (directory </> "r.db") "SELECT * FROM installations ORDER BY installation_id"
      repositories <- dumpRows (directory </> "r.db") "SELECT * FROM repositories ORDER BY installation_id, repository_id"
      checkJson mismatches (context <> " installations") (field "installations" row) installations
      checkJson mismatches (context <> " repositories") (field "repositories" row) repositories

dumpRows :: FilePath -> Text -> IO Json
dumpRows path sql = do
  connection <- Db.open (T.pack path)
  rows <- Db.query connection sql []
  Db.close connection
  pure (Array [Array (map cell r) | r <- rows])
  where
    cell = \case
      SQLInteger n -> Int (toInteger n)
      SQLFloat d -> Float d
      SQLText t -> String t
      SQLNull -> Null
      SQLBlob _ -> String "<blob>"

subjectOf :: Json -> (Integer, Integer, Integer)
subjectOf value = case listOf value of
  [a, b, c] -> (intOf a, intOf b, intOf c)
  _ -> error "corpus: subject"

apply :: WebhookCustody -> Maybe Routing.InstallationRegistry -> (Double -> IO ()) -> Json -> IO Json
apply custody registry setClock step = case textOf (field "op" step) of
  "receive" -> do
    let headers = [(textOf name, textOf value) | Array [name, value] <- listOf (field "headers" step)]
        body = either error id (B64.decode (TE.encodeUtf8 (textOf (field "body" step))))
    outcome <- try (receive custody headers body)
    pure $ case outcome of
      Right receipt ->
        Object $
          [ ("outcome", String "receipt")
          , ("delivery_id", String receipt.deliveryId)
          , ("disposition", String (dispositionName receipt.disposition))
          , ("observation", maybe Null (String . encodeObservation) receipt.observation)
          ]
            <> case receipt.observation of
              Nothing -> []
              Just item -> [("admitted", maybe Null dump (admitConversation "hamster-dan" "hamster-dan[bot]" item))]
      Left (e :: SomeException)
        | Just (WebhookRejected reason) <- fromException e -> Object [("outcome", String "rejected"), ("reason", String reason)]
        | Just (PythonFault cls _) <- fromException e -> Object [("outcome", String "error"), ("class", String cls)]
        | otherwise -> Object [("outcome", String "haskell-exception"), ("detail", String (T.pack (show e)))]
  "pending" -> do
    let subject = case field "subject" step of
          Null -> Nothing
          value -> Just (subjectOf value)
    items <- pending custody (fromInteger (intOf (field "limit" step))) subject
    pure (Array (map observationJson items))
  "has_pending" -> Bool <$> hasPending custody (subjectOf (field "subject" step))
  "eligible" -> Bool <$> eligible custody (textOf (field "delivery" step)) (subjectOf (field "subject" step))
  "acknowledge" -> Null <$ acknowledge custody (textOf (field "delivery" step)) (textOf (field "reason" step))
  "retry" -> Null <$ retry custody (textOf (field "delivery" step)) (ErrorClass (textOf (field "error" step)))
  "status" -> maybe Null String <$> status custody (textOf (field "delivery" step))
  "counts" -> Object . map (\(k, v) -> (k, Int (toInteger v))) . Map.toList <$> counts custody
  "failures" -> do
    items <- failures custody (fromInteger (intOf (field "limit" step)))
    pure $
      Array
        [ Object
            [ ("delivery_id", String item.deliveryId)
            , ("event", String item.event)
            , ("attempts", Int (toInteger item.attempts))
            , ("error_class", maybe Null String item.errorClass)
            , ("reason", maybe Null String item.reason)
            ]
        | item <- items
        ]
  "requeue" -> Bool <$> requeue custody (textOf (field "delivery" step))
  "clock" -> Null <$ setClock (case field "now" step of Float d -> d; Int i -> fromInteger i; _ -> 0)
  op -> case registry of
    Nothing -> error "corpus: routing step without a registry"
    Just routes -> routing routes op step

routing :: Routing.InstallationRegistry -> Text -> Json -> IO Json
routing routes op step = do
  outcome <- try $ case op of
    "installation" -> Bool <$> Routing.installation routes (field "action" step) (field "installation_id" step) (field "account_id" step)
    "repositories" ->
      Bool
        <$> Routing.repositories
          routes
          (field "action" step)
          (field "installation_id" step)
          (field "account_id" step)
          [(a, b) | Array [a, b] <- listOf (field "repositories" step)]
    "route" -> do
      found <- Routing.route routes (intOf (field "installation_id" step)) (intOf (field "repository_id" step))
      pure $ case found of
        Nothing -> Null
        Just r -> Array [Int r.installationId, Int r.accountId, Int r.repositoryId, String r.repositoryFullName]
    "reconcile" -> do
      let inventory =
            [ InstallationInventory (intOf a) (intOf b) [(intOf i, textOf n) | Array [i, n] <- listOf repos]
            | Array [a, b, repos] <- listOf (field "inventory" step)
            ]
      Int . toInteger <$> Routing.reconcile routes inventory
    "active_count" -> Int . toInteger <$> Routing.activeCount routes
    "active_installation_count" -> Int . toInteger <$> Routing.activeInstallationCount routes
    other -> error ("corpus: unknown op " <> show other)
  pure $ case outcome of
    Right value -> value
    Left (e :: SomeException)
      | Just (PythonFault cls detail) <- fromException e -> pythonError cls detail
      | Just (InventoryMismatch message) <- fromException e -> pythonError "ValueError" message
      | otherwise -> Object [("haskell-exception", String (T.pack (show e)))]
  where
    pythonError cls message = Object [("error", String cls), ("message", String message)]

-- | The territory custody ledger against the reference's own output
-- (@differential/retention_corpus.json@ and @retention_fixture.db@):
--
-- * the schema text in @sqlite_master@;
-- * a reference-written ledger opened and decoded;
-- * the capability encoding written by a release;
-- * @_decode@ and @_salvage_corrupt@ over mutated rows that SQLite read back;
-- * live, both ways (@differential/retention_interop.py@): a ledger written by
--   each language, with a record in every durable phase, an expiring record
--   and a corrupted one, opened by the other language, whose @lookup@ of
--   every row, @records()@, @recover()@ and @records()@ again must equal the
--   writer's own reading of the same bytes.
module Petrus.Agenticus.RetentionDifferentialSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM, forM_, void)
import Data.ByteString qualified as B
import Data.ByteString.Base16 qualified as Hex
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Attachment.Retention
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Resolution
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.TestSupport
import Petrus.Agenticus.Thread.Identity
import Petrus.Json (Json (..))
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import Data.IORef (newIORef, readIORef, writeIORef)
import Petrus.TestSupport.Python (pythonJson)
import System.Directory (createDirectory, copyFile, makeAbsolute)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec

type View =
  ( (Text, Text, Integer, Text)
  , (Text, Text, Integer)
  , (Text, Text, Text, [Text])
  , Double
  , (Maybe Text, Maybe Text)
  , (Maybe Text, Maybe Text, Maybe Integer)
  , Maybe Text
  )

recordView :: TerritoryCustodyRecord -> View
recordView r =
  ( (r.custodyId, r.ownerId, r.generation, phaseText r.phase)
  , (r.source.episodeId, r.source.attachmentId, r.source.attachmentEpoch)
  , ( leaseOperationId r.lease
    , leaseProvider r.lease
    , leaseId r.lease
    , [capabilityKey c | c <- foldr (:) [] (leaseCapabilities r.lease)]
    )
  , r.retainUntil
  , (TE.decodeUtf8 . Hex.encode <$> r.archive, r.archiveDigest)
  , (r.targetEpisodeId, r.targetAttachmentId, r.targetEpoch)
  , cleanupDispositionText <$> r.cleanup
  )

expectedView :: Json -> View
expectedView j =
  ( (text (member "custody_id" j), text (member "owner_id" j), int (member "generation" j), text (member "phase" j))
  , case items (member "source" j) of
      [e, a, n] -> (text e, text a, int n)
      _ -> error "bad source"
  , case items (member "lease" j) of
      [o, p, l, cs] -> (text o, text p, text l, map text (items cs))
      _ -> error "bad lease"
  , real (text (member "retain_until" j))
  , (optionalText (member "archive" j), optionalText (member "archive_digest" j))
  , case items (member "target" j) of
      [e, a, n] -> (optionalText e, optionalText a, case n of Null -> Nothing; other -> Just (int other))
      _ -> error "bad target"
  , optionalText (member "cleanup" j)
  )

items :: Json -> [Json]
items = \case
  Array xs -> xs
  other -> error ("expected an array, got " <> show other)

text :: Json -> Text
text = \case
  String t -> t
  other -> error ("expected a string, got " <> show other)

optionalText :: Json -> Maybe Text
optionalText = \case
  Null -> Nothing
  other -> Just (text other)

int :: Json -> Integer
int = \case
  Int n -> n
  other -> error ("expected an int, got " <> show other)

-- | Python's @repr(float)@ back to a 'Double'.
real :: Text -> Double
real = \case
  "inf" -> 1 / 0
  "-inf" -> -1 / 0
  value -> read (T.unpack (T.replace "e+" "e" (if "." `T.isInfixOf` value || "e" `T.isInfixOf` value then value else value <> ".0")))

sqlValue :: Json -> SqlValue
sqlValue j = case text (member "t" j) of
  "null" -> SQLNull
  "int" -> SQLInteger (fromInteger (int (member "v" j)))
  "real" -> SQLFloat (real (text (member "v" j)))
  "text" -> SQLText (text (member "v" j))
  "blob" -> SQLBlob (unhex (text (member "hex" j)))
  other -> error ("unknown cell type " <> T.unpack other)

unhex :: Text -> B.ByteString
unhex = either (error . show) id . Hex.decode . TE.encodeUtf8

cellJson :: SqlValue -> Json
cellJson = \case
  SQLText t -> String t
  SQLInteger n -> Int (toInteger n)
  SQLNull -> Null
  SQLFloat d -> Float d
  SQLBlob b -> String (TE.decodeUtf8 (Hex.encode b))

rawRows :: FilePath -> Text -> IO [[SqlValue]]
rawRows path' sql = do
  db <- openDatabase path'
  rows' <- queryRows db sql []
  closeDatabase db
  pure rows'

-- | A private ledger directory inside a temporary root.
withLedgerDir :: (FilePath -> IO a) -> IO a
withLedgerDir action = withSystemTempDirectory "retention-differential" $ \tmp -> do
  let dir = tmp </> "custody"
  createDirectory dir
  setFileMode dir 0o700
  action dir

snapshot :: Text -> ResolutionSnapshot
snapshot suffix =
  either (error . show) id $
    mkResolutionSnapshot
      1
      [ capabilityDescriptor (descriptorIdentity kind (kindText kind <> "-" <> suffix) 1) [] []
      | kind <- [KindRuntime, KindHands, KindTerritory]
      ]

spec :: Spec
spec = describe "differential/retention_corpus.json" $ do
  corpus <- runIO (loadJson "differential/retention_corpus.json")

  it "a fresh ledger's sqlite_master and table_info are the reference's, byte for byte" $ withLedgerDir $ \dir -> do
    let path' = dir </> "territories.db"
    openTerritoryCustody path' >>= closeTerritoryCustody
    master <- rawRows path' "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY rowid"
    info <- rawRows path' "PRAGMA table_info(territory_custody)"
    let schema = member "schema" corpus
    show (map (Array . map cellJson) master) `shouldBe` show (items (member "sqlite_master" schema))
    show (map (Array . map cellJson) info) `shouldBe` show (items (member "table_info" schema))

  it "opens a reference-written ledger and decodes every record exactly" $ withLedgerDir $ \dir -> do
    let path' = dir </> "territories.db"
    copyFile "differential/retention_fixture.db" path'
    setFileMode path' 0o600
    custody <- openTerritoryCustodyWith path' (pure 20)
    decoded <- records custody
    closeTerritoryCustody custody
    let expected = items (member "fixture_records" corpus)
    length expected `shouldBe` 5
    map recordView decoded `shouldBe` map expectedView expected

  it "a release writes the reference's compact sorted capability JSON" $ withLedgerDir $ \dir -> do
    let fixturePath = dir </> "fixture.db"
    copyFile "differential/retention_fixture.db" fixturePath
    reference <- rawRows fixturePath "SELECT capabilities FROM territory_custody WHERE custody_id='custody-releasing'"
    provider <- localProvider <$> newLocalProcessEnvironment
    let sourceDir = dir </> "source"
    createDirectory sourceDir
    writeFile (sourceDir </> "canary.txt") "fixture"
    archive' <- workspaceArchive sourceDir
    binding <- openMotusBinding provider "operation-haskell" defaultSpec archive' "initial"
    attachment <-
      newEpisodeAttachment
        (either (error . show) id (mkEpisodeId "episode-haskell"))
        (snapshot "haskell")
        (motusBinding binding)
        "attachment-haskell"
        100
        episodeOptions {Episode.attachmentEpoch = 3}
    let path' = dir </> "territories.db"
    custody <- openTerritoryCustodyWith path' (pure 10)
    void (beginRelease custody "custody-releasing" "host-one" attachment 50)
    void (recover custody)
    void (retire custody "custody-releasing" "host-one" provider)
    closeTerritoryCustody custody
    written <- rawRows path' "SELECT capabilities FROM territory_custody WHERE custody_id='custody-releasing'"
    -- Retirement keeps the capability column; compare it with the
    -- reference's release-time text.
    written `shouldBe` reference

  describe "live interop: each language's ledger, read by the other" $ do
    it "the reference opens a Haskell-written ledger and decodes, lists and recovers it as Haskell does" $ withLedgerDir $ \dir -> do
      writeHaskellLedger dir
      let original = dir </> "territories.db"
      ours <- privateCopy original (dir </> "haskell-reader") >>= readLedger 20
      theirs <- privateCopy original (dir </> "python-reader") >>= \copy' -> referenceInterop ["read", copy', "20"]
      readingOf theirs `shouldBe` ours
      -- Every durable phase was written, and one row is corrupt.
      [phase' | (_, Right (_, (_, _, _, phase'), _, _, _, _, _, _)) <- lookupsOf ours]
        `shouldMatchList` ["releasing", "retained", "retained", "claiming", "attached", "retiring", "retired"]
      length [() | (_, Left _) <- lookupsOf ours] `shouldBe` 1

    it "Haskell opens a fresh reference-written ledger and decodes, lists and recovers it as the reference does" $ withLedgerDir $ \dir -> do
      theirs <- referenceInterop ["write", dir]
      ours <- readLedger 20 (dir </> "territories.db")
      ours `shouldBe` readingOf theirs
      [phase' | (_, Right (_, (_, _, _, phase'), _, _, _, _, _, _)) <- lookupsOf ours]
        `shouldMatchList` ["releasing", "retained", "retained", "claiming", "attached", "retiring", "retired"]
      length [() | (_, Left _) <- lookupsOf ours] `shouldBe` 1

  it "_decode and _salvage_corrupt agree with the reference on every mutated row" $ do
    let cases = items (member "rows" corpus)
    (length cases > 1000) `shouldBe` True
    forM_ cases $ \entry -> do
      let row = map sqlValue (items (member "row" entry))
          expectedDecode = case lookupMember "record" entry of
            Just r -> Right (expectedView r)
            Nothing -> Left (text (member "error" entry))
          actualDecode = case decodeCustodyRow row of
            Right r -> Right (recordView r)
            Left e -> Left e.errorMessage
      (show (map cellJson row), actualDecode, phaseText (salvagePhase row))
        `shouldBe` (show (map cellJson row), expectedDecode, text (member "salvage" entry))
  where
    lookupMember key = \case
      Object members -> lookup key members
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- Live interop

-- | A ledger reading: each row's @lookup@, @records()@, @recover()@, and
-- @records()@ again; a refusal is its error text.
type Reading =
  ( [(Text, Either Text (Text, View))]
  , Either Text [View]
  , Either Text [View]
  , Either Text [View]
  )

lookupsOf :: Reading -> [(Text, Either Text (Text, (Text, Text, Integer, Text), (Text, Text, Integer), (Text, Text, Text, [Text]), Double, (Maybe Text, Maybe Text), (Maybe Text, Maybe Text, Maybe Integer), Maybe Text))]
lookupsOf (lookups, _, _, _) = [(custody, fmap flatten found) | (custody, found) <- lookups]
  where
    flatten (custody, (a, b, c, d, e, f, g)) = (custody, a, b, c, d, e, f, g)

-- | The reading the reference printed.
readingOf :: Json -> Reading
readingOf j =
  ( [ ( text (member "custody_id" entry)
      , case lookupMember' "record" entry of
          Just r -> Right (text (member "custody_id" r), expectedView r)
          Nothing -> Left (text (member "error" entry))
      )
    | entry <- items (member "lookups" j)
    ]
  , outcomeOf (member "before" j)
  , outcomeOf (member "recovered" j)
  , outcomeOf (member "after" j)
  )
  where
    outcomeOf o = case lookupMember' "records" o of
      Just rs -> Right (map expectedView (items rs))
      Nothing -> Left (text (member "error" o))

lookupMember' :: Text -> Json -> Maybe Json
lookupMember' key = \case
  Object members -> lookup key members
  _ -> Nothing

-- | The Haskell ledger's reading, at a fixed clock. Only a 'StorageError' is
-- a refusal the reference reports; any other error class is kept distinct.
readLedger :: Double -> FilePath -> IO Reading
readLedger now path' = do
  identities <- map (\case [SQLText custody] -> custody; other -> error (show other)) <$> rawRows path' "SELECT custody_id FROM territory_custody ORDER BY custody_id"
  custody <- openTerritoryCustodyWith path' (pure now)
  lookups <- forM identities $ \custody' -> do
    found <- attempt (lookupCustody custody custody')
    pure (custody', found >>= maybe (Left "absent") (\r -> Right (r.custodyId, recordView r)))
  listed <- attempt (map recordView <$> records custody)
  recovered <- attempt (map recordView <$> recover custody)
  relisted <- attempt (map recordView <$> records custody)
  closeTerritoryCustody custody
  pure (lookups, listed, recovered, relisted)
  where
    attempt :: IO a -> IO (Either Text a)
    attempt action =
      try action >>= \case
        Right value -> pure (Right value)
        Left (e :: AgenticusError)
          | e.errorClass == StorageError -> pure (Left e.errorMessage)
          | otherwise -> pure (Left (errorClassName e.errorClass <> ": " <> e.errorMessage))

-- | Copy a ledger into a fresh private directory, as a second writer would
-- find it.
privateCopy :: FilePath -> FilePath -> IO FilePath
privateCopy original directory = do
  createDirectory directory
  setFileMode directory 0o700
  let copy' = directory </> "territories.db"
  copyFile original copy'
  setFileMode copy' 0o600
  pure copy'

-- | Run @differential/retention_interop.py@ under the pinned reference.
referenceInterop :: [String] -> IO Json
referenceInterop arguments = do
  script <- makeAbsolute "differential/retention_interop.py"
  pythonJson
    "import runpy, sys; script = sys.argv[1]; sys.argv = sys.argv[1:]; runpy.run_path(script, run_name='__main__')"
    (script : arguments)

-- | The Haskell twin of @retention_interop.py write@: the same records,
-- written through the Haskell ledger over a real local provider.
writeHaskellLedger :: FilePath -> IO ()
writeHaskellLedger dir = withSystemTempDirectory "retention-interop" $ \root -> do
  let path' = dir </> "territories.db"
  provider <- localProvider <$> newLocalProcessEnvironment
  clock <- newIORef (10 :: Double)
  custody <- openTerritoryCustodyWith path' (readIORef clock)
  let attachmentFor suffix = do
        let sourceDir = root </> ("source-" <> T.unpack suffix)
        createDirectory sourceDir
        writeFile (sourceDir </> "canary.txt") ("interop " <> T.unpack suffix)
        archive' <- workspaceArchive sourceDir
        binding <- openMotusBinding provider ("operation-" <> suffix) defaultSpec archive' "initial"
        newEpisodeAttachment
          (either (error . show) id (mkEpisodeId ("episode-" <> suffix)))
          (snapshot suffix)
          (motusBinding binding)
          ("attachment-" <> suffix)
          100
          episodeOptions {Episode.attachmentEpoch = 3}
      reclaimFor suffix =
        reclaim
          custody
          ("custody-" <> suffix)
          "host-one"
          provider
          (either (error . show) id (mkEpisodeId ("episode-" <> suffix <> "-successor")))
          (snapshot (suffix <> "-successor"))
          ("attachment-" <> suffix <> "-successor")
          100
          Nothing
          Nothing
  attachmentFor "releasing" >>= \a -> void (beginRelease custody "custody-releasing" "host-one" a 50)
  attachmentFor "retained" >>= \a -> void (release custody "custody-retained" "host-one" a 50 30)
  attachmentFor "expiring" >>= \a -> void (release custody "custody-expiring" "host-one" a 15.5 30)
  attachmentFor "corrupt" >>= \a -> void (release custody "custody-corrupt" "host-one" a 50 30)
  forM_ ["attached", "claiming"] $ \suffix -> do
    attachmentFor suffix >>= \a -> void (release custody ("custody-" <> suffix) "host-one" a 50.5 30)
    void (reclaimFor suffix)
  attachmentFor "retired" >>= \a -> void (release custody "custody-retired" "host-one" a 50 30)
  void (retire custody "custody-retired" "host-one" provider)
  attachmentFor "retiring" >>= \a -> void (release custody "custody-retiring" "host-one" a 12.25 30)
  writeIORef clock 13
  expired <- try (reclaimFor "retiring")
  case expired of
    Left (e :: AgenticusError) -> e.errorMessage `shouldBe` "territory custody expired before reclaim"
    Right _ -> expectationFailure "an expired reclaim must fail"
  closeTerritoryCustody custody
  -- A crash between the durable claim and the attachment, and a column
  -- corrupted behind the ledger.
  rawExecute path' "UPDATE territory_custody SET phase='claiming' WHERE custody_id='custody-claiming'"
  rawExecute path' "UPDATE territory_custody SET capabilities='not-json' WHERE custody_id='custody-corrupt'"
  forM_ ["releasing", "retained", "expiring", "corrupt", "attached", "claiming", "retiring"] $ \suffix ->
    providerLookup provider ("operation-" <> suffix) >>= mapM_ (void . providerDestroy provider)
  where
    rawExecute path' sql = do
      db <- openDatabase path'
      runSql db sql []
      closeDatabase db

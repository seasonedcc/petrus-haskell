-- | Differential tests for the workspace-archive codec against fixtures
-- produced by CPython's @tarfile@ and upstream Petrus
-- (@test/fixtures/generate_archive_fixtures.py@), plus ports of the
-- upstream archive tests.
module ArchiveSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM, forM_, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json
import Petrus.Motus.Execution.Archive
import Petrus.Motus.Execution.Archive.Tar
import Petrus.Motus.Execution.Error
import Petrus.Motus.Execution.Internal.Posix (RealpathMode (..), fromRawPath, realpath, toRawPath)
import Support
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.Info (os)
import System.Posix.Directory.ByteString qualified as PD
import System.Posix.Files qualified as PF
import System.Posix.Files.ByteString qualified as PFB
import Test.Hspec

spec :: Spec
spec = do
  fixtures <- runIO (loadFixture "archive_fixtures.json")
  describe "workspace_archive (differential, CPython tarfile)" $
    forM_ (listField "workspaces" fixtures) $ \fixture ->
      it (T.unpack (textField "name" fixture)) $ withTempDir $ \tmp -> do
        let root = tmp </> "ws"
        createDirectory root
        buildWorkspace root (listField "entries" fixture)
        archive <- workspaceArchive root
        archiveDigest archive `shouldBe` textField "sha256" fixture
        toInteger (B.length archive) `shouldBe` intField "size" fixture
        archive `shouldBe` bytesZB64 "archive_zb64" fixture

  describe "PAX member headers (differential, TarInfo.tobuf)" $
    forM_ (zip [1 :: Int ..] (listField "headers" fixtures)) $ \(index, fixture) ->
      it ("header case " <> show index <> " (" <> T.unpack (textField "type" fixture) <> ")") $ do
        let name = bytesB64 "name_b64" fixture
            linkname = bytesB64 "linkname_b64" fixture
            kind = case textField "type" fixture of
              "file" -> WriteFile (fromInteger (intField "size" fixture))
              "dir" -> WriteDirectory
              "symlink" -> WriteSymlink linkname
              _ -> WriteHardlink linkname
        memberHeader (WriteMember name (fromInteger (intField "mode" fixture)) kind)
          `shouldBe` bytesZB64 "header_zb64" fixture

  describe "tarfile.open(r:*) + getmembers (differential)" $
    forM_ (listField "readers" fixtures) $ \fixture -> do
      let name = textField "name" fixture
          bytes = bytesZB64 "archive_zb64" fixture
      it (T.unpack name) $
        case (openArchive bytes, fieldMaybe "members_error" fixture) of
          (Left err, Just expected) -> checkError name err expected
          (Right (_, members), Nothing) -> do
            let expected = listField "members" fixture
            length members `shouldBe` length expected
            forM_ (zip members expected) (uncurry checkMember)
          (Left err, Nothing) -> expectationFailure ("unexpected failure: " <> show err)
          (Right (_, members), Just expected) ->
            expectationFailure ("expected " <> show expected <> " but parsed " <> show members)

  describe "validate_workspace_archive (differential)" $
    forM_ (listField "readers" fixtures) $ \fixture -> do
      let name = textField "name" fixture
          bytes = bytesZB64 "archive_zb64" fixture
          outcomes = field "validate" fixture
      it (T.unpack name) $
        forM_
          [ ("default", True, [])
          , ("no_links", False, [])
          , ("forbidden_secret", True, ["secret"])
          ]
          $ \(label, allowLinks, roots) -> do
            result <- try (validateWorkspaceArchive allowLinks roots bytes)
            case (result, fieldMaybe label outcomes) of
              (Right (), Nothing) -> pure ()
              (Left err, Just expected) -> checkError name err expected
              (Right (), Just expected) -> expectationFailure (T.unpack label <> ": expected " <> show expected)
              (Left err, Nothing) -> expectationFailure (T.unpack label <> ": unexpected " <> show err)

  describe "extract_workspace_archive (differential, extracted trees)" $
    forM_ (listField "readers" fixtures) $ \fixture -> do
      let name = textField "name" fixture
          bytes = bytesZB64 "archive_zb64" fixture
          expected = field "extract" fixture
      it (T.unpack name) $ withTempDir $ \tmp -> do
        let destination = tmp </> "out"
        destRaw <- toRawPath destination
        result <- try (extractWorkspaceArchive bytes destination)
        resolved <- either (const destRaw) id <$> realpath NonStrict destRaw
        let platformSpecific = name == "pax-binary" && os /= "darwin"
        if platformSpecific
          then do
            -- Linux accepts non-UTF-8 names that APFS rejects (EILSEQ).
            result `shouldSatisfy` either (const False) (const True)
            listing <- treeOf destRaw
            Map.keys listing `shouldBe` ["bin\xffname"]
          else do
            case (result, fieldMaybe "error" expected) of
              (Right (), Nothing) -> pure ()
              (Left err, Just expectedError) ->
                checkError name (normalizeDest [resolved, destRaw] err) expectedError
              (Right (), Just expectedError) -> expectationFailure ("expected " <> show expectedError)
              (Left err, Nothing) -> expectationFailure ("unexpected " <> show err)
            exists <- PFB.fileExist destRaw
            case fieldMaybe "tree" expected of
              Nothing -> exists `shouldBe` False
              Just (Array items) -> do
                listing <- treeOf destRaw
                listing `shouldBe` Map.fromList [(bytesB64 "path_b64" item, normalizeItem item) | item <- items]
              Just other -> expectationFailure ("bad tree fixture " <> show other)

  describe "upstream archive tests" $ do
    it "test_tar_rejects_escape_links_and_special_files" $ withTempDir $ \tmp -> do
      let member typeflag name linkname =
            ustar name typeflag linkname <> B.replicate 1024 0
      forM_
        [ member '0' "../escape" ""
        , member '2' "member" "../../escape"
        , member '6' "member" ""
        ]
        $ \bytes -> do
          result <- try (extractWorkspaceArchive bytes (tmp </> show (B.length bytes)))
          case result of
            Left err -> do
              errorKind err `shouldBe` ValueError
              errorMessage err `shouldSatisfy` (\m -> "unsafe" `T.isInfixOf` m || "unsupported" `T.isInfixOf` m)
            Right () -> expectationFailure "expected rejection"
      let duplicate = ustar "same" '0' "" <> ustar "same" '0' "" <> B.replicate 1024 0
      errorMatching (extractWorkspaceArchive duplicate (tmp </> "duplicate")) ValueError "duplicate"

    it "test_workspace_archive_member_and_size_limits_are_enforced" $ withTempDir $ \tmp -> do
      writeFile (tmp </> "one") "1"
      writeFile (tmp </> "two") "2"
      errorMatching
        (workspaceArchiveWith defaultArchiveLimits {limitMembers = 1} tmp)
        ValueError
        "too many"
      errorMatching
        (workspaceArchiveWith defaultArchiveLimits {limitMembers = 10, limitExtractedBytes = 1} tmp)
        ValueError
        "extracted size"

  describe "archive bounds and inputs" $ do
    it "rejects a non-directory root" $ withTempDir $ \tmp -> do
      writeFile (tmp </> "file") "x"
      workspaceArchive (tmp </> "file")
        `shouldThrowMessage` (ValueError, "workspace archive root must be a directory")
      workspaceArchive (tmp </> "missing")
        `shouldThrowMessage` (ValueError, "workspace archive root must be a directory")

    it "rejects unsupported files such as FIFOs" $ withTempDir $ \tmp -> do
      PF.createNamedPipe (tmp </> "pipe") 0o600
      workspaceArchive tmp
        `shouldThrowMessage` (ValueError, "workspace archive contains an unsupported file")

    it "enforces the transfer bound before validating or extracting" $ withTempDir $ \tmp -> do
      let oversized = B.replicate (maxWorkspaceArchiveBytes + 1) 0
      validateWorkspaceArchive True [] oversized
        `shouldThrowMessage` (ValueError, "workspace archive exceeds transfer size limit")
      extractWorkspaceArchive oversized (tmp </> "never")
        `shouldThrowMessage` (ValueError, "workspace archive exceeds transfer size limit")
      exists <- PF.fileExist (tmp </> "never")
      exists `shouldBe` False

    it "enforces the transfer bound on produced archives" $ withTempDir $ \tmp -> do
      writeFile (tmp </> "data") (replicate 4096 'x')
      workspaceArchiveWith defaultArchiveLimits {limitTransferBytes = 10239} tmp
        `shouldThrowMessage` (ValueError, "workspace archive exceeds transfer size limit")

    it "round-trips a workspace through extract and re-archive" $ withTempDir $ \tmp -> do
      let source = tmp </> "source"
      createDirectory source
      createDirectory (source </> "nested")
      writeFile (source </> "nested" </> "file.txt") "content"
      PF.createSymbolicLink "nested/file.txt" (source </> "link")
      first <- workspaceArchive source
      extractWorkspaceArchive first (tmp </> "restored")
      second <- workspaceArchive (tmp </> "restored")
      -- Modes of the extracted directory follow the umask, so compare the
      -- member lists rather than the bytes.
      let names bytes = either (const []) (map memberName . snd) (openArchive bytes)
      names second `shouldBe` names first
      linked <- readFile (tmp </> "restored" </> "link")
      linked `shouldBe` "content"
  where
    ustar :: ByteString -> Char -> ByteString -> ByteString
    ustar name typeflag linkname =
      let header = memberHeader (WriteMember name 0o644 (WriteFile 0))
          patched = B.take 156 header <> BC.singleton typeflag <> pad100 linkname <> B.drop 257 header
          pad100 v = v <> B.replicate (100 - B.length v) 0
          withoutSum = B.take 148 patched <> "        " <> B.drop 156 patched
          total = B.foldl' (\acc w -> acc + fromIntegral w) (0 :: Int) withoutSum
          rendered = BC.pack (let s = showOctal total in replicate (6 - length s) '0' ++ s) <> "\NUL"
       in B.take 148 withoutSum <> rendered <> B.drop 155 withoutSum
    showOctal n = if n < 8 then show n else showOctal (n `div` 8) ++ show (n `mod` 8)

buildWorkspace :: FilePath -> [Json] -> IO ()
buildWorkspace root entries = do
  forM_ entries $ \entry -> do
    let path = root </> T.unpack (textField "path" entry)
    case textField "type" entry of
      "dir" -> createDirectory path
      "file" -> B.writeFile path (content (intField "seed" entry) (fromInteger (intField "size" entry)))
      "symlink" -> PF.createSymbolicLink (T.unpack (textField "target" entry)) path
      "hardlink" -> PF.createLink (root </> T.unpack (textField "target" entry)) path
      other -> fail ("unknown entry type " <> T.unpack other)
  let depth entry = T.count "/" (textField "path" entry)
  forM_ (sortOn (Down . depth) entries) $ \entry ->
    when (textField "type" entry `elem` ["dir", "file"]) $
      PF.setFileMode (root </> T.unpack (textField "path" entry)) (fromInteger (intField "mode" entry))

content :: Integer -> Int -> ByteString
content seed size =
  let blockBytes = BA.convert (hash (BC.pack (show seed)) :: Digest SHA256) :: ByteString
   in B.take size (B.concat (replicate (size `div` 32 + 1) blockBytes))

checkError :: Text -> ExecutionError -> Json -> Expectation
checkError name err expected = do
  let kind = pythonClassKind (textField "class" expected)
      message = normalizeErrno (textField "message" expected)
  errorKind err `shouldBe` kind
  when (name `notElem` knownMessageDivergences) $
    normalizeErrno (errorMessage err) `shouldBe` message

-- | Fixtures whose error message intentionally differs (DIVERGENCES.md).
knownMessageDivergences :: [Text]
knownMessageDivergences = ["bz2-magic"]

normalizeErrno :: Text -> Text
normalizeErrno text = case T.breakOn "[Errno " text of
  (prefix, rest)
    | T.null rest -> text
    | otherwise ->
        let afterNumber = T.dropWhile (`elem` ['0' .. '9']) (T.drop 7 rest)
         in prefix <> "[Errno *" <> normalizeErrno afterNumber

normalizeDest :: [ByteString] -> ExecutionError -> ExecutionError
normalizeDest prefixes err =
  err {errorMessage = foldl replaceOne (errorMessage err) prefixes}
  where
    replaceOne message prefix = T.replace (TE.decodeUtf8 prefix) "<DEST>" message

checkMember :: Member -> Json -> Expectation
checkMember member expected = do
  memberName member `shouldBe` bytesB64 "name_b64" expected
  memberLinkname member `shouldBe` bytesB64 "linkname_b64" expected
  B.singleton (memberType member) `shouldBe` bytesB64 "type_b64" expected
  memberMode member `shouldBe` intField "mode" expected
  memberSize member `shouldBe` intField "size" expected
  memberOffset member `shouldBe` intField "offset" expected
  memberOffsetData member `shouldBe` intField "offset_data" expected
  case (memberMtime member, fieldMaybe "mtime" expected, fieldMaybe "mtime_float" expected) of
    (MTimeInt n, Just (Int m), Nothing) -> n `shouldBe` m
    (MTimeFloat d, Nothing, Just (Float f)) -> d `shouldBe` f
    (MTimeFloat d, Nothing, Just (Int f)) -> d `shouldBe` fromInteger f
    (actual, a, b) -> expectationFailure ("mtime mismatch " <> show (actual, a, b))
  let sparse = fmap (\case Array pairs -> [(a, b) | Array [Int a, Int b] <- pairs]; _ -> []) (fieldMaybe "sparse" expected)
  memberSparse member `shouldBe` sparse

-- | The extracted tree, keyed by raw relative path, in the fixture's shape.
treeOf :: ByteString -> IO (Map.Map ByteString Json)
treeOf root = Map.fromList <$> go ""
  where
    go relative = do
      let directory = if B.null relative then root else root <> "/" <> relative
      names <- listNames directory
      fmap concat . forM names $ \name -> do
        let child = if B.null relative then name else relative <> "/" <> name
            full = root <> "/" <> child
        st <- PFB.getSymbolicLinkStatus full
        let mode = Int (toInteger (PFB.fileMode st `mod` 0o10000))
            pathJson = String (TE.decodeUtf8 (B64.encode child))
            stamp =
              let seconds = realToFrac (PFB.modificationTimeHiRes st) :: Double
               in if seconds < 1e9
                    then Int (round (toRational (PFB.modificationTimeHiRes st) * 1000000000))
                    else String "now"
        if PFB.isSymbolicLink st
          then do
            target <- PFB.readSymbolicLink full
            pure
              [ ( child
                , Object
                    [ ("mode", mode)
                    , ("path_b64", pathJson)
                    , ("target_b64", String (TE.decodeUtf8 (B64.encode target)))
                    , ("type", String "symlink")
                    ]
                )
              ]
          else
            if PFB.isDirectory st
              then do
                nested <- go child
                pure ((child, Object [("mode", mode), ("mtime_ns", stamp), ("path_b64", pathJson), ("type", String "dir")]) : nested)
              else do
                bytes <- B.readFile =<< fromRawPath full
                let digest = T.pack (show (hash bytes :: Digest SHA256))
                pure
                  [ ( child
                    , Object
                        [ ("mode", mode)
                        , ("mtime_ns", stamp)
                        , ("nlink", Int (toInteger (PFB.linkCount st)))
                        , ("path_b64", pathJson)
                        , ("sha256", String digest)
                        , ("type", String "file")
                        ]
                    )
                  ]
    listNames directory = do
      stream <- PD.openDirStream directory
      let loop acc = do
            name <- PD.readDirStream stream
            if B.null name
              then pure acc
              else loop (if name `elem` [".", ".."] then acc else name : acc)
      names <- loop []
      PD.closeDirStream stream
      pure (Set.toList (Set.fromList names))

-- | Fixture items with keys sorted (as the generator writes them).
normalizeItem :: Json -> Json
normalizeItem = \case
  Object members -> Object (sortOn fst members)
  other -> other


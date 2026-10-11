{-# LANGUAGE CApiFFI #-}

-- | Supported bounded workspace-archive transfer helpers
-- (@petrus.motus.execution.archive@).
--
-- 'workspaceArchive' is byte-identical to CPython's
-- @petrus.motus._execution.artifacts.workspace_archive@ (the archive digests
-- are persisted by callers).  'validateWorkspaceArchive' and
-- 'extractWorkspaceArchive' reproduce the upstream ordered safety gate and
-- @tarfile.extractall(filter="data")@.
module Petrus.Motus.Execution.Archive
  ( -- * Limits
    maxWorkspaceArchiveBytes
  , maxArchiveMembers
  , maxExtractedBytes
    -- * Operations
  , ArchiveLimits (..)
  , defaultArchiveLimits
  , workspaceArchive
  , workspaceArchiveWith
  , validateWorkspaceArchive
  , extractWorkspaceArchive
  , archiveDigest
    -- * Lower level
  , openArchive
  , validatedMembers
  ) where

import Control.Exception (IOException, catch, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (complement, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (POSIXTime)
import Data.Word (Word32, Word64, Word8)
import Codec.Compression.Zlib.Internal qualified as Z
import Foreign.C.Error (Errno (..), eEXIST, eNOENT, errnoToIOError, getErrno, throwErrnoIfMinus1Retry)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import GHC.IO.Exception (IOException (..))
import Petrus.Motus.Execution.Archive.Tar
import Petrus.Motus.Execution.Error
import Petrus.Motus.Execution.Internal.PosixPath
import Petrus.Motus.Execution.Internal.PyText
import System.Posix.Directory.ByteString (closeDirStream, createDirectory, openDirStream, readDirStream)
import System.Posix.Files.ByteString
  ( FileStatus
  , createSymbolicLink
  , deviceID
  , fileID
  , fileMode
  , fileSize
  , getSymbolicLinkStatus
  , linkCount
  , readSymbolicLink
  , removeLink
  , setFileMode
  , setFileTimesHiRes
  )
import System.Posix.Files.ByteString qualified as F
import System.Posix.IO.ByteString
  ( OpenFileFlags (..)
  , OpenMode (..)
  , closeFd
  , defaultFileFlags
  , fdReadBuf
  , fdSeek
  , openFd
  )
import System.IO (SeekMode (..))
import System.Posix.Types (CSsize (..), Fd (..), FileOffset)
import Control.Exception (bracket)

-- | @MAX_ARCHIVE_BYTES@ (512 MiB): the transfer bound.
maxWorkspaceArchiveBytes :: Int
maxWorkspaceArchiveBytes = 512 * 1024 * 1024

-- | @MAX_ARCHIVE_MEMBERS@.
maxArchiveMembers :: Int
maxArchiveMembers = 200000

-- | @MAX_EXTRACTED_BYTES@ (2 GiB).
maxExtractedBytes :: Integer
maxExtractedBytes = 2 * 1024 * 1024 * 1024

-- | Lowercase hex SHA-256, as @hashlib.sha256(data).hexdigest()@.
archiveDigest :: ByteString -> Text
archiveDigest bytes = T.pack (show (hash bytes :: Digest SHA256))

-- | The bounds @workspace_archive@ enforces (upstream module constants;
-- tests lower them the way upstream tests monkeypatch them).
data ArchiveLimits = ArchiveLimits
  { limitMembers :: Int
  , limitExtractedBytes :: Integer
  , limitTransferBytes :: Int
  }
  deriving stock (Eq, Show)

defaultArchiveLimits :: ArchiveLimits
defaultArchiveLimits = ArchiveLimits maxArchiveMembers maxExtractedBytes maxWorkspaceArchiveBytes

throwValue :: Text -> IO a
throwValue = throwExecution ValueError

-- ---------------------------------------------------------------------------
-- Writing

data Planned = Planned
  { plannedHeader :: ByteString
  , plannedSource :: Maybe (RawFilePath, Int)
  }

-- | A deterministic bounded tar archive of one workspace.
workspaceArchive :: FilePath -> IO ByteString
workspaceArchive = workspaceArchiveWith defaultArchiveLimits

-- | 'workspaceArchive' with explicit bounds.
workspaceArchiveWith :: ArchiveLimits -> FilePath -> IO ByteString
workspaceArchiveWith limits root = do
  rootRaw <- pathlibString <$> toRawPath root
  rootStatus <- statMaybe rootRaw
  unless (maybe False F.isDirectory rootStatus) $
    throwValue "workspace archive root must be a directory"
  found <- walk rootRaw
  let entries = sortOn (codePointSortKey . fst) found
  when (length entries > limitMembers limits) $
    throwValue "workspace archive has too many members"
  total <- foldM checkEntry 0 entries
  when (total > limitExtractedBytes limits) $
    throwValue "workspace archive exceeds extracted size limit"
  planned <- plan rootRaw entries
  let membersLength = sum [B.length (plannedHeader p) + maybe 0 (paddedSize . snd) (plannedSource p) | p <- planned]
      totalLength = membersLength + archiveTrailerLength membersLength
  when (totalLength > limitTransferBytes limits) $
    throwValue "workspace archive exceeds transfer size limit"
  BI.create totalLength $ \base -> do
    end <- foldM (writePlanned base) 0 planned
    fillBytes (base `plusPtr` end) 0 (totalLength - end)
  where
    checkEntry total (_, status) = case status of
      Just st
        | F.isSymbolicLink st -> pure total
        | F.isRegularFile st -> pure (total + fromIntegral (fileSize st))
        | F.isDirectory st -> pure total
      _ -> throwValue "workspace archive contains an unsupported file"

-- | @root.rglob("*")@: every descendant, not following symlinked
-- directories, ignoring listing errors; with each path's @lstat@.
walk :: RawFilePath -> IO [(ByteString, Maybe FileStatus)]
walk root = go "" []
  where
    go relative acc = do
      let directory = if B.null relative then root else joinPath root relative
      listed <- try (listDirectory directory)
      case listed of
        Left (_ :: IOException) -> pure acc
        Right names ->
          foldM
            ( \acc' name -> do
                let child = if B.null relative then name else relative <> "/" <> name
                status <- lstatMaybe (joinPath root child)
                let acc'' = (child, status) : acc'
                case status of
                  Just st | F.isDirectory st -> go child acc''
                  _ -> pure acc''
            )
            acc
            names

listDirectory :: RawFilePath -> IO [ByteString]
listDirectory path = bracket (openDirStream path) closeDirStream (loop [])
  where
    loop acc stream = do
      name <- readDirStream stream
      if B.null name
        then pure acc
        else
          if name == "." || name == ".."
            then loop acc stream
            else loop (name : acc) stream

plan :: RawFilePath -> [(ByteString, Maybe FileStatus)] -> IO [Planned]
plan root entries = do
  inodesRef <- newIORef Map.empty
  fmap concat . forM entries $ \(relative, cached) -> do
    let path = joinPath root relative
    status <- maybe (lstatOrRaise path) pure cached
    let mode = fromIntegral (fileMode status) :: Int
    kind <-
      if F.isRegularFile status
        then do
          inodes <- readIORef inodesRef
          let inode = (fileID status, deviceID status)
          case Map.lookup inode inodes of
            Just first
              | linkCount status > 1 && first /= relative -> pure (Just (WriteHardlink first))
            _ -> do
              when (fileID status /= 0) $ modifyIORef' inodesRef (Map.insert inode relative)
              pure (Just (WriteFile (fromIntegral (fileSize status))))
        else
          if F.isDirectory status
            then pure (Just WriteDirectory)
            else
              if F.isSymbolicLink status
                then Just . WriteSymlink <$> readlinkOrRaise path
                else pure Nothing
    pure $ case kind of
      Nothing -> []
      Just k ->
        [ Planned
            (memberHeader (WriteMember relative mode k))
            (case k of WriteFile n -> Just (path, n); _ -> Nothing)
        ]
  where
    lstatOrRaise path = getSymbolicLinkStatus path `catch` (throwIO . osErrorFromRawIO)
    readlinkOrRaise path = readSymbolicLink path `catch` (throwIO . osErrorFromRawIO)

writePlanned :: Ptr Word8 -> Int -> Planned -> IO Int
writePlanned base offset (Planned header source) = do
  BU.unsafeUseAsCStringLen header $ \(ptr, len) -> copyBytes (base `plusPtr` offset) (castPtr ptr) len
  let dataStart = offset + B.length header
  case source of
    Nothing -> pure dataStart
    Just (path, size) -> do
      readExactly path (base `plusPtr` dataStart) size
      let padded = paddedSize size
      fillBytes (base `plusPtr` (dataStart + size)) 0 (padded - size)
      pure (dataStart + padded)

-- | Copy exactly @size@ bytes of a file (Python's @copyfileobj@ with a
-- length): a short file raises @OSError("unexpected end of data")@.
readExactly :: RawFilePath -> Ptr Word8 -> Int -> IO ()
readExactly path target size = do
  fd <- openFd path ReadOnly defaultFileFlags {cloexec = True} `catch` (throwIO . osErrorFromRawIO)
  let loop done
        | done >= size = pure ()
        | otherwise = do
            got <- fdReadBuf fd (target `plusPtr` done) (fromIntegral (min (size - done) (16 * 1024 * 1024)))
            when (got == 0) $ throwExecution OSError "unexpected end of data"
            loop (done + fromIntegral got)
  (loop 0 `catch` (throwIO . osErrorFromRawIO)) `finallyClose` fd
  where
    finallyClose action fd = do
      result <- try action
      closeFd fd
      either (throwIO :: ExecutionError -> IO a) pure result

-- | @str(pathlib.Path(raw))@: collapse duplicate separators and @.@
-- components, drop a trailing separator; keep exactly two leading slashes.
pathlibString :: ByteString -> ByteString
pathlibString raw =
  let (anchor, parts) = purePosixNormalize raw
      joined = anchor <> B.intercalate "/" parts
   in if B.null joined then "." else joined

-- ---------------------------------------------------------------------------
-- Opening (tarfile.open(mode="r:*"))

-- | Open archive bytes as @tarfile.open(fileobj=..., mode="r:*")@ and load
-- every member.  Returns the (possibly decompressed) payload the members'
-- data offsets refer to.
openArchive :: ByteString -> Either ExecutionError (ByteString, [Member])
openArchive bytes = do
  gz <- attemptGzip
  case gz of
    Right result -> Right result
    Left gzMessage ->
      case readTar bytes of
        Right members -> Right (bytes, members)
        Left (True, ReadFailure _)
          | isOtherCompression bytes ->
              Left (ExecutionError TarError "bzip2, xz, and zstd workspace archives are not supported")
        Left (True, ReadFailure message) ->
          Left
            ( ExecutionError TarError . T.pack $
                "file could not be opened successfully:\n- method gz: "
                  <> gzMessage
                  <> "\n- method bz2: ReadError('not a bzip2 file')\n- method xz: "
                  <> (if lzmaReadsEmpty bytes then readErrorRepr "empty file" else readErrorRepr "not an lzma file")
                  <> "\n- method zst: ReadError('not a zstd file')\n- method tar: "
                  <> readErrorRepr message
            )
        Left (_, failure) -> Left (fromFailure failure)
  where
    attemptGzip
      | B.null bytes = Right (Left (readErrorRepr "empty file"))
      | "\x1f\x8b" `B.isPrefixOf` bytes = do
          let payload = gunzipPrefix bytes
          case readTar payload of
            Right members -> Right (Right (payload, members))
            Left (True, ReadFailure message) -> Right (Left (readErrorRepr message))
            Left (_, failure) -> Left (fromFailure failure)
      | otherwise = Right (Left (readErrorRepr "not a gzip file"))
    readErrorRepr message = "ReadError(" <> pyStrRepr message <> ")"
    fromFailure = \case
      ReadFailure message -> ExecutionError TarError (T.pack message)
      PythonFailure cls message -> ExecutionError (pythonKind cls) (T.pack message)
    pythonKind = \case
      "ValueError" -> ValueError
      other -> OtherError (T.pack other)

-- | Whether CPython's @LZMAFile@ (format auto-detection) reads these bytes
-- as zero or more empty @.lzma@ ("alone") streams and then either reaches
-- the end or hits trailing data it ignores.  Tar headers often look like
-- such streams (a small first byte followed by NULs), and the resulting
-- @'empty file'@ shows up in @tarfile.open@'s aggregated error message.
lzmaReadsEmpty :: ByteString -> Bool
lzmaReadsEmpty = first
  where
    first bytes = case lzmaStream bytes of
      EmptyStream rest -> trailing rest
      _ -> False
    trailing rest
      | B.null rest = True
      | otherwise = case lzmaStream rest of
          EmptyStream more -> trailing more
          FormatError -> True
          _ -> False

data LzmaStream = EmptyStream ByteString | FormatError | NeedsInput | ProducesData

-- | One @.lzma@ stream as liblzma's picky alone decoder sees it.
lzmaStream :: ByteString -> LzmaStream
lzmaStream bytes
  | B.null bytes = NeedsInput
  | props > 224 || lc + lp > 4 = FormatError
  | B.length bytes < 5 = NeedsInput
  | not dictionaryOk = FormatError
  | B.length bytes < 13 = NeedsInput
  | size /= maxBound && size >= 2 ^ (38 :: Int) = FormatError
  | size /= 0 = ProducesData
  | B.length bytes < 18 = NeedsInput
  | B.any (/= 0) (B.take 5 (B.drop 13 bytes)) = FormatError
  | otherwise = EmptyStream (B.drop 18 bytes)
  where
    props = fromIntegral (B.index bytes 0) :: Int
    lc = props `mod` 9
    lp = (props `div` 9) `mod` 5
    littleEndian from count =
      foldr (\i acc -> acc * 256 + fromIntegral (B.index bytes (from + i))) 0 [0 .. count - 1] :: Integer
    dictionary = fromIntegral (littleEndian 1 4) :: Word32
    dictionaryOk =
      dictionary == maxBound
        || let d0 = dictionary - 1
               d1 = d0 .|. (d0 `shiftR` 2)
               d2 = d1 .|. (d1 `shiftR` 3)
               d3 = d2 .|. (d2 `shiftR` 4)
               d4 = d3 .|. (d3 `shiftR` 8)
               d5 = d4 .|. (d4 `shiftR` 16)
            in d5 + 1 == dictionary
    size = fromIntegral (littleEndian 5 8) :: Word64

isOtherCompression :: ByteString -> Bool
isOtherCompression bytes =
  "BZh" `B.isPrefixOf` bytes
    || "\xfd\&7zXZ\NUL" `B.isPrefixOf` bytes
    || "\x28\xb5\x2f\xfd" `B.isPrefixOf` bytes

-- | Decompress a gzip stream, keeping the bytes produced before any error
-- (CPython's reader only fails when it reads past that point) and capping
-- the result at 3 GiB.
gunzipPrefix :: ByteString -> ByteString
gunzipPrefix compressed = BL.toStrict (BL.fromChunks (capped 0 chunks))
  where
    chunks =
      Z.foldDecompressStreamWithInput
        (:)
        (const [])
        (const [])
        (Z.decompressST Z.gzipFormat Z.defaultDecompressParams)
        (BL.fromStrict compressed)
    limit = 3 * 1024 * 1024 * 1024 :: Int
    capped _ [] = []
    capped seen (c : cs)
      | seen >= limit = []
      | otherwise = B.take (limit - seen) c : capped (seen + B.length c) cs

-- ---------------------------------------------------------------------------
-- Validation

-- | The ordered archive-safety gate (@_validated_workspace_members@).
validatedMembers :: Bool -> Set ByteString -> [Member] -> Either ExecutionError [Member]
validatedMembers allowLinks forbiddenRoots members = do
  when (length members > maxArchiveMembers) $
    Left (valueError "workspace archive has too many members")
  go Set.empty 0 members
  pure members
  where
    go _ _ [] = Right ()
    go seen extracted (member : rest) = do
      let raw = memberName member
          shown = T.pack (pyStrRepr (decodeSurrogateEscape raw))
          (anchor, parts) = purePosixNormalize raw
          normalized =
            let joined = anchor <> B.intercalate "/" parts
             in if B.null joined then "." else joined
      when (not (B.null anchor) || ".." `elem` parts) $
        Left (valueError ("unsafe archive member: " <> shown))
      when (normalized `Set.member` seen) $
        Left (valueError ("duplicate archive member: " <> shown))
      case parts of
        first : _
          | first `Set.member` forbiddenRoots ->
              Left (valueError ("forbidden archive member: " <> shown))
        _ -> Right ()
      unless (isRegular member || isDirectory member || isSymlink member || isHardlink member) $
        Left (valueError ("unsupported archive member: " <> shown))
      extracted' <-
        if isRegular member
          then do
            let next = extracted + memberSize member
            when (next > maxExtractedBytes) $
              Left (valueError "workspace archive exceeds extracted size limit")
            pure next
          else pure extracted
      when (isSymlink member || isHardlink member) $ do
        unless allowLinks $
          Left (valueError ("archive links are not permitted: " <> shown))
        let (targetAnchor, targetParts) = purePosixNormalize (memberLinkname member)
            resolvedParts
              | isHardlink member = targetParts
              | otherwise = dropLast parts ++ targetParts
        when (not (B.null targetAnchor) || ".." `elem` resolvedParts) $
          Left (valueError ("unsafe archive link: " <> shown))
      go (Set.insert normalized seen) extracted' rest
    dropLast xs = take (length xs - 1) xs

-- | Validate a bounded archive without creating a destination or
-- extracting it.  Any tar-level failure becomes
-- @ValueError("workspace archive is malformed")@.
validateWorkspaceArchive :: Bool -> [Text] -> ByteString -> IO ()
validateWorkspaceArchive allowLinks forbiddenRoots bytes = do
  when (B.length bytes > maxWorkspaceArchiveBytes) $
    throwValue "workspace archive exceeds transfer size limit"
  case openArchive bytes of
    Left err
      | errorKind err == TarError -> throwValue "workspace archive is malformed"
      | otherwise -> throwIO err
    Right (_, members) ->
      either throwIO (const (pure ())) $
        validatedMembers allowLinks (Set.fromList (map TE.encodeUtf8 forbiddenRoots)) members

-- ---------------------------------------------------------------------------
-- Extraction

-- | Securely extract an archive: no archive-root escape, no special files
-- (@tarfile.extractall(filter="data")@ after the safety gate).
extractWorkspaceArchive :: ByteString -> FilePath -> IO ()
extractWorkspaceArchive bytes destination = do
  when (B.length bytes > maxWorkspaceArchiveBytes) $
    throwValue "workspace archive exceeds transfer size limit"
  destRaw <- pathlibString <$> toRawPath destination
  pathlibMkdirParents destRaw
  (payload, members) <- either throwIO pure (openArchive bytes)
  validated <- either throwIO pure (validatedMembers True Set.empty members)
  extractAll payload validated destRaw

-- | @Path.mkdir(parents=True, exist_ok=True)@.
pathlibMkdirParents :: RawFilePath -> IO ()
pathlibMkdirParents path = do
  result <- try (createDirectory path 0o777)
  case result of
    Right () -> pure ()
    Left (e :: IOException)
      | ioe_errno e == Just (errnoInt eNOENT) -> do
          let parent = pathlibParent path
          when (parent == path) $ throwIO (osErrorFromRawIO e)
          pathlibMkdirParents parent
          again <- try (createDirectory path 0o777)
          case again of
            Right () -> pure ()
            Left (e2 :: IOException) -> existOk e2
      | otherwise -> existOk e
  where
    existOk e = do
      status <- statMaybe path
      unless (maybe False F.isDirectory status) $ throwIO (osErrorFromRawIO e)
    pathlibParent p =
      let (anchor, parts) = purePosixNormalize p
       in case parts of
            [] -> p
            _ ->
              let joined = anchor <> B.intercalate "/" (take (length parts - 1) parts)
               in if B.null joined then "." else joined

errnoInt :: Errno -> CInt
errnoInt (Errno n) = n

-- | A member after @data_filter@.
data Filtered = Filtered
  { filteredMember :: Member
  , filteredName :: ByteString
  , filteredMode :: Maybe Integer
  , filteredLinkname :: ByteString
  }

memberRepr :: Member -> String
memberRepr = pyStrRepr . decodeSurrogateEscape . memberName

pathRepr :: ByteString -> String
pathRepr = pyStrRepr . decodeSurrogateEscape

filterError :: String -> IO a
filterError = throwExecution TarError . T.pack

realpathOrRaise :: ByteString -> IO ByteString
realpathOrRaise path = do
  result <- realpath AllowMissing path
  case result of
    Right resolved -> pure resolved
    Left (OsError errno failing) ->
      throwExecution OSError (T.pack (pythonErrnoMessage errno (Just (decodeSurrogateEscape failing))))

-- | @tarfile.data_filter@.
dataFilter :: Member -> ByteString -> IO Filtered
dataFilter member dest = do
  destPath <- realpathOrRaise dest
  let name =
        if "/" `B.isPrefixOf` memberName member
          then BC.dropWhile (== '/') (memberName member)
          else memberName member
  targetPath <- realpathOrRaise (joinPath destPath name)
  unless (commonpathWithin targetPath destPath) $
    filterError (memberRepr member <> " would be extracted to " <> pathRepr targetPath <> ", which is outside the destination")
  let masked = memberMode member .&. 0o755
  mode <-
    if isRegular member || isHardlink member
      then do
        let noExec = if masked .&. 0o100 == 0 then masked .&. complement 0o111 else masked
        pure (Just (noExec .|. 0o600))
      else
        if isDirectory member || isSymlink member
          then pure Nothing
          else filterError (memberRepr member <> " is a special file")
  linkname <-
    if isHardlink member || isSymlink member
      then do
        when (isAbsolute (memberLinkname member)) $
          filterError (memberRepr member <> " is a link to an absolute path")
        when (targetPath == destPath) $
          filterError (memberRepr member <> " would be extracted to " <> pathRepr targetPath <> ", which is outside the destination")
        let normalized = normpath (memberLinkname member)
            linkTarget
              | isSymlink member =
                  joinPath (joinPath destPath (dirname (BC.dropWhileEnd (== '/') name))) normalized
              | otherwise = joinPath destPath normalized
        resolved <- realpathOrRaise linkTarget
        unless (commonpathWithin resolved destPath) $
          filterError (memberRepr member <> " would link to " <> pathRepr resolved <> ", which is outside the destination")
        pure normalized
      else pure (memberLinkname member)
  pure (Filtered member name mode linkname)

-- | Which "fatal" errors 'extractAll' lets escape, matching
-- @_handle_fatal_error@ with @errorlevel=1@; @ExtractError@s are dropped.
data ExtractOutcome = Extracted | ExtractErrorIgnored

extractAll :: ByteString -> [Member] -> ByteString -> IO ()
extractAll payload members dest = do
  directoriesRef <- newIORef []
  forM_ members $ \member -> do
    filtered <- dataFilter member dest `catch` (throwIO . osErrorFromRawIO)
    when (isDirectory member) $ modifyIORef' directoriesRef (member :)
    _ <- extractMember payload members dest filtered (joinPath dest (filteredName filtered)) (not (isDirectory member))
    pure ()
  directories <- readIORef directoriesRef
  forM_ (sortOn (Down . codePointSortKey . memberName) (reverse directories)) $ \member -> do
    refiltered <- try (dataFilter member dest)
    case refiltered of
      Left (_ :: ExecutionError) -> pure ()
      Right filtered -> do
        let dirpath = joinPath dest (filteredName filtered)
        status <- try (getSymbolicLinkStatus dirpath)
        case status of
          Left (e :: IOException)
            | ioe_errno e == Just (errnoInt eNOENT) -> pure ()
            | otherwise -> throwIO (osErrorFromRawIO e)
          Right st
            | not (F.isDirectory st) -> pure ()
            | otherwise -> do
                _ <- setTimes dirpath (memberMtime member)
                pure ()

-- | @TarFile._extract_member@ (with @_extract_one@'s error policy).
extractMember :: ByteString -> [Member] -> ByteString -> Filtered -> ByteString -> Bool -> IO ExtractOutcome
extractMember payload members dest filtered targetpath0 setAttrs = do
  let targetpath = BC.dropWhileEnd (== '/') targetpath0
      upperdirs = dirname targetpath
      member = filteredMember filtered
  wrapOs $ do
    exists <- pathExists upperdirs
    when (not (B.null upperdirs) && not exists) $ makedirs upperdirs
  outcome <-
    if isRegular member
      then wrapOs (makeFile payload member targetpath) >> pure Extracted
      else
        if isDirectory member
          then wrapOs (makeDirectory targetpath) >> pure Extracted
          else makeLink payload members dest filtered targetpath
  case outcome of
    ExtractErrorIgnored -> pure ExtractErrorIgnored
    Extracted
      | setAttrs && not (isSymlink member) -> do
          chmodded <- case filteredMode filtered of
            Nothing -> pure True
            Just mode -> do
              result <- try (setFileMode targetpath (fromIntegral mode))
              pure (either (\(_ :: IOException) -> False) (const True) result)
          timed <- if chmodded then setTimes targetpath (memberMtime member) else pure False
          pure (if timed then Extracted else ExtractErrorIgnored)
      | otherwise -> pure Extracted
  where
    wrapOs action = action `catch` (throwIO . osErrorFromRawIO)

-- | @os.makedirs(name, exist_ok=True)@.
makedirs :: ByteString -> IO ()
makedirs name = do
  let (head0, tail0) = splitPath name
      (headPart, tailPart) = if B.null tail0 then splitPath head0 else (head0, tail0)
  when (not (B.null headPart) && not (B.null tailPart)) $ do
    exists <- pathExists headPart
    unless exists $ do
      result <- try (makedirs headPart)
      case result of
        Left (e :: IOException) | ioe_errno e /= Just (errnoInt eEXIST) -> throwIO e
        _ -> pure ()
  unless (tailPart == ".") $ do
    result <- try (createDirectory name 0o777)
    case result of
      Right () -> pure ()
      Left (e :: IOException) -> do
        status <- statMaybe name
        unless (maybe False F.isDirectory status) $ throwIO e
  where
    splitPath p =
      let i = maybe 0 (+ 1) (BC.elemIndexEnd '/' p)
          (h, t) = B.splitAt i p
       in (if not (B.null h) && BC.any (/= '/') h then BC.dropWhileEnd (== '/') h else h, t)

makeDirectory :: ByteString -> IO ()
makeDirectory targetpath = do
  result <- try (createDirectory targetpath 0o777)
  case result of
    Right () -> pure ()
    Left (e :: IOException)
      | ioe_errno e == Just (errnoInt eEXIST) -> do
          status <- statMaybe targetpath
          unless (maybe False F.isDirectory status) $ throwIO e
      | otherwise -> throwIO e

-- | @TarFile.makefile@: data (or sparse map) copied from the payload.
makeFile :: ByteString -> Member -> ByteString -> IO ()
makeFile payload member targetpath = do
  let flags = defaultFileFlags {creat = Just 0o666, trunc = True, cloexec = True}
  bracket (openFd targetpath WriteOnly flags) closeFd $ \fd -> do
    let source = memberOffsetData member
    case memberSparse member of
      Nothing -> copyFrom fd source (memberSize member)
      Just regions -> do
        _ <-
          foldM
            ( \position (offset, size) -> do
                when (offset < 0) $
                  throwExecution ValueError (T.pack ("negative seek position " <> show offset))
                _ <- fdSeek fd AbsoluteSeek (fromIntegral offset :: FileOffset)
                copyFrom fd position size
                pure (position + size)
            )
            source
            regions
        when (memberSize member < 0) $
          throwExecution ValueError (T.pack ("negative seek position " <> show (memberSize member)))
        F.setFdSize fd (fromIntegral (memberSize member))
  where
    copyFrom fd position size
      | size <= 0 = pure ()
      | otherwise = do
          let available = fromIntegral (B.length payload) - position
          when (position < 0 || available < size) $
            throwExecution TarError "unexpected end of data"
          writeAll fd (B.take (fromIntegral size) (B.drop (fromIntegral position) payload))

-- | Write all bytes in 64 KiB @write(2)@ calls (the size that measured
-- fastest for large extractions).  The call is @unsafe@: a 64 KiB write to
-- a regular file takes microseconds, and a @safe@ call per chunk cost ~10%
-- of a 256 MiB extraction.
writeAll :: Fd -> ByteString -> IO ()
writeAll (Fd fd) bytes = unless (B.null bytes) $ do
  written <-
    BU.unsafeUseAsCStringLen bytes $ \(ptr, len) ->
      throwErrnoIfMinus1Retry "write" (c_write fd (castPtr ptr) (fromIntegral (min len (64 * 1024))))
  writeAll (Fd fd) (B.drop (fromIntegral written) bytes)

foreign import capi unsafe "unistd.h write"
  c_write :: CInt -> Ptr Word8 -> CSize -> IO CSsize

foreign import capi unsafe "unistd.h linkat"
  c_linkat :: CInt -> CString -> CInt -> CString -> CInt -> IO CInt

foreign import capi "fcntl.h value AT_FDCWD" atFdcwd :: CInt

foreign import capi "fcntl.h value AT_SYMLINK_FOLLOW" atSymlinkFollow :: CInt

-- | @os.link(src, dst)@ (which follows a symlinked source).
hardLink :: ByteString -> ByteString -> IO ()
hardLink source target =
  B.useAsCString source $ \src -> B.useAsCString target $ \dst -> do
    result <- c_linkat atFdcwd src atFdcwd dst atSymlinkFollow
    when (result /= 0) $ do
      errno <- getErrno
      ioError (errnoToIOError "link" errno Nothing (Just (BC.unpack target)))

-- | @TarFile.makelink_with_filter@.
makeLink :: ByteString -> [Member] -> ByteString -> Filtered -> ByteString -> IO ExtractOutcome
makeLink payload members dest filtered targetpath = do
  let member = filteredMember filtered
      linkTarget = joinPath dest (filteredLinkname filtered)
  attempt <- try $
    if isSymlink member
      then do
        present <- pathLexists targetpath
        when present $ removeLink targetpath
        createSymbolicLink (filteredLinkname filtered) targetpath
        pure True
      else do
        exists <- pathExists linkTarget
        if exists
          then do
            present <- pathLexists targetpath
            when present $ removeLink targetpath
            hardLink linkTarget targetpath
            pure True
          else pure False
  case attempt of
    Right True -> pure Extracted
    Right False -> fallback False
    Left (_ :: IOException) -> fallback True
  where
    fallback keyErrorToExtractError = do
      let member = filteredMember filtered
          (searchName, candidates)
            | isSymlink member =
                ( B.intercalate "/" (filter (not . B.null) [dirname (filteredName filtered), filteredLinkname filtered])
                , members
                )
            | otherwise =
                (filteredLinkname filtered, takeWhile ((/= memberOffset member) . memberOffset) members)
          wanted = normpath searchName
      case filter ((== wanted) . normpath . memberName) (reverse candidates) of
        [] ->
          if keyErrorToExtractError
            then pure ExtractErrorIgnored
            else throwExecution KeyError (T.pack ("linkname " <> pathRepr searchName <> " not found"))
        unfiltered : _ -> do
          refiltered <- try (dataFilter unfiltered dest)
          case refiltered of
            Left (_ :: ExecutionError) ->
              filterError
                ( "link " <> memberRepr member <> " would be extracted as a copy of "
                    <> memberRepr unfiltered <> ", which was rejected"
                )
            Right copy -> extractMember payload members dest copy targetpath True

-- | @TarFile.utime@: failures are non-fatal @ExtractError@s.
setTimes :: ByteString -> MTime -> IO Bool
setTimes path mtime = do
  stamp <- case mtime of
    MTimeInt n
      | n < -(2 ^ (63 :: Int)) || n >= 2 ^ (63 :: Int) ->
          throwExecution (OtherError "OverflowError") "timestamp out of range for platform time_t"
      | otherwise -> pure (fromIntegral n :: POSIXTime)
    MTimeFloat d
      | isNaN d -> throwExecution ValueError "Invalid value NaN (not a number)"
      | isInfinite d -> throwExecution (OtherError "OverflowError") "timestamp too large to convert to C PyTime_t"
      | otherwise -> do
          let seconds = floor d :: Integer
              nanos = floor ((d - fromIntegral seconds) * 1e9) :: Integer
          pure (fromIntegral seconds + fromRational (toRational nanos / 1e9))
  result <- try (setFileTimesHiRes path stamp stamp)
  pure (either (\(_ :: IOException) -> False) (const True) result)

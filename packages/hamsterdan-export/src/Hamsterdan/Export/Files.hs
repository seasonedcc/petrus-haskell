-- | The file system and SQLite calls the exporter makes, with the
-- semantics and exception texts of the CPython 3.14 calls the reference
-- makes: @pathlib@ joining, @exists@/@is_file@/@is_dir@, @iterdir@,
-- @glob@ and @rglob@, @mkdir(parents=True, exist_ok=True)@,
-- @shutil.copyfile@, @read_bytes@/@read_text@/@write_text@, and
-- @sqlite3@'s @connect@/@execute@/@fetchall@.
--
-- A path is the @str@ of the reference's @Path@ object. Directory entries
-- whose names are not UTF-8 are a recorded divergence (DIVERGENCES.md):
-- CPython keeps their undecodable bytes as lone surrogates, which 'Text'
-- cannot hold.
module Hamsterdan.Export.Files
  ( -- * Paths
    joinPath
  , pathName
  , pathParent
  , pathSuffix
  , rawPath

    -- * Queries
  , exists
  , isFile
  , isDir
  , fileSize

    -- * Directories
  , iterdir
  , globBindings
  , rglobFiles
  , mkdirParents
  , withScratch

    -- * Files
  , readBytes
  , readText
  , writeBytes
  , writeText
  , copyFile
  , withAppend
  , removeFileQuietly

    -- * SQLite
  , queryRows
  ) where

import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (filterM, forM, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Database.SQLite3.Direct qualified as Direct
import Foreign.C.Error
  ( Errno (..)
  , eACCES
  , eAGAIN
  , eALREADY
  , eCHILD
  , eCONNABORTED
  , eCONNREFUSED
  , eCONNRESET
  , eEXIST
  , eINPROGRESS
  , eINTR
  , eISDIR
  , eNOENT
  , eNOTDIR
  , ePERM
  , ePIPE
  , eSHUTDOWN
  , eSRCH
  , eTIMEDOUT
  , eWOULDBLOCK
  )
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))
import GHC.IO.Exception (IOException (..))
import Hamsterdan.Python.Object (PV (..), PyError (..), raise)
import Hamsterdan.Python.Text (strRepr)
import Petrus.EngineFile.PyText (decodeText)
import Petrus.EngineFile.Validate (PyException (..))
import Petrus.EngineFile.Value (pyDict)
import System.Directory (removePathForcibly)
import System.Environment (lookupEnv)
import System.Posix.ByteString (RawFilePath)
import System.Posix.Types (Fd)
import System.Posix.Directory.ByteString qualified as Dir
import System.Posix.Files.ByteString qualified as Files
import System.Posix.IO.ByteString qualified as PIO
import System.Posix.Temp.ByteString (mkdtemp)

-- ---------------------------------------------------------------------------
-- Paths

-- | @path / name@, for a name that holds no @.@ or empty parts.
joinPath :: Text -> Text -> Text
joinPath base name
  | base == "." = name
  | "/" `T.isSuffixOf` base = base <> name
  | otherwise = base <> "/" <> name

-- | @path.name@.
pathName :: Text -> Text
pathName path
  | path `elem` [".", "/", "//"] = ""
  | otherwise = snd (T.breakOnEnd "/" path)

-- | @path.parent@.
pathParent :: Text -> Text
pathParent path
  | path `elem` [".", "/", "//"] = path
  | otherwise = case T.breakOnEnd "/" path of
      ("", _) -> "."
      (prefix, _)
        | prefix `elem` ["/", "//"] -> prefix
        | otherwise -> T.dropEnd 1 prefix

-- | @path.suffix@.
pathSuffix :: Text -> Text
pathSuffix path =
  let name = pathName path
   in case T.breakOnEnd "." name of
        (before, after) | T.length before > 1 -> "." <> after
        _ -> ""

rawPath :: Text -> RawFilePath
rawPath = TE.encodeUtf8

decodeName :: ByteString -> Text
decodeName = TE.decodeUtf8With lenientDecode

-- ---------------------------------------------------------------------------
-- Exceptions

-- | The @OSError@ subclass and text CPython raises for an errno on a path.
osError :: Text -> Errno -> IO PyError
osError path errno@(Errno n) = do
  description <- c_strerror n >>= peekCString
  pure (PyError (errnoClass errno) ("[Errno " <> T.pack (show n) <> "] " <> T.pack description <> ": " <> strRepr path))

errnoClass :: Errno -> Text
errnoClass errno
  | errno == eNOENT = "FileNotFoundError"
  | errno == eEXIST = "FileExistsError"
  | errno == eISDIR = "IsADirectoryError"
  | errno == eNOTDIR = "NotADirectoryError"
  | errno == eACCES || errno == ePERM = "PermissionError"
  | errno `elem` [eAGAIN, eALREADY, eWOULDBLOCK, eINPROGRESS] = "BlockingIOError"
  | errno == eCHILD = "ChildProcessError"
  | errno == ePIPE || errno == eSHUTDOWN = "BrokenPipeError"
  | errno == eCONNABORTED = "ConnectionAbortedError"
  | errno == eCONNREFUSED = "ConnectionRefusedError"
  | errno == eCONNRESET = "ConnectionResetError"
  | errno == eINTR = "InterruptedError"
  | errno == eSRCH = "ProcessLookupError"
  | errno == eTIMEDOUT = "TimeoutError"
  | otherwise = "OSError"

foreign import ccall unsafe "string.h strerror"
  c_strerror :: CInt -> IO CString

-- | Run a system call, raising the @OSError@ CPython raises for its errno.
onPath :: Text -> IO a -> IO a
onPath path action =
  try action >>= \case
    Right value -> pure value
    Left (e :: IOException) -> case ioe_errno e of
      Just n -> osError path (Errno n) >>= raise
      Nothing -> raise (PyError "OSError" (T.pack (show e)))

-- ---------------------------------------------------------------------------
-- Queries

statusOf :: Text -> IO (Maybe Files.FileStatus)
statusOf path = either (\(_ :: IOException) -> Nothing) Just <$> try (Files.getFileStatus (rawPath path))

-- | @path.exists()@.
exists :: Text -> IO Bool
exists path = isJust <$> statusOf path

-- | @path.is_file()@.
isFile :: Text -> IO Bool
isFile path = maybe False Files.isRegularFile <$> statusOf path

-- | @path.is_dir()@.
isDir :: Text -> IO Bool
isDir path = maybe False Files.isDirectory <$> statusOf path

lexists :: Text -> IO Bool
lexists path =
  either (\(_ :: IOException) -> False) (const True) <$> try (Files.getSymbolicLinkStatus (rawPath path))

-- | @path.stat().st_size@.
fileSize :: Text -> IO Integer
fileSize path = toInteger . Files.fileSize <$> onPath path (Files.getFileStatus (rawPath path))

-- ---------------------------------------------------------------------------
-- Directories

-- | The names in a directory, in the order the system lists them.
listNames :: Text -> IO [ByteString]
listNames path =
  onPath path $
    bracket (Dir.openDirStream (rawPath path)) Dir.closeDirStream $ \stream ->
      let loop acc = do
            name <- Dir.readDirStream stream
            if BS.null name
              then pure (reverse acc)
              else loop (if name == "." || name == ".." then acc else name : acc)
       in loop []

-- | @path.iterdir()@: each entry's path (the bare name under @.@).
iterdir :: Text -> IO [Text]
iterdir path = map (joinPath path . decodeName) <$> listNames path

-- | Like 'listNames', but an unreadable directory lists nothing (the way
-- @glob@ ignores @OSError@).
quietNames :: Text -> IO [Text]
quietNames path = either (\(_ :: PyError) -> []) (map decodeName) <$> try (listNames path)

-- | @sorted(state_dir.glob(f"applications/*/*/{pull_request}/binding.json"))@.
globBindings :: Text -> Text -> IO [Text]
globBindings root pullRequest = do
  let applications = joinPath root "applications"
  installations <- quietNames applications >>= filterM (isDir . joinPath applications)
  found <- fmap concat . forM installations $ \installation -> do
    let installationPath = joinPath applications installation
    repositories <- quietNames installationPath >>= filterM (isDir . joinPath installationPath)
    fmap catMaybes . forM repositories $ \repository -> do
      let candidate = joinPath (joinPath installationPath repository) (pullRequest <> "/binding.json")
      present <- lexists candidate
      pure (if present then Just ((installation, repository), candidate) else Nothing)
  pure (map snd (sortOn fst found))

-- | The paths @state_dir.rglob("*")@ yields that are files
-- (@path.is_file()@), relative to the root: every entry below it, not
-- descending into symbolic links to directories, unreadable directories
-- skipped.
rglobFiles :: Text -> IO [(Text, Text)]
rglobFiles root = do
  found <- newIORef []
  let walk relative = do
        let directory = if T.null relative then root else joinPath root relative
        names <- quietNames directory
        forM names $ \name -> do
          let child = if T.null relative then name else relative <> "/" <> name
              full = joinPath root child
          regular <- isFile full
          when regular $ modifyIORef' found ((child, full) :)
          linkStatus <- try (Files.getSymbolicLinkStatus (rawPath full)) :: IO (Either IOException Files.FileStatus)
          case linkStatus of
            Right status | Files.isDirectory status -> () <$ walk child
            _ -> pure ()
  _ <- walk ""
  readIORef found

-- | @path.mkdir(parents=True, exist_ok=True)@.
mkdirParents :: Text -> IO ()
mkdirParents path = do
  attempt <- try (Dir.createDirectory (rawPath path) 0o777)
  case attempt of
    Right () -> pure ()
    Left (e :: IOException)
      | ioe_errno e == Just (let Errno n = eNOENT in n) -> do
          let parent = pathParent path
          when (parent == path) (failWith e)
          mkdirParents parent
          again <- try (Dir.createDirectory (rawPath path) 0o777)
          case again of
            Right () -> pure ()
            Left (e' :: IOException)
              | ioe_errno e' == Just (let Errno n = eNOENT in n) -> failWith e'
              | otherwise -> existing e'
      | otherwise -> existing e
  where
    existing e = do
      directory <- isDir path
      unless directory (failWith e)
    failWith e = case ioe_errno e of
      Just n -> osError path (Errno n) >>= raise
      Nothing -> raise (PyError "OSError" (T.pack (show e)))

-- | @tempfile.TemporaryDirectory(prefix=prefix)@ in @tempfile.gettempdir()@.
withScratch :: Text -> (Text -> IO a) -> IO a
withScratch prefix action = do
  base <- temporaryRoot
  directory <- decodeName <$> mkdtemp (rawPath (joinPath base prefix))
  action directory `finally` removePathForcibly (T.unpack directory)
  where
    temporaryRoot = do
      candidates <- forM ["TMPDIR", "TEMP", "TMP"] lookupEnv
      pure (maybe "/tmp" T.pack (firstJust candidates))
    firstJust = \case
      [] -> Nothing
      Just value : _ | not (null value) -> Just value
      _ : rest -> firstJust rest

-- ---------------------------------------------------------------------------
-- Files

-- | @open(path, "rb").read()@.
readBytes :: Text -> IO ByteString
readBytes path = do
  fd <- onPath path (PIO.openFd (rawPath path) PIO.ReadOnly PIO.defaultFileFlags)
  flip finally (PIO.closeFd fd) $ do
    status <- onPath path (Files.getFdStatus fd)
    when (Files.isDirectory status) $ osError path (Errno 21) >>= raise
    onPath path (readAll fd)
  where
    readAll fd = do
      handle <- PIO.fdToHandle =<< PIO.dup fd
      BS.hGetContents handle

-- | @path.read_text(encoding="utf-8")@, as UTF-8 bytes with universal
-- newlines applied.
readText :: Text -> IO ByteString
readText path = do
  bytes <- readBytes path
  case decodeText bytes of
    Left (PyException name text) -> raise (PyError name text)
    Right text -> pure text

-- | @open(path, "wb").write(bytes)@.
writeBytes :: Text -> ByteString -> IO ()
writeBytes path bytes = withFd path (\fd -> writeAll path fd bytes)

-- | @path.write_text(text, encoding="utf-8")@.
writeText :: Text -> Text -> IO ()
writeText path text = writeBytes path (TE.encodeUtf8 text)

-- | @open(path, "w")@, then the action's writes; the file is closed (and
-- what was written stays) whatever the action does. Like the reference's
-- buffered file, the writes reach the file when it is closed.
withAppend :: Text -> ((ByteString -> IO ()) -> IO a) -> IO a
withAppend path action = do
  chunks <- newIORef []
  withFd path $ \fd ->
    action (\chunk -> modifyIORef' chunks (chunk :))
      `finally` (readIORef chunks >>= writeAll path fd . BS.concat . reverse)

-- | Open for writing (created, truncated), run the action, close.
withFd :: Text -> (Fd -> IO a) -> IO a
withFd path action = do
  fd <-
    onPath path $
      PIO.openFd (rawPath path) PIO.WriteOnly PIO.defaultFileFlags {PIO.trunc = True, PIO.creat = Just 0o666}
  action fd `finally` PIO.closeFd fd

writeAll :: Text -> Fd -> ByteString -> IO ()
writeAll path fd bytes
  | BS.null bytes = pure ()
  | otherwise = do
      written <- onPath path (PIO.fdWrite fd bytes)
      writeAll path fd (BS.drop (fromIntegral written) bytes)

-- | Remove a file if it is there; nothing else, and no complaint.
removeFileQuietly :: Text -> IO ()
removeFileQuietly path = void (try (Files.removeLink (rawPath path)) :: IO (Either IOException ()))

-- | @shutil.copyfile(src, dst)@.
copyFile :: Text -> Text -> IO ()
copyFile src dst = do
  sourceStatus <- statusOf src
  targetStatus <- statusOf dst
  case (sourceStatus, targetStatus) of
    (Just a, Just b)
      | Files.deviceID a == Files.deviceID b && Files.fileID a == Files.fileID b ->
          raise
            ( PyError
                "shutil.SameFileError"
                ("PosixPath(" <> strRepr src <> ") and PosixPath(" <> strRepr dst <> ") are the same file")
            )
    _ -> pure ()
  forM_' [(src, sourceStatus), (dst, targetStatus)] $ \(name, status) ->
    case status of
      Just s | Files.isNamedPipe s -> raise (PyError "shutil.SpecialFileError" ("`" <> name <> "` is a named pipe"))
      _ -> pure ()
  bytes <- readBytes src
  attempt <- try (writeBytes dst bytes)
  case attempt of
    Right () -> pure ()
    Left (e :: PyError)
      | e.cls == "IsADirectoryError" -> do
          present <- exists dst
          if present then raise e else raise (PyError "FileNotFoundError" ("Directory does not exist: " <> dst))
      | otherwise -> raise e
  where
    forM_' xs f = mapM_ f xs

-- ---------------------------------------------------------------------------
-- SQLite

-- | @sqlite3.connect(path)@, then @[dict(zip(names, row)) for row in
-- connection.execute(query).fetchall()]@, then @close()@.
--
-- Values convert as @sqlite3@ converts them (@TEXT@ decoded as strict
-- UTF-8), and every failure raises the @sqlite3@ exception class CPython
-- maps the SQLite result code to, with SQLite's message.
queryRows :: Text -> Text -> IO [[(Text, PV)]]
queryRows path query = do
  opened <- Direct.open (Direct.Utf8 (rawPath path))
  case opened of
    Left (code, Direct.Utf8 text) -> raise (PyError (sqliteClass code) (decodeName text))
    Right database -> flip finally (Direct.close database) $ do
      prepared <- Direct.prepare database (Direct.Utf8 (TE.encodeUtf8 query))
      case prepared of
        Left code -> failure database code
        Right Nothing -> pure []
        Right (Just statement) -> flip finally (Direct.finalize statement) $ do
          let loop acc = do
                stepped <- Direct.step statement
                case stepped of
                  Left code -> failure database code
                  Right Direct.Done -> pure (reverse acc)
                  Right Direct.Row -> do
                    row <- readRow statement
                    loop (row : acc)
          loop []
  where
    failure database code = do
      Direct.Utf8 text <- Direct.errmsg database
      raise (PyError (sqliteClass code) (decodeName text))

readRow :: Direct.Statement -> IO [(Text, PV)]
readRow statement = do
  count <- Direct.columnCount statement
  members <- forM [0 .. count - 1] $ \index -> do
    name <- maybe "" (\(Direct.Utf8 bytes) -> decodeName bytes) <$> Direct.columnName statement index
    kind <- Direct.columnType statement index
    value <- case kind of
      Direct.IntegerColumn -> PInt . toInteger <$> Direct.columnInt64 statement index
      Direct.FloatColumn -> PFloat <$> Direct.columnDouble statement index
      Direct.NullColumn -> pure PNone
      Direct.BlobColumn -> PBytes <$> Direct.columnBlob statement index
      Direct.TextColumn -> do
        Direct.Utf8 bytes <- Direct.columnText statement index
        case TE.decodeUtf8' bytes of
          Right text -> pure (PStr text)
          Left _ ->
            raise
              ( PyError
                  "sqlite3.OperationalError"
                  ( "Could not decode to UTF-8 column '"
                      <> name
                      <> "' with text '"
                      <> decodeName (BS.takeWhile (/= 0) bytes)
                      <> "'"
                  )
              )
    pure (name, value)
  pure (pyDict members)

-- | The exception class CPython's @sqlite3@ raises for a result code
-- (@get_exception_class@ in @Modules/_sqlite/util.c@).
sqliteClass :: Direct.Error -> Text
sqliteClass = \case
  Direct.ErrorInternal -> "sqlite3.InternalError"
  Direct.ErrorNotFound -> "sqlite3.InternalError"
  Direct.ErrorNoMemory -> "MemoryError"
  code
    | code `elem` operational -> "sqlite3.OperationalError"
  Direct.ErrorCorrupt -> "sqlite3.DatabaseError"
  Direct.ErrorTooBig -> "sqlite3.DataError"
  Direct.ErrorConstraint -> "sqlite3.IntegrityError"
  Direct.ErrorMismatch -> "sqlite3.IntegrityError"
  Direct.ErrorMisuse -> "sqlite3.InterfaceError"
  Direct.ErrorRange -> "sqlite3.InterfaceError"
  _ -> "sqlite3.DatabaseError"
  where
    operational =
      [ Direct.ErrorError
      , Direct.ErrorPermission
      , Direct.ErrorAbort
      , Direct.ErrorBusy
      , Direct.ErrorLocked
      , Direct.ErrorReadOnly
      , Direct.ErrorInterrupt
      , Direct.ErrorIO
      , Direct.ErrorFull
      , Direct.ErrorCan'tOpen
      , Direct.ErrorProtocol
      , Direct.ErrorEmpty
      , Direct.ErrorSchema
      ]

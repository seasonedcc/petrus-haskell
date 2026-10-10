module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (bracket, finally, try)
import Control.Monad (forM_, replicateM, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit, isHexDigit, isLower)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Text qualified as T
import Petrus.Json (Json (..), pythonFloatRepr)
import Petrus.Posix
import Petrus.TestSupport
import System.Directory
  ( createDirectory
  , createDirectoryLink
  , createFileLink
  , doesPathExist
  , getCurrentDirectory
  , listDirectory
  , removeFile
  , withCurrentDirectory
  )
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import System.Posix.Env qualified as Env
import System.Posix.Types (Fd)
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = hspec $ do
  flockSpec
  pathSpec
  atSpec
  fileSpec
  resourceSpec

withTemp :: (FilePath -> IO a) -> IO a
withTemp action = withSystemTempDirectory "petrus-posix" $ \dir -> realpath dir >>= action

-- A Python process holding (or trying) a flock on a path, driven by lines.
pythonLocker :: T.Text
pythonLocker =
  T.unlines
    [ "import fcntl, os, sys"
    , "path, mode = sys.argv[1], sys.argv[2]"
    , "fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)"
    , "kind = fcntl.LOCK_SH if mode == 'shared' else fcntl.LOCK_EX"
    , "print('ready', flush=True)"
    , "for line in sys.stdin:"
    , "    command = line.strip()"
    , "    if command == 'try':"
    , "        try:"
    , "            fcntl.flock(fd, kind | fcntl.LOCK_NB)"
    , "            print('acquired', flush=True)"
    , "        except BlockingIOError:"
    , "            print('busy', flush=True)"
    , "    elif command == 'unlock':"
    , "        fcntl.flock(fd, fcntl.LOCK_UN)"
    , "        print('released', flush=True)"
    , "    elif command == 'die':"
    , "        print('dying', flush=True)"
    , "        os.kill(os.getpid(), 9)"
    ]

withLocker :: FilePath -> String -> (PythonProcess -> IO a) -> IO a
withLocker path mode action =
  withPython pythonLocker [path, mode] $ \locker -> expectLine locker "ready" >> action locker

ask :: PythonProcess -> BC.ByteString -> IO BC.ByteString
ask locker command = sendLine locker command >> readLine locker

withLockFd :: FilePath -> (Fd -> IO a) -> IO a
withLockFd path = bracket (openLockFile path) closeFd

flockSpec :: Spec
flockSpec = describe "Flock" $ do
  it "excludes a second open file description in the same process" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLockFd path $ \first -> withLockFd path $ \second -> do
      tryLock first Exclusive `shouldReturn` True
      tryLock second Exclusive `shouldReturn` False
      unlock first
      tryLock second Exclusive `shouldReturn` True

  it "is refused while a Python fcntl.flock holder has the lock, and acquired after it releases" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLocker path "exclusive" $ \locker -> do
      ask locker "try" `shouldReturn` "acquired"
      withLockFd path $ \fd -> do
        tryLock fd Exclusive `shouldReturn` False
        tryLock fd Shared `shouldReturn` False
        ask locker "unlock" `shouldReturn` "released"
        tryLock fd Exclusive `shouldReturn` True

  it "refuses a Python fcntl.flock caller while Haskell holds the lock" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLockFd path $ \fd -> do
      tryLock fd Exclusive `shouldReturn` True
      withLocker path "exclusive" $ \locker -> do
        ask locker "try" `shouldReturn` "busy"
        withLocker path "shared" $ \reader -> ask reader "try" `shouldReturn` "busy"
        unlock fd
        ask locker "try" `shouldReturn` "acquired"

  it "shares a shared lock with Python and still excludes writers" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLocker path "shared" $ \reader -> do
      ask reader "try" `shouldReturn` "acquired"
      withLockFd path $ \fd -> do
        tryLock fd Shared `shouldReturn` True
        withLocker path "exclusive" $ \writer -> ask writer "try" `shouldReturn` "busy"
        withLockFd path $ \other -> tryLock other Exclusive `shouldReturn` False

  it "is released by the kernel when the Python holder dies" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLocker path "exclusive" $ \locker -> do
      ask locker "try" `shouldReturn` "acquired"
      withLockFd path $ \fd -> do
        tryLock fd Exclusive `shouldReturn` False
        ask locker "die" `shouldReturn` "dying"
        acquired <- timeout 10000000 (waitFor (tryLock fd Exclusive))
        acquired `shouldBe` Just ()

  it "blocks until a Python holder releases, and the wait is interruptible" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLocker path "exclusive" $ \locker -> do
      ask locker "try" `shouldReturn` "acquired"
      withLockFd path $ \fd -> do
        timeout 200000 (lock fd Exclusive) `shouldReturn` Nothing
        done <- newEmptyMVar
        void (forkIO (lock fd Exclusive >> putMVar done ()))
        threadDelay 200000
        tryReadMVar done `shouldReturn` Nothing
        ask locker "unlock" `shouldReturn` "released"
        timeout 5000000 (takeMVar done) `shouldReturn` Just ()
        ask locker "try" `shouldReturn` "busy"

  it "creates lock files with mode 0600" $ withTemp $ \dir -> do
    let path = dir </> "fresh.lock"
    withLockFd path (const (pure ()))
    status <- statAt Nothing path FollowLinks
    permissionBits status `shouldBe` 0o600

  it "revalidates the inode after waiting (Gondolin _locked)" $ withTemp $ \dir -> do
    let path = dir </> "lock"
    withLockFd path $ \holder -> do
      tryLock holder Exclusive `shouldReturn` True
      entered <- newEmptyMVar
      finished <- newEmptyMVar
      void . forkIO $
        withRevalidatedLock path 0o600 (do
          -- The lock now held must be on the file currently at the path.
          held <- withLockFd path (\probe -> tryLock probe Exclusive)
          putMVar entered held)
          `finally` putMVar finished ()
      threadDelay 200000
      tryReadMVar entered `shouldReturn` Nothing
      -- Replace the file while the waiter blocks on the old inode.
      removeFile path
      BS.writeFile path ""
      unlock holder
      timeout 5000000 (takeMVar entered) `shouldReturn` Just False
      timeout 5000000 (takeMVar finished) `shouldReturn` Just ()
    withLockFd path $ \fd -> tryLock fd Exclusive `shouldReturn` True
  where
    waitFor check = do
      ok <- check
      if ok then pure () else threadDelay 20000 >> waitFor check

-- Results from Python, one string per input; an exception becomes
-- "ExceptionName: message".
pythonStrings :: T.Text -> FilePath -> [FilePath] -> IO [String]
pythonStrings expression cwd inputs = do
  value <-
    pythonJson
      ( T.unlines
          [ "import json, os, sys"
          , "from pathlib import Path, PurePosixPath"
          , "os.chdir(sys.argv[1])"
          , "def run(p):"
          , "    try:"
          , "        return " <> expression
          , "    except Exception as error:"
          , "        return type(error).__name__ + ': ' + str(error)"
          , "print(json.dumps([run(p) for p in sys.argv[2:]]))"
          ]
      )
      (cwd : inputs)
  case value of
    Array items -> pure [T.unpack s | String s <- items]
    other -> fail ("unexpected Python output " ++ show other)

haskellStrings :: (FilePath -> IO FilePath) -> [FilePath] -> IO [String]
haskellStrings f = mapM $ \input -> do
  result <- try (f input)
  pure $ case result of
    Right value -> value
    Left (HomeDirectoryUnknown message) -> "RuntimeError: " ++ message

pathSpec :: Spec
pathSpec = describe "Path" $ do
  it "normalizes like PurePosixPath" $ do
    let inputs = ["", ".", "./", "a", "a/", "a//b", "a/./b/.", "/", "//", "///", "////a", "//a//b", "/../a", "a/../b", "...", "./.a", "~", "é/./ü//"]
    expected <- pythonStrings "str(PurePosixPath(p))" "/" inputs
    map purePath inputs `shouldBe` expected

  it "resolves exactly like Path.resolve (symlinks, .., loops, missing tails)" $ withTemp $ \dir -> do
    createDirectory (dir </> "dir")
    createDirectory (dir </> "é")
    BS.writeFile (dir </> "dir" </> "file") "x"
    createDirectoryLink "dir" (dir </> "link-dir")
    createDirectoryLink (dir </> "dir") (dir </> "abs-link")
    createDirectoryLink "link-dir" (dir </> "chain")
    createFileLink "loop-b" (dir </> "loop-a")
    createFileLink "loop-a" (dir </> "loop-b")
    createFileLink "self" (dir </> "self")
    createFileLink "missing/target" (dir </> "dangling")
    createFileLink "dir/file" (dir </> "file-link")
    createDirectoryLink ".." (dir </> "up")
    createDirectoryLink "../link-dir" (dir </> "dir" </> "back")
    createDirectoryLink "/tmp" (dir </> "tmp-link")
    let relative =
          [ "", ".", "..", "dir", "link-dir/../x", "loop-a/..", "chain/file", "dir/back/back/file"
          , "é", "é/../link-dir", "self", "up/x", "tmp-link/..", "missing/../dir"
          ]
        absolute =
          map
            (dir </>)
            [ "dir", "link-dir", "link-dir/file", "link-dir/../dir", "abs-link/file/..", "chain/file"
            , "loop-a", "loop-a/x", "self/x", "dangling", "dangling/more", "file-link/x", "dir/file/x/.."
            , "up/x", "dir/back/back/file", "missing/../dir", "tmp-link", "tmp-link/x/../y"
            ]
            ++ [dir ++ "//dir///./file", "/tmp", "/tmp/x/..", "/", "//", "//tmp", "///tmp", "/..", "/var/../tmp"]
        inputs = relative ++ absolute
    expected <- pythonStrings "str(Path(p).resolve())" dir inputs
    actual <- withCurrentDirectory dir (haskellStrings pathResolve inputs)
    actual `shouldBe` expected
    expectedReal <- pythonStrings "os.path.realpath(p)" dir inputs
    actualReal <- withCurrentDirectory dir (haskellStrings realpath inputs)
    actualReal `shouldBe` expectedReal

  it "resolves /tmp through the macOS /private symlink like Python" $ do
    resolved <- pathResolve "/tmp"
    when (os == "darwin") (resolved `shouldBe` "/private/tmp")

  it "expands ~ like Path.expanduser and os.path.expanduser for several HOME values" $ do
    original <- Env.getEnv "HOME"
    let inputs = ["~", "~/", "~/a/../b", "~//x", "~root", "~root/x", "~nosuchuser_petrus/x", "a/~", "/~", "~/~", "x"]
        restore = maybe (Env.unsetEnv "HOME") (\home -> Env.setEnv "HOME" home True) original
    flip finally restore $
      forM_ ([Nothing] ++ map Just ["/", "/custom//home//", "", "relative/home"]) $ \home -> do
        forM_ home (\value -> Env.setEnv "HOME" value True)
        cwd <- getCurrentDirectory
        expected <- pythonStrings "str(Path(p).expanduser())" cwd inputs
        haskellStrings pathExpandUser inputs `shouldReturn` expected
        expectedOs <- pythonStrings "os.path.expanduser(p)" cwd inputs
        haskellStrings expandUser inputs `shouldReturn` expectedOs

  it "matches the SQLite engine's expanduser().resolve() identity" $ withTemp $ \dir -> do
    createDirectoryLink dir (dir ++ "-alias")
    let inputs = [dir ++ "-alias/db.sqlite", dir </> "nested/../db.sqlite", "~/petrus-no-such/db.sqlite"]
    expected <- pythonStrings "str(Path(p).expanduser().resolve())" dir inputs
    haskellStrings expandAndResolve inputs `shouldReturn` expected
    removeFile (dir ++ "-alias")

atSpec :: Spec
atSpec = describe "At" $ do
  it "walks directories without following symlinks" $ withTemp $ \dir -> do
    createDirectory (dir </> "real")
    createDirectoryLink "real" (dir </> "link")
    bracket (openDirectoryAt Nothing dir) closeFd $ \root -> do
      bracket (openDirectoryAt (Just root) "real") closeFd (const (pure ()))
      openDirectoryAt (Just root) "link" `shouldThrow` anyIOException

  it "creates private files exclusively, refusing existing names and dangling symlinks" $ withTemp $ \dir -> do
    createFileLink "nowhere" (dir </> "dangling")
    bracket (openDirectoryAt Nothing dir) closeFd $ \root -> do
      fd <- createExclusiveAt (Just root) "leaf" 0o600
      writeAll fd "secret"
      fsyncFd fd
      closeFd fd
      createExclusiveAt (Just root) "leaf" 0o600 `shouldThrow` isAlreadyExistsError
      createExclusiveAt (Just root) "dangling" 0o600 `shouldThrow` isAlreadyExistsError
      doesPathExist (dir </> "nowhere") `shouldReturn` False
      status <- statAt (Just root) "leaf" NoFollowLinks
      (isRegularFile status, permissionBits status, statLinkCount status, statSize status)
        `shouldBe` (True, 0o600, 1, 6)
    BS.readFile (dir </> "leaf") `shouldReturn` "secret"

  it "stats like os.stat / os.lstat / os.fstat" $ withTemp $ \dir -> do
    BS.writeFile (dir </> "file") "12345"
    createFileLink "file" (dir </> "link")
    value <-
      pythonJson
        "import json, os, sys\nd = sys.argv[1]\nst = os.stat(d + '/link'); lst = os.lstat(d + '/link')\nprint(json.dumps([[s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_uid, s.st_gid, s.st_size, s.st_mtime_ns] for s in (st, lst)]))"
        [dir]
    followed <- statAt Nothing (dir </> "link") FollowLinks
    lstatted <- statAt Nothing (dir </> "link") NoFollowLinks
    let fields s =
          Array
            ( map
                (Int . toInteger)
                [ statDevice s, statInode s, statMode s, statLinkCount s, statUid s, statGid s, statSize s
                , statModifySeconds s * 1000000000 + statModifyNanoseconds s
                ]
            )
    value `shouldBe` Array [fields followed, fields lstatted]
    (isSymbolicLink lstatted, isRegularFile followed) `shouldBe` (True, True)
    bracket (openAt Nothing (dir </> "file") ReadOnly defaultFileFlags {cloexec = True}) closeFd $ \fd -> do
      opened <- fdStat fd
      statInode opened `shouldBe` statInode followed

  it "makes, renames, lists and removes entries relative to directory descriptors" $ withTemp $ \dir -> do
    bracket (openDirectoryAt Nothing dir) closeFd $ \root -> do
      mkdirAt (Just root) "a" 0o700
      mkdirAt (Just root) "b" 0o755
      mkdirAt (Just root) "a" 0o700 `shouldThrow` isAlreadyExistsError
      status <- statAt (Just root) "a" NoFollowLinks
      (isDirectory status, permissionBits status) `shouldBe` (True, 0o700)
      bracket (openDirectoryAt (Just root) "a") closeFd $ \a ->
        bracket (openDirectoryAt (Just root) "b") closeFd $ \b -> do
          forM_ ["one", "two", "é"] $ \name -> createExclusiveAt (Just a) name 0o600 >>= closeFd
          createExclusiveAt (Just b) "two" 0o600 >>= \fd -> writeAll fd "old" >> closeFd fd
          names <- listDirectoryFd a
          expected <- pythonJson "import json, os, sys\nprint(json.dumps(sorted(os.listdir(sys.argv[1]))))" [dir </> "a"]
          Array (map (String . T.pack) (sort names)) `shouldBe` expected
          -- Listing again from the same descriptor starts over.
          sort <$> listDirectoryFd a `shouldReturn` sort names
          renameAt (Just a) "two" (Just b) "two"
          BS.readFile (dir </> "b" </> "two") `shouldReturn` ""
          unlinkAt (Just a) "one"
          unlinkAt (Just a) "one" `shouldThrow` isDoesNotExistError
          unlinkAt (Just a) "é"
          listDirectoryFd a `shouldReturn` []
      removeDirectoryAt (Just root) "a"
      listDirectory dir `shouldReturn` ["b"]

  it "changes permissions on a descriptor" $ withTemp $ \dir -> do
    fd <- createExclusiveAt Nothing (dir </> "f") 0o600
    fchmod fd 0o640
    closeFd fd
    permissionBits <$> statAt Nothing (dir </> "f") FollowLinks `shouldReturn` 0o640

fileSpec :: Spec
fileSpec = describe "File" $ do
  it "atomically writes with mode 0600 and leaves no temporary behind" $ withTemp $ \dir -> do
    let target = dir </> "state.json"
    atomicWriteFile defaultAtomicWrite target "{\"a\":1}"
    atomicWriteFile defaultAtomicWrite {syncDirectory = True} target "{\"a\":2}"
    BS.readFile target `shouldReturn` "{\"a\":2}"
    listDirectory dir `shouldReturn` ["state.json"]
    permissionBits <$> statAt Nothing target FollowLinks `shouldReturn` 0o600

  it "leaves the destination untouched and removes the temporary when the replace fails" $ withTemp $ \dir -> do
    let target = dir </> "occupied"
    createDirectory target
    BS.writeFile (target </> "keep") "kept"
    atomicWriteFile defaultAtomicWrite target "new" `shouldThrow` anyIOException
    listDirectory dir `shouldReturn` ["occupied"]
    BS.readFile (target </> "keep") `shouldReturn` "kept"

  it "names temporaries exactly as each upstream site does" $ do
    let TempNaming mkstemp = mkstempNaming
        TempNaming hidden = hiddenUuidNaming
        TempNaming registry = uuidNaming "registry"
        TempNaming named = prefixNaming (\name -> "." ++ name ++ ".")
    names <- replicateM 20 (mkstemp "x")
    forM_ names $ \name -> do
      take 3 name `shouldBe` "tmp"
      length name `shouldBe` 11
      drop 3 name `shouldSatisfy` all (\c -> isLower c || isDigit c || c == '_')
    hiddenName <- hidden "thread.json"
    hiddenName `shouldSatisfy` \n -> ".thread.json." `isPrefixOf` n && ".tmp" `isSuffixOf` n && length n == 13 + 32 + 4
    registryName <- registry "registry.json"
    registryName `shouldSatisfy` \n -> "registry." `isPrefixOf` n && ".tmp" `isSuffixOf` n && length n == 9 + 32 + 4
    namedName <- named "results.json"
    namedName `shouldSatisfy` \n -> ".results.json." `isPrefixOf` n && length n == 14 + 8

  it "draws uuid4 hex strings Python accepts as version 4, RFC 4122" $ do
    hexes <- replicateM 50 uuid4Hex
    forM_ hexes $ \hex -> (length hex, all isHexDigit hex, all (not . (`elem` ['A' .. 'F'])) hex) `shouldBe` (32, True, True)
    value <-
      pythonJson
        "import json, sys, uuid\nprint(json.dumps(all(uuid.UUID(h).version == 4 and uuid.UUID(h).variant == uuid.RFC_4122 and uuid.UUID(h).hex == h for h in sys.argv[1:])))"
        hexes
    value `shouldBe` Bool True

  it "creates parents like Path.mkdir(parents=True, exist_ok=True)" $ withTemp $ \dir -> do
    let leaf = dir </> "a" </> "b" </> "c"
    makeDirectories leaf 0o700
    makeDirectories leaf 0o700
    permissionBits <$> statAt Nothing leaf FollowLinks `shouldReturn` 0o700
    BS.writeFile (dir </> "file") ""
    makeDirectories (dir </> "file") 0o700 `shouldThrow` isAlreadyExistsError
    makeDirectories (dir </> "file" </> "sub") 0o700 `shouldThrow` anyIOException
    fsyncPath (dir </> "a")

resourceSpec :: Spec
resourceSpec = describe "Resource" $ do
  it "reports the peak resident set in MB with the platform divisor" $ do
    rss <- maxRss
    rss `shouldSatisfy` (> 0)
    mb <- maxRssMb
    let divisor = if os == "darwin" then 1024 * 1024 else 1024 :: Integer
    mb `shouldBe` pythonRound 1 (fromIntegral rss / fromIntegral divisor)
    mb `shouldSatisfy` (> 0)

  it "takes an exact integer fast path that agrees with the general rounding" $
    forM_ [(n, k) | k <- [10, 20], n <- [0, 1, 51, 52, 53, 104857, 104858, 5242880, 5347737, 5347738, 123456789, 2 ^ (52 :: Int) + 12345]] $ \(n, k) ->
      roundTenthsOfPowerOfTwo n k `shouldBe` pythonRound 1 (fromIntegral n / 2 ^ k)

  it "matches os.sysconf('SC_PAGE_SIZE')" $ do
    size <- pageSize
    value <- pythonJson "import os\nprint(os.sysconf('SC_PAGE_SIZE'))" []
    value `shouldBe` Int size

  it "reads /proc/self/statm where it exists, and is absent elsewhere" $ do
    current <- currentRssMb
    if os == "darwin" then current `shouldBe` Nothing else current `shouldSatisfy` maybe False (> 0)

  it "computes current_rss_mb from statm exactly like Python" $ do
    let samples = ["1000 2560 3 4 0 5 0\n", "0 1 0", "9 123456789 1", "1", "", "x y", "1 -5 2", "1 +7 2"]
    forM_ [4096, 16384] $ \size -> do
      value <-
        pythonJson
          ( T.unlines
              [ "import json, sys"
              , "size = int(sys.argv[1])"
              , "def rss(text):"
              , "    try:"
              , "        return round(int(text.split()[1]) * size / 1024**2, 1)"
              , "    except (ValueError, IndexError):"
              , "        return None"
              , "print(json.dumps([rss(t) for t in sys.argv[2:]]))"
              ]
          )
          (show size : map BC.unpack samples)
      Array (map (maybe Null Float . currentRssMbFrom size) samples) `shouldBe` value

  it "rounds exactly like Python's round(x, n)" $ do
    let values =
          [0.05, 0.15, 0.25, 0.35, 0.45, 2.675, 1.45, -0.05, -0.04, -0.0, 0.0, 1e300, 5e-324, 123456789.25, 0.5, 1.5, 2.5, -2.5, 1e16 + 2, 7.0e-2]
            ++ [fromIntegral n / 1000 | n <- [0 :: Int, 7 .. 3000]]
            ++ [fromIntegral n / 7 | n <- [1 :: Int .. 200]]
        cases = [(x, d) | x <- values, d <- [0, 1, 2, 3, -1, -2]]
    value <-
      pythonJson
        "import json, sys\nargs = sys.argv[1:]\nprint(json.dumps([repr(round(float(args[i]), int(args[i + 1]))) for i in range(0, len(args), 2)]))"
        (concat [[pythonFloatRepr x, show d] | (x, d) <- cases])
    Array [String (T.pack (pythonFloatRepr (pythonRound d x))) | (x, d) <- cases] `shouldBe` value

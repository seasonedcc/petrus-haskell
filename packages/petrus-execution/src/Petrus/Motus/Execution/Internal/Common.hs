-- | Helpers shared by every provider (upstream @_execution/providers.py@
-- module-level functions).
module Petrus.Motus.Execution.Internal.Common
  ( operationLabel
  , specLabel
  , specFingerprint
  , checkOperationId
  , checkedHostCwd
  , checkedGuestCwd
  , missingCapabilitiesError
  , requireSupportedCapabilities
  , truncateOutput
  , newUuid4
  , uuidHex
  , replaceFile
  , shortTempName
  ) where

import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isPrefixOf)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Numeric (showHex)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Internal.PosixPath
  ( RealpathMode (..)
  , fromRawPath
  , joinPath
  , realpath
  , toRawPath
  )
import Petrus.Json.Python (pythonListRepr, pythonStrRepr)
import Petrus.Posix.File (AtomicWrite (..), TempNaming (..), atomicWriteFile, defaultAtomicWrite)
import Crypto.Random (getRandomBytes)
import Control.Exception (throwIO)

operationLabel :: Text
operationLabel = "run.petrus.operation"

specLabel :: Text
specLabel = "run.petrus.spec"

-- | @_fingerprint@: sha256 of @json.dumps({"image": image}, sort_keys=True,
-- separators=(",", ":"))@ as hex.
specFingerprint :: EnvironmentSpec -> Text
specFingerprint spec =
  let options = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True}
      material = case dumps options (Object [("image", maybe Null String (specImage spec))]) of
        Right bytes -> bytes
        Left _ -> error "fingerprint material is always finite"
   in T.pack (show (hash material :: Digest SHA256))

-- | @_operation_id@: @[A-Za-z0-9][A-Za-z0-9_.-]{0,127}@.
checkOperationId :: Text -> IO ()
checkOperationId value =
  unless (valid value) (throwExecution ValueError "operation id must be a safe non-empty provider label")
  where
    valid v = case T.uncons v of
      Just (first, rest) -> alnum first && T.length rest <= 127 && T.all (\c -> alnum c || c `elem` ("_.-" :: String)) rest
      Nothing -> False
    alnum c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | @f"unsupported capabilities: {sorted(missing)}"@.
missingCapabilitiesError :: Set Capability -> ExecutionError
missingCapabilitiesError missing =
  valueError ("unsupported capabilities: " <> pythonListRepr (map (pythonStrRepr . capabilityKey) (Set.toAscList missing)))

requireSupportedCapabilities :: Set Capability -> EnvironmentSpec -> IO ()
requireSupportedCapabilities supported spec = do
  let missing = specRequiredCapabilities spec `Set.difference` supported
  unless (Set.null missing) (throwIO (missingCapabilitiesError missing))

-- | @_checked_host_cwd@: the resolved cwd must stay under the resolved
-- workspace.
checkedHostCwd :: FilePath -> FilePath -> IO FilePath
checkedHostCwd workspace relative = do
  rawWorkspace <- toRawPath workspace
  rawRelative <- toRawPath relative
  resolvedCwd <- either (const escape) pure =<< realpath NonStrict (joinPath rawWorkspace rawRelative)
  resolvedRoot <- either (const escape) pure =<< realpath NonStrict rawWorkspace
  let rootParts = splitParts resolvedRoot
      cwdParts = splitParts resolvedCwd
  unless (rootParts `isPrefixOf` cwdParts) escape
  fromRawPath resolvedCwd
  where
    escape :: IO a
    escape = throwExecution ValueError "command cwd escapes the workspace"
    splitParts = filter (not . B.null) . B.split 47

-- | @_checked_guest_cwd@: lexical resolution of a guest-relative cwd.
checkedGuestCwd :: Text -> FilePath -> IO Text
checkedGuestCwd workspace relative = do
  let rootParts = filter (\p -> not (T.null p) && p /= ".") (T.splitOn "/" workspace)
      childText = T.pack relative
      childParts = filter (\p -> not (T.null p) && p /= ".") (T.splitOn "/" childText)
      anchorIsRoot = "/" `T.isPrefixOf` workspace && not ("//" `T.isPrefixOf` workspace && not ("///" `T.isPrefixOf` workspace))
  when
    ( not anchorIsRoot
        || ".." `elem` rootParts
        || "/" `T.isPrefixOf` childText
        || T.elem '\NUL' workspace
        || T.elem '\NUL' childText
    )
    escape
  let boundary = length rootParts
      step parts part
        | part == ".." = if length parts == boundary then Nothing else Just (init parts)
        | otherwise = Just (parts <> [part])
  case foldlM' step rootParts childParts of
    Nothing -> escape
    Just parts -> pure ("/" <> T.intercalate "/" parts)
  where
    escape :: IO a
    escape = throwExecution ValueError "command cwd escapes the workspace"
    foldlM' f = go
      where
        go acc [] = Just acc
        go acc (x : xs) = f acc x >>= \next -> go next xs

-- | Upstream @_result@ output bounding: @stdout[:limit]@ and
-- @stderr[:limit - len(stdout)]@, truncated when anything was dropped.
truncateOutput :: Int -> Bool -> ByteString -> ByteString -> (ByteString, ByteString, Bool)
truncateOutput limit overflow out err =
  let truncated = overflow || B.length out + B.length err > limit
      out' = B.take limit out
      err' = B.take (max 0 (limit - B.length out')) err
   in (out', err', truncated)

-- | @str(uuid.uuid4())@.
newUuid4 :: IO Text
newUuid4 = do
  bytes <- uuid4Bytes
  let hex = uuidHexOf bytes
  pure
    ( T.intercalate
        "-"
        [T.take 8 hex, T.take 4 (T.drop 8 hex), T.take 4 (T.drop 12 hex), T.take 4 (T.drop 16 hex), T.drop 20 hex]
    )

-- | Atomically replace a file: a mode-0600 temporary file beside it, named
-- by the action, written, fsynced and renamed over it (petrus-posix's
-- 'atomicWriteFile'; the directory is not fsynced).
replaceFile :: IO FilePath -> FilePath -> ByteString -> IO ()
replaceFile name = atomicWriteFile defaultAtomicWrite {tempNaming = TempNaming (const name)}

-- | @tmp@ and eight hex digits: the temporary name of artifact blobs and
-- of a compacted timeline.
shortTempName :: IO FilePath
shortTempName = ("tmp" <>) . T.unpack . T.take 8 <$> uuidHex

-- | @uuid.uuid4().hex@.
uuidHex :: IO Text
uuidHex = uuidHexOf <$> uuid4Bytes

uuid4Bytes :: IO [Word8]
uuid4Bytes = do
  bytes <- B.unpack <$> (getRandomBytes 16 :: IO ByteString)
  pure
    [ case index of
        6 -> (byte .&. 0x0f) .|. 0x40
        8 -> (byte .&. 0x3f) .|. 0x80
        _ -> byte
    | (index, byte) <- zip [0 :: Int ..] bytes
    ]

uuidHexOf :: [Word8] -> Text
uuidHexOf = T.pack . concatMap (\b -> let s = showHex b "" in if length s == 1 then '0' : s else s)

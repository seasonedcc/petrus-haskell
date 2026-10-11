-- | A small tar codec that reproduces CPython 3.14 @tarfile@ byte for byte.
--
-- Workspace archives are content-addressed (their SHA-256 digests are
-- persisted by callers), so the writer must emit exactly the bytes CPython's
-- @tarfile@ emits in @PAX_FORMAT@ for the members @workspace_archive@ adds,
-- and the reader must accept, reject, and interpret archives exactly as
-- @tarfile.open(mode="r:*")@ followed by @getmembers()@ does.  Names are
-- kept as raw bytes: CPython decodes them with @surrogateescape@, which is a
-- bijection, so nothing is lost.
module Petrus.Motus.Execution.Archive.Tar
  ( -- * Constants
    blockSize
  , recordSize
  , paddedSize
    -- * Writing
  , WriteKind (..)
  , WriteMember (..)
  , memberHeader
  , archiveTrailerLength
    -- * Reading
  , MTime (..)
  , Member (..)
  , ReadFailure (..)
  , readTar
  , isRegular
  , isDirectory
  , isSymlink
  , isHardlink
    -- * Type flags
  , regType
  , aregType
  , lnkType
  , symType
  , dirType
  , contType
  , gnuSparse
  ) where

import Control.Monad (forM, unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Unsafe qualified as BU
import Data.Int (Int8)
import Data.Word (Word8)
import Numeric (showOct)
import Petrus.Json.Python (fsDecode, isPythonSpace, parsePythonInt)
import Petrus.Motus.Execution.Internal.PyText

-- ---------------------------------------------------------------------------
-- Constants

blockSize :: Int
blockSize = 512

recordSize :: Int
recordSize = 20 * blockSize

-- | Round a byte count up to a whole number of blocks.
paddedSize :: Int -> Int
paddedSize n = ((n + blockSize - 1) `div` blockSize) * blockSize

regType, aregType, lnkType, symType, chrType, blkType, dirType, fifoType, contType :: Word8
regType = 0x30
aregType = 0x00
lnkType = 0x31
symType = 0x32
chrType = 0x33
blkType = 0x34
dirType = 0x35
fifoType = 0x36
contType = 0x37

gnuLongName, gnuLongLink, gnuSparse, xhdType, xglType, solarisXhdType :: Word8
gnuLongName = 0x4C
gnuLongLink = 0x4B
gnuSparse = 0x53
xhdType = 0x78
xglType = 0x67
solarisXhdType = 0x58

supportedTypes, regularTypes, gnuTypes :: [Word8]
supportedTypes =
  [ regType, aregType, lnkType, symType, dirType, fifoType, contType, chrType, blkType
  , gnuLongName, gnuLongLink, gnuSparse
  ]
regularTypes = [regType, aregType, contType, gnuSparse]
gnuTypes = [gnuLongName, gnuLongLink, gnuSparse]

posixMagic :: ByteString
posixMagic = "ustar\NUL00"

-- ---------------------------------------------------------------------------
-- Writing

-- | What @TarFile.gettarinfo@ observed for one workspace path.
data WriteKind
  = -- | A regular file with this many data bytes.
    WriteFile Int
  | WriteDirectory
  | -- | A symlink with its raw @readlink@ target.
    WriteSymlink ByteString
  | -- | A hard link to an already archived name.
    WriteHardlink ByteString
  deriving stock (Eq, Show)

data WriteMember = WriteMember
  { writeName :: ByteString
  -- ^ Relative POSIX path, raw bytes, no trailing slash.
  , writeMode :: Int
  -- ^ @st_mode@ (only the low 12 bits are written).
  , writeKind :: WriteKind
  }
  deriving stock (Eq, Show)

-- | The header blocks @TarFile.addfile@ writes for one member in
-- @PAX_FORMAT@ with uid/gid/mtime zeroed and empty owner names: an optional
-- @././\@PaxHeader@ extended header followed by the ustar header.
memberHeader :: WriteMember -> ByteString
memberHeader member = paxBlock <> ustar
  where
    name = case writeKind member of
      WriteDirectory -> writeName member <> "/"
      _ -> writeName member
    linkname = case writeKind member of
      WriteSymlink target -> target
      WriteHardlink target -> target
      _ -> ""
    (typeflag, size) = case writeKind member of
      WriteFile n -> (regType, n)
      WriteDirectory -> (dirType, 0)
      WriteSymlink _ -> (symType, 0)
      WriteHardlink _ -> (lnkType, 0)
    needsPax value = not (B.all (< 0x80) value) || codePointLength value > 100
    paxEntries =
      [("path", name) | needsPax name] ++ [("linkpath", linkname) | needsPax linkname]
    paxBlock
      | null paxEntries = B.empty
      | otherwise = paxHeader paxEntries
    ustar =
      ustarHeader
        (asciiReplace name)
        (writeMode member .&. 0o7777)
        (fromIntegral size)
        typeflag
        (asciiReplace linkname)

-- | @TarInfo._create_pax_generic_header@ for an extended (@x@) header.
paxHeader :: [(ByteString, ByteString)] -> ByteString
paxHeader entries = ustarHeader "././@PaxHeader" 0 (fromIntegral (B.length records)) xhdType "" <> padBlock records
  where
    binary = any (not . isStrictUtf8 . snd) entries
    records =
      (if binary then "21 hdrcharset=BINARY\n" else B.empty)
        <> B.concat [paxRecord keyword value | (keyword, value) <- entries]

paxRecord :: ByteString -> ByteString -> ByteString
paxRecord keyword value = BC.pack (show total) <> " " <> keyword <> "=" <> value <> "\n"
  where
    base = B.length keyword + B.length value + 3
    total = fixpoint 0
    fixpoint p =
      let n = base + length (show p)
       in if n == p then p else fixpoint n

padBlock :: ByteString -> ByteString
padBlock bytes = bytes <> B.replicate (paddedSize (B.length bytes) - B.length bytes) 0

-- | @TarInfo._create_header@ with USTAR layout, ASCII/replace encoding,
-- zero uid/gid/mtime and empty owner names.
ustarHeader :: ByteString -> Int -> Integer -> Word8 -> ByteString -> ByteString
ustarHeader name mode size typeflag linkname = withChecksum
  where
    field len bytes = B.take len bytes <> B.replicate (len - min len (B.length bytes)) 0
    octal digits n =
      let s = showOct n ""
       in BC.pack (replicate (digits - 1 - length s) '0' ++ s) <> "\NUL"
    raw =
      B.concat
        [ field 100 name
        , octal 8 mode
        , octal 8 (0 :: Int)
        , octal 8 (0 :: Int)
        , octal 12 size
        , octal 12 (0 :: Int)
        , "        "
        , B.singleton typeflag
        , field 100 linkname
        , posixMagic
        , B.replicate 32 0
        , B.replicate 32 0
        , B.replicate 8 0
        , B.replicate 8 0
        , B.replicate 155 0
        , B.replicate 12 0
        ]
    checksum = B.foldl' (\acc w -> acc + fromIntegral w) (0 :: Int) raw
    rendered = let s = showOct checksum "" in BC.pack (replicate (6 - length s) '0' ++ s) <> "\NUL"
    withChecksum = B.take 148 raw <> rendered <> B.drop 155 raw

-- | Bytes @TarFile.close@ appends after @offset@ bytes of members: two zero
-- blocks, then zero padding to a whole 'recordSize'.
archiveTrailerLength :: Int -> Int
archiveTrailerLength offset =
  let afterEnd = offset + 2 * blockSize
      remainder = afterEnd `mod` recordSize
   in 2 * blockSize + (if remainder > 0 then recordSize - remainder else 0)

-- ---------------------------------------------------------------------------
-- Reading

-- | A member's modification time: header and integer fields give an
-- 'Integer'; a PAX @mtime@ record is parsed with @float()@.
data MTime = MTimeInt Integer | MTimeFloat Double
  deriving stock (Eq, Show)

-- | One @TarInfo@ as @getmembers()@ returns it.
data Member = Member
  { memberName :: ByteString
  , memberLinkname :: ByteString
  , memberType :: Word8
  , memberMode :: Integer
  , memberUid :: Integer
  , memberGid :: Integer
  , memberSize :: Integer
  , memberMtime :: MTime
  , memberOffset :: Integer
  , memberOffsetData :: Integer
  , memberSparse :: Maybe [(Integer, Integer)]
  }
  deriving stock (Eq, Show)

isRegular, isDirectory, isSymlink, isHardlink :: Member -> Bool
isRegular m = memberType m `elem` regularTypes
isDirectory m = memberType m == dirType
isSymlink m = memberType m == symType
isHardlink m = memberType m == lnkType

-- | Why reading failed, mirroring which Python exception escapes
-- @tarfile.open@/@getmembers@.
data ReadFailure
  = -- | A @tarfile.TarError@ (always @ReadError@ here) with @str(e)@.
    ReadFailure String
  | -- | A non-tar Python exception (class name, message) that CPython lets
    -- escape for some malformed sparse metadata.
    PythonFailure String String
  deriving stock (Eq, Show)

data HeaderError
  = EmptyHeader
  | TruncatedHeader
  | EofHeader
  | InvalidHeader String
  | SubsequentHeader String

headerMessage :: HeaderError -> String
headerMessage = \case
  EmptyHeader -> "empty header"
  TruncatedHeader -> "truncated header"
  EofHeader -> "end of file header"
  InvalidHeader m -> m
  SubsequentHeader m -> m

data Failure
  = HeaderFailure HeaderError
  | ReadErr String
  | PyErr String String

data RState = RState
  { rsData :: ByteString
  , rsPos :: Integer
  , rsOffset :: Integer
  , rsGlobal :: [(ByteString, ByteString)]
  }

newtype R a = R {runR :: RState -> (Either Failure a, RState)}

instance Functor R where
  fmap f (R g) = R $ \s -> let (r, s') = g s in (fmap f r, s')

instance Applicative R where
  pure x = R (\s -> (Right x, s))
  R f <*> R g = R $ \s -> case f s of
    (Left e, s') -> (Left e, s')
    (Right h, s') -> let (r, s'') = g s' in (fmap h r, s'')

instance Monad R where
  R g >>= k = R $ \s -> case g s of
    (Left e, s') -> (Left e, s')
    (Right x, s') -> runR (k x) s'

failWith :: Failure -> R a
failWith e = R (\s -> (Left e, s))

invalid :: R a
invalid = failWith (HeaderFailure (InvalidHeader "invalid header"))

liftEither :: Either Failure a -> R a
liftEither = either failWith pure

getsR :: (RState -> a) -> R a
getsR f = R (\s -> (Right (f s), s))

modifyR :: (RState -> RState) -> R ()
modifyR f = R (\s -> (Right (), f s))

-- | Catch only @HeaderError@s (as @except HeaderError@ does).
catchHeader :: R a -> (HeaderError -> R a) -> R a
catchHeader (R g) handler = R $ \s -> case g s of
  (Left (HeaderFailure e), s') -> runR (handler e) s'
  other -> other

-- | @BytesIO.read(n)@.
readBytes :: Integer -> R ByteString
readBytes n = R $ \s ->
  let total = fromIntegral (B.length (rsData s)) :: Integer
      pos = rsPos s
      available = max 0 (min n (total - pos))
      chunk =
        if available <= 0
          then B.empty
          else B.take (fromIntegral available) (B.drop (fromIntegral pos) (rsData s))
   in (Right chunk, s {rsPos = pos + fromIntegral (B.length chunk)})

-- | @nts@: cut at the first NUL.
nts :: ByteString -> ByteString
nts = B.takeWhile (/= 0)

-- | @nti@: numeric header field (base-256 or octal).
nti :: ByteString -> Either Failure Integer
nti s = case B.uncons s of
  Nothing -> Left (PyErr "IndexError" "index out of range")
  Just (first, rest)
    | first == 0o200 || first == 0o377 ->
        let n = B.foldl' (\acc w -> acc * 256 + fromIntegral w) 0 rest
         in Right (if first == 0o377 then negate (256 ^ B.length rest - n) else n)
    | otherwise ->
        let text = nts s
         in if B.any (>= 0x80) text
              then Left (HeaderFailure (InvalidHeader "invalid header"))
              else case octalInt (BC.unpack text) of
                Just n -> Right n
                Nothing -> Left (HeaderFailure (InvalidHeader "invalid header"))

-- | @int(s.strip() or "0", 8)@.
octalInt :: String -> Maybe Integer
octalInt raw =
  let stripped = trim raw
   in if null stripped then Just 0 else signed stripped
  where
    trim = reverse . dropWhile isPythonSpace . reverse . dropWhile isPythonSpace
    signed = \case
      '-' : rest -> negate <$> prefixed rest
      '+' : rest -> prefixed rest
      rest -> prefixed rest
    prefixed = \case
      '0' : o : rest | o == 'o' || o == 'O' -> case rest of
        '_' : more -> digits more
        more -> digits more
      rest -> digits rest
    digits = \case
      [] -> Nothing
      c : rest | isOct c -> go (val c) rest
      _ -> Nothing
    go acc [] = Just acc
    go acc ('_' : c : rest) | isOct c = go (acc * 8 + val c) rest
    go acc (c : rest) | isOct c = go (acc * 8 + val c) rest
    go _ _ = Nothing
    isOct c = c >= '0' && c <= '7'
    val c = fromIntegral (fromEnum c - fromEnum '0')

-- | @_block@: round up to blocks, rejecting negative counts.
block :: Integer -> R Integer
block count
  | count < 0 = failWith (HeaderFailure (InvalidHeader "invalid offset"))
  | otherwise = pure (((count + 511) `div` 512) * 512)

calcChecksums :: ByteString -> (Integer, Integer)
calcChecksums buf =
  let bytes = B.take 148 buf <> B.drop 156 buf
      unsigned = B.foldl' (\acc w -> acc + fromIntegral w) 256 bytes
      signedSum = B.foldl' (\acc w -> acc + fromIntegral (fromIntegral w :: Int8)) 256 bytes
   in (unsigned, signedSum)

type SparseStructs = ([(Integer, Integer)], Bool, Integer)

emptyMember :: Member
emptyMember = Member "" "" regType 0 0 0 0 (MTimeInt 0) 0 0 Nothing

-- | @TarInfo._frombuf@.
frombuf :: Bool -> ByteString -> Either Failure (Member, Maybe SparseStructs)
frombuf dircheck buf
  | B.null buf = Left (HeaderFailure EmptyHeader)
  | B.length buf /= blockSize = Left (HeaderFailure TruncatedHeader)
  | B.all (== 0) buf = Left (HeaderFailure EofHeader)
  | otherwise = do
      chksum <- nti (slice 148 156)
      let (unsigned, signedSum) = calcChecksums buf
      unless (chksum == unsigned || chksum == signedSum) $
        Left (HeaderFailure (InvalidHeader "bad checksum"))
      mode <- nti (slice 100 108)
      uid <- nti (slice 108 116)
      gid <- nti (slice 116 124)
      size <- nti (slice 124 136)
      mtime <- nti (slice 136 148)
      let typeflag = BU.unsafeIndex buf 156
          name0 = nts (slice 0 100)
          linkname = nts (slice 157 257)
      _ <- nti (slice 329 337)
      _ <- nti (slice 337 345)
      let prefix = nts (slice 345 500)
          type1 =
            if dircheck && typeflag == aregType && "/" `B.isSuffixOf` name0
              then dirType
              else typeflag
      sparse <-
        if type1 == gnuSparse
          then do
            structs <- forM [0 .. 3 :: Int] $ \i -> do
              let pos = 386 + i * 24
              offset <- nti (slice pos (pos + 12))
              numbytes <- nti (slice (pos + 12) (pos + 24))
              pure (offset, numbytes)
            origsize <- nti (slice 483 495)
            pure (Just (structs, BU.unsafeIndex buf 482 /= 0, origsize))
          else pure Nothing
      let name1 = if type1 == dirType then BC.dropWhileEnd (== '/') name0 else name0
          name2 =
            if not (B.null prefix) && type1 `notElem` gnuTypes
              then prefix <> "/" <> name1
              else name1
      pure
        ( emptyMember
            { memberName = name2
            , memberLinkname = linkname
            , memberType = type1
            , memberMode = mode
            , memberUid = uid
            , memberGid = gid
            , memberSize = size
            , memberMtime = MTimeInt mtime
            }
        , sparse
        )
  where
    slice a b = B.take (b - a) (B.drop a buf)

-- | @TarInfo._fromtarfile@.
fromTarfile :: Bool -> R Member
fromTarfile dircheck = do
  buf <- readBytes (fromIntegral blockSize)
  (member, sparse) <- liftEither (frombuf dircheck buf)
  pos <- getsR rsPos
  procMember member {memberOffset = pos - fromIntegral blockSize} sparse

procMember :: Member -> Maybe SparseStructs -> R Member
procMember member sparse
  | t == gnuLongName || t == gnuLongLink = procGnuLong member
  | t == gnuSparse = procSparse member sparse
  | t == xhdType || t == xglType || t == solarisXhdType = procPax member
  | otherwise = procBuiltin member
  where
    t = memberType member

unsupportedOrRegular :: Member -> Bool
unsupportedOrRegular m = isRegular m || memberType m `notElem` supportedTypes

procBuiltin :: Member -> R Member
procBuiltin member = do
  offsetData <- getsR rsPos
  skip <- if unsupportedOrRegular member then block (memberSize member) else pure 0
  modifyR (\s -> s {rsOffset = offsetData + skip})
  global <- getsR rsGlobal
  patched <- applyPaxInfo global member {memberOffsetData = offsetData}
  pure (if isDirectory patched then patched {memberName = BC.dropWhileEnd (== '/') (memberName patched)} else patched)

procGnuLong :: Member -> R Member
procGnuLong member = do
  len <- block (memberSize member)
  buf <- readBytes len
  next <- fromTarfile False `catchHeader` (failWith . HeaderFailure . SubsequentHeader . headerMessage)
  let named
        | memberType member == gnuLongName = next {memberName = nts buf}
        | otherwise = next {memberLinkname = nts buf}
      stripped =
        if isDirectory named
          then named {memberName = fromMaybeSuffix (memberName named)}
          else named
  pure stripped {memberOffset = memberOffset member}
  where
    fromMaybeSuffix name = maybe name id (B.stripSuffix "/" name)

procSparse :: Member -> Maybe SparseStructs -> R Member
procSparse member sparse = do
  let (structs0, extended0, origsize) = maybe ([], False, 0) id sparse
  structs <- collect structs0 extended0
  offsetData <- getsR rsPos
  len <- block (memberSize member)
  modifyR (\s -> s {rsOffset = offsetData + len})
  pure member {memberSparse = Just structs, memberOffsetData = offsetData, memberSize = origsize}
  where
    collect acc False = pure acc
    collect acc True = do
      buf <- readBytes (fromIntegral blockSize)
      found <- forM [0 .. 20 :: Int] $ \i -> do
        let pos = i * 24
        offset <- liftEither (nti (B.take 12 (B.drop pos buf)))
        numbytes <- liftEither (nti (B.take 12 (B.drop (pos + 12) buf)))
        pure [(offset, numbytes) | offset /= 0 && numbytes /= 0]
      extended <-
        if B.length buf > 504
          then pure (BU.unsafeIndex buf 504 /= 0)
          else failWith (PyErr "IndexError" "index out of range")
      collect (acc ++ concat found) extended

-- | Ordered-dict assignment.
dictSet :: ByteString -> ByteString -> [(ByteString, ByteString)] -> [(ByteString, ByteString)]
dictSet key value entries
  | any ((== key) . fst) entries = [(k, if k == key then value else v) | (k, v) <- entries]
  | otherwise = entries ++ [(key, value)]

-- | The @([0-9]{1,20}) @ length prefix at @pos@.
lengthPrefix :: ByteString -> Int -> Maybe (Integer, Int)
lengthPrefix buf pos =
  let digits = B.takeWhile (\w -> w >= 0x30 && w <= 0x39) (B.drop pos buf)
      n = B.length digits
   in if n >= 1 && n <= 20 && B.length buf > pos + n && B.index buf (pos + n) == 0x20
        then Just (read (BC.unpack digits), pos + n)
        else Nothing

procPax :: Member -> R Member
procPax member = do
  len <- block (memberSize member)
  buf <- readBytes len
  global <- getsR rsGlobal
  rawHeaders <- liftEither (parseRecords buf 0 [])
  let withRecords base = foldl' (\acc (_, k, v) -> dictSet k v acc) base rawHeaders
      isGlobal = memberType member == xglType
      paxHeaders = withRecords global
  when isGlobal $ modifyR (\s -> s {rsGlobal = paxHeaders})
  next0 <- fromTarfile False `catchHeader` (failWith . HeaderFailure . SubsequentHeader . headerMessage)
  next1 <-
    if hasKey "GNU.sparse.map" paxHeaders
      then do
        let mapValue = lookupKey "GNU.sparse.map" paxHeaders
        numbers <- forM (BC.split ',' mapValue) $ \piece -> do
          let text = fsDecode piece
          maybe (failWith (PyErr "ValueError" (pyIntError text))) pure (parsePythonInt 10 text)
        pure next0 {memberSparse = Just (pairs numbers)}
      else
        if hasKey "GNU.sparse.size" paxHeaders
          then do
            offsets <- sequence [strictInt v | (_, k, v) <- rawHeaders, k == "GNU.sparse.offset"]
            numbytes <- sequence [strictInt v | (_, k, v) <- rawHeaders, k == "GNU.sparse.numbytes"]
            pure next0 {memberSparse = Just (zip offsets numbytes)}
          else
            if lookupMaybe "GNU.sparse.major" paxHeaders == Just "1"
              && lookupMaybe "GNU.sparse.minor" paxHeaders == Just "0"
              then gnuSparse10 next0
              else pure next0
  if memberType member == xhdType || memberType member == solarisXhdType
    then do
      patched <- applyPaxInfo paxHeaders next1
      let result = patched {memberOffset = memberOffset member}
      when (hasKey "size" paxHeaders) $ do
        skip <- if unsupportedOrRegular result then block (memberSize result) else pure 0
        modifyR (\s -> s {rsOffset = memberOffsetData result + skip})
      pure result
    else pure next1
  where
    hasKey key = any ((== key) . fst)
    lookupKey key entries = maybe "" id (lookup key entries)
    lookupMaybe = lookup
    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _ = []
    strictInt value
      | not (isStrictUtf8 value) = invalid
      | otherwise = maybe invalid pure (parsePythonInt 10 (fsDecode value))

parseRecords :: ByteString -> Int -> [(Integer, ByteString, ByteString)] -> Either Failure [(Integer, ByteString, ByteString)]
parseRecords buf pos acc
  | B.length buf > pos && B.index buf pos /= 0 = case lengthPrefix buf pos of
      Nothing -> bad
      Just (len, digitsEnd)
        | len < 5 -> bad
        | fromIntegral pos + len > fromIntegral (B.length buf) -> bad
        | otherwise ->
            let lenInt = fromIntegral len :: Int
                valueEnd = pos + lenInt - 1
                kvStart = digitsEnd + 1
                keywordAndValue = if valueEnd > kvStart then B.take (valueEnd - kvStart) (B.drop kvStart buf) else B.empty
                (rawKeyword, rest) = B.break (== 0x3D) keywordAndValue
             in if B.null rawKeyword || B.null rest || B.index buf valueEnd /= 0x0A
                  then bad
                  else parseRecords buf (pos + lenInt) ((len, rawKeyword, B.drop 1 rest) : acc)
  | otherwise = Right (reverse acc)
  where
    bad = Left (HeaderFailure (InvalidHeader "invalid header"))

-- | @_proc_gnusparse_10@.
gnuSparse10 :: Member -> R Member
gnuSparse10 next = do
  buf0 <- readBytes (fromIntegral blockSize)
  (fieldsRaw, buf1) <- splitLine buf0
  fields <- intBytes fieldsRaw
  let loop sparse buf
        | fromIntegral (length sparse) >= fields * 2 = pure (reverse sparse)
        | otherwise = do
            buf' <-
              if B.elem 0x0A buf
                then pure buf
                else (buf <>) <$> readBytes (fromIntegral blockSize)
            (numberRaw, rest) <- splitLine buf'
            number <- intBytes numberRaw
            loop (number : sparse) rest
  numbers <- loop [] buf1
  pos <- getsR rsPos
  pure next {memberOffsetData = pos, memberSparse = Just (pairs numbers)}
  where
    splitLine buf = case B.elemIndex 0x0A buf of
      Just i -> pure (B.take i buf, B.drop (i + 1) buf)
      Nothing -> failWith (PyErr "ValueError" "not enough values to unpack (expected 2, got 1)")
    intBytes raw = maybe (failWith (PyErr "ValueError" (pyIntBytesError raw))) pure (pyIntBytes raw)
    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _ = []

-- | @TarInfo._apply_pax_info@.
applyPaxInfo :: [(ByteString, ByteString)] -> Member -> R Member
applyPaxInfo headers member0 = go member0 headers
  where
    go member [] = pure member
    go member ((key, value) : rest) = case key of
      "GNU.sparse.name" -> go member {memberName = value} rest
      "GNU.sparse.size" -> sparseSize member value >>= \m -> go m rest
      "GNU.sparse.realsize" -> sparseSize member value >>= \m -> go m rest
      "path" -> go member {memberName = BC.dropWhileEnd (== '/') value} rest
      "linkpath" -> go member {memberLinkname = value} rest
      "size" -> go member {memberSize = intOrZero value} rest
      "uid" -> go member {memberUid = intOrZero value} rest
      "gid" -> go member {memberGid = intOrZero value} rest
      "mtime" ->
        go member {memberMtime = maybe (MTimeInt 0) MTimeFloat (pyFloat (fsDecode value))} rest
      _ -> go member rest
    intOrZero value = maybe 0 id (parsePythonInt 10 (fsDecode value))
    sparseSize member value =
      let text = fsDecode value
       in case parsePythonInt 10 text of
            Just n -> pure member {memberSize = n}
            Nothing -> failWith (PyErr "ValueError" (pyIntError text))

-- | @TarFile.next()@ for a non-streaming, non-@ignore_zeros@ archive.
-- 'Nothing' ends the archive.
nextMember :: R (Maybe Member)
nextMember = do
  offset <- getsR rsOffset
  pos <- getsR rsPos
  if offset /= pos && offset == 0
    then pure Nothing
    else do
      when (offset /= pos) $ do
        modifyR (\s -> s {rsPos = offset - 1})
        byte <- readBytes 1
        when (B.null byte) $ failWith (ReadErr "unexpected end of data")
      R $ \s -> case runR (fromTarfile True) s of
        (Right member, s') -> (Right (Just member), s')
        (Left (HeaderFailure e), s') -> case e of
          EofHeader -> (Right Nothing, s')
          InvalidHeader m
            | rsOffset s' == 0 -> (Left (ReadErr m), s')
            | otherwise -> (Right Nothing, s')
          EmptyHeader
            | rsOffset s' == 0 -> (Left (ReadErr "empty file"), s')
            | otherwise -> (Right Nothing, s')
          TruncatedHeader
            | rsOffset s' == 0 -> (Left (ReadErr "truncated header"), s')
            | otherwise -> (Right Nothing, s')
          SubsequentHeader m -> (Left (ReadErr m), s')
        (Left other, s') -> (Left other, s')

-- | Open an uncompressed archive (@taropen@ + @getmembers@).  The first
-- member is read while "opening"; a failure there is reported separately
-- so the caller can reproduce @tarfile.open@'s aggregated message.
readTar :: ByteString -> Either (Bool, ReadFailure) [Member]
readTar bytes = case runR nextMember initial of
  (Left failure, _) -> Left (True, toFailure failure)
  (Right Nothing, _) -> Right []
  (Right (Just first), state) -> go [first] state
  where
    initial = RState bytes 0 0 []
    go acc state = case runR nextMember state of
      (Left failure, _) -> Left (False, toFailure failure)
      (Right Nothing, _) -> Right (reverse acc)
      (Right (Just member), state') -> go (member : acc) state'
    toFailure = \case
      HeaderFailure e -> ReadFailure (headerMessage e)
      ReadErr m -> ReadFailure m
      PyErr cls m -> PythonFailure cls m


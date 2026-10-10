-- | The WHATWG URL parser, as Node's @new URL(input, base)@ runs it.
--
-- Node resolves refs with @new URL(ref, basePath)@ and reads
-- @URL#pathname@ / @URL#hostname@ / @URL#href@; GitHub links are normalized
-- with a regular expression. This module is a direct port of the URL
-- standard's basic URL parser (without state overrides): every state of the
-- state machine, host parsing (domains, IPv4 with hex/octal parts, IPv6 with
-- compression and embedded IPv4, opaque hosts), the percent-encode sets, the
-- Windows drive letter quirks of @file:@ URLs, and serialization.
--
-- One approximation: UTS #46 mapping of non-ASCII domain labels is limited
-- to Unicode simple lowercasing before Punycode (no NFKC compatibility
-- mapping and no bidi/joiner checks); see DIVERGENCES.md.
module Petrus.Viewer.Url
  ( Url (..)
  , parseUrl
  , resolveUrl
  , resolveUrlSpec
  , serializeUrl
  , urlPathname
  , urlHostname
  , urlProtocol
  , decodeURIComponent
  , normalizeGitHubUrl
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString qualified as B
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, isOctDigit, ord, toLower)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Numeric (showHex)

-- | A parsed URL. For special schemes (and hierarchical non-special URLs)
-- the path is a list of segments; otherwise it is opaque. The host is kept
-- serialized (IPv6 addresses in brackets).
data Url = Url
  { urlScheme :: String
  , urlUsername :: String
  , urlPassword :: String
  , urlHost :: Maybe String
  , urlPort :: Maybe Int
  , urlPath :: Either String [String]
  , urlQuery :: Maybe String
  , urlFragment :: Maybe String
  }
  deriving stock (Eq, Show)

specialPort :: String -> Maybe (Maybe Int)
specialPort = \case
  "http" -> Just (Just 80)
  "https" -> Just (Just 443)
  "ws" -> Just (Just 80)
  "wss" -> Just (Just 443)
  "ftp" -> Just (Just 21)
  "file" -> Just Nothing
  _ -> Nothing

isSpecial :: String -> Bool
isSpecial = isJust . specialPort

-- | @new URL(input)@.
parseUrl :: Text -> Maybe Url
parseUrl t = basicParse Nothing (prepare t)

-- | @new URL(input, base)@.
resolveUrl :: Text -> Text -> Maybe Url
resolveUrl input base = case resolveFilePath input base of
  Just u -> Just u
  Nothing -> resolveUrlSpec input base

-- | @new URL(input, base)@ through the full state machine.
resolveUrlSpec :: Text -> Text -> Maybe Url
resolveUrlSpec input base = do
  b <- parseUrl base
  basicParse (Just b) (prepare input)

-- | The common case of @/__petrus/resolve-ref@ without the state machine:
-- a relative path (@./sub.json@, @../x/y.json@) against a @file:///@ base,
-- both made only of characters that the parser copies unchanged and that
-- play no special role (no percent signs, drive-letter colons, backslashes,
-- queries, fragments, spaces, or non-ASCII). For those inputs the parser
-- reduces to splitting on @/@ and the dot-segment rules of the path state,
-- which is all this does; a property test checks it against
-- 'resolveUrlSpec'. Anything else returns 'Nothing'.
resolveFilePath :: Text -> Text -> Maybe Url
resolveFilePath input base = do
  rest <- T.stripPrefix "file:///" base
  if T.all plain rest && T.all plain input && not (T.null input) && T.head input /= '/'
    then
      let basePath = walk [] (T.splitOn "/" rest)
          dir = drop 1 basePath -- shorten: the base's last segment goes
       in Just
            emptyUrl
              { urlScheme = "file"
              , urlHost = Just ""
              , urlPath = Right (map T.unpack (reverse (walk dir (T.splitOn "/" input))))
              }
    else Nothing
  where
    plain c =
      isAsciiLower c || isAsciiUpper c || isDigit c || c == '/' || T.any (== c) "-._~!$&'()*+,;=@"
    -- the path state over '/'-separated segments; the path is reversed
    walk path = \case
      [] -> path
      [s]
        | s == ".." -> "" : drop 1 path
        | s == "." -> "" : path
        | otherwise -> s : path
      (s : more)
        | s == ".." -> walk (drop 1 path) more
        | s == "." -> walk path more
        | otherwise -> walk (s : path) more

-- | Strip leading and trailing C0 controls and spaces, remove tabs and
-- newlines.
prepare :: Text -> String
prepare = T.unpack . T.filter (\c -> c /= '\t' && c /= '\n' && c /= '\r') . T.dropAround c0space
  where
    c0space c = c <= '\x20'

emptyUrl :: Url
emptyUrl = Url "" "" "" Nothing Nothing (Right []) Nothing Nothing

data State
  = SchemeStart
  | Scheme
  | NoScheme
  | SpecialRelativeOrAuthority
  | PathOrAuthority
  | Relative
  | RelativeSlash
  | SpecialAuthoritySlashes
  | SpecialAuthorityIgnoreSlashes
  | Authority
  | Host
  | Port
  | File
  | FileSlash
  | FileHost
  | PathStart
  | Path
  | OpaquePath
  | Query
  | Fragment

-- | Parser state besides the state-machine state: the URL being built, the
-- buffer, and the authority/host flags.
data P = P
  { pUrl :: Url
  , pRevBuf :: String
  -- ^ the spec's buffer, reversed (appending is a cons)
  , pAtSign :: Bool
  , pPasswordToken :: Bool
  , pBrackets :: Bool
  }

-- | The basic URL parser. The remaining input is a list whose head is the
-- spec's @c@ (the empty list is the EOF code point). "Decrease pointer by
-- one" becomes running the next state on the same input.
basicParse :: Maybe Url -> String -> Maybe Url
basicParse base input0 = run SchemeStart (P emptyUrl "" False False False) input0
  where
    run :: State -> P -> String -> Maybe Url
    run state p input =
      let c = case input of
            (x : _) -> Just x
            [] -> Nothing
          rest = drop 1 input
          remaining = rest
          url = pUrl p
          revBuf = pRevBuf p
          buf = reverse revBuf
          special = isSpecial (urlScheme url)
          -- consume c and continue in state s (EOF ends the parse)
          next s p' = case input of
            [] -> Just (pUrl p')
            _ -> run s p' rest
          -- process c again in state s
          again s p' = run s p' input
          setUrl u = p {pUrl = u}
          isEnd = isNothing c
          endOfAuthority =
            isEnd || c == Just '/' || c == Just '?' || c == Just '#' || (special && c == Just '\\')
       in case state of
            SchemeStart -> case c of
              Just x
                | isAsciiAlpha x -> next Scheme p {pRevBuf = [toLower x]}
              _ -> again NoScheme p
            Scheme -> case c of
              Just x
                | isAsciiAlpha x || isDigit x || x `elem` ("+-." :: String) ->
                    next Scheme p {pRevBuf = toLower x : revBuf}
              Just ':' ->
                let u = url {urlScheme = buf}
                    p' = p {pUrl = u, pRevBuf = ""}
                 in if buf == "file"
                      then next File p'
                      else
                        if isSpecial buf
                          then case base of
                            Just b
                              | urlScheme b == buf -> next SpecialRelativeOrAuthority p'
                            _ -> next SpecialAuthoritySlashes p'
                          else
                            if take 1 remaining == "/"
                              then run PathOrAuthority p' (drop 1 remaining)
                              else next OpaquePath p' {pUrl = u {urlPath = Left ""}}
              _ -> run NoScheme p {pRevBuf = ""} input0
            NoScheme -> case base of
              Nothing -> Nothing
              Just b -> case urlPath b of
                Left _
                  | c == Just '#' ->
                      next
                        Fragment
                        ( setUrl
                            url
                              { urlScheme = urlScheme b
                              , urlPath = urlPath b
                              , urlQuery = urlQuery b
                              , urlFragment = Just ""
                              }
                        )
                  | otherwise -> Nothing
                Right _
                  | urlScheme b /= "file" -> again Relative p
                  | otherwise -> again File p
            SpecialRelativeOrAuthority
              | c == Just '/' && take 1 remaining == "/" -> run SpecialAuthorityIgnoreSlashes p (drop 1 remaining)
              | otherwise -> again Relative p
            PathOrAuthority
              | c == Just '/' -> next Authority p
              | otherwise -> again Path p
            Relative -> withBase $ \b ->
              let u0 = url {urlScheme = urlScheme b}
                  sp = isSpecial (urlScheme b)
                  inherited =
                    u0
                      { urlUsername = urlUsername b
                      , urlPassword = urlPassword b
                      , urlHost = urlHost b
                      , urlPort = urlPort b
                      , urlPath = urlPath b
                      , urlQuery = urlQuery b
                      }
               in case c of
                    Just '/' -> next RelativeSlash (setUrl u0)
                    Just '\\' | sp -> next RelativeSlash (setUrl u0)
                    Just '?' -> next Query (setUrl inherited {urlQuery = Just ""})
                    Just '#' -> next Fragment (setUrl inherited {urlFragment = Just ""})
                    Just _ -> again Path (setUrl (shortenPath inherited {urlQuery = Nothing}))
                    Nothing -> Just inherited
            RelativeSlash
              | special && (c == Just '/' || c == Just '\\') -> next SpecialAuthorityIgnoreSlashes p
              | c == Just '/' -> next Authority p
              | otherwise -> withBase $ \b ->
                  again
                    Path
                    ( setUrl
                        url
                          { urlUsername = urlUsername b
                          , urlPassword = urlPassword b
                          , urlHost = urlHost b
                          , urlPort = urlPort b
                          }
                    )
            SpecialAuthoritySlashes
              | c == Just '/' && take 1 remaining == "/" -> run SpecialAuthorityIgnoreSlashes p (drop 1 remaining)
              | otherwise -> again SpecialAuthorityIgnoreSlashes p
            SpecialAuthorityIgnoreSlashes
              | c == Just '/' || c == Just '\\' -> next SpecialAuthorityIgnoreSlashes p
              | otherwise -> again Authority p
            Authority
              | c == Just '@' ->
                  let buf' = if pAtSign p then "%40" ++ buf else buf
                      (u', pw') = foldl' credential (url, pPasswordToken p) buf'
                   in next Authority p {pUrl = u', pRevBuf = "", pAtSign = True, pPasswordToken = pw'}
              | endOfAuthority ->
                  if pAtSign p && null buf
                    then Nothing
                    else run Host p {pRevBuf = ""} (buf ++ input)
              | otherwise -> next Authority p {pRevBuf = maybe revBuf (: revBuf) c}
            Host
              | c == Just ':' && not (pBrackets p) ->
                  if null buf
                    then Nothing
                    else do
                      h <- parseHost (not special) buf
                      next Port p {pUrl = url {urlHost = Just h}, pRevBuf = ""}
              | endOfAuthority ->
                  if special && null buf
                    then Nothing
                    else do
                      h <- parseHost (not special) buf
                      again PathStart p {pUrl = url {urlHost = Just h}, pRevBuf = ""}
              | otherwise ->
                  let br = case c of
                        Just '[' -> True
                        Just ']' -> False
                        _ -> pBrackets p
                   in next Host p {pRevBuf = maybe revBuf (: revBuf) c, pBrackets = br}
            Port -> case c of
              Just x | isDigit x -> next Port p {pRevBuf = x : revBuf}
              _
                | endOfAuthority ->
                    if null buf
                      then again PathStart p
                      else
                        let n = read buf :: Integer
                         in if n > 65535
                              then Nothing
                              else
                                let port = fromInteger n
                                    port' = if specialPort (urlScheme url) == Just (Just port) then Nothing else Just port
                                 in again PathStart p {pUrl = url {urlPort = port'}, pRevBuf = ""}
                | otherwise -> Nothing
            File ->
              let u0 = url {urlScheme = "file", urlHost = Just ""}
               in case c of
                    Just x | x == '/' || x == '\\' -> next FileSlash (setUrl u0)
                    _ -> case base of
                      Just b
                        | urlScheme b == "file" ->
                            let inherited = u0 {urlHost = urlHost b, urlPath = urlPath b, urlQuery = urlQuery b}
                             in case c of
                                  Just '?' -> next Query (setUrl inherited {urlQuery = Just ""})
                                  Just '#' -> next Fragment (setUrl inherited {urlFragment = Just ""})
                                  Just _ ->
                                    let u1 = inherited {urlQuery = Nothing}
                                        u2 =
                                          if startsWithDriveLetter input
                                            then u1 {urlPath = Right []}
                                            else shortenPath u1
                                     in again Path (setUrl u2)
                                  Nothing -> Just inherited
                      _ -> again Path (setUrl u0)
            FileSlash
              | c == Just '/' || c == Just '\\' -> next FileHost p
              | otherwise -> case base of
                  Just b
                    | urlScheme b == "file" ->
                        let u1 = url {urlHost = urlHost b}
                            u2 = case urlPath b of
                              Right (first : _)
                                | not (startsWithDriveLetter input) && isNormalizedDriveLetter first ->
                                    u1 {urlPath = Right (pathList u1 ++ [first])}
                              _ -> u1
                         in again Path (setUrl u2)
                  _ -> again Path p
            FileHost
              | isEnd || c `elem` map Just ("/\\?#" :: String) ->
                  if isDriveLetter buf
                    then again Path p
                    else
                      if null buf
                        then again PathStart p {pUrl = url {urlHost = Just ""}}
                        else do
                          h <- parseHost False buf
                          let h' = if h == "localhost" then "" else h
                          again PathStart p {pUrl = url {urlHost = Just h'}, pRevBuf = ""}
              | otherwise -> next FileHost p {pRevBuf = maybe revBuf (: revBuf) c}
            PathStart
              | special ->
                  if c == Just '/' || c == Just '\\' then next Path p else again Path p
              | c == Just '?' -> next Query (setUrl url {urlQuery = Just ""})
              | c == Just '#' -> next Fragment (setUrl url {urlFragment = Just ""})
              | isEnd -> Just url
              | c == Just '/' -> next Path p
              | otherwise -> again Path p
            Path
              | isEnd || c == Just '/' || (special && c == Just '\\') || c == Just '?' || c == Just '#' ->
                  let slash = c == Just '/' || (special && c == Just '\\')
                      u1
                        | isDoubleDot buf =
                            let s = shortenPath url
                                -- Node (ada 2.9) leaves a non-special path
                                -- empty when a final ".." finds nothing to
                                -- remove; the standard would append "".
                                adaEmpty = not special && null (pathList url)
                             in if slash || adaEmpty then s else s {urlPath = Right (pathList s ++ [""])}
                        | isSingleDot buf =
                            if slash then url else url {urlPath = Right (pathList url ++ [""])}
                        | otherwise =
                            let seg =
                                  if urlScheme url == "file" && null (pathList url) && isDriveLetter buf
                                    then take 1 buf ++ ":"
                                    else buf
                             in url {urlPath = Right (pathList url ++ [seg])}
                      p' = p {pUrl = u1, pRevBuf = ""}
                   in case c of
                        Just '?' -> next Query p' {pUrl = u1 {urlQuery = Just ""}}
                        Just '#' -> next Fragment p' {pUrl = u1 {urlFragment = Just ""}}
                        _ -> next Path p'
              | otherwise -> case span plainPathChar input of
                  -- a run of code points the path state only buffers
                  (plain@(_ : _), rest') -> run Path p {pRevBuf = reverse plain ++ revBuf} rest'
                  _ -> next Path p {pRevBuf = maybe revBuf (\x -> reverse (encodeChar pathSet x) ++ revBuf) c}
            OpaquePath -> case c of
              Just '?' -> next Query (setUrl url {urlQuery = Just ""})
              Just '#' -> next Fragment (setUrl url {urlFragment = Just ""})
              Just x -> next OpaquePath (setUrl url {urlPath = Left (either id concat (urlPath url) ++ encodeChar c0Set x)})
              Nothing -> Just url
            Query
              | isEnd || c == Just '#' ->
                  let set = if special then specialQuerySet else querySet
                      q = fromMaybe "" (urlQuery url) ++ concatMap (encodeChar set) buf
                      u1 = url {urlQuery = Just q}
                   in if c == Just '#'
                        then next Fragment p {pUrl = u1 {urlFragment = Just ""}, pRevBuf = ""}
                        else Just u1
              | otherwise -> next Query p {pRevBuf = maybe revBuf (: revBuf) c}
            Fragment -> case c of
              Just x -> next Fragment (setUrl url {urlFragment = Just (fromMaybe "" (urlFragment url) ++ encodeChar fragmentSet x)})
              Nothing -> Just url
      where
        withBase k = maybe Nothing k base

    credential (u, pw) ch
      | ch == ':' && not pw = (u, True)
      | pw = (u {urlPassword = urlPassword u ++ encodeChar userinfoSet ch}, pw)
      | otherwise = (u {urlUsername = urlUsername u ++ encodeChar userinfoSet ch}, pw)

pathList :: Url -> [String]
pathList = either (const []) id . urlPath

shortenPath :: Url -> Url
shortenPath u = case urlPath u of
  Right [s]
    | urlScheme u == "file" && isNormalizedDriveLetter s -> u
  Right segs
    | not (null segs) -> u {urlPath = Right (init segs)}
  _ -> u

isAsciiAlpha :: Char -> Bool
isAsciiAlpha c = isAsciiLower c || isAsciiUpper c

isDriveLetter :: String -> Bool
isDriveLetter = \case
  [a, b] -> isAsciiAlpha a && (b == ':' || b == '|')
  _ -> False

isNormalizedDriveLetter :: String -> Bool
isNormalizedDriveLetter = \case
  [a, ':'] -> isAsciiAlpha a
  _ -> False

startsWithDriveLetter :: String -> Bool
startsWithDriveLetter s =
  isDriveLetter (take 2 s) && case drop 2 s of
    [] -> True
    (x : _) -> x `elem` ("/\\?#" :: String)

isSingleDot :: String -> Bool
isSingleDot s = map toLower s `elem` [".", "%2e"]

isDoubleDot :: String -> Bool
isDoubleDot s = map toLower s `elem` ["..", ".%2e", "%2e.", "%2e%2e"]

-- * Hosts

-- | The host parser. @opaque@ is "not special".
parseHost :: Bool -> String -> Maybe String
parseHost opaque input = case input of
  ('[' : inner)
    | not (null inner) && last inner == ']' -> do
        pieces <- parseIPv6 (init inner)
        pure ("[" ++ serializeIPv6 pieces ++ "]")
    | otherwise -> Nothing
  _
    | opaque ->
        if any isForbiddenHost input then Nothing else Just (concatMap (encodeChar c0Set) input)
    | otherwise -> do
        let domain = percentDecodeString input
        ascii <- domainToASCII domain
        if any isForbiddenDomain ascii
          then Nothing
          else
            if endsInNumber ascii
              then serializeIPv4 <$> parseIPv4 ascii
              else Just ascii

isForbiddenHost :: Char -> Bool
isForbiddenHost c = c `elem` ("\0\t\n\r #/:<>?@[\\]^|" :: String)

isForbiddenDomain :: Char -> Bool
isForbiddenDomain c = isForbiddenHost c || ord c <= 0x1f || c == '%' || c == '\x7f'

-- | UTS #46 ToASCII, approximated: labels split on the IDNA full stops,
-- lowercased, and Punycode-encoded when not ASCII. Invalid UTF-8 (decoded
-- to U+FFFD) is rejected, as UTS #46 disallows it.
domainToASCII :: String -> Maybe String
domainToASCII domain
  | any (== '\xFFFD') domain = Nothing
  | otherwise =
      let mapped = map (\c -> if c `elem` ("\x3002\xFF0E\xFF61" :: String) then '.' else toLower c) domain
          labels = splitOnDot mapped
          toAscii l
            | all ((< 0x80) . ord) l = l
            | otherwise = "xn--" ++ punycode l
          result = joinDots (map toAscii labels)
       in if null result then Nothing else Just result

splitOnDot :: String -> [String]
splitOnDot s = case break (== '.') s of
  (a, []) -> [a]
  (a, _ : r) -> a : splitOnDot r

joinDots :: [String] -> String
joinDots = \case
  [] -> ""
  [x] -> x
  (x : xs) -> x ++ "." ++ joinDots xs

-- | RFC 3492 Punycode encoding of one label.
punycode :: String -> String
punycode label = basics ++ (if null basics then "" else "-") ++ go 128 0 72 (length basics) ""
  where
    cps = map ord label
    basics = [c | c <- label, ord c < 0x80]
    b = length basics
    total = length cps
    go :: Int -> Int -> Int -> Int -> String -> String
    go n delta bias h acc
      | h >= total = reverse acc
      | otherwise =
          let m = minimum [c | c <- cps, c >= n]
              delta1 = delta + (m - n) * (h + 1)
              (delta2, bias2, h2, acc2) = foldl' (step m) (delta1, bias, h, acc) cps
           in go (m + 1) (delta2 + 1) bias2 h2 acc2
    step m (delta, bias, h, acc) c
      | c < m = (delta + 1, bias, h, acc)
      | c == m =
          let (digits, q) = emit delta bias base []
              acc' = reverse (digits ++ [digitChar q]) ++ acc
           in (0, adapt delta (h + 1) (h == b), h + 1, acc')
      | otherwise = (delta, bias, h, acc)
    emit q bias k out =
      let t
            | k <= bias = tmin
            | k >= bias + tmax = tmax
            | otherwise = k - bias
       in if q < t
            then (out, q)
            else emit ((q - t) `div` (base - t)) bias (k + base) (out ++ [digitChar (t + (q - t) `mod` (base - t))])
    base = 36
    tmin = 1
    tmax = 26
    adapt delta numPoints firstTime =
      let d0 = if firstTime then delta `div` 700 else delta `div` 2
          d1 = d0 + d0 `div` numPoints
          loop d k
            | d > ((base - tmin) * tmax) `div` 2 = loop (d `div` (base - tmin)) (k + base)
            | otherwise = k + ((base - tmin + 1) * d) `div` (d + 38)
       in loop d1 0
    digitChar d
      | d < 26 = chr (ord 'a' + d)
      | otherwise = chr (ord '0' + d - 26)

endsInNumber :: String -> Bool
endsInNumber s =
  let parts0 = splitOnDot s
      parts = if length parts0 > 1 && last parts0 == "" then init parts0 else parts0
   in case parts of
        [""] -> False
        _ ->
          let lastPart = last parts
           in (not (null lastPart) && all isDigit lastPart) || isJust (parseIPv4Number lastPart)

parseIPv4 :: String -> Maybe Integer
parseIPv4 s = do
  let parts0 = splitOnDot s
      parts = if length parts0 > 1 && last parts0 == "" then init parts0 else parts0
  if length parts > 4 then Nothing else pure ()
  numbers <- mapM parseIPv4Number parts
  if any (> 255) (init numbers) then Nothing else pure ()
  let n = length numbers
  if last numbers >= 256 ^ (5 - n) then Nothing else pure ()
  pure (last numbers + sum [x * 256 ^ (3 - i) | (i, x) <- zip [0 :: Int ..] (init numbers)])

parseIPv4Number :: String -> Maybe Integer
parseIPv4Number s
  | null s = Nothing
  | Just r <- stripHex s = digits 16 isHexDigit r
  | length s >= 2 && take 1 s == "0" = digits 8 isOctDigit (drop 1 s)
  | otherwise = digits 10 isDigit s
  where
    stripHex x
      | "0x" `isPrefixOf` x || "0X" `isPrefixOf` x = Just (drop 2 x)
      | otherwise = Nothing
    digits :: Integer -> (Char -> Bool) -> String -> Maybe Integer
    digits radix ok str
      | null str = Just 0
      | all ok str = Just (foldl' (\acc ch -> acc * radix + toInteger (hexValue ch)) 0 str)
      | otherwise = Nothing

serializeIPv4 :: Integer -> String
serializeIPv4 n =
  joinDots [show ((n `div` (256 ^ k)) `mod` 256) | k <- [3, 2, 1, 0 :: Int]]

hexValue :: Char -> Int
hexValue ch
  | isDigit ch = ord ch - 48
  | ch >= 'a' && ch <= 'f' = ord ch - 87
  | otherwise = ord ch - 55

-- | The IPv6 parser: eight 16-bit pieces.
parseIPv6 :: String -> Maybe [Int]
parseIPv6 input0 = start input0
  where
    start = \case
      (':' : r) -> case r of
        (':' : r') -> loop (replicate 8 0) 1 (Just 1) r'
        _ -> Nothing
      s -> loop (replicate 8 0) 0 Nothing s

    loop :: [Int] -> Int -> Maybe Int -> String -> Maybe [Int]
    loop addr pieceIndex compress s = case s of
      [] -> finish addr pieceIndex compress
      _
        | pieceIndex == 8 -> Nothing
      (':' : r)
        | isJust compress -> Nothing
        | otherwise -> loop addr (pieceIndex + 1) (Just (pieceIndex + 1)) r
      _ ->
        let (hexs, afterHex) = spanMax 4 isHexDigit s
            value = foldl' (\acc ch -> acc * 16 + hexValue ch) 0 hexs
         in case afterHex of
              ('.' : _)
                | null hexs -> Nothing
                | pieceIndex > 6 -> Nothing
                | otherwise -> do
                    addr' <- ipv4Part addr pieceIndex 0 s
                    finish (fst addr') (snd addr') compress
              (':' : r)
                | null r -> Nothing
                | otherwise -> loop (setAt pieceIndex value addr) (pieceIndex + 1) compress r
              [] -> finish (setAt pieceIndex value addr) (pieceIndex + 1) compress
              _ -> Nothing

    ipv4Part :: [Int] -> Int -> Int -> String -> Maybe ([Int], Int)
    ipv4Part addr pieceIndex numbersSeen s = case s of
      []
        | numbersSeen == 4 -> Just (addr, pieceIndex)
        | otherwise -> Nothing
      _ -> do
        s1 <-
          if numbersSeen > 0
            then case s of
              ('.' : r) | numbersSeen < 4 -> Just r
              _ -> Nothing
            else Just s
        let (ds, r2) = span isDigit s1
        if null ds then Nothing else pure ()
        if length ds > 1 && take 1 ds == "0" then Nothing else pure ()
        let v = foldl' (\acc ch -> acc * 10 + (ord ch - 48)) 0 (take 4 ds) :: Int
        if length ds > 3 || v > 255 then Nothing else pure ()
        let cur = addr !! pieceIndex
            addr' = setAt pieceIndex (cur * 0x100 + v) addr
            seen = numbersSeen + 1
            pieceIndex' = if seen == 2 || seen == 4 then pieceIndex + 1 else pieceIndex
        ipv4Part addr' pieceIndex' seen r2

    finish addr pieceIndex = \case
      Just comp ->
        let swaps = pieceIndex - comp
            moved = take comp addr ++ replicate (8 - comp - swaps) 0 ++ take swaps (drop comp addr)
         in Just moved
      Nothing
        | pieceIndex /= 8 -> Nothing
        | otherwise -> Just addr

    spanMax :: Int -> (Char -> Bool) -> String -> (String, String)
    spanMax n ok str =
      let (a, _) = span ok (take n str)
       in (a, drop (length a) str)

    setAt i v xs = take i xs ++ [v] ++ drop (i + 1) xs

serializeIPv6 :: [Int] -> String
serializeIPv6 pieces = go 0 False
  where
    compress = longestZeroRun
    go :: Int -> Bool -> String
    go i ignore0
      | i >= 8 = ""
      | ignore0 && pieces !! i == 0 = go (i + 1) True
      | Just i == compress = (if i == 0 then "::" else ":") ++ go (i + 1) True
      | otherwise = showHex (pieces !! i) "" ++ (if i /= 7 then ":" else "") ++ go (i + 1) False
    longestZeroRun =
      let runs = [(i, len) | i <- [0 .. 7], i == 0 || pieces !! (i - 1) /= 0, pieces !! i == 0, let len = length (takeWhile (== 0) (drop i pieces))]
          best = foldl' (\acc r@(_, l) -> case acc of Just (_, bl) | bl >= l -> acc; _ -> Just r) Nothing runs
       in case best of
            Just (i, l) | l > 1 -> Just i
            _ -> Nothing

-- * Percent-encoding

-- percent-encode sets (code points to encode)
c0Set, fragmentSet, querySet, specialQuerySet, pathSet, userinfoSet :: Char -> Bool
c0Set c = ord c < 0x20 || ord c > 0x7e
fragmentSet c = c0Set c || c `elem` (" \"<>`" :: String)
querySet c = c0Set c || c `elem` (" \"#<>" :: String)
specialQuerySet c = querySet c || c == '\''
pathSet c = querySet c || c `elem` ("?`{}" :: String)
userinfoSet c = pathSet c || c `elem` ("/:;=@[\\]^|" :: String)

-- | Path-state code points that are neither delimiters nor percent-encoded.
plainPathChar :: Char -> Bool
plainPathChar ch
  | ch >= 'a' && ch <= 'z' = True
  | ch >= 'A' && ch <= 'Z' = True
  | ch >= '-' && ch <= '9' = ch /= '/'
  | otherwise = ch /= '/' && ch /= '\\' && ch /= '?' && ch /= '#' && not (pathSet ch)

encodeChar :: (Char -> Bool) -> Char -> String
encodeChar inSet c
  | inSet c = concatMap pct (B.unpack (TE.encodeUtf8 (T.singleton c)))
  | otherwise = [c]
  where
    pct :: Word8 -> String
    pct w = '%' : hex2 w
    hex2 w = let h = map toUpperHex (showHex w "") in if length h == 1 then '0' : h else h
    toUpperHex x = if x >= 'a' && x <= 'f' then chr (ord x - 32) else x

-- * Serialization

-- | @URL#href@.
serializeUrl :: Url -> Text
serializeUrl u =
  T.pack $
    urlScheme u
      ++ ":"
      ++ maybe "" (\h -> "//" ++ creds ++ h ++ maybe "" ((':' :) . show) (urlPort u)) (urlHost u)
      ++ pathPrefix
      ++ urlPathString u
      ++ maybe "" ('?' :) (urlQuery u)
      ++ maybe "" ('#' :) (urlFragment u)
  where
    creds
      | null (urlUsername u) && null (urlPassword u) = ""
      | null (urlPassword u) = urlUsername u ++ "@"
      | otherwise = urlUsername u ++ ":" ++ urlPassword u ++ "@"
    pathPrefix = case urlPath u of
      Right ("" : _ : _) | isNothing (urlHost u) -> "/."
      _ -> ""

urlPathString :: Url -> String
urlPathString u = case urlPath u of
  Left opaque -> opaque
  Right segs -> concatMap ('/' :) segs

-- | @URL#pathname@.
urlPathname :: Url -> Text
urlPathname = T.pack . urlPathString

-- | @URL#hostname@ (host without port).
urlHostname :: Url -> Text
urlHostname = T.pack . fromMaybe "" . urlHost

-- | @URL#protocol@, e.g. @"file:"@.
urlProtocol :: Url -> Text
urlProtocol u = T.pack (urlScheme u ++ ":")

-- | Percent-decode, then UTF-8 decode (invalid sequences become U+FFFD).
percentDecodeString :: String -> String
percentDecodeString s = T.unpack (TE.decodeUtf8Lenient (B.pack (go (B.unpack (TE.encodeUtf8 (T.pack s))))))
  where
    go (0x25 : a : b : r)
      | isHexDigit (chr (fromIntegral a)) && isHexDigit (chr (fromIntegral b)) =
          fromIntegral (hexValue (chr (fromIntegral a)) * 16 + hexValue (chr (fromIntegral b))) : go r
    go (w : r) = w : go r
    go [] = []

-- | JavaScript @decodeURIComponent@: 'Left' carries the @URIError@ message.
decodeURIComponent :: Text -> Either Text Text
decodeURIComponent t
  | T.all (/= '%') t = Right t -- nothing to decode
  | otherwise = T.pack <$> go (T.unpack t)
  where
    go [] = Right []
    go ('%' : rest) = do
      (b0, rest1) <- byteAt rest
      if b0 < 0x80
        then (chr (fromIntegral b0) :) <$> go rest1
        else do
          let n
                | b0 .&. 0xE0 == 0xC0 = 1
                | b0 .&. 0xF0 == 0xE0 = 2
                | b0 .&. 0xF8 == 0xF0 = 3
                | otherwise = 0 :: Int
          if n == 0 then malformed else pure ()
          (conts, rest2) <- continuation n rest1
          let bytes = B.pack (b0 : conts)
          case TE.decodeUtf8' bytes of
            Right decoded
              | T.length decoded == 1 && isScalar (T.head decoded) ->
                  (T.unpack decoded ++) <$> go rest2
            _ -> malformed
    go (c : rest) = (c :) <$> go rest
    byteAt (a : b : rest)
      | isHexDigit a && isHexDigit b = Right (fromIntegral (digitValue a `shiftL` 4 .|. digitValue b) :: Word8, rest)
    byteAt _ = malformed
    continuation 0 rest = Right ([], rest)
    continuation k ('%' : rest) = do
      (b, rest') <- byteAt rest
      if b .&. 0xC0 /= 0x80 then malformed else pure ()
      (bs, rest'') <- continuation (k - 1 :: Int) rest'
      pure (b : bs, rest'')
    continuation _ _ = malformed
    malformed :: Either Text a
    malformed = Left "URI malformed"
    digitValue c
      | isDigit c = ord c - 48
      | c >= 'a' && c <= 'f' = ord c - 87
      | otherwise = ord c - 55
    isScalar c = ord c < 0xD800 || ord c > 0xDFFF

-- | @normalizeGitHubUrl@ from @server/urlCache.mjs@: rewrite
-- @https://github.com/OWNER/REPO/blob/REST@ to the raw content URL.
normalizeGitHubUrl :: Text -> Text
normalizeGitHubUrl url = case T.stripPrefix "https://github.com/" url of
  Just rest
    | Just (owner, r1) <- segment rest
    , Just (repo, r2) <- segment r1
    , Just r3 <- T.stripPrefix "blob/" r2
    , not (T.null r3)
    , not (T.any lineTerminator r3) ->
        T.concat ["https://raw.githubusercontent.com/", owner, "/", repo, "/", r3]
  _ -> url
  where
    -- [^/]+ followed by "/" (JS '.' and '[^/]' differ: [^/] also matches
    -- line terminators, '.' does not)
    segment t =
      let (seg, r) = T.break (== '/') t
       in if T.null seg || T.null r then Nothing else Just (seg, T.drop 1 r)
    lineTerminator c = c `elem` ['\n', '\r', '\x2028', '\x2029']

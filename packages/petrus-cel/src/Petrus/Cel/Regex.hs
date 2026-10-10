-- | The regular-expression dialect of CEL's @matches@ as cel-python runs it:
-- google-re2's @re2.search(pattern, text)@ with default options.
--
-- That means RE2's Perl-like syntax with RE2's Unicode 15.1 tables:
--
-- * @^@ and @$@ match only at the ends of the text unless @(?m)@ is on (and
--   @$@ does not match before a final newline); @.@ excludes @\\n@ unless
--   @(?s)@ is on.
-- * @\\d@, @\\s@, @\\w@, @\\b@ and the POSIX classes are ASCII-only; @\\pX@,
--   @\\p{Name}@, @\\PX@ and @\\p{^Name}@ use Unicode categories and scripts.
-- * @(?i)@ folds case through RE2's case orbits (so @k@ matches the Kelvin
--   sign but @ß@ never matches @SS@).
-- * Lookaround, backreferences, @(?#...)@, @(?x)@, @\\Z@, possessive and
--   stacked repetition operators are syntax errors, as are repetition counts
--   above 1000 (also across nesting).
--
-- The parser follows RE2's @parse.cc@ step by step, so the same patterns are
-- rejected, with RE2's error text. Matching is a Thompson-NFA simulation, so
-- it is linear in the text like RE2 and only answers whether a match exists.
--
-- Known deviations (none reachable from realistic Petrus filters):
--
-- * @\\C@ matches one code point rather than one UTF-8 byte.
-- * RE2 rejects patterns whose compiled program is too large (for example
--   @\\pL{500}@); the size here is an estimate of RE2's, so the cut-off is
--   approximate.
module Petrus.Cel.Regex
  ( Regex
  , compileRegex
  , compileRegexBytes
  , searchText
  , searchBytes
  ) where

import Control.Monad (foldM)
import Control.Monad.ST (ST, runST)
import Data.Array (Array)
import Data.Array qualified as A
import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, ord)
import Data.IntMap.Strict qualified as IntMap
import Data.STRef (newSTRef, readSTRef, writeSTRef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)

import Petrus.Cel.Unicode (RangeSet, member, rangeSet, rangeSetRanges, re2Category, re2Orbit, re2Orbits, re2Script)

-- | A compiled pattern.
data Regex = Regex (Array Int Inst) Int

-- ---------------------------------------------------------------------------
-- Syntax tree

data Assertion = BeginText | EndText | BeginLine | EndLine | WordBoundary | NotWordBoundary

data Node
  = NEmpty
  | NClass RangeSet
  | NAnyByte
  | NAssert Assertion
  | NCat [Node]
  | NAlt [Node]
  | NStar Node
  | NPlus Node
  | NQuest Node
  | -- | @{lo,hi}@; @hi@ is @-1@ when unbounded.
    NRepeat Int Int Node

data Flags = Flags
  { flagFold :: Bool
  , flagOneLine :: Bool
  , flagDotNL :: Bool
  }

-- | RE2's @LikePerl@ defaults (the non-greedy flag is irrelevant to
-- whether a match exists, so it is not tracked).
perlFlags :: Flags
perlFlags = Flags {flagFold = False, flagOneLine = True, flagDotNL = False}

-- | One open group: the flags to restore at its @)@, its finished
-- alternatives, and the current concatenation (both reversed).
data Group = Group Flags [Node] [Node]

data St = St
  { stPos :: Int
  , stFlags :: Flags
  , stGroup :: Group
  , stOuter :: [Group]
  }

maxRepeat :: Int
maxRepeat = 1000

maxRune :: Int
maxRune = 0x10FFFF

-- ---------------------------------------------------------------------------
-- Character sets

fullSet :: RangeSet
fullSet = rangeSet [(0, maxRune)]

complementSet :: RangeSet -> RangeSet
complementSet s = rangeSet (go 0 (rangeSetRanges s))
  where
    go next [] = [(next, maxRune) | next <= maxRune]
    go next ((lo, hi) : rest) = [(next, lo - 1) | next < lo] <> go (hi + 1) rest

unionSets :: [RangeSet] -> RangeSet
unionSets = rangeSet . concatMap rangeSetRanges

-- | Close a set under RE2's case-folding orbits.
foldSet :: RangeSet -> RangeSet
foldSet s = rangeSet (rangeSetRanges s <> [(c, c) | orbit <- re2Orbits, any (`member` s) orbit, c <- orbit])

ranges :: [(Int, Int)] -> RangeSet
ranges = rangeSet

charRanges :: [(Char, Char)] -> RangeSet
charRanges rs = rangeSet [(ord a, ord b) | (a, b) <- rs]

perlGroup :: Char -> Maybe (Int, RangeSet)
perlGroup = \case
  'd' -> Just (1, digits)
  'D' -> Just (-1, digits)
  's' -> Just (1, spaces)
  'S' -> Just (-1, spaces)
  'w' -> Just (1, word)
  'W' -> Just (-1, word)
  _ -> Nothing
  where
    digits = charRanges [('0', '9')]
    spaces = ranges [(9, 10), (12, 13), (32, 32)]
    word = charRanges [('0', '9'), ('A', 'Z'), ('a', 'z'), ('_', '_')]

posixGroup :: Text -> Maybe (Int, RangeSet)
posixGroup name = case T.stripPrefix "[:^" name of
  Just rest -> (,) (-1) <$> lookupName (T.dropEnd 2 rest)
  Nothing -> (,) 1 <$> (T.stripPrefix "[:" name >>= lookupName . T.dropEnd 2)
  where
    lookupName = \case
      "alnum" -> Just (charRanges [('0', '9'), ('A', 'Z'), ('a', 'z')])
      "alpha" -> Just (charRanges [('A', 'Z'), ('a', 'z')])
      "ascii" -> Just (ranges [(0, 0x7F)])
      "blank" -> Just (ranges [(9, 9), (32, 32)])
      "cntrl" -> Just (ranges [(0, 0x1F), (0x7F, 0x7F)])
      "digit" -> Just (charRanges [('0', '9')])
      "graph" -> Just (ranges [(0x21, 0x7E)])
      "lower" -> Just (charRanges [('a', 'z')])
      "print" -> Just (ranges [(0x20, 0x7E)])
      "punct" -> Just (ranges [(0x21, 0x2F), (0x3A, 0x40), (0x5B, 0x60), (0x7B, 0x7E)])
      "space" -> Just (ranges [(9, 13), (32, 32)])
      "upper" -> Just (charRanges [('A', 'Z')])
      "word" -> Just (charRanges [('0', '9'), ('A', 'Z'), ('a', 'z'), ('_', '_')])
      "xdigit" -> Just (charRanges [('0', '9'), ('A', 'F'), ('a', 'f')])
      _ -> Nothing

-- | RE2's @AddUGroup@: a positive group is case-folded when folding; a
-- negative one is the complement of the (folded) positive group.
groupSet :: Flags -> Int -> RangeSet -> RangeSet
groupSet flags sign g =
  let positive = if flagFold flags then foldSet g else g
   in if sign > 0 then positive else complementSet positive

-- | RE2's @AddRangeFlags@ for an explicit range.
rangeItem :: Flags -> Int -> Int -> RangeSet
rangeItem flags lo hi =
  let s = rangeSet [(lo, hi)]
   in if flagFold flags then foldSet s else s

literalNode :: Flags -> Int -> Node
literalNode flags c
  | flagFold flags = NClass (rangeSet [(x, x) | x <- re2Orbit c])
  | otherwise = NClass (rangeSet [(c, c)])

-- ---------------------------------------------------------------------------
-- Parser (RE2 parse.cc)

-- | Compile a pattern, or give RE2's error text.
compileRegex :: Text -> Either Text Regex
compileRegex pattern = do
  node <- parseRegex pattern
  let prog = compileNode node
  if programCost node > maxProgramCost
    then Left "pattern too large - compile failed"
    else Right prog

-- | Compile a @bytes@ pattern (which must be UTF-8).
compileRegexBytes :: ByteString -> Either Text Regex
compileRegexBytes bytes = case TE.decodeUtf8' bytes of
  Left _ -> Left "invalid UTF-8"
  Right pattern -> compileRegex pattern

parseRegex :: Text -> Either Text Node
parseRegex whole = loop Nothing (St 0 perlFlags (Group perlFlags [] []) [])
  where
    pn = T.length whole
    pa :: UArray Int Char
    pa = listArray (0, pn - 1) (T.unpack whole)
    at i = if i >= 0 && i < pn then Just (pa ! i) else Nothing
    slice i j = T.pack [pa ! k | k <- [i .. min pn j - 1]]
    status code arg = Left (if T.null arg then code else code <> ": " <> arg)

    push node st = let Group f alts items = stGroup st in st {stGroup = Group f alts (node : items)}

    -- One iteration of RE2's main loop; @lastRepeat@ is where the previous
    -- iteration's repetition operator started, if it was one.
    loop :: Maybe Int -> St -> Either Text Node
    loop lastRepeat st = case at pos of
      Nothing -> finish st
      Just c -> case c of
        '('
          | at (pos + 1) == Just '?' -> perlFlagsGroup st >>= loop Nothing
          | otherwise -> loop Nothing (openGroup (stFlags st) st) {stPos = pos + 1}
        '|' ->
          let Group f alts items = stGroup st
           in loop Nothing st {stPos = pos + 1, stGroup = Group f (concatNode items : alts) []}
        ')' -> case stOuter st of
          [] -> status "unexpected )" whole
          Group f alts items : outer ->
            let Group saved innerAlts innerItems = stGroup st
                node = altNode (concatNode innerItems : innerAlts)
             in loop Nothing st {stPos = pos + 1, stFlags = saved, stGroup = Group f alts (node : items), stOuter = outer}
        '^' -> next (NAssert (if flagOneLine flags then BeginText else BeginLine)) 1
        '$' -> next (NAssert (if flagOneLine flags then EndText else EndLine)) 1
        '.' -> next (NClass (if flagDotNL flags then fullSet else ranges [(0, 9), (11, maxRune)])) 1
        '[' -> do
          (set, pos') <- charClass flags pos
          loop Nothing (push (NClass set) st) {stPos = pos'}
        _ | c `elem` ['*', '+', '?'] -> do
          let nongreedy = at (pos + 1) == Just '?'
              end = if nongreedy then pos + 2 else pos + 1
              opstr = slice pos end
          case lastRepeat of
            Just start -> status "bad repetition operator" (slice start end)
            Nothing -> pure ()
          st' <- applyRepeat opstr st $ \x -> case c of
            '*' -> NStar x
            '+' -> NPlus x
            _ -> NQuest x
          loop (Just pos) st' {stPos = end}
        '{' -> case maybeParseRepeat (pos + 1) of
          Nothing -> next (literalNode flags (ord '{')) 1
          Just (lo, hi, afterBrace) -> do
            let nongreedy = at afterBrace == Just '?'
                end = if nongreedy then afterBrace + 1 else afterBrace
                opstr = slice pos end
            case lastRepeat of
              Just start -> status "bad repetition operator" (slice start end)
              Nothing -> pure ()
            if (hi /= -1 && hi < lo) || lo > maxRepeat || hi > maxRepeat
              then status "invalid repetition size" opstr
              else do
                st' <- applyRepeat opstr st (NRepeat lo hi)
                if (lo >= 2 || hi >= 2) && budget st' == 0
                  then status "invalid repetition size" opstr
                  else loop (Just pos) st' {stPos = end}
        '\\' -> escape st
        _ -> next (literalNode flags (ord c)) 1
      where
        pos = stPos st
        flags = stFlags st
        next node width = loop Nothing (push node st) {stPos = pos + width}

    budget st = case stGroup st of
      Group _ _ (node : _) -> repetitionBudget maxRepeat node
      _ -> maxRepeat

    applyRepeat opstr st wrap = case stGroup st of
      Group f alts (x : items) -> Right st {stGroup = Group f alts (wrap x : items)}
      Group _ _ [] -> status "no argument for repetition operator" opstr

    openGroup flags st = st {stGroup = Group flags [] [], stOuter = stGroup st : stOuter st}

    finish st = case stOuter st of
      [] -> let Group _ alts items = stGroup st in Right (altNode (concatNode items : alts))
      _ -> status "missing )" whole

    -- RE2's MaybeParseRepeat, starting after the '{'.
    maybeParseRepeat i = do
      (lo, j) <- parseInteger i
      c <- at j
      (hi, k) <-
        if c == ','
          then case at (j + 1) of
            Just '}' -> Just (-1, j + 1)
            Just _ -> parseInteger (j + 1)
            Nothing -> Nothing
          else Just (lo, j)
      if at k == Just '}' then Just (lo, hi, k + 1) else Nothing

    parseInteger i = case at i of
      Just d
        | isDigit d ->
            if d == '0' && maybe False isDigit (at (i + 1))
              then Nothing
              else digitsFrom i 0
      _ -> Nothing
    digitsFrom i n = case at i of
      Just d
        | isDigit d -> if n >= 100000000 then Nothing else digitsFrom (i + 1) (n * 10 + ord d - ord '0')
      _ -> Just (n, i)

    -- "(?" at stPos: flags, non-capturing and named groups.
    perlFlagsGroup st
      | (len > 3 && (c2 == Just '=' || c2 == Just '!')) || (len > 4 && c2 == Just '<' && (c3 == Just '=' || c3 == Just '!')) =
          status "invalid perl operator" (slice pos (pos + if c2 == Just '<' then 4 else 3))
      | (len > 4 && c2 == Just 'P' && c3 == Just '<') || (len > 3 && c2 == Just '<') =
          let begin = if c2 == Just 'P' then pos + 4 else pos + 3
           in case [k | k <- [pos + 2 .. pn - 1], pa ! k == '>'] of
                [] -> status "invalid named capture group" (slice pos pn)
                end : _
                  | validCaptureName (slice begin end) -> Right (openGroup (stFlags st) st) {stPos = end + 1}
                  | otherwise -> status "invalid named capture group" (slice pos (end + 1))
      | otherwise = flagLoop (pos + 2) False False (stFlags st)
      where
        pos = stPos st
        len = pn - pos
        c2 = at (pos + 2)
        c3 = at (pos + 3)
        bad i = status "invalid perl operator" (slice pos i)
        flagLoop i negated sawflag nflags = case at i of
          Nothing -> bad i
          Just c ->
            let i' = i + 1
                set f = flagLoop i' negated True (f (not negated) nflags)
             in case c of
                  'i' -> set (\v fl -> fl {flagFold = v})
                  'm' -> set (\v fl -> fl {flagOneLine = not v})
                  's' -> set (\v fl -> fl {flagDotNL = v})
                  'U' -> set (\_ fl -> fl)
                  '-'
                    | negated -> bad i'
                    | otherwise -> flagLoop i' True False nflags
                  ':' -> done i' negated sawflag nflags (openGroup (stFlags st) st)
                  ')' -> done i' negated sawflag nflags st
                  _ -> bad i'
        done i' negated sawflag nflags st'
          | negated && not sawflag = bad i'
          | otherwise = Right st' {stPos = i', stFlags = nflags}

    validCaptureName name =
      not (T.null name) && T.all (\ch -> any (\cat -> maybe False (member (ord ch)) (re2Category cat)) captureCategories) name
    captureCategories = ["Lu", "Ll", "Lt", "Lm", "Lo", "Nl", "Mn", "Mc", "Nd", "Pc"]

    escape st = case at (pos + 1) of
      Just 'b' -> next (NAssert WordBoundary) 2
      Just 'B' -> next (NAssert NotWordBoundary) 2
      Just 'A' -> next (NAssert BeginText) 2
      Just 'z' -> next (NAssert EndText) 2
      Just 'C' -> next NAnyByte 2
      Just 'Q' -> quoted (pos + 2) st
      Just p | p == 'p' || p == 'P' -> do
        (set, pos') <- unicodeGroup flags pos
        loop Nothing (push (NClass set) st) {stPos = pos'}
      Just d | Just (sign, g) <- perlGroup d -> next (NClass (groupSet flags sign g)) 2
      _ -> do
        (r, pos') <- parseEscape pos
        loop Nothing (push (literalNode flags r) st) {stPos = pos'}
      where
        pos = stPos st
        flags = stFlags st
        next node width = loop Nothing (push node st) {stPos = pos + width}
        quoted i s = case at i of
          Nothing -> loop Nothing s {stPos = i}
          Just '\\' | at (i + 1) == Just 'E' -> loop Nothing s {stPos = i + 2}
          Just ch -> quoted (i + 1) (push (literalNode flags (ord ch)) s)

    -- \p{Name}, \pN, \P..., \p{^Name} starting at the backslash.
    unicodeGroup flags i = do
      let sign0 = if at (i + 1) == Just 'P' then -1 else 1 :: Int
      (name, end) <- case at (i + 2) of
        Just '{' -> case [k | k <- [i + 3 .. pn - 1], pa ! k == '}'] of
          [] -> status "invalid character class range" (slice i pn)
          close : _ -> Right (slice (i + 3) close, close + 1)
        Just ch -> Right (T.singleton ch, i + 3)
        Nothing -> Right ("", i + 2)
      let seq' = slice i end
          (sign, name') = case T.uncons name of
            Just ('^', rest) -> (negate sign0, rest)
            _ -> (sign0, name)
          g
            | name' == "Any" = Just fullSet
            | otherwise = case re2Category (T.unpack name') of
                Just set -> Just set
                Nothing -> re2Script (T.unpack name')
      case g of
        Nothing -> status "invalid character class range" seq'
        Just set -> Right (groupSet flags sign set, end)

    -- RE2's ParseEscape starting at the backslash: the rune and the next position.
    parseEscape i = case at (i + 1) of
      Nothing -> status "trailing \\" ""
      Just c -> case c of
        _ | c >= '1' && c <= '7' -> case at j of
          Just d | isOctal d -> octal (ord c - ord '0') j
          _ -> badEscape j
        '0' -> octal 0 j
        'x' -> case at j of
          Nothing -> badEscape j
          Just '{' -> case at (j + 1) of
            Nothing -> status "invalid UTF-8" ""
            Just h -> hexBraced h (j + 2) 0 (0 :: Int)
          Just h1 -> case at (j + 1) of
            Nothing -> badEscape (j + 1)
            Just h2
              | isHexDigit h1 && isHexDigit h2 -> Right (hexValue h1 * 16 + hexValue h2, j + 2)
              | otherwise -> badEscape (j + 2)
        'n' -> Right (10, j)
        'r' -> Right (13, j)
        't' -> Right (9, j)
        'a' -> Right (7, j)
        'f' -> Right (12, j)
        'v' -> Right (11, j)
        _
          | ord c < 0x80 && not (isAsciiLower c || isAsciiUpper c || isDigit c) -> Right (ord c, j)
          | otherwise -> badEscape j
      where
        j = i + 2
        badEscape k = status "invalid escape sequence" (slice i k)
        isOctal d = d >= '0' && d <= '7'
        octal code k = case at k of
          Just d
            | isOctal d ->
                let code' = code * 8 + ord d - ord '0'
                 in case at (k + 1) of
                      Just e | isOctal e -> Right (code' * 8 + ord e - ord '0', k + 2)
                      _ -> Right (code', k + 1)
          _ -> Right (code, k)
        hexBraced h k code nhex
          | isHexDigit h =
              let code' = code * 16 + hexValue h
               in if code' > maxRune
                    then badEscape k
                    else case at k of
                      Nothing -> badEscape k
                      Just h' -> hexBraced h' (k + 1) code' (nhex + 1)
          | h /= '}' || nhex == 0 = badEscape k
          | otherwise = Right (code, k)

    hexValue h
      | isDigit h = ord h - ord '0'
      | isAsciiLower h = ord h - ord 'a' + 10
      | otherwise = ord h - ord 'A' + 10

    -- RE2's ParseCharClass starting at the '['.
    charClass flags start = do
      let afterOpen = start + 1
          (negated, i0) = if at afterOpen == Just '^' then (True, afterOpen + 1) else (False, afterOpen)
          missing :: Either Text a
          missing = status "missing ]" (slice start pn)
          items i first acc = case at i of
            Nothing -> missing
            Just ']' | not first -> Right (acc, i + 1)
            Just c
              | pn - i > 2 && c == '[' && at (i + 1) == Just ':'
              , Just nameEnd <- ccNameEnd (i + 2) -> do
                  let name = slice i nameEnd
                  case posixGroup name of
                    Nothing -> status "invalid character class range" name
                    Just (sign, g) -> items nameEnd False (groupSet flags sign g : acc)
              | pn - i > 2 && c == '\\' && (at (i + 1) == Just 'p' || at (i + 1) == Just 'P') -> do
                  (set, i') <- unicodeGroup flags i
                  items i' False (set : acc)
              | c == '\\'
              , Just d <- at (i + 1)
              , Just (sign, g) <- perlGroup d ->
                  items (i + 2) False (groupSet flags sign g : acc)
              | otherwise -> do
                  (lo, j) <- ccCharacter i
                  case (at j, at (j + 1)) of
                    (Just '-', Just c2) | c2 /= ']' -> do
                      (hi, k) <- ccCharacter (j + 1)
                      if hi < lo
                        then status "invalid character class range" (slice i k)
                        else items k False (rangeItem flags lo hi : acc)
                    _ -> items j False (rangeItem flags lo lo : acc)
          ccCharacter i = case at i of
            Nothing -> missing
            Just '\\' -> parseEscape i
            Just c -> Right (ord c, i + 1)
      (sets, end) <- items i0 True []
      let set = unionSets sets
      Right (if negated then complementSet set else set, end)

    -- The end of a "[:name:]" whose ":]" is searched from @q@ on.
    ccNameEnd q
      | q > pn - 2 = Nothing
      | pa ! q == ':' && pa ! (q + 1) == ']' = Just (q + 2)
      | otherwise = ccNameEnd (q + 1)

concatNode :: [Node] -> Node
concatNode = \case
  [] -> NEmpty
  [x] -> x
  reversed -> NCat (reverse reversed)

altNode :: [Node] -> Node
altNode = \case
  [x] -> x
  reversed -> NAlt (reverse reversed)

-- | RE2's RepetitionWalker: 1000 divided by the nested repetition counts.
repetitionBudget :: Int -> Node -> Int
repetitionBudget arg = \case
  NRepeat lo hi x ->
    let m = if hi < 0 then lo else hi
        arg' = if m > 0 then arg `div` m else arg
     in min arg' (repetitionBudget arg' x)
  NCat xs -> minimum (arg : map (repetitionBudget arg) xs)
  NAlt xs -> minimum (arg : map (repetitionBudget arg) xs)
  NStar x -> min arg (repetitionBudget arg x)
  NPlus x -> min arg (repetitionBudget arg x)
  NQuest x -> min arg (repetitionBudget arg x)
  _ -> arg

-- | An estimate of RE2's program size (a class costs about two
-- instructions per range once encoded as UTF-8).
programCost :: Node -> Int
programCost = \case
  NEmpty -> 1
  NClass s -> max 1 (2 * length (rangeSetRanges s))
  NAnyByte -> 1
  NAssert _ -> 1
  NCat xs -> sum (map programCost xs)
  NAlt xs -> sum (map programCost xs) + length xs
  NStar x -> programCost x + 1
  NPlus x -> programCost x + 1
  NQuest x -> programCost x + 1
  NRepeat lo hi x
    | hi < 0 -> (lo + 1) * programCost x + 1
    | otherwise -> hi * (programCost x + 1)

maxProgramCost :: Int
maxProgramCost = 540000

-- ---------------------------------------------------------------------------
-- Compilation to an NFA program

data Inst
  = IChar RangeSet Int
  | IAnyUnit Int
  | ISplit Int Int
  | IAssert Assertion Int
  | IMatch

compileNode :: Node -> Regex
compileNode node =
  let (start, (count, insts)) = comp node 0 (1, IntMap.singleton 0 IMatch)
   in Regex (A.listArray (0, count - 1) (IntMap.elems insts)) start
  where
    new inst (n, m) = (n, (n + 1, IntMap.insert n inst m))
    comp :: Node -> Int -> (Int, IntMap.IntMap Inst) -> (Int, (Int, IntMap.IntMap Inst))
    comp n k s = case n of
      NEmpty -> (k, s)
      NClass set -> new (IChar set k) s
      NAnyByte -> new (IAnyUnit k) s
      NAssert a -> new (IAssert a k) s
      NCat xs -> foldr (\x (k', s') -> comp x k' s') (k, s) xs
      NAlt [] -> (k, s)
      NAlt [x] -> comp x k s
      NAlt (x : xs) ->
        let (a, s1) = comp x k s
            (b, s2) = comp (NAlt xs) k s1
         in new (ISplit a b) s2
      NStar x ->
        let (loopPc, (c, m)) = (fst s, (fst s + 1, snd s))
            (body, (c', m')) = comp x loopPc (c, m)
         in (loopPc, (c', IntMap.insert loopPc (ISplit body k) m'))
      NPlus x ->
        let (loopPc, (c, m)) = (fst s, (fst s + 1, snd s))
            (body, (c', m')) = comp x loopPc (c, m)
         in (body, (c', IntMap.insert loopPc (ISplit body k) m'))
      NQuest x ->
        let (body, s1) = comp x k s
         in new (ISplit body k) s1
      NRepeat lo hi x ->
        let optional
              | hi < 0 = [NStar x]
              | otherwise = replicate (hi - lo) (NQuest x)
         in comp (NCat (replicate lo x <> optional)) k s

-- ---------------------------------------------------------------------------
-- Matching

-- | Is there a match anywhere in the text (@re2.search(...) is not None@)?
searchText :: Regex -> Text -> Bool
searchText re text = search re (map ord (T.unpack text))

-- | Search a @bytes@ subject: valid UTF-8 sequences are characters, and
-- each byte of an invalid sequence matches only @\\C@.
searchBytes :: Regex -> ByteString -> Bool
searchBytes re = search re . decodeUnits . BS.unpack
  where
    decodeUnits = \case
      [] -> []
      b : rest
        | b < 0x80 -> fromIntegral b : decodeUnits rest
        | Just (c, rest') <- multi b rest -> c : decodeUnits rest'
        | otherwise -> -1 : decodeUnits rest
    multi b rest
      | b >= 0xC2 && b <= 0xDF = cont 1 (fromIntegral b .&. 0x1F) 0x80 0xBF rest
      | b == 0xE0 = cont 2 (fromIntegral b .&. 0x0F) 0xA0 0xBF rest
      | b == 0xED = cont 2 (fromIntegral b .&. 0x0F) 0x80 0x9F rest
      | b >= 0xE1 && b <= 0xEF = cont 2 (fromIntegral b .&. 0x0F) 0x80 0xBF rest
      | b == 0xF0 = cont 3 (fromIntegral b .&. 0x07) 0x90 0xBF rest
      | b >= 0xF1 && b <= 0xF3 = cont 3 (fromIntegral b .&. 0x07) 0x80 0xBF rest
      | b == 0xF4 = cont 3 (fromIntegral b .&. 0x07) 0x80 0x8F rest
      | otherwise = Nothing
    cont :: Int -> Int -> Int -> Int -> [Word8] -> Maybe (Int, [Word8])
    cont n acc firstLo firstHi = \case
      x : rest
        | fromIntegral x >= firstLo && fromIntegral x <= firstHi ->
            let acc' = (acc `shiftL` 6) .|. (fromIntegral x .&. 0x3F)
             in if n == 1 then Just (acc', rest) else cont (n - 1) acc' 0x80 0xBF rest
      _ -> Nothing

search :: Regex -> [Int] -> Bool
search (Regex prog start) units = runST $ do
  let n = length units
      text :: UArray Int Int
      text = listArray (0, n - 1) units
      unit i = if i >= 0 && i < n then text ! i else -2
      isWord c = c >= 0 && c < 0x80 && (isAsciiLower (chr c) || isAsciiUpper (chr c) || isDigit (chr c) || c == ord '_')
      boundary i = isWord (unit (i - 1)) /= isWord (unit i)
      holds i = \case
        BeginText -> i == 0
        EndText -> i == n
        BeginLine -> i == 0 || unit (i - 1) == 10
        EndLine -> i == n || unit i == 10
        WordBoundary -> boundary i
        NotWordBoundary -> not (boundary i)
      (_, lastPc) = A.bounds prog
  marks <- newArray (0, lastPc) (-1) :: ST s (STUArray s Int Int)
  found <- newSTRef False
  let add i acc pc = do
        seen <- readArray marks pc
        if seen == i
          then pure acc
          else do
            writeArray marks pc i
            case prog A.! pc of
              IMatch -> acc <$ writeSTRef found True
              ISplit a b -> add i acc a >>= \acc' -> add i acc' b
              IAssert a k -> if holds i a then add i acc k else pure acc
              _ -> pure (pc : acc)
      step i threads = do
        threads' <- add i threads start
        matched <- readSTRef found
        if matched
          then pure True
          else
            if i >= n
              then pure False
              else do
                let c = text ! i
                next <-
                  foldM
                    ( \acc pc -> case prog A.! pc of
                        IChar set k | c >= 0 && member c set -> add (i + 1) acc k
                        IAnyUnit k -> add (i + 1) acc k
                        _ -> pure acc
                    )
                    []
                    (reverse threads')
                step (i + 1) next
  step 0 []

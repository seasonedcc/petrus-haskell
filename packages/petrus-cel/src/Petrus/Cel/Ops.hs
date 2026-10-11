-- | The Python object protocol cel-python's evaluation runs on.
--
-- cel-python implements CEL operators with Python's own operators over the
-- @celtypes@ classes, so the outcome of @a + b@ depends on CPython's binary
-- operator dispatch (@binary_op1@ with slot identity, reflected methods,
-- sequence concatenation and repetition), on which dunder methods each
-- @celtypes@ class overrides, and on the builtin types' C implementations.
-- This module reproduces that machinery for every class a value can have:
--
-- * arithmetic ('numberOp'): @IntType@ arithmetic wraps @int@'s and
--   range-checks, @IntType@ division truncates and works through
--   comparisons, @abs@ and floor division exactly as @celtypes@ writes it,
--   @true + 2@ is a plain @int@, @[1] + [2]@ a plain @list@, @2.5 / 0.0@ is
--   @inf@, and a @CELEvalError@ operand is absorbed or rejected depending on
--   which side it is on;
-- * comparison ('richCompare'): CPython's @do_richcompare@ (reflected method
--   first for a proper subclass, identity fallback for @==@/@!=@) over the
--   classes' methods, including @celtypes@' @type_matched@ guards and the
--   custom @ListType@/@MapType@ equality that folds element comparisons with
--   @logical_and@;
-- * containers ('getItem', 'pyIter', 'pyLen', 'operatorIn') with
--   dictionary lookups that compare same-hash keys exactly as CPython does;
-- * calls ('callValue'): the @celtypes@ constructors and cel-python's
--   builtin functions, with Python's argument-count errors.
--
-- Errors are values: every operation returns @Left@ the Python exception it
-- would raise, so callers can catch by class exactly where cel-python does.
--
-- Deviations (none observable through CEL in practice): object identity is
-- not tracked, so the identity shortcuts of @list.__eq__@ and dict lookups
-- are not taken (they only matter for a NaN compared with itself), and
-- repeating a sequence beyond 2^31 elements fails with @MemoryError@ instead
-- of attempting the allocation.
module Petrus.Cel.Ops
  ( -- * Arithmetic
    NumOp (..)
  , numberOp
  , negative
  , pyAbs
    -- * Comparison
  , CmpOp (..)
  , richCompare
    -- * Logic
  , logicalNot
  , logicalAnd
  , logicalOr
  , logicalCondition
    -- * Containers
  , pyLen
  , pyIter
  , getItem
  , dictLookup
  , dictContains
  , dictSet
  , operatorIn
    -- * Calls
  , callValue
  , resolveFunction
  , typeOf
  , isExcClass
  ) where

import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, ord)
import Data.Maybe (isJust)
import Data.Ratio ((%))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Numeric (showHex)

import Petrus.Cel.Python
import Petrus.Cel.Regex (compileRegex, compileRegexBytes, searchBytes, searchText)
import Petrus.Cel.Time
import Petrus.Cel.Value
import Petrus.Json.Wtf8 (hasLoneSurrogate)

-- ---------------------------------------------------------------------------
-- Helpers

typeErr :: Text -> Exc
typeErr = pyExc TypeError

valueErr :: Text -> Exc
valueErr = pyExc ValueError

tpName :: Value -> Text
tpName = className . pyType

quoted :: Text -> Text
quoted t = "'" <> t <> "'"

-- | Is the exception an instance of the class (or, for 'ValueError', of a
-- subclass)?
isExcClass :: ExcClass -> Exc -> Bool
isExcClass cls = \case
  PyExc c _ _
    | cls == ValueError -> isValueError c
    | otherwise -> c == cls
  CelExc _ -> False

boolType :: Bool -> Value
boolType b = VBool (if b then 1 else 0)

liftPy :: Either PyErr a -> Either Exc a
liftPy = either (Left . fromPyErr) Right

isText :: Value -> Bool
isText v = isJust (asText v)

maxSsize :: Integer
maxSsize = 2 ^ (63 :: Int) - 1

-- | @int(x)@ for a float: truncation with Python's errors.
truncDouble :: Double -> Either Exc Integer
truncDouble d
  | isNaN d = Left (valueErr "cannot convert float NaN to integer")
  | isInfinite d = Left (pyExc OverflowError "cannot convert float infinity to integer")
  | otherwise = Right (truncate d)

-- | @float(n)@ for an int (correctly rounded, @OverflowError@ beyond range).
intToDouble :: Integer -> Either Exc Double
intToDouble n =
  let d = fromRational (fromInteger n) :: Double
   in if isInfinite d then Left (pyExc OverflowError "int too large to convert to float") else Right d

-- | The C library's @fmod@ (exact).
fmod :: Double -> Double -> Double
fmod x y
  | isNaN x || isNaN y || isInfinite x = 0 / 0
  | isInfinite y = x
  | otherwise =
      let rx = toRational x
          ry = toRational y
          q = truncate (rx / ry) :: Integer
          r = fromRational (rx - fromInteger q * ry) :: Double
       in if r == 0 then (if x < 0 || isNegativeZero x then -0.0 else 0.0) else r

copySign :: Double -> Double -> Double
copySign magnitude sign
  | sign < 0 || isNegativeZero sign = negate (abs magnitude)
  | otherwise = abs magnitude

-- | Python's float @%@.
floatMod :: Double -> Double -> Double
floatMod vx wx =
  let m = fmod vx wx
   in if m /= 0
        then (if (wx < 0) /= (m < 0) then m + wx else m)
        else copySign 0 wx

-- | Python's float @//@.
floatFloorDiv :: Double -> Double -> Double
floatFloorDiv vx wx =
  let m0 = fmod vx wx
      d0 = (vx - m0) / wx
      d = if m0 /= 0 && (wx < 0) /= (m0 < 0) then d0 - 1 else d0
   in if d /= 0
        then
          let fl = if isInfinite d || isNaN d then d else fromInteger (floor d)
           in if d - fl > 0.5 then fl + 1 else fl
        else copySign 0 (vx / wx)

-- ---------------------------------------------------------------------------
-- Arithmetic

-- | The numeric binary operators.
data NumOp = OpAdd | OpSub | OpMul | OpTrueDiv | OpFloorDiv | OpMod
  deriving stock (Eq, Show)

opSymbol :: NumOp -> Text
opSymbol = \case
  OpAdd -> "+"
  OpSub -> "-"
  OpMul -> "*"
  OpTrueDiv -> "/"
  OpFloorDiv -> "//"
  OpMod -> "%"

-- | Which builtin C implementation fills a number slot.
data CKind = KLong | KFloat | KDelta | KDatetime | KStrMod | KBytesMod
  deriving stock (Eq)

-- | A type's number slot: empty, a builtin's C function, or @slot_nb_*@
-- (the class defines the dunder in Python).
data Slot = NoSlot | CSlot CKind | PySlot
  deriving stock (Eq)

numSlot :: PyClass -> NumOp -> Slot
numSlot cls op = case cls of
  CInt -> CSlot KLong
  CBoolType -> CSlot KLong
  CIntType -> PySlot
  CUintType -> PySlot
  CCELEvalError -> PySlot
  CFloat -> CSlot KFloat
  CDoubleType
    | op == OpTrueDiv || op == OpMod -> PySlot
    | otherwise -> CSlot KFloat
  CStr | op == OpMod -> CSlot KStrMod
  CStringType | op == OpMod -> CSlot KStrMod
  CBytes | op == OpMod -> CSlot KBytesMod
  CBytesType | op == OpMod -> CSlot KBytesMod
  CTimedelta -> CSlot KDelta
  CDurationType
    | op == OpAdd -> PySlot
    | otherwise -> CSlot KDelta
  CDatetime | op == OpAdd || op == OpSub -> CSlot KDatetime
  CTimestampType | op == OpAdd || op == OpSub -> PySlot
  _ -> NoSlot

-- | @PyNumber_Add@ / @_Subtract@ / @_Multiply@ / @_TrueDivide@ /
-- @_FloorDivide@ / @_Remainder@.
numberOp :: NumOp -> Value -> Value -> Either Exc Value
numberOp op v w =
  binaryOp1 op v w >>= \case
    Just r -> Right r
    Nothing -> case op of
      OpAdd | Just concatenate <- sqConcat v -> concatenate w
      OpMul
        | isSequence v -> sequenceRepeat v w
        | isSequence w -> sequenceRepeat w v
      _ -> Left (binopTypeError op v w)

binopTypeError :: NumOp -> Value -> Value -> Exc
binopTypeError op v w =
  typeErr ("unsupported operand type(s) for " <> opSymbol op <> ": " <> quoted (tpName v) <> " and " <> quoted (tpName w))

-- | CPython's @binary_op1@: 'Nothing' is @NotImplemented@.
binaryOp1 :: NumOp -> Value -> Value -> Either Exc (Maybe Value)
binaryOp1 op v w
  | sv /= NoSlot = do
      first <- if wFirst then callSlot sw op v w else Right Nothing
      case first of
        Just x -> Right (Just x)
        Nothing ->
          callSlot sv op v w >>= \case
            Just x -> Right (Just x)
            Nothing -> if wFirst then Right Nothing else callSlot sw op v w
  | otherwise = callSlot sw op v w
  where
    tv = pyType v
    tw = pyType w
    sv = numSlot tv op
    swRaw = if tw == tv then NoSlot else numSlot tw op
    sw = if swRaw == sv then NoSlot else swRaw
    wFirst = sw /= NoSlot && isSubclass tw tv

callSlot :: Slot -> NumOp -> Value -> Value -> Either Exc (Maybe Value)
callSlot slot op v w = case slot of
  NoSlot -> Right Nothing
  CSlot k -> cImpl k op v w
  PySlot -> slotNb op v w

-- | @SLOT1BINFULL@: the class's @__op__@, then the other operand's
-- @__rop__@.
slotNb :: NumOp -> Value -> Value -> Either Exc (Maybe Value)
slotNb op self other = do
  let ts = pyType self
      to = pyType other
      doOther = ts /= to && numSlot to op == PySlot
  r <- if numSlot ts op == PySlot then forwardMethod op self other else Right Nothing
  case r of
    Just x -> Right (Just x)
    Nothing
      | doOther -> reflectedMethod op other self
      | otherwise -> Right Nothing

-- | @type(self).__op__(self, other)@ for the classes with Python slots.
forwardMethod :: NumOp -> Value -> Value -> Either Exc (Maybe Value)
forwardMethod op self other = case pyType self of
  CIntType -> Just <$> intTypeMethod op self other
  CUintType -> Just <$> uintTypeMethod op self other
  CCELEvalError -> Right (Just self)
  CDoubleType -> case op of
    OpTrueDiv -> do
      zero <- richCompare CmpEq other (PFloat 0)
      if zero
        then Right (Just (VDouble (1 / 0)))
        else Just <$> (cImpl KFloat OpTrueDiv self other >>= doubleTypeOfResult)
    OpMod ->
      Left (typeErr ("found no matching overload for '_%_' applied to '(double, " <> classRepr (pyType other) <> ")'"))
    _ -> cImpl KFloat op self other
  CDurationType -> case op of
    OpAdd -> cImpl KDelta OpAdd self other >>= traverse wrapDuration
    _ -> cImpl KDelta op self other
  CTimestampType -> case op of
    OpAdd -> cImpl KDatetime OpAdd self other
    OpSub -> cImpl KDatetime OpSub self other >>= traverse wrapDuration
    _ -> Right Nothing
  _ -> Right Nothing

-- | @type(obj).__rop__(obj, arg)@.
reflectedMethod :: NumOp -> Value -> Value -> Either Exc (Maybe Value)
reflectedMethod op obj arg = case pyType obj of
  CIntType -> Just <$> intTypeReflected op obj arg
  CUintType -> Just <$> uintTypeReflected op obj arg
  CCELEvalError -> Right (Just obj)
  CDoubleType -> case op of
    OpTrueDiv -> do
      zero <- richCompare CmpEq obj (PFloat 0)
      if zero
        then Right (Just (VDouble (1 / 0)))
        else Just <$> (cImpl KFloat OpTrueDiv arg obj >>= doubleTypeOfResult)
    OpMod ->
      Left (typeErr ("found no matching overload for '_%_' applied to '(" <> classRepr (pyType arg) <> ", double)'"))
    _ -> cImpl KFloat op arg obj
  CDurationType -> case op of
    OpAdd -> cImpl KDelta OpAdd arg obj >>= traverse wrapDuration
    _ -> cImpl KDelta op arg obj
  CTimestampType -> case op of
    OpAdd -> cImpl KDatetime OpAdd arg obj
    OpSub -> cImpl KDatetime OpSub arg obj
    _ -> Right Nothing
  _ -> Right Nothing

-- | @DurationType(result)@ / @TimestampType(result)@ of an inherited
-- @timedelta@/@datetime@ operation.
wrapDuration :: Value -> Either Exc Value
wrapDuration = \case
  PTimedelta td -> durationType td
  VDuration td -> durationType td
  v -> Right v

-- | @DoubleType(float.__truediv__(...))@.
doubleTypeOfResult :: Maybe Value -> Either Exc Value
doubleTypeOfResult = \case
  Just (PFloat d) -> Right (VDouble d)
  Just v -> VDouble <$> pyFloatConvert v
  Nothing -> Left (typeErr "float() argument must be a string or a real number, not 'NotImplementedType'")

-- | @IntType(result)@ of an inherited operation, where 'Nothing' is
-- @NotImplemented@.
intTypeOfResult :: Maybe Value -> Either Exc Value
intTypeOfResult = \case
  Nothing -> Left notImplementedTypeError
  Just v -> intTypeNew v

uintTypeOfResult :: Maybe Value -> Either Exc Value
uintTypeOfResult = \case
  Nothing -> Left notImplementedTypeError
  Just v -> uintTypeNew v

intTypeMethod :: NumOp -> Value -> Value -> Either Exc Value
intTypeMethod op self other = case op of
  OpTrueDiv -> intTypeDivide self other self other
  OpFloorDiv -> intTypeDivide self other self other
  OpMod -> do
    selfNeg <- richCompare CmpLt self (VInt 0)
    a <- pyAbs self
    b <- pyAbs other
    m <- numberOp OpMod a b
    r <- numberOp OpMul (PInt (if selfNeg then -1 else 1)) m
    intTypeNew r
  _ -> cImpl KLong op self other >>= intTypeOfResult

intTypeReflected :: NumOp -> Value -> Value -> Either Exc Value
intTypeReflected op self other = case op of
  OpTrueDiv -> intTypeDivide self other other self
  OpFloorDiv -> intTypeDivide self other other self
  OpMod -> do
    leftNeg <- richCompare CmpLt other (VInt 0)
    a <- pyAbs other
    b <- pyAbs self
    m <- numberOp OpMod a b
    r <- numberOp OpMul (PInt (if leftNeg then -1 else 1)) m
    intTypeNew r
  _ -> cImpl KLong op other self >>= intTypeOfResult

-- | @IntType.__truediv__@ / @__rtruediv__@:
-- @sign(self) * sign(other) * (abs(dividend) // abs(divisor))@.
intTypeDivide :: Value -> Value -> Value -> Value -> Either Exc Value
intTypeDivide self other dividend divisor = do
  selfNeg <- richCompare CmpLt self (VInt 0)
  otherNeg <- richCompare CmpLt other (VInt 0)
  a <- pyAbs dividend
  b <- pyAbs divisor
  q <- numberOp OpFloorDiv a b
  let sign = (if selfNeg then -1 else 1) * (if otherNeg then -1 else 1)
  r <- numberOp OpMul (PInt sign) q
  intTypeNew r

uintTypeMethod :: NumOp -> Value -> Value -> Either Exc Value
uintTypeMethod op self other = case op of
  OpTrueDiv -> cImpl KLong OpFloorDiv self other >>= uintTypeOfResult
  _ -> cImpl KLong op self other >>= uintTypeOfResult

uintTypeReflected :: NumOp -> Value -> Value -> Either Exc Value
uintTypeReflected op self other = case op of
  OpTrueDiv -> cImpl KLong OpFloorDiv other self >>= uintTypeOfResult
  _ -> cImpl KLong op other self >>= uintTypeOfResult

-- | The builtin types' C number functions.
cImpl :: CKind -> NumOp -> Value -> Value -> Either Exc (Maybe Value)
cImpl kind op v w = case kind of
  KLong -> case (asInteger v, asInteger w) of
    (Just a, Just b) -> Just <$> longOp op a b
    _ -> Right Nothing
  KFloat -> case floatOperand v of
    Nothing -> Right Nothing
    Just ea -> do
      a <- ea
      case floatOperand w of
        Nothing -> Right Nothing
        Just eb -> do
          b <- eb
          Just <$> floatOp op a b
  KDelta -> deltaOp op v w
  KDatetime -> datetimeOp op v w
  KStrMod -> case asText v of
    Just fmt -> Just <$> strFormat v fmt w
    Nothing -> Right Nothing
  KBytesMod -> case asBytes v of
    Just fmt -> Just <$> bytesFormat fmt w
    Nothing -> Right Nothing

floatOperand :: Value -> Maybe (Either Exc Double)
floatOperand v = case asDouble v of
  Just d -> Just (Right d)
  Nothing -> intToDouble <$> asInteger v

zeroDivision :: Either Exc a
zeroDivision = Left (pyExc ZeroDivisionError "division by zero")

longOp :: NumOp -> Integer -> Integer -> Either Exc Value
longOp op a b = case op of
  OpAdd -> Right (PInt (a + b))
  OpSub -> Right (PInt (a - b))
  OpMul -> Right (PInt (a * b))
  OpTrueDiv
    | b == 0 -> zeroDivision
    | a == 0 -> Right (PFloat (if b < 0 then -0.0 else 0.0))
    | otherwise ->
        let d = fromRational (a % b) :: Double
         in if isInfinite d
              then Left (pyExc OverflowError "integer division result too large for a float")
              else Right (PFloat d)
  OpFloorDiv
    | b == 0 -> zeroDivision
    | otherwise -> Right (PInt (a `div` b))
  OpMod
    | b == 0 -> zeroDivision
    | otherwise -> Right (PInt (a `mod` b))

floatOp :: NumOp -> Double -> Double -> Either Exc Value
floatOp op a b = case op of
  OpAdd -> Right (PFloat (a + b))
  OpSub -> Right (PFloat (a - b))
  OpMul -> Right (PFloat (a * b))
  OpTrueDiv
    | b == 0 -> zeroDivision
    | otherwise -> Right (PFloat (a / b))
  OpFloorDiv
    | b == 0 -> zeroDivision
    | otherwise -> Right (PFloat (floatFloorDiv a b))
  OpMod
    | b == 0 -> zeroDivision
    | otherwise -> Right (PFloat (floatMod a b))

-- | @float.as_integer_ratio()@.
integerRatio :: Double -> Either Exc Rational
integerRatio d
  | isNaN d = Left (valueErr "cannot convert NaN to integer ratio")
  | isInfinite d = Left (pyExc OverflowError "cannot convert Infinity to integer ratio")
  | otherwise = Right (toRational d)

deltaValue :: Either PyErr Timedelta -> Either Exc (Maybe Value)
deltaValue = fmap (Just . PTimedelta) . liftPy

deltaOp :: NumOp -> Value -> Value -> Either Exc (Maybe Value)
deltaOp op v w = case op of
  OpAdd
    | Just (Timedelta a) <- asDelta v, Just (Timedelta b) <- asDelta w -> deltaValue (checkTimedelta (a + b))
  OpSub
    | Just (Timedelta a) <- asDelta v, Just (Timedelta b) <- asDelta w -> deltaValue (checkTimedelta (a - b))
  OpMul
    | Just d <- asDelta v -> scaled d w
    | Just d <- asDelta w -> scaled d v
  OpTrueDiv
    | Just d@(Timedelta a) <- asDelta v -> case w of
        _
          | Just (Timedelta b) <- asDelta w ->
              if b == 0 then zeroDivision else Right (Just (PFloat (fromRational (a % b))))
          | Just n <- asInteger w -> deltaValue (timedeltaDivInteger d n)
          | Just f <- asDouble w -> do
              r <- integerRatio f
              if r == 0 then zeroDivision else deltaValue (timedeltaMulRational d (recip r))
          | otherwise -> Right Nothing
  OpFloorDiv
    | Just (Timedelta a) <- asDelta v -> case w of
        _
          | Just (Timedelta b) <- asDelta w -> if b == 0 then zeroDivision else Right (Just (PInt (a `div` b)))
          | Just n <- asInteger w -> if n == 0 then zeroDivision else deltaValue (checkTimedelta (a `div` n))
          | otherwise -> Right Nothing
  OpMod
    | Just (Timedelta a) <- asDelta v, Just (Timedelta b) <- asDelta w ->
        if b == 0 then zeroDivision else deltaValue (checkTimedelta (a `mod` b))
  _ -> Right Nothing
  where
    scaled d@(Timedelta a) factor
      | Just n <- asInteger factor = deltaValue (checkTimedelta (a * n))
      | Just f <- asDouble factor = integerRatio f >>= deltaValue . timedeltaMulRational d
      | otherwise = Right Nothing

datetimeOp :: NumOp -> Value -> Value -> Either Exc (Maybe Value)
datetimeOp op v w = case (op, v, w) of
  (OpAdd, VTimestamp dt, _) | Just td <- asDelta w -> added dt td
  (OpAdd, _, VTimestamp dt) | Just td <- asDelta v -> added dt td
  (OpSub, VTimestamp a, VTimestamp b) -> Just . PTimedelta <$> liftPy (datetimeDiff a b)
  (OpSub, VTimestamp a, _) | Just (Timedelta td) <- asDelta w -> added a (Timedelta (negate td))
  _ -> Right Nothing
  where
    added dt td = Just . VTimestamp <$> liftPy (datetimeAdd dt td)

-- | @str % arg@ (@PyUnicode_Format@) for a single, non-tuple argument.
strFormat :: Value -> Text -> Value -> Either Exc Value
strFormat original fmt arg
  -- CPython's writer hands back the format object itself when it is copied
  -- whole (no conversion), and the empty-string singleton when nothing is
  -- written.
  | T.null fmt = if isDict then Right (PStr "") else Left notAllConverted
  | not (T.any (== '%') fmt) =
      if isDict then Right original else Left notAllConverted
  | otherwise = do
      (out, consumed) <- go (T.unpack fmt) 0 False []
      unless (consumed || isDict) (Left notAllConverted)
      Right (PStr (T.pack (concat (reverse out))))
  where
    isDict = isMappingLike arg && not (isText arg)
    notAllConverted = typeErr "not all arguments converted during string formatting"
    go :: String -> Int -> Bool -> [String] -> Either Exc ([String], Bool)
    go s i consumed acc = case s of
      [] -> Right (acc, consumed)
      '%' : rest -> case rest of
        [] -> Left (valueErr "incomplete format")
        '%' : rest' -> go rest' (i + 2) consumed ("%" : acc)
        c : rest' -> do
          when consumed (Left (typeErr "not enough arguments for format string"))
          piece <- convert c (i + 1)
          go rest' (i + 2) True (piece : acc)
      c : rest -> go rest (i + 1) consumed ([c] : acc)
    convert c index = case c of
      's' -> Right (T.unpack (valueStr arg))
      'r' -> Right (T.unpack (valueRepr arg))
      _
        | c `elem` ("diu" :: String) -> case asInteger arg of
            Just n -> Right (show n)
            Nothing -> case asDouble arg of
              Just d -> show <$> truncDouble d
              Nothing -> Left (typeErr ("%" <> T.singleton c <> " format: a real number is required, not " <> tpName arg))
        | otherwise ->
            Left
              ( valueErr
                  ( "unsupported format character " <> quoted (T.singleton c) <> " (0x" <> T.pack (showHex (ord c) "")
                      <> ") at index "
                      <> T.pack (show (index :: Int))
                  )
              )

-- | @bytes % arg@ for a single, non-tuple argument.
bytesFormat :: ByteString -> Value -> Either Exc Value
bytesFormat fmt arg = do
  (out, consumed) <- go (BS.unpack fmt) 0 False []
  unless (consumed || isDict) (Left (typeErr "not all arguments converted during bytes formatting"))
  Right (PBytes (BS.concat (reverse out)))
  where
    isDict = isMappingLike arg && not (isText arg) && not (isJust (asBytes arg))
    go :: [Word8] -> Int -> Bool -> [ByteString] -> Either Exc ([ByteString], Bool)
    go s i consumed acc = case s of
      [] -> Right (acc, consumed)
      37 : rest -> case rest of
        [] -> Left (valueErr "incomplete format")
        37 : rest' -> go rest' (i + 2) consumed ("%" : acc)
        c : rest' -> do
          when consumed (Left (typeErr "not enough arguments for format string"))
          piece <- convert (chr (fromIntegral c)) (i + 1)
          go rest' (i + 2) True (piece : acc)
      c : rest -> go rest (i + 1) consumed (BS.singleton c : acc)
    convert c index = case c of
      _
        | c == 's' || c == 'b' -> case asBytes arg of
            Just b -> Right b
            Nothing ->
              Left
                ( typeErr
                    ( "%" <> T.singleton c <> " requires a bytes-like object, or an object that implements __bytes__, not "
                        <> quoted (tpName arg)
                    )
                )
        | c `elem` ("diu" :: String) -> case asInteger arg of
            Just n -> Right (TE.encodeUtf8 (T.pack (show n)))
            Nothing -> case asDouble arg of
              Just d -> TE.encodeUtf8 . T.pack . show <$> truncDouble d
              Nothing -> Left (typeErr ("%" <> T.singleton c <> " format: a real number is required, not " <> tpName arg))
        | otherwise ->
            Left
              ( valueErr
                  ( "unsupported format character " <> quoted (T.singleton c) <> " (0x" <> T.pack (showHex (ord c) "")
                      <> ") at index "
                      <> T.pack (show (index :: Int))
                  )
              )

-- | The @sq_concat@ slot of the left operand.
sqConcat :: Value -> Maybe (Value -> Either Exc Value)
sqConcat v
  | Just t <- asText v = Just $ \w -> case asText w of
      Just u -> Right (PStr (t <> u))
      Nothing -> Left (typeErr ("can only concatenate str (not \"" <> tpName w <> "\") to str"))
  | Just b <- asBytes v = Just $ \w -> case asBytes w of
      Just c -> Right (PBytes (b <> c))
      Nothing -> Left (typeErr ("can't concat " <> tpName w <> " to " <> tpName v))
  | Just xs <- asList v = Just $ \w -> case asList w of
      Just ys -> Right (PList (xs <> ys))
      Nothing -> Left (typeErr ("can only concatenate list (not \"" <> tpName w <> "\") to list"))
  | otherwise = Nothing

isSequence :: Value -> Bool
isSequence v = isText v || isJust (asBytes v) || isJust (asList v)

-- | @sequence_repeat@: the count must be an index.
sequenceRepeat :: Value -> Value -> Either Exc Value
sequenceRepeat sq n = case asInteger n of
  Nothing -> Left (typeErr ("can't multiply sequence by non-int of type " <> quoted (tpName n)))
  Just c
    | c > maxSsize || c < negate maxSsize - 1 -> Left (pyExc OverflowError "cannot fit 'int' into an index-sized integer")
    | otherwise -> do
        let k = max 0 c
            size l = fromIntegral l * k
            tooBig l = size l > 2 ^ (31 :: Int)
        case () of
          _
            | Just t <- asText sq ->
                if tooBig (T.length t) then Left (pyExc MemoryError "") else Right (PStr (T.replicate (fromInteger k) t))
            | Just b <- asBytes sq ->
                if tooBig (BS.length b) then Left (pyExc MemoryError "") else Right (PBytes (BS.concat (replicate (fromInteger k) b)))
            | Just xs <- asList sq ->
                if tooBig (length xs) then Left (pyExc MemoryError "") else Right (PList (concat (replicate (fromInteger k) xs)))
            | otherwise -> Left (typeErr ("can't multiply sequence by non-int of type " <> quoted (tpName n)))

-- | @operator.neg@.
negative :: Value -> Either Exc Value
negative v = case v of
  PInt n -> Right (PInt (negate n))
  VBool _ -> Left (typeErr "no such overload")
  VInt n -> VInt <$> checkInt64 (negate n)
  VUint _ -> Left (typeErr "no such overload")
  PFloat d -> Right (PFloat (negate d))
  VDouble d -> Right (VDouble (negate d))
  PTimedelta (Timedelta us) -> PTimedelta <$> liftPy (checkTimedelta (negate us))
  VDuration (Timedelta us) -> PTimedelta <$> liftPy (checkTimedelta (negate us))
  VError _ -> Right v
  _ -> Left (typeErr ("bad operand type for unary -: " <> quoted (tpName v)))

-- | @abs()@.
pyAbs :: Value -> Either Exc Value
pyAbs v
  | Just n <- asInteger v = Right (PInt (abs n))
  | Just d <- asDouble v = Right (PFloat (abs d))
  | Just (Timedelta us) <- asDelta v = PTimedelta <$> liftPy (checkTimedelta (abs us))
  | otherwise = Left (typeErr ("bad operand type for abs(): " <> quoted (tpName v)))

-- ---------------------------------------------------------------------------
-- Comparison

-- | The rich comparison operators.
data CmpOp = CmpLt | CmpLe | CmpEq | CmpNe | CmpGt | CmpGe
  deriving stock (Eq, Show)

swapped :: CmpOp -> CmpOp
swapped = \case
  CmpLt -> CmpGt
  CmpLe -> CmpGe
  CmpGt -> CmpLt
  CmpGe -> CmpLe
  op -> op

cmpSymbol :: CmpOp -> Text
cmpSymbol = \case
  CmpLt -> "<"
  CmpLe -> "<="
  CmpEq -> "=="
  CmpNe -> "!="
  CmpGt -> ">"
  CmpGe -> ">="

cmpOrd :: (Ord a) => CmpOp -> a -> a -> Bool
cmpOrd op a b = case op of
  CmpLt -> a < b
  CmpLe -> a <= b
  CmpEq -> a == b
  CmpNe -> a /= b
  CmpGt -> a > b
  CmpGe -> a >= b

isOrdering :: CmpOp -> Bool
isOrdering op = op /= CmpEq && op /= CmpNe

-- | @PyObject_RichCompare@ followed by truthiness (every comparison method
-- reachable from CEL returns a @bool@).
richCompare :: CmpOp -> Value -> Value -> Either Exc Bool
richCompare op v w = do
  let tv = pyType v
      tw = pyType w
      reverseFirst = tv /= tw && isSubclass tw tv
  r1 <- if reverseFirst then typeRichcmp tw (swapped op) w v else Right Nothing
  case r1 of
    Just b -> Right b
    Nothing ->
      typeRichcmp tv op v w >>= \case
        Just b -> Right b
        Nothing -> do
          r3 <- if reverseFirst then Right Nothing else typeRichcmp tw (swapped op) w v
          case r3 of
            Just b -> Right b
            Nothing -> case op of
              CmpEq -> Right (identical v w)
              CmpNe -> Right (not (identical v w))
              _ ->
                Left
                  ( typeErr
                      ( quoted (cmpSymbol op) <> " not supported between instances of " <> quoted (tpName v) <> " and "
                          <> quoted (tpName w)
                      )
                  )

-- | Object identity, for the objects that compare by it (singletons,
-- classes, functions).
identical :: Value -> Value -> Bool
identical a b = case (a, b) of
  (VNone, VNone) -> True
  (VClass x, VClass y) -> x == y
  (VFunction x, VFunction y) -> x == y
  _ -> False

-- | A class's @tp_richcompare@ (its methods resolved through the MRO);
-- 'Nothing' is @NotImplemented@.
typeRichcmp :: PyClass -> CmpOp -> Value -> Value -> Either Exc (Maybe Bool)
typeRichcmp cls op self other = case cls of
  CInt -> Right (longCmp op self other)
  CBoolType -> Right (longCmp op self other)
  CIntType -> typeMatched self other >> Right (longCmp op self other)
  CUintType -> do
    unless (isOrdering op) (typeMatched self other)
    Right (longCmp op self other)
  CFloat -> Right (floatCmp op self other)
  CDoubleType -> do
    unless (isOrdering op) (typeMatched self other)
    Right (floatCmp op self other)
  CStr -> Right (ordCmp asText op self other)
  CStringType -> Right (ordCmp asText op self other)
  CBytes -> Right (ordCmp asBytes op self other)
  CBytesType -> Right (ordCmp asBytes op self other)
  CTimedelta -> Right (ordCmp asDelta op self other)
  CDurationType -> Right (ordCmp asDelta op self other)
  CDatetime -> Right (ordCmp asUtc op self other)
  CTimestampType -> Right (ordCmp asUtc op self other)
  CList -> listCmp op self other
  CListType -> case op of
    CmpEq -> Just <$> listTypeEq self other
    CmpNe -> Just <$> listTypeNe self other
    _ -> Left (typeErr "no such overload")
  CDict -> dictCmp op self other
  CNameContainer -> dictCmp op self other
  CMapType -> mapTypeCmp op self other
  CMessageType -> mapTypeCmp op self other
  CReferent -> objectCmp referentEq op self other
  CCELEvalError -> objectCmp errorEq op self other
  _ -> objectCmp (\_ _ -> Right Nothing) op self other
  where
    asUtc = \case
      VTimestamp dt -> Just (datetimeUtcMicros dt)
      _ -> Nothing

-- | @object.__eq__@ / @__ne__@ for a class with an optional custom
-- @__eq__@: equality by the method (or identity), @!=@ as its inverse.
objectCmp :: (Value -> Value -> Either Exc (Maybe Bool)) -> CmpOp -> Value -> Value -> Either Exc (Maybe Bool)
objectCmp customEq op self other = case op of
  CmpEq -> eqOf
  CmpNe -> fmap not <$> eqOf
  _ -> Right Nothing
  where
    eqOf =
      customEq self other >>= \case
        Just b -> Right (Just b)
        Nothing -> Right (if identical self other then Just True else Nothing)

referentEq :: Value -> Value -> Either Exc (Maybe Bool)
referentEq a b = case (a, b) of
  (VReferent x, VReferent y) -> Just <$> referentsEqual x y
  _ -> Right Nothing

referentsEqual :: Referent -> Referent -> Either Exc Bool
referentsEqual x y
  | referentAnnotation x /= referentAnnotation y = Right False
  | otherwise = do
      containers <- case (referentContainer x, referentContainer y) of
        (Nothing, Nothing) -> Right True
        (Just c, Just d) -> richCompare CmpEq (VContainer c) (VContainer d)
        (Just c, Nothing) -> richCompare CmpEq (VContainer c) VNone
        (Nothing, Just d) -> richCompare CmpEq VNone (VContainer d)
      if not containers
        then Right False
        else case (referentSetValue x, referentSetValue y) of
          (Nothing, Nothing) -> Right True
          (Just p, Just q) -> richCompare CmpEq p q
          _ -> Right False

errorEq :: Value -> Value -> Either Exc (Maybe Bool)
errorEq a b = case (a, b) of
  (VError x, VError y) -> Right (Just (x == y))
  _ -> Right Nothing

-- | @type_matched@: the operands' classes must be related.
typeMatched :: Value -> Value -> Either Exc ()
typeMatched self other =
  let ts = pyType self
      to = pyType other
   in if isSubclass to ts || isSubclass ts to
        then Right ()
        else
          Left
            ( typeErr
                ( "no such overload: " <> valueRepr self <> " " <> classRepr ts <> " != " <> valueRepr other <> " "
                    <> classRepr to
                )
            )

longCmp :: CmpOp -> Value -> Value -> Maybe Bool
longCmp op self other = cmpOrd op <$> asInteger self <*> asInteger other

ordCmp :: (Ord a) => (Value -> Maybe a) -> CmpOp -> Value -> Value -> Maybe Bool
ordCmp view op self other = cmpOrd op <$> view self <*> view other

floatCmp :: CmpOp -> Value -> Value -> Maybe Bool
floatCmp op self other = do
  a <- asDouble self
  case (asDouble other, asInteger other) of
    (Just b, _) -> Just (ieee a b)
    (_, Just n) -> Just (withInt a n)
    _ -> Nothing
  where
    ieee a b = case op of
      CmpLt -> a < b
      CmpLe -> a <= b
      CmpEq -> a == b
      CmpNe -> a /= b
      CmpGt -> a > b
      CmpGe -> a >= b
    withInt a n
      | isNaN a = op == CmpNe
      | isInfinite a = cmpOrd op (if a > 0 then 1 else -1 :: Int) 0
      | otherwise = cmpOrd op (toRational a) (fromInteger n)

-- | @list_richcompare@.
listCmp :: CmpOp -> Value -> Value -> Either Exc (Maybe Bool)
listCmp op self other = case (asList self, asList other) of
  (Just xs, Just ys)
    | length xs /= length ys && not (isOrdering op) -> Right (Just (op == CmpNe))
    | otherwise ->
        firstDifference xs ys >>= \case
          Nothing -> Right (Just (cmpOrd op (length xs) (length ys)))
          Just (a, b) -> case op of
            CmpEq -> Right (Just False)
            CmpNe -> Right (Just True)
            _ -> Just <$> richCompare op a b
  _ -> Right Nothing
  where
    firstDifference (a : as) (b : bs) =
      richCompare CmpEq a b >>= \case
        True -> firstDifference as bs
        False -> Right (Just (a, b))
    firstDifference _ _ = Right Nothing

-- | @dict_richcompare@.
dictCmp :: CmpOp -> Value -> Value -> Either Exc (Maybe Bool)
dictCmp op self other = case (asDict self, asDict other) of
  (Just a, Just b)
    | not (isOrdering op) -> do
        eq <- dictEqual a b
        Right (Just (if op == CmpEq then eq else not eq))
  _ -> Right Nothing

dictEqual :: Entries -> Entries -> Either Exc Bool
dictEqual a b
  | length a /= length b = Right False
  | otherwise = go a
  where
    go [] = Right True
    go ((k, av) : rest) =
      dictLookup b k >>= \case
        Nothing -> Right False
        Just bv ->
          richCompare CmpEq av bv >>= \case
            True -> go rest
            False -> Right False

-- | A @BoolType@ or a caught @TypeError@, as @ListType@/@MapType@ equality
-- fold them with @logical_and@/@logical_or@.
data Truth = TBool Bool | TErr Exc

truthRepr :: Truth -> (Text, Text)
truthRepr = \case
  TBool b -> (classRepr CBoolType, valueRepr (boolType b))
  TErr e -> ("<class 'TypeError'>", excRepr e)

foldTruth :: Bool -> [Either Exc Truth] -> Either Exc Truth
foldTruth isAnd = go (TBool isAnd)
  where
    go acc [] = Right acc
    go acc (item : rest) = do
      y <- item
      acc' <- combine acc y
      go acc' rest
    combine x y = case (x, y) of
      (TErr _, TErr _) ->
        let (tx, rx) = truthRepr x
            (ty, ry) = truthRepr y
         in Left (typeErr (tx <> " " <> rx <> (if isAnd then " and " else " or ") <> ty <> " " <> ry))
      (TErr _, TBool b) -> Right (if b == isAnd then x else y)
      (TBool a, TErr _) -> Right (if a == isAnd then y else x)
      (TBool a, TBool b) -> Right (TBool (if isAnd then a && b else a || b))

-- | @BoolType(s == o)@, or the @TypeError@ it raised.
caught :: Either Exc Bool -> Either Exc Truth
caught = \case
  Right b -> Right (TBool b)
  Left e | isExcClass TypeError e -> Right (TErr e)
  Left e -> Left e

settle :: Either Exc Truth -> Either Exc Bool
settle = \case
  Left e -> Left e
  Right (TErr e) -> Left e
  Right (TBool b) -> Right b

listTypeEq :: Value -> Value -> Either Exc Bool
listTypeEq self other = case (self, asList other) of
  (_, _) | VNone <- other -> Right False
  (VList xs, Just ys)
    | length xs /= length ys -> Right False
    | otherwise -> settle (foldTruth True [caught (richCompare CmpEq a b) | (a, b) <- zip xs ys])
  _ -> Left (typeErr ("no such overload: ListType == " <> classRepr (pyType other)))

listTypeNe :: Value -> Value -> Either Exc Bool
listTypeNe self other = case (self, asList other) of
  (VList xs, Just ys)
    | length xs /= length ys -> Right True
    | otherwise -> settle (foldTruth False [caught (richCompare CmpNe a b) | (a, b) <- zip xs ys])
  _ -> Left (typeErr ("no such overload: ListType != " <> classRepr (pyType other)))

-- | @MapType.__eq__@ / @__ne__@ (ordering falls back to @dict@'s).
mapTypeCmp :: CmpOp -> Value -> Value -> Either Exc (Maybe Bool)
mapTypeCmp op self other = case op of
  CmpEq -> case other of
    VNone -> Right (Just False)
    _ -> Just <$> withMapping "==" (\a b -> keysEqual a b >>= \same -> if same then values True a b else Right False)
  CmpNe -> Just <$> withMapping "!=" ne
  _ -> Right Nothing
  where
    withMapping symbol k = case (asDict self, asDict other) of
      (Just a, Just b) -> k a b
      _ -> Left (typeErr ("no such overload: MapType " <> symbol <> " " <> classRepr (pyType other)))
    keysEqual a b
      | length a /= length b = Right False
      | otherwise = allContained a b
    allContained [] _ = Right True
    allContained ((k, _) : rest) b =
      dictContains b k >>= \case
        True -> allContained rest b
        False -> Right False
    values isEq a _ =
      settle
        ( foldTruth
            isEq
            [ do
                s <- mapTypeGetItem a k
                o <- getItem other k
                caught (richCompare (if isEq then CmpEq else CmpNe) s o)
            | (k, _) <- a
            ]
        )
    ne a b
      | length a == 1 && length b == 1 = do
          same <- keysEqual a b
          if same
            then case a of
              [(k, _)] -> do
                s <- mapTypeGetItem a k
                o <- getItem other k
                richCompare CmpNe s o
              _ -> Right False
            else Right True
      | otherwise = do
          same <- keysEqual a b
          if not same then Right True else values False a b

-- ---------------------------------------------------------------------------
-- Logic

isBoolType :: Value -> Bool
isBoolType = \case
  VBool _ -> True
  _ -> False

typeDescription :: Value -> Text
typeDescription v = classRepr (pyType v) <> " " <> valueRepr v

-- | @celtypes.logical_not@.
logicalNot :: Value -> Either Exc Value
logicalNot v = case v of
  VError _ -> Right v
  VBool n -> Right (boolType (n == 0))
  _ -> Left (typeErr ("not " <> classRepr (pyType v)))

-- | @celtypes.logical_and@: commutative over errors and non-booleans.
logicalAnd :: Value -> Value -> Either Exc Value
logicalAnd x y = case (isBoolType x, isBoolType y) of
  (False, False) -> Left (typeErr (typeDescription x <> " and " <> typeDescription y))
  (False, True) -> Right (if truthy y then x else y)
  (True, False) -> Right (if truthy x then y else x)
  (True, True) -> Right (if truthy x then y else x)

-- | @celtypes.logical_or@.
logicalOr :: Value -> Value -> Either Exc Value
logicalOr x y = case (isBoolType x, isBoolType y) of
  (False, False) -> Left (typeErr (typeDescription x <> " or " <> typeDescription y))
  (False, True) -> Right (if truthy y then y else x)
  (True, False) -> Right (if truthy x then x else y)
  (True, True) -> Right (if truthy x then x else y)

-- | @celtypes.logical_condition@.
logicalCondition :: Value -> Value -> Value -> Either Exc Value
logicalCondition e x y
  | isBoolType e = Right (if truthy e then x else y)
  | otherwise =
      Left
        (typeErr ("Unexpected " <> classRepr (pyType e) <> " ? " <> classRepr (pyType x) <> " : " <> classRepr (pyType y)))

-- ---------------------------------------------------------------------------
-- Containers

-- | @len()@.
pyLen :: Value -> Either Exc Integer
pyLen v
  | Just t <- asText v = Right (fromIntegral (T.length t))
  | Just b <- asBytes v = Right (fromIntegral (BS.length b))
  | Just xs <- asList v = Right (fromIntegral (length xs))
  | Just kvs <- asDict v = Right (fromIntegral (length kvs))
  | otherwise = Left (typeErr ("object of type " <> quoted (tpName v) <> " has no len()"))

-- | @iter()@, fully consumed: list items, dict keys, a string's characters
-- (plain @str@), a bytes object's values (plain @int@).
pyIter :: Value -> Either Exc [Value]
pyIter v
  | Just xs <- asList v = Right xs
  | Just kvs <- asDict v = Right (map fst kvs)
  | Just t <- asText v = Right (map (PStr . T.singleton) (T.unpack t))
  | Just b <- asBytes v = Right (map (PInt . fromIntegral) (BS.unpack b))
  | otherwise = Left (typeErr (quoted (tpName v) <> " object is not iterable"))

-- | A dictionary lookup: hash, then compare each same-hash key (in
-- insertion order) with @stored == key@.
dictLookup :: Entries -> Value -> Either Exc (Maybe Value)
dictLookup entries key = case key of
  VString t -> Right (textLookup t)
  PStr t -> Right (textLookup t)
  _ -> case hashKey key of
    Nothing -> Left (unhashable key)
    Just h -> go [(k, v) | (k, v) <- entries, hashKey k == Just h]
  where
    textLookup t = case [v | (k, v) <- entries, Just u <- [asText k], u == t] of
      v : _ -> Just v
      [] -> Nothing
    go [] = Right Nothing
    go ((k, v) : rest) =
      richCompare CmpEq k key >>= \case
        True -> Right (Just v)
        False -> go rest

-- | @key in dict@.
dictContains :: Entries -> Value -> Either Exc Bool
dictContains entries key = isJust <$> dictLookup entries key

-- | @dict[key] = value@ (an existing equal key keeps its identity).
dictSet :: Entries -> Value -> Value -> Either Exc Entries
dictSet entries key value = case hashKey key of
  Nothing -> Left (unhashable key)
  Just h -> go entries
    where
      go [] = Right [(key, value)]
      go ((k, v) : rest)
        | hashKey k == Just h =
            richCompare CmpEq k key >>= \case
              True -> Right ((k, value) : rest)
              False -> ((k, v) :) <$> go rest
        | otherwise = ((k, v) :) <$> go rest

-- | @MapType.__getitem__@: the key type check, then the dict lookup.
mapTypeGetItem :: Entries -> Value -> Either Exc Value
mapTypeGetItem entries key
  | validKeyType key =
      dictLookup entries key >>= \case
        Just v -> Right v
        Nothing -> Left (keyError key)
  | otherwise = Left (typeErr ("unsupported key type: " <> classRepr (pyType key)))
  where
    validKeyType = \case
      VInt _ -> True
      VUint _ -> True
      VBool _ -> True
      VString _ -> True
      PStr _ -> True
      _ -> False

-- | @operator.getitem@.
getItem :: Value -> Value -> Either Exc Value
getItem obj key = case obj of
  VMap kvs -> mapTypeGetItem kvs key
  VMessage kvs -> mapTypeGetItem kvs key
  VContainer c ->
    dictLookup (containerEntries c) key >>= \case
      Just v -> Right v
      Nothing -> Left (keyError key)
  _
    | Just xs <- asList obj -> indexed "list indices must be integers or slices, not " False "list index out of range" xs id
    | Just t <- asText obj ->
        indexed "string indices must be integers, not " True "string index out of range" (T.unpack t) (PStr . T.singleton)
    | Just b <- asBytes obj ->
        indexed "byte indices must be integers or slices, not " False "index out of range" (BS.unpack b) (PInt . fromIntegral)
    | VClass cls <- obj -> Left (typeErr ("type " <> quoted (className cls) <> " is not subscriptable"))
    | otherwise -> Left (typeErr (quoted (tpName obj) <> " object is not subscriptable"))
  where
    indexed :: Text -> Bool -> Text -> [a] -> (a -> Value) -> Either Exc Value
    indexed typeMessage quote rangeMessage items wrap = case asInteger key of
      Nothing -> Left (typeErr (typeMessage <> (if quote then quoted else id) (tpName key)))
      Just i
        | i > maxSsize || i < negate maxSsize - 1 -> Left (pyExc IndexError "cannot fit 'int' into an index-sized integer")
        | otherwise ->
            let n = fromIntegral (length items)
                j = if i < 0 then i + n else i
             in if j < 0 || j >= n then Left (pyExc IndexError rangeMessage) else Right (wrap (items !! fromInteger j))

-- | cel-python's @operator_in@: errors pass through, a @TypeError@ from an
-- element comparison is remembered as a @CELEvalError@ while the scan goes
-- on.
operatorIn :: Value -> Value -> Either Exc Value
operatorIn item container = case (item, container) of
  (VError _, _) -> Right item
  (_, VError _) -> Right container
  _ -> pyIter container >>= go (boolType False)
  where
    go acc [] = Right acc
    go acc (c : cs) = case richCompare CmpEq c item of
      Right True -> Right (boolType True)
      Right False -> go acc cs
      Left e
        | isExcClass TypeError e -> go (VError (celError "no such overload" e Nothing)) cs
        | otherwise -> Left e

-- ---------------------------------------------------------------------------
-- Calls

-- | The names cel-python's function table binds that are identifiers:
-- the operators aside, only @_in_@ (@operator_in@) spells as one.
resolveFunction :: Text -> Maybe Value
resolveFunction name = case name of
  "_in_" -> Just (VFunction "operator_in")
  "size" -> fn
  "contains" -> fn
  "type" -> cls CTypeType
  "endsWith" -> fn
  "startsWith" -> fn
  "matches" -> fn
  "getDate" -> fn
  "getDayOfMonth" -> fn
  "getDayOfWeek" -> fn
  "getDayOfYear" -> fn
  "getFullYear" -> fn
  "getMonth" -> fn
  "getHours" -> fn
  "getMilliseconds" -> fn
  "getMinutes" -> fn
  "getSeconds" -> fn
  "bool" -> cls CBoolType
  "bytes" -> cls CBytesType
  "double" -> cls CDoubleType
  "duration" -> cls CDurationType
  "int" -> cls CIntType
  "list" -> cls CListType
  "map" -> cls CMapType
  "null_type" -> cls CNoneType
  "string" -> cls CStringType
  "timestamp" -> cls CTimestampType
  "uint" -> cls CUintType
  _ -> Nothing
  where
    fn = Just (VFunction ("function_" <> name))
    cls = Just . VClass

-- | @celtypes.TypeType(x)@ (Python's @type()@ for a non-class).
typeOf :: Value -> Value
typeOf = \case
  VClass _ -> VClass CTypeType
  v -> VClass (pyType v)

-- | Call a Python object with positional arguments.
callValue :: Value -> [Value] -> Either Exc Value
callValue f args = case f of
  VFunction name -> callFunction name args
  VClass cls -> callClass cls args
  VError _ -> Right f
  _ -> Left (typeErr (quoted (tpName f) <> " object is not callable"))

-- | Python's positional argument-count errors for a function with the
-- given parameters, of which the first @required@ have no default.
checkArity :: Text -> [Text] -> Int -> [Value] -> Either Exc ()
checkArity name params required args
  | given < required =
      let missing = drop given (take required params)
          count = length missing
       in Left
            ( typeErr
                ( name <> "() missing " <> T.pack (show count) <> " required positional argument" <> plural count <> ": "
                    <> joinNames (map quoted missing)
                )
            )
  | given > total =
      let takes =
            if required == total
              then T.pack (show total) <> " positional argument" <> plural total
              else "from " <> T.pack (show required) <> " to " <> T.pack (show total) <> " positional arguments"
       in Left
            ( typeErr
                (name <> "() takes " <> takes <> " but " <> T.pack (show given) <> (if given == 1 then " was" else " were") <> " given")
            )
  | otherwise = Right ()
  where
    given = length args
    total = length params
    plural n = if n == 1 then "" else "s"
    joinNames = \case
      [a] -> a
      [a, b] -> a <> " and " <> b
      xs -> T.intercalate ", " (init xs) <> ", and " <> last xs

-- | Arity of a @__new__(cls, ...)@ method: counts include @cls@.
checkNewArity :: Text -> [Text] -> Int -> [Value] -> Either Exc ()
checkNewArity name params required args =
  case checkArity name ("cls" : params) (required + 1) (VNone : args) of
    Left _ | length args < required -> checkArity name params required args
    r -> r

callFunction :: Text -> [Value] -> Either Exc Value
callFunction name args = case name of
  "operator_in" -> withArgs ["item", "container"] 2 $ \case
    [item, container] -> operatorIn item container
    _ -> Right VNone
  "function_size" -> withArgs ["container"] 1 $ \case
    [VNone] -> Right (VInt 0)
    [c] -> VInt <$> pyLen c
    _ -> Right VNone
  "function_contains" -> withArgs ["container", "item"] 2 $ \case
    [c, item] -> containsMethod c item
    _ -> Right VNone
  "function_startsWith" -> withArgs ["string", "fragment"] 2 $ \case
    [s, f] -> affix True s f
    _ -> Right VNone
  "function_endsWith" -> withArgs ["string", "fragment"] 2 $ \case
    [s, f] -> affix False s f
    _ -> Right VNone
  "function_matches" -> withArgs ["text", "pattern"] 2 $ \case
    [t, p] -> matches t p
    _ -> Right VNone
  _ | Just getter <- T.stripPrefix "function_" name -> withArgs ["ts", "tz_name"] 1 $ \case
    [ts] -> timeGetter getter ts Nothing
    [ts, tz] -> timeGetter getter ts (Just tz)
    _ -> Right VNone
  _ -> Left (typeErr ("unknown function " <> name))
  where
    withArgs params required k = checkArity name params required args >> k args

-- | The @contains@ method of the @celtypes@ containers.
containsMethod :: Value -> Value -> Either Exc Value
containsMethod container item = case container of
  VList xs -> boolType <$> anyM (\x -> richCompare CmpEq x item) xs
  VMap kvs -> boolType <$> dictContains kvs item
  VMessage kvs -> boolType <$> dictContains kvs item
  VString t -> case asText item of
    Just u -> Right (boolType (u `T.isInfixOf` t))
    Nothing -> Left (typeErr ("'in <string>' requires string as left operand, not " <> tpName item))
  VBytes b
    | Just n <- asInteger item ->
        if n < 0 || n > 255
          then Left (valueErr "byte must be in range(0, 256)")
          else Right (boolType (BS.elem (fromInteger n) b))
    | Just c <- asBytes item -> Right (boolType (c `BS.isInfixOf` b))
    | otherwise -> Left (typeErr ("a bytes-like object is required, not " <> quoted (tpName item)))
  _ -> Left (pyExc AttributeError (quoted (tpName container) <> " object has no attribute 'contains'"))
  where
    anyM _ [] = Right False
    anyM p (x : xs) = p x >>= \b -> if b then Right True else anyM p xs

-- | @str.startswith@ / @endswith@ (and the @bytes@ ones).
affix :: Bool -> Value -> Value -> Either Exc Value
affix isStart s fragment
  | Just t <- asText s = case asText fragment of
      Just f -> Right (boolType (if isStart then f `T.isPrefixOf` t else f `T.isSuffixOf` t))
      Nothing -> Left (typeErr (method <> " first arg must be str or a tuple of str, not " <> tpName fragment))
  | Just b <- asBytes s = case asBytes fragment of
      Just f -> Right (boolType (if isStart then f `BS.isPrefixOf` b else f `BS.isSuffixOf` b))
      Nothing -> Left (typeErr (method <> " first arg must be bytes or a tuple of bytes, not " <> tpName fragment))
  | otherwise = Left (pyExc AttributeError (quoted (tpName s) <> " object has no attribute " <> quoted method))
  where
    method = if isStart then "startswith" else "endswith"

-- | @value.encode("utf-8")@ of a string value and its text: a string
-- holding a lone surrogate (a WTF-8 'Text', "Petrus.Json.Wtf8") raises
-- CPython's @UnicodeEncodeError@ over the first run of surrogates, with its
-- arguments @(encoding, object, start, end, reason)@.
encodeUtf8Strict :: Value -> Text -> Either Exc ByteString
encodeUtf8Strict value t
  | not (hasLoneSurrogate t) = Right (TE.encodeUtf8 t)
  | otherwise =
      let (before, rest) = break isSurrogate (T.unpack t)
          run = takeWhile isSurrogate rest
          start = length before
          end = start + length run - 1
          what = case run of
            [c] -> "character '\\u" <> T.pack (showHex (ord c) "") <> "' in position " <> T.pack (show start)
            _ -> "characters in position " <> T.pack (show start) <> "-" <> T.pack (show end)
       in Left
            ( PyExc
                UnicodeEncodeError
                ("'utf-8' codec can't encode " <> what <> ": surrogates not allowed")
                ["'utf-8'", valueRepr value, T.pack (show start), T.pack (show (end + 1)), "'surrogates not allowed'"]
            )
  where
    isSurrogate c = ord c >= 0xD800 && ord c <= 0xDFFF

-- | @function_matches@: @re2.search(pattern, text)@; a pattern error is a
-- returned @CELEvalError@ (not raised).
matches :: Value -> Value -> Either Exc Value
matches text pattern = do
  compiled <- case pattern of
    _
      | Just p <- asText pattern -> compileRegex p <$ encodeUtf8Strict pattern p
      | Just p <- asBytes pattern -> Right (compileRegexBytes p)
      | otherwise -> Left (typeErr ("expected str or bytes pattern, got " <> tpName pattern))
  case compiled of
    Left message -> Right (VError (celError "match error" (pyExc Re2Error message) Nothing))
    Right re
      | Just t <- asText text -> boolType (searchText re t) <$ encodeUtf8Strict text t
      | Just b <- asBytes text -> Right (boolType (searchBytes re b))
      | otherwise -> Left (typeErr ("expected str or bytes text, got " <> tpName text))

-- | The @get*@ functions: @TimestampType@ methods (with a timezone) and
-- the four @DurationType@ ones (which @assert@ no timezone).
timeGetter :: Text -> Value -> Maybe Value -> Either Exc Value
timeGetter getter ts tz = case ts of
  VTimestamp dt -> do
    offset <- case tz of
      Nothing -> Right 0
      Just VNone -> Right 0
      Just z
        | not (truthy z) -> Right 0
        | Just name <- asText z -> liftPy (timezoneOffset (Just name))
        | otherwise -> Left (typeErr ("expected string or bytes-like object, got " <> quoted (tpName z)))
    local <- liftPy (inOffset offset dt)
    let f = datetimeFields local
    VInt <$> case getter of
      "getDate" -> Right (fromIntegral (fieldDay f))
      "getDayOfMonth" -> Right (fromIntegral (fieldDay f) - 1)
      "getDayOfWeek" -> Right (isoWeekday f `mod` 7)
      "getDayOfYear" -> Right (dayOfYear f)
      "getFullYear" -> Right (fieldYear f)
      "getMonth" -> Right (fromIntegral (fieldMonth f) - 1)
      "getHours" -> Right (fieldHour f)
      "getMilliseconds" -> Right (fieldMicrosecond f `div` 1000)
      "getMinutes" -> Right (fieldMinute f)
      "getSeconds" -> Right (fieldSecond f)
      _ -> Left (noAttribute getter)
  VDuration td
    | getter `elem` ["getHours", "getMilliseconds", "getMinutes", "getSeconds"] -> do
        case tz of
          Just VNone -> Right ()
          Nothing -> Right ()
          Just _ -> Left (pyExc AssertionError "")
        let total = timedeltaTotalSeconds td
            value = case getter of
              "getHours" -> total / 60 / 60
              "getMilliseconds" -> total * 1000
              "getMinutes" -> total / 60
              _ -> total
        n <- truncDouble value
        VInt <$> checkInt64 n
  _ -> Left (noAttribute getter)
  where
    noAttribute g = pyExc AttributeError (quoted (tpName ts) <> " object has no attribute " <> quoted g)

-- ---------------------------------------------------------------------------
-- Constructors

callClass :: PyClass -> [Value] -> Either Exc Value
callClass cls args = case cls of
  CBoolType -> one "BoolType.__new__" "source" boolTypeNew
  CIntType -> atLeastOne "IntType.__new__" intTypeNew
  CUintType -> atLeastOne "UintType.__new__" uintTypeNew
  CDoubleType -> one "DoubleType.__new__" "source" doubleTypeNew
  CStringType -> atLeastOne "StringType.__new__" stringTypeNew
  CBytesType -> atLeastOne "BytesType.__new__" bytesTypeNew
  CListType -> case args of
    [] -> Right (VList [])
    [x] -> VList <$> pyIter x
    _ -> Left (typeErr ("list expected at most 1 argument, got " <> T.pack (show (length args))))
  CMapType -> case args of
    [] -> Right (VMap [])
    [x] -> VMap <$> mapTypeInit x
    _ -> Left (typeErr ("MapType.__init__() takes from 1 to 2 positional arguments but " <> T.pack (show (length args + 1)) <> " were given"))
  CMessageType -> case args of
    [] -> Right (VMessage [])
    [x] -> VMessage <$> mapTypeInit x
    _ -> Left (typeErr "Expected dictionary or fields, not {args!r}")
  CDurationType -> do
    checkNewArity "DurationType.__new__" ["seconds", "nanos"] 1 args
    case args of
      [s] -> durationTypeNew s (VInt 0)
      [s, n] -> durationTypeNew s n
      _ -> Right VNone
  CTimestampType -> case args of
    [] -> checkNewArity "TimestampType.__new__" ["source"] 1 args >> Right VNone
    s : rest -> timestampTypeNew s rest
  CTypeType -> one "TypeType.__new__" "instance" (Right . typeOf)
  CNoneType -> case args of
    [] -> Right VNone
    _ -> Left (typeErr "NoneType takes no arguments")
  CInt -> case args of
    [] -> Right (PInt 0)
    [x] -> PInt <$> pyIntConvert x
    _ -> Left (typeErr ("int() takes at most 2 arguments (" <> T.pack (show (length args)) <> " given)"))
  CFloat -> case args of
    [] -> Right (PFloat 0)
    [x] -> PFloat <$> pyFloatConvert x
    _ -> Left (typeErr ("float expected at most 1 argument, got " <> T.pack (show (length args))))
  CStr -> case args of
    [] -> Right (PStr "")
    [x] -> Right (PStr (valueStr x))
    _ -> Left (typeErr ("str() takes at most 3 arguments (" <> T.pack (show (length args)) <> " given)"))
  CList -> case args of
    [] -> Right (PList [])
    [x] -> PList <$> pyIter x
    _ -> Left (typeErr ("list expected at most 1 argument, got " <> T.pack (show (length args))))
  CType -> case args of
    [x] -> Right (VClass (pyType x))
    _ -> Left (typeErr "type() takes 1 or 3 arguments")
  _ -> Left (typeErr ("cannot create " <> quoted (classQualifiedName cls) <> " instances"))
  where
    one name param k = do
      checkNewArity name [param] 1 args
      case args of
        [x] -> k x
        _ -> Right VNone
    atLeastOne name k = case args of
      [] -> checkNewArity name ["source"] 1 args >> Right VNone
      x : _ -> k x

-- | @MapType.get(StringType('value'))@ of a @MessageType@ argument.
messageValue :: Entries -> Either Exc Value
messageValue kvs =
  dictLookup kvs (VString "value") >>= \case
    Just v -> Right v
    Nothing -> Left (keyError (VString "value"))

-- | @int(x)@ (@PyNumber_Long@).
pyIntConvert :: Value -> Either Exc Integer
pyIntConvert v
  | Just n <- asInteger v = Right n
  | Just d <- asDouble v = truncDouble d
  | Just t <- asText v = parsed (parseIntDigits 10 (asciiTransform t)) (valueRepr v)
  | Just b <- asBytes v = parsed (parseIntDigits 10 (map (chr . fromIntegral) (BS.unpack b))) (bytesRepr b)
  | otherwise =
      Left (typeErr ("int() argument must be a string, a bytes-like object or a real number, not " <> quoted (tpName v)))
  where
    parsed result shown = case result of
      Right n -> Right n
      Left True -> Left (valueErr "Exceeds the limit (4300 digits) for integer string conversion")
      Left False -> Left (valueErr ("invalid literal for int() with base 10: " <> shown))

-- | @float(x)@ (@PyNumber_Float@).
pyFloatConvert :: Value -> Either Exc Double
pyFloatConvert v
  | Just d <- asDouble v = Right d
  | Just n <- asInteger v = intToDouble n
  | Just t <- asText v = maybe (Left (couldNot (valueRepr v))) Right (parseFloatText t)
  | Just b <- asBytes v =
      maybe (Left (couldNot (bytesRepr b))) Right (parseFloatText (T.pack (map (chr . fromIntegral) (BS.unpack b))))
  | otherwise = Left (typeErr ("float() argument must be a string or a real number, not " <> quoted (tpName v)))
  where
    couldNot shown = valueErr ("could not convert string to float: " <> shown)

-- | @int(text, 16)@ for the @0x@-prefixed strings @IntType@ accepts.
hexInt :: Text -> Either Exc Integer
hexInt t = case parseIntDigits 16 (asciiTransform t) of
  Right n -> Right n
  Left _ -> Left (valueErr ("invalid literal for int() with base 16: " <> strRepr t))

-- | @BoolType(source)@.
boolTypeNew :: Value -> Either Exc Value
boolTypeNew src = case src of
  VNone -> Right (VBool 0)
  VBool _ -> Right src
  VMessage kvs -> VBool <$> (messageValue kvs >>= pyIntConvert)
  _
    | Just t <- asText src, t `elem` ["False", "f", "FALSE", "false"] -> Right (VBool 0)
    | Just t <- asText src, t `elem` ["True", "t", "TRUE", "true"] -> Right (VBool 1)
    | otherwise -> VBool <$> pyIntConvert src

-- | @IntType(source)@.
intTypeNew :: Value -> Either Exc Value
intTypeNew src = case src of
  VNone -> Right (VInt 0)
  VInt _ -> Right src
  VMessage kvs -> VInt <$> (messageValue kvs >>= pyIntConvert)
  VTimestamp dt -> do
    let f = datetimeTimestamp dt
    unless (f >= -(2 ^ (63 :: Int)) && f < 2 ^ (63 :: Int)) (Left (valueErr "overflow"))
    VInt <$> truncDouble f
  _
    | Just d <- asDouble src -> truncDouble d >>= fmap VInt . checkInt64
    | Just t <- asText src, T.take 2 t `elem` ["0x", "0X"] -> hexInt (T.drop 2 t) >>= fmap VInt . checkInt64
    | Just t <- asText src, T.take 3 t `elem` ["-0x", "-0X"] -> hexInt (T.drop 3 t) >>= fmap VInt . checkInt64 . negate
    | otherwise -> pyIntConvert src >>= fmap VInt . checkInt64

-- | @UintType(source)@.
uintTypeNew :: Value -> Either Exc Value
uintTypeNew src = case src of
  VUint _ -> Right src
  VNone -> Right (VUint 0)
  VTimestamp dt -> do
    let f = datetimeTimestamp dt
    unless (f >= 0 && f < 2 ^ (64 :: Int)) (Left (valueErr "overflow"))
    VUint <$> truncDouble f
  VMessage kvs -> do
    v <- mapTypeGetItem kvs (PStr "value")
    let v' = case v of
          VNone -> PInt 0
          _ -> v
    low <- richCompare CmpLe (PInt 0) v'
    inRange <- if low then richCompare CmpLt v' (PInt (2 ^ (64 :: Int))) else Right False
    unless inRange (Left (valueErr "overflow"))
    VUint <$> pyIntConvert v'
  _
    | Just d <- asDouble src -> truncDouble d >>= fmap VUint . checkUint64
    | Just t <- asText src, T.take 2 t `elem` ["0x", "0X"] -> hexInt (T.drop 2 t) >>= fmap VUint . checkUint64
    | otherwise -> pyIntConvert src >>= fmap VUint . checkUint64

-- | @DoubleType(source)@.
doubleTypeNew :: Value -> Either Exc Value
doubleTypeNew src = case src of
  VNone -> Right (VDouble 0)
  VMessage kvs -> VDouble <$> (messageValue kvs >>= pyFloatConvert)
  _ -> VDouble <$> pyFloatConvert src

-- | @StringType(source)@.
stringTypeNew :: Value -> Either Exc Value
stringTypeNew src
  | Just b <- asBytes src = VString <$> decodeUtf8 b
  | Just t <- asText src = Right (VString t)
  | otherwise = Right (VString (valueStr src))

-- | @bytes.decode('utf-8')@ with CPython's error message.
decodeUtf8 :: ByteString -> Either Exc Text
decodeUtf8 b = case TE.decodeUtf8' b of
  Right t -> Right t
  Left _ ->
    let (position, byte, reason) = firstInvalid 0 (BS.unpack b)
     in Left
          ( pyExc
              UnicodeDecodeError
              ( "'utf-8' codec can't decode byte 0x" <> T.justifyRight 2 '0' (T.pack (showHex byte ""))
                  <> " in position "
                  <> T.pack (show position)
                  <> ": "
                  <> reason
              )
          )
  where
    firstInvalid :: Int -> [Word8] -> (Int, Word8, Text)
    firstInvalid i = \case
      [] -> (i, 0, "unexpected end of data")
      c : rest
        | c < 0x80 -> firstInvalid (i + 1) rest
        | c >= 0xc2 && c <= 0xdf -> continuation 1 c rest
        | c >= 0xe0 && c <= 0xef -> continuation 2 c rest
        | c >= 0xf0 && c <= 0xf4 -> continuation 3 c rest
        | otherwise -> (i, c, "invalid start byte")
      where
        continuation n c rest =
          let (cs, after) = splitAt n rest
              ok k x = case (c, k :: Int) of
                (0xe0, 0) -> x >= 0xa0 && x <= 0xbf
                (0xed, 0) -> x >= 0x80 && x <= 0x9f
                (0xf0, 0) -> x >= 0x90 && x <= 0xbf
                (0xf4, 0) -> x >= 0x80 && x <= 0x8f
                _ -> x >= 0x80 && x <= 0xbf
              valid = and (zipWith ok [0 ..] cs)
           in if not valid
                then (i, c, "invalid continuation byte")
                else
                  if length cs < n
                    then (i, c, "unexpected end of data")
                    else firstInvalid (i + n + 1) after

-- | @BytesType(source)@.
bytesTypeNew :: Value -> Either Exc Value
bytesTypeNew src = case src of
  VNone -> Right (VBytes BS.empty)
  VMessage kvs -> VBytes <$> (messageValue kvs >>= bytesBuiltin)
  _
    | Just b <- asBytes src -> Right (VBytes b)
    | Just t <- asText src -> VBytes <$> encodeUtf8Strict src t
    | isJust (asList src) || isJust (asDict src) -> VBytes <$> (pyIter src >>= bytesFromItems)
    | otherwise -> Left (typeErr ("Invalid initial value type: " <> classRepr (pyType src)))

-- | The builtin @bytes(x)@.
bytesBuiltin :: Value -> Either Exc ByteString
bytesBuiltin v
  | Just b <- asBytes v = Right b
  | Just _ <- asText v = Left (typeErr "string argument without an encoding")
  | Just n <- asInteger v = if n < 0 then Left (valueErr "negative count") else Right (BS.replicate (fromInteger n) 0)
  | isJust (asList v) || isJust (asDict v) = pyIter v >>= bytesFromItems
  | otherwise = Left (typeErr ("cannot convert " <> quoted (tpName v) <> " object to bytes"))

bytesFromItems :: [Value] -> Either Exc ByteString
bytesFromItems items = BS.pack <$> traverse byte items
  where
    byte x = case asInteger x of
      Just n
        | n >= 0 && n < 256 -> Right (fromInteger n)
        | otherwise -> Left (valueErr "bytes must be in range(0, 256)")
      Nothing -> Left (typeErr (quoted (tpName x) <> " object cannot be interpreted as an integer"))

-- | @MapType.__init__(items)@.
mapTypeInit :: Value -> Either Exc Entries
mapTypeInit items = case items of
  VNone -> Right []
  _
    | isJust (asList items) || isText items || isJust (asBytes items) -> pyIter items >>= foldM addPair []
    | Just kvs <- asDict items -> foldM (\acc (k, v) -> dictSet acc k v) [] kvs
    | otherwise -> Left (typeErr ("Invalid initial value type: " <> classRepr (pyType items)))
  where
    addPair acc item = do
      parts <- case pyIter item of
        Right xs -> Right xs
        Left _ -> Left (typeErr ("cannot unpack non-iterable " <> tpName item <> " object"))
      case parts of
        [name, value] -> do
          duplicate <- dictContains acc name
          when duplicate (Left (valueErr ("Duplicate key " <> valueRepr name)))
          dictSet acc name value
        _
          | length parts < 2 ->
              Left (valueErr ("not enough values to unpack (expected 2, got " <> T.pack (show (length parts)) <> ")"))
          | otherwise ->
              Left (valueErr ("too many values to unpack (expected 2, got " <> T.pack (show (length parts)) <> ")"))

-- | @DurationType(seconds, nanos)@.
durationTypeNew :: Value -> Value -> Either Exc Value
durationTypeNew seconds nanos
  | Just td <- asDelta seconds = durationType td
  | Just n <- asInteger seconds = do
      unless (abs n <= maxDurationSeconds) (Left (valueErr "range error: {seconds}"))
      micros <- numberOp OpFloorDiv nanos (PInt 1000)
      extra <- case micros of
        _
          | Just m <- asInteger micros -> Right m
          | Just d <- asDouble micros -> Right (round d)
          | otherwise -> Left (typeErr ("unsupported type for timedelta microseconds component: " <> tpName micros))
      VDuration <$> liftPy (checkTimedelta (n * 1000000 + extra))
  | Just t <- asText seconds = VDuration <$> liftPy (parseDurationString t)
  | otherwise = Left (typeErr ("Invalid initial value type: " <> classRepr (pyType seconds)))

-- | @TimestampType(source, *args)@.
timestampTypeNew :: Value -> [Value] -> Either Exc Value
timestampTypeNew src rest = case src of
  VTimestamp _ -> Right src
  _
    | Just year <- asInteger src, length rest >= 2 -> do
        fields <- traverse field rest
        VTimestamp <$> liftPy (datetimeFromFields 0 (year : fields))
    | Just t <- asText src ->
        liftPy (parseTimestamp t) >>= \case
          ParsedDatetime dt -> Right (VTimestamp dt)
          ParsedNotDatetime -> Left (pyExc AttributeError "'Duration' object has no attribute 'year'")
    | otherwise -> Left (typeErr ("Cannot create " <> classRepr CTimestampType <> " from " <> valueRepr src))
  where
    field x = case asInteger x of
      Just n -> Right n
      Nothing -> Left (typeErr (quoted (tpName x) <> " object cannot be interpreted as an integer"))

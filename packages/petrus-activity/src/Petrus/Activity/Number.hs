-- | A Python @int | float@ that keeps its spelling.
--
-- Activity policies, failure delays, and the kernel's virtual instants are
-- all Python numbers in the reference: an integer stays an integer on the
-- wire (@10@) and a float stays a float (@0.5@, @10.0@). 'Number' keeps that
-- distinction while comparing and adding the way Python does — @1 == 1.0@,
-- @1 < 1.5@, @int + int@ is an @int@, @int + float@ is a @float@ — so the
-- kernel can order and advance instants without ever coercing a spelling.
module Petrus.Activity.Number
  ( Number (..)
  , numberJson
  , numberFromJson
  , numberValue
  , isFinite
  , isIntegral
  , reprNumber
  ) where

import Control.DeepSeq (NFData (..))
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), pythonFloatRepr)

-- | An integer or a float, as spelled.
data Number = IntNumber Integer | FloatNumber Double

instance NFData Number where
  rnf = \case
    IntNumber i -> rnf i
    FloatNumber d -> rnf d

-- | Python's numeric equality: exact across int and float, NaN unequal to
-- everything.
instance Eq Number where
  IntNumber a == IntNumber b = a == b
  FloatNumber a == FloatNumber b = a == b
  IntNumber a == FloatNumber b = intFloatEq a b
  FloatNumber a == IntNumber b = intFloatEq b a

intFloatEq :: Integer -> Double -> Bool
intFloatEq i d = not (isNaN d || isInfinite d) && toRational d == fromInteger i

-- | Python's numeric order: exact across int and float (never by rounding
-- the integer). Infinities order beyond every integer; NaN compares as
-- greater than everything so that sorting stays total.
instance Ord Number where
  compare (IntNumber a) (IntNumber b) = compare a b
  compare (FloatNumber a) (FloatNumber b) = compareDouble a b
  compare (IntNumber a) (FloatNumber b) = compareMixed a b
  compare (FloatNumber a) (IntNumber b) = invert (compareMixed b a)

compareDouble :: Double -> Double -> Ordering
compareDouble a b
  | isNaN a && isNaN b = EQ
  | isNaN a = GT
  | isNaN b = LT
  | otherwise = compare a b

compareMixed :: Integer -> Double -> Ordering
compareMixed i d
  | isNaN d = LT
  | isInfinite d = if d > 0 then LT else GT
  | otherwise = compare (fromInteger i) (toRational d)

invert :: Ordering -> Ordering
invert = \case
  LT -> GT
  GT -> LT
  EQ -> EQ

-- | Arithmetic with Python's int/float promotion. Integer literals are
-- integers, so @0 :: Number@ is the logical epoch @IntNumber 0@.
instance Num Number where
  (+) = arith (+) (+)
  (-) = arith (-) (-)
  (*) = arith (*) (*)
  negate = \case
    IntNumber i -> IntNumber (negate i)
    FloatNumber d -> FloatNumber (negate d)
  abs = \case
    IntNumber i -> IntNumber (abs i)
    FloatNumber d -> FloatNumber (abs d)
  signum = \case
    IntNumber i -> IntNumber (signum i)
    FloatNumber d -> FloatNumber (signum d)
  fromInteger = IntNumber

arith :: (Integer -> Integer -> Integer) -> (Double -> Double -> Double) -> Number -> Number -> Number
arith int float a b = case (a, b) of
  (IntNumber x, IntNumber y) -> IntNumber (int x y)
  _ -> FloatNumber (float (numberValue a) (numberValue b))

-- | Python's @repr@: @10@, @0.5@, @10.0@, @inf@, @nan@.
instance Show Number where
  show = T.unpack . reprNumber

reprNumber :: Number -> Text
reprNumber = \case
  IntNumber i -> T.pack (show i)
  FloatNumber d
    | isNaN d -> "nan"
    | isInfinite d -> if d > 0 then "inf" else "-inf"
    | otherwise -> T.pack (pythonFloatRepr d)

-- | The JSON spelling of a number.
numberJson :: Number -> Json
numberJson = \case
  IntNumber i -> Int i
  FloatNumber d -> Float d

-- | Read a JSON number. Booleans are not numbers here: the reference's
-- policy and instant checks refuse @bool@ by exact type.
numberFromJson :: Json -> Maybe Number
numberFromJson = \case
  Int i -> Just (IntNumber i)
  Float d -> Just (FloatNumber d)
  _ -> Nothing

-- | The number as a double, for range checks and float arithmetic (Python's
-- @float(int)@, correctly rounded).
numberValue :: Number -> Double
numberValue = \case
  IntNumber i -> fromInteger i
  FloatNumber d -> d

-- | @math.isfinite@.
isFinite :: Number -> Bool
isFinite = \case
  IntNumber _ -> True
  FloatNumber d -> not (isNaN d || isInfinite d)

-- | Whether the number is spelled as an integer.
isIntegral :: Number -> Bool
isIntegral = \case
  IntNumber _ -> True
  FloatNumber _ -> False

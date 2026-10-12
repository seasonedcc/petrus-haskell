-- | CPython's @repr()@ of the object a JSON value stands for (what
-- @json.loads@, or @dict(pairs)@ for an object's members, builds), written
-- straight into one buffer.
--
-- Hamsterdan keeps its dashboard log as @f"{kind}:{body}"@ and its
-- projection digests as @f"{kind}:{sorted(body.items())!r}"@, and Petrus
-- error texts quote values with @!r@, so these spellings are hot. A plain
-- version (difference lists of the pieces, joined by one 'T.concat', with
-- each string through 'pythonStrRepr') cannot keep up with CPython: on
-- hamsterdan-contracts' benchmark it printed a dashboard entry in 916 ns and
-- a digest in 1.41 µs, against CPython's 636 ns and 1.36 µs, where this
-- writer takes 487 ns and 769 ns (hamsterdan-contracts' @bench/RESULTS.md@,
-- "The literal printer"). So the writer measures an upper bound of the
-- output ('bound'), writes into a buffer of that size, and shrinks it.
module Petrus.Json.Python.JsonRepr
  ( jsonRepr
  , jsonItemsRepr
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array (Array, listArray, (!))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as TA
import Data.Text.Internal qualified as TI
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Json.Repr (pythonDoubleRepr)
import Petrus.Json.Value (Json (..), pythonDict)

-- | @repr(value)@ of the object a JSON value stands for: @None@, @True@,
-- ints, floats, @str@ (with every escape CPython writes), lists, and dicts
-- holding each key once, at its first position, with its last value.
jsonRepr :: Json -> Text
jsonRepr value = written (bound value) (\array -> writeJson array 0 value)

-- | @repr@ of a list of @(key, value)@ tuples, such as @sorted(d.items())@
-- (the caller orders the items).
jsonItemsRepr :: [(Text, Json)] -> Text
jsonItemsRepr items =
  written (2 + sum [stringBound key + bound value + 6 | (key, value) <- items]) $ \array -> do
    TA.unsafeWrite array 0 0x5B
    end <- separated array 1 item items
    TA.unsafeWrite array end 0x5D
    pure (end + 1)
  where
    item array offset (key, value) = do
      TA.unsafeWrite array offset 0x28
      afterKey <- writeString array (offset + 1) key
      TA.unsafeWrite array afterKey 0x2C
      TA.unsafeWrite array (afterKey + 1) 0x20
      afterValue <- writeJson array (afterKey + 2) value
      TA.unsafeWrite array afterValue 0x29
      pure (afterValue + 1)

-- | Run a writer over a buffer of at least the given size. Every write
-- stays inside it: 'bound' is an upper bound of what the writers produce.
written :: Int -> (forall s. TA.MArray s -> ST s Int) -> Text
written size write = runST $ do
  array <- TA.new size
  end <- write array
  TA.shrinkM array end
  frozen <- TA.unsafeFreeze array
  pure (TI.text frozen 0 end)

-- | The UTF-8 length of a text, in bytes.
utf8Length :: Text -> Int
utf8Length (TI.Text _ _ size) = size

-- | An upper bound of the UTF-8 length of a value's @repr@.
bound :: Json -> Int
bound = \case
  Null -> 4
  Bool _ -> 5
  Int value -> utf8Length (intText value)
  Float _ -> 32
  String value -> stringBound value
  Array values -> 2 + sum [bound value + 2 | value <- values]
  Object members -> 2 + sum [stringBound key + bound value + 4 | (key, value) <- members]

-- | No character's escape is longer than four times its UTF-8 length
-- (a C0 control becomes @\\xhh@), plus the quotes.
stringBound :: Text -> Int
stringBound value = 4 * utf8Length value + 2

intText :: Integer -> Text
intText value
  | value >= 0 && value < smallIntCount = smallInts ! fromInteger value
  | otherwise = T.pack (show value)

-- | The spellings of the small non-negative integers (counts, flags, run
-- attempts), computed once.
smallInts :: Array Int Text
smallInts = listArray (0, fromInteger smallIntCount - 1) [T.pack (show i) | i <- [0 .. smallIntCount - 1]]

smallIntCount :: Integer
smallIntCount = 1024

writeJson :: TA.MArray s -> Int -> Json -> ST s Int
writeJson array offset = \case
  Null -> writeText array offset "None"
  Bool True -> writeText array offset "True"
  Bool False -> writeText array offset "False"
  Int value -> writeText array offset (intText value)
  Float value -> writeText array offset (pythonDoubleRepr value)
  String value -> writeString array offset value
  Array values -> do
    TA.unsafeWrite array offset 0x5B
    end <- separated array (offset + 1) writeJson values
    TA.unsafeWrite array end 0x5D
    pure (end + 1)
  Object members -> do
    TA.unsafeWrite array offset 0x7B
    end <- separated array (offset + 1) member (pythonDict members)
    TA.unsafeWrite array end 0x7D
    pure (end + 1)
  where
    member target at (key, value) = do
      afterKey <- writeString target at key
      TA.unsafeWrite target afterKey 0x3A
      TA.unsafeWrite target (afterKey + 1) 0x20
      writeJson target (afterKey + 2) value

-- | Write items separated by @", "@.
separated :: TA.MArray s -> Int -> (TA.MArray s -> Int -> a -> ST s Int) -> [a] -> ST s Int
separated array offset writeItem = \case
  [] -> pure offset
  first : rest -> writeItem array offset first >>= go rest
  where
    go [] at = pure at
    go (next : more) at = do
      TA.unsafeWrite array at 0x2C
      TA.unsafeWrite array (at + 1) 0x20
      writeItem array (at + 2) next >>= go more

writeText :: TA.MArray s -> Int -> Text -> ST s Int
writeText array offset (TI.Text source from size) = do
  TA.copyI size array offset source from
  pure (offset + size)

-- | Write @repr(str)@: printable ASCII without quotes or backslashes in
-- single quotes as it is, anything else as 'pythonStrRepr' spells it.
writeString :: TA.MArray s -> Int -> Text -> ST s Int
writeString array offset value
  | simpleAscii value = do
      TA.unsafeWrite array offset 0x27
      end <- writeText array (offset + 1) value
      TA.unsafeWrite array end 0x27
      pure (end + 1)
  | otherwise = writeText array offset (pythonStrRepr value)

-- | Whether a text is printable ASCII without quotes or backslashes (its
-- @repr@ is the text in single quotes), tested on the UTF-8 bytes.
simpleAscii :: Text -> Bool
simpleAscii (TI.Text array offset size) = go offset
  where
    end = offset + size
    go i
      | i >= end = True
      | otherwise =
          let w = TA.unsafeIndex array i
           in w >= 0x20 && w < 0x7F && w /= 0x27 && w /= 0x22 && w /= 0x5C && go (i + 1)

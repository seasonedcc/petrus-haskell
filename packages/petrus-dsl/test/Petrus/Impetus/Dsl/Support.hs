-- | Shared test vocabulary: the reference tests' dataclasses as 'Typed'
-- payload types, and small Petri-aware implementations.
module Petrus.Impetus.Dsl.Support
  ( Order (..)
  , Config (..)
  , Receipt (..)
  , StringOrder (..)
  , StringConfig (..)
  , processArgs
  , positiveArgs
  , withinLimitArgs
  , emptyHandler
  , trueGuard
  , np
  , int
  , mustRight
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Binding (Handler, Typed (..), TypedArgs, handlerTokens, param)
import Petrus.Impetus.Petrinet.Enabledness (Guard)
import Petrus.Impetus.Petrinet.Schema (NetPath, netPath)
import Petrus.Json (Json (..), lookupMember)
import Text.Read (readMaybe)

-- | @Order(amount: int)@.
newtype Order = Order Integer
  deriving stock (Eq, Show)

-- | @Config(limit: int)@.
newtype Config = Config Integer
  deriving stock (Eq, Show)

-- | @Receipt(total: int)@.
newtype Receipt = Receipt Integer
  deriving stock (Eq, Show)

intMember :: Text -> Json -> Either Text Integer
intMember key value = case lookupMember key value of
  Just (Int n) -> Right n
  Just other -> Left ("TypeError(" <> T.pack (show other) <> ")")
  Nothing -> Left ("KeyError('" <> key <> "')")

instance Typed Order where
  typedColor = "Order"
  toPayload (Order n) = Object [("amount", Int n)]
  fromPayload v = Order <$> intMember "amount" v

instance Typed Config where
  typedColor = "Config"
  toPayload (Config n) = Object [("limit", Int n)]
  fromPayload v = Config <$> intMember "limit" v

instance Typed Receipt where
  typedColor = "Receipt"
  toPayload (Receipt n) = Object [("total", Int n)]
  fromPayload v = Receipt <$> intMember "total" v

-- | An 'Order' read through a custom converter that parses string amounts
-- (the reference test's @RecordingConverter@): the same color, another
-- decoding.
newtype StringOrder = StringOrder Order
  deriving stock (Eq, Show)

-- | A 'Config' read through the same custom converter.
newtype StringConfig = StringConfig Config
  deriving stock (Eq, Show)

stringMember :: Text -> Json -> Either Text Integer
stringMember key value = case lookupMember key value of
  Just (String s) | Just n <- readMaybe (T.unpack s) -> Right n
  Just (Int n) -> Right n
  _ -> Left ("cannot decode " <> key)

instance Typed StringOrder where
  typedColor = "Order"
  toPayload (StringOrder order) = toPayload order
  fromPayload v = StringOrder . Order <$> stringMember "amount" v

instance Typed StringConfig where
  typedColor = "Config"
  toPayload (StringConfig config) = toPayload config
  fromPayload v = StringConfig . Config <$> stringMember "limit" v

-- | @def process(order: Order) -> Receipt: return Receipt(order.amount + 1)@.
processArgs :: TypedArgs Receipt
processArgs = (\(Order amount) -> Receipt (amount + 1)) <$> param "order"

-- | @def positive(order: Order) -> bool: return order.amount > 0@.
positiveArgs :: TypedArgs Bool
positiveArgs = (\(Order amount) -> amount > 0) <$> param "order"

-- | @def within_limit(order: Order, config: Config) -> bool@, decoded
-- through the custom converter.
withinLimitArgs :: TypedArgs Bool
withinLimitArgs =
  (\(StringOrder (Order amount)) (StringConfig (Config limit)) -> amount <= limit)
    <$> param "order"
    <*> param "config"

-- | @lambda binding, outputs: {}@.
emptyHandler :: Handler
emptyHandler _ _ = Right (handlerTokens [])

-- | @lambda binding: True@.
trueGuard :: Guard
trueGuard _ = Right True

np :: Text -> NetPath
np = either (error . T.unpack) id . netPath

int :: Integer -> Json
int = Int

mustRight :: Show e => Either e a -> a
mustRight = either (error . show) id

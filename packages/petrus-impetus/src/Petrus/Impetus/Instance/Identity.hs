-- | The validated identities of the Instance protocol: @InstanceIdentity@,
-- @DeliveryIdentity@ and @FiringOccurrenceId@ of @petrus.impetus.instance@.
--
-- Each is a newtype whose constructor is not exported. A smart constructor
-- applies the reference's rule and returns its message on refusal. Python
-- also checks that the argument is of the exact built-in type; here the
-- argument's type ensures that (DIVERGENCES item 15).
--
-- Upstream's classes subclass @str@ and @int@, so a value is usable wherever
-- the plain one is. Here a value converts explicitly ('instanceIdentityText',
-- 'deliveryIdentityText', 'firingOccurrenceIdInt'). The kernel uses the
-- newtypes where upstream's annotations are load-bearing: the fields of
-- @AcceptedDelivery@, and the check of the identity an Instance is created
-- or resumed with.
module Petrus.Impetus.Instance.Identity
  ( InstanceIdentity
  , mkInstanceIdentity
  , instanceIdentityText
  , DeliveryIdentity
  , mkDeliveryIdentity
  , deliveryIdentityText
  , FiringOccurrenceId
  , mkFiringOccurrenceId
  , firingOccurrenceIdInt
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.Python (pythonIntRepr, pythonStrRepr)
-- | The non-empty durable identity of one Instance.
newtype InstanceIdentity = InstanceIdentity Text
  deriving stock (Eq, Ord, Show)

-- | @InstanceIdentity(value)@.
mkInstanceIdentity :: Text -> Either Text InstanceIdentity
mkInstanceIdentity value
  | T.null value = Left ("Instance identity must be a non-empty string of the exact built-in type, got " <> pythonStrRepr value)
  | otherwise = Right (InstanceIdentity value)

instanceIdentityText :: InstanceIdentity -> Text
instanceIdentityText (InstanceIdentity value) = value

-- | The non-empty stable identity of one external source delivery.
newtype DeliveryIdentity = DeliveryIdentity Text
  deriving stock (Eq, Ord, Show)

-- | @DeliveryIdentity(value)@.
mkDeliveryIdentity :: Text -> Either Text DeliveryIdentity
mkDeliveryIdentity value
  | T.null value = Left ("delivery identity must be a non-empty string of the exact built-in type, got " <> pythonStrRepr value)
  | otherwise = Right (DeliveryIdentity value)

deliveryIdentityText :: DeliveryIdentity -> Text
deliveryIdentityText (DeliveryIdentity value) = value

-- | The positive writer-minted identity of one firing occurrence.
newtype FiringOccurrenceId = FiringOccurrenceId Int
  deriving stock (Eq, Ord, Show)

-- | @FiringOccurrenceId(value)@.
mkFiringOccurrenceId :: Int -> Either Text FiringOccurrenceId
mkFiringOccurrenceId value
  | value < 1 = Left ("firing occurrence must be a positive integer of the exact built-in type, got " <> pythonIntRepr value)
  | otherwise = Right (FiringOccurrenceId value)

firingOccurrenceIdInt :: FiringOccurrenceId -> Int
firingOccurrenceIdInt (FiringOccurrenceId value) = value

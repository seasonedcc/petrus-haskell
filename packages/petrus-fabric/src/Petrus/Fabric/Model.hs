{-# LANGUAGE DataKinds #-}

-- | Transport-neutral Fabric values (a port of @petrus.fabric.model@,
-- spec/fabric.md §3–§4).
--
-- Every value is validated by its smart constructor and cannot be built or
-- updated any other way: the record constructors are not exported, and the
-- fields are read with record dot syntax through 'HasField' instances
-- (@envelope.sender@, @envelope.digest@, @route.instanceId@).
module Petrus.Fabric.Model
  ( -- * Limits
    maxInlinePayloadBytes
  , maxTextBytes
    -- * Value rules (§3)
  , fabricText
  , jsonCopy
  , jsonObject
  , canonicalBytes
  , sha256Hex
    -- * ReplyRoute (§4.1)
  , ReplyRoute
  , replyRoute
  , replyRouteToData
  , replyRouteFromData
    -- * Envelope (§4.2)
  , Envelope
  , envelope
  , envelopeToData
  , envelopeFromData
  , envelopeFields
    -- * Endpoint (§4.3)
  , Endpoint
  , endpoint
  , endpointToData
  , endpointFromData
    -- * Results (§4.4, §4.5)
  , DeliveryState (..)
  , deliveryStateText
  , Submission (..)
  , Receipt (..)
    -- * Reference spellings for messages
  , pyRepr
  , pyStrList
  , exactObject
  ) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Unsafe qualified as TU
import Data.Time (UTCTime)
import GHC.Records (HasField (..))
import Petrus.Fabric.Error
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps, dumpsString, encodeErrorMessage)
import Petrus.Json.Encode (EncodeError (..))
import Petrus.Json.Repr (pythonReprText)

-- | @MAX_INLINE_PAYLOAD_BYTES@: 64 KiB of canonical payload bytes (§4.2.1).
maxInlinePayloadBytes :: Int
maxInlinePayloadBytes = 64 * 1024

-- | The Fabric text limit in UTF-8 bytes (§3.1).
maxTextBytes :: Int
maxTextBytes = 1024

-- ---------------------------------------------------------------------------
-- Value rules

-- | @_text(value, name)@: non-empty, at most 1024 UTF-8 bytes (§3.1), and —
-- the spec's SHOULD, where the reference fails late at the database — free
-- of U+0000.
fabricText :: Text -> Text -> Either FabricError Text
fabricText name value
  | T.null value || TU.lengthWord8 value > maxTextBytes =
      Left (InvalidValue (name <> " must be a non-empty string of at most 1024 UTF-8 bytes"))
  | T.any (== '\0') value = Left (InvalidValue (name <> " must not contain NUL (U+0000)"))
  | otherwise = Right value

-- | @_json_copy(value, name)@: refuse non-finite floats (with the offending
-- path), NUL in strings, and integers CPython will not print; answer the
-- value as @json.loads(json.dumps(value))@ would (duplicate members collapse
-- to their first position with their last value).
jsonCopy :: Text -> Json -> Either FabricError Json
jsonCopy name value = validate name value >> Right (detach value)
  where
    validate path = \case
      Float d
        | isNaN d || isInfinite d ->
            Left (InvalidValue (path <> " must be strict JSON (NaN and Infinity are forbidden)"))
        | otherwise -> Right ()
      Int n
        | abs n >= integerLimit -> Left (InvalidValue (T.pack (encodeErrorMessage (IntegerTooLarge 4300))))
        | otherwise -> Right ()
      String s
        | T.any (== '\0') s -> Left (InvalidValue (path <> " must not contain NUL (U+0000)"))
        | otherwise -> Right ()
      Array items -> mapM_ (\(i, item) -> validate (path <> "[" <> T.pack (show i) <> "]") item) (zip [0 :: Int ..] items)
      Object members -> mapM_ (\(key, item) -> member path key >> validate (path <> "." <> key) item) members
      _ -> Right ()
    member path key
      | T.any (== '\0') key = Left (InvalidValue (path <> " object keys must not contain NUL (U+0000)"))
      | otherwise = Right ()

integerLimit :: Integer
integerLimit = 10 ^ (4300 :: Int)

-- A dict built from members: first position, last value.
detach :: Json -> Json
detach = \case
  Array items -> Array (map detach items)
  Object members -> Object (map (fmap detach) (dedupe members))
  other -> other
  where
    dedupe members
      | Set.size (Set.fromList (map fst members)) == length members = members
      | otherwise =
          let lastValue = Map.fromList members
              go _ [] = []
              go seen ((k, _) : rest)
                | Set.member k seen = go seen rest
                | otherwise = (k, lastValue Map.! k) : go (Set.insert k seen) rest
           in go Set.empty members

-- | @_json_object(value, name)@: the value must be an object.
jsonObject :: Text -> Json -> Either FabricError [(Text, Json)]
jsonObject name = \case
  Object members -> Right members
  _ -> Left (InvalidType (name <> " must be a JSON object"))

-- | @_canonical(value)@: sorted keys, compact separators, raw UTF-8, no NaN
-- (§3.3).
canonicalBytes :: Json -> Either FabricError ByteString
canonicalBytes = first (InvalidValue . T.pack . encodeErrorMessage) . dumps canonicalOptions

canonicalOptions :: EncodeOptions
canonicalOptions = compact {sortKeys = True}

-- | Lowercase SHA-256 hex (§3.4).
sha256Hex :: ByteString -> Text
sha256Hex = TE.decodeLatin1 . Base16.encode . SHA256.hash

-- | The canonical (and only) spelling of a string.
canonicalString :: Text -> B.Builder
canonicalString = B.byteString . dumpsString canonicalOptions

-- | @exact_object@: the members of an object whose key set is exactly the
-- given one, or the message.
exactObject :: [Text] -> Text -> Json -> Either FabricError (Map.Map Text Json)
exactObject fields message = \case
  Object members
    | Map.keysSet m == Set.fromList fields -> Right m
    where
      m = Map.fromList members
  _ -> Left (InvalidValue message)

-- | @repr(str)@.
pyRepr :: Text -> Text
pyRepr = T.pack . pythonReprText

-- | @repr(list_of_str)@.
pyStrList :: [Text] -> Text
pyStrList items = "[" <> T.intercalate ", " (map pyRepr items) <> "]"

-- ---------------------------------------------------------------------------
-- ReplyRoute

-- | Where a reply to an envelope must go (§4.1).
data ReplyRoute = ReplyRoute {rrInstanceId :: Text, rrSource :: Text}
  deriving stock (Eq, Ord, Show)

instance HasField "instanceId" ReplyRoute Text where getField r = r.rrInstanceId
instance HasField "source" ReplyRoute Text where getField r = r.rrSource

replyRoute :: Text -> Text -> Either FabricError ReplyRoute
replyRoute instanceId source =
  ReplyRoute <$> fabricText "reply_route.instance_id" instanceId <*> fabricText "reply_route.source" source

replyRouteToData :: ReplyRoute -> Json
replyRouteToData r = Object [("instance_id", String r.rrInstanceId), ("source", String r.rrSource)]

replyRouteFromData :: Json -> Either FabricError ReplyRoute
replyRouteFromData value = do
  members <- exactObject ["instance_id", "source"] "reply_route must be an exact object with instance_id and source" value
  instanceId <- textMember "reply_route.instance_id" (members Map.! "instance_id")
  source <- textMember "reply_route.source" (members Map.! "source")
  replyRoute instanceId source

textMember :: Text -> Json -> Either FabricError Text
textMember name = \case
  String s -> fabricText name s
  _ -> Left (InvalidValue (name <> " must be a non-empty string of at most 1024 UTF-8 bytes"))

-- ---------------------------------------------------------------------------
-- Envelope

-- | One Fabric message, version 1 (§4.2).
data Envelope = Envelope
  { envDeliveryId :: Text
  , envSender :: Text
  , envRecipient :: Text
  , envSource :: Text
  , envCorrelation :: Text
  , envPayload :: Json
  , envReplyRoute :: Maybe ReplyRoute
  , envPayloadBytes :: ByteString
  -- ^ The payload's canonical bytes (measured for the size limit).
  , envDigest :: ~Text
  -- ^ Computed on first use, then kept.
  }

-- | Field equality, as the reference's dataclass compares (payloads by
-- Python value equality).
instance Eq Envelope where
  a == b =
    (a.envDeliveryId, a.envSender, a.envRecipient, a.envSource, a.envCorrelation, a.envReplyRoute)
      == (b.envDeliveryId, b.envSender, b.envRecipient, b.envSource, b.envCorrelation, b.envReplyRoute)
      && a.envPayload == b.envPayload

instance Show Envelope where
  showsPrec d e =
    showParen (d > 10) $
      showString "Envelope "
        . showsPrec 11 e.envDeliveryId
        . showChar ' '
        . showsPrec 11 e.envSender
        . showChar ' '
        . showsPrec 11 e.envRecipient
        . showChar ' '
        . showsPrec 11 e.envSource
        . showChar ' '
        . showsPrec 11 e.envCorrelation
        . showChar ' '
        . showsPrec 11 e.envPayload
        . showChar ' '
        . showsPrec 11 e.envReplyRoute

instance HasField "deliveryId" Envelope Text where getField e = e.envDeliveryId
instance HasField "sender" Envelope Text where getField e = e.envSender
instance HasField "recipient" Envelope Text where getField e = e.envRecipient
instance HasField "source" Envelope Text where getField e = e.envSource
instance HasField "correlation" Envelope Text where getField e = e.envCorrelation
-- | Always a JSON object.
instance HasField "payload" Envelope Json where getField e = e.envPayload
instance HasField "replyRoute" Envelope (Maybe ReplyRoute) where getField e = e.envReplyRoute
-- | SHA-256 hex of the canonical envelope JSON (§4.2.2).
instance HasField "digest" Envelope Text where getField e = e.envDigest
-- | @fabric:<code points of sender>:<sender>:<delivery_id>@ (§4.2.3).
instance HasField "ingressIdentity" Envelope Text where
  getField e = "fabric:" <> T.pack (show (T.length e.envSender)) <> ":" <> e.envSender <> ":" <> e.envDeliveryId

-- | @Envelope(delivery_id, sender, recipient, source, correlation, payload,
-- reply_route)@.
envelope :: Text -> Text -> Text -> Text -> Text -> Json -> Maybe ReplyRoute -> Either FabricError Envelope
envelope deliveryId sender recipient source correlation payload route = do
  deliveryId' <- fabricText "delivery_id" deliveryId
  sender' <- fabricText "sender" sender
  recipient' <- fabricText "recipient" recipient
  source' <- fabricText "source" source
  correlation' <- fabricText "correlation" correlation
  _ <- jsonObject "payload" payload
  payload' <- jsonCopy "payload" payload
  bytes <- canonicalBytes payload'
  let size = BS.length bytes
  if size > maxInlinePayloadBytes
    then
      Left
        ( InvalidValue
            ( "payload is "
                <> T.pack (show size)
                <> " canonical JSON bytes; inline fabric payloads are limited to "
                <> T.pack (show maxInlinePayloadBytes)
                <> " bytes \8212 use the artifact protocol and send a verified artifact reference"
            )
        )
    else
      let built = Envelope deliveryId' sender' recipient' source' correlation' payload' route bytes (digestOf built)
       in Right built

-- The canonical envelope assembled around the payload's canonical bytes:
-- the members in sorted order (§4.2.2).
digestOf :: Envelope -> Text
digestOf e =
  sha256Hex . BL.toStrict . B.toLazyByteString $
    "{\"correlation\":"
      <> canonicalString e.envCorrelation
      <> ",\"delivery_id\":"
      <> canonicalString e.envDeliveryId
      <> ",\"payload\":"
      <> B.byteString e.envPayloadBytes
      <> ",\"recipient\":"
      <> canonicalString e.envRecipient
      <> ",\"reply_route\":"
      <> maybe "null" route e.envReplyRoute
      <> ",\"sender\":"
      <> canonicalString e.envSender
      <> ",\"source\":"
      <> canonicalString e.envSource
      <> ",\"version\":1}"
  where
    route r = "{\"instance_id\":" <> canonicalString r.rrInstanceId <> ",\"source\":" <> canonicalString r.rrSource <> "}"

-- | The eight-member JSON form (§4.2), in the reference's member order.
envelopeToData :: Envelope -> Json
envelopeToData e =
  Object
    [ ("version", Int 1)
    , ("delivery_id", String e.envDeliveryId)
    , ("sender", String e.envSender)
    , ("recipient", String e.envRecipient)
    , ("source", String e.envSource)
    , ("correlation", String e.envCorrelation)
    , ("payload", e.envPayload)
    , ("reply_route", maybe Null replyRouteToData e.envReplyRoute)
    ]

-- | The member names of envelope version 1.
envelopeFields :: [Text]
envelopeFields = ["version", "delivery_id", "sender", "recipient", "source", "correlation", "payload", "reply_route"]

-- | @Envelope.from_data@: exact members, @version@ the integer 1 (§4.2).
envelopeFromData :: Json -> Either FabricError Envelope
envelopeFromData value = do
  members <- case value of
    Object ms
      | Map.keysSet m == expected -> Right m
      | otherwise ->
          let keys = Map.keysSet m
              missing = sort (Set.toList (Set.difference expected keys))
              unknown = sortOn pyRepr (Set.toList (Set.difference keys expected))
           in Left (shape missing unknown)
      where
        m = Map.fromList ms
    _ -> Left (shape (sort envelopeFields) [])
  case members Map.! "version" of
    Int 1 -> Right ()
    _ -> Left (InvalidValue "envelope version must be integer 1")
  _ <- jsonObject "payload" (members Map.! "payload")
  deliveryId <- textMember "delivery_id" (members Map.! "delivery_id")
  sender <- textMember "sender" (members Map.! "sender")
  recipient <- textMember "recipient" (members Map.! "recipient")
  source <- textMember "source" (members Map.! "source")
  correlation <- textMember "correlation" (members Map.! "correlation")
  route <- case members Map.! "reply_route" of
    Null -> Right Nothing
    other -> Just <$> replyRouteFromData other
  envelope deliveryId sender recipient source correlation (members Map.! "payload") route
  where
    expected = Set.fromList envelopeFields
    shape missing unknown =
      InvalidValue
        ("envelope requires exact version-1 fields (missing=" <> pyStrList missing <> ", unknown=" <> pyStrList unknown <> ")")

-- ---------------------------------------------------------------------------
-- Endpoint

-- | A discoverable service address (§4.3).
data Endpoint = Endpoint {epRecipient :: Text, epSource :: Text, epCapabilities :: Json}
  deriving stock (Eq, Show)

instance HasField "recipient" Endpoint Text where getField e = e.epRecipient
instance HasField "source" Endpoint Text where getField e = e.epSource
-- | Always a JSON object.
instance HasField "capabilities" Endpoint Json where getField e = e.epCapabilities

endpoint :: Text -> Text -> Json -> Either FabricError Endpoint
endpoint recipient source capabilities = do
  recipient' <- fabricText "recipient" recipient
  source' <- fabricText "source" source
  _ <- jsonObject "capabilities" capabilities
  Endpoint recipient' source' <$> jsonCopy "capabilities" capabilities

endpointToData :: Endpoint -> Json
endpointToData e = Object [("recipient", String e.epRecipient), ("source", String e.epSource), ("capabilities", e.epCapabilities)]

endpointFromData :: Json -> Either FabricError Endpoint
endpointFromData value = do
  members <-
    exactObject
      ["recipient", "source", "capabilities"]
      "endpoint must be an exact object with recipient, source, and capabilities"
      value
  _ <- jsonObject "capabilities" (members Map.! "capabilities")
  recipient <- textMember "recipient" (members Map.! "recipient")
  source <- textMember "source" (members Map.! "source")
  endpoint recipient source (members Map.! "capabilities")

-- ---------------------------------------------------------------------------
-- Results

-- | A delivery's state: the reference's strings @"pending"@ and
-- @"accepted"@.
data DeliveryState = Pending | Accepted
  deriving stock (Eq, Ord, Show)

deliveryStateText :: DeliveryState -> Text
deliveryStateText = \case
  Pending -> "pending"
  Accepted -> "accepted"

-- | The answer to a submission (§4.4).
data Submission = Submission
  { sender :: Text
  , deliveryId :: Text
  , state :: DeliveryState
  , duplicate :: Bool
  , occurrence :: Maybe Int
  , acceptedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show)

-- | A delivery's durable status (§4.5).
data Receipt = Receipt
  { sender :: Text
  , deliveryId :: Text
  , recipient :: Text
  , source :: Text
  , digest :: Text
  , state :: DeliveryState
  , occurrence :: Maybe Int
  , acceptedAt :: Maybe UTCTime
  , payloadRetained :: Bool
  }
  deriving stock (Eq, Show)

{-# LANGUAGE DataKinds #-}

-- | Strict provider-neutral values for proposing, fencing, and evidencing
-- Effects (@petrus.agenticus.effect.model@).
--
-- Every @to_data@ shape keeps the reference's key order, every decoder the
-- reference's refusal order, class, and message.  Where the reference checks
-- cross-field invariants at run time, the Haskell values make the invalid
-- combinations unrepresentable instead (see @divergences/effect.md@):
--
-- * 'LookupResult' is a sum whose only receipt-carrying case is
--   'LookupApplied';
-- * 'EffectEvidence' carries one 'EvidenceOutcome' instead of a
--   @(recovery, receipt_digest)@ pair;
-- * 'EffectDecision' is @Rejected | Approved fence | Concluded evidence@ and
--   its kind is derived from the evidence.
--
-- The upstream field views (@.recovery@, @.receiptDigest@, @.kind@,
-- @.fence@, @.evidence@, @.reasonCode@, @.disposition@, @.receipt@) remain
-- available as virtual record fields.
module Petrus.Agenticus.Effect.Model
  ( -- * Strict payloads
    PayloadValue (..)
  , EffectPayload (..)
  , payloadFromJson
  , payloadToJson
  , payloadValueToJson
  , canonicalPayload
  , digestPayload
  , digestPayloadJson
    -- * Grammars
  , schemaVersion
  , isCode
  , isDigest
    -- * Targets
  , TargetIdentity
  , mkTargetIdentity
  , targetToData
  , targetFromData
    -- * Proposals
  , EffectProposal
  , mkEffectProposal
  , proposalToData
  , proposalFromData
    -- * Fences
  , EffectFence
  , mkEffectFence
  , fenceToData
  , fenceFromData
  , matches
    -- * Receipts
  , EffectReceipt
  , mkEffectReceipt
  , receiptToData
  , receiptFromData
  , correlates
    -- * Lookups
  , LookupDisposition (..)
  , dispositionText
  , parseDisposition
  , LookupResult (..)
  , mkLookupResult
  , lookupToData
  , lookupFromData
    -- * Evidence
  , EvidenceOutcome (..)
  , outcomeRecovery
  , outcomeReceiptDigest
  , EffectEvidence
  , mkEffectEvidence
  , evidenceToData
  , evidenceFromData
    -- * Decisions
  , EffectDecisionKind (..)
  , decisionKindText
  , parseDecisionKind
  , EffectDecision
  , mkEffectDecision
  , reject
  , approve
  , concluded
  , decisionToData
  , decisionFromData
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as B
import Data.ByteString.Builder.Prim qualified as P
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import GHC.Records (HasField (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

schemaVersion :: Integer
schemaVersion = 1

-- ---------------------------------------------------------------------------
-- Strict payloads

-- | A strict JSON value: no floating-point numbers, string keys only.  The
-- reference rejects floats at run time (@_strict_json@); here they cannot be
-- written.  Objects are maps, so keys are unique (Python dict semantics) and
-- iterate in code-point order, the order @sort_keys=True@ writes.
data PayloadValue
  = PNull
  | PBool Bool
  | PInt Integer
  | PString Text
  | PArray [PayloadValue]
  | PObject (Map Text PayloadValue)
  deriving stock (Eq, Show)

-- | A strict JSON object: the only payload shape the reference accepts.
newtype EffectPayload = EffectPayload (Map Text PayloadValue)
  deriving stock (Eq, Show)

-- | @_payload_copy@: admit a decoded JSON value as an Effect payload, with
-- the reference's @TypeError@ refusals.  Duplicate members keep the last
-- value, like @json.loads@ building a dict.
payloadFromJson :: Json -> Either AgenticusError EffectPayload
payloadFromJson = \case
  Object members -> EffectPayload <$> traverse strict (Map.fromList members)
  _ -> Left (typeError "effect payload must be a strict JSON object")
  where
    strict = \case
      Null -> Right PNull
      Bool b -> Right (PBool b)
      Int i -> Right (PInt i)
      String s -> Right (PString s)
      Array items -> PArray <$> traverse strict items
      Object members -> PObject <$> traverse strict (Map.fromList members)
      Float _ ->
        Left
          ( typeError
              "effect payload must contain only strict JSON values; floating-point and extended Python values are forbidden"
          )

payloadToJson :: EffectPayload -> Json
payloadToJson (EffectPayload members) = payloadValueToJson (PObject members)

payloadValueToJson :: PayloadValue -> Json
payloadValueToJson = \case
  PNull -> Null
  PBool b -> Bool b
  PInt i -> Int i
  PString s -> String s
  PArray items -> Array (map payloadValueToJson items)
  PObject members -> Object [(k, payloadValueToJson v) | (k, v) <- Map.toAscList members]

-- | @_canonical(payload)@: @json.dumps(v, ensure_ascii=False,
-- sort_keys=True, separators=(",", ":")).encode()@, written directly from
-- the strict value (no float spelling, no sorting pass).
canonicalBuilder :: PayloadValue -> B.Builder
canonicalBuilder = \case
  PNull -> B.string7 "null"
  PBool True -> B.string7 "true"
  PBool False -> B.string7 "false"
  PInt i -> B.integerDec i
  PString s -> quoted s
  PArray [] -> B.string7 "[]"
  PArray (x : xs) -> B.char7 '[' <> canonicalBuilder x <> foldr (\y rest -> B.char7 ',' <> canonicalBuilder y <> rest) (B.char7 ']') xs
  PObject members -> case Map.toAscList members of
    [] -> B.string7 "{}"
    (k, v) : rest ->
      B.char7 '{' <> pair k v <> foldr (\(k', v') acc -> B.char7 ',' <> pair k' v' <> acc) (B.char7 '}') rest
  where
    pair k v = quoted k <> B.char7 ':' <> canonicalBuilder v

-- | A JSON string literal as @json.dumps(..., ensure_ascii=False)@ writes it.
-- UTF-8 continuation and lead bytes are all @>= 0x80@, so escaping is a
-- per-byte decision.
quoted :: Text -> B.Builder
quoted s = B.char7 '"' <> TE.encodeUtf8BuilderEscaped escapeByte s <> B.char7 '"'

escapeByte :: P.BoundedPrim Word8
escapeByte =
  P.condB (\w -> w >= 0x20 && w /= 0x22 && w /= 0x5c) (P.liftFixedToBounded P.word8) $
    P.condB (== 0x22) (short 0x22) $
      P.condB (== 0x5c) (short 0x5c) $
        P.condB (== 0x0a) (short 0x6e) $
          P.condB (== 0x0d) (short 0x72) $
            P.condB (== 0x09) (short 0x74) $
              P.condB (== 0x08) (short 0x62) $
                P.condB (== 0x0c) (short 0x66) $
                  P.liftFixedToBounded (unicode P.>$< fixed6)
  where
    short :: Word8 -> P.BoundedPrim Word8
    short c = P.liftFixedToBounded (const (0x5c, c) P.>$< P.word8 P.>*< P.word8)
    fixed6 = P.word8 P.>*< P.word8 P.>*< P.word8 P.>*< P.word8 P.>*< P.word8 P.>*< P.word8
    unicode w = (0x5c, (0x75, (0x30, (0x30, (hex (w `shiftR` 4), hex (w .&. 0x0f))))))
    hex n = if n < 10 then 0x30 + n else 0x57 + n

-- | The canonical bytes of a payload.
canonicalPayload :: EffectPayload -> ByteString
canonicalPayload (EffectPayload members) = BL.toStrict (B.toLazyByteString (canonicalBuilder (PObject members)))

-- | @digest_payload@ for an already-strict payload.
digestPayload :: EffectPayload -> Text
digestPayload (EffectPayload members) =
  "sha256:" <> T.pack (show (hashlazy (B.toLazyByteString (canonicalBuilder (PObject members))) :: Digest SHA256))

-- | @digest_payload(payload)@ over a decoded JSON value.
digestPayloadJson :: Json -> Either AgenticusError Text
digestPayloadJson = fmap digestPayload . payloadFromJson

-- ---------------------------------------------------------------------------
-- Field grammars and messages

-- | @[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*@, matched in full.
isCode :: Text -> Bool
isCode value = case T.uncons value of
  Just (c, rest) | lower c -> segment rest
  _ -> False
  where
    lower c = c >= 'a' && c <= 'z'
    alnum c = lower c || (c >= '0' && c <= '9')
    segment s = case T.uncons (T.dropWhile alnum s) of
      Nothing -> True
      Just (sep, more)
        | sep == '.' || sep == '_' || sep == '-'
        , Just (c, _) <- T.uncons more
        , alnum c ->
            segment more
      _ -> False

-- | @sha256:[0-9a-f]{64}@, matched in full.
isDigest :: Text -> Bool
isDigest value = case T.stripPrefix "sha256:" value of
  Just hex -> T.length hex == 64 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) hex
  Nothing -> False

textError :: Text -> AgenticusError
textError name = valueError (name <> " must be a non-empty, trimmed string of at most 256 UTF-8 bytes")

-- | @_text(value, name)@.
text :: Text -> Text -> Either AgenticusError Text
text name = checkedText maxTextBytes (textError name)

-- | @_code(value, name)@.
code :: Text -> Text -> Either AgenticusError Text
code name value = do
  _ <- text name value
  if isCode value then Right value else Left (valueError (name <> " must be a lowercase dotted, dashed, or underscored code"))

-- | @_positive_integer(value, name)@.
positive :: Text -> Integer -> Either AgenticusError Integer
positive name value
  | value > 0 = Right value
  | otherwise = Left (valueError (name <> " must be a positive integer"))

-- | @_digest(value, name)@.
digestField :: Text -> Text -> Either AgenticusError Text
digestField name value
  | isDigest value = Right value
  | otherwise = Left (valueError (name <> " must be a lowercase SHA-256 digest"))

-- Decoding counterparts over raw JSON members.

textJ :: Text -> Json -> Either AgenticusError Text
textJ name = \case
  String value -> text name value
  _ -> Left (textError name)

codeJ :: Text -> Json -> Either AgenticusError Text
codeJ name = \case
  String value -> code name value
  _ -> Left (textError name)

positiveJ :: Text -> Json -> Either AgenticusError Integer
positiveJ name = \case
  Int value -> positive name value
  _ -> Left (valueError (name <> " must be a positive integer"))

digestJ :: Text -> Json -> Either AgenticusError Text
digestJ name = \case
  String value -> digestField name value
  _ -> Left (valueError (name <> " must be a lowercase SHA-256 digest"))

-- | @type(data["schema_version"]) is not int or data["schema_version"] != 1@.
versioned :: Text -> Fields -> Either AgenticusError ()
versioned subject fields = case member "schema_version" fields of
  Int 1 -> Right ()
  _ -> Left (valueError (subject <> " schema_version must be integer 1"))

exact :: [Text] -> Text -> Json -> Either AgenticusError Fields
exact fields message = exactObject fields (valueError message)

-- | SHA-256 over the canonical bytes of a @to_data()@ value (no floats).
canonicalDigest :: Json -> Text
canonicalDigest value = "sha256:" <> sha256Hex (canonicalBytes value)

-- ---------------------------------------------------------------------------
-- Targets

-- | Host-defined external target identity with no provider-specific type.
data TargetIdentity = TargetIdentity
  { _targetType :: Text
  , _targetId :: Text
  }
  deriving stock (Eq, Ord, Show)

instance HasField "targetType" TargetIdentity Text where
  getField r = r._targetType

instance HasField "targetId" TargetIdentity Text where
  getField r = r._targetId

mkTargetIdentity :: Text -> Text -> Either AgenticusError TargetIdentity
mkTargetIdentity targetType targetId =
  TargetIdentity <$> code "target type" targetType <*> text "target id" targetId

targetToData :: TargetIdentity -> Json
targetToData t = Object [("target_type", String t.targetType), ("target_id", String t.targetId)]

targetFromData :: Json -> Either AgenticusError TargetIdentity
targetFromData json = do
  fields <- exact ["target_type", "target_id"] "target identity requires exact target_type and target_id fields" json
  TargetIdentity <$> codeJ "target type" (member "target_type" fields) <*> textJ "target id" (member "target_id" fields)

-- ---------------------------------------------------------------------------
-- Proposals

-- | One secret-free proposal identity; a host keeps the raw payload
-- separately.  'digest' (@EffectProposal.digest@) is computed once, on first
-- use.
data EffectProposal = EffectProposal
  { _proposalId :: Text
  , _effectType :: Text
  , _effectVersion :: Integer
  , _payloadDigest :: Text
  , _target :: TargetIdentity
  , _requestedAuthorityClass :: Text
  , _digest :: ~Text
  -- ^ Binds approval and evidence to every exact field of this proposal.
  }
  deriving stock (Show)

instance HasField "proposalId" EffectProposal Text where
  getField r = r._proposalId

instance HasField "effectType" EffectProposal Text where
  getField r = r._effectType

instance HasField "effectVersion" EffectProposal Integer where
  getField r = r._effectVersion

instance HasField "payloadDigest" EffectProposal Text where
  getField r = r._payloadDigest

instance HasField "target" EffectProposal TargetIdentity where
  getField r = r._target

instance HasField "requestedAuthorityClass" EffectProposal Text where
  getField r = r._requestedAuthorityClass

instance HasField "digest" EffectProposal Text where
  getField r = r._digest

-- | Field equality; the cached digest is a function of the fields.
instance Eq EffectProposal where
  a == b =
    a.proposalId == b.proposalId
      && a.effectType == b.effectType
      && a.effectVersion == b.effectVersion
      && a.payloadDigest == b.payloadDigest
      && a.target == b.target
      && a.requestedAuthorityClass == b.requestedAuthorityClass

mkEffectProposal :: Text -> Text -> Integer -> Text -> TargetIdentity -> Text -> Either AgenticusError EffectProposal
mkEffectProposal proposalId effectType effectVersion payloadDigest target authority =
  proposal
    <$> text "proposal id" proposalId
    <*> code "effect type" effectType
    <*> positive "effect version" effectVersion
    <*> digestField "payload digest" payloadDigest
    <*> pure target
    <*> code "requested authority class" authority

-- | Assemble a validated proposal and attach its lazily computed digest.
proposal :: Text -> Text -> Integer -> Text -> TargetIdentity -> Text -> EffectProposal
proposal pid etype version pdigest tgt authority =
  let value = EffectProposal pid etype version pdigest tgt authority (canonicalDigest (proposalToData value))
   in value

proposalToData :: EffectProposal -> Json
proposalToData p =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("proposal_id", String p.proposalId)
    , ("effect_type", String p.effectType)
    , ("effect_version", Int p.effectVersion)
    , ("payload_digest", String p.payloadDigest)
    , ("target", targetToData p.target)
    , ("requested_authority_class", String p.requestedAuthorityClass)
    ]

proposalFromData :: Json -> Either AgenticusError EffectProposal
proposalFromData json = do
  fields <-
    exact
      ["schema_version", "proposal_id", "effect_type", "effect_version", "payload_digest", "target", "requested_authority_class"]
      "effect proposal requires exact version-1 fields"
      json
  versioned "effect proposal" fields
  proposal
    <$> textJ "proposal id" (member "proposal_id" fields)
    <*> codeJ "effect type" (member "effect_type" fields)
    <*> positiveJ "effect version" (member "effect_version" fields)
    <*> digestJ "payload digest" (member "payload_digest" fields)
    <*> targetFromData (member "target" fields)
    <*> codeJ "requested authority class" (member "requested_authority_class" fields)

-- ---------------------------------------------------------------------------
-- Fences

-- | Frozen proposal, authority, target, Episode, and attachment
-- preconditions.
data EffectFence = EffectFence
  { _proposalId :: Text
  , _proposalDigest :: Text
  , _authorityEpoch :: Integer
  , _targetHead :: Text
  , _episodeId :: Text
  , _attachmentId :: Text
  , _attachmentEpoch :: Integer
  }
  deriving stock (Eq, Show)

instance HasField "proposalId" EffectFence Text where
  getField r = r._proposalId

instance HasField "proposalDigest" EffectFence Text where
  getField r = r._proposalDigest

instance HasField "authorityEpoch" EffectFence Integer where
  getField r = r._authorityEpoch

instance HasField "targetHead" EffectFence Text where
  getField r = r._targetHead

instance HasField "episodeId" EffectFence Text where
  getField r = r._episodeId

instance HasField "attachmentId" EffectFence Text where
  getField r = r._attachmentId

instance HasField "attachmentEpoch" EffectFence Integer where
  getField r = r._attachmentEpoch

-- | The constructor, validating in @__post_init__@ order.
mkEffectFence :: Text -> Text -> Integer -> Text -> Text -> Text -> Integer -> Either AgenticusError EffectFence
mkEffectFence pid pdigest authorityEpoch targetHead episodeId attachmentId attachmentEpoch = do
  pid' <- text "proposal id" pid
  targetHead' <- text "target head" targetHead
  episodeId' <- text "episode id" episodeId
  attachmentId' <- text "attachment id" attachmentId
  pdigest' <- digestField "proposal digest" pdigest
  authority' <- positive "authority epoch" authorityEpoch
  attachmentEpoch' <- positive "attachment epoch" attachmentEpoch
  pure (EffectFence pid' pdigest' authority' targetHead' episodeId' attachmentId' attachmentEpoch')

fenceToData :: EffectFence -> Json
fenceToData f =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("proposal_id", String f.proposalId)
    , ("proposal_digest", String f.proposalDigest)
    , ("authority_epoch", Int f.authorityEpoch)
    , ("target_head", String f.targetHead)
    , ("episode_id", String f.episodeId)
    , ("attachment_id", String f.attachmentId)
    , ("attachment_epoch", Int f.attachmentEpoch)
    ]

fenceFromData :: Json -> Either AgenticusError EffectFence
fenceFromData json = do
  fields <-
    exact
      ["schema_version", "proposal_id", "proposal_digest", "authority_epoch", "target_head", "episode_id", "attachment_id", "attachment_epoch"]
      "effect fence requires exact version-1 fields"
      json
  versioned "effect fence" fields
  EffectFence
    <$> textJ "proposal id" (member "proposal_id" fields)
    <*> digestJ "proposal digest" (member "proposal_digest" fields)
    <*> positiveJ "authority epoch" (member "authority_epoch" fields)
    <*> textJ "target head" (member "target_head" fields)
    <*> textJ "episode id" (member "episode_id" fields)
    <*> textJ "attachment id" (member "attachment_id" fields)
    <*> positiveJ "attachment epoch" (member "attachment_epoch" fields)

-- | @fence.matches(proposal)@.
matches :: EffectFence -> EffectProposal -> Bool
matches f p = f.proposalId == p.proposalId && f.proposalDigest == p.digest

-- ---------------------------------------------------------------------------
-- Receipts

-- | Digest-only provider evidence correlated to one complete proposal
-- identity.
data EffectReceipt = EffectReceipt
  { _proposalId :: Text
  , _proposalDigest :: Text
  , _payloadDigest :: Text
  , _target :: TargetIdentity
  , _receiptDigest :: Text
  }
  deriving stock (Eq, Show)

instance HasField "proposalId" EffectReceipt Text where
  getField r = r._proposalId

instance HasField "proposalDigest" EffectReceipt Text where
  getField r = r._proposalDigest

instance HasField "payloadDigest" EffectReceipt Text where
  getField r = r._payloadDigest

instance HasField "target" EffectReceipt TargetIdentity where
  getField r = r._target

instance HasField "receiptDigest" EffectReceipt Text where
  getField r = r._receiptDigest

mkEffectReceipt :: Text -> Text -> Text -> TargetIdentity -> Text -> Either AgenticusError EffectReceipt
mkEffectReceipt pid pdigest payload tgt receipt =
  EffectReceipt
    <$> text "proposal id" pid
    <*> digestField "proposal digest" pdigest
    <*> digestField "payload digest" payload
    <*> pure tgt
    <*> digestField "receipt digest" receipt

-- | @receipt.correlates(proposal)@.
correlates :: EffectReceipt -> EffectProposal -> Bool
correlates r p =
  r.proposalId == p.proposalId
    && r.proposalDigest == p.digest
    && r.payloadDigest == p.payloadDigest
    && r.target == p.target

receiptToData :: EffectReceipt -> Json
receiptToData r =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("proposal_id", String r.proposalId)
    , ("proposal_digest", String r.proposalDigest)
    , ("payload_digest", String r.payloadDigest)
    , ("target", targetToData r.target)
    , ("receipt_digest", String r.receiptDigest)
    ]

receiptFromData :: Json -> Either AgenticusError EffectReceipt
receiptFromData json = do
  fields <-
    exact
      ["schema_version", "proposal_id", "proposal_digest", "payload_digest", "target", "receipt_digest"]
      "effect receipt requires exact version-1 fields"
      json
  versioned "effect receipt" fields
  EffectReceipt
    <$> textJ "proposal id" (member "proposal_id" fields)
    <*> digestJ "proposal digest" (member "proposal_digest" fields)
    <*> digestJ "payload digest" (member "payload_digest" fields)
    <*> targetFromData (member "target" fields)
    <*> digestJ "receipt digest" (member "receipt_digest" fields)

-- ---------------------------------------------------------------------------
-- Lookups

-- | A lookup- or fence-derived recovery classification before any retry.
data LookupDisposition
  = Applied
  | SafeToRetry
  | Superseded
  | Indeterminate
  deriving stock (Eq, Ord, Show, Enum, Bounded)

dispositionText :: LookupDisposition -> Text
dispositionText = \case
  Applied -> "applied"
  SafeToRetry -> "safe-to-retry"
  Superseded -> "superseded"
  Indeterminate -> "indeterminate"

-- | @LookupDisposition(value)@ for a decoded JSON value.
parseDisposition :: Json -> Maybe LookupDisposition
parseDisposition = \case
  String value -> lookup value [(dispositionText d, d) | d <- [minBound .. maxBound]]
  _ -> Nothing

-- | A lookup proof; only 'LookupApplied' carries a (correlated) receipt.
data LookupResult
  = LookupApplied EffectReceipt
  | LookupSafeToRetry
  | LookupSuperseded
  | LookupIndeterminate
  deriving stock (Eq, Show)

instance HasField "disposition" LookupResult LookupDisposition where
  getField = \case
    LookupApplied _ -> Applied
    LookupSafeToRetry -> SafeToRetry
    LookupSuperseded -> Superseded
    LookupIndeterminate -> Indeterminate

instance HasField "receipt" LookupResult (Maybe EffectReceipt) where
  getField = \case
    LookupApplied receipt -> Just receipt
    _ -> Nothing

-- | @LookupResult(disposition, receipt)@.
mkLookupResult :: LookupDisposition -> Maybe EffectReceipt -> Either AgenticusError LookupResult
mkLookupResult disposition receipt = case (disposition, receipt) of
  (Applied, Just r) -> Right (LookupApplied r)
  (SafeToRetry, Nothing) -> Right LookupSafeToRetry
  (Superseded, Nothing) -> Right LookupSuperseded
  (Indeterminate, Nothing) -> Right LookupIndeterminate
  _ -> Left (valueError "only an applied lookup requires an EffectReceipt")

lookupToData :: LookupResult -> Json
lookupToData result =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("disposition", String (dispositionText result.disposition))
    , ("receipt", maybe Null receiptToData result.receipt)
    ]

lookupFromData :: Json -> Either AgenticusError LookupResult
lookupFromData json = do
  fields <- exact ["schema_version", "disposition", "receipt"] "lookup result requires exact version-1 fields" json
  versioned "lookup result" fields
  disposition <- maybe (Left (valueError "lookup disposition is not supported")) Right (parseDisposition (member "disposition" fields))
  receipt <- case member "receipt" fields of
    Null -> Right Nothing
    raw -> Just <$> receiptFromData raw
  mkLookupResult disposition receipt

-- ---------------------------------------------------------------------------
-- Evidence

-- | How an Effect concluded: direct execution and an applied lookup carry
-- the receipt digest; the other recoveries cannot.
data EvidenceOutcome
  = DirectExecution Text
  | RecoveredApplied Text
  | RecoveredSafeToRetry
  | RecoveredSuperseded
  | RecoveredIndeterminate
  deriving stock (Eq, Show)

-- | The reference's @recovery@ field ('Nothing' for direct execution).
outcomeRecovery :: EvidenceOutcome -> Maybe LookupDisposition
outcomeRecovery = \case
  DirectExecution _ -> Nothing
  RecoveredApplied _ -> Just Applied
  RecoveredSafeToRetry -> Just SafeToRetry
  RecoveredSuperseded -> Just Superseded
  RecoveredIndeterminate -> Just Indeterminate

-- | The reference's @receipt_digest@ field.
outcomeReceiptDigest :: EvidenceOutcome -> Maybe Text
outcomeReceiptDigest = \case
  DirectExecution receipt -> Just receipt
  RecoveredApplied receipt -> Just receipt
  _ -> Nothing

-- | Secret-free exact correlation and lookup- or fence-derived recovery
-- evidence.
data EffectEvidence = EffectEvidence
  { _proposalId :: Text
  , _proposalDigest :: Text
  , _payloadDigest :: Text
  , _target :: TargetIdentity
  , _fence :: EffectFence
  , _outcome :: EvidenceOutcome
  }
  deriving stock (Eq, Show)

instance HasField "proposalId" EffectEvidence Text where
  getField r = r._proposalId

instance HasField "proposalDigest" EffectEvidence Text where
  getField r = r._proposalDigest

instance HasField "payloadDigest" EffectEvidence Text where
  getField r = r._payloadDigest

instance HasField "target" EffectEvidence TargetIdentity where
  getField r = r._target

instance HasField "fence" EffectEvidence EffectFence where
  getField r = r._fence

instance HasField "outcome" EffectEvidence EvidenceOutcome where
  getField r = r._outcome

instance HasField "recovery" EffectEvidence (Maybe LookupDisposition) where
  getField e = outcomeRecovery e.outcome

instance HasField "receiptDigest" EffectEvidence (Maybe Text) where
  getField e = outcomeReceiptDigest e.outcome

-- | @EffectEvidence(proposal_id, proposal_digest, payload_digest, target,
-- fence, recovery, receipt_digest)@ with the constructor's checks in order.
mkEffectEvidence
  :: Text -> Text -> Text -> TargetIdentity -> EffectFence -> Maybe LookupDisposition -> Maybe Text -> Either AgenticusError EffectEvidence
mkEffectEvidence pid pdigest payload tgt f recovery receipt = do
  pid' <- text "proposal id" pid
  pdigest' <- digestField "proposal digest" pdigest
  payload' <- digestField "payload digest" payload
  require (f.proposalId == pid' && f.proposalDigest == pdigest') (valueError "effect evidence fence does not match its proposal")
  receipt' <- traverse (digestField "receipt digest") receipt
  result <- case (recovery, receipt') of
    (Just Applied, Nothing) -> Left (valueError "applied evidence requires a receipt digest")
    (Just Applied, Just r) -> Right (RecoveredApplied r)
    (Just _, Just _) -> Left (valueError "non-applied recovery evidence cannot carry a receipt digest")
    (Nothing, Nothing) -> Left (valueError "direct execution evidence requires a receipt digest")
    (Nothing, Just r) -> Right (DirectExecution r)
    (Just SafeToRetry, Nothing) -> Right RecoveredSafeToRetry
    (Just Superseded, Nothing) -> Right RecoveredSuperseded
    (Just Indeterminate, Nothing) -> Right RecoveredIndeterminate
  pure (EffectEvidence pid' pdigest' payload' tgt f result)

evidenceToData :: EffectEvidence -> Json
evidenceToData e =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("proposal_id", String e.proposalId)
    , ("proposal_digest", String e.proposalDigest)
    , ("payload_digest", String e.payloadDigest)
    , ("target", targetToData e.target)
    , ("fence", fenceToData e.fence)
    , ("recovery", maybe Null (String . dispositionText) e.recovery)
    , ("receipt_digest", maybe Null String e.receiptDigest)
    ]

evidenceFromData :: Json -> Either AgenticusError EffectEvidence
evidenceFromData json = do
  fields <-
    exact
      ["schema_version", "proposal_id", "proposal_digest", "payload_digest", "target", "fence", "recovery", "receipt_digest"]
      "effect evidence requires exact version-1 fields"
      json
  versioned "effect evidence" fields
  recovery <- case member "recovery" fields of
    Null -> Right Nothing
    raw -> maybe (Left (valueError "effect evidence recovery is not supported")) (Right . Just) (parseDisposition raw)
  receipt <- case member "receipt_digest" fields of
    Null -> Right Nothing
    raw -> Just <$> digestJ "receipt digest" raw
  pid <- textJ "proposal id" (member "proposal_id" fields)
  pdigest <- digestJ "proposal digest" (member "proposal_digest" fields)
  payload <- digestJ "payload digest" (member "payload_digest" fields)
  tgt <- targetFromData (member "target" fields)
  f <- fenceFromData (member "fence" fields)
  mkEffectEvidence pid pdigest payload tgt f recovery receipt

-- ---------------------------------------------------------------------------
-- Decisions

-- | Complete host decision vocabulary for a proposal lifecycle.
data EffectDecisionKind
  = DecisionReject
  | DecisionApprove
  | DecisionExecute
  | DecisionAlreadyApplied
  | DecisionSuperseded
  | DecisionIndeterminate
  deriving stock (Eq, Ord, Show, Enum, Bounded)

decisionKindText :: EffectDecisionKind -> Text
decisionKindText = \case
  DecisionReject -> "reject"
  DecisionApprove -> "approve"
  DecisionExecute -> "execute"
  DecisionAlreadyApplied -> "already-applied"
  DecisionSuperseded -> "superseded"
  DecisionIndeterminate -> "indeterminate"

parseDecisionKind :: Json -> Maybe EffectDecisionKind
parseDecisionKind = \case
  String value -> lookup value [(decisionKindText k, k) | k <- [minBound .. maxBound]]
  _ -> Nothing

-- | One exact host decision.  A rejection carries only its proposal
-- coordinates and reason code; an approval only its fence (whose proposal
-- coordinates are the decision's); an outcome only its evidence (whose
-- fence and coordinates are the decision's).
data EffectDecision
  = Rejected Text Text Text
  | Approved EffectFence
  | Concluded EffectEvidence
  deriving stock (Eq, Show)

instance HasField "kind" EffectDecision EffectDecisionKind where
  getField = \case
    Rejected {} -> DecisionReject
    Approved _ -> DecisionApprove
    Concluded e -> case e.outcome of
      DirectExecution _ -> DecisionExecute
      RecoveredApplied _ -> DecisionAlreadyApplied
      RecoveredSuperseded -> DecisionSuperseded
      RecoveredSafeToRetry -> DecisionIndeterminate
      RecoveredIndeterminate -> DecisionIndeterminate

instance HasField "proposalId" EffectDecision Text where
  getField = \case
    Rejected pid _ _ -> pid
    Approved f -> f.proposalId
    Concluded e -> e.proposalId

instance HasField "proposalDigest" EffectDecision Text where
  getField = \case
    Rejected _ pdigest _ -> pdigest
    Approved f -> f.proposalDigest
    Concluded e -> e.proposalDigest

instance HasField "fence" EffectDecision (Maybe EffectFence) where
  getField = \case
    Rejected {} -> Nothing
    Approved f -> Just f
    Concluded e -> Just e.fence

instance HasField "evidence" EffectDecision (Maybe EffectEvidence) where
  getField = \case
    Concluded e -> Just e
    _ -> Nothing

instance HasField "reasonCode" EffectDecision (Maybe Text) where
  getField = \case
    Rejected _ _ reason -> Just reason
    _ -> Nothing

-- | @EffectDecision(kind, proposal_id, proposal_digest, fence, evidence,
-- reason_code)@ with the constructor's checks in order.
mkEffectDecision
  :: EffectDecisionKind -> Text -> Text -> Maybe EffectFence -> Maybe EffectEvidence -> Maybe Text -> Either AgenticusError EffectDecision
mkEffectDecision kind pid pdigest fence evidence reason = do
  pid' <- text "proposal id" pid
  pdigest' <- digestField "proposal digest" pdigest
  reason' <- traverse (code "reason code") reason
  case kind of
    DecisionReject -> case (reason', fence, evidence) of
      (Just r, Nothing, Nothing) -> Right (Rejected pid' pdigest' r)
      _ -> Left (valueError "reject requires only a secret-free reason code")
    DecisionApprove -> case (fence, evidence, reason') of
      (Just f, Nothing, Nothing) -> do
        fenceCorrelates f pid' pdigest'
        Right (Approved f)
      _ -> Left (valueError "approve requires exactly one fence")
    _ -> case (fence, evidence, reason') of
      (Just f, Just e, Nothing) -> do
        require (e.recovery `elem` expectedRecovery kind) (valueError "effect evidence recovery does not match the decision kind")
        fenceCorrelates f pid' pdigest'
        require
          (e.proposalId == pid' && e.proposalDigest == pdigest' && e.fence == f)
          (valueError "effect decision evidence does not match its proposal and fence")
        Right (Concluded e)
      _ -> Left (valueError "execution decisions require exact fence and evidence values")
  where
    fenceCorrelates f pid' pdigest' =
      require (f.proposalId == pid' && f.proposalDigest == pdigest') (valueError "effect decision fence does not match its proposal")
    expectedRecovery = \case
      DecisionExecute -> [Nothing]
      DecisionAlreadyApplied -> [Just Applied]
      DecisionSuperseded -> [Just Superseded]
      _ -> [Just SafeToRetry, Just Indeterminate]

-- | @EffectDecision.reject(proposal, reason_code)@.
reject :: EffectProposal -> Text -> Either AgenticusError EffectDecision
reject p reason = mkEffectDecision DecisionReject p.proposalId p.digest Nothing Nothing (Just reason)

-- | @EffectDecision.approve(proposal, fence)@.
approve :: EffectProposal -> EffectFence -> Either AgenticusError EffectDecision
approve p f
  | matches f p = mkEffectDecision DecisionApprove p.proposalId p.digest (Just f) Nothing Nothing
  | otherwise = Left (valueError "approval fence does not match the proposal")

-- | The outcome decision for evidence: total, since evidence already
-- correlates with its fence and proposal.
concluded :: EffectEvidence -> EffectDecision
concluded = Concluded

decisionToData :: EffectDecision -> Json
decisionToData d =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("kind", String (decisionKindText d.kind))
    , ("proposal_id", String d.proposalId)
    , ("proposal_digest", String d.proposalDigest)
    , ("fence", maybe Null fenceToData d.fence)
    , ("evidence", maybe Null evidenceToData d.evidence)
    , ("reason_code", maybe Null String d.reasonCode)
    ]

decisionFromData :: Json -> Either AgenticusError EffectDecision
decisionFromData json = do
  fields <-
    exact
      ["schema_version", "kind", "proposal_id", "proposal_digest", "fence", "evidence", "reason_code"]
      "effect decision requires exact version-1 fields"
      json
  versioned "effect decision" fields
  kind <- maybe (Left (valueError "effect decision kind is not supported")) Right (parseDecisionKind (member "kind" fields))
  pid <- textJ "proposal id" (member "proposal_id" fields)
  pdigest <- digestJ "proposal digest" (member "proposal_digest" fields)
  fence <- optional fenceFromData (member "fence" fields)
  evidence <- optional evidenceFromData (member "evidence" fields)
  reason <- optional (codeJ "reason code") (member "reason_code" fields)
  mkEffectDecision kind pid pdigest fence evidence reason
  where
    optional decode = \case
      Null -> Right Nothing
      raw -> Just <$> decode raw

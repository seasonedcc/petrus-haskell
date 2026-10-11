-- | The implementation of "Petrus.Agenticus.Runtime.Pi". Besides its public
-- interface it exports what the tests and the differential corpus reach:
-- adapter internals (the reference's private attributes, for tests).
-- pure protocol pieces (exposed for the differential corpus).
--
-- Not a stable interface: other code imports "Petrus.Agenticus.Runtime.Pi".
module Petrus.Agenticus.Runtime.Pi.Internal
  ( -- * Pins and catalogs
    piSdkVersion
  , piSdkSourceCommit
  , piAiVersion
  , piSourceCommit
  , piSdkSource
  , piAiSource
  , piCcPatchVersion
  , piCcPatchSourceCommit
  , piCcPatchSource
  , piApiKeyCatalog
  , piSubscriptionCatalog
  , piCcPatchSubscriptionCatalog
    -- * Descriptors
  , piContinuationDescriptor
  , piProgram
  , piProgramCapabilities
  , piContinuationCapabilities
  , piConnectionCapabilities
  , piSubscriptionConnectionCapabilities
  , piCcPatchConnectionCapabilities
  , piCollocatedHands
  , piCapabilityScopedHands
  , piLocalTerritory
  , piGondolinTerritory
  , piE2bTerritory
  , piToolSchemas
    -- * Continuation payloads
  , PiContinuationPayloadV1 (sessionId, workingDirectoryBinding, sessionJsonl)
  , mkPiContinuationPayloadV1
  , payloadSchemaVersion
  , PiContinuationOperations (..)
  , PiTurnOperations (..)
  , PiContinuationCodec
  , piContinuationCodec
  , codecStore
  , codecLoad
    -- * Configuration and invocations
  , PiRuntimeConfig (..)
  , piRuntimeConfig
  , newPiRuntimeConfig
  , renderPiRuntimeConfig
  , PiRuntimeInvocation (..)
  , newPiRuntimeInvocation
  , renderPiRuntimeInvocation
  , piDurableWorkFingerprint
  , piDurableFingerprint
    -- * Connection custody
    -- * Helper clients
  , PiCandidate (..)
  , PiHelperResult (..)
  , PiHelperClient (..)
  , PiHelperArgs (..)
  , PiHelperFactory (..)
  , subprocessFactory
  , SubprocessClient
  , SubprocessOptions (..)
  , subprocessOptions
  , newSubprocessClient
  , newSubprocessClientWith
  , subprocessClient
  , subprocessStartFrame
  , piHelperPath
    -- * Operations
  , PiOperation
  , piOperationId
  , piOperationReceipt
  , piOperationClosed
  , waitPiOperation
  , cancelPiOperation
  , closePiOperation
  , piRuntimeOperation
    -- * The adapter
  , PiRuntimeAdapter
  , newPiRuntimeAdapter
  , PiAdapterOptions (..)
  , piAdapterOptions
  , newPiRuntimeAdapterWith
  , adapterConfig
  , adapterDescriptor
  , adapterHands
  , adapterTerritory
  , adapterProgram
  , adapterContinuationDescriptor
  , adapterRuntimeCapabilities
  , renderPiRuntimeAdapter
  , probe
  , ProbePaths (..)
  , probePaths
  , enableScriptedConformance
  , startPi
  , evictPi
  , receiptPi
    -- * Adapter internals (the reference's private attributes, for tests)
  , PiAdapterRuntime (..)
  , readAdapterRuntime
  , PiAdapterHooks (..)
  , noHooks
  , adapterBindingCurrent
  , adapterOperationIds
    -- * Pure protocol pieces (exposed for the differential corpus)
  , piText
  , piUuid
  , canonicalUuid
  , strictLoad
  , strictFrameLoad
  , validateNativeAuth
  , decodeNativeAuth
  , validateSession
  , workingBinding
  , pyB64DecodeStrict
  , pyB64DecodeText
  , b64Encode
  , compactBytes
  , frameBytes
  , startFrame
  , maxPrompt
  , maxKey
  ) where

import Control.Concurrent.MVar
import Control.Exception
  ( IOException
  , SomeException
  , catch
  , fromException
  , mask_
  , throwIO
  , try
  )
import Control.Monad (forM_, unless, when)
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit, isHexDigit, isLower)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import GHC.Clock (getMonotonicTime)
import Numeric (showHex)
import Paths_petrus_agenticus_runtime (getDataFileName)
import Petrus.Agenticus.Attachment.Binding
  ( AttachmentBinding (..)
  , AttachmentCoordinates (..)
  , bindingExecution
  , bindingLeaseIdentity
  , bindingProvider
  )
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor
  ( CapabilityDescriptor (..)
  , DescriptorIdentity (..)
  , DescriptorKind (..)
  , capabilityDescriptor
  , descriptorIdentity
  )
import Petrus.Agenticus.Catalog.Resolution (snapshotDescriptor)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionIdentity (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , PublicationResult (..)
  , ReleaseResult (..)
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error hiding (ValueError)
import Petrus.Agenticus.Error qualified as E
import Petrus.Agenticus.Hands.Contract
  ( ToolMethod (..)
  , ToolResult
  , allToolMethods
  , maxArgvPartChars
  , maxArgvParts
  , maxContentChars
  , maxCwdChars
  , maxPathChars
  , maxQueryChars
  , toolMethodText
  , toolResultToModelData
  )
import Petrus.Agenticus.Hands.Gateway (HandsGateway, gatewayAttachmentEpoch, gatewayAttachmentId, gatewayEpisodeId)
import Petrus.Agenticus.Hands.Gateway qualified as Gateway
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), currentGrant)
import Petrus.Agenticus.Internal.Exception
import Petrus.Agenticus.Internal.PyRepr (pyStrRepr)
import Petrus.Agenticus.Internal.Validate (encodeRefusal, isBoundedText, isTrimmed, sha256Hex, utf8Length)
import Petrus.Agenticus.Program.Descriptor
  ( AgentProgramDescriptor
  , ProgramOwnership (..)
  , agentProgramDescriptor
  , continuationRequirement
  )
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Internal.Process (HelperSpec (..), Helper (..), Framing (..), privateEnvironment, spawnHelper, nextReceived, helperExited, closeHelper, waitExit, exitInt, runBounded, removeRoot)
import Petrus.Agenticus.Runtime.Internal.Lifecycle (Lifecycle, LifecycleTexts (..), newLifecycle)
import Petrus.Agenticus.Runtime.Internal.Lifecycle qualified as Lifecycle
import Petrus.Agenticus.Runtime.Installation
  ( ProbeDisposition (..)
  , RuntimeInstallation
  , RuntimeProbeResult (..)
  , mkInstalledComponent
  , mkProbeIssue
  , mkRuntimeInstallation
  , mkRuntimeProbeResult
  )
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition (..)
  , RuntimeOperation (..)
  , RuntimeOperationCleanup
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Profiles (piNativeA2Local, piNativeA4E2b, piNativeA4Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..), mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation
  ( Continuation (..)
  , ContinuationDescriptor
  , ContinuationState (..)
  , continuationDescriptor
  )
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (..), TurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Impetus.Internal.PyJson qualified as Py
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution
  ( EnvironmentProvider (..)
  , LeaseState (..)
  , attachmentLease
  , identityOperationId
  , leaseIdentity
  , leaseProvider
  , leaseState
  )
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesPathExist
  , findExecutable
  , makeAbsolute
  , pathIsSymbolicLink
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files qualified as Files
import System.Posix.Unistd (SystemID (..), getSystemID)
import System.Posix.User (getEffectiveUserID)
import Data.ByteString qualified as BS

-- ---------------------------------------------------------------------------
-- Pins and catalogs

piSdkVersion, piSdkSourceCommit, piAiVersion, piSourceCommit, piSdkSource, piAiSource :: Text
piSdkVersion = "0.83.0"
piSdkSourceCommit = "6e48c10f5b1f5cfc90d6cb21abf26a3e1e8a6bd7"
piAiVersion = "0.83.0"
piSourceCommit = piSdkSourceCommit
piSdkSource = "npm:@earendil-works/pi-coding-agent@" <> piSdkVersion <> "#commit=" <> piSdkSourceCommit
piAiSource = "npm:@earendil-works/pi-ai@" <> piAiVersion <> "#commit=" <> piSourceCommit

piCcPatchVersion, piCcPatchSourceCommit, piCcPatchSource :: Text
piCcPatchVersion = "1.0.1"
piCcPatchSourceCommit = "1891a39e3e1c61e37f950159fdc51de1ecffce84"
piCcPatchSource =
  "npm:pi-cc-patch@1.0.1#"
    <> "sha512-1yxwj/4K3RIT+zAcngpL6yQ3QHwYDx6oJ+F7vQU4SHGotspqexPfSTxlSgzdtVD35jrqbTSeccwQrE5cjdVXlg=="

piApiKeyCatalog, piSubscriptionCatalog, piCcPatchSubscriptionCatalog :: [(Text, Text)]
piApiKeyCatalog =
  [ ("anthropic", "claude-sonnet-4-5")
  , ("openrouter", "anthropic/claude-sonnet-4.5")
  , ("openai", "gpt-5.6-sol")
  ]
piSubscriptionCatalog =
  [ ("anthropic", "claude-sonnet-4-5")
  , ("openai-codex", "gpt-5.6-sol")
  ]
piCcPatchSubscriptionCatalog = [("anthropic", "claude-sonnet-4-5")]

-- ---------------------------------------------------------------------------
-- Descriptors

programId, continuationId, connectionId', subscriptionConnectionId, ccPatchConnectionId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "pi.harness-owned" 1
continuationId = descriptorIdentity KindContinuation "pi.native" 1
connectionId' = descriptorIdentity KindConnection "pi.compatible-api-key" 1
subscriptionConnectionId = descriptorIdentity KindConnection "pi.native-subscription" 1
ccPatchConnectionId = descriptorIdentity KindConnection "pi.cc-patch-subscription" 1

handsId, capabilityHandsId, territoryId, gondolinTerritoryId, e2bTerritoryId :: DescriptorIdentity
handsId = descriptorIdentity KindHands "pi.collocated" 1
capabilityHandsId = descriptorIdentity KindHands "pi.capability-scoped" 1
territoryId = descriptorIdentity KindTerritory "motus.local" 1
gondolinTerritoryId = descriptorIdentity KindTerritory "motus.gondolin" 1
e2bTerritoryId = descriptorIdentity KindTerritory "motus.e2b" 1

piContinuationDescriptor :: ContinuationDescriptor
piContinuationDescriptor = continuationDescriptor continuationId programId

piProgram :: AgentProgramDescriptor
piProgram =
  agentProgramDescriptor
    programId
    HarnessOwned
    True
    [continuationRequirement continuationId programId]
    (Just continuationId)
    False
    False

piProgramCapabilities
  , piContinuationCapabilities
  , piConnectionCapabilities
  , piSubscriptionConnectionCapabilities
  , piCcPatchConnectionCapabilities
  , piCollocatedHands
  , piCapabilityScopedHands
  , piLocalTerritory
  , piGondolinTerritory
  , piE2bTerritory
    :: CapabilityDescriptor
piProgramCapabilities = capabilityDescriptor programId ["program.harness-owned"] []
piContinuationCapabilities = capabilityDescriptor continuationId ["continuation.pi-native"] []
piConnectionCapabilities = capabilityDescriptor connectionId' ["connection.pi-compatible"] []
piSubscriptionConnectionCapabilities = capabilityDescriptor subscriptionConnectionId ["connection.pi-compatible"] []
piCcPatchConnectionCapabilities = capabilityDescriptor ccPatchConnectionId ["connection.pi-compatible"] []
piCollocatedHands = capabilityDescriptor handsId ["hands.collocated"] []
piCapabilityScopedHands = capabilityDescriptor capabilityHandsId ["hands.capability-scoped"] []
piLocalTerritory = capabilityDescriptor territoryId [] []
piGondolinTerritory = capabilityDescriptor gondolinTerritoryId [] []
piE2bTerritory = capabilityDescriptor e2bTerritoryId [] []

-- ---------------------------------------------------------------------------
-- Bounds and tool schemas

maxPrompt, maxKey, maxAuth, defaultSession, helperFrameLimit :: Int
maxPrompt = 64 * 1024
maxKey = 8192
maxAuth = 1000000
defaultSession = 4000000
helperFrameLimit = 16 * 1024 * 1024

ccPatchIndexSha256 :: Text
ccPatchIndexSha256 = "a2829f6fd8c5f9b12b2297ba2edc4b4b8b80b4d676adcd65a88855e72d76729a"

publicationMargin :: Double
publicationMargin = 5.0

-- | @_SCHEMAS@: the closed JSON schema advertised for each method, in the
-- reference's member order.
piToolSchemas :: [(ToolMethod, Json)]
piToolSchemas =
  [ (WorkspaceRead, object' [("path", pathSchema)] ["path"])
  , (WorkspaceSearch, object' [("query", textSchema maxQueryChars), ("path", pathSchema)] ["query", "path"])
  ,
    ( WorkspaceShell
    , object'
        [ ( "argv"
          , Object
              [ ("type", String "array")
              , ("minItems", Int 1)
              , ("maxItems", Int (toInteger maxArgvParts))
              , ("items", textSchema maxArgvPartChars)
              ]
          )
        , ("cwd", textSchema maxCwdChars)
        ]
        ["argv", "cwd"]
    )
  ,
    ( WorkspaceWrite
    , object'
        [ ("path", pathSchema)
        , ("content", Object [("type", String "string"), ("maxLength", Int (toInteger maxContentChars))])
        ]
        ["path", "content"]
    )
  , (WorkspaceTest, Object [("type", String "object"), ("properties", Object []), ("additionalProperties", Bool False)])
  ]
  where
    pathSchema = textSchema maxPathChars
    textSchema limit = Object [("type", String "string"), ("minLength", Int 1), ("maxLength", Int (toInteger limit))]
    object' properties required =
      Object
        [ ("type", String "object")
        , ("properties", Object properties)
        , ("required", Array (map String required))
        , ("additionalProperties", Bool False)
        ]

-- ---------------------------------------------------------------------------
-- Validation helpers

-- | @_text(value, label, bound)@. A lone surrogate fails @value.encode()@,
-- after the emptiness and strip checks.
piText :: Text -> Int -> Text -> Either AgenticusError Text
piText label bound value
  | not (T.null value) && isTrimmed value, Just refusal <- encodeRefusal value = Left refusal
  | isBoundedText bound value = Right value
  | otherwise = Left (valueError (label <> " must be bounded non-empty text"))

-- | @_uuid@: a canonical lowercase RFC 4122 session identity.
piUuid :: Text -> Either AgenticusError Text
piUuid value = do
  _ <- piText "Pi session identity" 36 value
  if canonicalUuid value then Right value else Left (valueError "Pi session identity must be canonical")

canonicalUuid :: Text -> Bool
canonicalUuid value = case T.splitOn "-" value of
  [a, b, c, d, e] ->
    hexOf 8 a
      && hexOf 4 b
      && hexOf 4 c
      && hexOf 4 d
      && hexOf 12 e
      && T.head c `elem` ("12345" :: String)
      && T.head d `elem` ("89ab" :: String)
  _ -> False
  where
    hexOf n part = T.length part == n && T.all (\ch -> isDigit ch || (isHexDigit ch && isLower ch)) part

-- | @_strict_load@: strict UTF-8 JSON without @NaN@/@Infinity@ constants
-- or duplicate members at any depth. 'Left' is the reference's
-- @ValueError@ (including @UnicodeDecodeError@ and @JSONDecodeError@).
--
-- CPython's scanner admits lone surrogate escapes (@"\\ud800"@) into a
-- @str@; so does this one, as a WTF-8 'Text' ("Petrus.Json.Wtf8"). A
-- reader that encodes such a string fails as CPython's @str.encode()@ does
-- ('encodeRefusal').
strictLoad :: ByteString -> Either () Json
strictLoad bytes = do
  text <- either (const (Left ())) Right (TE.decodeUtf8' bytes)
  -- Whatever petrus-json's strict parser admits, the CPython-faithful
  -- scanner admits as the same value: it differs only by refusing a UTF-8
  -- BOM and nesting past 'J.defaultNestingLimit' (the scanner has no depth
  -- bound). Only those, and the refusals, take the slower scanner.
  case J.parseJson strictParseOptions bytes of
    Right value -> Right value
    Left _ -> either (const (Left ())) (Right . fromRaw) (Py.loads hooks text)
  where
    hooks =
      Py.Hooks
        { parseInt = either (const (Left ())) Right . Py.defaultInt
        , parseFloat = Right . Py.defaultFloat
        , parseConstant = const (Left ())
        , objectPairs = \pairs ->
            if Set.size (Set.fromList (map fst pairs)) == length pairs then Right () else Left ()
        }
    fromRaw = \case
      Py.RNull -> Null
      Py.RBool b -> Bool b
      Py.RInt n -> Int n
      Py.RFloat d -> Float d
      Py.RStr t -> String (J.fromCodePoints t)
      Py.RList xs -> Array (map fromRaw xs)
      Py.RDict members -> Object [(J.fromCodePoints k, fromRaw v) | (k, v) <- members]

-- | 'strictLoad' for helper frames, on petrus-json's parser alone (a frame
-- is never nested past its depth bound). Like the reference, it keeps lone
-- surrogate escapes; the frame loops fail on, or pass on, such a string
-- where the reference does.
strictFrameLoad :: ByteString -> Either () Json
strictFrameLoad bytes = case TE.decodeUtf8' bytes of
  Left _ -> Left ()
  Right _ -> either (const (Left ())) Right (J.parseJson strictParseOptions bytes)

-- | @json.loads@ with a duplicate-refusing @object_pairs_hook@ and a
-- refusing @parse_constant@.
strictParseOptions :: J.ParseOptions
strictParseOptions =
  J.pythonLoads
    { J.duplicateMembers = J.RejectDuplicates
    , J.allowNonFiniteConstants = False
    , J.loneSurrogates = J.KeepLoneSurrogates
    }

bare :: AgenticusError
bare = valueError ""

-- | A frame member that is a non-empty string (@isinstance(v, str) and v@).
nonEmptyString :: Json -> Maybe Text
nonEmptyString = \case
  String value | not (T.null value) -> Just value
  _ -> Nothing

-- | @_validate_native_auth@: one exact OAuth credential object for the
-- provider, at most @bound@ bytes of strict UTF-8.
validateNativeAuth :: ByteString -> Text -> Int -> Either AgenticusError ByteString
validateNativeAuth value provider bound = do
  when (B.null value || B.length value > bound) (Left bare)
  _ <- either (Left . agenticusError (OtherError "UnicodeDecodeError")) Right (Py.decodeUtf8Python value)
  stored <- either (const (Left bare)) Right (strictLoad value)
  credential <- case stored of
    Object [(key, credential)] | key == provider -> Right credential
    _ -> Left bare
  members <- case credential of
    Object members -> Right members
    _ -> Left bare
  let field name = lookup name members
      nonEmptyText = \case
        Just (String s) -> not (T.null s)
        _ -> False
  expiresFinite <- case field "expires" of
    Just (Int n)
      | abs n > maxFloatInteger -> Left (agenticusError (OtherError "OverflowError") "int too large to convert to float")
      | otherwise -> Right True
    Just (Float x) -> Right (not (isNaN x || isInfinite x))
    _ -> Right False
  when
    ( field "type" /= Just (String "oauth")
        || not (nonEmptyText (field "access"))
        || not (nonEmptyText (field "refresh"))
        || not expiresFinite
        || (provider == "openai-codex" && not (nonEmptyText (field "accountId")))
    )
    (Left bare)
  pure value
  where
    -- The largest integer @float()@ accepts (it rounds to the largest finite double).
    maxFloatInteger = 2 ^ (1024 :: Int) - 2 ^ (970 :: Int) - 1 :: Integer

-- | @_decode_native_auth@: canonical base64 of a valid native credential.
decodeNativeAuth :: Json -> Text -> Int -> Either AgenticusError ByteString
decodeNativeAuth value provider bound = case value of
  String encoded -> do
    body <- pyB64DecodeText encoded
    when (b64Encode body /= encoded) (Left bare)
    validateNativeAuth body provider bound
  _ -> Left bare

-- | @base64.b64decode(value, validate=True)@ for a @str@: non-ASCII text is
-- a @ValueError@ before any base64 rule applies.
pyB64DecodeText :: Text -> Either AgenticusError ByteString
pyB64DecodeText value
  | T.any (> '\x7f') value = Left (valueError "string argument should contain only ASCII characters")
  | otherwise = pyB64DecodeStrict (TE.encodeUtf8 value)

-- | @base64.b64decode(value, validate=True)@ on CPython 3.14: only the
-- standard alphabet with exact trailing padding; non-zero trailing bits are
-- ignored. A refusal is @binascii.Error@, a @ValueError@.
pyB64DecodeStrict :: ByteString -> Either AgenticusError ByteString
pyB64DecodeStrict input
  | B.any (not . allowed) input = refuse "Only base64 data is allowed"
  | B.elem 61 dataPart = refuse "Discontinuous padding not allowed"
  | B.length padding > 2 && dataLength `mod` 4 == 1 = refuse lengthMessage
  | B.length padding > 2 = refuse "Excess padding not allowed"
  | dataLength `mod` 4 == 1 = refuse lengthMessage
  | B.length padding /= expectedPadding = refuse "Incorrect padding"
  | otherwise = Right (decodeGroups (B.unpack dataPart))
  where
    (dataPart, padding) = B.spanEnd (== 61) input
    dataLength = B.length dataPart
    expectedPadding = case dataLength `mod` 4 of
      2 -> 2
      3 -> 1
      _ -> 0
    lengthMessage =
      "Invalid base64-encoded string: number of data characters ("
        <> T.pack (show dataLength)
        <> ") cannot be 1 more than a multiple of 4"
    refuse = Left . agenticusError (OtherError "Error")
    allowed w = isAlphabet w || w == 61
    isAlphabet w = (w >= 65 && w <= 90) || (w >= 97 && w <= 122) || (w >= 48 && w <= 57) || w == 43 || w == 47
    sextet :: Word8 -> Int
    sextet w
      | w >= 65 && w <= 90 = fromIntegral w - 65
      | w >= 97 && w <= 122 = fromIntegral w - 71
      | w >= 48 && w <= 57 = fromIntegral w + 4
      | w == 43 = 62
      | otherwise = 63
    decodeGroups ws = B.pack (go ws)
    go (a : b : c : d : rest) =
      let n = (sextet a `shiftL` 18) .|. (sextet b `shiftL` 12) .|. (sextet c `shiftL` 6) .|. sextet d
       in byte (n `shiftR` 16) : byte (n `shiftR` 8) : byte n : go rest
    go [a, b, c] =
      let n = (sextet a `shiftL` 18) .|. (sextet b `shiftL` 12) .|. (sextet c `shiftL` 6)
       in [byte (n `shiftR` 16), byte (n `shiftR` 8)]
    go [a, b] = [byte (((sextet a `shiftL` 18) .|. (sextet b `shiftL` 12)) `shiftR` 16)]
    go _ = []
    byte n = fromIntegral (n .&. 0xff)

-- | @base64.b64encode(value).decode()@.
b64Encode :: ByteString -> Text
b64Encode body = TE.decodeLatin1 (convertToBase Base64 body)

-- | @_validate_session@: complete strict JSONL with exactly one leading
-- version-3 header for the session.
validateSession :: ByteString -> Text -> Int -> Int -> Either AgenticusError ByteString
validateSession value sessionId bound events = do
  when (B.null value || B.length value > bound || BC.last value /= '\n') $
    Left (valueError "Pi session must be bounded complete JSONL")
  let lines' = splitLinesKeepEnds value
  when (null lines' || length lines' > events) $ Left (valueError "Pi session event bound exceeded")
  objects <- either (const (Left (valueError "Pi session must contain strict JSON objects"))) Right (traverse entry lines')
  let isSession members = lookup "type" members == Just (String "session")
      headers = filter isSession objects
  case objects of
    header : _
      | length headers == 1
          && isSession header
          && lookup "version" header == Just (Int 3)
          && lookup "id" header == Just (String sessionId) ->
          Right value
    _ -> Left (valueError "Pi session header mismatch")
  where
    entry line
      | BC.last line /= '\n' || line == "\n" || line == "\r\n" = Left ()
      | otherwise = case strictLoad (B.init line) of
          Right (Object members) -> Right members
          _ -> Left ()

-- | @bytes.splitlines(keepends=True)@: lines end at @\\n@, @\\r\\n@ or @\\r@.
splitLinesKeepEnds :: ByteString -> [ByteString]
splitLinesKeepEnds bytes
  | B.null bytes = []
  | otherwise = case B.findIndex (\w -> w == 10 || w == 13) bytes of
      Nothing -> [bytes]
      Just i ->
        let end
              | B.index bytes i == 13 && i + 1 < B.length bytes && B.index bytes (i + 1) == 10 = i + 2
              | otherwise = i + 1
            (line, rest) = B.splitAt end bytes
         in line : splitLinesKeepEnds rest

-- | @_working_binding(path)@: SHA-256 of the resolved path text.
workingBinding :: FilePath -> Text
workingBinding = sha256Hex . TE.encodeUtf8 . T.pack

-- ---------------------------------------------------------------------------
-- Continuation payloads

-- | One opaque native Pi session revision. 'Show' renders no field.
data PiContinuationPayloadV1 = PiContinuationPayloadV1
  { sessionId :: Text
  , workingDirectoryBinding :: Text
  , sessionJsonl :: ByteString
  }
  deriving stock (Eq)

instance Show PiContinuationPayloadV1 where
  show _ = "PiContinuationPayloadV1(schema_version=1)"

payloadSchemaVersion :: Integer
payloadSchemaVersion = 1

-- | @PiContinuationPayloadV1(session_id, working_directory_binding,
-- session_jsonl)@.
mkPiContinuationPayloadV1 :: Text -> Text -> ByteString -> Either AgenticusError PiContinuationPayloadV1
mkPiContinuationPayloadV1 session binding body = do
  session' <- piUuid session
  binding' <- piText "Pi working-directory binding" 64 binding
  unless (T.length binding' == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) binding') $
    Left (valueError "Pi working-directory binding must be SHA-256")
  _ <- validateSession body session' defaultSession 10000
  pure (PiContinuationPayloadV1 session' binding' body)

-- | Host storage of Pi continuation payloads.
data PiContinuationOperations = PiContinuationOperations
  { store :: Text -> PiContinuationPayloadV1 -> IO Text
  , load :: Text -> IO PiContinuationPayloadV1
  }

-- | Host storage of final Turn text.
newtype PiTurnOperations = PiTurnOperations
  { storeTurn :: Text -> Text -> IO Text
  }

newtype PiContinuationCodec = PiContinuationCodec PiContinuationOperations

piContinuationCodec :: PiContinuationOperations -> PiContinuationCodec
piContinuationCodec = PiContinuationCodec

codecStore :: PiContinuationCodec -> Text -> PiContinuationPayloadV1 -> IO Text
codecStore (PiContinuationCodec operations) operationId payload = do
  operationId' <- throwLeft (piText "Pi operation" 256 operationId)
  reference <- operations.store operationId' payload
  throwLeft (piText "state reference" 512 reference)

codecLoad :: PiContinuationCodec -> Continuation -> IO PiContinuationPayloadV1
codecLoad (PiContinuationCodec operations) continuation = do
  when (continuation.descriptor /= piContinuationDescriptor) $
    throwIO (valueError "Pi Continuation does not match this runtime")
  operations.load continuation.stateReference

-- ---------------------------------------------------------------------------
-- Configuration

-- | @PiRuntimeConfig@. Build one with 'piRuntimeConfig' and validate it with
-- 'newPiRuntimeConfig', which resolves both directories (the reference
-- validates in @__post_init__@; @dataclasses.replace@ is a record update
-- followed by 'newPiRuntimeConfig').
data PiRuntimeConfig = PiRuntimeConfig
  { provider :: Text
  , model :: Text
  , workingDirectory :: FilePath
  , runtimeRoot :: FilePath
  , hostId :: Text
  , ccPatch :: Bool
  , credentialTtl :: Double
  , wallTimeout :: Double
  , cancellationGrace :: Double
  , maxEvents :: Int
  , maxToolCalls :: Int
  , maxFrameBytes :: Int
  , maxOutputBytes :: Int
  , maxSessionBytes :: Int
  , maxAuthBytes :: Int
  , territoryProfile :: Text
  }
  deriving stock (Eq)

instance Show PiRuntimeConfig where
  show = T.unpack . renderPiRuntimeConfig

-- | The reference's defaults.
piRuntimeConfig :: Text -> Text -> FilePath -> FilePath -> PiRuntimeConfig
piRuntimeConfig provider model workingDirectory runtimeRoot =
  PiRuntimeConfig
    { provider
    , model
    , workingDirectory
    , runtimeRoot
    , hostId = "local"
    , ccPatch = False
    , credentialTtl = 315.0
    , wallTimeout = 300.0
    , cancellationGrace = 2.0
    , maxEvents = 10000
    , maxToolCalls = 256
    , maxFrameBytes = 14 * 1024 * 1024
    , maxOutputBytes = 1000000
    , maxSessionBytes = defaultSession
    , maxAuthBytes = maxAuth
    , territoryProfile = "local"
    }

-- | @repr(config)@ without the two private paths.
renderPiRuntimeConfig :: PiRuntimeConfig -> Text
renderPiRuntimeConfig c =
  "PiRuntimeConfig(provider="
    <> pyStrRepr c.provider
    <> ", model="
    <> pyStrRepr c.model
    <> ", host_id="
    <> pyStrRepr c.hostId
    <> ", cc_patch="
    <> (if c.ccPatch then "True" else "False")
    <> ", credential_ttl="
    <> T.pack (J.pythonFloatRepr c.credentialTtl)
    <> ", wall_timeout="
    <> T.pack (J.pythonFloatRepr c.wallTimeout)
    <> ", cancellation_grace="
    <> T.pack (J.pythonFloatRepr c.cancellationGrace)
    <> ", max_events="
    <> int c.maxEvents
    <> ", max_tool_calls="
    <> int c.maxToolCalls
    <> ", max_frame_bytes="
    <> int c.maxFrameBytes
    <> ", max_output_bytes="
    <> int c.maxOutputBytes
    <> ", max_session_bytes="
    <> int c.maxSessionBytes
    <> ", max_auth_bytes="
    <> int c.maxAuthBytes
    <> ", territory_profile="
    <> pyStrRepr c.territoryProfile
    <> ")"
  where
    int = T.pack . show

-- | Validate and normalize a configuration (@PiRuntimeConfig.__post_init__@).
newPiRuntimeConfig :: PiRuntimeConfig -> IO PiRuntimeConfig
newPiRuntimeConfig c = do
  provider <- throwLeft (piText "Pi provider" 256 c.provider)
  model <- throwLeft (piText "Pi model" 256 c.model)
  hostId <- throwLeft (piText "Pi host_id" 256 c.hostId)
  workingDirectory <- directory "working_directory" c.workingDirectory
  runtimeRoot <- directory "runtime_root" c.runtimeRoot
  uid <- getEffectiveUserID
  rootStatus <- Files.getFileStatus runtimeRoot
  when (Files.fileMode rootStatus .&. 0o7777 /= 0o700 || Files.fileOwner rootStatus /= uid) $
    throwIO (valueError "Pi runtime_root must be owned mode-0700")
  forM_ [("credential_ttl", c.credentialTtl), ("wall_timeout", c.wallTimeout), ("cancellation_grace", c.cancellationGrace)] $
    \(name, value) ->
      when (isNaN value || isInfinite value || value <= 0) $
        throwIO (valueError ("Pi " <> name <> " must be positive and finite"))
  when (c.ccPatch && lookup provider piCcPatchSubscriptionCatalog /= Just model) $
    throwIO (valueError "Pi cc_patch requires its exact Anthropic subscription pair")
  unless (c.territoryProfile `elem` ["local", "gondolin", "e2b"]) $
    throwIO (valueError "Pi territory_profile must be local, gondolin, or e2b")
  forM_
    [ ("max_events", c.maxEvents)
    , ("max_tool_calls", c.maxToolCalls)
    , ("max_frame_bytes", c.maxFrameBytes)
    , ("max_output_bytes", c.maxOutputBytes)
    , ("max_session_bytes", c.maxSessionBytes)
    , ("max_auth_bytes", c.maxAuthBytes)
    ]
    $ \(name, value) -> when (value <= 0) $ throwIO (valueError ("Pi " <> name <> " must be positive"))
  let encodedSession = ((c.maxSessionBytes + 2) `div` 3) * 4
      encodedAuth = ((c.maxAuthBytes + 2) `div` 3) * 4
  when
    ( c.maxFrameBytes < encodedSession + encodedAuth + 6 * c.maxOutputBytes + 128 * 1024
        || c.maxFrameBytes > helperFrameLimit
    )
    $ throwIO (valueError "Pi frame bound cannot carry the output, session, and authority bounds")
  pure c {provider, model, hostId, workingDirectory, runtimeRoot}
  where
    directory name selected = do
      linked <- pathIsSymbolicLink selected `catch` \(_ :: IOException) -> pure False
      when linked $ throwIO (valueError ("Pi " <> name <> " must be stable"))
      path <- canonicalizePath selected
      isDirectory <- doesDirectoryExist path
      unless isDirectory $ throwIO (valueError ("Pi " <> name <> " must be an existing directory"))
      pure path

-- ---------------------------------------------------------------------------
-- Invocations

-- | One Pi Turn request. Build it with 'newPiRuntimeInvocation', which runs
-- the reference's @__post_init__@ checks.
data PiRuntimeInvocation = PiRuntimeInvocation
  { operationId :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , prompt :: Text
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  , gateway :: HandsGateway
  , grantEpoch :: Integer
  , continuation :: Maybe Continuation
  }

instance Show PiRuntimeInvocation where
  show = T.unpack . renderPiRuntimeInvocation

-- | @repr(invocation)@: no prompt, attachment, gateway or continuation.
renderPiRuntimeInvocation :: PiRuntimeInvocation -> Text
renderPiRuntimeInvocation i =
  "PiRuntimeInvocation(operation_id="
    <> pyStrRepr i.operationId
    <> ", episode_id=EpisodeId(value="
    <> pyStrRepr (lifecycleIdText i.episodeId)
    <> "), turn_id=TurnId(value="
    <> pyStrRepr (lifecycleIdText i.turnId)
    <> "), connection="
    <> T.pack (show i.connection)
    <> ", grant_epoch="
    <> T.pack (show i.grantEpoch)
    <> ")"

newPiRuntimeInvocation :: PiRuntimeInvocation -> IO PiRuntimeInvocation
newPiRuntimeInvocation i = do
  operationId <- throwLeft (piText "Pi operation" 256 i.operationId)
  throwLeft (promptValid i.prompt)
  let profile = i.connection.identity.profile
  when (i.connection.status /= StatusReady || profile `notElem` ["api-key", "subscription", "cc-patch-subscription"]) $
    throwIO (valueError "Pi invocation requires a ready compatible connection")
  let catalog = if profile == "cc-patch-subscription" then piCcPatchSubscriptionCatalog else piSubscriptionCatalog
  when (profile /= "api-key" && isNothing (lookup i.connection.identity.provider catalog)) $
    throwIO (valueError "Pi subscription connection requires an exact native OAuth provider")
  when (Episode.episodeId i.attachment /= i.episodeId) $
    throwIO (valueError "Pi invocation requires its exact attachment")
  c <- Episode.coordinates i.attachment
  when
    ( (gatewayEpisodeId i.gateway, gatewayAttachmentId i.gateway, gatewayAttachmentEpoch i.gateway)
        /= (c.episodeId, c.attachmentId, c.attachmentEpoch)
    )
    $ throwIO (valueError "Pi gateway attachment mismatch")
  when (i.grantEpoch <= 0) $ throwIO (valueError "Pi grant epoch must be positive")
  pure PiRuntimeInvocation {operationId, episodeId = i.episodeId, turnId = i.turnId, prompt = i.prompt, connection = i.connection, attachment = i.attachment, gateway = i.gateway, grantEpoch = i.grantEpoch, continuation = i.continuation}

promptValid :: Text -> Either AgenticusError ()
promptValid prompt
  | T.null prompt || utf8Length prompt > maxPrompt || T.elem '\0' prompt =
      Left (valueError "Pi prompt must be bounded non-empty text")
  | otherwise = Right ()

-- | @pi_durable_work_fingerprint@: the stable, secret-free identity of
-- prospective Pi work, without any process-scoped fence.
piDurableWorkFingerprint
  :: PiRuntimeConfig -> EpisodeId -> TurnId -> Text -> ConnectionIdentity -> Maybe Continuation -> Either AgenticusError Text
piDurableWorkFingerprint config episode turn prompt connection continuation = do
  promptValid prompt
  let identity =
        Object
          [ ("schema_version", Int 1)
          , ("episode_id", String (lifecycleIdText episode))
          , ("turn_id", String (lifecycleIdText turn))
          , ("prompt_sha256", String (sha256Hex (TE.encodeUtf8 prompt)))
          , ("connection_id", String connection.connectionId)
          , ("connection_provider", String connection.provider)
          , ("connection_profile", String connection.profile)
          , ("connection_account", String connection.accountFingerprint)
          , ("provider", String config.provider)
          , ("model", String config.model)
          , ("territory", String config.territoryProfile)
          , ("cc_patch", Bool config.ccPatch)
          ,
            ( "continuation"
            , case continuation of
                Nothing -> Null
                Just c ->
                  Object
                    [ ("id", String (lifecycleIdText c.id))
                    , ("thread", String (lifecycleIdText c.thread))
                    , ("state_reference_sha256", String (sha256Hex (TE.encodeUtf8 c.stateReference)))
                    ]
            )
          ]
      options = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True, J.allowNan = False}
  encoded <- either (const (Left (valueError "Out of range float values are not JSON compliant"))) Right (J.dumps options identity)
  pure (sha256Hex encoded)

-- | @pi_durable_fingerprint(config, invocation)@.
piDurableFingerprint :: PiRuntimeConfig -> PiRuntimeInvocation -> Either AgenticusError Text
piDurableFingerprint config i =
  piDurableWorkFingerprint config i.episodeId i.turnId i.prompt i.connection.identity i.continuation

-- ---------------------------------------------------------------------------
-- Helper clients

-- | One completed native candidate. 'Show' renders only the session shape.
data PiCandidate = PiCandidate
  { sessionId :: Text
  , text :: Text
  , sessionJsonl :: ByteString
  }
  deriving stock (Eq)

instance Show PiCandidate where
  show _ = "_Candidate(<opaque>)"

data PiHelperResult = PiHelperResult
  { candidate :: Maybe PiCandidate
  , nativeAuth :: Maybe ByteString
  , code :: Text
  }
  deriving stock (Eq)

instance Show PiHelperResult where
  show r = "_HelperResult(candidate=" <> show r.candidate <> ", code=" <> show r.code <> ")"

-- | @_HelperClient@: run one Turn (gateway, invocation, current, monotonic
-- deadline) and close, reporting whether cleanup is proven.
data PiHelperClient = PiHelperClient
  { run :: HandsGateway -> PiRuntimeInvocation -> IO Bool -> Double -> IO PiHelperResult
  , close :: IO Bool
  }

-- | The keyword arguments of @_HelperFactory.create@.
data PiHelperArgs = PiHelperArgs
  { node :: FilePath
  , sdkEntrypoint :: Text
  , privateRoot :: FilePath
  , config :: PiRuntimeConfig
  , invocation :: PiRuntimeInvocation
  , prior :: Maybe PiContinuationPayloadV1
  , apiKey :: Maybe Text
  , nativeAuth :: Maybe ByteString
  , extension :: Maybe Text
  }

newtype PiHelperFactory = PiHelperFactory
  { create :: PiHelperArgs -> IO PiHelperClient
  }

-- | @_SubprocessFactory(helper)@.
subprocessFactory :: FilePath -> PiHelperFactory
subprocessFactory helper = PiHelperFactory (\args -> subprocessClient <$> newSubprocessClient helper args)

-- | The installed verbatim @pi_helper.mjs@.
piHelperPath :: IO FilePath
piHelperPath = getDataFileName "data/pi_helper.mjs" >>= makeAbsolute

-- | Knobs the reference reaches by monkeypatching.
data SubprocessOptions = SubprocessOptions
  { modelData :: ToolResult -> Json
  -- ^ @ToolResult.to_model_data@.
  , adjustStart :: [(Text, Json)] -> [(Text, Json)]
  -- ^ Rewrites the @start@ frame (the reference assigns @client._start@).
  }

subprocessOptions :: SubprocessOptions
subprocessOptions = SubprocessOptions {modelData = toolResultToModelData, adjustStart = id}

-- | @_SubprocessClient@: one private helper process.
data SubprocessClient = SubprocessClient
  { config :: PiRuntimeConfig
  , prior :: Maybe PiContinuationPayloadV1
  , options :: SubprocessOptions
  , helper :: Helper
  , start :: [(Text, Json)]
  }

newSubprocessClient :: FilePath -> PiHelperArgs -> IO SubprocessClient
newSubprocessClient = newSubprocessClientWith subprocessOptions

newSubprocessClientWith :: SubprocessOptions -> FilePath -> PiHelperArgs -> IO SubprocessClient
newSubprocessClientWith options helper args = do
  when (isNothing args.apiKey == isNothing args.nativeAuth) $ throwIO (runtimeProtocolError "credential-invalid")
  grant <- currentGrant (Episode.grants args.invocation.attachment)
  granted <- case grant of
    Just g | g.grantEpoch == args.invocation.grantEpoch -> pure g.capabilities
    _ -> throwIO (runtimeProtocolError "grant-mismatch")
  let command =
        HelperSpec
          { executable = args.node
          , arguments = [helper, T.unpack args.sdkEntrypoint, maybe "--no-extension" T.unpack args.extension]
          , directory = Nothing
          , environment = Just (privateEnvironment args.privateRoot args.node)
          }
  started <- spawnHelper Chunks command >>= maybe (throwIO (runtimeProtocolError "helper-launch-failed")) pure
  session <- maybe newUuid4 (pure . (.sessionId)) args.prior
  let start = options.adjustStart (startFrame args.config args session granted)
  pure
    SubprocessClient
      { config = args.config
      , prior = args.prior
      , options
      , helper = started
      , start
      }

-- | The @start@ frame, in the reference's member order.
startFrame :: PiRuntimeConfig -> PiHelperArgs -> Text -> Set ToolMethod -> [(Text, Json)]
startFrame config args session granted =
  [ ("type", String "start")
  , ("version", Int 1)
  , ("provider", String config.provider)
  , ("model", String config.model)
  , ("prompt", String args.invocation.prompt)
  , ("cwd", String (T.pack config.workingDirectory))
  , ("root", String (T.pack args.privateRoot))
  , ("session_id", String session)
  , ("session", maybe Null (String . b64Encode . (.sessionJsonl)) args.prior)
  , ("schemas", Object [(toolMethodText m, s) | m <- allToolMethods, m `Set.member` granted, Just s <- [lookup m piToolSchemas]])
  , ("limits", Object (limits <> [("auth", Int (toInteger config.maxAuthBytes)) | isJust args.nativeAuth]))
  ]
    <> case (args.apiKey, args.nativeAuth) of
      (Just key, _) -> [("api_key", String key)]
      (_, Just auth) -> [("auth", String (b64Encode auth))]
      _ -> []
  where
    limits =
      [ ("frame", Int (toInteger config.maxFrameBytes))
      , ("output", Int (toInteger config.maxOutputBytes))
      , ("session", Int (toInteger config.maxSessionBytes))
      , ("events", Int (toInteger config.maxEvents))
      , ("tools", Int (toInteger config.maxToolCalls))
      ]

subprocessStartFrame :: SubprocessClient -> [(Text, Json)]
subprocessStartFrame c = c.start

subprocessClient :: SubprocessClient -> PiHelperClient
subprocessClient c = PiHelperClient {run = runSubprocess c, close = closeSubprocess c}

-- | A uuid4 in canonical text.
newUuid4 :: IO Text
newUuid4 = do
  raw <- getRandomBytes 16 :: IO ByteString
  let bytes = B.unpack raw
      set i f = zipWith (\j w -> if j == i then f w else w) [0 :: Int ..]
      fixed = set 8 (\w -> (w .&. 0x3f) .|. 0x80) (set 6 (\w -> (w .&. 0x0f) .|. 0x40) bytes)
      hex = concatMap (\w -> let s = showHex w "" in if length s == 1 then '0' : s else s) fixed
      (a, r1) = splitAt 8 hex
      (b, r2) = splitAt 4 r1
      (c, r3) = splitAt 4 r2
      (d, e) = splitAt 4 r3
  pure (T.pack (a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e))

-- | @json.dumps(value, separators=(",", ":"), ensure_ascii=False,
-- allow_nan=False).encode()@. Both steps fail with a @ValueError@: a
-- non-finite float, or a lone surrogate the dump kept.
compactBytes :: Json -> Either AgenticusError ByteString
compactBytes value = case J.dumps J.compact value of
  Left _ -> Left (valueError "Out of range float values are not JSON compliant")
  Right dumped -> maybe (Right dumped) Left (encodeRefusal (J.unsafeTextFromBytes dumped))

-- | A helper frame's line: 'compactBytes' and @b"\\n"@.
frameBytes :: Json -> Either AgenticusError ByteString
frameBytes frame = (<> "\n") <$> compactBytes frame

writeFrame :: SubprocessClient -> Json -> IO ()
writeFrame c frame = do
  encoded <- either (const (throwIO (runtimeProtocolError "helper-pipe-failed"))) pure (frameBytes frame)
  when (B.length encoded > c.config.maxFrameBytes) $ throwIO (runtimeProtocolError "frame-overflow")
  written <- try (B.hPut c.helper.input encoded >> hFlush c.helper.input)
  case written of
    Right () -> pure ()
    Left (_ :: IOException) -> throwIO (runtimeProtocolError "helper-pipe-failed")

data Loop = Loop
  { buffer :: ByteString
  , ready :: Bool
  , terminal :: Bool
  , abortSent :: Bool
  , eof :: Bool
  , seen :: Set Text
  , events :: Int
  , tools :: Int
  , graceEnd :: Double
  , candidate :: Maybe PiCandidate
  , nativeAuth :: Maybe ByteString
  , terminalCode :: Maybe Text
  }

protocol :: Text -> IO a
protocol = throwIO . runtimeProtocolError

-- | The reference's fail-closed protocol state machine.
runSubprocess :: SubprocessClient -> HandsGateway -> PiRuntimeInvocation -> IO Bool -> Double -> IO PiHelperResult
runSubprocess c gateway' invocation current deadline = do
  let start = c.start
  writeFrame c (Object start)
  let subscription = isJust (lookup "auth" start)
  final <- loop subscription (Loop B.empty False False False False Set.empty 0 0 0 Nothing Nothing Nothing)
  when (not (B.null final.buffer) || not final.terminal || isNothing final.candidate == isNothing final.terminalCode) $
    protocol "terminal-missing"
  case (c.prior, final.candidate) of
    (Just p, Just cand) | cand.sessionId /= p.sessionId -> protocol "session-mismatch"
    _ -> pure ()
  exited <- waitExit c.helper.process c.config.cancellationGrace
  returncode <- maybe (protocol "helper-exit-inconsistent") pure exited
  let expected = if isJust final.candidate then 0 else 1
  when (exitInt returncode /= expected) $ protocol "helper-exit-inconsistent"
  case final.terminalCode of
    Just code | not (subscription && code == "provider-failed") -> protocol code
    _ -> pure ()
  pure (PiHelperResult final.candidate final.nativeAuth (fromMaybe "turn-completed" final.terminalCode))
  where
    cfg = c.config
    loop subscription s
      | s.terminal = pure s
      | otherwise = do
          now <- getMonotonicTime
          live <- current
          let stopping = not live || now >= deadline
          s1 <-
            if stopping && not s.abortSent
              then do
                writeFrame c (Object [("type", String "abort")])
                pure s {abortSent = True, graceEnd = now + cfg.cancellationGrace}
              else pure s
          when (s1.abortSent && now >= s1.graceEnd) $ do
            live' <- current
            protocol (if not live' then "cancelled" else "deadline-exceeded")
          exited <- helperExited c.helper
          if exited && s1.eof
            then pure s1
            else do
              next <- nextChunk
              case next of
                -- The reference breaks once the helper has exited and no
                -- output is pending.
                Nothing | exited -> pure s1
                Nothing -> loop subscription s1
                Just Nothing -> loop subscription s1 {eof = True}
                Just (Just chunk) -> do
                  let buffer = s1.buffer <> chunk
                  when (B.length buffer > cfg.maxFrameBytes) $ protocol "frame-overflow"
                  s2 <- frames subscription s1 {buffer}
                  loop subscription s2
    nextChunk = nextReceived c.helper 50000
    frames subscription s = case B.elemIndex 10 s.buffer of
      Nothing -> pure s
      Just i -> do
        let raw = B.take i s.buffer
            rest = B.drop (i + 1) s.buffer
        fields <- case strictFrameLoad raw of
          Right (Object members) -> pure members
          _ -> protocol "malformed-frame"
        let events = s.events + 1
        when (events > cfg.maxEvents) $ protocol "event-overflow"
        s' <- frame subscription s {buffer = rest, events} fields
        frames subscription s'
    keys fields = sort (map fst fields)
    frame subscription s fields = case lookup "type" fields of
      Just (String "ready") -> do
        when (s.ready || s.terminal || keys fields /= ["type"]) $ protocol "frame-order"
        pure s {ready = True}
      Just (String "tool_call") -> do
        when (not s.ready || s.terminal || keys fields /= sort ["type", "id", "method", "params"]) $ protocol "frame-order"
        let identity = fromMaybe Null (lookup "id" fields)
            method = fromMaybe Null (lookup "method" fields)
            params = fromMaybe Null (lookup "params" fields)
            dumpOptions = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.allowNan = False}
        encoded <-
          either
            (\_ -> throwIO (valueError "Out of range float values are not JSON compliant"))
            pure
            (J.dumps dumpOptions params)
        -- @len(identity.encode())@ raises outside any @try@.
        forM_ (encodeRefusal =<< nonEmptyString identity) throwIO
        callId <- case (identity, method, params) of
          (String i, String m, Object _)
            | not (T.null i)
                && utf8Length i <= 128
                && not (i `Set.member` s.seen)
                && m `elem` map toolMethodText allToolMethods
                && B.length encoded <= 8192 ->
                pure i
          _ -> protocol "malformed-tool-call"
        let tools = s.tools + 1
        when (tools > cfg.maxToolCalls) $ protocol "tool-overflow"
        coords <- Episode.coordinates invocation.attachment
        result <-
          Gateway.submit
            gateway'
            ( Object
                [ ("version", Int 1)
                , ("call_id", String callId)
                , ("episode_id", String coords.episodeId)
                , ("attachment_id", String coords.attachmentId)
                , ("attachment_epoch", Int coords.attachmentEpoch)
                , ("grant_epoch", Int invocation.grantEpoch)
                , ("method", method)
                , ("params", params)
                ]
            )
        writeFrame c (Object [("type", String "tool_result"), ("id", String callId), ("result", c.options.modelData result)])
        pure s {tools, seen = Set.insert callId s.seen}
      Just (String "complete") -> do
        let expected = sort (["type", "session_id", "text", "session"] <> ["auth" | subscription])
        when (not s.ready || s.terminal || keys fields /= expected) $ protocol "frame-order"
        let member name = fromMaybe Null (lookup name fields)
            parsed = do
              sid <- case member "session_id" of
                String value -> piUuid value
                _ -> Left bare
              text <- case member "text" of
                String value | isNothing (encodeRefusal value) && utf8Length value <= cfg.maxOutputBytes -> Right value
                _ -> Left bare
              body <- case member "session" of
                String value -> pyB64DecodeText value
                _ -> Left bare
              _ <- validateSession body sid cfg.maxSessionBytes cfg.maxEvents
              auth <-
                if subscription
                  then Just <$> decodeNativeAuth (member "auth") cfg.provider cfg.maxAuthBytes
                  else Right Nothing
              pure (PiCandidate sid text body, auth)
        case parsed of
          Right (cand, auth) -> pure s {candidate = Just cand, nativeAuth = auth, terminal = True}
          Left e
            | malformed e -> protocol "malformed-complete"
            | otherwise -> throwIO e
      Just (String "failed") -> do
        let codeValue = lookup "code" fields
            providerFailure = codeValue == Just (String "provider-failed")
            expected = sort (["type", "code"] <> ["auth" | subscription && providerFailure])
        code <- case codeValue of
          Just (String value)
            | not s.terminal
                && keys fields == expected
                && value `elem` ["aborted", "provider-failed", "session-invalid", "protocol-failed"] ->
                pure value
          _ -> protocol "malformed-failed"
        auth <-
          if subscription && providerFailure
            then case decodeNativeAuth (fromMaybe Null (lookup "auth" fields)) cfg.provider cfg.maxAuthBytes of
              Right value -> pure (Just value)
              Left e
                | malformed e -> protocol "malformed-failed"
                | otherwise -> throwIO e
            else pure s.nativeAuth
        code' <-
          if code == "aborted" && s.abortSent
            then current >>= \live -> pure (if not live then "cancelled" else "deadline-exceeded")
            else pure code
        pure s {terminal = True, terminalCode = Just code', nativeAuth = auth}
      _ -> protocol "unknown-frame"
    -- @except TypeError, ValueError@ (with their subclasses).
    malformed e = any (e `isInstanceOf`) [E.ValueError, TypeError] || e.errorClass `elem` [OtherError "Error", OtherError "UnicodeDecodeError"]

-- | Close pipes, kill the helper's whole process group, and report whether
-- the helper and its stderr drain are proven gone.
closeSubprocess :: SubprocessClient -> IO Bool
closeSubprocess c = closeHelper c.helper c.config.cancellationGrace

-- ---------------------------------------------------------------------------
-- Operations

-- | One started Pi Turn (@_Operation@).
data PiOperation = PiOperation
  { adapter :: PiRuntimeAdapter
  , inv :: PiRuntimeInvocation
  , key :: Text
  , prior :: Maybe PiContinuationPayloadV1
  , factory :: PiHelperFactory
  , lifecycle :: Lifecycle
  }

instance Eq PiOperation where
  a == b = a.lifecycle == b.lifecycle

instance Show PiOperation where
  show o = "_Operation(operation_id=" <> T.unpack (pyStrRepr o.inv.operationId) <> ")"

piOperationId :: PiOperation -> Text
piOperationId o = o.inv.operationId

piOperationReceipt :: PiOperation -> IO (Maybe RuntimeTurnSettlement)
piOperationReceipt o = Lifecycle.receipt o.lifecycle

piOperationClosed :: PiOperation -> IO Bool
piOperationClosed o = Lifecycle.isClosed o.lifecycle

runOperation :: PiOperation -> IO ()
runOperation o = do
  outcome <- try (executeOperation o.adapter o)
  settled <- case outcome of
    Right value -> pure value
    Left (_ :: SomeException) -> do
      failed <- settle o.inv TurnFailed 0 "runtime-failed" Nothing Nothing
      pure (failed, RuntimeCleanupUnverified)
  Lifecycle.settle o.lifecycle (settle o.inv TurnCancelled 0 "cancelled" Nothing Nothing) settled

operationCurrent :: PiOperation -> IO Bool
operationCurrent o = Lifecycle.current o.lifecycle

-- | The publication check after cancellation (@_publication_error@).
publicationError :: PiOperation -> IO (Maybe Text)
publicationError o = do
  grant <- currentGrant (Episode.grants o.inv.attachment)
  case grant of
    Just g | g.grantEpoch == o.inv.grantEpoch -> do
      now <- adapterNow o.adapter
      pure (if now >= min g.deadline (Episode.episodeDeadline o.inv.attachment) then Just "deadline-exceeded" else Nothing)
    _ -> pure (Just "grant-mismatch")

-- | @_Operation.claim@: the last cancellation point before publication.
claim :: PiOperation -> IO (Maybe Text)
claim o = do
  let hooks = o.adapter.hooks
  maybe id id hooks.claim $ do
    first <- Lifecycle.inspect o.lifecycle (publicationError o)
    case first of
      Just e -> pure (Just e)
      Nothing -> do
        current <- adapterBindingCurrent o.adapter o.inv
        Lifecycle.claim o.lifecycle $
          publicationError o >>= \case
            Just e -> pure (Just e)
            Nothing
              | not current -> pure (Just o.adapter.leaseFailure)
              | otherwise -> pure Nothing

-- | @wait(timeout)@.
waitPiOperation :: PiOperation -> Maybe Double -> IO RuntimeTurnSettlement
waitPiOperation o = Lifecycle.waitSettled o.lifecycle

-- | @cancel(reason)@.
cancelPiOperation :: PiOperation -> Text -> IO CancellationDisposition
cancelPiOperation o reason = do
  _ <- throwLeft (piText "Pi cancellation reason" 256 reason)
  Lifecycle.requestCancel o.lifecycle $
    Episode.cancel o.inv.attachment reason `catch` rethrowAsync

-- | @close()@.
closePiOperation :: PiOperation -> IO RuntimeOperationCleanup
closePiOperation o = do
  let config = o.adapter.config
  Lifecycle.closeWith o.lifecycle (config.cancellationGrace * 2) (Lifecycle.settledEvidence o.lifecycle)

-- | The operation as the provider-neutral 'RuntimeOperation' record.
piRuntimeOperation :: PiOperation -> RuntimeOperation
piRuntimeOperation o =
  RuntimeOperation
    { operationId = o.inv.operationId
    , wait = waitPiOperation o
    , cancel = cancelPiOperation o
    , close = closePiOperation o
    }

-- ---------------------------------------------------------------------------
-- The adapter

-- | The reference's mutable private attributes (@_installation@, @_node@,
-- ...), which its tests assign directly.
data PiAdapterRuntime = PiAdapterRuntime
  { installation :: Maybe RuntimeInstallation
  , scriptedConformance :: Bool
  , node :: Maybe FilePath
  , sdkEntrypoint :: Maybe Text
  , ccPatchEntrypoint :: Maybe Text
  , helper :: Maybe FilePath
  , factory :: Maybe PiHelperFactory
  , subprocessFactoryInstalled :: Bool
  -- ^ Whether 'factory' is the probe's own @_SubprocessFactory@.
  }

-- | Seams the reference's tests reach by monkeypatching.
data PiAdapterHooks = PiAdapterHooks
  { bindingCurrent :: Maybe ((PiRuntimeInvocation -> IO Bool) -> PiRuntimeInvocation -> IO Bool)
  -- ^ Wraps @_binding_current@.
  , claim :: Maybe (IO (Maybe Text) -> IO (Maybe Text))
  -- ^ Wraps @_Operation.claim@.
  , spawn :: Maybe (IO () -> IO ())
  -- ^ Replaces @threading.Thread.start@.
  }

noHooks :: PiAdapterHooks
noHooks = PiAdapterHooks Nothing Nothing Nothing

data PiRuntimeAdapter = PiRuntimeAdapter
  { config :: PiRuntimeConfig
  , codec :: PiContinuationCodec
  , turns :: PiTurnOperations
  , custody :: HostConnectionCustody
  , clock :: IO Double
  , descriptor :: CapabilityDescriptor
  , hands :: CapabilityDescriptor
  , territory :: CapabilityDescriptor
  , runtimeCapabilities :: Set Text
  , leaseProvider :: Text
  , leaseFailure :: Text
  , runtime :: MVar PiAdapterRuntime
  , operations :: MVar (Map Text PiOperation)
  , hooks :: PiAdapterHooks
  }

-- | @PiRuntimeAdapter(config, codec, turns, custody, clock=..., client_factory=...)@.
newPiRuntimeAdapter
  :: PiRuntimeConfig -> PiContinuationCodec -> PiTurnOperations -> HostConnectionCustody -> IO Double -> Maybe PiHelperFactory -> IO PiRuntimeAdapter
newPiRuntimeAdapter config codec turns custody clock factory =
  newPiRuntimeAdapterWith PiAdapterOptions {clock, factory, hooks = noHooks, prepare = const id} config codec turns custody

-- | What the reference's tests assign on a built adapter (@_clock@, its
-- private hooks, @_installation@, @_node@, ...), fixed at construction.
data PiAdapterOptions = PiAdapterOptions
  { clock :: IO Double
  , factory :: Maybe PiHelperFactory
  , hooks :: PiAdapterHooks
  , prepare :: CapabilityDescriptor -> PiAdapterRuntime -> PiAdapterRuntime
  -- ^ The readiness a probe would record, given the runtime descriptor.
  }

piAdapterOptions :: PiAdapterOptions
piAdapterOptions = PiAdapterOptions {clock = getMonotonicTime, factory = Nothing, hooks = noHooks, prepare = const id}

newPiRuntimeAdapterWith
  :: PiAdapterOptions -> PiRuntimeConfig -> PiContinuationCodec -> PiTurnOperations -> HostConnectionCustody -> IO PiRuntimeAdapter
newPiRuntimeAdapterWith options config0 codec turns custody = do
  config <- newPiRuntimeConfig config0
  let (descriptor, hands, territory) = case config.territoryProfile of
        "gondolin" -> (piNativeA4Gondolin, piCapabilityScopedHands, piGondolinTerritory)
        "e2b" -> (piNativeA4E2b, piCapabilityScopedHands, piE2bTerritory)
        _ -> (piNativeA2Local, piCollocatedHands, piLocalTerritory)
      split = config.territoryProfile /= "local"
  runtime <- newMVar (options.prepare descriptor (PiAdapterRuntime Nothing False Nothing Nothing Nothing Nothing options.factory False))
  operations <- newMVar Map.empty
  pure
    PiRuntimeAdapter
      { config
      , codec
      , turns
      , custody
      , clock = options.clock
      , descriptor
      , hands
      , territory
      , runtimeCapabilities =
          Set.fromList ["runtime.cancel", "runtime.continue", "runtime.harness-owned", if split then "runtime.split" else "runtime.local"]
      , leaseProvider = if split then config.territoryProfile else "local-process"
      , leaseFailure = if split then "runtime-territory-lease-required" else "runtime-local-lease-required"
      , runtime
      , operations
      , hooks = options.hooks
      }

adapterConfig :: PiRuntimeAdapter -> PiRuntimeConfig
adapterConfig a = a.config

adapterDescriptor, adapterHands, adapterTerritory :: PiRuntimeAdapter -> CapabilityDescriptor
adapterDescriptor a = a.descriptor
adapterHands a = a.hands
adapterTerritory a = a.territory

adapterProgram :: PiRuntimeAdapter -> AgentProgramDescriptor
adapterProgram _ = piProgram

adapterContinuationDescriptor :: PiRuntimeAdapter -> ContinuationDescriptor
adapterContinuationDescriptor _ = piContinuationDescriptor

adapterRuntimeCapabilities :: PiRuntimeAdapter -> Set Text
adapterRuntimeCapabilities a = a.runtimeCapabilities

-- | @repr(adapter)@.
renderPiRuntimeAdapter :: PiRuntimeAdapter -> IO Text
renderPiRuntimeAdapter a = do
  let config = a.config
  ready <- isJust . (.installation) <$> readMVar a.runtime
  pure $
    "PiRuntimeAdapter(territory_profile="
      <> pyStrRepr config.territoryProfile
      <> ", provider="
      <> pyStrRepr config.provider
      <> ", model="
      <> pyStrRepr config.model
      <> ", ready="
      <> (if ready then "True" else "False")
      <> ")"

modifyAdapterRuntime :: PiRuntimeAdapter -> (PiAdapterRuntime -> PiAdapterRuntime) -> IO ()
modifyAdapterRuntime a f = modifyMVar_ a.runtime (pure . f)

readAdapterRuntime :: PiRuntimeAdapter -> IO PiAdapterRuntime
readAdapterRuntime a = readMVar a.runtime

adapterOperationIds :: PiRuntimeAdapter -> IO [Text]
adapterOperationIds a = Map.keys <$> readMVar a.operations

adapterNow :: PiRuntimeAdapter -> IO Double
adapterNow a = a.clock

-- | Executables and package roots for 'probe' (@probe(cli_path=..., ...)@).
data ProbePaths = ProbePaths
  { cliPath :: Maybe FilePath
  , nodePath :: Maybe FilePath
  , packageRoot :: Maybe FilePath
  , ccPatchRoot :: Maybe FilePath
  }

probePaths :: ProbePaths
probePaths = ProbePaths Nothing Nothing Nothing Nothing

-- | @probe(...)@: verify the exact pinned packages, Node 22.19 or later,
-- and the helper's own @--probe@ against the SDK.
probe :: PiRuntimeAdapter -> ProbePaths -> IO RuntimeProbeResult
probe a paths = do
  cli <- maybe (findExecutable "pi") (pure . Just) paths.cliPath
  node <- maybe (findExecutable "node") (pure . Just) paths.nodePath
  case (cli, node) of
    (Just cli', Just node') -> do
      outcome <- try (probeInstalled a paths cli' node')
      case outcome of
        Right (installation, nodeReal, sdk, helper, ccEntry) -> do
          modifyAdapterRuntime a $ \r ->
            let installFactory = isNothing r.factory
             in r
                  { node = Just nodeReal
                  , sdkEntrypoint = Just sdk
                  , helper = Just helper
                  , ccPatchEntrypoint = ccEntry
                  , factory = if installFactory then Just (subprocessFactory helper) else r.factory
                  , subprocessFactoryInstalled = installFactory || r.subprocessFactoryInstalled
                  }
          record a =<< throwLeft (mkRuntimeProbeResult a.descriptor.identity ProbeReady (Just installation) [])
        Left (e :: SomeException) -> do
          rethrowAsync e
          issue <- throwLeft (mkProbeIssue "protocol-unavailable" (Just "pi"))
          record a =<< throwLeft (mkRuntimeProbeResult a.descriptor.identity ProbeUnavailable Nothing [issue])
    _ -> do
      issue <- throwLeft (mkProbeIssue (if isNothing cli then "client-not-installed" else "node-not-installed") (Just "pi"))
      record a =<< throwLeft (mkRuntimeProbeResult a.descriptor.identity ProbeNotInstalled Nothing [issue])

probeInstalled :: PiRuntimeAdapter -> ProbePaths -> FilePath -> FilePath -> IO (RuntimeInstallation, FilePath, Text, FilePath, Maybe Text)
probeInstalled a paths cli node = do
  let config = a.config
  let invalid = throwIO (valueError "probe")
      strict path = doesPathExist path >>= \exists -> if exists then canonicalizePath path else invalid
      readJson path = BS.readFile path >>= either (const invalid) pure . J.parseJson J.pythonLoads
      field name = \case
        Object members -> fromMaybe Null (lookup name members)
        _ -> Null
  cliReal <- strict cli
  nodeReal <- strict node
  root <- maybe (pure (takeDirectory (takeDirectory cliReal))) strict paths.packageRoot
  expectedCli <- strict (root </> "dist/cli.js")
  when (cliReal /= expectedCli) invalid
  package <- readJson (root </> "package.json")
  sdk <- strict (root </> "dist/index.js")
  let nestedAi = root </> "node_modules" </> "@earendil-works" </> "pi-ai"
  nested <- doesDirectoryExist nestedAi
  aiRoot <- strict (if nested then nestedAi else takeDirectory root </> "pi-ai")
  ai <- readJson (aiRoot </> "package.json")
  let dependency = field "@earendil-works/pi-ai" (field "dependencies" package)
  when
    ( field "name" package /= String "@earendil-works/pi-coding-agent"
        || field "version" package /= String piSdkVersion
        || field "bin" package `notElem` [Object [("pi", String "dist/cli.js")], String "dist/cli.js"]
        || field "main" package `notElem` [String "dist/index.js", String "./dist/index.js"]
        || field "name" ai /= String "@earendil-works/pi-ai"
        || field "version" ai /= String piAiVersion
        || dependency `notElem` map String [piAiVersion, "^" <> piAiVersion, "~" <> piAiVersion]
    )
    invalid
  (versionCode, versionOutBytes, _) <- runBounded [nodeReal, "--version"] Nothing >>= maybe invalid pure
  let versionOut = T.unpack (TE.decodeUtf8With (\_ _ -> Just '\xfffd') versionOutBytes)
  when (versionCode /= ExitSuccess) invalid
  let version = T.strip (T.pack versionOut)
  case T.splitOn "." <$> T.stripPrefix "v" version of
    Just parts@[_, _, _]
      | all (\p -> not (T.null p) && T.all isDigit p) parts
      , map (read . T.unpack) parts >= [22, 19, 0 :: Integer] ->
          pure ()
    _ -> invalid
  ccEntry <-
    if config.ccPatch
      then do
        ccRoot <- maybe (strict (takeDirectory (takeDirectory root) </> "pi-cc-patch")) strict paths.ccPatchRoot
        ccPackage <- readJson (ccRoot </> "package.json")
        entry <- strict (ccRoot </> "index.ts")
        body <- BS.readFile entry
        when
          ( field "name" ccPackage /= String "pi-cc-patch"
              || field "version" ccPackage /= String piCcPatchVersion
              || field "pi" ccPackage /= Object [("extensions", Array [String "./index.ts"])]
              || sha256Hex body /= ccPatchIndexSha256
          )
          invalid
        pure (Just entry)
      else pure Nothing
  helper <- piHelperPath >>= strict
  let catalogs =
        Object
          [ ("api_keys", pairs piApiKeyCatalog)
          , ("subscriptions", pairs piSubscriptionCatalog)
          , ("cc_patch_subscriptions", pairs piCcPatchSubscriptionCatalog)
          ]
      pairs = Array . map (\(p, m) -> Array [String p, String m])
  catalogText <- either (const invalid) pure (J.dumpsText J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} catalogs)
  let command = [nodeReal, helper, sdk, "--probe", T.unpack catalogText] <> maybe [] pure ccEntry
  (code, out, err) <- runBounded command (Just (privateEnvironment "/dev/null" nodeReal)) >>= maybe invalid pure
  frame <- either (const invalid) pure (strictFrameLoad (fst (BC.spanEnd (== '\n') out)))
  when (code /= ExitSuccess || not (B.null err) || BC.count '\n' out /= 1 || frame /= Object [("type", String "probe"), ("ok", Bool True)]) invalid
  system <- getSystemID
  components <-
    throwLeft . sequence $
      [ mkInstalledComponent "pi-coding-agent" piSdkVersion piSdkSource
      , mkInstalledComponent "pi-ai" piAiVersion piAiSource
      , mkInstalledComponent "node" (T.drop 1 version) ("executable:" <> T.pack nodeReal)
      ]
        <> [mkInstalledComponent "pi-cc-patch" piCcPatchVersion piCcPatchSource | isJust ccEntry]
  installation <-
    throwLeft $
      mkRuntimeInstallation
        a.descriptor.identity
        1
        components
        (nonEmpty (T.toLower (T.pack (systemName system))))
        (nonEmpty (T.toLower (T.pack (machine system))))
        a.runtimeCapabilities
  pure (installation, nodeReal, T.pack sdk, helper, T.pack <$> ccEntry)
  where
    nonEmpty value = if T.null value then "unknown" else value

-- | @_record@: keep the readiness that matches this probe verdict.
record :: PiRuntimeAdapter -> RuntimeProbeResult -> IO RuntimeProbeResult
record a result = do
  modifyAdapterRuntime a $ \r ->
    let installation = if result.disposition == ProbeReady then result.installation else Nothing
     in if isJust installation
          then r {scriptedConformance = False, installation}
          else
            r
              { scriptedConformance = False
              , installation = Nothing
              , node = Nothing
              , sdkEntrypoint = Nothing
              , ccPatchEntrypoint = Nothing
              , helper = Nothing
              , factory = if r.subprocessFactoryInstalled then Nothing else r.factory
              , subprocessFactoryInstalled = False
              }
  pure result

-- | @_enable_scripted_conformance@: ready the Petrus-owned scripted client
-- without forging an installation.
enableScriptedConformance :: PiRuntimeAdapter -> IO ()
enableScriptedConformance a = modifyMVar_ a.runtime $ \r -> do
  when (isNothing r.factory) $ throwIO (typeError "scripted Pi conformance requires a client factory")
  pure r {scriptedConformance = True, node = Just "scripted-conformance:node", sdkEntrypoint = Just "scripted-conformance:sdk"}

-- | @start(invocation)@: the same handle for an identical redelivery.
startPi :: PiRuntimeAdapter -> PiRuntimeInvocation -> IO PiOperation
startPi a inv0 = do
  inv <- newPiRuntimeInvocation inv0
  validate a inv
  forM_ inv.continuation $ \c ->
    when (c.state /= ContinuationInUse) $ throwIO (runtimeProtocolError "continuation-not-claimed")
  prior <- traverse (codecLoad a.codec) inv.continuation
  let config = a.config
  forM_ prior $ \p ->
    when (p.workingDirectoryBinding /= workingBinding config.workingDirectory) $
      throwIO (runtimeProtocolError "continuation-project-mismatch")
  coords <- Episode.coordinates inv.attachment
  let identity =
        "("
          <> T.intercalate
            ", "
            [ pyStrRepr (lifecycleIdText inv.episodeId)
            , pyStrRepr (lifecycleIdText inv.turnId)
            , pyStrRepr (sha256Hex (TE.encodeUtf8 inv.prompt))
            , pyStrRepr inv.connection.identity.connectionId
            , T.pack (show inv.connection.authorityEpoch)
            , T.pack (show inv.connection.stateVersion)
            , pyStrRepr coords.attachmentId
            , T.pack (show coords.attachmentEpoch)
            , T.pack (show inv.grantEpoch)
            , pyStrRepr config.provider
            , pyStrRepr config.model
            , pyStrRepr config.territoryProfile
            , optional (pyStrRepr . lifecycleIdText . (.id)) inv.continuation
            , optional (pyStrRepr . lifecycleIdText . (.thread)) inv.continuation
            , optional (pyStrRepr . sha256Hex . TE.encodeUtf8 . (.stateReference)) inv.continuation
            , optional (pyStrRepr . (.sessionId)) prior
            , optional (pyStrRepr . sha256Hex . (.sessionJsonl)) prior
            ]
          <> ")"
      key = sha256Hex (TE.encodeUtf8 identity)
  let hooks = a.hooks
  mask_ $ do
    registered <- modifyMVar a.operations $ \known -> do
      r <- readMVar a.runtime
      factory <- case (r.installation, r.scriptedConformance, r.factory, r.node, r.sdkEntrypoint) of
        (installation, scripted, Just factory, Just _, Just _) | isJust installation || scripted -> pure factory
        _ -> throwIO (runtimeProtocolError "runtime-not-ready")
      case Map.lookup inv.operationId known of
        Just old
          | old.key /= key -> throwIO (runtimeProtocolError "operation-conflict")
          | otherwise -> pure (known, Left old)
        Nothing -> do
          operation <- newOperation a inv key prior factory
          pure (Map.insert inv.operationId operation known, Right operation)
    case registered of
      Left old -> pure old
      Right operation -> do
        let thread = Lifecycle.startWorker operation.lifecycle (runOperation operation)
        spawned <- try (maybe thread ($ thread) hooks.spawn)
        case spawned of
          Right () -> pure operation
          Left (e :: SomeException) -> do
            modifyMVar_ a.operations $ \known ->
              pure (if Map.lookup inv.operationId known == Just operation then Map.delete inv.operationId known else known)
            throwIO e
  where
    optional f = maybe "None" f

newOperation :: PiRuntimeAdapter -> PiRuntimeInvocation -> Text -> Maybe PiContinuationPayloadV1 -> PiHelperFactory -> IO PiOperation
newOperation adapter inv key prior factory = do
  lifecycle <- newLifecycle (LifecycleTexts "Pi wait timeout must be positive and finite" "Pi operation has not settled") inv.operationId
  pure PiOperation {adapter, inv, key, prior, factory, lifecycle}

-- | @evict(operation_id)@: remove one closed process-local receipt.
evictPi :: PiRuntimeAdapter -> Text -> IO Bool
evictPi a operationId = do
  operationId' <- throwLeft (piText "Pi operation" 256 operationId)
  modifyMVar a.operations $ \known -> case Map.lookup operationId' known of
    Nothing -> pure (known, False)
    Just operation -> do
      closedAlready <- piOperationClosed operation
      unless closedAlready $ throwIO (runtimeProtocolError "operation-active")
      pure (Map.delete operationId' known, True)

-- | @receipt(operation_id)@: one secret-free local settlement.
receiptPi :: PiRuntimeAdapter -> Text -> IO (Maybe RuntimeTurnSettlement)
receiptPi a operationId = do
  operationId' <- throwLeft (piText "Pi operation" 256 operationId)
  known <- readMVar a.operations
  maybe (pure Nothing) piOperationReceipt (Map.lookup operationId' known)

validate :: PiRuntimeAdapter -> PiRuntimeInvocation -> IO ()
validate a inv = do
  validateConnection a inv
  let profile = inv.connection.identity.profile
      connection
        | profile == "cc-patch-subscription" = ccPatchConnectionId
        | profile == "subscription" = subscriptionConnectionId
        | otherwise = connectionId'
      expected =
        [ (KindRuntime, a.descriptor.identity)
        , (KindConnection, connection)
        , (KindProgram, programId)
        , (KindHands, a.hands.identity)
        , (KindTerritory, a.territory.identity)
        , (KindContinuation, continuationId)
        ]
      snapshot = Episode.episodeSnapshot inv.attachment
  when (any (\(k, v) -> fmap (.identity) (snapshotDescriptor k snapshot) /= Just v) expected) $
    throwIO (runtimeProtocolError "resolution-mismatch")
  case snapshotDescriptor KindEffect snapshot of
    Just effect | "effect.host-fenced" `Set.member` effect.offers -> pure ()
    _ -> throwIO (runtimeProtocolError "resolution-mismatch")
  grant <- currentGrant (Episode.grants inv.attachment)
  case grant of
    Just g | g.grantEpoch == inv.grantEpoch -> pure ()
    _ -> throwIO (runtimeProtocolError "grant-mismatch")
  current <- adapterBindingCurrent a inv
  unless current $ throwIO (runtimeProtocolError a.leaseFailure)

-- | @_binding_current@ (through the test hook, when one is installed).
adapterBindingCurrent :: PiRuntimeAdapter -> PiRuntimeInvocation -> IO Bool
adapterBindingCurrent a inv = do
  let hooks = a.hooks
  maybe id id hooks.bindingCurrent (bindingCurrent a) inv

bindingCurrent :: PiRuntimeAdapter -> PiRuntimeInvocation -> IO Bool
bindingCurrent a inv = case (Episode.episodeBinding inv.attachment).motus of
  Nothing -> pure False
  Just binding -> do
    execution <- bindingExecution binding
    let lease = attachmentLease execution
    if leaseState lease /= Ready || leaseProvider lease /= a.leaseProvider
      then pure False
      else do
        observed <- try $ do
          provider <- bindingProvider binding
          providerLookup provider (identityOperationId (bindingLeaseIdentity binding))
        case observed of
          Left (e :: SomeException) -> rethrowAsync e >> pure False
          Right Nothing -> pure False
          Right (Just found) ->
            pure
              ( leaseIdentity found == bindingLeaseIdentity binding
                  && leaseState found == Ready
                  && leaseProvider found == a.leaseProvider
              )

validateConnection :: PiRuntimeAdapter -> PiRuntimeInvocation -> IO ()
validateConnection a inv = do
  let config = a.config
  r <- readMVar a.runtime
  let profile = inv.connection.identity.profile
  when (inv.connection.identity.provider /= config.provider) $ throwIO (runtimeProtocolError "connection-provider-mismatch")
  when (config.ccPatch /= (profile == "cc-patch-subscription")) $ throwIO (runtimeProtocolError "connection-profile-mismatch")
  when (config.ccPatch && isNothing r.ccPatchEntrypoint) $ throwIO (runtimeProtocolError "cc-patch-not-ready")
  when (profile /= "api-key") $ do
    let catalog = if config.ccPatch then piCcPatchSubscriptionCatalog else piSubscriptionCatalog
    when (lookup config.provider catalog /= Just config.model) $ throwIO (runtimeProtocolError "subscription-model-mismatch")
    let reserve = publicationMargin + 2 * config.cancellationGrace
    when (config.credentialTtl < config.wallTimeout + reserve) $ throwIO (runtimeProtocolError "subscription-ttl-insufficient")

settle :: PiRuntimeInvocation -> TurnOutcome -> Integer -> Text -> Maybe Text -> Maybe Text -> IO RuntimeTurnSettlement
settle inv outcome appends code output continuation =
  throwLeft (mkRuntimeTurnSettlement inv.episodeId inv.turnId outcome appends code output continuation)

data Exec = Exec
  { materialization :: Maybe HostMaterialization
  , client :: Maybe PiHelperClient
  , root :: Maybe (FilePath, Maybe (Integer, Integer))
  , attempted :: Bool
  , connectionSettled :: Bool
  , clean :: Bool
  , outcome :: TurnOutcome
  , code :: Text
  , outputRef :: Maybe Text
  , continuationRef :: Maybe Text
  }

-- | @_execute@: authority, helper, claim, admission, checkpoint and
-- publication, with cleanup and release precedence kept explicit.
executeOperation :: PiRuntimeAdapter -> PiOperation -> IO (RuntimeTurnSettlement, RuntimeCleanupDisposition)
executeOperation a operation = do
  let config = a.config
  r <- readMVar a.runtime
  let inv = operation.inv
      prior = operation.prior
      subscription = inv.connection.identity.profile `elem` ["subscription", "cc-patch-subscription"]
      ids name = inv.operationId <> "." <> name
      reserve = if subscription then publicationMargin + 2 * config.cancellationGrace else 0
  now0 <- adapterNow a
  let attachmentRemaining = max 0 (Episode.episodeDeadline inv.attachment - now0)
      runBudget = min config.wallTimeout (max 0 (attachmentRemaining - reserve))
  deadline <- (+ runBudget) <$> getMonotonicTime
  state <- newIORef (Exec Nothing Nothing Nothing False False True TurnFailed "runtime-failed" Nothing Nothing)
  let set f = modifyIORef' state f
      body = do
        live <- operationCurrent operation
        unless live $ protocol "cancelled"
        now <- adapterNow a
        when (runBudget <= 0 || now >= Episode.episodeDeadline inv.attachment) $ protocol "deadline-exceeded"
        set (\s -> s {attempted = True})
        let mode = if subscription then LeaseRefresh else LeaseRead
        materialization <-
          a.custody.materialize
            inv.connection.identity.connectionId
            config.hostId
            mode
            (min config.credentialTtl (max 0.001 (runBudget + reserve)))
            (ids "materialize")
        set (\s -> s {materialization = Just materialization})
        when (materialization.mode /= mode) $ protocol "custody-materialization-mismatch"
        let fence = materialization.fence
        when
          ( (fence.connectionId, fence.hostId, fence.authorityEpoch, fence.baseVersion)
              /= (inv.connection.identity.connectionId, config.hostId, inv.connection.authorityEpoch, inv.connection.stateVersion)
          )
          $ protocol "custody-state-mismatch"
        credential <- materialization.home.read
        let bound = if subscription then config.maxAuthBytes else maxKey
        when (B.null credential || B.length credential > bound) $ protocol "credential-invalid"
        apiKey <-
          if subscription
            then do
              case validateNativeAuth credential config.provider config.maxAuthBytes of
                Right _ -> pure ()
                Left e | credentialRefusal e -> protocol "credential-invalid"
                Left e -> throwIO e
              pure Nothing
            else case TE.decodeUtf8' credential of
              Right key | isBoundedText maxKey key -> pure (Just key)
              _ -> protocol "credential-invalid"
        let nativeAuth = if subscription then Just credential else Nothing
        rootPath <- createTempDirectory config.runtimeRoot "operation-"
        Files.setFileMode rootPath 0o700
        metadata <- Files.getSymbolicLinkStatus rootPath
        uid <- getEffectiveUserID
        set (\s -> s {root = Just (rootPath, Nothing)})
        when (not (Files.isDirectory metadata) || Files.fileMode metadata .&. 0o7777 /= 0o700 || Files.fileOwner metadata /= uid) $
          protocol "private-root-invalid"
        let identity = (toInteger (Files.deviceID metadata), toInteger (Files.fileID metadata))
        set (\s -> s {root = Just (rootPath, Just identity)})
        factoryNode <- maybe (throwIO (valueError "Pi node is not ready")) pure r.node
        factorySdk <- maybe (throwIO (valueError "Pi SDK is not ready")) pure r.sdkEntrypoint
        client <-
          operation.factory.create
            PiHelperArgs
              { node = factoryNode
              , sdkEntrypoint = factorySdk
              , privateRoot = rootPath
              , config
              , invocation = inv
              , prior
              , apiKey
              , nativeAuth
              , extension = if config.ccPatch then r.ccPatchEntrypoint else Nothing
              }
        set (\s -> s {client = Just client})
        when subscription $ a.custody.activate materialization (ids "activate")
        helperResult <- client.run inv.gateway inv (operationCurrent operation) deadline
        let candidate = helperResult.candidate
        if subscription
          then do
            returned <- case helperResult.nativeAuth of
              Just value
                | (isNothing candidate && helperResult.code == "provider-failed")
                    || (isJust candidate && helperResult.code == "turn-completed") ->
                    pure value
              _ -> protocol "credential-invalid"
            case validateNativeAuth returned config.provider config.maxAuthBytes of
              Right _ -> pure ()
              Left e | credentialRefusal e -> protocol "credential-invalid"
              Left e -> throwIO e
            closedClean <- client.close
            set (\s -> s {client = Nothing, clean = closedClean && s.clean})
            removed <- removeRoot rootPath (Just identity)
            set (\s -> s {root = Nothing, clean = removed && s.clean})
            clean <- (.clean) <$> readIORef state
            unless clean $ protocol "private-cleanup-uncertain"
          else when (isNothing candidate || isJust helperResult.nativeAuth || helperResult.code /= "turn-completed") $
            protocol "malformed-complete"
        claim operation >>= maybe (pure ()) protocol
        admission <- a.custody.admitResult fence (ids "admit")
        when (admission.operationId /= ids "admit" || admission.purpose /= "result" || admission.attachmentId /= fence.attachmentId) $
          protocol "custody-admission-mismatch"
        when subscription $ do
          materialization.home.replace (fromMaybe B.empty helperResult.nativeAuth)
          publication <- a.custody.checkpoint materialization (ids "checkpoint")
          let verified = checkpointVerified publication (ids "checkpoint") fence.attachmentId inv
          set (\s -> s {connectionSettled = verified})
          unless verified $ protocol "connection-publication-mismatch"
        case candidate of
          Just cand -> do
            output <- a.turns.storeTurn inv.operationId cand.text >>= throwLeft . piText "Pi output reference" 512
            set (\s -> s {outputRef = Just output})
            payload <- throwLeft (mkPiContinuationPayloadV1 cand.sessionId (workingBinding config.workingDirectory) cand.sessionJsonl)
            continuationRef <- codecStore a.codec inv.operationId payload
            set (\s -> s {continuationRef = Just continuationRef, outcome = TurnCompleted, code = "turn-completed"})
          Nothing -> set (\s -> s {outcome = TurnFailed, code = "provider-failed"})
  outcome <- try body
  case outcome of
    Right () -> pure ()
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | Just failure <- fromException e, Just code <- runtimeProtocolErrorCode failure -> do
          live <- operationCurrent operation
          let cancelled = not live || code == "cancelled"
          set (\s -> s {code = if cancelled then "cancelled" else code, outcome = if cancelled then TurnCancelled else TurnFailed})
      | otherwise -> do
          live <- operationCurrent operation
          set (\s -> s {code = "runtime-failed", outcome = if live then TurnFailed else TurnCancelled})
  -- finally
  s <- readIORef state
  forM_ s.client $ \client -> do
    -- As in the reference, a raising close escapes the remaining cleanup.
    closedClean <- client.close
    set (\x -> x {clean = closedClean && x.clean})
  forM_ s.root $ \(path, identity) -> do
    removed <- removeRoot path identity
    set (\x -> x {clean = removed && x.clean})
  when (not s.connectionSettled) $ forM_ s.materialization $ \materialization -> do
    verified <-
      (releaseVerified <$> a.custody.release materialization (ids "release") <*> pure (ids "release") <*> pure materialization.fence.attachmentId)
        `catch` \(e :: SomeException) -> rethrowAsync e >> pure False
    set (\x -> x {clean = verified && x.clean})
  final <- readIORef state
  if not final.clean
    then (,RuntimeCleanupUnverified) <$> settle inv TurnFailed 0 "cleanup-unverified" Nothing Nothing
    else do
      let completed = final.outcome == TurnCompleted
      settlement <-
        settle
          inv
          final.outcome
          (if completed then 1 else 0)
          final.code
          (if completed then final.outputRef else Nothing)
          (if completed then final.continuationRef else Nothing)
      pure (settlement, if final.attempted then RuntimeCleanupClean else RuntimeCleanupNotCreated)
  where
    -- @except UnicodeDecodeError, json.JSONDecodeError, ValueError@.
    credentialRefusal e = e `isInstanceOf` E.ValueError || e.errorClass == OtherError "UnicodeDecodeError"

releaseVerified :: ReleaseResult -> Text -> Text -> Bool
releaseVerified value operationId attachmentId =
  value.operationId == operationId
    && value.cleanup.attachmentId == attachmentId
    && (value.cleanup.removed || value.cleanup.alreadyAbsent)
    && not value.cleanup.securityViolation

checkpointVerified :: PublicationResult -> Text -> Text -> PiRuntimeInvocation -> Bool
checkpointVerified value operationId attachmentId inv =
  value.operationId == operationId
    && value.connection.identity == inv.connection.identity
    && value.connection.status == StatusReady
    && value.connection.authorityEpoch == inv.connection.authorityEpoch
    && value.connection.stateVersion == inv.connection.stateVersion + 1
    && value.cleanup.attachmentId == attachmentId
    && (value.cleanup.removed || value.cleanup.alreadyAbsent)
    && not value.cleanup.securityViolation

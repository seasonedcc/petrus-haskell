-- | Supported provider-neutral execution-territory contract
-- (@petrus.motus.execution@).
--
-- Motus owns temporary execution territories without assigning agent,
-- Thread, Episode, Activity, or canonical-History meaning to them.  Concrete
-- providers live in sibling modules and may offer different capability keys.
--
-- Values whose upstream constructors validate their inputs are built with
-- smart constructors returning @Either ExecutionError@; the record
-- constructors are not exported, so every value in hand satisfies the
-- upstream invariants.
module Petrus.Motus.Execution
  ( -- * Bounds
    maxCommandOutputBytes
  , maxPrivateFileBytes
  , maxPrivateFileNameBytes
  , maxPrivateFilesPerAttachment
  , maxPrivateFileTotalBytes
    -- * Capabilities and states
  , Capability (..)
  , capCommandCancellation
  , capContainer
  , capExplicitEnvironment
  , capMicrovm
  , capPrivateFileTransfer
  , capProcessGroup
  , capRecreatableLookup
  , capTerritoryCancellation
  , capVm
  , capWorkspace
  , LeaseState (..)
  , leaseStateText
  , ReconcileClass (..)
  , reconcileClassText
  , CleanupDisposition (..)
  , cleanupDispositionText
    -- * Specs and leases
  , EnvironmentSpec
  , specImage
  , specRequiredCapabilities
  , defaultSpec
  , mkEnvironmentSpec
  , LeaseIdentity
  , identityOperationId
  , identityProvider
  , identityLeaseId
  , mkLeaseIdentity
  , EnvironmentLease
  , leaseOperationId
  , leaseProvider
  , leaseId
  , leaseCapabilities
  , leaseState
  , leaseIdentity
  , mkEnvironmentLease
  , ExecutionAttachment
  , attachmentId
  , attachmentLease
  , attachmentInputDigest
  , attachmentWorkspace
  , mkExecutionAttachment
  , ExecutionProvenance
  , provenanceOperationId
  , provenanceProvider
  , provenanceLeaseId
  , provenanceIdentity
  , mkExecutionProvenance
  , leaseProvenance
    -- * Commands
  , Seconds (..)
  , secondsToDouble
  , CommandSpec (..)
  , commandSpec
  , Command
  , commandArgv
  , commandCwd
  , commandEnvironment
  , commandTimeout
  , commandOutputLimit
  , commandIsCurrent
  , commandPrivateRoots
  , mkCommand
  , CommandResult
  , resultReturncode
  , resultStdout
  , resultStderr
  , resultTimedOut
  , resultSuperseded
  , resultOutputTruncated
  , resultProvenance
  , mkCommandResult
    -- * Private files
  , PrivateFile
  , privateFileName
  , privateFileContent
  , mkPrivateFile
  , PrivateFileRef
  , refFileId
  , refName
  , refAttachmentId
  , refProvenance
  , mkPrivateFileRef
  , PrivateFileCleanupResult
  , privateCleanupAttachmentId
  , privateCleanupProvenance
  , privateCleanupDisposition
  , privateCleanupRemoved
  , privateCleanupDetail
  , privateCleanupPhysicalErasureGuaranteed
  , privateCleanupVerified
  , mkPrivateFileCleanupResult
    -- * Recovery and cleanup
  , ReconcileResult
  , reconcileClassification
  , reconcileLease
  , reconcileDetail
  , terminalResult
  , retryableResult
  , uncertainResult
  , CleanupResult (..)
  , cleanupVerified
    -- * Providers
  , EnvironmentProvider (..)
  , PrivateFileTransfer (..)
    -- * Errors
  , module Petrus.Motus.Execution.Error
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Motus.Execution.Error
import Petrus.Json (pythonDict)
import Petrus.Json.Python (isPythonSpace)

-- ---------------------------------------------------------------------------
-- Bounds

maxCommandOutputBytes :: Int
maxCommandOutputBytes = 1000000

maxPrivateFileBytes :: Int
maxPrivateFileBytes = 1000000

maxPrivateFileNameBytes :: Int
maxPrivateFileNameBytes = 64

maxPrivateFilesPerAttachment :: Int
maxPrivateFilesPerAttachment = 16

maxPrivateFileTotalBytes :: Int
maxPrivateFileTotalBytes = 4000000

-- ---------------------------------------------------------------------------
-- Capabilities and states

-- | A capability key.  Shared keys have constants below; providers may
-- advertise extension keys, so the type is open.
newtype Capability = Capability {capabilityKey :: Text}
  deriving stock (Eq, Ord)

instance Show Capability where
  show (Capability key) = show key

capCommandCancellation
  , capContainer
  , capExplicitEnvironment
  , capMicrovm
  , capPrivateFileTransfer
  , capProcessGroup
  , capRecreatableLookup
  , capTerritoryCancellation
  , capVm
  , capWorkspace
    :: Capability
capCommandCancellation = Capability "command-cancellation"
capContainer = Capability "container"
capExplicitEnvironment = Capability "explicit-environment"
capMicrovm = Capability "microvm"
capPrivateFileTransfer = Capability "private-file-transfer"
capProcessGroup = Capability "process-group"
capRecreatableLookup = Capability "recreatable-lookup"
capTerritoryCancellation = Capability "territory-cancellation"
capVm = Capability "vm"
capWorkspace = Capability "workspace"

-- | Provider-observed state of one territory lease.
data LeaseState = Ready | Terminal | Uncertain
  deriving stock (Eq, Ord, Show, Enum, Bounded)

leaseStateText :: LeaseState -> Text
leaseStateText = \case
  Ready -> "ready"
  Terminal -> "terminal"
  Uncertain -> "uncertain"

-- | Whether an operation is terminal, safe to retry, or still uncertain.
data ReconcileClass = ReconcileTerminal | ReconcileRetryable | ReconcileUncertain
  deriving stock (Eq, Ord, Show, Enum, Bounded)

reconcileClassText :: ReconcileClass -> Text
reconcileClassText = \case
  ReconcileTerminal -> "terminal"
  ReconcileRetryable -> "retryable"
  ReconcileUncertain -> "uncertain"

-- | Independently consumable result of one identity-correlated destroy.
data CleanupDisposition = Clean | NotCreated | Unverified
  deriving stock (Eq, Ord, Show, Enum, Bounded)

cleanupDispositionText :: CleanupDisposition -> Text
cleanupDispositionText = \case
  Clean -> "clean"
  NotCreated -> "not-created"
  Unverified -> "unverified"

-- | @_text@: non-empty, already trimmed, no control characters.
checkText :: Text -> Text -> Either ExecutionError Text
checkText name value
  | T.null value
      || T.any isPythonSpace (T.take 1 value)
      || T.any isPythonSpace (T.takeEnd 1 value)
      || T.any (\c -> ord c < 32) value =
      Left (valueError (name <> " must be a non-empty trimmed string without control characters"))
  | otherwise = Right value

-- ---------------------------------------------------------------------------
-- Specs and leases

-- | Provider-neutral creation request and required capability constraints.
data EnvironmentSpec = EnvironmentSpec
  { specImage :: Maybe Text
  , specRequiredCapabilities :: Set Capability
  }
  deriving stock (Eq, Show)

defaultSpec :: EnvironmentSpec
defaultSpec = EnvironmentSpec Nothing Set.empty

mkEnvironmentSpec :: Maybe Text -> [Capability] -> Either ExecutionError EnvironmentSpec
mkEnvironmentSpec image capabilities = do
  checkedImage <- traverse (checkText "environment image") image
  checked <- traverse (fmap Capability . checkText "environment capability" . capabilityKey) capabilities
  pure (EnvironmentSpec checkedImage (Set.fromList checked))

-- | Stable provider identity for one temporary territory lease.
data LeaseIdentity = LeaseIdentity
  { identityOperationId :: Text
  , identityProvider :: Text
  , identityLeaseId :: Text
  }
  deriving stock (Eq, Ord, Show)

mkLeaseIdentity :: Text -> Text -> Text -> Either ExecutionError LeaseIdentity
mkLeaseIdentity operation provider lease =
  LeaseIdentity
    <$> checkText "lease operation_id" operation
    <*> checkText "lease provider" provider
    <*> checkText "lease lease_id" lease

-- | Detached provider lease fact; state may change while identity remains.
data EnvironmentLease = EnvironmentLease
  { leaseOperationId :: Text
  , leaseProvider :: Text
  , leaseId :: Text
  , leaseCapabilities :: Set Capability
  , leaseState :: LeaseState
  }
  deriving stock (Eq, Show)

mkEnvironmentLease :: Text -> Text -> Text -> Set Capability -> LeaseState -> Either ExecutionError EnvironmentLease
mkEnvironmentLease operation provider lease capabilities state = do
  identity <- mkLeaseIdentity operation provider lease
  checked <- traverse (fmap Capability . checkText "environment capability" . capabilityKey) (Set.toList capabilities)
  pure
    ( EnvironmentLease
        (identityOperationId identity)
        (identityProvider identity)
        (identityLeaseId identity)
        (Set.fromList checked)
        state
    )

leaseIdentity :: EnvironmentLease -> LeaseIdentity
leaseIdentity lease = LeaseIdentity (leaseOperationId lease) (leaseProvider lease) (leaseId lease)

-- | One workspace/archive binding to a current territory lease.
data ExecutionAttachment = ExecutionAttachment
  { attachmentId :: Text
  , attachmentLease :: EnvironmentLease
  , attachmentInputDigest :: Text
  , attachmentWorkspace :: FilePath
  }
  deriving stock (Eq, Show)

mkExecutionAttachment :: Text -> EnvironmentLease -> Text -> FilePath -> Either ExecutionError ExecutionAttachment
mkExecutionAttachment identifier lease digest workspace =
  ExecutionAttachment
    <$> checkText "attachment_id" identifier
    <*> pure lease
    <*> checkText "attachment input_digest" digest
    <*> pure workspace

-- | Lease correlation attached to one command result.
data ExecutionProvenance = ExecutionProvenance
  { provenanceOperationId :: Text
  , provenanceProvider :: Text
  , provenanceLeaseId :: Text
  }
  deriving stock (Eq, Ord, Show)

mkExecutionProvenance :: Text -> Text -> Text -> Either ExecutionError ExecutionProvenance
mkExecutionProvenance operation provider lease = do
  identity <- mkLeaseIdentity operation provider lease
  pure (ExecutionProvenance (identityOperationId identity) (identityProvider identity) (identityLeaseId identity))

provenanceIdentity :: ExecutionProvenance -> LeaseIdentity
provenanceIdentity p = LeaseIdentity (provenanceOperationId p) (provenanceProvider p) (provenanceLeaseId p)

-- | The provenance of a (valid) lease.
leaseProvenance :: EnvironmentLease -> ExecutionProvenance
leaseProvenance lease = ExecutionProvenance (leaseOperationId lease) (leaseProvider lease) (leaseId lease)

-- ---------------------------------------------------------------------------
-- Commands

-- | A duration that remembers whether it was written as an integer or a
-- float, because it is rendered into wire formats with Python's @str()@ /
-- @json.dumps@ (@5@ versus @5.0@).  Integer literals give 'WholeSeconds',
-- fractional literals 'FractionalSeconds'.
data Seconds = WholeSeconds Integer | FractionalSeconds Double
  deriving stock (Eq, Show)

instance Num Seconds where
  fromInteger = WholeSeconds
  a + b = FractionalSeconds (secondsToDouble a + secondsToDouble b)
  a * b = FractionalSeconds (secondsToDouble a * secondsToDouble b)
  abs = FractionalSeconds . abs . secondsToDouble
  signum = FractionalSeconds . signum . secondsToDouble
  negate = \case
    WholeSeconds n -> WholeSeconds (negate n)
    FractionalSeconds d -> FractionalSeconds (negate d)

instance Fractional Seconds where
  fromRational = FractionalSeconds . fromRational
  a / b = FractionalSeconds (secondsToDouble a / secondsToDouble b)

secondsToDouble :: Seconds -> Double
secondsToDouble = \case
  WholeSeconds n -> fromInteger n
  FractionalSeconds d -> d

-- | The unvalidated command request; 'commandSpec' fills upstream defaults.
data CommandSpec = CommandSpec
  { specArgv :: [Text]
  , specCwd :: FilePath
  , specEnvironment :: [(Text, Text)]
  , specTimeout :: Maybe Seconds
  , specOutputLimit :: Int
  , specIsCurrent :: Maybe (IO Bool)
  , specPrivateRoots :: [(Text, PrivateFileRef)]
  }

-- | @Command(argv)@ with upstream defaults.
commandSpec :: [Text] -> CommandSpec
commandSpec argv = CommandSpec argv "." [] Nothing maxCommandOutputBytes Nothing []

-- | One bounded command with an optional timeout and a currency check.
-- Equality ignores the currency check; 'Show' omits private roots.
data Command = Command
  { commandArgv :: [Text]
  , commandCwd :: FilePath
  -- ^ Normalized like @pathlib.Path@ (always relative).
  , commandEnvironment :: [(Text, Text)]
  -- ^ Insertion-ordered, unique names.
  , commandTimeout :: Maybe Seconds
  , commandOutputLimit :: Int
  , commandIsCurrent :: Maybe (IO Bool)
  , commandPrivateRoots :: [(Text, PrivateFileRef)]
  }

instance Eq Command where
  a == b =
    (commandArgv a, commandCwd a, commandEnvironment a, commandTimeout a, commandOutputLimit a, commandPrivateRoots a)
      == (commandArgv b, commandCwd b, commandEnvironment b, commandTimeout b, commandOutputLimit b, commandPrivateRoots b)

instance Show Command where
  showsPrec d c =
    showParen (d > 10) $
      showString "Command {argv = "
        . shows (commandArgv c)
        . showString ", cwd = "
        . shows (commandCwd c)
        . showString ", environment = "
        . shows (commandEnvironment c)
        . showString ", timeout = "
        . shows (commandTimeout c)
        . showString ", output_limit = "
        . shows (commandOutputLimit c)
        . showString "}"

environmentName :: Text -> Bool
environmentName name = case T.uncons name of
  Just (first, rest) -> (isAsciiLetter first || first == '_') && T.all (\c -> isAsciiLetter c || isDigit c || c == '_') rest
  Nothing -> False
  where
    isAsciiLetter c = isAsciiUpper c || isAsciiLower c

-- | @str(pathlib.PurePosixPath(p))@ and whether it is absolute.
pathlibNormalize :: FilePath -> (Bool, FilePath)
pathlibNormalize path =
  let absolute = take 1 path == "/"
      anchor
        | take 2 path == "//" && take 3 path /= "///" = "//"
        | absolute = "/"
        | otherwise = ""
      parts = filter (\p -> not (null p) && p /= ".") (splitOn path)
      joined = anchor <> concatWith parts
   in (absolute, if null joined then "." else joined)
  where
    splitOn s = case break (== '/') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitOn rest
    concatWith [] = ""
    concatWith [x] = x
    concatWith (x : xs) = x <> "/" <> concatWith xs

-- | Validate a command request (upstream @Command.__post_init__@).
mkCommand :: CommandSpec -> Either ExecutionError Command
mkCommand spec = do
  let argv = specArgv spec
      (absolute, cwd) = pathlibNormalize (specCwd spec)
      timeoutValid = case specTimeout spec of
        Nothing -> True
        Just t -> let d = secondsToDouble t in not (isNaN d || isInfinite d) && d > 0
      outputValid = specOutputLimit spec >= 0 && specOutputLimit spec <= maxCommandOutputBytes
  if null argv || absolute || not timeoutValid || not outputValid
    then
      Left
        ( valueError
            ( "command requires argv, a relative cwd, a positive finite timeout, and an output limit between 0 and "
                <> T.pack (show maxCommandOutputBytes)
                <> " bytes"
            )
        )
    else Right ()
  let environment = pythonDict (specEnvironment spec)
      privateRoots = pythonDict (specPrivateRoots spec)
  if any (T.elem '\NUL') argv
    || any (\(k, v) -> not (environmentName k) || T.elem '\NUL' k || T.elem '\NUL' v) environment
    then Left (valueError "invalid command or environment value")
    else Right ()
  if length privateRoots > maxPrivateFilesPerAttachment
    || any (\(k, _) -> not (environmentName k) || k `elem` map fst environment) privateRoots
    then Left (valueError "invalid command private root binding")
    else Right ()
  pure (Command argv cwd environment (specTimeout spec) (specOutputLimit spec) (specIsCurrent spec) privateRoots)

-- | Bounded process result correlated to the territory that produced it.
data CommandResult = CommandResult
  { resultReturncode :: Int
  , resultStdout :: ByteString
  , resultStderr :: ByteString
  , resultTimedOut :: Bool
  , resultSuperseded :: Bool
  , resultOutputTruncated :: Bool
  , resultProvenance :: ExecutionProvenance
  }
  deriving stock (Eq, Show)

mkCommandResult
  :: Int -> ByteString -> ByteString -> Bool -> Bool -> Bool -> ExecutionProvenance -> Either ExecutionError CommandResult
mkCommandResult code out err timedOut superseded truncated provenance
  | B.length out + B.length err > maxCommandOutputBytes =
      Left (valueError "command result exceeds the supported output bound")
  | otherwise = Right (CommandResult code out err timedOut superseded truncated provenance)

-- ---------------------------------------------------------------------------
-- Private files

checkPrivateFileName :: Text -> Either ExecutionError Text
checkPrivateFileName name
  | name `elem` [".", ".."]
      || not (T.all (\c -> ord c < 128) name)
      || B.length (TE.encodeUtf8 name) > maxPrivateFileNameBytes
      || not (safe name) =
      Left (valueError "private file name must be one bounded safe ASCII filename component")
  | otherwise = Right name
  where
    safe value = case T.uncons value of
      Just (first, rest) -> alnum first && T.all (\c -> alnum c || c `elem` ("._-" :: String)) rest
      Nothing -> False
    alnum c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | One bounded opaque file entering or leaving provider-private custody.
-- 'Show' never prints the content.
data PrivateFile = PrivateFile
  { privateFileName :: Text
  , privateFileContent :: ByteString
  }
  deriving stock (Eq)

instance Show PrivateFile where
  show file = "PrivateFile {name = " <> show (privateFileName file) <> "}"

mkPrivateFile :: Text -> ByteString -> Either ExecutionError PrivateFile
mkPrivateFile name content = do
  checked <- checkPrivateFileName name
  if B.length content > maxPrivateFileBytes
    then Left (valueError ("private file content exceeds the " <> T.pack (show maxPrivateFileBytes) <> "-byte bound"))
    else Right (PrivateFile checked content)

-- | Path-free reference to one file under an exact territory attachment.
data PrivateFileRef = PrivateFileRef
  { refFileId :: Text
  , refName :: Text
  , refAttachmentId :: Text
  , refProvenance :: ExecutionProvenance
  }
  deriving stock (Eq, Ord, Show)

mkPrivateFileRef :: Text -> Text -> Text -> ExecutionProvenance -> Either ExecutionError PrivateFileRef
mkPrivateFileRef fileId name attachment provenance =
  PrivateFileRef
    <$> checkText "private file_id" fileId
    <*> checkPrivateFileName name
    <*> checkText "private file attachment_id" attachment
    <*> pure provenance

-- | Path-free, independently consumable cleanup evidence for private files.
data PrivateFileCleanupResult = PrivateFileCleanupResult
  { privateCleanupAttachmentId :: Text
  , privateCleanupProvenance :: ExecutionProvenance
  , privateCleanupDisposition :: CleanupDisposition
  , privateCleanupRemoved :: Int
  , privateCleanupDetail :: Text
  , privateCleanupPhysicalErasureGuaranteed :: Bool
  }
  deriving stock (Eq, Show)

mkPrivateFileCleanupResult
  :: Text -> ExecutionProvenance -> CleanupDisposition -> Int -> Text -> Bool -> Either ExecutionError PrivateFileCleanupResult
mkPrivateFileCleanupResult attachment provenance disposition removed detail erasure = do
  checked <- checkText "private cleanup attachment_id" attachment
  if removed < 0
    then Left (valueError "private cleanup removed count must be a non-negative integer")
    else Right (PrivateFileCleanupResult checked provenance disposition removed detail erasure)

-- | Whether cleanup may pass a fail-closed private-custody gate.
privateCleanupVerified :: PrivateFileCleanupResult -> Bool
privateCleanupVerified result = privateCleanupDisposition result `elem` [Clean, NotCreated]

-- ---------------------------------------------------------------------------
-- Recovery and cleanup

-- | Lookup-first recovery classification for one operation identity.  A
-- terminal result always carries the observed lease and a retryable one
-- never does; the smart constructors make other combinations
-- unrepresentable.
data ReconcileResult = ReconcileResult
  { reconcileClassification :: ReconcileClass
  , reconcileLease :: Maybe EnvironmentLease
  , reconcileDetail :: Text
  }
  deriving stock (Eq, Show)

terminalResult :: EnvironmentLease -> Text -> ReconcileResult
terminalResult lease = ReconcileResult ReconcileTerminal (Just lease)

retryableResult :: Text -> ReconcileResult
retryableResult = ReconcileResult ReconcileRetryable Nothing

uncertainResult :: Maybe EnvironmentLease -> Text -> ReconcileResult
uncertainResult = ReconcileResult ReconcileUncertain

-- | Fail-closed destruction evidence for one exact lease identity.
data CleanupResult = CleanupResult
  { cleanupIdentity :: LeaseIdentity
  , cleanupDisposition :: CleanupDisposition
  , cleanupDetail :: Text
  }
  deriving stock (Eq, Show)

-- | Whether cleanup may pass a fail-closed settlement gate.
cleanupVerified :: CleanupResult -> Bool
cleanupVerified result = cleanupDisposition result `elem` [Clean, NotCreated]

-- ---------------------------------------------------------------------------
-- Providers

-- | The supported territory lifecycle; creation and recovery are
-- lookup-first.  'providerPrivateFiles' is the optional private-file
-- transfer extension (upstream's @PrivateFileTransfer@ protocol).
data EnvironmentProvider = EnvironmentProvider
  { providerName :: Text
  , providerCapabilities :: Set Capability
  , providerCreate :: Text -> EnvironmentSpec -> IO EnvironmentLease
  , providerLookup :: Text -> IO (Maybe EnvironmentLease)
  , providerAttach :: EnvironmentLease -> ByteString -> Text -> IO ExecutionAttachment
  , providerExecute :: ExecutionAttachment -> Command -> IO CommandResult
  , providerExport :: ExecutionAttachment -> IO ByteString
  , providerCancel :: EnvironmentLease -> Text -> IO ()
  , providerReconcile :: Text -> IO ReconcileResult
  , providerDestroy :: EnvironmentLease -> IO CleanupResult
  , providerPrivateFiles :: Maybe PrivateFileTransfer
  }

-- | Complete private-file import, command binding, export, and cleanup.
data PrivateFileTransfer = PrivateFileTransfer
  { importPrivateFile :: ExecutionAttachment -> PrivateFile -> IO PrivateFileRef
  , exportPrivateFile :: ExecutionAttachment -> PrivateFileRef -> IO PrivateFile
  , deletePrivateFile :: ExecutionAttachment -> PrivateFileRef -> IO PrivateFileCleanupResult
  , cleanupPrivateFiles :: ExecutionAttachment -> IO PrivateFileCleanupResult
  }

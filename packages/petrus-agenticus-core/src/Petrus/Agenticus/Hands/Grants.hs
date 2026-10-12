-- | Provider-neutral capability policy and immutable attachment-bound grants
-- (@petrus.agenticus.hands.grants@).
--
-- A grant is the only source of tool authority.  Every grant is bound to one
-- exact attachment identity and epoch, carries an exact capability set, a
-- finite call budget, and a finite deadline, and can never be inherited after
-- the attachment it names is replaced.
module Petrus.Agenticus.Hands.Grants
  ( -- * Grants
    CapabilityGrant
      ( attachmentId
      , attachmentEpoch
      , grantEpoch
      , capabilities
      , writablePaths
      , allowedArgv
      , deadline
      , maxCalls
      , writableRoots
      , deniedWritableRoots
      )
  , mkCapabilityGrant
  , permits
  , permitsWritePath
    -- * Opening grants
  , GrantSpec (..)
  , grantSpec
    -- * The ledger
  , GrantLedger (attachmentId, attachmentEpoch)
  , newGrantLedger
  , currentGrant
  , openGrant
  , tryOpenGrant
  , closeGrant
  , consumeGrant
  , tryConsumeGrant
  ) where

import Control.Exception (throwIO)
import Data.Char (ord)
import Data.IORef
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), maxArgvPartChars, maxArgvParts, maxPathChars)
import Petrus.Agenticus.Internal.Validate

-- | One immutable, finite, deadline-bounded authority for one attachment
-- epoch.
data CapabilityGrant = CapabilityGrant
  { attachmentId :: Text
  , attachmentEpoch :: Integer
  , grantEpoch :: Integer
  , capabilities :: Set ToolMethod
  , writablePaths :: Set Text
  , allowedArgv :: Set [Text]
  , deadline :: Double
  , maxCalls :: Integer
  , writableRoots :: Set Text
  , deniedWritableRoots :: Set Text
  }
  deriving stock (Eq, Show)

identity :: Text -> Text -> Either AgenticusError Text
identity name = checkedText maxTextBytes (valueError (name <> " must be a bounded non-empty identity string"))

positive :: Text -> Integer -> Either AgenticusError Integer
positive name value
  | value > 0 = Right value
  | otherwise = Left (valueError (name <> " must be a positive integer"))

writablePath :: Text -> Either AgenticusError Text
writablePath value = do
  path <- identity "grant writable path" value
  if T.length path > maxPathChars
    || "/" `T.isPrefixOf` path
    || T.any (== '\\') path
    || any (`elem` ["", ".", ".."]) (T.splitOn "/" path)
    then Left (valueError "grant writable path must be a bounded normalized relative path")
    else Right path

writableRoot :: Text -> Either AgenticusError Text
writableRoot = \case
  "." -> Right "."
  value -> writablePath value

argvCommand :: [Text] -> Either AgenticusError [Text]
argvCommand command
  | any badPart command || null command || length command > maxArgvParts =
      Left (valueError "grant argv command must be 1..4 bounded non-empty parts")
  | otherwise = Right command
  where
    badPart part =
      T.null part
        || T.length part > maxArgvPartChars
        || T.any (== '\\') part
        || T.any (\c -> ord c < 32 || ord c == 127) part
        || any (`elem` [".", ".."]) (T.splitOn "/" part)

-- | @CapabilityGrant(...)@ in upstream positional order, validated in
-- upstream order.
mkCapabilityGrant
  :: Text
  -> Integer
  -> Integer
  -> [ToolMethod]
  -> [Text]
  -> [[Text]]
  -> Double
  -> Integer
  -> [Text]
  -> [Text]
  -> Either AgenticusError CapabilityGrant
mkCapabilityGrant attachment attachmentEpoch' grantEpoch' caps paths argv deadline' maxCalls' roots denied = do
  a <- identity "grant attachment_id" attachment
  ae <- positive "grant attachment_epoch" attachmentEpoch'
  ge <- positive "grant grant_epoch" grantEpoch'
  ps <- traverse writablePath paths
  av <- traverse argvCommand argv
  if isNaN deadline' || isInfinite deadline'
    then Left (valueError "grant deadline must be a finite number")
    else Right ()
  mc <- positive "grant max_calls" maxCalls'
  rs <- traverse writableRoot roots
  ds <- traverse writableRoot denied
  Right
    CapabilityGrant
      { attachmentId = a
      , attachmentEpoch = ae
      , grantEpoch = ge
      , capabilities = Set.fromList caps
      , writablePaths = Set.fromList ps
      , allowedArgv = Set.fromList av
      , deadline = deadline'
      , maxCalls = mc
      , writableRoots = Set.fromList rs
      , deniedWritableRoots = Set.fromList ds
      }

permits :: CapabilityGrant -> ToolMethod -> Bool
permits grant m = m `Set.member` grant.capabilities

-- | Whether one normalized path is inside this grant's exact write scope.
-- Denied roots take precedence over exact paths and writable roots; root
-- matching is by whole path segments.
permitsWritePath :: CapabilityGrant -> Text -> Bool
permitsWritePath grant path
  | any under (Set.toList grant.deniedWritableRoots) = False
  | otherwise = path `Set.member` grant.writablePaths || any under (Set.toList grant.writableRoots)
  where
    under root = root == "." || path == root || (root <> "/") `T.isPrefixOf` path

-- | The arguments of @GrantLedger.open@.
data GrantSpec = GrantSpec
  { specCapabilities :: [ToolMethod]
  , specWritablePaths :: [Text]
  , specWritableRoots :: [Text]
  , specDeniedWritableRoots :: [Text]
  , specAllowedArgv :: [[Text]]
  , specDeadline :: Double
  , specMaxCalls :: Integer
  }
  deriving stock (Eq, Show)

-- | Capabilities, deadline and call budget, with no write scope or argv.
grantSpec :: [ToolMethod] -> Double -> Integer -> GrantSpec
grantSpec caps deadline' maxCalls' =
  GrantSpec
    { specCapabilities = caps
    , specWritablePaths = []
    , specWritableRoots = []
    , specDeniedWritableRoots = []
    , specAllowedArgv = []
    , specDeadline = deadline'
    , specMaxCalls = maxCalls'
    }

data LedgerState = LedgerState
  { lastEpoch :: Integer
  , current :: Maybe CapabilityGrant
  , consumed :: Integer
  }

-- | Attachment-scoped grant custody with strictly increasing grant epochs.
--
-- The ledger holds at most one current grant.  Opening a grant for a new
-- attachment epoch permanently retires every grant of prior epochs, so no
-- authority survives attachment replacement.  Every operation is one atomic
-- update of a single reference (upstream's @RLock@).
data GrantLedger = GrantLedger
  { attachmentId :: Text
  , attachmentEpoch :: Integer
  , state :: IORef LedgerState
  }

newGrantLedger :: Text -> Integer -> IO GrantLedger
newGrantLedger attachment epoch = do
  a <- throwLeft (identity "ledger attachment_id" attachment)
  e <- throwLeft (positive "ledger attachment_epoch" epoch)
  GrantLedger a e <$> newIORef (LedgerState 0 Nothing 0)

currentGrant :: GrantLedger -> IO (Maybe CapabilityGrant)
currentGrant ledger = (.current) <$> readIORef ledger.state

-- | Issue the next grant epoch, replacing any current grant.  An invalid
-- spec leaves the ledger unchanged.
tryOpenGrant :: GrantLedger -> GrantSpec -> IO (Either AgenticusError CapabilityGrant)
tryOpenGrant ledger spec = atomicModifyIORef' ledger.state $ \s ->
  case build (s.lastEpoch + 1) of
    Left e -> (s, Left e)
    Right grant -> (LedgerState grant.grantEpoch (Just grant) 0, Right grant)
  where
    build epoch =
      mkCapabilityGrant
        ledger.attachmentId
        ledger.attachmentEpoch
        epoch
        spec.specCapabilities
        spec.specWritablePaths
        spec.specAllowedArgv
        spec.specDeadline
        spec.specMaxCalls
        spec.specWritableRoots
        spec.specDeniedWritableRoots

openGrant :: GrantLedger -> GrantSpec -> IO CapabilityGrant
openGrant ledger spec = tryOpenGrant ledger spec >>= either throwIO pure

-- | Retire the current grant without opening a successor.
closeGrant :: GrantLedger -> IO ()
closeGrant ledger = atomicModifyIORef' ledger.state $ \s -> (s {current = Nothing, consumed = 0}, ())

-- | Spend one call of the exact current grant or refuse fail-closed
-- (@GrantLedgerError@ for a stale epoch, @GrantBudgetExhausted@ for a spent
-- budget).  The gateway consumes only when a call is admitted past its
-- prechecks, so rejected requests never spend grant budget.
tryConsumeGrant :: GrantLedger -> Integer -> IO (Either AgenticusError CapabilityGrant)
tryConsumeGrant ledger epoch = atomicModifyIORef' ledger.state $ \s -> case s.current of
  Just grant
    | grant.grantEpoch == epoch ->
        if s.consumed >= grant.maxCalls
          then (s, Left (agenticusError GrantBudgetExhausted "grant call budget is exhausted"))
          else (s {consumed = s.consumed + 1}, Right grant)
  _ -> (s, Left (agenticusError GrantLedgerError "grant epoch is not current for this attachment"))

consumeGrant :: GrantLedger -> Integer -> IO CapabilityGrant
consumeGrant ledger epoch = tryConsumeGrant ledger epoch >>= either throwIO pure

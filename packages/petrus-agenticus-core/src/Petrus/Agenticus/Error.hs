{-# LANGUAGE FieldSelectors #-}

-- | The one exception type every Agenticus operation raises.
--
-- Upstream Python signals failures with exception classes whose messages are
-- part of the observable contract (tests match on them, and several
-- operations surface them to hosts).  The Haskell port keeps the messages
-- byte-for-byte and records the Python class as an 'ErrorClass'.  The upstream
-- class hierarchy is kept by 'isInstanceOf', so a caller can test for
-- @CustodyError@ and accept every subclass the way @except CustodyError@ does.
module Petrus.Agenticus.Error
  ( ErrorClass (..)
  , errorClassName
  , parentClass
  , isSubclassOf
  , AgenticusError (..)
  , isInstanceOf
  , agenticusError
  , valueError
  , typeError
  , runtimeError
  , lookupError
  , throwAgenticus
  , throwLeft
  ) where

import Control.Exception (Exception, throwIO)
import Data.Text (Text)
import Data.Text qualified as T

-- | Every Python exception class an Agenticus failure surfaces as.
data ErrorClass
  = -- Builtins
    ValueError
  | TypeError
  | LookupError
  | KeyError
  | RuntimeError
  | TimeoutError
  | -- catalog
    CatalogRegistrationError
  | DuplicateRegistrationError
  | AmbiguousRegistrationError
  | UnknownRegistrationError
  | SelectionError
  | DuplicateSelectionError
  | AmbiguousSelectionError
  | -- thread
    ContinuationTransitionError
  | IncompatibleContinuation
  | LifecycleTransitionError
  | EpisodeBudgetExceeded
  | -- connection
    KeyOperationError
  | MaterializationError
  | MaterializationSecurityError
  | StorageError
  | StorageSecurityError
  | CustodyError
  | HostNotEnrolled
  | LeaseConflict
  | StaleCustody
  | StaleAttachment
  | ReauthorizationRequired
  | OperationConflict
  | StorageContention
  | -- hands
    ToolCallConflict
  | ToolRequestRejected
  | GrantLedgerError
  | GrantBudgetExhausted
  | WorkspaceAdapterError
  | ConformanceError
  | -- attachment
    MotusBindingError
  | EpisodeAttachmentError
  | UncertainCustodyError
  | -- runtime
    RuntimeProtocolError
  | AgentNetRunnerError
  | -- | Any other Python class, named verbatim.
    OtherError Text
  deriving stock (Eq, Ord, Show)

-- | The Python class name.
errorClassName :: ErrorClass -> Text
errorClassName = \case
  OtherError name -> name
  other -> T.pack (show other)

-- | The direct Python base class ('Nothing' for the builtin roots, which all
-- derive from @Exception@).
parentClass :: ErrorClass -> Maybe ErrorClass
parentClass = \case
  ValueError -> Nothing
  TypeError -> Nothing
  LookupError -> Nothing
  KeyError -> Just LookupError
  RuntimeError -> Nothing
  TimeoutError -> Nothing
  CatalogRegistrationError -> Just ValueError
  DuplicateRegistrationError -> Just CatalogRegistrationError
  AmbiguousRegistrationError -> Just CatalogRegistrationError
  UnknownRegistrationError -> Just LookupError
  SelectionError -> Just ValueError
  DuplicateSelectionError -> Just SelectionError
  AmbiguousSelectionError -> Just SelectionError
  ContinuationTransitionError -> Just ValueError
  IncompatibleContinuation -> Just ValueError
  LifecycleTransitionError -> Just ValueError
  EpisodeBudgetExceeded -> Just LifecycleTransitionError
  KeyOperationError -> Just RuntimeError
  MaterializationError -> Just RuntimeError
  MaterializationSecurityError -> Just MaterializationError
  StorageError -> Just RuntimeError
  StorageSecurityError -> Just StorageError
  CustodyError -> Just RuntimeError
  HostNotEnrolled -> Just CustodyError
  LeaseConflict -> Just CustodyError
  StaleCustody -> Just CustodyError
  StaleAttachment -> Just CustodyError
  ReauthorizationRequired -> Just CustodyError
  OperationConflict -> Just CustodyError
  StorageContention -> Just CustodyError
  ToolCallConflict -> Just RuntimeError
  ToolRequestRejected -> Just ValueError
  GrantLedgerError -> Just ValueError
  GrantBudgetExhausted -> Just GrantLedgerError
  WorkspaceAdapterError -> Just RuntimeError
  ConformanceError -> Just RuntimeError
  MotusBindingError -> Just RuntimeError
  EpisodeAttachmentError -> Just RuntimeError
  UncertainCustodyError -> Just EpisodeAttachmentError
  RuntimeProtocolError -> Just RuntimeError
  AgentNetRunnerError -> Just RuntimeError
  OtherError _ -> Nothing

-- | @issubclass(a, b)@.
isSubclassOf :: ErrorClass -> ErrorClass -> Bool
isSubclassOf a b
  | a == b = True
  | otherwise = maybe False (`isSubclassOf` b) (parentClass a)

-- | A failure: the Python class it corresponds to and the exact upstream
-- message (@str(error)@).
data AgenticusError = AgenticusError
  { errorClass :: ErrorClass
  , errorMessage :: Text
  }
  deriving stock (Eq, Show)

instance Exception AgenticusError

-- | @isinstance(error, cls)@.
isInstanceOf :: AgenticusError -> ErrorClass -> Bool
isInstanceOf e cls = errorClass e `isSubclassOf` cls

agenticusError :: ErrorClass -> Text -> AgenticusError
agenticusError = AgenticusError

valueError, typeError, runtimeError, lookupError :: Text -> AgenticusError
valueError = AgenticusError ValueError
typeError = AgenticusError TypeError
runtimeError = AgenticusError RuntimeError
lookupError = AgenticusError LookupError

throwAgenticus :: ErrorClass -> Text -> IO a
throwAgenticus cls message = throwIO (AgenticusError cls message)

-- | Raise a 'Left' in 'IO'.
throwLeft :: Either AgenticusError a -> IO a
throwLeft = either throwIO pure

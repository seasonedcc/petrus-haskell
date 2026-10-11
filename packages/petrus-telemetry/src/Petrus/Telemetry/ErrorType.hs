-- | The Python class name the reference reports for a failure
-- (@type(error).__name__@), for the Haskell exceptions that have a Python
-- counterpart.
--
-- A span's @error_type@ and the runtime's failure texts use this vocabulary,
-- so a mixed Python/Haskell deployment's dashboards see one spelling:
--
-- * an 'IOException' carrying an @errno@ is the 'OSError' subclass CPython
--   picks for that @errno@ (@FileNotFoundError@ for @ENOENT@,
--   @PermissionError@ for @EACCES@, ...), and @OSError@ without one;
-- * 'UserInterrupt' is @KeyboardInterrupt@, @async@'s @AsyncCancelled@ is
--   asyncio's @CancelledError@;
-- * 'DivideByZero' is @ZeroDivisionError@, 'Overflow' is @OverflowError@;
-- * an 'ExitCode' is @SystemExit@.
--
-- Callers that raise their own exceptions in the reference's vocabulary
-- (the Engine's @ValueError@/@TypeError@/@RuntimeError@, a handler's
-- recorded failure) name them through 'withSpanClassifying'
-- ("Petrus.Telemetry"). Any other Haskell exception has no Python class and
-- is named by its 'Typeable' type constructor (@ErrorCall@).
module Petrus.Telemetry.ErrorType
  ( pythonErrorType
  , oserrorSubclass
  , haskellTypeName
  ) where

import Control.Exception
  ( ArithException (..)
  , AsyncException (..)
  , SomeAsyncException (..)
  , SomeException (..)
  , fromException
  )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable, tyConModule, tyConName, typeOf, typeRepTyCon)
import Foreign.C.Error
  ( Errno (..)
  , eACCES
  , eAGAIN
  , eALREADY
  , eCHILD
  , eCONNABORTED
  , eCONNREFUSED
  , eCONNRESET
  , eEXIST
  , eINPROGRESS
  , eINTR
  , eISDIR
  , eNOENT
  , eNOTDIR
  , ePERM
  , ePIPE
  , eSHUTDOWN
  , eSRCH
  , eTIMEDOUT
  , eWOULDBLOCK
  )
import Foreign.C.Types (CInt (..))
import GHC.IO.Exception (IOException (..))
import System.Exit (ExitCode)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall unsafe "petrus_telemetry_enotcapable" c_enotcapable :: IO CInt

-- | @ENOTCAPABLE@ where the platform has one.
eNOTCAPABLE :: Maybe Errno
eNOTCAPABLE = case unsafePerformIO c_enotcapable of
  n | n < 0 -> Nothing
  n -> Just (Errno n)
{-# NOINLINE eNOTCAPABLE #-}

-- | The Python class name of an exception, as the reference would report
-- it: see the module header.
pythonErrorType :: SomeException -> Text
pythonErrorType some
  | Just (io :: IOException) <- fromException some = maybe "OSError" (oserrorSubclass . Errno) (ioe_errno io)
  | Just UserInterrupt <- fromException some = "KeyboardInterrupt"
  | Just DivideByZero <- fromException some = "ZeroDivisionError"
  | Just Overflow <- fromException some = "OverflowError"
  | Just (_ :: ExitCode) <- fromException some = "SystemExit"
  | Just (SomeAsyncException inner) <- fromException some = asyncName inner
  | SomeException e <- some = haskellTypeName e
  where
    asyncName inner
      | tyConName tc == "AsyncCancelled" && "Control.Concurrent.Async" `T.isPrefixOf` T.pack (tyConModule tc) = "CancelledError"
      | otherwise = haskellTypeName inner
      where
        tc = typeRepTyCon (typeOf inner)

-- | CPython's @OSError(errno, ...)@ subclass for an @errno@
-- (@Objects/exceptions.c@, @_PyExc_InitState@'s table).
oserrorSubclass :: Errno -> Text
oserrorSubclass errno
  | errno `elem` [eAGAIN, eALREADY, eWOULDBLOCK, eINPROGRESS] = "BlockingIOError"
  | errno == eCHILD = "ChildProcessError"
  | errno `elem` [ePIPE, eSHUTDOWN] = "BrokenPipeError"
  | errno == eCONNABORTED = "ConnectionAbortedError"
  | errno == eCONNREFUSED = "ConnectionRefusedError"
  | errno == eCONNRESET = "ConnectionResetError"
  | errno == eEXIST = "FileExistsError"
  | errno == eNOENT = "FileNotFoundError"
  | errno == eISDIR = "IsADirectoryError"
  | errno == eNOTDIR = "NotADirectoryError"
  | errno == eINTR = "InterruptedError"
  | errno `elem` [eACCES, ePERM] || Just errno == eNOTCAPABLE = "PermissionError"
  | errno == eSRCH = "ProcessLookupError"
  | errno == eTIMEDOUT = "TimeoutError"
  | otherwise = "OSError"

-- | The 'Typeable' type constructor's name: what a Haskell exception with no
-- Python counterpart is called.
haskellTypeName :: (Typeable e) => e -> Text
haskellTypeName = T.pack . tyConName . typeRepTyCon . typeOf

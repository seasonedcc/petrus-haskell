-- | Synchronous-versus-asynchronous exception handling, as the Agenticus
-- reference's @except Exception@ separates them: Python's @Exception@ does
-- not catch @KeyboardInterrupt@ or @SystemExit@, and here no handler swallows
-- an asynchronous exception (a 'killThread', 'timeout', or @async@
-- cancellation of the calling thread).
module Petrus.Agenticus.Internal.Exception
  ( isAsync
  , isSync
  , trySync
  , rethrowAsync
  ) where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Maybe (isJust)

-- | Whether an exception was delivered asynchronously.
isAsync :: SomeException -> Bool
isAsync e = isJust (fromException e :: Maybe SomeAsyncException)

isSync :: SomeException -> Bool
isSync = not . isAsync

-- | @try@ for synchronous failures; asynchronous ones propagate.
trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left e | isAsync e -> throwIO e
    other -> pure other

-- | The handler of @except Exception: pass@: rethrow an asynchronous
-- exception, swallow a synchronous one.
rethrowAsync :: SomeException -> IO ()
rethrowAsync e
  | isAsync e = throwIO e
  | otherwise = pure ()

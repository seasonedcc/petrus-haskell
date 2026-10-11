-- | Shared helpers for the host test suite.
module TestSupport
  ( withTempRoot
  , runtimeError
  , valueError
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import System.Directory (canonicalizePath)
import System.IO.Temp (withSystemTempDirectory)

-- | A fresh temporary directory with a symlink-free path (pytest's
-- @tmp_path@ is resolved; macOS's @/var@ is a symlink).
withTempRoot :: (FilePath -> IO a) -> IO a
withTempRoot use = withSystemTempDirectory "hamsterdan-host" (\dir -> canonicalizePath dir >>= use)

-- | @pytest.raises(RuntimeError, match=fragment)@.
runtimeError :: Text -> RuntimeError -> Bool
runtimeError fragment (RuntimeError message) = fragment `T.isInfixOf` message

-- | @pytest.raises(ValueError, match=fragment)@.
valueError :: Text -> ValueError -> Bool
valueError fragment (ValueError message) = fragment `T.isInfixOf` message

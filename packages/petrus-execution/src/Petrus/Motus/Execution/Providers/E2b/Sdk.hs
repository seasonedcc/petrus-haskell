-- | The E2B SDK surface upstream's @E2bEnvironment@ uses
-- (@Sandbox.list/create/connect@, @files.write/read/remove@,
-- @commands.run@ and command handles), as a record.
--
-- "Petrus.Motus.Execution.Providers.E2b.Http" binds it to E2B's REST and
-- envd APIs; tests bind it to a port of upstream's in-process fake.
module Petrus.Motus.Execution.Providers.E2b.Sdk
  ( E2bSdk (..)
  , E2bOptions (..)
  , E2bSandboxInfo (..)
  , E2bPaginator (..)
  , E2bSandbox (..)
  , E2bRunOptions (..)
  , E2bCommandResult (..)
  , E2bHandle (..)
  ) where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)

-- | Keyword options upstream passes as @**self._opts()@.
newtype E2bOptions = E2bOptions {optionApiKey :: Maybe Text}
  deriving stock (Eq, Show)

data E2bSandboxInfo = E2bSandboxInfo
  { infoSandboxId :: Text
  , infoMetadata :: Map Text Text
  , infoState :: Text
  -- ^ @str(getattr(state, "value", state))@.
  }

data E2bPaginator = E2bPaginator
  { paginatorHasNext :: IO Bool
  , paginatorNextItems :: E2bOptions -> IO [E2bSandboxInfo]
  }

data E2bRunOptions = E2bRunOptions
  { runEnvs :: [(Text, Text)]
  , runCwd :: Maybe Text
  , runTimeout :: Maybe Double
  }

-- | A finished command.  A binding returns non-zero exits (the SDK's
-- @CommandExitException@, which carries the same three fields) as results,
-- not exceptions; the provider raises where upstream lets the exception
-- propagate (foreground runs).
data E2bCommandResult = E2bCommandResult
  { commandExitCode :: Int
  , commandStdout :: Text
  , commandStderr :: Text
  }

data E2bHandle = E2bHandle
  { handleWait :: (Text -> IO ()) -> (Text -> IO ()) -> IO E2bCommandResult
  , handleKill :: IO ()
  }

data E2bSandbox = E2bSandbox
  { sandboxId :: Text
  , sandboxKill :: IO ()
  , sandboxWriteFile :: Text -> ByteString -> IO ()
  , sandboxReadFile :: Text -> IO ByteString
  , sandboxRemoveFile :: Text -> IO ()
  , sandboxRun :: Text -> E2bRunOptions -> IO E2bCommandResult
  -- ^ A foreground @commands.run@.
  , sandboxRunBackground :: Text -> E2bRunOptions -> IO E2bHandle
  }

data E2bSdk = E2bSdk
  { sdkList :: E2bOptions -> Map Text Text -> Int -> IO E2bPaginator
  -- ^ @Sandbox.list(query=SandboxQuery(metadata=...), limit=...)@.
  , sdkCreate :: E2bOptions -> Text -> Int -> Map Text Text -> IO E2bSandbox
  -- ^ @Sandbox.create(template, timeout, metadata, envs={}, secure=True)@.
  , sdkConnect :: E2bOptions -> Text -> Maybe Int -> IO E2bSandbox
  -- ^ @Sandbox.connect(sandbox_id, timeout=...)@.
  }

-- | The Absurd provider of the Worker process entry point: the
-- @--provider absurd@ branch of the reference's
-- @petrus.motus.worker._cli._provider_factory@, as a
-- 'ProviderPlugins' slot for "Petrus.Motus.Worker.Cli".
--
-- A worker executable that links this package passes 'absurdPlugins' (or
-- sets 'absurdProvider' on its own plugins) to 'workerMain'; it then
-- serves @--provider absurd --dsn ...@ exactly as
-- @python -m petrus.motus.worker@ does.
module Petrus.Motus.Worker.Absurd
  ( absurdProvider
  , absurdPlugins
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Motus.Dispatch (WorkerDispatch)
import Petrus.Motus.Dispatch.Absurd (AbsurdWorkerOptions (..), openAbsurdWorkerDispatch, toWorkerDispatch)
import Petrus.Motus.Worker.Cli (ProviderPlugins (..), WorkerArguments (..), noPlugins)

-- | @AbsurdWorkerDispatch(arguments.dsn, queues=queues,
-- worker_id=arguments.worker_id, claim_timeout=arguments.claim_timeout)@.
absurdProvider :: WorkerArguments -> [Text] -> IO WorkerDispatch
absurdProvider arguments queues =
  toWorkerDispatch
    <$> openAbsurdWorkerDispatch
      (TE.encodeUtf8 (fromMaybe "" arguments.dsn))
      AbsurdWorkerOptions {queues, workerId = arguments.workerId, claimTimeout = arguments.claimTimeout}

-- | Local custody (built in) plus Absurd.
absurdPlugins :: ProviderPlugins
absurdPlugins = noPlugins {absurd = Just absurdProvider}

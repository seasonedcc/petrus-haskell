-- | Starting a child process the way CPython's @subprocess.Popen@ does, for
-- callers outside this package that manage the child's pipes themselves.
--
-- The reference's Agenticus hosts start their helpers and sidecars with
-- @Popen(..., close_fds=True, start_new_session=True)@. The port starts
-- them with this package's @posix_spawn@, which keeps only stdio open as
-- CPython does, where the @process@ package forks and closes every
-- descriptor up to @RLIMIT_NOFILE@. This module is the public face of that
-- primitive; the capture loops stay in the private
-- "Petrus.Motus.Execution.Internal.Process".
module Petrus.Motus.Execution.Spawn
  ( Child
  , childPid
  , StdioFd (..)
  , spawnChild
  ) where

import Petrus.Motus.Execution.Internal.Process (Child, StdioFd (..), childPid, spawnChild)

-- | What CPython's @subprocess@ reports for a finished child.
module Petrus.Posix.Process
  ( exitInt
  ) where

import System.Exit (ExitCode (..))

-- | A @Popen.returncode@: the exit status, or minus the number of the
-- signal that ended the child (the @process@ library's 'ExitFailure'
-- already carries that negative number, as CPython does).
exitInt :: ExitCode -> Int
exitInt = \case
  ExitSuccess -> 0
  ExitFailure n -> n

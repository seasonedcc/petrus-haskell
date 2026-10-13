-- | POSIX primitives the Petrus runtime needs with Python-identical
-- behavior: BSD @flock@ locks ("Petrus.Posix.Flock"), openat-family calls,
-- @linkat@ and @shutil.rmtree@ ("Petrus.Posix.At"),
-- @Path.resolve@/@expanduser@, @os.path.normpath@, @PurePosixPath@ parts
-- and @os.confstr@ ("Petrus.Posix.Path"), fsync, whole-buffer writes and
-- atomic replace ("Petrus.Posix.File"), @getrusage@/@sysconf@ ("Petrus.Posix.Resource"),
-- descriptor readiness ("Petrus.Posix.Poll"), @getaddrinfo@ error codes
-- ("Petrus.Posix.Netdb") and a child's @returncode@
-- ("Petrus.Posix.Process").
module Petrus.Posix
  ( module Petrus.Posix.At
  , module Petrus.Posix.File
  , module Petrus.Posix.Flock
  , module Petrus.Posix.Netdb
  , module Petrus.Posix.Path
  , module Petrus.Posix.Poll
  , module Petrus.Posix.Process
  , module Petrus.Posix.Resource
  ) where

import Petrus.Posix.At
import Petrus.Posix.File
import Petrus.Posix.Flock
import Petrus.Posix.Netdb
import Petrus.Posix.Path
import Petrus.Posix.Poll
import Petrus.Posix.Process
import Petrus.Posix.Resource

-- | @petrus-zeromq-dispatch@: the ZeroMQ Dispatch server process
-- (@python -m petrus.motus.transport.zeromq@).
module Main (main) where

import Petrus.Motus.Transport.ZeroMQ.Cli (serverMain)

main :: IO ()
main = serverMain "petrus-zeromq-dispatch"

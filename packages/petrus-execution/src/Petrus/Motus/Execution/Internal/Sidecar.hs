{-# LANGUAGE TemplateHaskell #-}

-- | The verbatim upstream Gondolin sidecar (@gondolin_sidecar.mjs@),
-- embedded at compile time from @data/gondolin_sidecar.mjs@.
--
-- Embedding keeps the compiled provider relocatable: it never has to find
-- an installed data file, and the bytes it runs are exactly the bytes
-- reviewed in the repository (the test suite pins their SHA-256).
module Petrus.Motus.Execution.Internal.Sidecar
  ( sidecarSource
  , sidecarSha256
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)

-- | The sidecar module source, byte-for-byte.
sidecarSource :: ByteString
sidecarSource =
  BC.pack
    $( do
         let path = "data/gondolin_sidecar.mjs"
         addDependentFile path
         contents <- runIO (B.readFile path)
         lift (BC.unpack contents)
     )

-- | Hex SHA-256 of 'sidecarSource'.
sidecarSha256 :: Text
sidecarSha256 = T.pack (show (hash sidecarSource :: Digest SHA256))

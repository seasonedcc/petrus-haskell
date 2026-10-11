{-# LANGUAGE TemplateHaskell #-}

-- | Compile-time embedding of the vendored Absurd schema: the file's raw
-- bytes become a primitive string literal, so the library carries the exact
-- release script and needs no data files at run time. The file is a
-- dependency of the module that splices it, so editing it rebuilds that
-- module (and the sha256 check at every apply catches the edit).
module Petrus.Motus.Dispatch.Absurd.Embed (embedFile) where

import Data.ByteString qualified as BS
import Data.ByteString.Unsafe (unsafePackAddressLen)
import Language.Haskell.TH (Exp, Q, integerL, litE, runIO, stringPrimL)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.IO.Unsafe (unsafePerformIO)

-- | An expression of type 'BS.ByteString' holding the file's bytes, read
-- relative to the package directory at compile time. The spliced
-- unsafePerformIO only wraps the static literal ('unsafePackAddressLen'
-- copies nothing and has no other effect).
embedFile :: FilePath -> Q Exp
embedFile path = do
  addDependentFile path
  bytes <- runIO (BS.readFile path)
  [|unsafePerformIO (unsafePackAddressLen $(litE (integerL (fromIntegral (BS.length bytes)))) $(litE (stringPrimL (BS.unpack bytes))))|]

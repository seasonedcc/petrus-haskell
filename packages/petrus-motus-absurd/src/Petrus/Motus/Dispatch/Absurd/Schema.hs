{-# LANGUAGE TemplateHaskell #-}

-- | The D11 triple pin and the vendored Absurd release schema
-- (@petrus.motus.dispatch.absurd@'s @ABSURD_*@ constants, @_pinned_schema@
-- and @ensure_absurd_schema@).
--
-- The exact release script (@absurd_schema/absurd-0.4.0.sql@, byte-for-byte
-- the reference's vendored copy) is embedded at compile time. Its sha256 is
-- re-verified against 'absurdSqlSha256' on every 'ensureAbsurdSchema' call,
-- the already-provisioned path included, and a database that already has an
-- @absurd@ schema must report exactly 'absurdVersion' — a re-pin is a
-- deliberate act, never an implicit upgrade at boot.
module Petrus.Motus.Dispatch.Absurd.Schema
  ( -- * The triple pin
    absurdVersion
  , absurdCommit
  , absurdSqlSha256

    -- * The vendored script
  , vendoredSchema
  , pinnedSchema

    -- * Provisioning
  , ensureAbsurdSchema
  , ensureAbsurdSchemaWith

    -- * Errors
  , AbsurdError (..)
  ) where

import Control.Exception (Exception (..), throwIO, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Motus.Dispatch.Absurd.Embed (embedFile)
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Json.Python.Exception (IsPythonException (..), pythonExceptionFromException, pythonExceptionToException, raised)
import Petrus.Postgres (Connection, PostgresError (..), execute_, queryFirst, sql)

-- | The pinned Absurd release tag.
absurdVersion :: Text
absurdVersion = "0.4.0"

-- | The release tag's commit.
absurdCommit :: Text
absurdCommit = "05282a40c8dddc378acdc6933adc4c221583808a"

-- | The sha256 of the release's @sql/absurd.sql@.
absurdSqlSha256 :: Text
absurdSqlSha256 = "c2ed3a301aa2a4782257843e514e8057c3049de5998ea8dc632a1a159464b51c"

-- | The reference's @RuntimeError@ from the Absurd adapter: a refused
-- schema, a stale Activity Attempt, an unsafe custody transfer, or a
-- cancelled task met by @collect@.
newtype AbsurdError = AbsurdError Text
  deriving stock (Eq, Show)

instance Exception AbsurdError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (AbsurdError message) = T.unpack message

instance IsPythonException AbsurdError where
  toPythonException (AbsurdError message) = raised "RuntimeError" message

-- | The vendored release script's raw bytes, as compiled in.
vendoredSchema :: ByteString
vendoredSchema = $(embedFile "absurd_schema/absurd-0.4.0.sql")
{-# NOINLINE vendoredSchema #-}

-- | @_pinned_schema@: the given script's text once its raw bytes hash to
-- the pin; a drifted or edited copy is a hard stop.
pinnedSchema :: ByteString -> Either AbsurdError Text
pinnedSchema vendored
  | digest /= absurdSqlSha256 =
      Left
        ( AbsurdError
            ( "vendored absurd-"
                <> absurdVersion
                <> ".sql hash mismatch: expected "
                <> absurdSqlSha256
                <> ", found "
                <> digest
                <> " — the pinned schema is never forked; restore the verbatim release file or re-pin deliberately "
                <> "(re-verifying the triple pin and re-running the ES-009 matrix)"
            )
        )
  | otherwise = Right (TE.decodeUtf8 vendored)
  where
    digest = TE.decodeLatin1 (Base16.encode (SHA256.hash vendored))

-- | @ensure_absurd_schema(connection)@ with the compiled-in script.
ensureAbsurdSchema :: Connection -> IO ()
ensureAbsurdSchema = ensureAbsurdSchemaWith vendoredSchema

-- | @ensure_absurd_schema@ over a given copy of the script (tests pass a
-- tampered one, as the reference's monkeypatch does). The hash is checked
-- first, before any statement; an existing @absurd@ schema must answer
-- @absurd.get_schema_version()@ with the pinned version; an empty database
-- gets the whole script as one multi-statement unit (atomic: a failed apply
-- leaves nothing behind).
ensureAbsurdSchemaWith :: ByteString -> Connection -> IO ()
ensureAbsurdSchemaWith vendored connection = do
  pinned <- either throwIO pure (pinnedSchema vendored)
  present <- queryFirst connection "SELECT 1 FROM pg_namespace WHERE nspname = 'absurd'" []
  case present of
    Nothing -> execute_ connection (sql pinned) []
    Just _ -> do
      answer <- try @PostgresError (queryFirst connection "SELECT absurd.get_schema_version()" [])
      version <- case answer of
        Left failure ->
          throwIO
            ( AbsurdError
                ( "an 'absurd' schema exists but does not answer absurd.get_schema_version(): not the pinned "
                    <> "engine — refusing to touch it ("
                    <> errorMessage failure
                    <> ")"
                )
            )
        Right (Just (value : _)) -> pure (TE.decodeUtf8 <$> value)
        Right _ -> pure Nothing
      if version == Just absurdVersion
        then pure ()
        else
          throwIO
            ( AbsurdError
                ( "the database speaks absurd schema version "
                    <> maybe "None" pythonStrRepr version
                    <> ", but this adapter is pinned to "
                    <> pythonStrRepr absurdVersion
                    <> ": a re-pin is a deliberate act [D11] — never an implicit upgrade at boot"
                )
            )

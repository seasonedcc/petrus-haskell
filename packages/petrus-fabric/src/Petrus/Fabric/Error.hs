-- | The error categories of fabric.md §12, shared by Fabric and the process
-- lifecycle (processes.md §1).
--
-- The reference raises Python built-in exceptions and the spec makes only
-- their /category/ normative. Each constructor here names the category and
-- remembers which Python class the reference raises at that site, so an
-- Activity executor can classify a failure exactly as the reference's
-- dispatchers do ('pythonExceptionName'). Messages reproduce the
-- reference's text; they are informative (fabric.md §14).
module Petrus.Fabric.Error
  ( FabricError (..)
  , Category (..)
  , categoryText
  , errorCategory
  , errorMessage
  , pythonExceptionName
  , orThrow
  ) where

import Control.Exception (Exception (..), throwIO)
import Data.Text (Text)
import Data.Text qualified as T

-- | A refusal. Storage failures are not represented: the driver's
-- 'Petrus.Postgres.PostgresError' propagates unchanged, as psycopg's errors
-- do in the reference.
data FabricError
  = -- | invalid, raised as @ValueError@.
    InvalidValue Text
  | -- | invalid, raised as @TypeError@.
    InvalidType Text
  | -- | conflict (@ValueError@).
    Conflict Text
  | -- | denied (@PermissionError@).
    Denied Text
  | -- | not-found (@LookupError@).
    NotFound Text
  | -- | schema-refused (@RuntimeError@).
    SchemaRefused Text
  deriving stock (Eq, Show)

instance Exception FabricError where
  displayException = T.unpack . errorMessage

-- | fabric.md §12's categories.
data Category = Invalid | ConflictCategory | DeniedCategory | NotFoundCategory | SchemaRefusedCategory | Storage
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The spec's spelling: @invalid@, @conflict@, @denied@, @not-found@,
-- @schema-refused@, @storage@.
categoryText :: Category -> Text
categoryText = \case
  Invalid -> "invalid"
  ConflictCategory -> "conflict"
  DeniedCategory -> "denied"
  NotFoundCategory -> "not-found"
  SchemaRefusedCategory -> "schema-refused"
  Storage -> "storage"

errorCategory :: FabricError -> Category
errorCategory = \case
  InvalidValue _ -> Invalid
  InvalidType _ -> Invalid
  Conflict _ -> ConflictCategory
  Denied _ -> DeniedCategory
  NotFound _ -> NotFoundCategory
  SchemaRefused _ -> SchemaRefusedCategory

errorMessage :: FabricError -> Text
errorMessage = \case
  InvalidValue m -> m
  InvalidType m -> m
  Conflict m -> m
  Denied m -> m
  NotFound m -> m
  SchemaRefused m -> m

-- | The Python class the reference raises for this refusal.
pythonExceptionName :: FabricError -> Text
pythonExceptionName = \case
  InvalidValue _ -> "ValueError"
  InvalidType _ -> "TypeError"
  Conflict _ -> "ValueError"
  Denied _ -> "PermissionError"
  NotFound _ -> "LookupError"
  SchemaRefused _ -> "RuntimeError"

-- | Throw a 'Left'.
orThrow :: Either FabricError a -> IO a
orThrow = either throwIO pure

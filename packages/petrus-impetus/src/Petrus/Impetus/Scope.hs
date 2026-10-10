-- | Immutable lifecycle-scope identity (@petrus.impetus.scope@).
--
-- A lifecycle scope is a named, explicit ownership boundary for one
-- generation of process work. Its durable identity is exactly
-- @(name, generation)@; the History records that open, close, and reset
-- generations carry it verbatim, so the value is kept as small and as
-- validated as the wire spelling it becomes.
module Petrus.Impetus.Scope
  ( LifecycleScope
  , lifecycleScope
  , scopeName
  , scopeGeneration
  , validScopeName
  , scopeNameError
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Internal.Repr (pyStr)

-- | One exact named lifecycle generation. Construct with 'lifecycleScope':
-- the name is non-empty without NUL and the generation is positive, the same
-- rules the reference enforces in @__post_init__@.
data LifecycleScope = LifecycleScope Text Integer
  deriving stock (Eq, Ord)

instance Show LifecycleScope where
  -- Mirrors the reference's dataclass repr, which History diagnostics embed.
  show (LifecycleScope name generation) =
    "LifecycleScope(name=" ++ T.unpack (pyStr name) ++ ", generation=" ++ show generation ++ ")"

-- | Build a scope, refusing what the reference refuses.
lifecycleScope :: Text -> Integer -> Either Text LifecycleScope
lifecycleScope name generation
  | not (validScopeName name) = Left scopeNameError
  | generation < 1 =
      Left "LifecycleScope generation must be a positive integer of the exact built-in type"
  | otherwise = Right (LifecycleScope name generation)

-- | Whether a scope name is admissible: non-empty, without NUL.
validScopeName :: Text -> Bool
validScopeName name = not (T.null name) && not (T.any (== '\0') name)

-- | The reference's rejection text for an invalid scope name.
scopeNameError :: Text
scopeNameError =
  "LifecycleScope name must be a non-empty string without NUL and use the exact built-in type"

scopeName :: LifecycleScope -> Text
scopeName (LifecycleScope name _) = name

scopeGeneration :: LifecycleScope -> Integer
scopeGeneration (LifecycleScope _ generation) = generation

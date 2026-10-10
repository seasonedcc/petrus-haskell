-- | The Common Expression Language, evaluated exactly as cel-python
-- (@celpy@ 0.5.0) evaluates it.
--
-- Compile once with 'compile' (a pure parse to a typed tree), then evaluate
-- the 'Program' against variables given as 'Json' with 'evaluateJson'. The
-- result is cel-python's: a 'Value' (with the @repr@ and truthiness of the
-- Python object cel-python would return), or the exception it would raise —
-- a CEL evaluation error ('CelExc') or a Python exception ('PyExc') —
-- returned as a value, never thrown.
--
-- > case compile "amount >= 100" of
-- >   Right program -> truthy <$> evaluateJson program [("amount", Int 150)]
-- >   Left err -> ...
--
-- 'freeVariables' is Petrus's construction-time scope analysis
-- (@petrus.impetus.binding.cel.free_variables@). "Petrus.Cel.Binding" builds
-- Petrus's filter, guard, and completion environments on top of this
-- module, and "Petrus.Cel.Impetus" plugs them into the Impetus kernel.
module Petrus.Cel
  ( -- * Programs
    Program
  , compile
  , programSource
  , programExpr
  , ParseError (..)
  , freeVariables
    -- * Evaluation
  , evaluateJson
  , evaluateValues
    -- * Results
  , Value
  , valueRepr
  , valueStr
  , truthy
  , jsonToCel
  , Exc (..)
  , CelError (..)
  , excRepr
  , excStr
  , ExcClass (..)
  , excClassName
  ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

import Petrus.Cel.Eval (baseActivation, bindValues, evaluate)
import Petrus.Cel.Parse (ParseError (..), parseCel)
import Petrus.Cel.Python (ExcClass (..), excClassName)
import Petrus.Cel.Syntax
import Petrus.Cel.Value
import Petrus.Json (Json)

-- | A compiled CEL expression.
data Program = Program
  { programSource :: Text
  -- ^ The source text.
  , programExpr :: Expr
  -- ^ The typed syntax tree.
  }

-- | Parse an expression (cel-python's @Environment().compile@). A syntax
-- error carries cel-python's line, column, and message.
compile :: Text -> Either ParseError Program
compile source = Program source <$> parseCel source

-- | Petrus's free variables of an expression: every identifier in variable
-- position (an @ident@ node; function and method names are not), minus the
-- variable each macro (@exists@, @all@, @exists_one@, @map@, @filter@)
-- binds. As in Petrus, the subtraction is global rather than scoped, and a
-- macro's variable is the first identifier of its first argument in lark's
-- @find_data@ order. (@reduce@ and @min@ bind nothing here, exactly as in
-- Petrus.)
freeVariables :: Program -> Set Text
freeVariables program = Set.fromList (findIdents tree) `Set.difference` bound
  where
    tree = toLark (programExpr program)
    bound = Set.fromList (concatMap macroVariable (subtrees tree))
    subtrees t@(LarkTree _ children) = t : concat [subtrees c | LarkNode c <- children]
    macroVariable = \case
      LarkTree "member_dot_arg" children
        | (method : _) <- [name | LarkToken _ name <- children]
        , method `elem` ["exists", "all", "exists_one", "map", "filter"]
        , (LarkTree _ (LarkNode firstArgument : _) : _) <- [t | LarkNode t@(LarkTree "exprlist" _) <- children]
        , (variable : _) <- findIdents firstArgument ->
            [variable]
      _ -> []

-- | Evaluate against variables given as JSON: each value is converted with
-- @celpy.json_to_cel@ (an out-of-range integer raises @ValueError@), then
-- bound (a name that is not a dotted identifier raises @ValueError@), then
-- the program runs. @Left@ is whatever cel-python raises: a 'CelExc' for a
-- CEL error, a 'PyExc' for a Python exception escaping the evaluator.
evaluateJson :: Program -> [(Text, Json)] -> Either Exc Value
evaluateJson program variables = traverse (traverse jsonToCel) variables >>= evaluateValues program

-- | Evaluate against variables that are already CEL values.
evaluateValues :: Program -> [(Text, Value)] -> Either Exc Value
evaluateValues program variables = do
  activation <- bindValues variables baseActivation
  evaluate activation (programExpr program)

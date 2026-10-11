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
--
-- == Where cel-python departs from the CEL specification
--
-- This package follows cel-python, not the specification, wherever they
-- differ; the differential corpus (@test/corpus@) records every such case.
-- The ones a Petrus expression is most likely to meet:
--
-- * __Lexing.__ lark's contextual lexer: after an operand only @in@ can
--   follow, so @x int@ reads as @x in t@; @_in_@ is an identifier bound to
--   cel-python's @operator_in@ (@_in_(1, [1])@ is @true@). @//@ starts a
--   comment; there are no block comments and no digit separators.
-- * __Comparison.__ No heterogeneous numeric equality: @1 == 1.0@,
--   @1 == 1u@, @duration(\'1s\') == 1@ and @{true: 1} == {1: 1}@ are
--   \"no matching overload\" errors, as is @1 in [1.0]@. Comparisons are
--   left-associative over Python values, so @1 < 2 < 3@ is
--   @(1 < 2) < 3@, which holds because a CEL bool is a Python @int@.
-- * __Arithmetic.__ Overflow outside int64/uint64 is the error
--   \"return error for overflow\" (@0u - 1u@, @2u - 3@, @uint(-1)@), but a
--   bool operand escapes the check (@true + 9223372036854775807@ is the
--   plain Python int 9223372036854775808). Mixed @int@/@uint@ arithmetic is
--   allowed (@5 / 2u@ is @2@), and so is an int with a double, giving an
--   int (@-7 % 2.5@ is @-2@); with an int dividend @1 / 0@ and @1 / 0.0@
--   are \"modulus or divide by zero\", while @1.0 / 0.0@ is @inf@; integer
--   division and remainder truncate toward zero.
-- * __Errors.__ A CEL error is a value: @&&@ and @||@ absorb it when the
--   other side decides, and anything else applied to it is a \"no matching
--   overload\" error naming the error class (@[1, 1/0][0]@). A Python
--   exception raised inside an operand is not a value and escapes the
--   whole expression (@null.map(x, x) || true@ raises @TypeError@).
-- * __Macros.__ @filter@ and @map@ run over strings and bytes too
--   (@\'abc\'.filter(c, c != \'b\')@ is @[\'a\', \'c\']@); @reduce@ and @min@
--   exist; a malformed macro raises Python\'s unpacking @ValueError@.
-- * __Conversions.__ Python\'s parsers: @int(\' \\t12\\n\')@ and Unicode
--   digits are accepted, @double(\'inF\')@ is infinity, @bool(\'-1\')@ is
--   true while @bool(0.5)@ is false, @string(1e-7)@ is @\'1e-07\'@;
--   @timestamp@ accepts any ISO 8601 form @datetime@ parses
--   (@timestamp(\'2020-W01\')@). Message construction works for the
--   wrapper types and @google.protobuf.Struct@.
-- * __Functions.__ @contains@, @startsWith@ and @endsWith@ on mismatched
--   string/bytes operands are \"no such overload\"; @matches@ is RE2 with
--   RE2\'s Unicode 15.1 tables (see "Petrus.Cel.Regex").
--
-- A string literal spelling a lone surrogate (@\'\\uD800\'@) keeps it, as
-- Python's @str@ does: 'Text' carries it in WTF-8 ("Petrus.Json.Wtf8"),
-- its @size@ and @repr@ are CPython's, and where cel-python encodes the
-- string (@bytes(s)@, @matches@) it raises CPython's @UnicodeEncodeError@
-- with the same arguments.
module Petrus.Cel
  ( -- * Programs
    Program
  , compile
  , programSource
  , programExpr
  , ParseError (..)
  , freeVariables
  , macros
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
-- | @MACROS@ of @binding/cel.py@: the macros whose variable 'freeVariables'
-- subtracts.
macros :: Set Text
macros = Set.fromList ["exists", "all", "exists_one", "map", "filter"]

freeVariables :: Program -> Set Text
freeVariables program = Set.fromList (findIdents tree) `Set.difference` bound
  where
    tree = toLark (programExpr program)
    bound = Set.fromList (concatMap macroVariable (subtrees tree))
    subtrees t@(LarkTree _ children) = t : concat [subtrees c | LarkNode c <- children]
    macroVariable = \case
      LarkTree "member_dot_arg" children
        | (method : _) <- [name | LarkToken _ name <- children]
        , method `Set.member` macros
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

{-# LANGUAGE OverloadedRecordDot #-}

-- | The Impetus kernel's CEL compilers: "Petrus.Cel.Binding" behind the
-- kernel's 'CelCompilers' seam.
--
-- > instanceConfig { celCompilers = Petrus.Cel.Impetus.celCompilers }
--
-- A compile-time 'Left' is the reference's declared-mismatch @ValueError@
-- text (an invalid expression, or a free variable outside the scope the
-- kernel passes). An evaluation-time 'Left' is the reference's diagnostic
-- text for the exception, Python's @repr()@ of it (cel-python's activation
-- dump inside "undeclared reference" errors is abbreviated); the kernel
-- reads it as not admitted, not satisfied, or not holding.
module Petrus.Cel.Impetus
  ( celCompilers
  ) where

import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text (Text)

import Petrus.Cel.Binding qualified as Binding
import Petrus.Impetus.Binding (CelCompilers (..), Completion)
import Petrus.Impetus.Petrinet

-- | CEL compilers reproducing @petrus.impetus.binding.cel@.
celCompilers :: CelCompilers
celCompilers =
  CelCompilers
    { compileGuard = guard
    , compileFilter = filter'
    , compileCompletion = completion
    }

tokenJson :: Token -> Binding.TokenJson
tokenJson t = Binding.TokenJson t.color t.payload

filter' :: Cel -> Either Text Filter
filter' declaration = do
  predicate <- Binding.compileFilter (celExpression declaration)
  Right (either (Left . Binding.diagnostic) Right . predicate . (.payload))

guard :: Cel -> NetPath -> Set.Set NetPath -> Either Text Guard
guard declaration at scope = do
  predicate <-
    Binding.compileGuard (celExpression declaration) (netPathText at) (map netPathText (Set.toList scope))
  Right $ \b ->
    either (Left . Binding.diagnostic) Right $
      predicate [(netPathText p, map tokenJson ts) | (p, ts) <- b.consumed ++ b.read]

completion :: Cel -> [NetPath] -> Either Text Completion
completion declaration places = do
  predicate <- Binding.compileCompletion (celExpression declaration) (map netPathText places)
  let byName = [(netPathText p, p) | p <- places]
  Right $ \marking ->
    either (Left . Binding.diagnostic) Right $
      predicate (\name -> maybe [] (\p -> map tokenJson (toList (placeTokens p marking))) (lookup name byName))

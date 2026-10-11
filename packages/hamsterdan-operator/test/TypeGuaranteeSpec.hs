{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors -Wno-missing-signatures #-}

-- | The reference test cases whose inputs the port's types make impossible
-- to write (DIVERGENCES.md, "Type-enforced refusals"). This module compiles
-- with deferred type errors, and each example passes only when using the
-- ill-typed value raises a 'TypeError': the slot the reference checks at
-- run time is a type here.
module TypeGuaranteeSpec (spec) where

import Control.Exception (TypeError (..), evaluate)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Readiness (ChangeResult (..))
import Hamsterdan.Host.PublicationQualification
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Directory (createDirectory)
import Test.Hspec

-- Each ill-typed value is its own top-level binding with no signature, so
-- the deferred error fires only where a typed slot receives it.

nullCategory = Nothing :: Maybe Text
zeroCategory = 0 :: Int
falseCategory = False
emptyCategory = [] :: [Text]
stringOk = "true" :: Text
passedSchema = pure ("passed" :: Text)
booleanRunner = \(_ :: [Text]) -> pure True
yesObserver = pure ("yes" :: Text)

-- | @class ForcedRef(str)@ with its own @__format__@.
newtype ForcedRef = ForcedRef Text

forcedBase = ForcedRef (T.replicate 40 "a")

effect publication result cleanup ok =
  ChangeResult
    { epoch = 2
    , head = T.replicate 40 "a"
    , ok = ok
    , provisionalHead = ""
    , fingerprint = ""
    , lineage = ""
    , operation = "change:diagnostic"
    , publicationCategory = publication
    , agentResultCategory = result
    , agentCleanupCategory = cleanup
    }

typeError :: TypeError -> Bool
typeError (TypeError _) = True

recordFresh :: ChangeResult -> Int -> IO ()
recordFresh value publications = do
  evidence <- newPublicationQualification
  recordOriginal evidence value publications

-- Each use of an ill-typed value is a top-level binding too, so its
-- deferred error is raised where the example runs it, not while the spec
-- tree is built.

nullCategoryUse = recordFresh (effect nullCategory "" "" False) 0
zeroCategoryUse = recordFresh (effect "ref_cas" zeroCategory "" False) 0
falseCategoryUse = recordFresh (effect "ref_cas" "" falseCategory False) 0
emptyCategoryUse = recordFresh (effect "ref_cas" emptyCategory "" False) 0
stringOkUse = recordFresh (effect "" "" "" stringOk) 1

passedSchemaUse = do
  evidence <- newPublicationQualification
  recordOriginal evidence (effect "" "" "" True) 1
  runPublicationAssertions evidence passedSchema (pure True) (pure True)

booleanRunnerUse = (booleanRunner :: [Text] -> IO Int) [] >>= evaluate

forcedBaseUse =
  withSystemTempDirectory "qualification" \tmp -> do
    let root = tmp </> "private"
    createDirectory root 0o700
    push (atomicSetupPush (root </> "push-spent")) "https://github.com/owner/target.git" forcedBase (T.replicate 40 "b") (\_ -> pure 0)

yesObserverUse = (yesObserver :: IO Bool) >>= evaluate

spec :: Spec
spec = describe "Type-enforced refusals (Haskell port)" do
  describe "test_falsy_nonstring_categories_cannot_bypass_the_closed_vocabulary" do
    it "publication_category None does not type-check: the category is Text" $
      nullCategoryUse `shouldThrow` typeError
    it "agent_result_category 0 does not type-check: the category is Text" $
      zeroCategoryUse `shouldThrow` typeError
    it "agent_cleanup_category False does not type-check: the category is Text" $
      falseCategoryUse `shouldThrow` typeError
    it "agent_result_category [] does not type-check: the category is Text" $
      emptyCategoryUse `shouldThrow` typeError

  describe "test_assertions_are_one_shot_and_non_boolean_evidence_is_rejected" do
    it "a schema assertion returning \"passed\" does not type-check: it returns Bool" $
      passedSchemaUse `shouldThrow` typeError
    it "ok = \"true\" does not type-check: ok is Bool" $
      stringOkUse `shouldThrow` typeError

  it "test_atomic_setup_nonzero_or_throwing_runner_never_retains_private_diagnostics: a runner returning True does not type-check: it returns Int" $
    booleanRunnerUse `shouldThrow` typeError

  it "test_atomic_setup_rejects_string_subclasses_before_formatting_or_spending: a str subclass does not type-check: refs are Text" $
    forcedBaseUse `shouldThrow` typeError

  it "test_setup_observation_requires_strict_confirmation_without_retaining_diagnostics: an observer returning \"yes\" does not type-check: it returns Bool" $
    yesObserverUse `shouldThrow` typeError

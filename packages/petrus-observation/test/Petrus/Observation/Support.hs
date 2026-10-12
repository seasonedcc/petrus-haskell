-- | Shared builders for the observation specs: the reference's
-- @canonical_engine()@ rebuilt with Instance doors, fixture and corpus
-- loading, and small assertion helpers.
--
-- The reference drives an Engine; observation reads only the Instance and
-- its History, so each Engine call is replaced by the Instance door it
-- performs under the Engine's simulated clock (which stays at the
-- construction instant): @Engine.create(..., at=7)@ is 'newInstance' at 7,
-- one @advance()@ that begins an Activity is 'begin' of the head candidate,
-- @deliver@ is 'acceptDelivery' then 'completeDelivery', and @open_scope@,
-- @close_scope@, and @seal@ are the Instance doors of the same name.
module Petrus.Observation.Support
  ( -- * Nets and instances
    a
  , b
  , c
  , source
  , work
  , bridge
  , canonicalNet
  , canonicalConfig
  , canonicalInstance
  , create
  , advance
  , celStub
  , netOf
    -- * Fixtures
  , specFile
  , readJsonFile
  , corpusFile
    -- * Assertions
  , expectRight
  , shouldBeExactly
  , shouldSpellFixture
  , member
  , members
  , items
  , firstOf
  ) where

import Control.Monad (filterM)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocationFields (..), activityInvocation, defaultInvocationFields)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), CelCompilers (..), handlerTokens)
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Json (Json (..), dumps, exactEq, indented, parseJson, pythonLoads)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

a, b, c, source, work :: NetPath
a = "a"
b = "b"
c = "c"
source = "source"
work = "work"

-- | The reference test's @Bridge@ Activity handler.
bridge :: ActivityHandler
bridge =
  ActivityHandler
    { prepare = \binding -> case bindingTokens binding of
        t : _ ->
          activityInvocation
            (defaultInvocationFields "canonical.activity" (Object [("nested", Array [t.payload])]))
              { correlation = Just "canonical-correlation"
              , idempotency = Just "canonical-idempotency"
              }
        [] -> Left "no tokens"
    , project = \_ result -> Right (handlerTokens [(b, [Token (Just "Done") result])])
    , projectFailure = Nothing
    }

-- | The one inline completion the canonical net declares, @size(b) > 0@
-- (CEL is a separate package; the kernel takes compilers at construction).
celStub :: CelCompilers
celStub =
  CelCompilers
    { compileGuard = \_ _ _ -> Left "no CEL guards in these specs"
    , compileFilter = \_ -> Left "no CEL filters in these specs"
    , compileCompletion = \expression _ -> case celExpression expression of
        "size(b) > 0" -> Right (\m -> Right (not (Seq.null (placeTokens b m))))
        other -> Left ("unexpected completion " <> other)
    }

netOf :: HasCallStack => NetSpec -> Net
netOf spec = either (error . T.unpack) id (mkNet spec)

canonicalNet :: Net
canonicalNet =
  netOf
    NetSpec
      { places = [place c, coloredPlace a "Input", coloredPlace b "Done"]
      , transitions =
          [ Transition {path = work, handler = Just (HandlerSymbol "bridge"), guards = [], timers = []}
          , transition source
          ]
      , arcs = [arc source c, arc a work, arc work b]
      , completion = Just (CompletionCel (unsafeCel "size(b) > 0"))
      , name = Just "canonical-observation"
      }

canonicalConfig :: InstanceConfig
canonicalConfig =
  defaultInstanceConfig
    { initialMarking =
        markingFromList [(a, [Token (Just "Input") (Object [("ordinal", Int 1)]), Token (Just "Input") (Object [("ordinal", Int 2)])])]
    , handlerImplementations = Map.fromList [(Symbol "bridge", ActivityBound bridge)]
    , celCompilers = celStub
    , constructionInstant = IntNumber 7
    , suppliedIdentity = Just "canonical-instance"
    }

-- | @canonical_engine()@: created at 7, advanced once (the Activity
-- occurrence begins).
canonicalInstance :: HasCallStack => IO Instance
canonicalInstance = do
  inst <- create canonicalNet canonicalConfig
  advance inst
  pure inst

create :: HasCallStack => Net -> InstanceConfig -> IO Instance
create net cfg = newInstance net cfg >>= expectRight . either (Left . renderInstanceError) Right

-- | One Engine @advance()@ that begins the head candidate.
advance :: HasCallStack => Instance -> IO ()
advance inst =
  candidates inst >>= \case
    binding : _ -> begin inst binding Nothing >>= expectRight . either (Left . renderInstanceError) Right >> pure ()
    [] -> expectationFailure "expected an enabled candidate"

expectRight :: (HasCallStack, Show e) => Either e x -> IO x
expectRight = \case
  Right x -> pure x
  Left e -> expectationFailure ("expected Right, got Left " <> show e) >> error "unreachable"

-- | Exact equality: member order and int/float spelling included.
shouldBeExactly :: HasCallStack => Json -> Json -> Expectation
shouldBeExactly actual expected =
  if exactEq actual expected
    then pure ()
    else expectationFailure ("expected exactly\n" <> show expected <> "\nbut got\n" <> show actual)

-- | The fixture's own bytes are the reference writer's spelling of the
-- projected value (two-space indentation, insertion order, one newline).
shouldSpellFixture :: HasCallStack => Json -> FilePath -> Expectation
shouldSpellFixture value path = do
  expected <- BS.readFile path
  fmap (<> "\n") (dumps indented value) `shouldBe` Right expected

member :: HasCallStack => Text -> Json -> Json
member key = \case
  Object ms | Just v <- lookup key ms -> v
  other -> error ("no member " <> T.unpack key <> " in " <> take 200 (show other))

members :: HasCallStack => [Text] -> Json -> Json
members path value = foldl (flip member) value path

items :: HasCallStack => Json -> [Json]
items = \case
  Array xs -> xs
  other -> error ("not an array: " <> take 200 (show other))

firstOf :: HasCallStack => [x] -> x
firstOf = \case
  x : _ -> x
  [] -> error "expected a nonempty list"

findExisting :: [FilePath] -> IO FilePath
findExisting paths = do
  found <- filterM (\p -> (||) <$> doesDirectoryExist p <*> doesFileExist p) paths
  case found of
    p : _ -> pure p
    [] -> error ("none of " <> show paths <> " exists")

-- | The pinned spec directory. unsafePerformIO (NOINLINE): a fixed path,
-- resolved once, that pure fixture paths and spec trees are built from.
specDirectory :: FilePath
specDirectory = unsafePerformIO (findExisting ["../../upstream/petrus/spec", "upstream/petrus/spec"])
{-# NOINLINE specDirectory #-}

specFile :: FilePath -> FilePath
specFile name = specDirectory </> name

corpusFile :: IO FilePath
corpusFile =
  findExisting
    [ "differential/observation_corpus.json"
    , "packages/petrus-observation/differential/observation_corpus.json"
    ]

readJsonFile :: FilePath -> IO Json
readJsonFile path = do
  raw <- BS.readFile path
  either (error . (("cannot parse " <> path <> ": ") <>)) pure (parseJson pythonLoads raw)

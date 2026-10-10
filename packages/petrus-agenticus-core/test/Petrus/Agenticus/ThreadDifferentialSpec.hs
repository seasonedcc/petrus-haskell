-- | Replays @differential/thread_corpus.json@ (generated from the reference
-- by @differential/thread_corpus.py@): lifecycle traces, @from_data@ of
-- valid and mutated documents, compatibility verdicts and runtime
-- foundation values, byte for byte.
module Petrus.Agenticus.ThreadDifferentialSpec (spec) where

import Control.Monad (forM_, unless)
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Result
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape (strEnumJson)
import Petrus.Agenticus.Program.Descriptor
import Petrus.Agenticus.Runtime.Installation
import Petrus.Agenticus.Runtime.Operation
import Petrus.Agenticus.Runtime.Result
import Petrus.Agenticus.Support
import Petrus.Agenticus.Thread.Continuation
import Petrus.Agenticus.Thread.Identity
import Petrus.Agenticus.Thread.Lifecycle
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Hspec

at :: Text -> Json -> Json
at key j = fromMaybe Null (J.lookupMember key j)

arrayOf :: Json -> [Json]
arrayOf = \case
  Array xs -> xs
  _ -> []

textOf :: Json -> Text
textOf = \case
  String t -> t
  other -> error ("expected a string, got " <> show other)

intOf :: Json -> Integer
intOf = \case
  Int i -> i
  other -> error ("expected an integer, got " <> show other)

enumOf :: (StrEnum a) => Json -> a
enumOf j = fromMaybe (error ("unknown enum value " <> show j)) (strEnumJson j)

dumps :: Json -> Text
dumps = either (error . show) id . J.dumpsText J.defaultDumps

-- | The observable outcome of one reference call.
data Outcome
  = Accepted Json (Maybe Text)
  | Refused Text Text
  deriving stock (Eq, Show)

expected :: Json -> Outcome
expected r = case at "error" r of
  Null -> Accepted (at "ok" r) (case at "disposition" r of String d -> Just d; _ -> Nothing)
  e -> Refused (textOf (at "class" e)) (textOf (at "message" e))

refused :: AgenticusError -> Outcome
refused e = Refused (errorClassName e.errorClass) e.errorMessage

-- | An outcome whose value is the @json.dumps@ of a document.
documentOutcome :: (a -> Json) -> (a -> Maybe Text) -> Either AgenticusError a -> Outcome
documentOutcome encode disposition = either refused (\v -> Accepted (String (dumps (encode v))) (disposition v))

valueOutcome :: Either AgenticusError Json -> Outcome
valueOutcome = either refused (\v -> Accepted v Nothing)

-- | Compare a batch of outcomes, reporting the first few mismatches.
matchAll :: [(String, Outcome, Outcome)] -> Expectation
matchAll cases = do
  let failures = [(label, want, got) | (label, want, got) <- cases, not (same want got)]
  unless (null failures) $
    expectationFailure $
      show (length failures)
        <> " of "
        <> show (length cases)
        <> " cases differ; first:\n"
        <> unlines [label <> "\n  reference: " <> show want <> "\n  haskell:   " <> show got | (label, want, got) <- take 5 failures]
  where
    same (Accepted a da) (Accepted b db) = J.exactEq a b && da == db
    same a b = a == b

spec :: Spec
spec = describe "differential: thread_corpus.json" $ do
  corpus <- runIO (loadJson "differential/thread_corpus.json")

  describe "traces" $
    forM_ (zip [0 :: Int ..] (arrayOf (at "traces" corpus))) $ \(index, trace) ->
      it ("trace " <> show index <> " (" <> T.unpack (textOf (at "thread" trace)) <> ")") $ replayTrace trace

  describe "decode" $ do
    let cases = arrayOf (at "decode" corpus)
        kinds = Set.toList (Set.fromList [textOf (at "kind" c) | c <- cases])
    forM_ kinds $ \kind ->
      it ("from_data " <> T.unpack kind) $
        matchAll
          [ (T.unpack kind <> " " <> T.unpack (dumps (at "input" c)), expected (at "result" c), decode kind (at "input" c))
          | c <- cases
          , textOf (at "kind" c) == kind
          ]

  it "compatibility" $
    matchAll
      [ ( T.unpack (dumps c)
        , Accepted (at "result" c) Nothing
        , valueOutcome $ do
            p <- programFromData (at "program" c)
            d <- traverse continuationDescriptorFromData (nullable (at "continuation" c))
            pure (String (dumps (resultToData (checkContinuationCompatibility p d))))
        )
      | c <- arrayOf (at "compatibility" corpus)
      ]

  describe "runtime" $ do
    let runtime = at "runtime" corpus
        batch name build =
          it name $
            matchAll
              [ (T.unpack (dumps c), expected (at "result" c), build c)
              | c <- arrayOf (at (T.pack name) runtime)
              ]
    batch "components" $ \c -> valueOutcome $ case map textOf (arrayOf (at "args" c)) of
      [n, v, s] -> (\i -> Array (map String [i.name, i.version, i.sourceIdentity])) <$> mkInstalledComponent n v s
      _ -> error "bad component case"
    batch "issues" $ \c -> valueOutcome $ case arrayOf (at "args" c) of
      [code, comp] -> issueJson <$> mkProbeIssue (textOf code) (textOf <$> nullable comp)
      _ -> error "bad issue case"
    batch "installations" $ \c -> valueOutcome (installationView <$> installation (at "args" c))
    batch "probes" $ \c -> valueOutcome $ do
      let spec' = at "args" c
      r <- identityFromData (at "runtime" spec')
      inst <- traverse installation (nullable (at "installation" spec'))
      is <- traverse (\i -> case arrayOf i of [code, comp] -> mkProbeIssue (textOf code) (textOf <$> nullable comp); _ -> error "bad issue") (arrayOf (at "issues" spec'))
      result <- mkRuntimeProbeResult r (enumOf (at "disposition" spec')) inst is
      pure (Object [("issues", Array (map issueJson result.issues)), ("installation", Bool (result.installation /= Nothing))])
    batch "settlements" $ \c -> valueOutcome $ do
      let spec' = at "args" c
      result <-
        mkRuntimeTurnSettlement
          (literalEpisodeId "episode-1")
          (literalTurnId "turn-1")
          (enumOf (at "outcome" spec'))
          (intOf (at "accepted_appends" spec'))
          (textOf (at "termination_code" spec'))
          (textOf <$> nullable (at "output_reference" spec'))
          (textOf <$> nullable (at "continuation_reference" spec'))
      pure (Array [String result.terminationCode, maybe Null String result.outputReference, maybe Null String result.continuationReference])
    batch "cleanups" $ \c -> valueOutcome $ do
      let spec' = at "args" c
          erased = case at "physical_erasure_guaranteed" spec' of
            Bool b -> b
            _ -> error "bad erasure flag"
      Bool . cleanupVerified
        <$> mkRuntimeOperationCleanup (textOf (at "operation_id" spec')) (enumOf (at "disposition" spec')) (textOf (at "code" spec')) erased
    batch "protocol_errors" $ \c ->
      let e = runtimeProtocolError (textOf (at "code" c))
       in if e.errorClass == RuntimeProtocolError then Accepted (String e.errorMessage) Nothing else refused e
    batch "termination_codes" $ \c -> valueOutcome (String <$> safeTerminationCode (textOf (at "code" c)))

nullable :: Json -> Maybe Json
nullable = \case
  Null -> Nothing
  other -> Just other

issueJson :: ProbeIssue -> Json
issueJson i = Array [String i.code, maybe Null String i.component]

installation :: Json -> Either AgenticusError RuntimeInstallation
installation spec' = do
  r <- identityFromData (at "runtime" spec')
  components <-
    traverse
      (\c -> case map textOf (arrayOf c) of [n, v, s] -> mkInstalledComponent n v s; _ -> error "bad component")
      (arrayOf (at "components" spec'))
  mkRuntimeInstallation
    r
    (intOf (at "version" spec'))
    components
    (textOf (at "platform" spec'))
    (textOf (at "architecture" spec'))
    (Set.fromList (map textOf (arrayOf (at "capabilities" spec'))))

installationView :: RuntimeInstallation -> Json
installationView i =
  Object
    [ ("components", Array [Array (map String [c.name, c.version, c.sourceIdentity]) | c <- i.components])
    , ("capabilities", Array (map String (Set.toAscList i.capabilities)))
    ]

decode :: Text -> Json -> Outcome
decode kind input = case kind of
  "thread" -> doc threadToData threadFromData
  "episode" -> doc episodeToData episodeFromData
  "turn" -> doc turnToData turnFromData
  "budget" -> doc episodeBudgetToData episodeBudgetFromData
  "continuation" -> doc continuationToData continuationFromData
  "continuation_descriptor" -> doc continuationDescriptorToData continuationDescriptorFromData
  "program" -> doc programToData programFromData
  "thread_id" -> doc lifecycleIdToData (lifecycleIdFromData @ThreadId)
  "episode_id" -> doc lifecycleIdToData (lifecycleIdFromData @EpisodeId)
  "turn_id" -> doc lifecycleIdToData (lifecycleIdFromData @TurnId)
  "continuation_id" -> doc lifecycleIdToData (lifecycleIdFromData @ContinuationId)
  _ -> error ("unknown decode kind " <> T.unpack kind)
  where
    doc :: (a -> Json) -> (Json -> Either AgenticusError a) -> Outcome
    doc encode decoder = documentOutcome encode (const Nothing) (decoder input)

-- | Walk one session, checking every step's outcome, and that every
-- accepted Thread survives a full-validation round trip.
replayTrace :: Json -> Expectation
replayTrace trace = do
  let initial = do
        c <- traverse continuationFromData (nullable (at "continuation" trace))
        t <- mkThreadId (textOf (at "thread" trace))
        newThread t c
  matchAll [("initial thread", expected (at "result" trace), documentOutcome threadToData (const Nothing) initial)]
  case initial of
    Left _ -> pure ()
    Right t0 -> go (0 :: Int) t0 (arrayOf (at "steps" trace))
  where
    go _ _ [] = pure ()
    go n t (step : rest) = do
      let op = textOf (at "op" step)
          want = expected (at "result" step)
          label = "step " <> show n <> " " <> T.unpack (dumps step)
      case op of
        "episode_settle" -> do
          let got = documentOutcome (episodeToData . (.episode)) (Just . enumText . (.disposition)) $ do
                e <- lastEpisode t
                next <- traverse continuationFromData (nullable (at "continuation" step))
                episodeSettle (enumOf (at "outcome" step)) next e
          matchAll [(label, want, got)]
          go (n + 1) t rest
        "episode_cancel" -> do
          let got = case lastEpisode t of
                Right e ->
                  let c = episodeRequestCancellation e
                   in Accepted (String (dumps (episodeToData c.episode))) (Just (enumText c.disposition))
                Left err -> refused err
          matchAll [(label, want, got)]
          go (n + 1) t rest
        _ -> do
          let outcome = threadStep op step t
              got = either refused (\(t', d) -> Accepted (String (dumps (threadToData t'))) d) outcome
          matchAll [(label, want, got)]
          case outcome of
            Right (t', _) -> do
              threadFromData (threadToData t') `shouldBe` Right t'
              go (n + 1) t' rest
            Left _ -> go (n + 1) t rest

    lastEpisode t = case t.episodes of
      _ :|> e -> Right e
      Empty -> Left (valueError "no episode")

threadStep :: Text -> Json -> Thread -> Either AgenticusError (Thread, Maybe Text)
threadStep op step t = case op of
  "start_episode" -> do
    e <- mkEpisodeId (textOf (at "episode" step))
    p <- programFromData (at "program" step)
    r <- identityFromData (at "runtime" step)
    b <- case map intOf (arrayOf (at "budget" step)) of
      [turns, appends] -> mkEpisodeBudget turns appends
      _ -> error "bad budget"
    plain (startEpisode e p r b t)
  "start_turn" -> turn >>= \u -> plain (startTurn u t)
  "accept_append" -> turn >>= \u -> plain (acceptAppend u t)
  "settle_turn" -> turn >>= \u -> plain (settleTurn u (enumOf (at "outcome" step)) t)
  "request_cancellation" -> do
    c <- requestCancellation t
    pure (c.thread, Just (enumText c.disposition))
  "settle_episode" -> do
    next <- traverse continuationFromData (nullable (at "continuation" step))
    s <- settleEpisode (enumOf (at "outcome" step)) next t
    pure (s.thread, Just (enumText s.disposition))
  "close" -> plain (closeThread t)
  _ -> error ("unknown op " <> T.unpack op)
  where
    turn = mkTurnId (textOf (at "turn" step))
    plain = fmap (,Nothing)

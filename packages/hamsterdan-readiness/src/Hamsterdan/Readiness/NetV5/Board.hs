-- | Render the dashboard entries as a human decision board
-- (@net_v5/board.py@).
--
-- The dashboard loop's entry log is the projection identity and stays
-- untouched; this module is the PRESENTATION of that log at the
-- publication seam. The board answers exactly three reader questions, in
-- order: can this merge, who acts next, and which head does the answer
-- refer to. Latest fact per concern wins.
--
-- An entry this renderer cannot parse is shown verbatim in the attention
-- list instead of faulting the upsert. Entry bodies are Python literals
-- of any shape, so every read below reproduces the reference's dynamic
-- semantics (@str()@, truthiness, @int()@, @==@); where the reference
-- raises, the render answers 'Left' with the exception it raises.
module Hamsterdan.Readiness.NetV5.Board
  ( renderBoard
  , gateFacts
  , gateFactsValue
  , pyInt
  ) where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.PyLiteral (LiteralError (..), LiteralErrorKind (..), PyValue (..), literalEval, pyEq, repr)
import Hamsterdan.Python (PythonException, intText, pythonError)

typeError, valueError :: Text -> PythonException
typeError = pythonError "TypeError"
valueError = pythonError "ValueError"

type Body = [(PyValue, PyValue)]

-- | Body or parse refusal: 'Nothing' for an unrecognized entry.
parsed :: Text -> Either PythonException (Maybe (Text, Body))
parsed entry = case T.breakOn ":" entry of
  (_, "") -> Right Nothing
  (kind, rest) -> case literalEval (T.drop 1 rest) of
    Right (PyDict body) -> Right (Just (kind, body))
    Right _ -> Right Nothing
    Left e -> case e.errorKind of
      -- @literal_eval@'s TypeError escapes the reference's
      -- @except ValueError, SyntaxError@.
      Unhashable -> Left (typeError e.errorMessage)
      _ -> Right Nothing

-- | @body.get(key)@ for a string key.
getV :: Text -> Body -> Maybe PyValue
getV key body = snd <$> find (pyEq (PyStr key) . fst) body

getOr :: Text -> PyValue -> Body -> PyValue
getOr key fallback body = maybe fallback id (getV key body)

-- | @str(value)@.
str :: PyValue -> Text
str = \case
  PyStr s -> s
  other -> repr other

truthy :: PyValue -> Bool
truthy = \case
  PyNone -> False
  PyBool b -> b
  PyInt i -> i /= 0
  PyFloat d -> d /= 0
  PyStr s -> not (T.null s)
  PyList xs -> not (null xs)
  PyTuple xs -> not (null xs)
  PyDict xs -> not (null xs)

-- | @int(value or 0)@.
intOr0 :: PyValue -> Either PythonException Integer
intOr0 v = if truthy v then pyInt v else Right 0

-- | @int(value)@ for a literal value.
pyInt :: PyValue -> Either PythonException Integer
pyInt = \case
  PyBool b -> Right (if b then 1 else 0)
  PyInt i -> Right i
  PyFloat d
    | isNaN d -> Left (valueError "cannot convert float NaN to integer")
    | isInfinite d -> Left (pythonError "OverflowError" "cannot convert float infinity to integer")
    | otherwise -> Right (truncate d)
  PyStr s -> intText s
  PyNone -> Left (notReal "NoneType")
  PyList _ -> Left (notReal "list")
  PyTuple _ -> Left (notReal "tuple")
  PyDict _ -> Left (notReal "dict")
  where
    notReal t = typeError ("int() argument must be a string, a bytes-like object or a real number, not '" <> t <> "'")

-- | Insert or replace in place, as a Python dict assignment does.
assign :: (Eq k) => k -> v -> [(k, v)] -> [(k, v)]
assign k v xs
  | any ((== k) . fst) xs = [(k', if k' == k then v else v') | (k', v') <- xs]
  | otherwise = xs ++ [(k, v)]

remove :: (Eq k) => k -> [(k, v)] -> [(k, v)]
remove k = filter ((/= k) . fst)

-- | The latest fact per concern, plus the paired open/closed sets.
data Facts = Facts
  { latest :: [(Text, Body)]
  , faults :: [((Text, Text), Body)]
  , mutations :: [(Text, Body)]
  , humanNeeded :: Maybe Body
  , unparsed :: [Text]
  }

collect :: [Text] -> Either PythonException Facts
collect = go (Facts [] [] [] Nothing [])
  where
    go facts [] = Right facts
    go facts (entry : rest) =
      parsed entry >>= \case
        Nothing -> go facts {unparsed = facts.unparsed ++ [entry]} rest
        Just (kind, body) -> go (absorb facts {latest = assign kind body facts.latest} kind body) rest
    absorb facts kind body = case kind of
      "fault" ->
        let key = (str (getOr "where" (PyStr "") body), str (getOr "op" (PyStr "") body))
            status = getOr "status" PyNone body
         in if any (pyEq status . PyStr) ["resolved", "cancelled"]
              then facts {faults = remove key facts.faults}
              else facts {faults = assign key body facts.faults}
      "mutation_pending" -> facts {mutations = assign (str (getOr "op_key" (PyStr "") body)) body facts.mutations}
      "mutation_settled" -> facts {mutations = remove (str (getOr "op_key" (PyStr "") body)) facts.mutations}
      "human_needed" -> facts {humanNeeded = Just body}
      -- fresh CI evidence obsoletes the exhausted-ladder escalation
      "checks" -> facts {humanNeeded = Nothing}
      _ -> facts

concern :: Text -> Facts -> Body
concern kind facts = maybe [] id (lookup kind facts.latest)

short :: PyValue -> Text
short = T.take 7 . str

is :: Text -> Maybe PyValue -> Bool
is expected = maybe False (pyEq (PyStr expected))

verdict :: Facts -> Either PythonException Text
verdict facts
  | is "terminal" (getV "phase" state) = Right "closed — this board is frozen."
  | is "quiescent" (getV "phase" state) = Right "paused — draft PR. I resume when it leaves draft."
  | ((_, op), body) : _ <- facts.faults =
      Right
        ( "⚠️ needs attention — operation `" <> op <> "` faulted: " <> str (getOr "reason" (PyStr "") body)
            <> ". Ask me to recover it."
        )
  | Just _ <- facts.humanNeeded =
      Right ("❌ CI keeps failing on `" <> headShort <> "` — automated reruns are exhausted. **A human needs to look.**")
  | not (null facts.mutations) = Right ("🔧 working — I'm pushing an update to `" <> headShort <> "`.")
  | checks == "failure" = Right ("❌ CI failed for `" <> headShort <> "`. **Author:** fix and push; I re-evaluate the new head.")
  | otherwise = do
      blocking <- intOr0 (getOr "blocking" (PyInt 0) findings)
      if blocking > 0
        then
          let b = getOr "blocking" PyNone findings
           in Right
                ( "❌ " <> str b <> " blocking finding(s) of " <> str (getOr "count" b findings) <> " on `" <> headShort
                    <> "`. **Author:** see the review findings."
                )
        else
          if is "unable" (getV "status" review)
            then
              Right
                ( "⚠️ I could not review `" <> headShort <> "` (" <> str (getOr "category" (PyStr "unable") review)
                    <> "). Push a new head or ask me to retry."
                )
            else
              if truthy (getOr "changes_requested" PyNone human)
                then Right ("waiting on author — a reviewer requested changes on `" <> headShort <> "`.")
                else do
                  unresolved <- intOr0 (getOr "unresolved" (PyInt 0) human)
                  Right (afterHuman unresolved)
  where
    state = concern "state" facts
    review = concern "review" facts
    findings = concern "findings" facts
    human = concern "human" facts
    checks = checksStatus facts
    headShort = short (getOr "head" (PyStr "") state)
    afterHuman unresolved
      | unresolved > 0 =
          "waiting on humans — " <> str (getOr "unresolved" PyNone human) <> " unresolved review thread(s) on `" <> headShort <> "`."
      | not (truthy (getOr "base_current" (PyBool False) state)) =
          "⚠️ base is stale — the target branch moved past `" <> short (getOr "base" (PyStr "") state)
            <> "`. **Author:** update the branch."
      | not (truthy (getOr "mergeable" (PyBool True) state)) = "❌ merge conflict on `" <> headShort <> "`. **Author:** resolve and push."
      | checks `elem` ["pending", "queued", "in_progress"] = "⏳ waiting on CI for `" <> headShort <> "`. Nothing for you to do."
      | not (is "clear" (getV "status" review)) = "⏳ reviewing `" <> headShort <> "`. Nothing for you to do."
      | not (truthy (getOr "approval" (PyBool False) human)) =
          "waiting on human approval for `" <> headShort <> "` — everything on my side is clear."
      | otherwise = "✅ all gates clear for `" <> headShort <> "` — see the readiness advisory. Merging stays yours."

checksStatus :: Facts -> Text
checksStatus facts = str (getOr "status" (PyStr "pending") (concern "checks" facts))

checksCell :: Text -> Text
checksCell = \case
  "pending" -> "⏳ not started"
  "queued" -> "⏳ queued"
  "in_progress" -> "⏳ in progress"
  "success" -> "✅ success"
  "failure" -> "❌ failing"
  other -> "⚠️ " <> other

reviewCellOf :: Text -> Text
reviewCellOf = \case
  "pending" -> "⏳ reviewing"
  "clear" -> "✅ clear"
  "blocking" -> "❌ blocking"
  "unable" -> "⚠️ unable"
  other -> "⚠️ " <> other

reviewCell :: Facts -> Either PythonException Text
reviewCell facts
  | status == "unable" =
      let category = str (getOr "category" (PyStr "") review)
       in Right (if category `elem` ["", "unable"] then cell else cell <> " · " <> category)
  | Just raw <- getV "count" findings = do
      count <- intOr0 raw
      Right
        ( if count == 0
            then cell <> " · 0 findings"
            else cell <> " · " <> str (getOr "blocking" (PyInt 0) findings) <> " blocking of " <> T.pack (show count) <> " finding(s)"
        )
  | otherwise = Right cell
  where
    review = concern "review" facts
    findings = concern "findings" facts
    status = str (getOr "status" (PyStr "pending") review)
    cell = reviewCellOf status

humanCell :: Facts -> Text
humanCell facts
  | null human = "⏳ no review yet"
  | otherwise = approval <> " · " <> str (getOr "unresolved" (PyInt 0) human) <> " unresolved thread(s)"
  where
    human = concern "human" facts
    approval
      | truthy (getOr "changes_requested" PyNone human) = "❌ changes requested"
      | truthy (getOr "approval" PyNone human) = "✅ approved"
      | otherwise = "⏳ not approved"

rows :: Facts -> Either PythonException [(Text, Text)]
rows facts = do
  review <- reviewCell facts
  Right
    [ ("CI checks", checksCell (checksStatus facts))
    , ("Dan's review", review)
    , ("Human review", humanCell facts)
    , ("Base", if truthy (getOr "base_current" PyNone state) then "✅ current with `" <> base <> "`" else "⚠️ behind `" <> base <> "`")
    , ("Conflicts", if truthy (getOr "mergeable" (PyBool True) state) then "✅ none" else "❌ merge conflict")
    ]
  where
    state = concern "state" facts
    base = short (getOr "base" (PyStr "") state)

attention :: Facts -> [Text]
attention facts =
  [ "- ⚠️ " <> wherePart <> " operation `" <> op <> "` faulted: " <> str (getOr "reason" (PyStr "") body) <> " — ask me to recover it."
  | ((wherePart, op), body) <- facts.faults
  ]
    ++ ["- 🔧 push in flight: `" <> str (getOr "op" (PyStr "") body) <> "`." | (_, body) <- facts.mutations]
    ++ [ "- ❌ CI failure `" <> short (getOr "fingerprint" (PyStr "") body) <> "` exhausted automated reruns — a human needs to look."
       | Just body <- [facts.humanNeeded]
       ]
    ++ ["- ⚠️ unrecognized: `" <> entry <> "`" | entry <- facts.unparsed]

-- | @gate_facts(entries)@: the same distilled fold the rendered board
-- shows, as data — @(kind, body)@ pairs in the reference's order.
gateFacts :: [Text] -> Either PythonException [(Text, Body)]
gateFacts entries = do
  facts <- collect entries
  let derived = ["fault", "mutation_pending", "mutation_settled", "human_needed"]
  Right
    ( [(kind, body) | (kind, body) <- facts.latest, kind `notElem` derived]
        ++ [("fault", body) | (_, body) <- facts.faults]
        ++ [("mutation_pending", body) | (_, body) <- facts.mutations]
        ++ [("human_needed", body) | Just body <- [facts.humanNeeded]]
    )

-- | 'gateFacts' as the Python value @gate_facts@ returns
-- (@[{"kind": ..., "body": {...}}, ...]@).
gateFactsValue :: [Text] -> Either PythonException PyValue
gateFactsValue entries = do
  view <- gateFacts entries
  Right (PyList [PyDict [(PyStr "kind", PyStr kind), (PyStr "body", PyDict body)] | (kind, body) <- view])

-- | @render_board(entries)@.
renderBoard :: [Text] -> Either PythonException Text
renderBoard entries = do
  facts <- collect entries
  table <- T.intercalate "\n" . map (\(g, c) -> "| " <> g <> " | " <> c <> " |") <$> rows facts
  headline <- verdict facts
  let state = concern "state" facts
      sections =
        ["## Hamsterdan summary — " <> headline, "| Gate | State |\n|------|-------|\n" <> table]
          ++ [T.intercalate "\n" lines' | let lines' = attention facts, not (null lines')]
          ++ [ "<sub>head " <> str h <> " on base " <> str (getOr "base" (PyStr "") state) <> "</sub>"
             | Just h <- [getV "head" state]
             , truthy h
             ]
  Right (T.intercalate "\n\n" sections)

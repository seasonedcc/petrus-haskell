-- | Deterministic Graphviz presentation of a canonical 'Net'
-- (@petrus.impetus.petrinet.dot@).
--
-- 'toDot' is byte-identical to the reference's @to_dot@ for the same net,
-- marking, and options; 'render' writes DOT directly or shells out to a
-- local Graphviz for SVG, PNG, or PDF.
module Petrus.Impetus.Petrinet.Dot
  ( Theme (..)
  , Direction (..)
  , DotOptions (..)
  , defaultDotOptions
  , toDot
  , render
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Internal.Repr (pyStr)
import Petrus.Impetus.Petrinet.Marking (Marking, counts)
import Petrus.Impetus.Petrinet.Schema
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath (takeExtension)
import System.IO (Handle, hClose, hSetBinaryMode)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, waitForProcess)

data Theme = Dark | Light
  deriving stock (Eq, Show)

data Direction = TopDown | LeftRight
  deriving stock (Eq, Show)

data DotOptions = DotOptions
  { theme :: Theme
  , direction :: Direction
  , groupScopes :: Bool
  }
  deriving stock (Eq, Show)

-- | The reference's keyword defaults: dark, top-down, grouped scopes.
defaultDotOptions :: DotOptions
defaultDotOptions = DotOptions Dark TopDown True

data Palette = Palette
  { canvas, cluster, primary, secondary, placeColor, transitionColor, consumeColor, readColor, inhibitColor, marked :: Text
  }

palette :: Theme -> Palette
palette = \case
  Dark -> Palette "#0d1117" "#161b22" "#e6edf3" "#8b949e" "#58a6ff" "#d29922" "#8b949e" "#58a6ff" "#f85149" "#1f6feb"
  Light -> Palette "#ffffff" "#f6f8fa" "#1f2328" "#59636e" "#0969da" "#9a6700" "#57606a" "#0969da" "#cf222e" "#ddf4ff"

rankdir :: Direction -> Text
rankdir = \case
  TopDown -> "TB"
  LeftRight -> "LR"

-- | Graphviz text: no NUL; newlines normalized.
textOf :: Text -> Either Text Text
textOf value
  | T.any (== '\0') value = Left "Graphviz text cannot contain a NUL character"
  | otherwise = Right (T.replace "\r" "\n" (T.replace "\r\n" "\n" value))

quoteDot :: Text -> Either Text Text
quoteDot value = do
  text <- textOf value
  Right ("\"" <> T.replace "\n" "\\n" (T.replace "\"" "\\\"" (T.replace "\\" "\\\\" text)) <> "\"")

attributes :: [(Text, Text)] -> Either Text Text
attributes values = T.intercalate ", " <$> mapM (\(name, value) -> ((name <> "=") <>) <$> quoteDot value) values

-- | Python's @html.escape(text, quote=True)@.
htmlEscape :: Text -> Text
htmlEscape = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  '\'' -> "&#x27;"
  c -> T.singleton c

richLabel :: Text -> Text -> Palette -> Either Text Text
richLabel primaryText secondaryText p = do
  primaryT <- (T.replace "\n" "<BR ALIGN=\"CENTER\"/>" . htmlEscape) <$> textOf primaryText
  secondaryT <- (T.replace "\n" "<BR ALIGN=\"CENTER\"/>" . htmlEscape) <$> textOf secondaryText
  let rows =
        "<TR><TD><B><FONT COLOR=\""
          <> p.primary
          <> "\" POINT-SIZE=\"14\">"
          <> primaryT
          <> "</FONT></B></TD></TR>"
          <> ( if T.null secondaryT
                 then ""
                 else "<TR><TD><FONT COLOR=\"" <> p.secondary <> "\" POINT-SIZE=\"9\">" <> secondaryT <> "</FONT></TD></TR>"
             )
  Right ("<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLPADDING=\"1\">" <> rows <> "</TABLE>>")

nodeAttributes :: [(Text, Text)] -> Text -> [(Text, Text)] -> Either Text Text
nodeAttributes before label after = do
  b <- attributes before
  a <- attributes after
  Right (b <> ", label=" <> label <> ", " <> a)

declarationText :: Either AnonymousDeclaration (Either Text Cel) -> Text
declarationText = \case
  Left anonymousDeclaration -> maybe "anonymous declaration" id anonymousDeclaration.displayName
  Right (Left symbol) -> symbol
  Right (Right expression) -> "cel: " <> celExpression expression

declarationTooltip :: Either AnonymousDeclaration (Either Text Cel) -> Text
declarationTooltip value = case value of
  Left anonymousDeclaration | isJust anonymousDeclaration.displayName -> declarationText value <> " (anonymous declaration)"
  _ -> declarationText value

handlerView :: HandlerDeclaration -> Either AnonymousDeclaration (Either Text Cel)
handlerView = \case
  HandlerSymbol s -> Right (Left s)
  HandlerAnonymous a -> Left a

guardView :: GuardDeclaration -> Either AnonymousDeclaration (Either Text Cel)
guardView = \case
  GuardSymbol s -> Right (Left s)
  GuardCel c -> Right (Right c)
  GuardAnonymous a -> Left a

filterView :: FilterDeclaration -> Either AnonymousDeclaration (Either Text Cel)
filterView = \case
  FilterSymbol s -> Right (Left s)
  FilterCel c -> Right (Right c)

timerText :: Timer -> Text
timerText = \case
  Delay duration -> "delay: " <> T.pack (show duration)
  Until instant -> "until: " <> T.pack (show instant)

isBareAnonymous :: Either AnonymousDeclaration a -> Bool
isBareAnonymous = \case
  Left a -> not (isJust a.displayName)
  Right _ -> False

transitionDetails :: Transition -> Bool -> (Text, Text)
transitionDetails t source =
  let handlerParts = case t.handler of
        Nothing -> []
        Just h ->
          let v = handlerView h
           in [(if isBareAnonymous v then "handler" else "handler: " <> declarationText v, "handler: " <> declarationTooltip v)]
      guardParts = case t.guards of
        [] -> []
        [g] ->
          let v = guardView g
           in [(if isBareAnonymous v then "guard" else "guard: " <> declarationText v, "guards: " <> declarationTooltip v)]
        gs -> [(T.pack (show (length gs)) <> " guards", "guards: " <> T.intercalate "; " (map (declarationTooltip . guardView) gs))]
      timerParts = case map timerText t.timers of
        [] -> []
        [single] -> [(single, "timers: " <> single)]
        many -> [(T.pack (show (length many)) <> " timers", "timers: " <> T.intercalate "; " many)]
      sourceParts = [("source", "source transition") | source]
      parts = sourceParts ++ handlerParts ++ guardParts ++ timerParts
   in (T.intercalate " · " (map fst parts), T.intercalate "\n" (netPathText t.path : map snd parts))

placeLine :: Text -> Place -> Int -> Palette -> Text -> Either Text Text
placeLine identifier pl count p indent = do
  let secondaryParts = maybe [] pure pl.color ++ [T.pack (show count) <> (if count == 1 then " token" else " tokens") | count /= 0]
      before = [("color", p.placeColor), ("fillcolor", if count /= 0 then p.marked else p.canvas)]
      after = [("shape", "ellipse"), ("style", "filled"), ("tooltip", netPathText pl.path)]
  label <- richLabel (lastSegment pl.path) (T.intercalate " · " secondaryParts) p
  q <- quoteDot identifier
  body <- nodeAttributes before label after
  Right (indent <> q <> " [" <> body <> "];")

transitionLine :: Text -> Transition -> Bool -> Palette -> Text -> Either Text Text
transitionLine identifier t source p indent = do
  let (secondaryText, tooltip) = transitionDetails t source
      before = [("color", p.transitionColor), ("fillcolor", p.cluster)]
      after =
        [("penwidth", "2") | source]
          ++ [ ("shape", "box")
             , ("style", if source then "rounded,filled,dashed" else "rounded,filled")
             , ("tooltip", tooltip)
             ]
  label <- richLabel (lastSegment t.path) secondaryText p
  q <- quoteDot identifier
  body <- nodeAttributes before label after
  Right (indent <> q <> " [" <> body <> "];")

data Node = PlaceNode NetPath Text Place | TransitionNode NetPath Text Transition

nodePath :: Node -> NetPath
nodePath = \case
  PlaceNode at _ _ -> at
  TransitionNode at _ _ -> at

nodeLine :: Net -> Map.Map NetPath Int -> Palette -> Text -> Node -> Either Text Text
nodeLine net countMap p indent = \case
  PlaceNode at identifier pl -> placeLine identifier pl (Map.findWithDefault 0 at countMap) p indent
  TransitionNode at identifier t -> transitionLine identifier t (isSource net at) p indent

arcLine :: Arc -> Text -> Text -> Palette -> Either Text Text
arcLine a sourceId targetId p = do
  let semantic = case a.mode of
        Read -> "read"
        Inhibit -> "inhibit"
        Consume -> "consume"
      colorFor = case a.mode of
        Read -> p.readColor
        Inhibit -> p.inhibitColor
        Consume -> p.consumeColor
      labelParts =
        [semantic | a.mode /= Consume]
          ++ [T.pack (show a.weight) <> "×" | a.weight /= 1]
          ++ maybe [] pure a.color
          ++ maybe [] (\f -> ["filter: " <> declarationText (filterView f)]) a.filter
      attrs =
        [("arrowhead", if a.mode == Inhibit then "odot" else "normal"), ("color", colorFor)]
          ++ [("label", T.intercalate " · " labelParts) | not (null labelParts)]
          ++ [ ("style", if a.mode == Consume then "solid" else "dashed")
             , ("tooltip", netPathText a.source <> " -> " <> netPathText a.target)
             ]
  s <- quoteDot sourceId
  t <- quoteDot targetId
  body <- attributes attrs
  Right ("  " <> s <> " -> " <> t <> " [" <> body <> "];")

-- | Deterministic Graphviz DOT source for one canonical net. 'Left' only
-- for text Graphviz cannot carry (a NUL character).
toDot :: Net -> Maybe Marking -> DotOptions -> Either Text Text
toDot net marking options = do
  let p = palette options.theme
      countMap = maybe Map.empty (Map.fromList . counts) marking
      placeNodes = [PlaceNode at ("p" <> T.pack (show position)) (netPlaces net Map.! at) | (position, at) <- zip [0 :: Int ..] (netPlaceOrder net)]
      transitionNodes = [TransitionNode at ("t" <> T.pack (show position)) (netTransitions net Map.! at) | (position, at) <- zip [0 :: Int ..] (netTransitionOrder net)]
      nodes = placeNodes ++ transitionNodes
      identifiers = Map.fromList [(nodePath n, identifierOf n) | n <- nodes]
      identifierOf = \case
        PlaceNode _ i _ -> i
        TransitionNode _ i _ -> i
      graphAttributes =
        [("bgcolor", p.canvas), ("fontcolor", p.primary), ("fontname", "Helvetica")]
          ++ maybe [] (\n -> [("label", n), ("labelloc", "t")]) (netName net)
          ++ [("nodesep", "0.6"), ("pad", "0.25"), ("rankdir", rankdir options.direction), ("ranksep", "1.0")]
  graphLine <- attributes graphAttributes
  primaryQ <- quoteDot p.primary
  secondaryQ <- quoteDot p.secondary
  let (scoped, unscoped) =
        foldl'
          ( \(sc, un) n ->
              let at = nodePath n
               in if options.groupScopes && segmentCount at > 1
                    then (OMap.insertWith (\new old -> old ++ new) (firstSegment at) [n] sc, un)
                    else (sc, un ++ [n])
          )
          (OMap.empty, [])
          nodes
  unscopedLines <- mapM (nodeLine net countMap p "  ") unscoped
  clusterLines <-
    concat
      <$> mapM
        ( \(position, (scopeName, members)) -> do
            clusterAttrs <-
              attributes
                [ ("color", p.secondary)
                , ("fillcolor", p.cluster)
                , ("fontcolor", p.secondary)
                , ("label", scopeName)
                , ("style", "filled")
                , ("tooltip", scopeName)
                ]
            memberLines <- mapM (nodeLine net countMap p "    ") members
            Right
              ( ["  subgraph \"cluster_" <> T.pack (show position) <> "\" {", "    graph [" <> clusterAttrs <> "];"]
                  ++ memberLines
                  ++ ["  }"]
              )
        )
        (zip [0 :: Int ..] (OMap.toList scoped))
  arcLines <- mapM (\a -> arcLine a (identifiers Map.! a.source) (identifiers Map.! a.target) p) (netArcs net)
  let lines' =
        [ "digraph \"impetus\" {"
        , "  graph [" <> graphLine <> "];"
        , "  node [fontcolor=" <> primaryQ <> ", fontname=\"Helvetica\"];"
        , "  edge [fontcolor=" <> secondaryQ <> ", fontname=\"Helvetica\", fontsize=\"10\"];"
        ]
          ++ unscopedLines
          ++ clusterLines
          ++ arcLines
          ++ ["}"]
  Right (T.intercalate "\n" lines' <> "\n")

-- | Write DOT directly (@.dot@) or render SVG, PNG, or PDF through the local
-- Graphviz @dot@ executable. Returns the target path, or the reference's
-- error message.
render :: Net -> FilePath -> Maybe Marking -> DotOptions -> IO (Either Text FilePath)
render net target marking options = do
  let extension = takeExtension target
      suffix = map toLower extension
      formats = [(".svg", "svg"), (".png", "png"), (".pdf", "pdf")] :: [(String, String)]
  if suffix /= ".dot" && suffix `notElem` map fst formats
    then pure (Left ("unsupported Graphviz output suffix " <> pyStr (T.pack extension) <> "; expected .dot, .svg, .png, or .pdf"))
    else case toDot net marking options of
      Left err -> pure (Left err)
      Right source
        | suffix == ".dot" -> BS.writeFile target (TE.encodeUtf8 source) >> pure (Right target)
        | otherwise -> do
            executable <- findExecutable "dot"
            case executable of
              Nothing -> pure (Left "Graphviz 'dot' executable was not found; install Graphviz or render to a .dot file")
              Just dotPath -> do
                let format = maybe "svg" id (lookup suffix formats)
                started <-
                  try
                    ( createProcess
                        (proc dotPath ["-T" <> format, "-o", target]) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
                    ) ::
                    IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
                case started of
                  Left err -> pure (Left ("Graphviz 'dot' could not be started: " <> T.pack (show err)))
                  Right (Just stdinH, Just stdoutH, Just stderrH, handle) -> do
                    hSetBinaryMode stdinH True
                    BS.hPut stdinH (TE.encodeUtf8 source)
                    hClose stdinH
                    errBytes <- BS.hGetContents stderrH
                    _ <- BS.hGetContents stdoutH
                    code <- waitForProcess handle
                    case code of
                      ExitSuccess -> pure (Right target)
                      ExitFailure n -> do
                        let diagnostic = T.strip (TE.decodeUtf8Lenient errBytes)
                        pure
                          ( Left
                              ( "Graphviz 'dot' failed with exit code "
                                  <> T.pack (show n)
                                  <> ": "
                                  <> (if T.null diagnostic then "no diagnostic output" else diagnostic)
                              )
                          )
                  Right _ -> pure (Left "Graphviz 'dot' could not be started: missing pipes")

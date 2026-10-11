-- | Parity: @tests/petrus/impetus/petrinet/test_petrinet_dot.py@.
--
-- The reference's monkeypatched @shutil.which@ / @subprocess.run@ become a
-- real search path: each render test points @PATH@ at a scratch directory
-- holding (or lacking) a fake @dot@ executable.
module Petrus.Impetus.DotSpec (spec) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Petrinet.Dot
import Petrus.Impetus.TestSupport
import Petrus.Json (Json (..))
import System.Directory
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec

goldenNet :: Net
goldenNet =
  let source = np "scope.input"
      at = np "scope.run"
      target = np "scope.output"
   in mustNet
        (netSpec [coloredPlace source "Work", place target] [(transition at) {handler = Just (HandlerSymbol "process"), guards = [GuardSymbol "ready"], timers = [Delay 5]}] [arc source at, arc at target])
          { name = Just "example"
          }

dot :: Net -> Maybe Marking -> DotOptions -> IO Text
dot net marking options = expectRight (toDot net marking options)

data Golden = Golden {goldenTheme :: Theme, goldenDirection :: Direction, background, cluster, primary, secondary, placeColor, transitionColor, consumeColor, rankdir :: Text}

goldenSource :: Golden -> Text
goldenSource g =
  T.unlines
    [ "digraph \"impetus\" {"
    , "  graph [bgcolor=\"" <> g.background <> "\", fontcolor=\"" <> g.primary <> "\", fontname=\"Helvetica\", label=\"example\", labelloc=\"t\", nodesep=\"0.6\", pad=\"0.25\", rankdir=\"" <> g.rankdir <> "\", ranksep=\"1.0\"];"
    , "  node [fontcolor=\"" <> g.primary <> "\", fontname=\"Helvetica\"];"
    , "  edge [fontcolor=\"" <> g.secondary <> "\", fontname=\"Helvetica\", fontsize=\"10\"];"
    , "  subgraph \"cluster_0\" {"
    , "    graph [color=\"" <> g.secondary <> "\", fillcolor=\"" <> g.cluster <> "\", fontcolor=\"" <> g.secondary <> "\", label=\"scope\", style=\"filled\", tooltip=\"scope\"];"
    , "    \"p0\" [color=\"" <> g.placeColor <> "\", fillcolor=\"" <> g.background <> "\", label=<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLPADDING=\"1\"><TR><TD><B><FONT COLOR=\"" <> g.primary <> "\" POINT-SIZE=\"14\">input</FONT></B></TD></TR><TR><TD><FONT COLOR=\"" <> g.secondary <> "\" POINT-SIZE=\"9\">Work</FONT></TD></TR></TABLE>>, shape=\"ellipse\", style=\"filled\", tooltip=\"scope.input\"];"
    , "    \"p1\" [color=\"" <> g.placeColor <> "\", fillcolor=\"" <> g.background <> "\", label=<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLPADDING=\"1\"><TR><TD><B><FONT COLOR=\"" <> g.primary <> "\" POINT-SIZE=\"14\">output</FONT></B></TD></TR></TABLE>>, shape=\"ellipse\", style=\"filled\", tooltip=\"scope.output\"];"
    , "    \"t0\" [color=\"" <> g.transitionColor <> "\", fillcolor=\"" <> g.cluster <> "\", label=<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLPADDING=\"1\"><TR><TD><B><FONT COLOR=\"" <> g.primary <> "\" POINT-SIZE=\"14\">run</FONT></B></TD></TR><TR><TD><FONT COLOR=\"" <> g.secondary <> "\" POINT-SIZE=\"9\">handler: process · guard: ready · delay: 5</FONT></TD></TR></TABLE>>, shape=\"box\", style=\"rounded,filled\", tooltip=\"scope.run\\nhandler: process\\nguards: ready\\ntimers: delay: 5\"];"
    , "  }"
    , "  \"p0\" -> \"t0\" [arrowhead=\"normal\", color=\"" <> g.consumeColor <> "\", label=\"Work\", style=\"solid\", tooltip=\"scope.input -> scope.run\"];"
    , "  \"t0\" -> \"p1\" [arrowhead=\"normal\", color=\"" <> g.consumeColor <> "\", style=\"solid\", tooltip=\"scope.run -> scope.output\"];"
    , "}"
    ]

goldens :: [Golden]
goldens =
  [ Golden Dark TopDown "#0d1117" "#161b22" "#e6edf3" "#8b949e" "#58a6ff" "#d29922" "#8b949e" "TB"
  , Golden Dark LeftRight "#0d1117" "#161b22" "#e6edf3" "#8b949e" "#58a6ff" "#d29922" "#8b949e" "LR"
  , Golden Light TopDown "#ffffff" "#f6f8fa" "#1f2328" "#59636e" "#0969da" "#9a6700" "#57606a" "TB"
  , Golden Light LeftRight "#ffffff" "#f6f8fa" "#1f2328" "#59636e" "#0969da" "#9a6700" "#57606a" "LR"
  ]

shouldContainText :: HasCallStack => Text -> Text -> Expectation
shouldContainText haystack needle =
  if needle `T.isInfixOf` haystack
    then pure ()
    else expectationFailure ("expected to find " <> show needle <> " in:\n" <> T.unpack haystack)

shouldNotContainText :: HasCallStack => Text -> Text -> Expectation
shouldNotContainText haystack needle =
  if needle `T.isInfixOf` haystack
    then expectationFailure ("did not expect to find " <> show needle <> " in:\n" <> T.unpack haystack)
    else pure ()

-- | A fresh scratch directory, removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-dot-spec"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- | Run with @PATH@ set to exactly the directory (the monkeypatched
-- @shutil.which@).
withSearchPath :: FilePath -> IO a -> IO a
withSearchPath dir action =
  bracket
    (lookupEnv "PATH" <* setEnv "PATH" dir)
    (maybe (unsetEnv "PATH") (setEnv "PATH"))
    (const action)

-- | Install an executable @dot@ script into the directory.
fakeDot :: FilePath -> String -> IO FilePath
fakeDot dir body = do
  let path = dir </> "dot"
  writeFile path body
  permissions <- getPermissions path
  setPermissions path (setOwnerExecutable True permissions)
  pure path

-- | The attributes of an SVG tag's attribute text.
attributesOf :: Text -> [(Text, Text)]
attributesOf text = case T.breakOn "=\"" text of
  (_, "") -> []
  (preceding, rest) ->
    let name = case reverse (T.words preceding) of
          lastWord : _ -> lastWord
          [] -> ""
        (value, remaining) = T.breakOn "\"" (T.drop 2 rest)
     in (name, value) : attributesOf (T.drop 1 remaining)

-- | Each @<text ...>content</text>@ element as (attributes, content).
textElements :: Text -> [([(Text, Text)], Text)]
textElements svg =
  [ (attributesOf attrs, T.takeWhile (/= '<') (T.drop 1 content))
  | chunk <- drop 1 (T.splitOn "<text" svg)
  , let (attrs, content) = T.breakOn ">" chunk
  ]

spec :: Spec
spec = describe "Petrinet.Dot" $ do
  -- test_to_dot_has_deterministic_golden_source_for_each_presentation (parametrized)
  describe "golden source" $
    mapM_
      ( \g ->
          it ("is deterministic for " <> show g.goldenTheme <> " " <> show g.goldenDirection) $ do
            let options = defaultDotOptions {theme = g.goldenTheme, direction = g.goldenDirection}
            dot goldenNet Nothing options `shouldReturn` goldenSource g
            dot goldenNet Nothing options `shouldReturn` goldenSource g
      )
      goldens

  -- test_to_dot_presents_marking_declarations_and_every_arc_semantic (parametrized)
  describe "marking, declarations, and arc semantics" $
    mapM_
      ( \(theme', marked, consumeColor, readColor, inhibitColor) ->
          it ("are presented for " <> show theme') $ do
            let consumePlace = np "flow.consume"
                readPlace = np "flow.read"
                inhibitPlace = np "flow.inhibit"
                done = np "flow.done"
                run = np "flow.run"
                net =
                  netOf
                    [place consumePlace, place readPlace, place inhibitPlace, place done]
                    [(transition run) {handler = Just (HandlerSymbol "handle"), guards = [GuardCel (unsafeCel "binding.ok"), GuardSymbol "allowed"], timers = [Delay 2, Until 9]}]
                    [ withArcColor (Just "Job") ((arc consumePlace run) {weight = 2, filter = Just (FilterCel (unsafeCel "token.kind == \"ready\""))})
                    , (arc readPlace run) {mode = Read, filter = Just (FilterSymbol "visible")}
                    , withArcColor (Just "Blocker") ((arc inhibitPlace run) {mode = Inhibit})
                    , withArcColor (Just "Result") (arc run done)
                    ]
                -- The reference's second token carries an arbitrary object;
                -- token data is JSON here, so it carries null.
                marking = markingFromList [(consumePlace, [tokD "Job" (Object [("secret", String "must-not-render")]), tokD "Job" Null])]
            source <- dot net (Just marking) defaultDotOptions {theme = theme'}
            source `shouldContainText` ("fillcolor=\"" <> marked <> "\", label=<")
            source `shouldNotContainText` ("<FONT COLOR=\"" <> marked <> "\"")
            source `shouldContainText` ">consume</FONT>"
            source `shouldContainText` ">2 tokens</FONT>"
            source `shouldNotContainText` "secret"
            source `shouldContainText` ">run</FONT>"
            source `shouldContainText` ">handler: handle · 2 guards · 2 timers</FONT>"
            source `shouldContainText` "tooltip=\"flow.run\\nhandler: handle\\nguards: cel: binding.ok; allowed\\ntimers: delay: 2; until: 9\""
            source `shouldContainText` ("color=\"" <> consumeColor <> "\", label=\"2× · Job · filter: cel: token.kind == \\\"ready\\\"\"")
            source `shouldContainText` ("color=\"" <> readColor <> "\", label=\"read · filter: visible\", style=\"dashed\"")
            source `shouldContainText` ("arrowhead=\"odot\", color=\"" <> inhibitColor <> "\", label=\"inhibit · Blocker\", style=\"dashed\"")
            source `shouldContainText` "label=\"Result\", style=\"solid\""
      )
      [ (Dark, "#1f6feb", "#8b949e", "#58a6ff", "#f85149")
      , (Light, "#ddf4ff", "#57606a", "#0969da", "#cf222e")
      ]

  -- test_to_dot_groups_top_level_scopes_with_opt_out
  it "groups top-level scopes, with an opt-out" $ do
    grouped <- dot goldenNet Nothing defaultDotOptions
    flat <- dot goldenNet Nothing defaultDotOptions {groupScopes = False}
    grouped `shouldContainText` "subgraph \"cluster_0\""
    flat `shouldNotContainText` "subgraph"

  -- test_to_dot_preserves_parallel_arcs_and_escapes_user_text
  it "preserves parallel arcs and escapes user text" $ do
    let inputPlace = np "scope.in\"put"
        at = np "scope.run"
        net =
          mustNet
            (netSpec [coloredPlace inputPlace "A \"<quoted>\" & \\ color"] [(transition at) {handler = Just (HandlerSymbol "handle \"this\"\\now")}] [arc inputPlace at, arc inputPlace at])
              { name = Just "net \"name\"\\literal"
              }
    source <- dot net Nothing defaultDotOptions
    source `shouldContainText` "label=\"net \\\"name\\\"\\\\literal\""
    source `shouldContainText` ">in&quot;put</FONT>"
    source `shouldContainText` ">A &quot;&lt;quoted&gt;&quot; &amp; \\ color</FONT>"
    source `shouldContainText` "handler: handle &quot;this&quot;\\now"
    source `shouldContainText` "tooltip=\"scope.in\\\"put -> scope.run\""
    T.count "\"p0\" -> \"t0\"" source `shouldBe` 2

  -- test_to_dot_normalizes_graphviz_text_without_losing_unicode_or_tabs
  it "normalizes Graphviz text without losing unicode or tabs" $ do
    let inputPlace = np "scope.café\tinput"
        at = np "scope.run"
        net = netOf [coloredPlace inputPlace "line one\r\nline two"] [transition at] [arc inputPlace at]
    source <- dot net Nothing defaultDotOptions
    source `shouldContainText` ">café\tinput</FONT>"
    source `shouldContainText` "line one<BR ALIGN=\"CENTER\"/>line two</FONT>"
    source `shouldNotContainText` "\\t"

  -- test_to_dot_marks_sources_and_keeps_anonymous_declarations_in_tooltips
  it "marks sources and keeps anonymous declarations in tooltips" $ do
    projectOpen <- expectRight (anonymousNamed "project_open")
    let sourceTransition = np "ingress.open"
        target = np "ingress.opened"
        net = netOf [place target] [(transition sourceTransition) {handler = Just (HandlerAnonymous projectOpen)}] [arc sourceTransition target]
    source <- dot net Nothing defaultDotOptions
    source `shouldContainText` ">source · handler: project_open</FONT>"
    source `shouldNotContainText` ">anonymous<"
    source `shouldContainText` "penwidth=\"2\""
    source `shouldContainText` "style=\"rounded,filled,dashed\""
    source `shouldContainText` "tooltip=\"ingress.open\\nsource transition\\nhandler: project_open (anonymous declaration)\""

  -- test_to_dot_rejects_nul_graphviz_text
  it "rejects NUL Graphviz text" $
    toDot (netOf [place (np "bad\0place")] [] []) Nothing defaultDotOptions
      `shouldFailWith` "Graphviz text cannot contain a NUL character"

  -- enforced by types: test_to_dot_rejects_unknown_presentation_arguments
  -- (Theme and Direction are closed)
  -- enforced by types: test_to_dot_requires_canonical_net

  describe "render" $ do
    -- test_render_writes_dot_without_invoking_graphviz (an empty search path
    -- proves Graphviz is never looked up)
    it "writes DOT without invoking Graphviz" $
      withScratch $ \dir -> do
        let target = dir </> "net.dot"
        result <- withSearchPath (dir </> "nothing-here") (render goldenNet target Nothing defaultDotOptions)
        result `shouldBe` Right target
        written <- TE.decodeUtf8 <$> BS.readFile target
        dot goldenNet Nothing defaultDotOptions `shouldReturn` written

    -- test_render_rejects_unsupported_suffix
    it "rejects an unsupported suffix" $
      withScratch $ \dir ->
        render goldenNet (dir </> "net.jpg") Nothing defaultDotOptions
          `shouldReturn` Left "unsupported Graphviz output suffix '.jpg'; expected .dot, .svg, .png, or .pdf"

    -- test_render_reports_missing_graphviz
    it "reports missing Graphviz" $
      withScratch $ \dir ->
        withSearchPath dir (render goldenNet (dir </> "net.svg") Nothing defaultDotOptions)
          `shouldReturn` Left "Graphviz 'dot' executable was not found; install Graphviz or render to a .dot file"

    -- test_render_reports_graphviz_failure
    it "reports a Graphviz failure with its diagnostic" $
      withScratch $ \dir -> do
        _ <- fakeDot dir "#!/bin/sh\n/bin/cat > /dev/null\necho 'syntax exploded' >&2\nexit 1\n"
        withSearchPath dir (render goldenNet (dir </> "net.pdf") Nothing defaultDotOptions)
          `shouldReturn` Left "Graphviz 'dot' failed with exit code 1: syntax exploded"

    -- test_render_infers_each_graphviz_output_format (parametrized)
    describe "infers each Graphviz output format" $
      mapM_
        ( \(suffix, formatName) ->
            it ("for " <> suffix) $
              withScratch $ \dir -> do
                let target = dir </> ("net" <> suffix)
                    record = dir </> "record"
                    argsFile = record </> "args"
                    stdinFile = record </> "stdin"
                createDirectory record
                executable <-
                  fakeDot dir (concat ["#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\" > '", argsFile, "'\n/bin/cat > '", stdinFile, "'\n"])
                withSearchPath dir (render goldenNet target Nothing defaultDotOptions) `shouldReturn` Right target
                arguments <- lines <$> readFile argsFile
                arguments `shouldBe` [executable, "-T" <> formatName, "-o", target]
                input <- TE.decodeUtf8 <$> BS.readFile stdinFile
                dot goldenNet Nothing defaultDotOptions `shouldReturn` input
        )
        [(".svg", "svg"), (".png", "png"), (".pdf", "pdf")]

    -- test_render_reports_graphviz_start_failure (an executable whose
    -- interpreter does not exist cannot be started)
    it "reports a Graphviz start failure" $
      withScratch $ \dir -> do
        _ <- fakeDot dir "#!/nonexistent/interpreter\n"
        result <- withSearchPath dir (render goldenNet (dir </> "net.png") Nothing defaultDotOptions)
        either id (T.pack . ("unexpected success: " <>)) result `shouldSatisfy` T.isPrefixOf "Graphviz 'dot' could not be started: "

    -- test_render_produces_real_svg_with_theme_palette (parametrized; needs a
    -- local Graphviz)
    describe "produces real SVG with the theme palette" $
      mapM_
        ( \(theme', background, cluster', primary', secondary', placeColor') ->
            it ("for " <> show theme') $ do
              graphviz <- findExecutable "dot"
              case graphviz of
                Nothing -> expectationFailure "Graphviz 'dot' is not on PATH: this example renders with the real Graphviz"
                Just _ ->
                  withScratch $ \dir -> do
                    target <- render goldenNet (dir </> "net.svg") Nothing defaultDotOptions {theme = theme'} >>= expectRight
                    svg <- TE.decodeUtf8 <$> BS.readFile target
                    svg `shouldContainText` "<svg"
                    svg `shouldContainText` ("fill=\"" <> background <> "\"")
                    svg `shouldContainText` ("stroke=\"" <> placeColor' <> "\"")
                    let (_, clusterOnwards) = T.breakOn "class=\"cluster\"" svg
                        (_, polygon) = T.breakOn "<polygon" clusterOnwards
                    lookup "fill" (attributesOf (T.takeWhile (/= '>') polygon)) `shouldBe` Just cluster'
                    let texts = textElements svg
                    case ([a | (a, "input") <- texts], [a | (a, "Work") <- texts, lookup "font-size" a == Just "9.00"]) of
                      (primaryName : _, secondaryMetadata : _) -> do
                        lookup "font-weight" primaryName `shouldBe` Just "bold"
                        lookup "font-size" primaryName `shouldBe` Just "14.00"
                        lookup "fill" primaryName `shouldBe` Just primary'
                        lookup "font-weight" secondaryMetadata `shouldBe` Nothing
                        lookup "fill" secondaryMetadata `shouldBe` Just secondary'
                      other -> expectationFailure ("text elements not found: " <> show other)
        )
        [ (Dark, "#0d1117", "#161b22", "#e6edf3", "#8b949e", "#58a6ff")
        , (Light, "#ffffff", "#f6f8fa", "#1f2328", "#59636e", "#0969da")
        ]

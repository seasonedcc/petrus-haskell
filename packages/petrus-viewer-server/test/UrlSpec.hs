-- | WHATWG URL resolution, GitHub normalization, decodeURIComponent, and
-- the URL cache (port of tests/urlCache.test.mjs).
module UrlSpec (spec) where

import Control.Exception (finally)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Viewer.Json
import Petrus.Viewer.Url
import Petrus.Viewer.UrlCache
import System.Directory (doesFileExist, removeDirectoryRecursive)
import Test.Hspec
import Test.QuickCheck
import TestSupport (fixturePath)

resolve :: Text -> Text -> Either Text Text
resolve ref base = maybe (Left "Invalid URL") (Right . serializeUrl) (resolveUrl ref base)

parse :: Text -> Either Text Text
parse u = maybe (Left "Invalid URL") (Right . serializeUrl) (parseUrl u)

-- | Path-like text: dot segments, empty segments, plain names, and now and
-- then a character with a special role in URLs.
newtype PathText = PathText Text
  deriving stock (Show)

instance Arbitrary PathText where
  arbitrary =
    PathText . T.intercalate "/"
      <$> listOf
        ( frequency
            [ (3, elements [".", "..", "", "a", "b.json", "x-y_z~", "$&'()*+,;=@!"])
            , (1, T.pack <$> listOf1 (elements "aZ09.-_~"))
            , (1, T.pack <$> listOf1 (elements "a.%2e%2E:|\\?# \t\233/C"))
            ]
        )

spec :: Spec
spec = do
  describe "new URL(ref, base).href" $ do
    it "matches Node on a recorded corpus of generated refs" $ do
      raw <- B.readFile (fixturePath "url-whatwg-node.json")
      cases <- case parseJs raw of
        Right (JsArr cs) -> pure cs
        _ -> fail "bad fixture"
      let expected v = case asObject v of
            Just o
              | Just (JsStr s) <- lookupKey "ok" o -> Just (Right (jsStringText s))
              | Just (JsStr s) <- lookupKey "error" o -> Just (Left (jsStringText s))
            _ -> Nothing
          mismatches =
            [ (ref, base, got, want)
            | JsArr [JsStr r, JsStr b, e] <- cases
            , Just want <- [expected e]
            , let ref = jsStringText r
            , let base = jsStringText b
            , let got = resolve ref base
            , got /= want
            ]
      length cases `shouldSatisfy` (> 2000)
      take 5 mismatches `shouldBe` []

    it "resolves file paths on the fast path exactly like the state machine" $
      property $ \(PathText ref) (PathText base) ->
        let full = "file:///" <> base
         in classify (resolveUrl ref full /= Nothing && T.all (`notElem` ("%:\\?# |\233" :: String)) (ref <> base)) "fast path" $
              (resolveUrl ref full === resolveUrlSpec ref full)
                .&&. (resolveUrl ref ("file://" <> base) === resolveUrlSpec ref ("file://" <> base))

    it "parses hosts: IPv4 forms, IPv6 compression, IDNA, opaque hosts" $ do
      parse "http://0x7f.1/" `shouldBe` Right "http://127.0.0.1/"
      parse "http://1.2.3.4.5/" `shouldBe` Left "Invalid URL"
      parse "http://foo.09/" `shouldBe` Left "Invalid URL"
      parse "http://[1:0:0:0:0:0:0:1]/" `shouldBe` Right "http://[1::1]/"
      parse "http://[::ffff:1.2.3.4]/" `shouldBe` Right "http://[::ffff:102:304]/"
      parse "http://\xc9X.com/" `shouldBe` Right "http://xn--x-9fa.com/"
      parse "http://\xdf.de/" `shouldBe` Right "http://xn--zca.de/"
      parse "http://a%41.com/" `shouldBe` Right "http://aa.com/"
      parse "foo://Ex%41mple/" `shouldBe` Right "foo://Ex%41mple/"
      parse "foo://ex ample/" `shouldBe` Left "Invalid URL"

    it "keeps Windows drive letters in file URLs" $ do
      parse "file://C:/x" `shouldBe` Right "file:///C:/x"
      parse "file://host/C|/x/../.." `shouldBe` Right "file://host/C:/"
      resolve "/abs/n.json" "file:///C:/nets/x.json" `shouldBe` Right "file:///C:/abs/n.json"
      resolve "\\" "file:///C:/nets/x.json" `shouldBe` Right "file:///C:/"

    it "resolves dot segments (with Node's empty non-special path quirk)" $ do
      resolve "../B.json" "file:///a/sub/A.json" `shouldBe` Right "file:///a/B.json"
      resolve "%2e%2E/x" "http://h/a/b" `shouldBe` Right "http://h/x"
      parse "foo://host/a/.." `shouldBe` Right "foo://host/"
      parse "foo://host/.." `shouldBe` Right "foo://host"
      parse "foo:/.//p" `shouldBe` Right "foo:/.//p"

    it "percent-encodes per component" $ do
      parse "http://a/^'x?'^#^'" `shouldBe` Right "http://a/^'x?%27^#^'"
      parse "foo://a/^'x?'^#^'" `shouldBe` Right "foo://a/^'x?'^#^'"
      parse "mailto:a b ?x" `shouldBe` Right "mailto:a b ?x"

  describe "normalizeGitHubUrl" $ do
    it "rewrites blob URLs to raw content" $
      normalizeGitHubUrl "https://github.com/org/repo/blob/main/path/to/net.json"
        `shouldBe` "https://raw.githubusercontent.com/org/repo/main/path/to/net.json"
    it "leaves other URLs alone" $ do
      normalizeGitHubUrl "https://github.com/org/repo/tree/main/x.json" `shouldBe` "https://github.com/org/repo/tree/main/x.json"
      normalizeGitHubUrl "https://github.com/a/b/blob/" `shouldBe` "https://github.com/a/b/blob/"
      normalizeGitHubUrl "https://github.com/a/b/blob/c\nd" `shouldBe` "https://github.com/a/b/blob/c\nd"

  describe "decodeURIComponent" $ do
    it "decodes UTF-8 sequences" $ decodeURIComponent "a%20b%C3%A9%F0%9F%98%80+" `shouldBe` Right "a b\xe9\x1F600+"
    it "throws URIError on malformed input" $ do
      decodeURIComponent "%E9" `shouldBe` Left "URI malformed"
      decodeURIComponent "%" `shouldBe` Left "URI malformed"
      decodeURIComponent "%ED%A0%80" `shouldBe` Left "URI malformed"

  describe "urlCache (tests/urlCache.test.mjs)" $ do
    it "slugifyUrl: converts raw.githubusercontent.com URL to slug" $
      slugifyUrl "https://raw.githubusercontent.com/org/repo/abc123/path/to/file.json" `shouldBe` Right (Just "org-repo-abc123")
    it "slugifyUrl: handles branch names with slashes" $
      slugifyUrl "https://raw.githubusercontent.com/org/repo/feature/branch/path/to/file.json" `shouldBe` Right (Just "org-repo-feature")
    it "slugifyUrl: handles non-GitHub HTTPS URLs" $
      slugifyUrl "https://example.com/some/path/file.json" `shouldBe` Right (Just "example.com-some-path")
    it "slugifyUrl: returns null for file:// URLs" $
      slugifyUrl "file:///path/to/file.json" `shouldBe` Right Nothing
    it "slugifyUrl: throws on invalid URLs" $
      slugifyUrl "not a url" `shouldBe` Left "Invalid URL"
    it "getCacheDir: returns path under ~/Documents/Petrus/" $ do
      dir <- getCacheDir "org-repo-abc123"
      dir `shouldSatisfy` T.isSuffixOf "/Documents/Petrus/org-repo-abc123" . T.pack
      take 1 dir `shouldBe` "/"
    it "cacheRelativePath: extracts path after org/repo/ref for GitHub" $
      cacheRelativePath "https://raw.githubusercontent.com/org/repo/abc123/path/to/file.json" `shouldBe` Right "path/to/file.json"
    it "cacheRelativePath: uses full path for non-GitHub" $
      cacheRelativePath "https://example.com/some/path/file.json" `shouldBe` Right "some/path/file.json"
    it "cacheFile: writes content to disk and returns path" $ do
      let slug = "petrus-viewer-server-test-cache"
      dir <- getCacheDir slug
      flip finally (removeDirectoryRecursive dir) $ do
        path <- cacheFile slug "sub/file.json" "{\"net\": \"cached\"}"
        doesFileExist path `shouldReturn` True
        B.readFile path `shouldReturn` "{\"net\": \"cached\"}"

# hamsterdan-github divergences

These are the intentional or accepted differences from `upstream/hamsterdan`
(`src/hamsterdan/github_app`) and the libraries under it (githubkit 0.16.0,
httpx 0.28.1, hishel 1.3.0, PyJWT 2.13.0). **No wire format diverges.** The
differential corpora compare these byte for byte with the pinned Python (see
[PARITY.md](PARITY.md)):

- every request line, ordered header list and body;
- the App JWT and installation-token requests;
- every stored inbox and routing row;
- every observation's JSON.

## API shape

1. **Capabilities are records of functions.**
   - Python's `Transport`, `BinaryTransport` and `GraphQLTransport` are
     structural `Protocol`s. Here they are records (`Transport { request,
     pages }`, …) in `Hamsterdan.GitHub.Models`.
   - Tests build fakes as record values, not subclasses. The upstream tests
     that subclass `FakeTransport` pass an override function instead
     (`test/GitHubSpec.hs`).
2. **The network is an `Exchange` in `ClientOptions`**, not an
   `httpx.BaseTransport` passed down through GitHubKit.
   - The `Exchange` sees the request exactly as httpx would put it on the
     wire, and hands back the raw status, header bytes and a chunk reader.
   - Everything above it is the same code in tests and production: header
     decoding, `Content-Encoding`, the HTTP cache, auth and bounds.
3. **No `repr`.**
   - `test_transport_repr_does_not_claim_or_expose_credentials` checks the
     Python `repr` of `GitHubKitTransport`. No Haskell value has a `Show`
     instance that could print a credential.
   - `Secret` (configuration) has a redacting `Show`.
   - `GitHubClient`, `AppClients` and `Transport` have no `Show` instance at
     all, so the test has nothing to port.
4. **Exceptions are typed.** Each one stands for a Python exception class:

   | Haskell | Python |
   | --- | --- |
   | `GitHubBoundaryError` | `GitHubBoundaryError` (and `GitHubObjectWriteError`, as `kind`) |
   | `InvalidRequest` | `ValueError` raised for bad caller input |
   | `PublicationCollision` | `ValueError("... different payload")` |
   | `PublicationRejected` | `ValueError("GitHub rejected ...")` |
   | `RerunRefused` | `RerunRefusedError` |
   | `ContractRefused` | `RuntimeError` (startup and contract refusals) |
   | `ConfigurationError` | `ConfigurationError` |
   | `WebhookRejected` | the inbox's HTTP 400 refusals |

   Where the reference would let a CPython exception escape (a `KeyError`,
   `TypeError`, `AttributeError` or `ValueError` from malformed provider
   data), the port throws `PythonFault` carrying that class name. The class is
   compared with the corpus; the message is not (see 12).
5. **Effect hooks are plain functions.** The fence, the fault hook and
   `retry_delay` are `Fence`, `EffectFault` and `Double -> IO ()`. A fence or
   hook refuses by throwing, as in Python.

## Inputs CPython can represent and `Text` cannot

6. **Lone surrogates in provider JSON.**
   - CPython decodes JSON with `surrogatepass`, so a body containing `"\ud800"`
     yields a `str` holding a lone surrogate. `Data.Text` cannot hold one.
   - `Hamsterdan.GitHub.Python.loadsBytes` reports such documents as
     malformed JSON. A webhook payload containing a lone-surrogate escape is
     therefore refused by the inbox (Python would accept and store it, still
     escaped, in the observation), and the transport treats such a response
     body as malformed JSON (`response_json`).
   - GitHub does not emit lone surrogates. The corpora contain none.
   - The rest of the path already behaves as CPython does on such a string,
     so this entry closes with petrus-json's lone-surrogate support (audit
     IMP-2: a WTF-8 `Text` under `KeepLoneSurrogates`). Every provider
     document is parsed with `Hamsterdan.GitHub.Python.providerLoads`, the
     one place to switch. After that:
     - a lone surrogate in an `issue_comment` body is refused with 400, as
       the reference's `len(text.encode())` raises `UnicodeEncodeError`
       (a `ValueError`): `Hamsterdan.PyText.utf8EncodeError`;
     - anywhere else the delivery is accepted with 202, and the stored
       observation is written with `ensure_ascii`, which escapes it again
       as `\ud800`, the reference's bytes. An installation lifecycle never
       binds one to SQLite: the registry admits ASCII repository names
       only, on both sides. Any bind that did would raise
       `UnicodeEncodeError` with CPython's message, as CPython's `sqlite3`
       does (`Hamsterdan.Sqlite`).
     `PyTextSpec` checks both texts against CPython 3.14.6 on WTF-8
     strings.
7. **Very deep JSON nesting.**
   - CPython raises `RecursionError` once its C stack guard trips. `petrus-json`
     has no depth limit and parses such documents.
   - The corpora include 5000-level arrays in responses and 200-level arrays in
     webhook payloads. Both sides parse those identically.
   - Response bodies are capped at 1 MiB, so the difference only shows on a
     hostile provider.

## Partial reimplementations of library validation

8. **GitHubKit's `InstallationToken` model is validated partially.**
   - pydantic validates the whole token-response model. The port checks the
     members Hamsterdan depends on:
     - `token` and `expires_at` are strings, and `expires_at` parses with
       GitHubKit's `strptime` format;
     - each optional member, if present, is `null` or of the declared JSON
       type;
     - `repositories` is a list of objects.
   - The members *inside* each repository object are not validated. A token
     response whose repository objects are malformed (a non-integer `id`, a
     missing `full_name`, …) is accepted here and refused by pydantic.
   - The HTTP corpus covers `repositories` values of `[]`, a string, `null`
     and `[5]`, and both sides agree on every one.
9. **`urllib.parse.urlsplit`'s NFKC netloc check is not reproduced.**
   - CPython refuses a non-ASCII netloc whose NFKC normalization introduces
     `/`, `?`, `#`, `@` or `:`. The port does not normalize.
   - The transport refuses every origin other than `https://api.github.com`
     anyway, so such a URL is refused either way. Only the error text differs
     (`ValueError` vs. the origin refusal).
10. **httpx's IDNA host validation is not reproduced.**
    - `httpx.URL` encodes non-ASCII hosts with IDNA and raises `InvalidURL` for
      invalid labels. `Hamsterdan.GitHub.Url.httpxUrl` admits them unchecked.
    - Only redirect `Location` headers reach this code. The bounded transport
      refuses every redirect, and every foreign host, regardless.
11. **`str.isdigit` is approximated in the hishel date parser.**
    - `pyIsDigit` is used by `Cache.parseDate`, the port of hishel's
      `parse_date` over `email.utils.parsedate_tz`. It accepts Unicode
      decimal digits plus the superscript, subscript and circled digits.
    - CPython's `str.isdigit` also accepts a few rarer `Numeric_Type=Digit`
      characters (for example Ethiopic and dingbat digits). A `Date` or
      `Last-Modified` header containing one could parse differently.
    - Header values are decoded from bytes as httpx does, and GitHub sends
      ASCII dates.

## Testing scope

12. **The messages of uncaught CPython exceptions are not compared.**
    - The corpora record the class of a `KeyError`, `TypeError`, …
      (`PythonFault`) and compare it.
    - The message is CPython's own text, such as `'NoneType' object is not
      subscriptable`. Nothing downstream reads it.
    - Every message Hamsterdan writes itself is compared exactly:
      `GitHubBoundaryError` messages, failure classes, provider status and
      detail atoms, refusal texts, and configuration errors.
    - PyJWT's `InvalidKeyError` message is an example of a CPython message that
      is not compared. For a parseable non-RSA key (EC, Ed25519) PyJWT says
      "Invalid Key type for RSAAlgorithm"; the port says "Could not parse the
      provided public key.", PyJWT's text for unparseable keys. The class
      matches.
13. **The production exchange is differentially tested over plain HTTP only.**
    - Both sides' corpora run over a mock network: `httpx.MockTransport` and a
      scripted `Exchange`. So h11's wire-level checks (for example, refusing
      CR or LF in a header value) and http-client's are not compared.
    - The production code path (`exchangeAt`, which `realExchange` is at
      `https://api.github.com`) is compared on the wire by hamsterdan-host:
      `InteropSpec` and `CliSpec` point both hosts at one recording fake
      GitHub (`newPlainExchangeAt`, and an httpx transport that rewrites the
      origin). The request line, the headers in order, and the body bytes
      match. That comparison found http-client's default
      `Accept-Encoding: gzip`, which httpx does not send. The exchange now
      suppresses it. TLS itself is not compared.
    - The headers the stack sends are fixed strings, the App JWT and the
      installation token. Non-ASCII values are refused before sending, as
      httpx refuses them.
    - `test_app_foundation.py`'s client tests also use a mock transport, and
      are ported the same way.

## Runtime environment

14. **No environment-driven proxies or CA bundles.**
    - httpx's `trust_env=True` honors `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`
      and `SSL_CERT_FILE`, and otherwise verifies TLS against certifi's bundle.
    - `newRealExchange` connects directly (`managerSetProxy noProxy`) and
      verifies against the system trust store (http-client-tls).
    - Hamsterdan's container image (`deployment/Containerfile`) sets none of
      these variables.
15. **No concurrency throttler.**
    - GitHubKit wraps each request in a `LocalThrottler(100)` semaphore per
      client, which bounds concurrent requests to 100.
    - The Haskell client has no such bound. A caller that issues more than
      100 concurrent requests through one client must bound them itself.
      Within this package, every operation issues its requests one at a
      time.

## Implementation notes (no observable difference)

- **Prepared statements are cached per connection.** This matches CPython
  `sqlite3`'s statement cache, so SQL, transactions and stored bytes are
  unchanged. See [bench/RESULTS.md](bench/RESULTS.md).
- **The webhook HMAC key state is computed once per custody.** The digest and
  the constant-time comparison are unchanged.
- **One HTTP cache and one token cache per `AppClients`.** This is the same
  scope as the reference: `GitHubAppClients` gives every client it builds one
  `MemCacheStrategy`, and that strategy holds both the token cache and the
  hishel storage.

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
   data), the port throws hamsterdan-contracts' `PythonException` (petrus-json's
   class name and `args`, the value every Hamsterdan port raises). The class is
   compared with the corpus; the message is not (see 12).
5. **Effect hooks are plain functions.** The fence, the fault hook and
   `retry_delay` are `Fence`, `EffectFault` and `Double -> IO ()`. A fence or
   hook refuses by throwing, as in Python.

## Inputs CPython can represent and `Text` cannot

6. **Lone surrogates in provider JSON: resolved, no longer a difference.**
   - CPython's `json.loads` keeps a lone surrogate escape (`"\ud800"`) in a
     `str`. `Hamsterdan.Python.loads` and `loadsBytes` (petrus-json's
     `loadsText` and `loadsBytes`), which parse every provider document
     (webhook payloads, the observations the inbox stores, and response
     bodies), keep it too, as a WTF-8 `Text`.
   - A lone surrogate in an `issue_comment` body is refused with 400, as the
     reference's `len(text.encode())` raises `UnicodeEncodeError` (a
     `ValueError`): `Hamsterdan.Python.Text.utf8EncodeError`.
   - Anywhere else the delivery is accepted with 202, and the stored
     observation is written with `ensure_ascii`, which escapes it again as
     `\ud800`, the reference's bytes. `pending` reads it back with the same
     options. An installation lifecycle never binds one to SQLite: the
     registry admits ASCII repository names only, on both sides. Any bind
     that did would raise `UnicodeEncodeError` with CPython's message, as
     CPython's `sqlite3` does (`Hamsterdan.Sqlite`).
   - Checked against the reference: six fixed sequences at the end of
     `webhooks.jsonl` (surrogates in the action, a member key, the actor
     login and association, a comment body, a review comment, and the
     repository names of installation lifecycles, with and without a
     registry) and the uvicorn surface in hamsterdan-host's `ApiSpec`
     (202 and 400). `PyTextSpec` checks the `UnicodeEncodeError` texts
     against CPython 3.14.6 on WTF-8 strings.
   - Response bodies are parsed the same way. GitHub does not emit lone
     surrogates, and the effects and HTTP corpora contain none, so the
     response path is not differentially tested on them.
7. **Very deep JSON nesting.**
   - CPython's limit depends on the C stack. On an 8 MiB main-thread stack,
     CPython 3.14 parses and re-encodes a webhook whose `action` nests
     100,001 levels deep. At 520,000 levels (still under the 1 MiB body cap)
     `json.loads` raises `RecursionError`, which the reference does not catch
     (HTTP 500).
   - `petrus-json` refuses documents nested past a fixed 100,000 levels
     (`defaultNestingLimit`). A webhook nested deeper is a malformed envelope
     here (HTTP 400), where the reference may accept it or answer 500.
   - Its encoder has the same limit, and no observation member sits deeper
     than it did in the body, so a parsed observation always encodes.
     `encodeObservation` still returns the refusal, and `receive` raises it as
     the reference's `RecursionError` rather than failing with an `ErrorCall`.
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
9. **`urllib.parse.urlsplit`'s NFKC netloc check: resolved, no longer a
   difference.**
   - CPython refuses a non-ASCII netloc whose NFKC normalization introduces
     `/`, `?`, `#`, `@` or `:`. The transport's `urlsplit` is now
     hamsterdan-contracts' `Hamsterdan.Python.Url`, which the Pi prompt
     envelope already used: it makes the check (from the Unicode 16.0
     table), and quotes the host in the bracketed-host `ValueError` and the
     `port` error as CPython does.
   - `hamsterdan-contracts`' `PythonSpec` checks `urlsplit`, `hostname`,
     `port`, `username`, `password` and `urlunsplit` against the pinned
     interpreter.
10. **httpx's IDNA host validation is not reproduced.**
    - `httpx.URL` encodes non-ASCII hosts with IDNA and raises `InvalidURL` for
      invalid labels. `Hamsterdan.GitHub.Url.httpxUrl` admits them unchecked.
    - Only redirect `Location` headers reach this code. The bounded transport
      refuses every redirect, and every foreign host, regardless.
11. **`str.isdigit` in the hishel date parser: resolved, no longer a
    difference.**
    - `Cache.parseDate` (hishel's `parse_date` over
      `email.utils.parsedate_tz`) used an approximate `pyIsDigit` that
      missed the rarer `Numeric_Type=Digit` characters (Ethiopic, dingbat
      digits), and GHC's Unicode 15.1 `toLower`; a year such as `፩` with a
      valid year in the zone slot parsed where the reference returns `None`.
    - It now uses `Hamsterdan.Python.Text.isDigit` and `lower`, which are
      petrus-json's CPython 3.14 (Unicode 16.0) tables, checked on every code
      point against the pinned interpreter.
    - `test/corpus/dates.jsonl` (`scripts/gen_date_corpus.py`, 1 520 header
      values through the reference's `parse_date`) pins it in
      `HttpCorpusSpec`.

## Testing scope

12. **The messages of uncaught CPython exceptions are not compared.**
    - The corpora record the class of a `KeyError`, `TypeError`, …
      (`PythonException`) and compare it.
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

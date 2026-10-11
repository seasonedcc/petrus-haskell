/**
 * Differential tests: the Haskell ports against the Node code they replace,
 * on generated inputs (fixed seed, so failures reproduce).
 *
 *   - relay output bytes: `JSON.stringify(JSON.parse(raw))` plus the id stamp,
 *     for the agent relay and the collaboration relay;
 *   - `JSON.parse` error messages (surfaced by resolve-ref and the MCP
 *     open-file tool);
 *   - WHATWG URL resolution (`new URL(ref, base).href`, used by resolve-ref);
 *   - the upstream server/urlCache.mjs functions.
 */

import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { callOracle } from "../shims/haskell-url-cache.mjs";

const VIEWER = process.env.PETRUS_HS_VIEWER_DIR;
const upstreamUrlCache = await import(path.join(VIEWER, "server/urlCache.mjs"));

let seed = 0x5eed1234;
function rand() {
  // mulberry32
  seed |= 0;
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (xs) => xs[Math.floor(rand() * xs.length)];
const int = (n) => Math.floor(rand() * n);

const STRING_PIECES = [
  "a", "petrus", "é", "😀", "\\u00e9", "\\ud83d\\ude00", "\\ud800", "\\udfff", "\\uDBFF", "\\n", "\\t", "\\\"",
  "\\\\", "\\/", "\\b", "\\f", "\\r", "\\u0000", "\\u001f", "\\u007f", "\u2028", "\u2029", "\\u2028", " ", "ﬀ", "𝄞",
  "\\u0041", "<", "&", "'",
];
function genString() {
  let s = "";
  for (let i = int(5); i > 0; i--) s += pick(STRING_PIECES);
  return `"${s}"`;
}
const NUMBERS = [
  "0", "-0", "1", "-1", "1.5", "0.1", "1e21", "1e-7", "123456789012345678901234567890", "1E+2", "1e400", "-1e400",
  "5e-324", "2.2250738585072014e-308", "0.30000000000000004", "9007199254740993", "1.0", "100", "1e-6", "123e-20",
  "4.35", "0.000001", "0.0000001", "17976931348623157e292", "1.7976931348623157e309", "2e-323", "12.34e5", "-0.0",
];
const KEYS = ['"a"', '"b"', '"0"', '"1"', '"10"', '"01"', '"-1"', '"4294967294"', '"4294967295"', '"1.5"', '"clientId"', '"peerId"', '"targetClientId"', '"é"', '"\\u0030"', '""'];
const WS = ["", " ", "\n", "\t", "\r\n  "];

function genValue(depth) {
  const r = rand();
  if (depth <= 0 || r < 0.35) {
    return pick([() => pick(NUMBERS), genString, () => pick(["true", "false", "null"])])();
  }
  if (r < 0.65) {
    const items = [];
    for (let i = int(4); i > 0; i--) items.push(pick(WS) + genValue(depth - 1) + pick(WS));
    return `[${items.join(",")}]`;
  }
  const members = [];
  for (let i = int(5); i > 0; i--) members.push(`${pick(WS)}${pick(KEYS)}${pick(WS)}:${pick(WS)}${genValue(depth - 1)}`);
  return `{${members.join(",")}}`;
}

function genMessage() {
  const v = genValue(4);
  return rand() < 0.8 && v.startsWith("{") ? v : rand() < 0.5 ? `{"m":${v}}` : v;
}

// Inputs reach the backend as UTF-8 (WebSocket text frames, HTTP bodies,
// files), where lone surrogates cannot occur, so corruption that splits a
// surrogate pair is repaired the way a UTF-8 encoder would (U+FFFD).
function corrupt(s) {
  return corruptRaw(s).toWellFormed();
}

function corruptRaw(s) {
  const i = int(s.length + 1);
  const op = int(4);
  const junk = pick(["}", "]", ",", ":", "\"", "x", "-", "0", "\\", "\u0001", "é", " ", "{", "tru", "1e", "1.", "-a", "\\u12"]);
  if (op === 0) return s.slice(0, i);
  if (op === 1) return s.slice(0, i) + junk + s.slice(i);
  if (op === 2) return s.slice(0, i) + s.slice(i + 1);
  return junk + s;
}

function nodeRelay(kind, raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch { return null; }
  if (kind === "agent") {
    if (typeof msg !== "object" || msg === null || Array.isArray(msg)) return null;
    msg.clientId = "7";
  } else {
    if (typeof msg !== "object" || msg === null) return null; // Node throws here (strict mode)
    msg.peerId = "7";
  }
  return JSON.stringify(msg);
}

function nodeParse(raw) {
  try {
    return { ok: JSON.stringify(JSON.parse(raw)) };
  } catch (e) {
    // V8 can cut a surrogate pair when quoting the offending token or its
    // context; the message keeps the lone surrogate, and so does the port's.
    return { error: e.message };
  }
}

const N = 4000;

/** Compare all cases, then report every mismatch (up to 15) at once. */
function expectAll(cases) {
  const bad = cases.filter(([, actual, expected]) => !isDeepStrictEqual(actual, expected));
  const report = bad
    .slice(0, Number(process.env.DIFF_REPORT ?? 15))
    .map(([label, actual, expected]) => `${label}\n    haskell: ${JSON.stringify(actual)}\n    node:    ${JSON.stringify(expected)}`)
    .join("\n");
  assert.equal(bad.length, 0, `${bad.length} of ${cases.length} differ:\n${report}`);
}

test(`relay output is byte-identical (${N} generated messages, both relays)`, () => {
  const inputs = Array.from({ length: N }, genMessage);
  const results = callOracle(inputs.flatMap((s) => [["relayAgent", s], ["relayCollab", s]]));
  expectAll(
    inputs.flatMap((s, i) => [
      [`agent relay ${JSON.stringify(s)}`, results[2 * i], { ok: nodeRelay("agent", s) }],
      [`collab relay ${JSON.stringify(s)}`, results[2 * i + 1], { ok: nodeRelay("collab", s) }],
    ]),
  );
});

test(`JSON.parse results and error messages match V8 (${N} corrupted documents)`, () => {
  const inputs = Array.from({ length: N }, () => corrupt(genMessage()));
  inputs.push("", " ", "NaN", "Infinity", "undefined", "[object Object]", "01", "-", "1.", "1e", "\"\\x\"", "\"\\u12G4\"", "\"abc", "[1,]", "{\"a\":1,}", "{,}", "tru", "nul", "{\"a\" 1}", "[1 2]", "\u00a0{}");
  const results = callOracle(inputs.map((s) => ["jsonRoundTrip", s]));
  expectAll(inputs.map((s, i) => [`JSON.parse(${JSON.stringify(s)})`, results[i], nodeParse(s)]));
});

const URL_BASES = [
  "file:///Users/me/nets/main.json",
  "file:///tmp/a%20b/c.json",
  "https://raw.githubusercontent.com/org/repo/main/nets/root.json",
  "http://example.com:8080/x/y/z.json?q=1#h",
  "file:///C:/nets/x.json",
  "file://server/share/x.json",
  "foo://host/a/b",
  "mailto:someone",
];
const URL_PIECES = [
  "sub", "..", ".", "%2e", "%2E%2E", "a b", "é", "%41", "%zz", "x.json", "?", "#", "\\", "//", "~", "@", ":", "[", "|",
  "^", "{", "}", "'", "`", "C:", "c|", "0x7f.1", "1.2.3", "[::1]", "[1:0::ffff:1.2.3.4]", "[::", "user:pw@", ":8080",
  ":99999", "ÉX", "ß", "%C3%A9", "%FF", "localhost", "xn--9ca", "0", "09", "a.", "\t",
];
const URL_PREFIXES = ["", "", "", "/", "//", "///", "http:", "http://", "file:", "file://", "file:///", "foo:", "foo://", "https:\\\\"];
function genRef() {
  if (rand() < 0.1) return pick(["https://example.org/n.json", "//host/n.json", "/abs/n.json", "file:///etc/x.json", "mailto:x", "http://[::1]:80/a.json", "HTTP://EXAMPLE.com/A.json", "http://ex ample.com/"]);
  const parts = [];
  for (let i = 1 + int(4); i > 0; i--) parts.push(pick(URL_PIECES));
  return pick(URL_PREFIXES) + parts.join(pick(["/", "/", "", "\\", "."]));
}
// Node 22 (ada 2.9.2) resolves a ref that contains "#" against a base with
// an opaque path (e.g. "x#f" against "mailto:a" gives "mailto:a/x#f"); the
// URL standard, and the Haskell port, reject it. Such pairs are excluded
// (DIVERGENCES.md).
const adaOpaqueFragmentBug = (ref, base) =>
  /^[a-z][a-z0-9+.-]*:[^/]/i.test(base) && !base.startsWith("file:") && !/^[a-z][a-z0-9+.-]*:/i.test(ref) && ref.indexOf("#") > 0;

function nodeResolve(ref, base) {
  try { return { ok: new URL(ref, base).href }; } catch { return { error: "Invalid URL" }; }
}

test("URL resolution matches WHATWG URL (6000 generated refs)", () => {
  const cases = Array.from({ length: 6000 }, () => [genRef(), pick(URL_BASES)]).filter(([r, b]) => !adaOpaqueFragmentBug(r, b));
  const results = callOracle(cases.map(([r, b]) => ["resolveUrl", r, b]));
  expectAll(cases.map(([r, b], i) => [`new URL(${JSON.stringify(r)}, ${JSON.stringify(b)})`, results[i], nodeResolve(r, b)]));
});

test("urlCache functions match server/urlCache.mjs", () => {
  const urls = [
    "https://raw.githubusercontent.com/org/repo/abc123/path/to/file.json",
    "https://raw.githubusercontent.com/org/repo/main/file.json",
    "https://raw.githubusercontent.com/org/repo/main",
    "https://raw.githubusercontent.com/org",
    "https://example.com/some/path/file.json",
    "https://example.com/",
    "https://example.com",
    "http://Example.COM:8080/a%20b/c.json?x=1",
    "file:///path/to/file.json",
    "https://github.com/org/repo/blob/main/path/to/net.json",
    "https://github.com/org/repo/tree/main/x.json",
    "https://github.com/org/blob/main",
    "https://github.com/a/b/blob/",
    "https://github.com/a/b/blob/c\nd",
    "https://raw.githubusercontent.com//repo//x.json",
  ];
  const calls = urls.flatMap((u) => [["slugifyUrl", u], ["cacheRelativePath", u], ["normalizeGitHubUrl", u]]);
  const results = callOracle(calls);
  const expect = (fn, u) => {
    try { return { ok: upstreamUrlCache[fn](u) }; } catch (e) { return { error: e.message }; }
  };
  urls.forEach((u, i) => {
    assert.deepEqual(results[3 * i], expect("slugifyUrl", u), `slugifyUrl(${JSON.stringify(u)})`);
    assert.deepEqual(results[3 * i + 1], expect("cacheRelativePath", u), `cacheRelativePath(${JSON.stringify(u)})`);
    assert.deepEqual(results[3 * i + 2], expect("normalizeGitHubUrl", u), `normalizeGitHubUrl(${JSON.stringify(u)})`);
  });
});

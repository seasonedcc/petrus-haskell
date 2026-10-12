/**
 * HTTP wire differential for /__petrus/open-file and /__petrus/resolve-ref:
 * raw requests against `petrus` and against the upstream endpoint on bare
 * `node:http` (bench/node-baseline.mjs runs server/openFileEndpoint.mjs
 * unchanged), comparing what each connection receives: every response's
 * status code and reason, the headers the handler sets (in order, byte for
 * byte), the body, and whether the server closes the connection. The
 * framing is Warp's, not Node's (DIVERGENCES.md, "Response framing"): the
 * HTTP version of the status line and the Date, Connection, Keep-Alive and
 * Content-Length headers are left out of the comparison.
 *
 * Both servers see the same connections in the same order, so the pending
 * file each one holds agrees at every step. Each scenario is a list of
 * chunks written on one connection with a pause between them (so a request
 * split across chunks arrives in pieces).
 */

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const BIN = process.env.PETRUS_HS_BIN_DIR;
const VIEWER = process.env.PETRUS_HS_VIEWER_DIR;
const PACKAGE = process.env.PETRUS_HS_PACKAGE_DIR;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function waitPort(port) {
  for (let i = 0; i < 200; i++) {
    const ok = await new Promise((resolve) => {
      const s = net.connect(port, "127.0.0.1");
      s.once("connect", () => { s.destroy(); resolve(true); });
      s.once("error", () => resolve(false));
    });
    if (ok) return;
    await sleep(25);
  }
  throw new Error(`port ${port} never opened`);
}

async function startServer(cmd, args, cwd, env = {}) {
  const port = await freePort();
  const proc = spawn(cmd, args(port), { cwd, stdio: "ignore", env: { ...process.env, ...env } });
  const stop = () => new Promise((r) => { if (proc.exitCode !== null || proc.pid === undefined) r(); else { proc.once("exit", r); proc.kill("SIGTERM"); } });
  try {
    await Promise.race([waitPort(port), new Promise((_, reject) => proc.once("error", reject))]);
  } catch (e) {
    await stop();
    throw e;
  }
  return { port, stop };
}

/** Write the chunks on one connection; everything received until the
 * server closes or stays quiet. */
function exchange(port, chunks, { pause = 60, quiet = 250, readDelay = 0 } = {}) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, "127.0.0.1");
    // a slow reader: the server's socket buffer fills before anything is read
    if (readDelay) {
      sock.pause();
      setTimeout(() => sock.resume(), readDelay);
    }
    let raw = Buffer.alloc(0);
    let timer = null;
    const finish = (closed) => {
      clearTimeout(timer);
      sock.destroy();
      resolve({ responses: responses(raw.toString("latin1")), closed });
    };
    const arm = (wait = quiet) => { clearTimeout(timer); timer = setTimeout(() => finish(false), wait); };
    sock.on("data", (d) => { raw = Buffer.concat([raw, d]); arm(); });
    sock.on("end", () => finish(true));
    sock.on("error", (e) => (raw.length ? finish(true) : reject(e)));
    sock.on("connect", async () => {
      for (const c of chunks) {
        sock.write(c);
        await sleep(pause);
      }
      arm(readDelay + quiet);
    });
  });
}

// Headers that frame the message rather than carry the handler's answer.
const FRAMING = new Set(["date", "connection", "keep-alive", "content-length", "transfer-encoding"]);

/** The responses on one connection, without their framing: status code and
 * reason, the other headers in order, and the body (by Content-Length; to
 * the next status line or the end without one). */
function responses(text) {
  const out = [];
  let rest = text;
  while (rest.length) {
    const head = rest.indexOf("\r\n\r\n");
    if (head < 0) {
      out.push({ partial: rest });
      break;
    }
    const [statusLine, ...lines] = rest.slice(0, head).split("\r\n");
    const status = statusLine.replace(/^HTTP\/1\.[01] /, "");
    const fields = lines.map((l) => [l.slice(0, l.indexOf(":")), l.slice(l.indexOf(":") + 1).trim()]);
    const length = fields.find(([k]) => k.toLowerCase() === "content-length");
    rest = rest.slice(head + 4);
    let body;
    if (length) {
      body = rest.slice(0, Number(length[1]));
    } else if (/^(1\d\d|204|304) /.test(status)) {
      body = "";
    } else {
      const next = rest.search(/HTTP\/1\.[01] \d{3} /);
      body = next < 0 ? rest : rest.slice(0, next);
    }
    rest = rest.slice(body.length);
    out.push({ status, headers: fields.filter(([k]) => !FRAMING.has(k.toLowerCase())), body });
  }
  return out;
}

const post = (url, body, extra = "") =>
  `POST ${url} HTTP/1.1\r\nHost: x\r\n${extra}Content-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;
const get = (url, extra = "") => `GET ${url} HTTP/1.1\r\nHost: x\r\n${extra}\r\n`;
const OPEN = "/__petrus/open-file";
const RESOLVE = "/__petrus/resolve-ref";

test("open-file and resolve-ref answer with Node's bytes", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "petrus-http-wire-"));
  const net1 = path.join(dir, "B.json");
  const gone = path.join(dir, "gone.json");
  fs.copyFileSync(path.join(VIEWER, "examples/sample-net.json"), net1);
  const node = await startServer(process.execPath, (p) => [path.join(PACKAGE, "bench/node-baseline.mjs"), VIEWER, String(p)], dir);
  let hs;
  try {
    hs = await startServer(path.join(BIN, "petrus"), (p) => ["--no-open", "--strict-port", "--port", String(p)], dir, { PETRUS_RELAY_PERF: "0" });
  } catch (e) {
    await node.stop();
    fs.rmSync(dir, { recursive: true, force: true });
    throw e;
  }
  const pathBody = (p) => JSON.stringify({ path: p });
  const SCENARIOS = {
    "GET with nothing pending (204)": [get(OPEN)],
    "OPTIONS on both endpoints": [`OPTIONS ${OPEN} HTTP/1.1\r\nHost: x\r\n\r\n`, `OPTIONS ${RESOLVE} HTTP/1.1\r\nHost: x\r\n\r\n`],
    "POST then GET (200 with the file, then 204)": [post(OPEN, pathBody(net1)), get(OPEN), get(OPEN)],
    "POST refusals": [post(OPEN, '{"path":1}'), post(OPEN, "not json{{{"), post(OPEN, "null"), post(OPEN, pathBody("/nonexistent/file.json")), post(OPEN, "")],
    "other methods (405, HEAD without a body)": [`DELETE ${OPEN} HTTP/1.1\r\nHost: x\r\n\r\n`, `PUT ${OPEN} HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}`, `HEAD ${OPEN} HTTP/1.1\r\nHost: x\r\n\r\n`],
    "resolve-ref: a local file": [post(RESOLVE, JSON.stringify({ ref: "./B", basePath: `file://${dir}/A.json` }))],
    "resolve-ref: refusals": [
      post(RESOLVE, "nope"),
      post(RESOLVE, "null"),
      post(RESOLVE, '{"ref":"x"}'),
      post(RESOLVE, JSON.stringify({ ref: "./missing", basePath: `file://${dir}/A.json` })),
      post(RESOLVE, '{"ref":"./x","basePath":"ftp://h/A.json"}'),
      post(RESOLVE, '{"ref":1,"basePath":"file:///a"}'),
      post(RESOLVE, '{"ref":"x","basePath":"nope"}'),
      post(RESOLVE, JSON.stringify({ ref: "./%E0%A4%A", basePath: `file://${dir}/A.json` })),
      // V8 quotes the token and its context by UTF-16 units, cutting the
      // pair: the error body carries a lone surrogate escape.
      post(RESOLVE, "[\u{1F600}]"),
      post(RESOLVE, "[1,aaaaaaaaa\u{1F600}bbbbbbbbbbbbbbb"),
    ],
    "Connection: close": [get(OPEN, "Connection: close\r\n")],
    "lower-case field names and values": [`GET ${OPEN} HTTP/1.1\r\nhost: x\r\nconnection: CLOSE\r\n\r\n`],
    "HTTP/1.0 (Connection: close, no Content-Length)": [`POST ${OPEN} HTTP/1.0\r\nContent-Length: 10\r\n\r\n{"path":1}`],
    "a request split across packets": [`POST ${OPEN} HTTP/1.1\r\nHost: x\r\nContent-Le`, `ngth: 10\r\n\r\n{"pa`, `th":1}`],
    "Expect: 100-continue, body after the interim response": [`POST ${OPEN} HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n`, `{"path":1}`],
    "Expect: 100-continue, body at once": [`POST ${OPEN} HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n{"path":1}`],
    // Pipelined requests whose answers do not depend on when Node reads a
    // POST body: Node runs a pipelined request's handler as soon as its
    // head is parsed, and a POST body is delivered asynchronously, so a GET
    // pipelined after a POST may or may not see the file that POST set
    // (DIVERGENCES.md). Every answer here is the same either way.
    "pipelined requests": [get(OPEN) + `OPTIONS ${OPEN} HTTP/1.1\r\nHost: x\r\n\r\n` + post(OPEN, '{"path":1}') + get(OPEN) + post(RESOLVE, "null")],
    "a pipelined burst larger than the socket buffer, read slowly": {
      chunks: [Array.from({ length: 400 }, () => post(RESOLVE, JSON.stringify({ ref: "./B", basePath: `file://${dir}/A.json` }))).join("")],
      readDelay: 400,
    },
  };
  try {
    for (const [name, scenario] of Object.entries(SCENARIOS)) {
      await t.test(name, async () => {
        const { chunks, readDelay = 0 } = Array.isArray(scenario) ? { chunks: scenario } : scenario;
        const n = await exchange(node.port, chunks, { readDelay });
        const h = await exchange(hs.port, chunks, { readDelay });
        assert.ok(n.responses.length > 0, "node answered");
        assert.deepEqual(h.responses, n.responses);
        assert.equal(h.closed, n.closed, "closes the connection like Node");
      });
    }
    await t.test("HTTP/1.0 asking for keep-alive: the same answer; Warp keeps the connection", async () => {
      // Node frames a 1.0 response by closing the connection, whatever the
      // client asked; Warp sends Content-Length and keeps a 1.0 connection
      // that asks for keep-alive (DIVERGENCES.md, "Response framing")
      const chunks = [`GET ${OPEN} HTTP/1.0\r\nConnection: keep-alive\r\n\r\n`, `GET ${OPEN} HTTP/1.0\r\n\r\n`];
      const n = await exchange(node.port, chunks);
      const h = await exchange(hs.port, chunks);
      assert.equal(n.responses.length, 1);
      assert.ok(n.closed);
      assert.deepEqual(h.responses, [n.responses[0], n.responses[0]]);
      assert.ok(h.closed, "closed after the second request, which did not ask for keep-alive");
    });
    await t.test("a pending file that cannot be read (500, and it stays pending)", async () => {
      // the file exists when it is posted, then disappears before the GETs
      fs.writeFileSync(gone, "{}");
      const n0 = await exchange(node.port, [post(OPEN, pathBody(gone))]);
      const h0 = await exchange(hs.port, [post(OPEN, pathBody(gone))]);
      assert.deepEqual(h0.responses, n0.responses);
      fs.rmSync(gone);
      const n = await exchange(node.port, [get(OPEN), get(OPEN)]);
      const h = await exchange(hs.port, [get(OPEN), get(OPEN)]);
      assert.deepEqual(n.responses.map((r) => r.status), ["500 Internal Server Error", "500 Internal Server Error"]);
      assert.deepEqual(h.responses, n.responses);
      // once the file is back, the next GET reads it
      fs.writeFileSync(gone, "{}");
      const n2 = await exchange(node.port, [get(OPEN), get(OPEN)]);
      const h2 = await exchange(hs.port, [get(OPEN), get(OPEN)]);
      assert.deepEqual(h2.responses, n2.responses);
    });
  } finally {
    await node.stop();
    await hs.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

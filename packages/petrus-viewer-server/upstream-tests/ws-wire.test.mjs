/**
 * WebSocket wire differential: raw requests and frames against the Haskell
 * relays and the Node relays built on `ws`, comparing every byte each
 * connection receives: the opening handshake (101, or the 400/405 that
 * refuses it), then frames, close codes, close reasons, and whether the
 * server closes the connection.
 *
 *   - collaboration relay: `petrus-collab` vs upstream `server/collab.mjs`;
 *   - agent relay: `petrus` `/ws/agent` vs the upstream relay logic on bare
 *     `ws` (bench/node-baseline.mjs, the code the upstream test extracts
 *     from vite.config.ts).
 *
 * Both servers see the same connections in the same order, so the ids they
 * assign agree. Frames are masked with a fixed key unless a scenario says
 * otherwise.
 */

import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
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

async function startServer(cmd, args, env = {}) {
  const port = await freePort();
  const proc = spawn(cmd, args(port), { stdio: "ignore", env: { ...process.env, ...env } });
  await waitPort(port);
  return {
    port,
    stop: () => new Promise((r) => { if (proc.exitCode !== null) r(); else { proc.once("exit", r); proc.kill("SIGTERM"); } }),
  };
}

const MASK = Buffer.from([0x37, 0xfa, 0x21, 0x3d]);

/** A client frame: opcode, payload, and header overrides. */
function frame(opcode, payload = Buffer.alloc(0), { fin = true, rsv = 0, mask = true, len = null } = {}) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const n = len ?? data.length;
  const head = [(fin ? 0x80 : 0) | (rsv << 4) | opcode];
  const m = mask ? 0x80 : 0;
  let ext = Buffer.alloc(0);
  if (n < 126) head.push(m | n);
  else if (n < 65536) { head.push(m | 126); ext = Buffer.alloc(2); ext.writeUInt16BE(n); }
  else { head.push(m | 127); ext = Buffer.alloc(8); ext.writeBigUInt64BE(BigInt(n)); }
  const body = Buffer.from(data);
  if (mask) for (let i = 0; i < body.length; i++) body[i] ^= MASK[i & 3];
  return Buffer.concat([Buffer.from(head), ext, mask ? MASK : Buffer.alloc(0), body]);
}
const text = (s, o) => frame(1, Buffer.from(s), o);
const closeFrame = (code, reason = "") => {
  const b = Buffer.alloc(2);
  b.writeUInt16BE(code);
  return frame(8, Buffer.concat([b, Buffer.from(reason)]));
};

/** A raw WebSocket client that records what the server sends. */
function connect(port, wsPath) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, "127.0.0.1");
    const client = { sock, raw: Buffer.alloc(0), closed: false, handshake: null };
    sock.on("data", (d) => {
      client.raw = Buffer.concat([client.raw, d]);
      if (client.handshake === null) {
        const end = client.raw.indexOf("\r\n\r\n");
        if (end >= 0) {
          client.handshake = client.raw.subarray(0, end + 4).toString();
          client.raw = client.raw.subarray(end + 4);
          resolve(client);
        }
      }
    });
    sock.on("close", () => { client.closed = true; });
    sock.on("error", (e) => { if (client.handshake === null) reject(e); });
    sock.write(
      `GET ${wsPath} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
        `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`,
    );
  });
}

/** Decode server frames for readable failure messages. */
function frames(buf) {
  const out = [];
  let i = 0;
  while (i + 2 <= buf.length) {
    const op = buf[i] & 0x0f;
    let n = buf[i + 1] & 0x7f;
    let h = 2;
    if (n === 126) { n = buf.readUInt16BE(i + 2); h = 4; }
    else if (n === 127) { n = Number(buf.readBigUInt64BE(i + 2)); h = 10; }
    const p = buf.subarray(i + h, i + h + n);
    out.push(`${buf[i].toString(16)} op${op} ${op === 8 && p.length >= 2 ? `code ${p.readUInt16BE(0)} "${p.subarray(2)}"` : p.length > 200 ? `${p.length} bytes` : JSON.stringify(p.toString())}`);
    i += h + n;
  }
  if (i < buf.length) out.push(`+${buf.length - i} undecoded bytes`);
  return out;
}

// Each scenario drives connections through `ctx` and returns nothing; what
// every connection received is compared afterwards.
const ctx = (port, wsPath) => {
  const clients = [];
  return {
    clients,
    async open() {
      const c = await connect(port, wsPath);
      clients.push(c);
      await sleep(60);
      return c;
    },
    async send(c, ...bufs) {
      c.sock.write(Buffer.concat(bufs));
      await sleep(60);
    },
    async settle(ms = 120) { await sleep(ms); },
    async finish() {
      // close what is still open, politely, and let the server see it
      for (const c of clients) if (!c.closed) c.sock.write(closeFrame(1000));
      await sleep(150);
      for (const c of clients) c.sock.destroy();
      await sleep(60);
    },
  };
};

const BIG = JSON.stringify({ type: "schema", blob: "x".repeat(300000) });
const MEDIUM = JSON.stringify({ type: "cursor", label: "é".repeat(200) });

const FRAME_SCENARIOS = {
  "a relayed message and the leave that follows": async (t) => {
    const a = await t.open();
    const b = await t.open();
    await t.send(a, text('{"type":"cursor","x":1}'));
    await t.send(a, closeFrame(1000, "bye"));
    await t.settle();
    void b;
  },
  "16-bit and 64-bit lengths": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, text(MEDIUM));
    await t.send(a, text(BIG));
    await t.settle(300);
  },
  "a message split across TCP writes": async (t) => {
    const a = await t.open();
    await t.open();
    const f = text(BIG);
    for (let i = 0; i < f.length; i += 7001) await t.send(a, f.subarray(i, i + 7001));
    await t.settle(300);
  },
  "two frames in one write, the second split": async (t) => {
    const a = await t.open();
    await t.open();
    const f = Buffer.concat([text('{"n":1}'), text('{"n":2}'), text('{"n":3}')]);
    await t.send(a, f.subarray(0, f.length - 3));
    await t.send(a, f.subarray(f.length - 3));
  },
  "fragmented message with a ping in between": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, frame(1, '{"type":', { fin: false }), frame(0, '"frag"', { fin: false }), frame(9, "mid"), frame(0, ',"n":1}'));
  },
  "binary frame relayed as text": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, frame(2, '{"type":"bin","s":"é"}'));
  },
  "ping and pong": async (t) => {
    const a = await t.open();
    await t.send(a, frame(9, "hello"), frame(10, "ignored"), frame(9, ""), frame(9, "p".repeat(125)));
  },
  "close without a code": async (t) => {
    const a = await t.open();
    await t.send(a, frame(8));
  },
  "close with a code and a reason": async (t) => {
    const a = await t.open();
    await t.send(a, closeFrame(4001, "done é"));
  },
  // (a JSON primitive would kill server/collab.mjs: DIVERGENCES.md)
  "arrays and invalid JSON": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, text("[1,2]"), text("not json"), text('{"ok":1}'));
  },
  "data after a close frame is ignored": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, Buffer.concat([closeFrame(1000), text('{"after":true}')]));
  },
};

// Protocol errors: ws closes with a code and no reason. Only against the
// agent relay: server/collab.mjs has no "error" listener, so ws's error
// event kills the process (DIVERGENCES.md).
const ERROR_SCENARIOS = {
  "invalid close code": async (t) => { const a = await t.open(); await t.send(a, closeFrame(1005)); },
  "close code 999": async (t) => { const a = await t.open(); await t.send(a, closeFrame(999)); },
  "close payload of one byte": async (t) => { const a = await t.open(); await t.send(a, frame(8, Buffer.from([3]))); },
  "close reason that is not UTF-8": async (t) => { const a = await t.open(); await t.send(a, frame(8, Buffer.from([3, 232, 0xff, 0xfe]))); },
  "unmasked frame": async (t) => { const a = await t.open(); await t.send(a, text('{"a":1}', { mask: false })); },
  "RSV1 set": async (t) => { const a = await t.open(); await t.send(a, text('{"a":1}', { rsv: 4 })); },
  "RSV2 set": async (t) => { const a = await t.open(); await t.send(a, text('{"a":1}', { rsv: 2 })); },
  "opcode 3": async (t) => { const a = await t.open(); await t.send(a, frame(3, "x")); },
  "opcode 11": async (t) => { const a = await t.open(); await t.send(a, frame(11, "x")); },
  "continuation without a message": async (t) => { const a = await t.open(); await t.send(a, frame(0, "x")); },
  "text frame inside a fragmented message": async (t) => {
    const a = await t.open();
    await t.send(a, frame(1, "{", { fin: false }), frame(1, "}"));
  },
  "ping without FIN": async (t) => { const a = await t.open(); await t.send(a, frame(9, "x", { fin: false })); },
  "ping of 126 bytes": async (t) => { const a = await t.open(); await t.send(a, frame(9, "p".repeat(126))); },
  "text that is not UTF-8": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, frame(1, Buffer.from([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xc3, 0x28, 0x22, 0x7d])));
  },
  "fragmented text that is not UTF-8 across fragments": async (t) => {
    const a = await t.open();
    await t.send(a, frame(1, Buffer.from([0x22, 0xe2, 0x82]), { fin: false }), frame(0, Buffer.from([0x22])));
  },
  "length above 2^53 - 1": async (t) => {
    const a = await t.open();
    const head = Buffer.from([0x81, 0xff, 0x00, 0x20, 0, 0, 0, 0, 0, 0]);
    await t.send(a, head);
  },
  "message above the 100 MiB limit (announced)": async (t) => {
    const a = await t.open();
    await t.send(a, frame(1, Buffer.alloc(0), { len: 100 * 1024 * 1024 + 1 }).subarray(0, 14));
  },
  "fragments above the limit together": async (t) => {
    const a = await t.open();
    // a small first fragment, then a continuation whose announced length
    // takes the message past the limit
    await t.send(a, frame(1, '{"a":', { fin: false }), frame(0, Buffer.alloc(0), { len: 100 * 1024 * 1024 }).subarray(0, 14));
  },
};

const AGENT_SCENARIOS = {
  "targeted request and response": async (t) => {
    const browser = await t.open();
    const agent = await t.open();
    await t.open();
    await t.send(agent, text('{"protocol":"petrus-agent","version":1,"kind":"request","requestId":"r1","action":"document.inspect","targetClientId":"1"}'));
    await t.send(browser, text('{"protocol":"petrus-agent","version":1,"kind":"response","requestId":"r1","ok":true,"result":{"a":[1,2.5,"é"]},"targetClientId":"2"}'));
  },
  "spoofed id, non-canonical JSON, broadcast": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, text('{ "clientId" : "fake", "n": 1.50, "1": [1e21] }'));
    await t.send(a, text('{"targetClientId":"99","lost":true}'));
    await t.send(a, text('{"targetClientId":"","everyone":true}'));
  },
  "arrays are dropped": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, text("[1,2]"), text('{"after":1}'));
  },
  "close handshake and leave": async (t) => {
    const a = await t.open();
    await t.open();
    await t.send(a, closeFrame(1001, "going away"));
    await t.settle();
  },
};

// Opening handshakes: the full response (101 and what follows, or the
// 400/405 that refuses the upgrade) and whether the server closes.
const KEY = "dGhlIHNhbXBsZSBub25jZQ==";
const HANDSHAKES = {
  "plain upgrade": [],
  "first of the requested subprotocols": [["Sec-WebSocket-Protocol", "petrus-agent, other"]],
  "repeated subprotocol headers": [["Sec-WebSocket-Protocol", "a"], ["Sec-WebSocket-Protocol", "b"]],
  "duplicate subprotocol": [["Sec-WebSocket-Protocol", "a,a"]],
  "subprotocols separated by a space": [["Sec-WebSocket-Protocol", "a b"]],
  "subprotocol with trailing tab": [["Sec-WebSocket-Protocol", "a ,b\t"]],
  "empty subprotocol between commas": [["Sec-WebSocket-Protocol", "a,,b"]],
  "Upgrade in mixed case": [["Upgrade", "WebSocket"]],
  "Upgrade naming another protocol": [["Upgrade", "h2c"]],
  "key of the wrong shape": [["Sec-WebSocket-Key", "abc"]],
  "missing key": [["Sec-WebSocket-Key", null]],
  "version 8": [["Sec-WebSocket-Version", "8"]],
  "version 12": [["Sec-WebSocket-Version", "12"]],
  "version in hex": [["Sec-WebSocket-Version", "0x0d"]],
  "version 13.0": [["Sec-WebSocket-Version", "13.0"]],
  "version 1.3e1": [["Sec-WebSocket-Version", "1.3e1"]],
  "missing version": [["Sec-WebSocket-Version", null]],
  "version that is not a number": [["Sec-WebSocket-Version", "13a"]],
  "Connection with several tokens": [["Connection", "keep-alive, Upgrade"]],
  "POST": [["@method", "POST"]],
};

function handshakeRequest(port, wsPath, overrides) {
  let method = "GET";
  const headers = [["Host", `127.0.0.1:${port}`], ["Upgrade", "websocket"], ["Connection", "Upgrade"], ["Sec-WebSocket-Key", KEY], ["Sec-WebSocket-Version", "13"]];
  const extra = [];
  for (const [name, value] of overrides) {
    if (name === "@method") { method = value; continue; }
    const i = headers.findIndex(([n]) => n === name);
    if (i >= 0 && !extra.some(([n]) => n === name)) {
      if (value === null) headers.splice(i, 1);
      else headers[i] = [name, value];
    } else extra.push([name, value]);
  }
  const lines = [...headers, ...extra].map(([n, v]) => `${n}: ${v}`);
  return `${method} ${wsPath} HTTP/1.1\r\n${lines.join("\r\n")}\r\n\r\n`;
}

async function runHandshakes(server, wsPath) {
  const results = {};
  for (const [name, overrides] of Object.entries(HANDSHAKES)) {
    const sock = net.connect(server.port, "127.0.0.1");
    const got = { raw: Buffer.alloc(0), closedByServer: false };
    sock.on("data", (d) => { got.raw = Buffer.concat([got.raw, d]); });
    sock.on("close", () => { got.closedByServer = true; });
    sock.on("error", () => {});
    sock.write(handshakeRequest(server.port, wsPath, overrides));
    await sleep(250);
    const closedByServer = got.closedByServer;
    if (!closedByServer) { sock.write(closeFrame(1000)); await sleep(100); }
    sock.destroy();
    await sleep(40);
    results[name] = { response: got.raw.toString("latin1"), closedByServer };
  }
  return results;
}

async function compareHandshakes(nodeServer, hsServer, wsPath) {
  const node = await runHandshakes(nodeServer, wsPath);
  const hs = await runHandshakes(hsServer, wsPath);
  for (const name of Object.keys(HANDSHAKES)) assert.deepEqual(hs[name], node[name], `handshake "${name}" differs`);
}

async function runAll(server, wsPath, scenarios) {
  const results = {};
  for (const [name, run] of Object.entries(scenarios)) {
    const t = ctx(server.port, wsPath);
    await run(t);
    await t.settle();
    results[name] = t.clients.map((c) => ({ bytes: c.raw.toString("hex"), closedByServer: c.closed }));
    await t.finish();
  }
  return results;
}

async function compare(nodeServer, hsServer, nodePath, hsPath, scenarios) {
  const node = await runAll(nodeServer, nodePath, scenarios);
  const hs = await runAll(hsServer, hsPath, scenarios);
  for (const name of Object.keys(scenarios)) {
    const show = (r) => r.map((c) => ({ closedByServer: c.closedByServer, frames: frames(Buffer.from(c.bytes, "hex")) }));
    assert.deepEqual(show(hs[name]), show(node[name]), `${name}: decoded frames differ`);
    assert.deepEqual(hs[name], node[name], `${name}: bytes differ`);
  }
}

test("collaboration relay: same bytes on the wire as server/collab.mjs", { timeout: 120000 }, async () => {
  const node = await startServer(process.execPath, (p) => [path.join(VIEWER, "server/collab.mjs"), String(p)]);
  const hs = await startServer(path.join(BIN, "petrus-collab"), (p) => [String(p)]);
  try {
    await compareHandshakes(node, hs, "/");
    await compare(node, hs, "/", "/", FRAME_SCENARIOS);
  } finally {
    await node.stop();
    await hs.stop();
  }
});

test("agent relay: same bytes on the wire as the ws relay", { timeout: 120000 }, async () => {
  const node = await startServer(process.execPath, (p) => [path.join(PACKAGE, "bench/node-baseline.mjs"), VIEWER, String(p)]);
  const hs = await startServer(path.join(BIN, "petrus"), (p) => ["--no-open", "--strict-port", "--port", String(p)], { PETRUS_RELAY_PERF: "0" });
  try {
    await compareHandshakes(node, hs, "/ws/agent");
    await compare(node, hs, "/ws/agent", "/ws/agent", { ...FRAME_SCENARIOS, ...ERROR_SCENARIOS, ...AGENT_SCENARIOS });
  } finally {
    await node.stop();
    await hs.stop();
  }
});

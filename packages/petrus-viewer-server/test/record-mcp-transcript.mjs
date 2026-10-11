#!/usr/bin/env node
/**
 * Records test/fixtures/mcp-transcript-node.txt, the golden transcript of
 * test/McpSpec.hs: the session in test/fixtures/mcp-requests.json replayed
 * through the upstream Node MCP server (upstream/petrus-viewer/server/mcp.mjs),
 * bridged to the same fake browser McpSpec uses, over the upstream agent
 * relay (bench/node-baseline.mjs), in a scratch working directory with the
 * same three files. The output is normalized as McpSpec normalizes the
 * Haskell side: the working directory becomes <CWD>, the relay port <PORT>,
 * and screenshot timestamps canvas-<STAMP>.
 *
 * Usage (from the repository root, after `pnpm install` in
 * upstream/petrus-viewer):
 *
 *   node packages/petrus-viewer-server/test/record-mcp-transcript.mjs          # rewrite the fixture
 *   node packages/petrus-viewer-server/test/record-mcp-transcript.mjs --check  # fail if it differs
 *
 * Rerun it after moving the petrus-viewer pin or editing mcp-requests.json
 * (UPSTREAM.md). The fake browser below must stay identical to McpSpec's.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE = path.resolve(HERE, "..");
const REPO = path.resolve(PACKAGE, "../..");
const VIEWER = path.join(REPO, "upstream/petrus-viewer");
const FIXTURES = path.join(HERE, "fixtures");
const TRANSCRIPT = path.join(FIXTURES, "mcp-transcript-node.txt");
const check = process.argv.includes("--check");

const require = createRequire(path.join(VIEWER, "package.json"));
const { WebSocket } = require("ws");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The agent relay on a free port; resolves to [process, port]. */
async function startRelay() {
  for (let attempt = 0; attempt < 20; attempt++) {
    const port = 47000 + Math.floor(Math.random() * 2000);
    const relay = spawn(process.execPath, [path.join(PACKAGE, "bench/node-baseline.mjs"), VIEWER, String(port)], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const up = await new Promise((resolve) => {
      relay.stdout.on("data", (d) => String(d).includes("listening") && resolve(true));
      relay.on("exit", () => resolve(false));
    });
    if (up) return [relay, port];
  }
  throw new Error("could not start the relay");
}

/** Answers agent requests exactly like McpSpec's fakeBrowser. */
function answer(m) {
  const action = typeof m.action === "string" ? m.action : null;
  let ok = true;
  let payload;
  switch (action) {
    case "simulation.inspect":
      payload = {
        mode: "edit",
        revision: "rev-1",
        isTerminal: false,
        state: {
          net: "test",
          states: [
            { fired: null, marking: { p1: 1, p2: 0 }, context: {} },
            { fired: "t1", marking: { p1: 0, p2: 1.5, 10: 2 }, context: {} },
          ],
          current: 1,
        },
      };
      break;
    case "canvas.screenshot":
      payload = { base64: "iVBORw0KGgo=" };
      break;
    case "document.open":
      payload = { netName: "opened" };
      break;
    case "schema.undo":
      ok = false;
      payload = { code: "conflict", message: "Nothing to undo" };
      break;
    default:
      payload = {
        echo: m.params ?? null,
        action,
        unicode: "é \u{1F600}",
        num: [1.5, 1e21, 0.1, -0, 123456789012],
      };
  }
  return {
    protocol: "petrus-agent",
    version: 1,
    kind: "response",
    requestId: m.requestId ?? null,
    action,
    ok,
    targetClientId: m.clientId ?? null,
    [ok ? "result" : "error"]: payload,
  };
}

async function connectBrowser(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/agent`);
  await new Promise((resolve, reject) => {
    ws.once("message", resolve); // the welcome
    ws.once("error", reject);
  });
  ws.on("message", (raw) => {
    let m;
    try { m = JSON.parse(String(raw)); } catch { return; }
    if (m && m.protocol === "petrus-agent" && m.kind === "request") ws.send(JSON.stringify(answer(m)));
  });
  return ws;
}

function scratchDir() {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "petrus-mcp-golden-")));
  fs.mkdirSync(path.join(dir, "examples"));
  fs.writeFileSync(path.join(dir, "examples/sample-net.json"), '{"fileVersion":"2","net":"sample","arcs":[],"places":{},"transitions":{}}\n');
  fs.writeFileSync(path.join(dir, "package.json"), '{"name":"fixture"}\n');
  fs.writeFileSync(path.join(dir, "index.html"), "<!doctype html>\n<html><body></body></html>\n");
  return dir;
}

async function record() {
  const requests = JSON.parse(fs.readFileSync(path.join(FIXTURES, "mcp-requests.json"), "utf8"));
  const [relay, port] = await startRelay();
  const browser = await connectBrowser(port);
  const cwd = scratchDir();
  const env = { ...process.env };
  for (const k of ["PETRUS_AGENT_URL", "PETRUS_MCP_REQUEST_TIMEOUT_MS", "PETRUS_HISTORY_URL", "PETRUS_PERF"]) delete env[k];
  env.PETRUS_AGENT_URL = `ws://localhost:${port}/ws/agent`;
  env.PETRUS_MCP_REQUEST_TIMEOUT_MS = "300";
  const mcp = spawn(process.execPath, [path.join(VIEWER, "server/mcp.mjs")], { cwd, env, stdio: ["pipe", "pipe", "ignore"] });
  const lines = [];
  let pending = "";
  let waiting = null;
  mcp.stdout.on("data", (d) => {
    pending += String(d);
    let i;
    while ((i = pending.indexOf("\n")) >= 0) {
      lines.push(pending.slice(0, i));
      pending = pending.slice(i + 1);
      if (waiting) waiting();
    }
  });
  try {
    for (const r of requests) {
      const before = lines.length;
      mcp.stdin.write((typeof r === "string" ? r : JSON.stringify(r)) + "\n");
      if (typeof r === "object" && r.id !== undefined) {
        const got = await Promise.race([
          new Promise((resolve) => {
            waiting = () => lines.length > before && resolve(true);
            waiting();
          }),
          sleep(10000).then(() => false),
        ]);
        waiting = null;
        if (!got) throw new Error(`no response to ${JSON.stringify(r)}`);
      } else {
        await sleep(200);
      }
    }
  } finally {
    mcp.kill();
    browser.terminate();
    relay.kill();
    fs.rmSync(cwd, { recursive: true, force: true });
  }
  return lines
    .map((l) => l.split(cwd).join("<CWD>").split(`:${port}/`).join(":<PORT>/").replace(/canvas-\d+/g, "canvas-<STAMP>"))
    .map((l) => l + "\n")
    .join("");
}

const transcript = await record();
if (check) {
  const committed = fs.readFileSync(TRANSCRIPT, "utf8");
  if (committed !== transcript) {
    const a = committed.split("\n");
    const b = transcript.split("\n");
    const i = a.findIndex((l, k) => l !== b[k]);
    console.error(`mcp-transcript-node.txt is stale: line ${i + 1} differs\ncommitted: ${a[i]}\nrecorded:  ${b[i]}`);
    process.exit(1);
  }
  console.log(`mcp-transcript-node.txt matches the Node server (${lineCount(transcript)} lines)`);
} else {
  fs.writeFileSync(TRANSCRIPT, transcript);
  console.log(`wrote ${path.relative(REPO, TRANSCRIPT)} (${lineCount(transcript)} lines)`);
}

function lineCount(t) {
  return t.split("\n").length - 1;
}

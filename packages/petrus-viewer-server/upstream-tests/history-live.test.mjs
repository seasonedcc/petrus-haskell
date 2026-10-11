/**
 * History replay and live watching in the real browser UI, from real
 * Petrus producers, with nothing from Node on the backend path:
 *
 *   producers (observation-protocol-v1 over HTTP):
 *     - petrus-viewer-server-test --chain-producer (test/ChainProducer.hs):
 *       a Haskell Engine (petrus-engine) served by petrus-observation-http,
 *       instance "chain-hs";
 *     - test/chain_producer.py: the pinned upstream Python reference Engine
 *       and observation server (interpreter from scripts/upstream-python),
 *       instance "chain-py";
 *   petrus (Haskell) --observation <both> ── /temporal ──> built upstream UI
 *   (headless Chromium), inspected through petrus-mcp (Haskell) and the
 *   petrus /ws/agent relay.
 *
 * Both producers run the same scenario: the chain Net a -> t1 -> b -> t2 ->
 * c -> t3 -> d, advanced one step at a time. The UI's own "Connect" dialog
 * lists them, "Load State" replays one, and "Watch Live" follows one while
 * it advances (the UI polls get_state every 2 s and appends new states).
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import readline from "node:readline";
import { spawn, execFileSync } from "node:child_process";
import { chromium } from "playwright";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { PETRUS, PETRUS_MCP, UI_DIR } from "../shims/haskell-backend.mjs";

const BIN = process.env.PETRUS_HS_BIN_DIR;
const VIEWER = process.env.PETRUS_HS_VIEWER_DIR;
const PACKAGE = process.env.PETRUS_HS_PACKAGE_DIR;
const REPO = path.resolve(PACKAGE, "../..");
const SAMPLE_NET = path.join(VIEWER, "examples/sample-net.json");

const producers = {};
let petrus;
let port;
let browser;
let page;
let mcp;

/** A producer process speaking the fixture's line protocol. */
function startProducer(name, cmd, args, cwd) {
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, { cwd, stdio: ["pipe", "pipe", "inherit"] });
    const lines = readline.createInterface({ input: proc.stdout });
    const waiting = [];
    lines.on("line", (line) => waiting.shift()?.(line));
    const next = () => new Promise((r) => waiting.push(r));
    proc.on("exit", (code) => reject(new Error(`${name} exited ${code}`)));
    next().then((line) => {
      const producer = {
        proc,
        port: Number(line),
        advance: async () => {
          proc.stdin.write("advance\n");
          return Number(await next());
        },
      };
      resolve(producer);
    });
  });
}

async function stopProducer(producer) {
  if (!producer || producer.proc.exitCode !== null) return;
  const exited = new Promise((r) => producer.proc.once("exit", r));
  producer.proc.stdin.end(); // both fixtures shut down at end of input
  const timer = setTimeout(() => producer.proc.kill("SIGTERM"), 10000);
  await exited;
  clearTimeout(timer);
}

function startPetrus(observationUrls) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, PETRUS_OPEN_FILE: SAMPLE_NET };
    delete env.PETRUS_SOURCE_URL;
    delete env.PETRUS_OBSERVATION_URLS;
    const proc = spawn(
      PETRUS,
      ["--no-open", "--strict-port", "--port", "0", "--ui-dir", UI_DIR, ...observationUrls.flatMap((u) => ["--observation", u])],
      { env, stdio: ["ignore", "pipe", "inherit"] },
    );
    let output = "";
    const timer = setTimeout(() => reject(new Error(`petrus start timeout: ${output}`)), 15000);
    proc.stdout.on("data", (chunk) => {
      output += chunk.toString();
      const match = output.match(/Local:\s+http:\/\/localhost:(\d+)/);
      if (match) {
        clearTimeout(timer);
        proc.stdout.resume();
        resolve({ proc, port: Number(match[1]) });
      }
    });
    proc.on("exit", (code) => reject(new Error(`petrus exited ${code}: ${output}`)));
  });
}

async function ok(name, args = {}) {
  const result = await mcp.callTool({ name, arguments: args });
  const text = result.content?.map((c) => c.text ?? "").join("") ?? "";
  assert.ok(!result.isError, `${name} failed: ${text}`);
  return JSON.parse(text);
}

const simulation = () => ok("petrus_inspect_simulation");

async function until(what, predicate, ms = 15000) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await simulation();
    if (predicate(last)) return last;
    await new Promise((r) => setTimeout(r, 200));
  }
  assert.fail(`${what}: ${JSON.stringify({ mode: last?.mode, states: last?.state?.states?.length, isTerminal: last?.isTerminal })}`);
}

/** Open the UI's Connect dialog, list the /temporal workflows, select one. */
async function connectDialog(workflowId) {
  // a dialog left open by a failed step would cover the toolbar
  if (await page.locator(".temporal-overlay").count()) await page.click(".temporal-dialog .temporal-close");
  await page.click('button[title="Connect to running Temporal workflow"]');
  const inputs = page.locator(".temporal-dialog .temporal-input");
  await inputs.nth(1).fill("default"); // namespace; the host stays "/temporal"
  await page.click('.temporal-dialog button:has-text("List")');
  const row = page.locator(".temporal-table tbody tr", { hasText: workflowId });
  await row.waitFor({ timeout: 10000 });
  const cells = await row.locator("td").allTextContents();
  await row.click();
  return cells;
}

/** The token counts of a state, without the empty places. */
const marking = (s) => Object.fromEntries(Object.entries(s.marking).filter(([, n]) => n > 0));

describe("Haskell backend, browser UI, history from real producers", { timeout: 180000 }, () => {
  before(async () => {
    producers.hs = await startProducer("chain producer", path.join(BIN, "petrus-viewer-server-test"), ["--chain-producer", "chain-hs"]);
    const python = execFileSync(path.join(REPO, "scripts/upstream-python"), ["petrus"], { encoding: "utf8" }).trim();
    producers.py = await startProducer("chain_producer.py", python, ["-I", path.join(PACKAGE, "test/chain_producer.py"), "chain-py"], path.join(REPO, "upstream/petrus"));
    const started = await startPetrus([producers.hs, producers.py].map((p) => `http://127.0.0.1:${p.port}`));
    petrus = started.proc;
    port = started.port;

    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    await page.goto(`http://localhost:${port}`, { waitUntil: "networkidle", timeout: 20000 });

    mcp = new Client({ name: "petrus-history-test", version: "1.0.0" });
    const env = { ...process.env, PETRUS_AGENT_URL: `ws://localhost:${port}/ws/agent`, PETRUS_PERF: "0", PETRUS_HISTORY_URL: `http://localhost:${port}/temporal` };
    delete env.PETRUS_MCP_DEV_COMMAND;
    await mcp.connect(new StdioClientTransport({ command: PETRUS_MCP, args: [], env, stderr: "ignore" }));
    // the UI is up once the agent bridge sees it
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline && !(await ok("petrus_status")).browser_ui_ready) await new Promise((r) => setTimeout(r, 200));
  });

  after(async () => {
    await mcp?.close().catch(() => {});
    await page?.close().catch(() => {});
    await browser?.close().catch(() => {});
    if (petrus && petrus.exitCode === null) {
      const exited = new Promise((resolve) => petrus.once("exit", resolve));
      petrus.kill("SIGTERM");
      await exited;
    }
    await stopProducer(producers.hs);
    await stopProducer(producers.py);
  });

  it("the Connect dialog lists both producers' instances", async () => {
    const cells = await connectDialog("chain-hs");
    // the UI shows WORKFLOW_EXECUTION_STATUS_RUNNING as RUNNING
    assert.deepEqual(cells.slice(0, 3), ["chain-hs", "viewer-chain", "RUNNING"]);
    const rows = await page.locator(".temporal-table tbody tr .temporal-cell-id").allTextContents();
    assert.deepEqual([...rows].sort(), ["chain-hs", "chain-py"]);
    await page.click('.temporal-dialog button:has-text("Cancel")');
  });

  const finals = {};
  for (const name of ["hs", "py"]) {
    const workflowId = `chain-${name}`;

    it(`${workflowId}: Load State replays the history`, async () => {
      await connectDialog(workflowId);
      await page.click('.temporal-dialog button:has-text("Load State")');
      // InstanceCreated (no tokens yet), then TokensInitialized
      const sim = await until("replay", (s) => s.mode === "replay" && s.state?.states?.length === 2);
      assert.deepEqual(sim.state.states.map(marking), [{}, { a: 1 }]);
      const doc = await ok("petrus_inspect_document", { includeSchema: true });
      assert.deepEqual(Object.keys(doc.snapshot.netSchema.places).sort(), ["a", "b", "c", "d"]);
    });

    it(`${workflowId}: Watch Live follows the Engine as it advances`, async () => {
      await connectDialog(workflowId);
      await page.click('.temporal-dialog button:has-text("Watch Live")');
      await until("live", (s) => s.mode === "live");
      let seen = 2;
      for (;;) {
        const fired = await producers[name].advance();
        if (fired === 0) break;
        // the next poll (every 2 s) appends the new states
        const sim = await until(`live after ${seen} states`, (s) => s.state?.states?.length > seen);
        seen = sim.state.states.length;
      }
      // the UI steps through every appended state and leaves live mode once
      // the workflow is terminal
      const sim = await until("terminal", (s) => s.mode === "replay" && s.isTerminal === true, 20000);
      const states = sim.state.states;
      assert.equal(states.length, seen);
      assert.deepEqual(states.slice(0, 2).map(marking), [{}, { a: 1 }]);
      assert.deepEqual(marking(states[states.length - 1]), { d: 1 });
      assert.deepEqual([...new Set(states.map((s) => s.fired).filter(Boolean))], ["t1", "t2", "t3"]);
      finals[name] = states.map((s) => ({ fired: s.fired, marking: marking(s) }));
    });

    it(`${workflowId}: petrus_trace_import replays the finished run`, async () => {
      const r = await ok("petrus_trace_import", { workflowId });
      assert.equal(r.mode, "replay");
      assert.equal(r.source, "temporal");
      const sim = await simulation();
      assert.equal(sim.state.states.length, r.importedStates);
      assert.equal(r.importedStates, finals[name].length);
    });
  }

  it("the Haskell and Python producers give the UI the same history", () => {
    assert.ok(finals.hs && finals.py);
    assert.deepEqual(finals.hs, finals.py);
  });
});

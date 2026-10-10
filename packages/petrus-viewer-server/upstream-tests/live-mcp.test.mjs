/**
 * End to end, with nothing from Node on the backend path:
 *
 *   MCP SDK client ──stdio── petrus-mcp (Haskell)
 *        ──ws──> petrus /ws/agent relay (Haskell) ──ws──> browser UI (built
 *        upstream bundle served by petrus, headless Chromium)
 *
 * plus history replay: petrus serves /temporal from a Petrus observation
 * producer (a stub serving the observation-protocol-v1 fixtures from
 * upstream/petrus/spec), and petrus_trace_import (with PETRUS_HISTORY_URL)
 * loads that history into the browser's replay mode.
 *
 * Every MCP tool is exercised against the live UI.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { PETRUS, PETRUS_MCP, UI_DIR } from "../shims/haskell-backend.mjs";

const VIEWER = process.env.PETRUS_HS_VIEWER_DIR;
const SPEC = process.env.PETRUS_HS_SPEC_DIR;
const SAMPLE_NET = path.join(VIEWER, "examples/sample-net.json");
const TOOLS = [
  "petrus_status", "petrus_inspect_document", "petrus_inspect_canvas", "petrus_inspect_selection",
  "petrus_inspect_simulation", "petrus_preview_mutation", "petrus_apply_mutation", "petrus_undo", "petrus_redo",
  "petrus_simulation_command", "petrus_scenario_save", "petrus_scenario_compare", "petrus_trace_import",
  "petrus_trace_scenarios", "petrus_screenshot", "petrus_open_file",
];

let producer;
let petrus;
let port;
let browser;
let page;
let mcp;
let mcpNoHistory;

/** A Petrus observation producer (observation-protocol-v1 HTTP profile). */
function startProducer() {
  const snapshot = fs.readFileSync(path.join(SPEC, "observation/engine-snapshot-v1.json"));
  const document = fs.readFileSync(path.join(SPEC, "net-document-v1-observation.json"));
  const server = http.createServer((req, res) => {
    const body = req.url === "/v1/snapshot" ? snapshot : req.url === "/v1/document" ? document : null;
    if (!body) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { "Content-Type": "application/json" }).end(body);
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

function startPetrus(observationUrl) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, PETRUS_OPEN_FILE: SAMPLE_NET };
    delete env.PETRUS_SOURCE_URL;
    const proc = spawn(
      PETRUS,
      ["--no-open", "--strict-port", "--port", "0", "--ui-dir", UI_DIR, "--observation", observationUrl],
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

async function connectMcp(extraEnv) {
  const client = new Client({ name: "petrus-live-test", version: "1.0.0" });
  const env = { ...process.env, PETRUS_AGENT_URL: `ws://localhost:${port}/ws/agent`, PETRUS_PERF: "0", ...extraEnv };
  delete env.PETRUS_MCP_DEV_COMMAND;
  if (!extraEnv.PETRUS_HISTORY_URL) delete env.PETRUS_HISTORY_URL;
  await client.connect(new StdioClientTransport({ command: PETRUS_MCP, args: [], env, stderr: "ignore" }));
  return client;
}

async function call(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  const text = result.content?.map((c) => c.text ?? "").join("") ?? "";
  if (result.isError) return { error: text };
  try {
    return { ok: JSON.parse(text), text };
  } catch {
    return { ok: text, text };
  }
}

async function ok(client, name, args) {
  const r = await call(client, name, args);
  assert.ok(!("error" in r), `${name} failed: ${r.error}`);
  return r.ok;
}

/** Dotted ids of a hierarchical NetSchema's places or transitions. */
function ids(schema, kind, prefix = "") {
  const own = Object.keys(schema?.[kind] ?? {}).map((k) => prefix + k);
  const nested = Object.entries(schema?.subnets ?? {}).flatMap(([name, sub]) => ids(sub, kind, `${prefix}${name}.`));
  return [...own, ...nested];
}

async function schemaOf(client) {
  return (await ok(client, "petrus_inspect_document", { includeSchema: true })).snapshot.netSchema;
}

/** The UI loads the initial file asynchronously after boot. */
async function waitForPlace(client, place) {
  const deadline = Date.now() + 15000;
  let places = [];
  while (Date.now() < deadline) {
    places = ids(await schemaOf(client), "places");
    if (places.includes(place)) break;
    await new Promise((r) => setTimeout(r, 200));
  }
  return places;
}

describe("Haskell backend, live browser, MCP tools", { timeout: 120000 }, () => {
  before(async () => {
    producer = await startProducer();
    const started = await startPetrus(`http://127.0.0.1:${producer.address().port}`);
    petrus = started.proc;
    port = started.port;

    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    await page.goto(`http://localhost:${port}`, { waitUntil: "networkidle", timeout: 20000 });
    await page.waitForFunction(() => {
      const badge = document.querySelector(".pi-status-badge");
      return badge && badge.getAttribute("title")?.includes("connected");
    }, { timeout: 10000 }).catch(() => {});

    mcp = await connectMcp({ PETRUS_HISTORY_URL: `http://localhost:${port}/temporal` });
    mcpNoHistory = await connectMcp({});
  });

  after(async () => {
    await mcp?.close().catch(() => {});
    await mcpNoHistory?.close().catch(() => {});
    await page?.close().catch(() => {});
    await browser?.close().catch(() => {});
    if (petrus && petrus.exitCode === null) {
      const exited = new Promise((resolve) => petrus.once("exit", resolve));
      petrus.kill("SIGTERM");
      await exited;
    }
    await new Promise((resolve) => producer?.close(resolve));
  });

  it("lists the upstream tools", async () => {
    const { tools } = await mcp.listTools();
    assert.deepEqual(tools.map((t) => t.name), TOOLS);
  });

  it("petrus_status sees the bridge and the browser UI", async () => {
    const status = await ok(mcp, "petrus_status");
    assert.equal(status.mcp_server, "running");
    assert.equal(status.bridge_connected, true);
    assert.equal(status.browser_ui_ready, true);
  });

  it("the UI loaded PETRUS_OPEN_FILE through /__petrus/open-file", async () => {
    const places = await waitForPlace(mcp, "payment.pending");
    assert.ok(places.includes("payment.pending"), JSON.stringify(places));
    const doc = await ok(mcp, "petrus_inspect_document", { includeSchema: true });
    assert.equal(doc.snapshot.mode, "edit");
  });

  it("canvas and selection inspection", async () => {
    const canvas = await ok(mcp, "petrus_inspect_canvas", { includeNodes: true, includeEdges: true });
    assert.ok(canvas.canvas.nodes.length > 0);
    const selection = await ok(mcp, "petrus_inspect_selection");
    assert.ok(Array.isArray(selection.selection.nodeIds));
  });

  it("petrus_open_file loads a net from disk", async () => {
    const result = await ok(mcp, "petrus_open_file", { path: SAMPLE_NET });
    assert.ok(result);
    assert.ok(ids(await schemaOf(mcp), "transitions").includes("payment.authorize"));
  });

  it("simulation: fire, step back, step forward", async () => {
    const before = await ok(mcp, "petrus_inspect_simulation");
    const start = before.state.current;
    // fire the first enabled transition (firing a disabled one is a no-op)
    let fired = null;
    for (const t of ids(await schemaOf(mcp), "transitions")) {
      const r = await ok(mcp, "petrus_simulation_command", { kind: "fire-transition", transitionId: t });
      if (r.currentStateIndex === start + 1) {
        fired = t;
        break;
      }
      assert.equal(r.currentStateIndex, start);
    }
    assert.ok(fired, "no transition is enabled");
    const afterFire = await ok(mcp, "petrus_inspect_simulation");
    assert.equal(afterFire.state.current, start + 1);
    await ok(mcp, "petrus_simulation_command", { kind: "step-back" });
    assert.equal((await ok(mcp, "petrus_inspect_simulation")).state.current, start);
    // stepping forward over a fired transition animates the tokens first
    await ok(mcp, "petrus_simulation_command", { kind: "step-forward" });
    let current = null;
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      current = (await ok(mcp, "petrus_inspect_simulation")).state.current;
      if (current === start + 1) break;
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.equal(current, start + 1);
  });

  it("scenarios: save and compare", async () => {
    const a = await call(mcp, "petrus_scenario_save", { name: "after-fire" });
    assert.ok(!a.error, a.error);
    await ok(mcp, "petrus_simulation_command", { kind: "step-back" });
    const b = await call(mcp, "petrus_scenario_save", { name: "before-fire" });
    assert.ok(!b.error, b.error);
    const cmp = await ok(mcp, "petrus_scenario_compare", { scenarioA: "before-fire", scenarioB: "after-fire" });
    assert.ok(Object.keys(cmp.differences ?? cmp).length > 0, JSON.stringify(cmp));
    const missing = await call(mcp, "petrus_scenario_compare", { scenarioA: "nope", scenarioB: "after-fire" });
    assert.equal(missing.error, "Scenario 'nope' not found.");
  });

  it("mutations: preview, apply, undo, redo", async () => {
    const preview = await ok(mcp, "petrus_preview_mutation", {
      operations: [{ kind: "add-place", nodeId: "live_test_place", position: { x: 640, y: 80 } }],
    });
    assert.ok(preview.previewId);
    await ok(mcp, "petrus_apply_mutation", { previewId: preview.previewId });
    const has = async () => ids(await schemaOf(mcp), "places").includes("live_test_place");
    assert.equal(await has(), true);
    await ok(mcp, "petrus_undo");
    assert.equal(await has(), false);
    await ok(mcp, "petrus_redo");
    assert.equal(await has(), true);
  });

  it("petrus_screenshot writes a PNG", async () => {
    const r = await call(mcp, "petrus_screenshot");
    assert.ok(!r.error, r.error);
    const file = r.text.replace(/^Screenshot saved to /, "");
    const bytes = fs.readFileSync(file);
    assert.deepEqual([...bytes.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
    fs.rmSync(file, { force: true });
  });

  it("/temporal serves the observation producer as Temporal workflows", async () => {
    const list = await (await fetch(`http://localhost:${port}/temporal/api/v1/namespaces/default/workflows`)).json();
    assert.equal(list.executions.length, 1);
    assert.equal(list.executions[0].execution.workflowId, "canonical-instance");
    const query = async (q) =>
      (await (await fetch(`http://localhost:${port}/temporal/api/v1/namespaces/default/workflows/canonical-instance/query/${q}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      })).json()).queryResult[0];
    const schema = await query("get_schema");
    assert.ok(schema.places && schema.transitions);
    const state = await query("get_state");
    assert.ok(state.history.states.length > 0);
  });

  it("petrus_trace_import without a history source behaves as upstream", async () => {
    const r = await call(mcpNoHistory, "petrus_trace_import", { workflowId: "canonical-instance" });
    assert.equal(r.error, "trace.import requires runtimeState payload");
  });

  it("petrus_trace_import replays observed history (PETRUS_HISTORY_URL)", async () => {
    const r = await ok(mcp, "petrus_trace_import", { workflowId: "canonical-instance" });
    assert.equal(r.mode, "replay");
    assert.equal(r.source, "temporal");
    assert.ok(r.importedStates > 0);
    const sim = await ok(mcp, "petrus_inspect_simulation");
    assert.equal(sim.mode, "replay");
    assert.equal(sim.state.states.length, r.importedStates);
    const scenarios = await ok(mcp, "petrus_trace_scenarios", { prefix: "obs" });
    assert.ok(JSON.stringify(scenarios).includes("obs-initial"));
  });
});

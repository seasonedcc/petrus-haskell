#!/usr/bin/env node
/**
 * Benchmark the Haskell viewer backend against the upstream Node backend
 * with one load client (petrus-viewer-bench) for both.
 *
 * Targets (each started on its own non-default port, stopped by PID):
 *   haskell     petrus --no-open --strict-port --port P   (relay perf log on, like Vite)
 *   haskell     the same with PETRUS_RELAY_PERF=0 (relay scenarios only; no
 *               log, like the bare baseline)
 *   node-vite   upstream `vite --port P --strictPort` (what bin/petrus.mjs runs)
 *   node-bare   bench/node-baseline.mjs: upstream endpoint + relay on bare
 *               node:http, no perf log (Node's best case)
 * Collaboration fan-out:
 *   haskell     petrus --host localhost /collab-ws, and petrus-collab P
 *   node        node server/collab.mjs P
 * Static UI (the `pnpm build` output) and the /temporal proxy:
 *   haskell     petrus --ui-dir upstream/petrus-viewer/dist
 *   node-vite   the Vite dev server (above), and `vite preview` (serves dist/)
 *   Both proxies forward /temporal to localhost:7243 (Vite's is hard-coded),
 *   where `petrus-viewer-bench backend` answers every request with the same
 *   2.4 KB JSON.
 * MCP tools/call round trip (the process the agent talks to over stdio,
 * bridged to one agent relay, petrus with PETRUS_RELAY_PERF=0, where the
 * load client's fake browser answers):
 *   haskell     petrus-mcp
 *   node        node server/mcp.mjs
 * Cold start (spawn until the file and the UI are served):
 *   haskell     petrus --no-open --ui-dir upstream/petrus-viewer/dist FILE
 *   node        node bin/petrus.mjs --no-open FILE (pnpm exec vite)
 *
 * All servers run for the whole benchmark and the runs are interleaved
 * (scenario by scenario, rep by rep, rotating which target goes first), so
 * load from other processes on the machine hits every target alike. The
 * reported run is the median by ops/s.
 *
 * Usage:
 *   node packages/petrus-viewer-server/bench/run.mjs [--bin-dir DIR] [--reps 5] [--quick]
 *        [--only "SUBSTRING|SUBSTRING"] [--rts "RTS OPTIONS"] [--json out.json]
 *
 * Without --bin-dir the executables are built with cabal (benchmarks enabled).
 * Requires `pnpm install` in upstream/petrus-viewer, and `pnpm build` there
 * for the static and cold-start scenarios.
 */
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE = path.resolve(HERE, "..");
const REPO = path.resolve(PACKAGE, "../..");
const VIEWER = path.join(REPO, "upstream/petrus-viewer");

const args = process.argv.slice(2);
const opt = (name, d) => {
  const i = args.indexOf(name);
  return i < 0 ? d : args[i + 1];
};
const quick = args.includes("--quick");
const reps = Number(opt("--reps", quick ? "1" : "5"));
const only = opt("--only", null);
const jsonOut = opt("--json", null);
const binDir = opt("--bin-dir", null);
// extra RTS options for the Haskell servers, e.g. --rts "-N4"
const rts = opt("--rts", null);
const rtsArgs = rts ? ["+RTS", ...rts.split(/\s+/).filter(Boolean), "-RTS"] : [];

function bin(name) {
  if (binDir) return path.resolve(binDir, name);
  const target = name === "petrus-viewer-bench" ? "petrus-viewer-server:bench:petrus-viewer-bench" : `petrus-viewer-server:exe:${name}`;
  return execFileSync("cabal", ["list-bin", "--enable-benchmarks", target], { cwd: REPO, encoding: "utf8" }).trim();
}
if (!binDir) {
  execFileSync("cabal", ["build", "--enable-benchmarks", "petrus-viewer-server:exes", "petrus-viewer-server:benchmarks"], { cwd: REPO, stdio: "inherit" });
}
const BENCH = bin("petrus-viewer-bench");
const PETRUS = bin("petrus");
const PETRUS_COLLAB = bin("petrus-collab");
const PETRUS_MCP = bin("petrus-mcp");

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "petrus-bench-"));
const netFile = path.join(scratch, "B.json");
fs.copyFileSync(path.join(VIEWER, "examples/sample-net.json"), netFile);
const DIST = path.join(VIEWER, "dist");
// the built bundle's path, from the built index.html
const bundle = fs.existsSync(path.join(DIST, "index.html"))
  ? (fs.readFileSync(path.join(DIST, "index.html"), "utf8").match(/\/assets\/main-[^"]+\.js/) ?? [null])[0]
  : null;
const bundleKiB = bundle ? Math.round(fs.statSync(path.join(DIST, bundle)).size / 1024) : 0;
// the Temporal stand-in's port: Vite's proxy target is hard-coded
const TEMPORAL_PORT = 7243;

let nextPort = 47310;
const children = new Set();
process.on("exit", () => {
  for (const c of children) try { c.kill(); } catch {}
});

// resolves with the loopback address the server accepts connections on
const tryHost = (port, host) =>
  new Promise((resolve) => {
    const s = net.connect(port, host);
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => { s.destroy(); resolve(false); });
  });

function waitPort(port, ms = 30000) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const attempt = async () => {
      for (const host of ["127.0.0.1", "::1"]) if (await tryHost(port, host)) return resolve(host);
      if (Date.now() > deadline) reject(new Error(`port ${port} never opened`));
      else setTimeout(attempt, 100);
    };
    attempt();
  });
}

async function start(cmd, argv, cwd, env = {}, fixedPort = null) {
  const port = fixedPort ?? nextPort++;
  if (fixedPort && ((await tryHost(port, "127.0.0.1")) || (await tryHost(port, "::1")))) {
    throw new Error(`port ${port} is taken; the benchmark needs it`);
  }
  const child = spawn(cmd, argv(port), { cwd, stdio: ["ignore", "ignore", "inherit"], env: { ...process.env, ...env } });
  children.add(child);
  const host = await waitPort(port);
  await new Promise((r) => setTimeout(r, 500));
  return { port, host, child };
}

// processes the targets of a group share (started once, on first use)
const helpers = new Map();
function helper(name, launch) {
  if (!helpers.has(name)) helpers.set(name, launch());
  return helpers.get(name);
}
const agentRelay = () =>
  helper("relay", () => start(PETRUS, (p) => ["--no-open", "--strict-port", "--port", String(p)], scratch, { PETRUS_RELAY_PERF: "0" }));
const temporalBackend = () =>
  helper("temporal", () => start(BENCH, (p) => ["backend", "--port", String(p)], scratch, {}, TEMPORAL_PORT));

function stop({ child }) {
  children.delete(child);
  child.kill(); // exact PID of the server we started
  return new Promise((r) => (child.exitCode !== null ? r() : child.once("exit", r)));
}

function rssMiB(pid) {
  try {
    return Math.round(Number(execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim()) / 1024);
  } catch {
    return null;
  }
}

function runBench(argv) {
  const out = execFileSync(BENCH, [...argv, "+RTS", "-M2G", "-RTS"], { encoding: "utf8", timeout: 300000 });
  return JSON.parse(out.trim().split("\n").pop());
}

const n = (full, q) => String(quick ? q : full);
const get = (target, concurrency, requests) => ["http", "--endpoint", "get", "--target", target, "--concurrency", String(concurrency), "--requests", requests];
const mcp = (tool, args, concurrency, calls) => (t) => ["mcp", "--cmd", JSON.stringify(t.cmd), "--cwd", scratch, "--tool", tool, "--args", JSON.stringify(args), "--concurrency", String(concurrency), "--calls", calls];
const TEMPORAL_PATH = "/temporal/api/v1/namespaces/default/workflows?query=bench";
// `group` selects the targets; fan-out targets supply the WebSocket path
const SCENARIOS = [
  { name: "relay round trip, 1 pair", group: "viewer", argv: () => ["relay", "--pairs", "1", "--iters", n(5000, 1000)] },
  { name: "relay round trip, 16 pairs", group: "viewer", argv: () => ["relay", "--pairs", "16", "--iters", n(2000, 300)] },
  { name: "open-file POST+GET, 1 client", group: "viewer", argv: () => ["http", "--endpoint", "open-file", "--file", netFile, "--concurrency", "1", "--requests", n(20000, 1000)] },
  { name: "open-file POST+GET, 16 clients in lockstep", group: "viewer", argv: () => ["http", "--endpoint", "open-file", "--file", netFile, "--concurrency", "16", "--requests", n(64000, 4000)] },
  { name: "resolve-ref, 1 client", group: "viewer", argv: () => ["http", "--endpoint", "resolve-ref", "--file", netFile, "--concurrency", "1", "--requests", n(20000, 1000)] },
  { name: "resolve-ref, 16 clients", group: "viewer", argv: () => ["http", "--endpoint", "resolve-ref", "--file", netFile, "--concurrency", "16", "--requests", n(64000, 4000)] },
  { name: "collab fan-out, 50 peers x 1000 msgs", group: "collab", argv: (t) => ["fanout", "--path", t.wsPath, "--receivers", "50", "--messages", n(1000, 200)] },
  { name: "collab fan-out, 200 peers x 200 msgs", group: "collab", argv: (t) => ["fanout", "--path", t.wsPath, "--receivers", "200", "--messages", n(200, 50)] },
  { name: "GET / (index.html), 1 client", group: "static", argv: () => get("/", 1, n(20000, 1000)) },
  { name: "GET / (index.html), 16 clients", group: "static", argv: () => get("/", 16, n(64000, 4000)) },
  { name: `GET the JS bundle (${bundleKiB} KiB), 16 clients`, group: "static", built: true, argv: () => get(bundle, 16, n(8000, 800)) },
  { name: "GET /sample-net.json, 16 clients", group: "static", argv: () => get("/sample-net.json", 16, n(64000, 4000)) },
  // Fewer requests than the other rows: Vite's proxy closes every
  // connection, so through Vite each request opens two new TCP connections
  // (about 1k requests/s), and each leaves a socket in TIME_WAIT.
  { name: "GET /temporal/... (proxied), 1 client", group: "temporal", argv: () => get(TEMPORAL_PATH, 1, n(4000, 300)) },
  { name: "GET /temporal/... (proxied), 16 clients", group: "temporal", argv: () => get(TEMPORAL_PATH, 16, n(8000, 640)) },
  { name: "MCP petrus_inspect_document, 1 call at a time", group: "mcp", argv: mcp("petrus_inspect_document", { includeSchema: true }, 1, n(4000, 400)) },
  { name: "MCP petrus_inspect_document, 16 calls in flight", group: "mcp", argv: mcp("petrus_inspect_document", { includeSchema: true }, 16, n(16000, 1600)) },
  { name: "MCP petrus_status, 1 call at a time", group: "mcp", argv: mcp("petrus_status", {}, 1, n(4000, 400)) },
  { name: "cold start until the file and UI are served", group: "startup", argv: (t) => ["startup", "--cmd", JSON.stringify(t.cmd), "--cwd", scratch, "--rounds", n(10, 3)] },
].filter((s) => !only || only.split("|").some((o) => s.name.includes(o)));

if (SCENARIOS.some((s) => s.group === "static" || s.group === "startup") && !bundle) {
  console.error("the static and cold-start scenarios need the built UI: (cd upstream/petrus-viewer && pnpm build)");
  process.exit(1);
}

const runsOn = (t, s) => t.groups.includes(s.group) && (!t.match || s.name.includes(t.match)) && !(t.servesSource && s.built);
// kind: "server" (started here, measured over HTTP/WebSocket), "process"
// (the load client spawns the command; `start` gives the helper it talks to)
const TARGETS = [
  // --host serves /collab-ws, as `vite --host` does
  { name: "haskell (petrus)", groups: ["viewer", "collab", "static", "temporal"], wsPath: "/collab-ws", start: () => start(PETRUS, (p) => ["--no-open", "--strict-port", "--port", String(p), "--host", "localhost", "--ui-dir", DIST, ...rtsArgs], scratch) },
  // like for like with the bare Node baseline, which prints no relay lines
  { name: "haskell (petrus, relay log off)", groups: ["viewer"], match: "relay", start: () => start(PETRUS, (p) => ["--no-open", "--strict-port", "--port", String(p), ...rtsArgs], scratch, { PETRUS_RELAY_PERF: "0" }) },
  // serves the UI from source: no built bundle
  { name: "node (vite dev server)", groups: ["viewer", "static", "temporal"], servesSource: true, start: () => start(process.execPath, (p) => [path.join(VIEWER, "node_modules/vite/bin/vite.js"), "--port", String(p), "--strictPort"], VIEWER) },
  { name: "node (vite preview)", groups: ["static", "temporal"], start: () => start(process.execPath, (p) => [path.join(VIEWER, "node_modules/vite/bin/vite.js"), "preview", "--port", String(p), "--strictPort"], VIEWER) },
  { name: "node (bare baseline)", groups: ["viewer"], start: () => start(process.execPath, (p) => [path.join(HERE, "node-baseline.mjs"), VIEWER, String(p)], scratch) },
  { name: "haskell (petrus-collab)", groups: ["collab"], wsPath: "/", start: () => start(PETRUS_COLLAB, (p) => [String(p), ...rtsArgs], scratch) },
  { name: "node (server/collab.mjs)", groups: ["collab"], wsPath: "/", start: () => start(process.execPath, (p) => [path.join(VIEWER, "server/collab.mjs"), String(p)], VIEWER) },
  { name: "haskell (petrus-mcp)", groups: ["mcp"], kind: "process", cmd: [PETRUS_MCP, ...rtsArgs], start: agentRelay },
  { name: "node (server/mcp.mjs)", groups: ["mcp"], kind: "process", cmd: [process.execPath, path.join(VIEWER, "server/mcp.mjs")], start: agentRelay },
  { name: "haskell (petrus FILE)", groups: ["startup"], kind: "process", cmd: [PETRUS, "--no-open", "--ui-dir", DIST, ...rtsArgs, netFile], start: async () => ({}) },
  { name: "node (bin/petrus.mjs FILE)", groups: ["startup"], kind: "process", cmd: [process.execPath, path.join(VIEWER, "bin/petrus.mjs"), "--no-open", netFile], start: async () => ({}) },
].filter((t) => SCENARIOS.some((s) => runsOn(t, s)));

if (SCENARIOS.some((s) => s.group === "temporal")) await temporalBackend();
const servers = new Map();
for (const t of TARGETS) servers.set(t.name, await t.start());

const results = [];
for (const scenario of SCENARIOS) {
  const targets = TARGETS.filter((t) => runsOn(t, scenario));
  const runs = new Map(targets.map((t) => [t.name, []]));
  for (let rep = 0; rep < reps; rep++) {
    for (let k = 0; k < targets.length; k++) {
      const t = targets[(k + rep) % targets.length];
      const { host, port } = servers.get(t.name);
      runs.get(t.name).push(runBench([...scenario.argv(t), ...(port ? ["--host", host, "--port", String(port)] : [])]));
    }
  }
  // every target must do the same work: the same status counts in every run
  const work = (r) => (r.status200 === undefined ? null : `${r.status200}/${r.status204}/${r.statusOther}`);
  const works = new Set(targets.flatMap((t) => runs.get(t.name).map(work)));
  if (works.size > 1) {
    const perTarget = targets.map((t) => `${t.name}: ${[...new Set(runs.get(t.name).map(work))].join(", ")}`);
    console.error(`WORKLOAD DIFFERS between runs of "${scenario.name}" (200/204/other): ${perTarget.join("; ")}`);
    process.exitCode = 1;
  }
  for (const t of targets) {
    const rs = [...runs.get(t.name)].sort((a, b) => a.opsPerSec - b.opsPerSec);
    const r = rs[Math.floor(rs.length / 2)];
    results.push({ ...r, target: t.name, scenario: scenario.name, group: scenario.group, allOpsPerSec: runs.get(t.name).map((x) => x.opsPerSec) });
    const bytes = (r.bodyBytes === undefined ? "" : `  ${r.bodyBytes} B`) + (r.serverUserUsPerOp === undefined ? "" : `  server CPU ${r.serverUserUsPerOp}us user + ${r.serverSysUsPerOp}us sys per op`) + (r.reconnects ? `  ${r.reconnects} reconnects (Connection: close)` : "");
    console.error(`${t.name.padEnd(30)} ${scenario.name.padEnd(48)} ${String(r.opsPerSec).padStart(9)} ops/s  p50 ${r.p50us}us  p99 ${r.p99us}us${bytes}`);
  }
}
const isServer = (t) => (t.kind ?? "server") === "server";
const rss = Object.fromEntries(TARGETS.filter(isServer).map((t) => [t.name, rssMiB(servers.get(t.name).child.pid)]));
for (const t of TARGETS.filter(isServer)) await stop(servers.get(t.name));
for (const h of helpers.values()) await stop(await h);
fs.rmSync(scratch, { recursive: true, force: true });

// Markdown summary, one set of tables per group: one row per scenario, one
// column per target, and the ratio of the best Haskell target to the best
// Node target
const find = (t, s) => results.find((x) => x.target === t && x.scenario === s);
const peak = (r) => Math.max(...r.allOpsPerSec);
let md = "";
for (const group of [...new Set(SCENARIOS.map((s) => s.group))]) {
  const scenarios = SCENARIOS.filter((s) => s.group === group);
  const targets = TARGETS.filter((t) => scenarios.some((s) => runsOn(t, s)));
  const names = targets.map((t) => t.name);
  md += `### ${group}\n\n| scenario | ${names.join(" | ")} | Haskell / Node |\n|---|${names.map(() => "---:").join("|")}|---:|\n`;
  for (const s of scenarios) {
    const cells = names.map((t) => {
      const r = find(t, s.name);
      return r ? `${r.opsPerSec} (${r.p50us} / ${r.p99us})` : "";
    });
    const best = (prefix) => Math.max(0, ...names.filter((t) => t.startsWith(prefix)).map((t) => find(t, s.name)?.opsPerSec ?? 0));
    md += `| ${s.name} | ${cells.join(" | ")} | ${(best("haskell") / best("node")).toFixed(2)}x |\n`;
  }
  if (targets.some(isServer)) md += `| server RSS after run (MiB) | ${names.map((t) => rss[t] ?? "").join(" | ")} | |\n`;
  md += `\nCells: median ops/s over ${reps} interleaved runs (p50 / p99 latency in us).\n`;
  // on a shared machine the medians move with outside load; the best run of
  // each target is what it can do when the machine lets it
  md += `\n| scenario (best of ${reps}) | ${names.join(" | ")} | Haskell / Node |\n|---|${names.map(() => "---:").join("|")}|---:|\n`;
  for (const s of scenarios) {
    const vals = names.map((t) => (find(t, s.name) ? peak(find(t, s.name)) : null));
    const best = (prefix) => Math.max(0, ...names.map((t, i) => (t.startsWith(prefix) ? vals[i] ?? 0 : 0)));
    md += `| ${s.name} | ${vals.map((v) => v ?? "").join(" | ")} | ${(best("haskell") / best("node")).toFixed(2)}x |\n`;
  }
  // every round runs each target once, back to back; the ratio within a
  // round is the least exposed to the machine's drift between rounds
  md += `\n| scenario | Haskell / Node in each round (best of each side) | min |\n|---|---|---:|\n`;
  for (const s of scenarios) {
    const side = (prefix) => names.filter((t) => t.startsWith(prefix) && find(t, s.name)).map((t) => find(t, s.name).allOpsPerSec);
    const hs = side("haskell");
    const ns = side("node");
    if (!hs.length || !ns.length) continue;
    const ratios = Array.from({ length: reps }, (_, i) => Math.max(...hs.map((r) => r[i])) / Math.max(...ns.map((r) => r[i])));
    md += `| ${s.name} | ${ratios.map((r) => r.toFixed(2)).join(" ")} | ${Math.min(...ratios).toFixed(2)}x |\n`;
  }
  md += "\n";
}
console.log(md);
if (jsonOut) {
  const machine = `${os.cpus()[0].model} x${os.cpus().length}, ${os.platform()} ${os.release()}, node ${process.version}`;
  fs.writeFileSync(jsonOut, JSON.stringify({ machine, loadavg: os.loadavg(), reps, results, rss }, null, 2));
}
process.exit(process.exitCode ?? 0);

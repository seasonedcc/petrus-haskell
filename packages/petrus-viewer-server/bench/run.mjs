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
 *   haskell     petrus /collab-ws, and petrus-collab P
 *   node        node server/collab.mjs P
 *
 * All servers run for the whole benchmark and the runs are interleaved
 * (scenario by scenario, rep by rep, rotating which target goes first), so
 * load from other processes on the machine hits every target alike. The
 * reported run is the median by ops/s.
 *
 * Usage:
 *   node packages/petrus-viewer-server/bench/run.mjs [--bin-dir DIR] [--reps 5] [--quick]
 *        [--only SUBSTRING] [--rts "RTS OPTIONS"] [--json out.json]
 *
 * Without --bin-dir the executables are built with cabal (benchmarks enabled).
 * Requires `pnpm install` in upstream/petrus-viewer.
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
  if (binDir) return path.join(binDir, name);
  const target = name === "petrus-viewer-bench" ? "petrus-viewer-server:bench:petrus-viewer-bench" : `petrus-viewer-server:exe:${name}`;
  return execFileSync("cabal", ["list-bin", "--enable-benchmarks", target], { cwd: REPO, encoding: "utf8" }).trim();
}
if (!binDir) {
  execFileSync("cabal", ["build", "--enable-benchmarks", "petrus-viewer-server:exes", "petrus-viewer-server:benchmarks"], { cwd: REPO, stdio: "inherit" });
}
const BENCH = bin("petrus-viewer-bench");
const PETRUS = bin("petrus");
const PETRUS_COLLAB = bin("petrus-collab");

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "petrus-bench-"));
const netFile = path.join(scratch, "B.json");
fs.copyFileSync(path.join(VIEWER, "examples/sample-net.json"), netFile);

let nextPort = 47310;
const children = new Set();
process.on("exit", () => {
  for (const c of children) try { c.kill(); } catch {}
});

// resolves with the loopback address the server accepts connections on
function waitPort(port, ms = 30000) {
  const deadline = Date.now() + ms;
  const tryHost = (host) =>
    new Promise((resolve) => {
      const s = net.connect(port, host);
      s.once("connect", () => { s.destroy(); resolve(true); });
      s.once("error", () => { s.destroy(); resolve(false); });
    });
  return new Promise((resolve, reject) => {
    const attempt = async () => {
      for (const host of ["127.0.0.1", "::1"]) if (await tryHost(host)) return resolve(host);
      if (Date.now() > deadline) reject(new Error(`port ${port} never opened`));
      else setTimeout(attempt, 100);
    };
    attempt();
  });
}

async function start(cmd, argv, cwd, env = {}) {
  const port = nextPort++;
  const child = spawn(cmd, argv(port), { cwd, stdio: ["ignore", "ignore", "inherit"], env: { ...process.env, ...env } });
  children.add(child);
  const host = await waitPort(port);
  await new Promise((r) => setTimeout(r, 500));
  return { port, host, child };
}

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
// `group` selects the targets; fan-out targets supply the WebSocket path
const SCENARIOS = [
  { name: "relay round trip, 1 pair", group: "viewer", argv: () => ["relay", "--pairs", "1", "--iters", n(5000, 1000)] },
  { name: "relay round trip, 16 pairs", group: "viewer", argv: () => ["relay", "--pairs", "16", "--iters", n(2000, 300)] },
  { name: "open-file POST+GET, 1 client", group: "viewer", argv: () => ["http", "--endpoint", "open-file", "--file", netFile, "--concurrency", "1", "--requests", n(5000, 1000)] },
  { name: "open-file POST+GET, 16 clients", group: "viewer", argv: () => ["http", "--endpoint", "open-file", "--file", netFile, "--concurrency", "16", "--requests", n(32000, 4000)] },
  { name: "resolve-ref, 1 client", group: "viewer", argv: () => ["http", "--endpoint", "resolve-ref", "--file", netFile, "--concurrency", "1", "--requests", n(5000, 1000)] },
  { name: "resolve-ref, 16 clients", group: "viewer", argv: () => ["http", "--endpoint", "resolve-ref", "--file", netFile, "--concurrency", "16", "--requests", n(32000, 4000)] },
  { name: "collab fan-out, 50 peers x 1000 msgs", group: "collab", argv: (t) => ["fanout", "--path", t.wsPath, "--receivers", "50", "--messages", n(1000, 200)] },
  { name: "collab fan-out, 200 peers x 200 msgs", group: "collab", argv: (t) => ["fanout", "--path", t.wsPath, "--receivers", "200", "--messages", n(200, 50)] },
].filter((s) => !only || s.name.includes(only));

const runsOn = (t, s) => t.groups.includes(s.group) && (!t.match || s.name.includes(t.match));
const TARGETS = [
  { name: "haskell (petrus)", groups: ["viewer", "collab"], wsPath: "/collab-ws", start: () => start(PETRUS, (p) => ["--no-open", "--strict-port", "--port", String(p), ...rtsArgs], scratch) },
  // like for like with the bare Node baseline, which prints no relay lines
  { name: "haskell (petrus, relay log off)", groups: ["viewer"], match: "relay", start: () => start(PETRUS, (p) => ["--no-open", "--strict-port", "--port", String(p), ...rtsArgs], scratch, { PETRUS_RELAY_PERF: "0" }) },
  { name: "node (vite dev server)", groups: ["viewer"], start: () => start(process.execPath, (p) => [path.join(VIEWER, "node_modules/vite/bin/vite.js"), "--port", String(p), "--strictPort"], VIEWER) },
  { name: "node (bare baseline)", groups: ["viewer"], start: () => start(process.execPath, (p) => [path.join(HERE, "node-baseline.mjs"), VIEWER, String(p)], scratch) },
  { name: "haskell (petrus-collab)", groups: ["collab"], wsPath: "/", start: () => start(PETRUS_COLLAB, (p) => [String(p), ...rtsArgs], scratch) },
  { name: "node (server/collab.mjs)", groups: ["collab"], wsPath: "/", start: () => start(process.execPath, (p) => [path.join(VIEWER, "server/collab.mjs"), String(p)], VIEWER) },
].filter((t) => SCENARIOS.some((s) => runsOn(t, s)));

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
      runs.get(t.name).push(runBench([...scenario.argv(t), "--host", host, "--port", String(port)]));
    }
  }
  for (const t of targets) {
    const rs = [...runs.get(t.name)].sort((a, b) => a.opsPerSec - b.opsPerSec);
    const r = rs[Math.floor(rs.length / 2)];
    results.push({ ...r, target: t.name, scenario: scenario.name, allOpsPerSec: runs.get(t.name).map((x) => x.opsPerSec) });
    console.error(`${t.name.padEnd(26)} ${scenario.name.padEnd(38)} ${String(r.opsPerSec).padStart(9)} ops/s  p50 ${r.p50us}us  p99 ${r.p99us}us`);
  }
}
const rss = Object.fromEntries(TARGETS.map((t) => [t.name, rssMiB(servers.get(t.name).child.pid)]));
for (const t of TARGETS) await stop(servers.get(t.name));
fs.rmSync(scratch, { recursive: true, force: true });

// Markdown summary: one row per scenario, one column per target, and the
// ratio of the best Haskell server to the best Node server
const names = TARGETS.map((t) => t.name);
const find = (t, s) => results.find((x) => x.target === t && x.scenario === s);
const peak = (r) => Math.max(...r.allOpsPerSec);
let md = `| scenario | ${names.join(" | ")} | Haskell / Node |\n|---|${names.map(() => "---:").join("|")}|---:|\n`;
for (const s of SCENARIOS) {
  const cells = names.map((t) => {
    const r = find(t, s.name);
    return r ? `${r.opsPerSec} (${r.p50us} / ${r.p99us})` : "";
  });
  const best = (prefix) => Math.max(0, ...names.filter((t) => t.startsWith(prefix)).map((t) => find(t, s.name)?.opsPerSec ?? 0));
  md += `| ${s.name} | ${cells.join(" | ")} | ${(best("haskell") / best("node")).toFixed(2)}x |\n`;
}
md += `| server RSS after run (MiB) | ${names.map((t) => rss[t] ?? "").join(" | ")} | |\n`;
md += `\nCells: median ops/s over ${reps} interleaved runs (p50 / p99 latency in us).\n`;
// on a shared machine the medians move with outside load; the best run of
// each target is what it can do when the machine lets it
md += `\n| scenario (best of ${reps}) | ${names.join(" | ")} | Haskell / Node |\n|---|${names.map(() => "---:").join("|")}|---:|\n`;
for (const s of SCENARIOS) {
  const vals = names.map((t) => (find(t, s.name) ? peak(find(t, s.name)) : null));
  const best = (prefix) => Math.max(0, ...names.map((t, i) => (t.startsWith(prefix) ? vals[i] ?? 0 : 0)));
  md += `| ${s.name} | ${vals.map((v) => v ?? "").join(" | ")} | ${(best("haskell") / best("node")).toFixed(2)}x |\n`;
}
console.log(md);
if (jsonOut) {
  const machine = `${os.cpus()[0].model} x${os.cpus().length}, ${os.platform()} ${os.release()}, node ${process.version}`;
  fs.writeFileSync(jsonOut, JSON.stringify({ machine, reps, results, rss }, null, 2));
}
process.exit(0);

#!/usr/bin/env node
/**
 * Benchmark the Haskell viewer backend against the upstream Node backend
 * with one load client (petrus-viewer-bench) for both.
 *
 * Targets (each started on its own non-default port, stopped by PID):
 *   haskell     petrus --no-open --strict-port --port P   (relay perf log on, like Vite)
 *   node-vite   upstream `vite --port P --strictPort` (what bin/petrus.mjs runs)
 *   node-bare   bench/node-baseline.mjs: upstream endpoint + relay on bare
 *               node:http, no perf log (Node's best case)
 * Collaboration fan-out:
 *   haskell     petrus /collab-ws, and petrus-collab P
 *   node        node server/collab.mjs P
 *
 * Usage:
 *   node packages/petrus-viewer-server/bench/run.mjs [--bin-dir DIR] [--reps 3] [--quick] [--json out.json]
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
const reps = Number(opt("--reps", quick ? "1" : "3"));
const jsonOut = opt("--json", null);
let binDir = opt("--bin-dir", null);

function bin(name) {
  if (binDir) return path.join(binDir, name);
  const target = name === "petrus-viewer-bench" ? "petrus-viewer-server:bench:petrus-viewer-bench" : `petrus-viewer-server:exe:${name}`;
  return execFileSync("cabal", ["list-bin", target], { cwd: REPO, encoding: "utf8" }).trim();
}
if (!binDir) {
  execFileSync("cabal", ["build", "petrus-viewer-server:exes", "petrus-viewer-server:benchmarks"], { cwd: REPO, stdio: "inherit" });
}
const BENCH = bin("petrus-viewer-bench");
const PETRUS = bin("petrus");
const PETRUS_COLLAB = bin("petrus-collab");

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "petrus-bench-"));
const netFile = path.join(scratch, "B.json");
fs.copyFileSync(path.join(VIEWER, "examples/sample-net.json"), netFile);

let nextPort = 47310;
const children = new Set();
process.on("exit", () => { for (const c of children) try { c.kill(); } catch {} });

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

async function start(cmd, argv, cwd) {
  const port = nextPort++;
  const child = spawn(cmd, argv(port), { cwd, stdio: ["ignore", "ignore", "inherit"] });
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
  const out = execFileSync(BENCH, argv, { encoding: "utf8", timeout: 300000 });
  return JSON.parse(out.trim().split("\n").pop());
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

function measure({ port, host }, scenario) {
  const runs = [];
  for (let i = 0; i < reps; i++) runs.push(runBench([...scenario.argv, "--host", host, "--port", String(port)]));
  const pick = runs.find((r) => r.opsPerSec === median(runs.map((x) => x.opsPerSec)));
  return pick;
}

const n = (full, q) => String(quick ? q : full);
const HTTP_SCENARIOS = [
  { name: "relay round trip, 1 pair", argv: ["relay", "--pairs", "1", "--iters", n(5000, 1000)] },
  { name: "relay round trip, 16 pairs", argv: ["relay", "--pairs", "16", "--iters", n(2000, 300)] },
  { name: "open-file POST+GET, 1 client", argv: ["http", "--endpoint", "open-file", "--file", netFile, "--concurrency", "1", "--requests", n(5000, 1000)] },
  { name: "open-file POST+GET, 16 clients", argv: ["http", "--endpoint", "open-file", "--file", netFile, "--concurrency", "16", "--requests", n(32000, 4000)] },
  { name: "resolve-ref, 1 client", argv: ["http", "--endpoint", "resolve-ref", "--file", netFile, "--concurrency", "1", "--requests", n(5000, 1000)] },
  { name: "resolve-ref, 16 clients", argv: ["http", "--endpoint", "resolve-ref", "--file", netFile, "--concurrency", "16", "--requests", n(32000, 4000)] },
];
const FANOUT = (path_) => [
  { name: "collab fan-out, 50 peers x 1000 msgs", argv: ["fanout", "--path", path_, "--receivers", "50", "--messages", n(1000, 200)] },
  { name: "collab fan-out, 200 peers x 200 msgs", argv: ["fanout", "--path", path_, "--receivers", "200", "--messages", n(200, 50)] },
];

const TARGETS = [
  { name: "haskell (petrus)", scenarios: [...HTTP_SCENARIOS, ...FANOUT("/collab-ws")], start: () => start(PETRUS, (p) => ["--no-open", "--strict-port", "--port", String(p)], scratch) },
  { name: "node (vite dev server)", scenarios: HTTP_SCENARIOS, start: () => start(process.execPath, (p) => [path.join(VIEWER, "node_modules/vite/bin/vite.js"), "--port", String(p), "--strictPort"], VIEWER) },
  { name: "node (bare baseline)", scenarios: HTTP_SCENARIOS, start: () => start(process.execPath, (p) => [path.join(HERE, "node-baseline.mjs"), VIEWER, String(p)], scratch) },
  { name: "haskell (petrus-collab)", scenarios: FANOUT("/"), start: () => start(PETRUS_COLLAB, (p) => [String(p)], scratch) },
  { name: "node (server/collab.mjs)", scenarios: FANOUT("/"), start: () => start(process.execPath, (p) => [path.join(VIEWER, "server/collab.mjs"), String(p)], VIEWER) },
];

const results = [];
for (const target of TARGETS) {
  const server = await target.start();
  for (const scenario of target.scenarios) {
    const r = measure(server, scenario);
    results.push({ target: target.name, scenario: scenario.name, ...r });
    console.error(`${target.name.padEnd(26)} ${scenario.name.padEnd(38)} ${String(r.opsPerSec).padStart(9)} ops/s  p50 ${r.p50us}us  p99 ${r.p99us}us`);
  }
  const rss = rssMiB(server.child.pid);
  results.push({ target: target.name, scenario: "server RSS after run (MiB)", rss });
  await stop(server);
}
fs.rmSync(scratch, { recursive: true, force: true });

// Markdown summary: one row per scenario, one column group per target
const scenarios = [...new Set(results.filter((r) => r.opsPerSec !== undefined).map((r) => r.scenario))];
const targets = TARGETS.map((t) => t.name);
let md = `| scenario | ${targets.map((t) => `${t} ops/s (p50 / p99 us)`).join(" | ")} |\n|---|${targets.map(() => "---:").join("|")}|\n`;
for (const s of scenarios) {
  const cells = targets.map((t) => {
    const r = results.find((x) => x.target === t && x.scenario === s);
    return r ? `${r.opsPerSec} (${r.p50us} / ${r.p99us})` : "";
  });
  md += `| ${s} | ${cells.join(" | ")} |\n`;
}
md += `| server RSS after run (MiB) | ${targets.map((t) => results.find((x) => x.target === t && x.rss !== undefined)?.rss ?? "").join(" | ")} |\n`;
console.log(md);
if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ machine: `${os.cpus()[0].model} x${os.cpus().length}, ${os.platform()} ${os.release()}, node ${process.version}`, reps, results }, null, 2));
process.exit(0);

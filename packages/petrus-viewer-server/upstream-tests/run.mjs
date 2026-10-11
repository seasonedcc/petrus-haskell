#!/usr/bin/env node
/**
 * Run the upstream petrus-viewer server and integration tests against the
 * Haskell backend (packages/petrus-viewer-server).
 *
 * The test files are taken verbatim from the pinned submodule
 * (upstream/petrus-viewer/tests), copied into a scratch directory, and
 * rewritten only where they construct the backend under test: imports of
 * the in-process Node servers point at shims/haskell-backend.mjs, and spawns
 * of `node server/mcp.mjs`, `bin/petrus.mjs`, and `vite` spawn the Haskell
 * executables. Every rewrite must match the upstream text exactly, so an
 * upstream change fails loudly instead of silently testing something else.
 *
 * Usage:
 *   node packages/petrus-viewer-server/upstream-tests/run.mjs [options] [suite...]
 *
 * Options:
 *   --bin-dir <dir>     use these executables (petrus, petrus-mcp,
 *                       petrus-collab, petrus-viewer-oracle,
 *                       petrus-viewer-server-test) instead of
 *                       building with cabal
 *   --skip-playwright   skip the headless-browser suites
 *   --keep              keep the scratch directory
 *
 * Suites: relay, endpoints, url-cache, cli, mcp, mcp-haskell-relay, collab,
 * differential, wire, playwright, live, history (default: all).
 *
 * Requirements: pnpm install (and pnpm build for the browser suites) in
 * upstream/petrus-viewer; `npx playwright install chromium` for playwright;
 * the history suite also runs the pinned Python reference producer through
 * scripts/upstream-python.
 */

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE = path.resolve(HERE, "..");
const REPO = path.resolve(PACKAGE, "../..");
const VIEWER = path.join(REPO, "upstream/petrus-viewer");
const EXECUTABLES = ["petrus", "petrus-mcp", "petrus-collab", "petrus-viewer-oracle"];
// the test executable doubles as the Haskell observation producer
// (--chain-producer, test/ChainProducer.hs) for the history suite
const TEST_EXECUTABLE = "petrus-viewer-server-test";

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return null;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const flag = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
};
let binDir = opt("--bin-dir");
const skipPlaywright = flag("--skip-playwright");
const keep = flag("--keep");

const IMPORT_BACKEND = `import * as __haskell from "../shims/haskell-backend.mjs";\n`;

/**
 * Each suite: upstream files plus exact-text rewrites. `from` must occur;
 * every occurrence is replaced.
 */
const SUITES = {
  relay: {
    files: ["tests/bridgeVitePlugin.test.mjs"],
    rewrites: [
      ['import http from "node:http";', 'import http from "../shims/haskell-backend.mjs";'],
      ["function attachBridgeRelay(httpServer) {\n", "function attachBridgeRelay(httpServer) {\n  if (httpServer.isHaskellBackend) return null; // the relay runs in petrus\n"],
    ],
  },
  endpoints: {
    files: ["tests/openFileEndpoint.test.mjs", "tests/resolveRefEndpoint.test.mjs"],
    rewrites: [
      ['import http from "node:http";', 'import http from "../shims/haskell-backend.mjs";'],
      ['import { attachOpenFileEndpoint } from "../server/openFileEndpoint.mjs";', 'import { attachOpenFileEndpoint } from "../shims/haskell-backend.mjs";'],
    ],
  },
  "url-cache": {
    files: ["tests/urlCache.test.mjs"],
    rewrites: [['from "../server/urlCache.mjs";', 'from "../shims/haskell-url-cache.mjs";']],
  },
  cli: {
    files: ["tests/petrusCli.test.mjs"],
    prepend: IMPORT_BACKEND,
    rewrites: [["spawn(process.execPath, [CLI_PATH, ...args], {", "spawn(__haskell.PETRUS, [...args], {"]],
  },
  mcp: {
    files: ["tests/mcpServer.test.mjs"],
    prepend: IMPORT_BACKEND,
    rewrites: [['spawn(process.execPath, ["server/mcp.mjs"], {', "spawn(__haskell.PETRUS_MCP, [], {"]],
  },
  "mcp-haskell-relay": {
    files: ["tests/mcpServer.test.mjs"],
    prepend: IMPORT_BACKEND,
    rewrites: [
      ['spawn(process.execPath, ["server/mcp.mjs"], {', "spawn(__haskell.PETRUS_MCP, [], {"],
      ['import http from "node:http";', 'import http from "../shims/haskell-backend.mjs";'],
      ["function attachBridgeRelay(httpServer) {\n", "function attachBridgeRelay(httpServer) {\n  if (httpServer.isHaskellBackend) return null; // the relay runs in petrus\n"],
    ],
  },
  collab: {
    files: ["tests/collab-server.test.mjs"],
    prepend: `import { startCollabRelay as startRelay } from "../shims/haskell-backend.mjs";\n`,
    rewrites: [["function startRelay(port) {", "function startNodeRelay(port) {"]],
  },
  differential: {
    own: ["differential.test.mjs"],
  },
  wire: {
    own: ["ws-wire.test.mjs"],
  },
  playwright: {
    browser: true,
    files: ["tests/playwright/bridge-live.test.mjs"],
    prepend: `import * as __haskell from "../../shims/haskell-backend.mjs";\n`,
    rewrites: [
      [
        'spawn(process.execPath, ["./node_modules/.bin/vite", "--port", String(port)], {',
        'spawn(__haskell.PETRUS, ["--no-open", "--strict-port", "--port", String(port), "--ui-dir", __haskell.UI_DIR], {',
      ],
    ],
  },
  live: {
    browser: true,
    own: ["live-mcp.test.mjs"],
  },
  history: {
    browser: true,
    own: ["history-live.test.mjs"],
  },
};

function log(msg) {
  process.stdout.write(`${msg}\n`);
}

function resolveBinaries() {
  if (binDir) return path.resolve(binDir);
  log("building the Haskell executables (cabal build petrus-viewer-server:exes and its test)...");
  const test = `petrus-viewer-server:test:${TEST_EXECUTABLE}`;
  execFileSync("cabal", ["build", "-v0", "--enable-tests", "petrus-viewer-server:exes", test], { cwd: REPO, stdio: "inherit" });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "petrus-hs-bin-"));
  for (const [name, target] of [...EXECUTABLES.map((exe) => [exe, `petrus-viewer-server:exe:${exe}`]), [TEST_EXECUTABLE, test]]) {
    const bin = execFileSync("cabal", ["list-bin", "-v0", "--enable-tests", target], { cwd: REPO })
      .toString()
      .trim();
    fs.symlinkSync(bin, path.join(dir, name));
  }
  return dir;
}

function rewrite(text, suite, file) {
  let out = text;
  for (const [from, to] of suite.rewrites ?? []) {
    if (!out.includes(from)) throw new Error(`${file}: upstream text changed, rewrite not applicable:\n  ${from}`);
    out = out.split(from).join(to);
  }
  return (suite.prepend ?? "") + out;
}

function prepareWorkdir() {
  if (!fs.existsSync(path.join(VIEWER, "node_modules"))) {
    throw new Error(`run pnpm install in ${VIEWER} first`);
  }
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "petrus-hs-upstream-tests-"));
  fs.symlinkSync(path.join(VIEWER, "node_modules"), path.join(work, "node_modules"));
  fs.symlinkSync(path.join(VIEWER, "examples"), path.join(work, "examples"));
  fs.writeFileSync(path.join(work, "package.json"), JSON.stringify({ type: "module", private: true }));
  fs.mkdirSync(path.join(work, "shims"));
  for (const f of fs.readdirSync(path.join(HERE, "shims"))) {
    fs.copyFileSync(path.join(HERE, "shims", f), path.join(work, "shims", f));
  }
  fs.mkdirSync(path.join(work, "tests/playwright"), { recursive: true });
  return work;
}

function runSuite(work, name, suite, env) {
  const targets = [];
  for (const file of suite.files ?? []) {
    const source = fs.readFileSync(path.join(VIEWER, file), "utf8");
    const target = path.join(work, file.replace(/\.test\.mjs$/, `.${name}.test.mjs`));
    fs.writeFileSync(target, rewrite(source, suite, file));
    targets.push(target);
  }
  for (const file of suite.own ?? []) {
    const target = path.join(work, "tests", file);
    fs.copyFileSync(path.join(HERE, file), target);
    targets.push(target);
  }
  const r = spawnSync(process.execPath, ["--test", "--test-reporter=tap", "--test-concurrency=1", ...targets], {
    cwd: work,
    env,
    encoding: "utf8",
    maxBuffer: 1 << 28,
  });
  const tap = (r.stdout ?? "") + (r.stderr ?? "");
  fs.writeFileSync(path.join(work, `${name}.tap`), tap);
  const count = (key) => Number((tap.match(new RegExp(`^# ${key} (\\d+)`, "m")) ?? [])[1] ?? 0);
  const failures = [...tap.matchAll(/^\s*not ok \d+ - (.*)$/gm)].map((m) => m[1]);
  return { tests: count("tests"), pass: count("pass"), fail: count("fail"), failures, status: r.status };
}

function main() {
  const wanted = args.length ? args : Object.keys(SUITES);
  for (const w of wanted) if (!SUITES[w]) throw new Error(`unknown suite ${w}`);
  binDir = resolveBinaries();
  const uiDir = path.join(VIEWER, "dist");
  const work = prepareWorkdir();
  const env = {
    ...process.env,
    PETRUS_HS_BIN_DIR: binDir,
    PETRUS_HS_UI_DIR: uiDir,
    PETRUS_HS_VIEWER_DIR: VIEWER,
    PETRUS_HS_PACKAGE_DIR: PACKAGE,
    PETRUS_HS_SPEC_DIR: path.join(REPO, "upstream/petrus/spec"),
  };
  log(`scratch directory: ${work}`);
  let failed = 0;
  const rows = [];
  for (const name of wanted) {
    const suite = SUITES[name];
    if (suite.browser && skipPlaywright) {
      rows.push([name, "skipped"]);
      continue;
    }
    if (suite.browser && !fs.existsSync(path.join(uiDir, "index.html"))) {
      throw new Error(`run pnpm build in ${VIEWER} first (needed by ${name})`);
    }
    const res = runSuite(work, name, suite, env);
    const ok = res.fail === 0 && res.status === 0 && res.tests > 0;
    if (!ok) failed++;
    rows.push([name, `${ok ? "PASS" : "FAIL"}  ${res.pass}/${res.tests} passed`]);
    log(`${ok ? "PASS" : "FAIL"} ${name}: ${res.pass}/${res.tests} passed`);
    for (const f of res.failures) log(`    not ok - ${f}`);
  }
  log("");
  for (const [name, result] of rows) log(`${name.padEnd(20)} ${result}`);
  if (keep || failed) log(`TAP logs: ${work}/*.tap`);
  else fs.rmSync(work, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

main();

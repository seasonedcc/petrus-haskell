/**
 * Haskell-backend shims for the upstream petrus-viewer tests.
 *
 * The upstream server tests build their servers in process (a Node
 * `http.Server` with the relay / open-file code attached). The runner
 * rewrites their imports to this module, so the same test bodies talk to
 * the Haskell executables instead:
 *
 *   - `createServer()` returns an object with the `http.Server` methods the
 *     tests use (`listen`, `address`, `close`); `listen` starts `petrus`
 *     (agent relay, open-file and resolve-ref endpoints, ...) on a free port;
 *   - `attachOpenFileEndpoint(server, file)` records the initial file, passed
 *     to `petrus` as PETRUS_OPEN_FILE (exactly how the Vite plugin gets it);
 *   - `startCollabRelay(port)` starts `petrus-collab <port>`.
 *
 * Executables come from PETRUS_HS_BIN_DIR (set by run.mjs).
 */

import { spawn, execFileSync } from "node:child_process";
import path from "node:path";

const BIN = process.env.PETRUS_HS_BIN_DIR;
if (!BIN) throw new Error("PETRUS_HS_BIN_DIR is not set (run through upstream-tests/run.mjs)");

export const PETRUS = path.join(BIN, "petrus");
export const PETRUS_MCP = path.join(BIN, "petrus-mcp");
export const PETRUS_COLLAB = path.join(BIN, "petrus-collab");
// the test executable answers oracle calls with --oracle (test/Oracle.hs)
export const ORACLE = path.join(BIN, "petrus-viewer-server-test");
export const UI_DIR = process.env.PETRUS_HS_UI_DIR;

class HaskellViewerServer {
  constructor() {
    this.isHaskellBackend = true;
    this.initialFile = null;
    this.sourceUrl = null;
    this.proc = null;
    this.port = null;
  }

  listen(port, _host, callback) {
    const env = { ...process.env };
    delete env.PETRUS_OPEN_FILE;
    delete env.PETRUS_SOURCE_URL;
    if (this.initialFile) env.PETRUS_OPEN_FILE = this.initialFile;
    if (this.sourceUrl) env.PETRUS_SOURCE_URL = this.sourceUrl;
    const args = ["--no-open", "--strict-port", "--port", String(port || 0)];
    if (UI_DIR) args.push("--ui-dir", UI_DIR);
    this.proc = spawn(PETRUS, args, { env, stdio: ["ignore", "pipe", "inherit"] });
    let output = "";
    const onData = (chunk) => {
      output += chunk.toString();
      const match = output.match(/Local:\s+http:\/\/localhost:(\d+)/);
      if (match) {
        this.port = Number(match[1]);
        this.proc.stdout.off("data", onData);
        this.proc.stdout.resume(); // keep draining relay perf logs
        callback?.();
      }
    };
    this.proc.stdout.on("data", onData);
    this.proc.on("exit", (code) => {
      if (this.port === null) throw new Error(`petrus exited (${code}) before listening: ${output}`);
    });
    return this;
  }

  address() {
    return { port: this.port, address: "127.0.0.1", family: "IPv4" };
  }

  close(callback) {
    if (!this.proc || this.proc.exitCode !== null || this.proc.signalCode !== null) {
      callback?.();
      return this;
    }
    this.proc.once("exit", () => callback?.());
    this.proc.kill("SIGTERM");
    return this;
  }
}

export function createServer() {
  return new HaskellViewerServer();
}

export default { createServer };

export function attachOpenFileEndpoint(server, initialFile = null, sourceUrl = null) {
  if (!server.isHaskellBackend) throw new Error("expected the Haskell server shim");
  server.initialFile = initialFile;
  server.sourceUrl = sourceUrl;
}

/** Start `petrus-collab <port>` and return once it accepts connections. */
export function startCollabRelay(port) {
  const proc = spawn(PETRUS_COLLAB, [String(port)], { stdio: "ignore" });
  // The upstream tests construct the relay synchronously and connect right
  // away, so block until the port answers.
  execFileSync(process.execPath, [
    "-e",
    `const net = require("node:net");
     const deadline = Date.now() + 10000;
     (function attempt() {
       const s = net.connect(${Number(port)}, "localhost");
       s.on("connect", () => { s.destroy(); process.exit(0); });
       s.on("error", () => {
         if (Date.now() > deadline) process.exit(1);
         setTimeout(attempt, 20);
       });
     })();`,
  ]);
  return {
    close() {
      if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGTERM");
    },
  };
}

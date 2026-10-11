
import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
export const VERSION = "0.12.0";
export const PETRUS_FAKE = true;
export class RealFSProvider { constructor(root) { this.root = root; } }
export function createHttpHooks() { return { httpHooks: { qualified: true }, env: {} }; }
export function resolveImageSelector(selector) {
  if (selector !== "fake-image") throw new Error("wrong image");
  return { assetDir: selector };
}
export function loadGuestAssets(assetDir) {
  return {
    kernelPath: path.join(assetDir, "kernel"),
    initrdPath: path.join(assetDir, "initrd"),
    rootfsPath: path.join(assetDir, "rootfs"),
  };
}
export class VM {
  static async create(options) {
    const assets = options.sandbox.imagePath;
    if (!assets || typeof assets !== "object" || path.dirname(assets.rootfsPath) !== "fake-image" || !options.sandbox.netEnabled) throw new Error("wrong image");
    if (!options.httpHooks.qualified) throw new Error("wrong hooks");
    const vm = new VM(options.vfs.mounts["/petrus-transfer"].root);
    await vm.start();
    return vm;
  }
  constructor(root) {
    this.root = root;
    this.child = null;
    this.started = false;
    this.guest = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "fake-codex-guest-"));
  }
  async start() { this.started = true; }
  exec(argv, options) {
    if (!this.started) throw new Error("sandbox stopped");
    const privateRoot = path.join(this.guest, ".petrus-private");
    const mapped = value => value === "/workspace" || value.startsWith("/workspace/")
      ? value.replace("/workspace", this.guest)
      : value === "/tmp/.petrus-private" || value.startsWith("/tmp/.petrus-private/")
      ? value.replace("/tmp/.petrus-private", privateRoot)
      : value === "/petrus-transfer" || value.startsWith("/petrus-transfer/")
      ? value.replace("/petrus-transfer", this.root)
      : value === "/usr/local/bin/codex" ? __CODEX__
      : value === "/bin/uname" ? __UNAME__ : value;
    const cwd = options.cwd ? mapped(options.cwd) : this.root;
    let translated = argv.map(value => mapped(value).replace?.("R='/tmp/.petrus-private'", `R='${privateRoot}'`) ?? mapped(value));
    if (translated[0] === "/bin/tar" && !fs.existsSync(translated[0])) translated[0] = "/usr/bin/tar";
    const env = Object.fromEntries(Object.entries(options.env ?? {}).map(([key, value]) => [key, mapped(value)]));
    if (argv.includes("cancel-me")) fs.writeFileSync(__STARTED__, "started");
    this.child = childProcess.spawn(translated[0], translated.slice(1), { cwd, env, detached: true });
    if (Buffer.isBuffer(options.stdin)) this.child.stdin.end(options.stdin); else this.child.stdin.end();
    const child = this.child, queued = [], waiters = [];
    let finished = false;
    const emit = value => { const waiter = waiters.shift(); waiter ? waiter(value) : queued.push(value); };
    child.stdout.on("data", data => emit({ value: { stream: "stdout", data }, done: false }));
    child.stderr.on("data", data => emit({ value: { stream: "stderr", data }, done: false }));
    child.on("close", () => { finished = true; emit({ done: true }); });
    const result = new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("close", code => code === null ? reject(new Error("VM closed")) : resolve({ exitCode: code }));
    });
    return { result, output() { return { [Symbol.asyncIterator]() { return this; }, next() {
      if (queued.length) return Promise.resolve(queued.shift());
      if (finished) return Promise.resolve({ done: true });
      return new Promise(resolve => waiters.push(resolve));
    } }; } };
  }
  async close() {
    if (this.child && this.child.exitCode === null) {
      const child = this.child;
      const closed = new Promise(resolve => child.once("close", resolve));
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
      await closed;
    }
    fs.rmSync(this.guest, { recursive: true, force: true });
  }
}

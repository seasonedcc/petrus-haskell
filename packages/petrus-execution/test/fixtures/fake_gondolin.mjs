
import childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
export const VERSION = "0.12.0";
export const PETRUS_FAKE = true;
export class RealFSProvider { constructor(root) { this.root = root; } }
export function createHttpHooks() { return { httpHooks: { fakeHooks: true }, env: {} }; }
export function resolveImageSelector(selector) {
  if (!["fake-image", "fake-image-slow-probe", "fake-image-custom-store"].includes(selector)) {
    throw new Error(`unknown local image under ${process.env.GONDOLIN_IMAGE_STORE ?? process.env.XDG_CACHE_HOME}`);
  }
  if (selector === "fake-image-custom-store") {
    const store = process.env.GONDOLIN_IMAGE_STORE
      ?? (process.env.XDG_CACHE_HOME ? path.join(process.env.XDG_CACHE_HOME, "gondolin", "images") : undefined);
    if (!store || !path.isAbsolute(store)) throw new Error("missing custom image store");
    return { assetDir: path.join(store, "objects", selector) };
  }
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
    if (!assets || typeof assets !== "object") throw new Error("image was not resolved locally");
    const image = path.basename(path.dirname(assets.rootfsPath));
    if (!["fake-image", "fake-image-slow-probe", "fake-image-custom-store"].includes(image)) throw new Error("wrong VM options");
    const expected = JSON.stringify({ sandbox: { vmm: "qemu", imagePath: assets, netEnabled: true } });
    if (JSON.stringify({ sandbox: options.sandbox }) !== expected) throw new Error("wrong VM options");
    if (!options.httpHooks.fakeHooks || Object.keys(options).sort().join() !== "httpHooks,sandbox,vfs") throw new Error("wrong VM options");
    const vm = new VM(options.vfs.mounts["/petrus-transfer"].root, image);
    const sessions = process.env.GONDOLIN_SESSIONS_DIR;
    if (!sessions || !path.isAbsolute(sessions)) throw new Error("missing isolated session registry");
    fs.mkdirSync(sessions, { recursive: true });
    vm.registration = path.join(sessions, "fake-session.json");
    fs.writeFileSync(vm.registration, "registered");
    await vm.start();
    return vm;
  }
  constructor(root, image) {
    this.root = root; this.child = null; this.started = false;
    this.image = image;
    this.guest = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "fake-guest-"));
  }
  async start() { this.started = true; }
  exec(argv, options) {
    if (!this.started) throw new Error("sandbox is stopped");
    const privateRoot = path.join(this.guest, ".petrus-private");
    const mapped = value => value === "/workspace" || value.startsWith("/workspace/")
      ? value.replace("/workspace", this.guest)
      : value === "/tmp/.petrus-private" || value.startsWith("/tmp/.petrus-private/")
      ? value.replace("/tmp/.petrus-private", privateRoot)
      : value === "/petrus-transfer" || value.startsWith("/petrus-transfer/")
      ? value.replace("/petrus-transfer", this.root) : value;
    const cwd = options.cwd ? mapped(options.cwd) : this.root;
    if (options.stdout !== "pipe" || options.stderr !== "pipe" || !Number.isFinite(options.windowBytes)) throw new Error("wrong exec options");
    const translated = argv.map(value => mapped(value).replace?.("R='/tmp/.petrus-private'", `R='${privateRoot}'`) ?? mapped(value));
    if (translated[0] === "/bin/tar" && !fs.existsSync(translated[0])) translated[0] = "/usr/bin/tar";
    const env = Object.fromEntries(Object.entries(options.env ?? {}).map(([key, value]) => [key, mapped(value)]));
    if (this.image === "fake-image-slow-probe" && translated.at(-1) === "probe") {
      this.child = childProcess.spawn("/bin/sh", ["-c", 'sleep 0.2; exec "$@"', "slow-probe", ...translated], { cwd, env, detached: true });
    } else {
      this.child = childProcess.spawn(translated[0], translated.slice(1), { cwd, env, detached: true });
    }
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
      const rows = childProcess.execFileSync("/bin/ps", ["-axo", "pid=,ppid="], { encoding: "utf8" });
      const children = new Map();
      for (const line of rows.split("\n")) {
        const [pid, ppid] = line.trim().split(/\s+/).map(Number);
        if (Number.isInteger(pid) && Number.isInteger(ppid)) children.set(pid, ppid);
      }
      const descendants = [], pending = [child.pid];
      while (pending.length) {
        const parent = pending.pop();
        for (const [pid, ppid] of children) if (ppid === parent) { descendants.push(pid); pending.push(pid); }
      }
      for (const pid of descendants.reverse()) try { process.kill(pid, "SIGKILL"); } catch {}
      try { child.kill("SIGKILL"); } catch {}
      await closed;
    }
    fs.rmSync(this.registration, { force: true });
    fs.rmSync(this.guest, { recursive: true, force: true });
  }
}

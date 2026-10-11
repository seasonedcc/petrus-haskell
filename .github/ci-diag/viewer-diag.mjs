// TEMPORARY CI diagnostic: what the browser does in its first seconds against
// the Haskell petrus backend. Usage (from upstream/petrus-viewer):
//   node viewer-diag.mjs PETRUS_BINARY UI_DIR
import { chromium } from "playwright";
import { spawn } from "node:child_process";

const [petrusBin, uiDir] = process.argv.slice(2);
const t0 = Date.now();
const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(2).padStart(6)}s`, ...a);

const proc = spawn(petrusBin, ["--no-open", "--strict-port", "--port", "0", "--ui-dir", uiDir], {
  stdio: ["ignore", "pipe", "pipe"],
});
proc.stderr.on("data", (c) => log("petrus stderr:", String(c).trim()));
const port = await new Promise((resolve, reject) => {
  let out = "";
  proc.stdout.on("data", (c) => {
    out += String(c);
    log("petrus stdout:", String(c).trim());
    const m = out.match(/http:\/\/(?:localhost|127\.0\.0\.1):(\d+)/);
    if (m) resolve(Number(m[1]));
  });
  proc.on("exit", (code) => reject(new Error(`petrus exited ${code}: ${out}`)));
});
log("port", port);

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
page.on("console", (m) => log("console", m.type(), m.text().slice(0, 300)));
page.on("pageerror", (e) => log("pageerror", e.message.slice(0, 300)));
page.on("requestfailed", (r) => log("requestfailed", r.url().slice(0, 150), r.failure()?.errorText));
page.on("requestfinished", (r) => log("requestfinished", r.url().slice(0, 150)));
page.on("websocket", (ws) => {
  log("websocket open", ws.url());
  ws.on("framesent", (f) => log("ws sent", String(f.payload).slice(0, 120)));
  ws.on("framereceived", (f) => log("ws recv", String(f.payload).slice(0, 120)));
  ws.on("socketerror", (e) => log("ws error", e));
  ws.on("close", () => log("ws close", ws.url()));
});
for (const host of ["localhost", "127.0.0.1"]) {
  log("goto", host);
  try {
    await page.goto(`http://${host}:${port}`, { waitUntil: "networkidle", timeout: 20000 });
    log("networkidle reached");
  } catch (e) {
    log("goto failed", e.message.split("\n")[0]);
  }
  for (let i = 0; i < 25; i++) {
    const title = await page.evaluate(() => document.querySelector(".pi-status-badge")?.getAttribute("title") ?? null);
    if (i % 5 === 0 || title?.includes("connected")) log("badge", title);
    if (title?.includes("connected") && !title.includes("disconnected")) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
}
await browser.close();
proc.kill("SIGTERM");
log("done");
process.exit(0);

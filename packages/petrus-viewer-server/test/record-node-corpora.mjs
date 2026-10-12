#!/usr/bin/env node
/**
 * Records the results of the two Node-recorded corpora of the test suite
 * from Node itself (Node 22, the version CI and the upstream viewer use):
 *
 *   test/fixtures/json-parse-v8.json   (JsonSpec) [input, {"ok": JSON.stringify(JSON.parse(input))}
 *                                                         or {"error": the SyntaxError's message}]
 *   test/fixtures/url-whatwg-node.json (UrlSpec)  [ref, base, {"ok": new URL(ref, base).href}
 *                                                             or {"error": the TypeError's message}]
 *
 * The inputs are the committed ones: they were generated once (random
 * documents and refs), and this script keeps them and recomputes every
 * result, so a result that is not Node's own (one edited by hand, or recorded
 * by another Node) is caught.
 *
 * Usage (from anywhere; needs no `pnpm install`):
 *
 *   node packages/petrus-viewer-server/test/record-node-corpora.mjs           # rewrite both fixtures
 *   node packages/petrus-viewer-server/test/record-node-corpora.mjs --check   # fail if either differs
 *   node packages/petrus-viewer-server/test/record-node-corpora.mjs OUTDIR    # write them to OUTDIR
 *
 * scripts/check-corpora runs the OUTDIR form and compares the bytes.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");
const check = process.argv.includes("--check");
const outDir = process.argv.slice(2).find((a) => !a.startsWith("--"));

function outcome(f) {
  try {
    return { ok: f() };
  } catch (e) {
    return { error: e.message };
  }
}

const corpora = {
  "json-parse-v8.json": ([input]) => [input, outcome(() => JSON.stringify(JSON.parse(input)))],
  "url-whatwg-node.json": ([ref, base]) => [ref, base, outcome(() => new URL(ref, base).href)],
};

let failed = false;
for (const [name, record] of Object.entries(corpora)) {
  const file = path.join(FIXTURES, name);
  const committed = fs.readFileSync(file, "utf8");
  const fresh = "[\n" + JSON.parse(committed).map((c) => JSON.stringify(record(c))).join(",\n") + "\n]\n";
  if (check) {
    if (fresh !== committed) {
      const a = committed.split("\n");
      const b = fresh.split("\n");
      const line = a.findIndex((l, i) => l !== b[i]);
      console.error(`${name}: differs from Node ${process.version} at line ${line + 1}:\n  committed: ${a[line]}\n  Node:      ${b[line]}`);
      failed = true;
    } else {
      console.log(`${name}: matches Node ${process.version}`);
    }
  } else {
    fs.writeFileSync(outDir ? path.join(outDir, name) : file, fresh);
  }
}
process.exit(failed ? 1 : 0);

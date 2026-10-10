// Open and save net files the way petrus-viewer does, using the viewer's own
// TypeScript (upstream/petrus-viewer/src/utils), so the corpus holds files
// exactly as the viewer writes them.
//
// Opening is fileIO.ts parseNetFile (JSON.parse, the fileVersion check,
// flatToNested, unprefixViewState); saving is fileIO.ts writeToHandle
// (buildFlatNet, then compactJson with FLAT_NET_KEY_ORDER plus "\n").
// fileIO.ts itself imports browser-only modules, so its two short bodies are
// repeated here verbatim.
//
// Input (stdin): a JSON array of {"name", "text"}. Output (stdout): a JSON
// object mapping each name to {"saved": text} or {"error": message}.
//
// Needs Node 22.18 or later (TypeScript type stripping), from the
// repository root:
//
//   node packages/petrus-engine-file/differential/viewer_resave.mjs < in.json

import { register } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

// The viewer's sources import siblings without extensions (Vite resolves
// them); resolve "./netpath" to "./netpath.ts" the same way.
register(
  "data:text/javascript," +
    encodeURIComponent(`
      export async function resolve(specifier, context, next) {
        if (specifier.startsWith(".") && !/\\.[a-z]+$/.test(specifier)) {
          return next(specifier + ".ts", context);
        }
        return next(specifier, context);
      }
    `),
);

const here = path.dirname(fileURLToPath(import.meta.url));
const utils = path.resolve(here, "../../../upstream/petrus-viewer/src/utils");
const load = (name) => import(pathToFileURL(path.join(utils, name)).href);

const { compactJson } = await load("compactJson.ts");
const { buildFlatNet, FLAT_NET_KEY_ORDER } = await load("flatFormat.ts");
const { flatToNested, unprefixViewState } = await load("flatRead.ts");

// fileIO.ts parseNetFile
function parseNetFile(raw) {
  const parsed = JSON.parse(raw);

  if (parsed.fileVersion !== "2" || !parsed.net) {
    throw new Error('Invalid file: expected fileVersion "2" flat format with a "net" key');
  }

  const flatNet = parsed;
  const netSchema = flatToNested(flatNet);
  const viewState = flatNet.viewState ? unprefixViewState(flatNet.viewState) : null;
  return {
    fileVersion: "2",
    netSchema,
    viewState,
  };
}

// fileIO.ts writeToHandle, without the handle
function serialize(data) {
  const flatNet = buildFlatNet(data);
  return compactJson(flatNet, 0, FLAT_NET_KEY_ORDER) + "\n";
}

const inputs = JSON.parse(readFileSync(0, "utf8"));
const out = {};
for (const { name, text } of inputs) {
  try {
    out[name] = { saved: serialize(parseNetFile(text)) };
  } catch (error) {
    out[name] = { error: String(error && error.message) };
  }
}
process.stdout.write(JSON.stringify(out) + "\n");

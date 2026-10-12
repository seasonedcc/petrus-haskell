/**
 * `src/agent/protocol.ts` with `parseAgentMessage` answered by the Haskell
 * port (Petrus.Viewer.Agent.Protocol) through the test executable's
 * oracle mode (`petrus-viewer-server-test --oracle`). Everything else (the constructors, `serializeAgentMessage`,
 * `createProtocolFixtures`, `selectedEdgeToRef`) is the upstream module
 * itself: it builds the messages the browser side sends, and the browser
 * side stays TypeScript.
 *
 * The input travels as JSON text. JavaScript's Infinity, which JSON has no
 * literal for, is written as 1e400 (JSON.parse reads that back as
 * Infinity, and so does the Haskell parser).
 */

import { callOracle } from "./haskell-url-cache.mjs";

export * from "../src/agent/protocol.ts";

const POSITIVE = "\u0000petrus:+Infinity\u0000";
const NEGATIVE = "\u0000petrus:-Infinity\u0000";

function toJsonText(input) {
  const text = JSON.stringify(input, (_key, value) => {
    if (typeof value !== "number" || Number.isFinite(value)) return value;
    if (Number.isNaN(value)) throw new Error("haskell-protocol shim: NaN has no JSON spelling");
    return value > 0 ? POSITIVE : NEGATIVE;
  });
  return text
    .split(JSON.stringify(POSITIVE)).join("1e400")
    .split(JSON.stringify(NEGATIVE)).join("-1e400");
}

export function parseAgentMessage(input) {
  const [result] = callOracle([["parseAgentMessage", toJsonText(input)]]);
  if ("error" in result) throw new Error(result.error);
  return result.ok;
}

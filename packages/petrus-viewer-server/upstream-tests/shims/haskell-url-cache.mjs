/**
 * `server/urlCache.mjs`, answered by the Haskell port (Petrus.Viewer.UrlCache
 * and Petrus.Viewer.Url) through the test executable's oracle mode
 * (`petrus-viewer-server-test --oracle`, test/Oracle.hs).
 */

import { execFileSync } from "node:child_process";
import { ORACLE } from "./haskell-backend.mjs";

export function callOracle(calls) {
  const out = execFileSync(ORACLE, ["--oracle"], { input: JSON.stringify(calls), maxBuffer: 1 << 28 });
  return JSON.parse(out.toString("utf8"));
}

function call(name, ...args) {
  const [result] = callOracle([[name, ...args]]);
  if ("error" in result) throw new TypeError(result.error);
  return result.ok;
}

export const normalizeGitHubUrl = (url) => call("normalizeGitHubUrl", url);
export const slugifyUrl = (url) => call("slugifyUrl", url);
export const getCacheDir = (slug) => call("getCacheDir", slug);
export const cacheRelativePath = (url) => call("cacheRelativePath", url);
export const cacheFile = (slug, relativePath, content) => call("cacheFile", slug, relativePath, content);

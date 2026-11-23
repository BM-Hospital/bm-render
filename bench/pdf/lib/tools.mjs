// Paths of bench/pdf and of the external tools setup.mjs downloads (tools.json).
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PDF_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const ROOT = path.resolve(PDF_DIR, "..", "..");
export const TOOLS_DIR = path.join(PDF_DIR, "tools");
export const OUT_DIR = path.join(ROOT, "bench", "out", "pdf");

let manifest;
export const toolsManifest = () => (manifest ??= JSON.parse(readFileSync(path.join(PDF_DIR, "tools.json"), "utf8")));

function walk(dir, name, depth = 0) {
  if (depth > 6 || !existsSync(dir)) return null;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if ((e.isFile() || e.isSymbolicLink()) && e.name.toLowerCase() === name.toLowerCase()) return path.join(dir, e.name);
  }
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory() && e.name !== "download") { const r = walk(path.join(dir, e.name), name, depth + 1); if (r) return r; }
  }
  return null;
}

const cache = new Map();
/** Absolute path of binary `bin` of tool `name` (tools.json), or null when setup has not installed it. */
export function findBin(name, bin) {
  const key = name + "/" + bin;
  if (cache.has(key)) return cache.get(key);
  const t = toolsManifest().tools[name];
  const dir = path.join(TOOLS_DIR, name);
  let p = null;
  if (t && existsSync(path.join(dir, ".ok.json"))) {
    const rel = t.bin[bin];
    if (rel && existsSync(path.join(dir, rel))) p = path.join(dir, rel);
    else p = walk(dir, path.basename(rel || bin + (process.platform === "win32" ? ".exe" : "")));
    // (tools.json pins the Windows builds; elsewhere the same tool, installed by other means into
    // bench/pdf/tools/<name>/, is the binary without the .exe suffix)
    if (!p && process.platform !== "win32" && rel) p = walk(dir, path.basename(rel).replace(/\.exe$/i, ""));
  }
  cache.set(key, p);
  return p;
}

/** Version of an installed tool as recorded by setup (tools.json + .ok.json). */
export function toolInfo(name) {
  const t = toolsManifest().tools[name];
  const ok = path.join(TOOLS_DIR, name, ".ok.json");
  return t ? { version: t.version, installed: existsSync(ok), sha256: t.sha256 } : null;
}

export function dirSize(dir) {
  let n = 0;
  if (!existsSync(dir)) return 0;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    n += e.isDirectory() ? dirSize(p) : statSync(p).size;
  }
  return n;
}

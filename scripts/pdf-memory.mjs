#!/usr/bin/env node
// Live memory of a long flowing document (takumi-pdf `memory_tests.rs`): 700 sections with no forced page break,
// a 320x240 page with 24px margins and a `Page n of N` header, so the document is laid out twice (one pass counts
// the pages, one draws them). In each pass, the live bytes once page 200 is laid out must stay within 10 % of the
// live bytes once page 50 is: the memory a long document holds must not grow with the pages behind it.
//
// Live bytes are the native addon's allocation counter (memoryTrace checkpoints, src/memtrace.zig), not RSS or the
// wasm memory size. Each render runs in a child process of its own (a fresh heap).
//
//   node scripts/pdf-memory.mjs              the invariant, and peak / live figures
//   node scripts/pdf-memory.mjs --stress     also the stress document at 1, 10, 100 and 500 pages (peak, live, time, size)
//   node scripts/pdf-memory.mjs --stress --sizes=100,500     other page counts of the stress document
//   BM_PDF_CHUNKS=off node scripts/pdf-memory.mjs   the document laid out whole (for comparison; fails)
//
// Exit code 1 when the invariant fails or the native addon is not built (node scripts/build-native.mjs).
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const EARLY = 50;
const LATE = 200;
const MiB = (b) => (b / 2 ** 20).toFixed(2) + " MiB";

function addonFile() {
  const dir = path.join(ROOT, "native", "dist");
  const name = existsSync(dir) ? readdirSync(dir).find((d) => d.startsWith(`${process.platform}-${process.arch}`)) : null;
  return name ? path.join(dir, name, `bm-render.${name}.node`) : null;
}

/** takumi `sections(700)`: a heading and a paragraph per section, in one div. */
const sections = (count) =>
  `<div style="font-size: 12px">${Array.from({ length: count }, (_, i) => `<section><h2>Section ${i}</h2><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p></section>`).join("")}</div>`;

const child = args.find((a) => a.startsWith("--child="))?.slice(8);
if (child) {
  process.env.BM_RENDER_BACKEND = "native";
  const addon = createRequire(import.meta.url)(addonFile());
  const mod = await import(pathToFileURL(path.join(ROOT, "js", "node-pdf.mjs")).href);
  const { INTER, stressHtml, stressCorpus } = await import(pathToFileURL(path.join(ROOT, "bench", "pdf", "corpus", "docs.mjs")).href);
  const r = new mod.PdfRenderer();
  for (const f of INTER) r.registerFont({ name: f.name, data: new Uint8Array(readFileSync(f.path)), weight: f.weight, style: f.style });
  const chunks = process.env.BM_PDF_CHUNKS === "off" ? { chunks: false } : {};
  let source, options;
  if (child.startsWith("sections")) {
    source = sections(Number(child.split(":")[1] ?? 700));
    options = { size: { width: 320, height: 240 }, margin: 24, header: `<div style="font-family:Inter">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>`, ...chunks };
  } else {
    source = stressHtml(Number(child));
    options = { ...stressCorpus([1])[0].options(), ...chunks };
  }
  addon.memoryPeak(1);
  const base = addon.memoryPeak(0);
  addon.memoryTrace(1);
  const t0 = performance.now();
  const bytes = await r.render(source, options);
  const ms = performance.now() - t0;
  const trace = JSON.parse(addon.memoryTrace(0));
  const peak = addon.memoryPeak(0);
  // the passes: the counting pass marks each page it lays out ("count: page"), the drawing pass each page drawn
  const passes = [];
  for (const label of ["count: page", "emit: page done"]) {
    const live = trace.filter(([l]) => l === label).map(([, b]) => b - base);
    if (live.length) passes.push({ label, pages: live.length, early: live[EARLY - 1] ?? null, late: live[LATE - 1] ?? null, first: live[0], last: live[live.length - 1] });
  }
  const parts = trace.filter(([l]) => l === "part: drawn").length;
  const whole = trace.map(([l]) => l).filter((l) => l.startsWith("chunks: whole: ")).map((l) => l.slice(15));
  console.log(JSON.stringify({ ms, bytes: bytes.length, peak: peak - base, passes, parts, whole }));
  process.exit(0);
}

if (!addonFile()) {
  console.log("native addon not built (node scripts/build-native.mjs --target=<this host>)");
  process.exit(1);
}
function run(which) {
  const p = spawnSync(process.execPath, [fileURLToPath(import.meta.url), `--child=${which}`], { cwd: ROOT, env: process.env, encoding: "utf8", maxBuffer: 1 << 26 });
  const line = (p.stdout || "").trim().split("\n").pop();
  try {
    return JSON.parse(line);
  } catch {
    throw new Error(`child ${which} failed:\n${p.stdout}\n${p.stderr}`);
  }
}
let failed = false;
const s = run("sections");
console.log(`sections(700): ${s.passes.map((p) => p.pages).join(" / ")} pages, peak ${MiB(s.peak)}, ${s.ms.toFixed(0)} ms, ${(s.bytes / 1024).toFixed(0)} KiB, parts ${s.parts}${s.whole.length ? " (whole: " + s.whole.join("; ") + ")" : ""}`);
if (s.passes.length < 2) {
  console.log("  FAIL: expected a counting pass and a drawing pass");
  failed = true;
}
for (const p of s.passes) {
  const ok = p.early > 0 && p.late > 0 && p.late <= p.early * 1.1;
  if (!ok) failed = true;
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${p.label.padEnd(16)} live after page ${EARLY}: ${MiB(p.early ?? 0)}, after page ${LATE}: ${MiB(p.late ?? 0)} (x${(p.late / p.early).toFixed(3)}), first ${MiB(p.first)}, last ${MiB(p.last)}`);
}
if (args.includes("--stress")) {
  const sizes = (args.find((a) => a.startsWith("--sizes="))?.slice(8) ?? "1,10,100,500").split(",").map(Number);
  console.log("stress document (native, fresh process each; live = allocator bytes above the pre-render baseline):");
  console.log("| pages | ms/page | peak | live after page 1 | live after page 50 | live after page 200 | live after last page | parts | PDF KiB/page |");
  console.log("|--:|--:|--:|--:|--:|--:|--:|--:|--:|");
  for (const n of sizes) {
    const t = run(String(n));
    const d = t.passes.find((p) => p.label === "emit: page done");
    const cell = (v) => (v == null ? "-" : MiB(v));
    console.log(`| ${n} | ${(t.ms / n).toFixed(2)} | ${MiB(t.peak)} | ${cell(d?.first)} | ${cell(d?.early)} | ${cell(d?.late)} | ${cell(d?.last)} | ${t.parts}${t.whole.length ? " (whole: " + t.whole.join("; ") + ")" : ""} | ${(t.bytes / n / 1024).toFixed(1)} |`);
  }
}
process.exitCode = failed ? 1 : 0;

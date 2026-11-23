// Runs the PDF audit probes: every scripts/pdf-audit/*.probe.mjs registers probes with lib.mjs's `probe()`.
//
//   node scripts/pdf-audit/run.mjs [--json] [--quiet] [--strict] [filter ...]
//
//   TAKUMI_PDF_REF_ENTRY=<bench/out/pdf-oracle/node.mjs>  the pinned source-built oracle (scripts/build-takumi-pdf-oracle.mjs)
//   TAKUMI_PDF_REF=<dir with node_modules/takumi-pdf>     the published takumi-pdf instead (not accepted by --strict)
//   BM_RENDER_BACKEND=wasm | native                       the bm-render backend (both must give the same result)
//   PDF_AUDIT_EXCEPTIONS=<file>                           another exception list (default scripts/pdf-audit/exceptions.json)
//
// A failure is EXPECTED only when scripts/pdf-audit/exceptions.json names its probe, its kind and its text (gate.mjs).
// `--strict` exits 1 on any unexpected failure, any unverified comparison (no reference), a stale exception (one
// whose probe ran without that failure) or without the pinned oracle. Writes bench/out/pdf-audit/results.json: the
// provenance (bm revision, backend binary hash, oracle revision and hashes, fonts, tool versions), per-kind assertion
// counts, and every row. Needs js/bm_render.pdf.wasm (`node scripts/build.mjs --profile=pdf`).
import { readdirSync, writeFileSync, writeSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { bmMod, fontsUsed, oracle, outDir, popplerBin, refMod, refVersion, root, runProbes } from "./lib.mjs";
import { applyExceptions, KIND_NAMES, loadExceptions, provenance } from "./gate.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
for (const arg of argv) if (arg.startsWith('--') && !['--json', '--quiet', '--strict'].includes(arg)) throw new Error(`Unknown PDF audit option: ${arg}`);
const filter = argv.filter((a) => !a.startsWith("--"));
const quiet = argv.includes("--quiet");
const strict = argv.includes("--strict");
// The report is written synchronously: on Windows stdout to a pipe is asynchronous, and a process
// that loaded native addons (bm-render, @napi-rs/canvas for pdf.js) can end before it is flushed.
const say = (line) => writeSync(1, line + "\n");

const exceptionsFile = path.resolve(process.env.PDF_AUDIT_EXCEPTIONS || path.join(here, "exceptions.json"));
const exceptions = loadExceptions(exceptionsFile);
for (const f of readdirSync(here).filter((n) => n.endsWith(".probe.mjs")).sort()) await import(pathToFileURL(path.join(here, f)).href);

say(`bm-render/pdf backend: ${bmMod.backend}; reference: ${refMod ? "takumi-pdf " + refVersion : "not installed (set TAKUMI_PDF_REF_ENTRY): comparisons are unverified"}`);
const rows = await runProbes(filter);
if (rows.length === 0) throw new Error(`No PDF audit probes matched: ${filter.join(", ") || "(all)"}`);
const gate = applyExceptions(rows, exceptions);
const prov = provenance({ root, backend: bmMod.backend, oracle, fonts: fontsUsed(), exceptionsFile, poppler: popplerBin() });

let fail = 0; let pass = 0; let unverified = 0; let expected = 0;
for (const r of rows) {
  if (r.status === "FAIL") fail++; else if (r.status === "EXPECTED") expected++; else if (r.status === "UNVERIFIED") unverified++; else pass++;
  if (!quiet || r.status === "FAIL") say(`${r.status.padEnd(10)} ${r.id.padEnd(44)} ${r.pass} ok${r.fail ? ", " + r.fail + " failed" : ""}${r.unverified ? ", " + r.unverified + " unverified" : ""}`);
  for (const f of r.unexpected) say(`           - [${f.kind}] ${f.failure}`);
  if (!quiet) for (const f of r.expected) say(`           ~ [${f.kind}, ${f.status}] ${f.failure}`);
  if (!quiet) for (const n of r.notes) say(`           . ${n}`);
}
for (const e of gate.stale) say(`STALE      ${e.probe.padEnd(44)} [${e.kind}] exception no failure matched: /${e.match}/`);

// assertions per kind: page content, page count, page boxes, text, links, tags and font mapping are gated apart
const kinds = Object.fromEntries(KIND_NAMES.map((k) => [k, { pass: 0, fail: 0, expected: 0 }]));
for (const r of rows) {
  for (const [k, c] of Object.entries(r.kinds)) { kinds[k].pass += c.pass; kinds[k].fail += c.fail; }
  for (const e of r.expected) { kinds[e.kind].fail--; kinds[e.kind].expected++; }
}
say(`\nassertions by kind (pass / unexpected fail / expected difference):`);
for (const [k, c] of Object.entries(kinds)) if (c.pass || c.fail || c.expected) say(`  ${k.padEnd(13)} ${String(c.pass).padStart(6)} / ${c.fail} / ${c.expected}`);
say(`provenance: bm ${prov.bm.revision?.slice(0, 12) ?? "?"}${prov.bm.localChanges ? "+local changes" : ""} ${prov.bm.backend} ${prov.bm.artifact.file} ${prov.bm.artifact.sha256?.slice(0, 12) ?? ""}; oracle ${oracle ? `${oracle.kind} ${oracle.revision ?? oracle.version}` : "none"}; ${prov.fonts.length} font files loaded; ${prov.tools.pdftotext ?? "no pdftotext"}; node ${prov.tools.node}`);

const byStatus = (s) => gate.expected.filter((e) => e.status === s).length;
writeFileSync(path.join(outDir, "results.json"), JSON.stringify({
  provenance: prov, backend: bmMod.backend, reference: refVersion,
  summary: { probes: rows.length, pass, fail, expected, unverified, staleExceptions: gate.stale.length, expectedDeliberate: byStatus("deliberate"), expectedOpen: byStatus("open"), kinds },
  unexpected: gate.unexpected, expected: gate.expected, stale: gate.stale, rows,
}, null, 1));
if (argv.includes("--json")) say(JSON.stringify(rows));
say(`\n${rows.length} probes: ${pass} pass, ${fail} fail, ${expected} expected (${byStatus("deliberate")} deliberate / ${byStatus("open")} open differences, scripts/pdf-audit/exceptions.json), ${unverified} unverified (no reference)${gate.stale.length ? `, ${gate.stale.length} stale exception(s)` : ""}`);
const pinned = !!process.env.TAKUMI_PDF_REF_ENTRY && !!refMod;
process.exitCode = fail || (strict && (!pinned || unverified || gate.stale.length)) ? 1 : 0;

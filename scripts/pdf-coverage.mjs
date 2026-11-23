// Case inventory of takumi-pdf's own tests, separate from golden equivalence and instrumented code coverage.
//
//   node scripts/pdf-coverage.mjs            regenerate scripts/pdf-coverage-map.json (case classifications are kept)
//   node scripts/pdf-coverage.mjs --check    fail when the regenerated map differs from the committed one
//   node scripts/pdf-coverage.mjs --strict   fail on an unclassified case or an adapter that names nothing
//   ... --audit=bench/out/pdf-audit/results.json   (with --strict) also fail when a `verified` case's probe did not
//                                            pass in that full pinned audit, or a `differs` / `open` case's probe
//                                            failed without an exception
//
// Every Rust `#[test]` under takumi-pdf/ (pdf_fixtures.rs, streaming_tests.rs, window_scenes.rs, memory_tests.rs and
// the unit tests of src/, krilla/ and subsetter/) and every Bun `test()` of the PDF wrapper and the shared resource
// preparation is a case. Each case is classified:
//   golden-adapter  the test writes a golden; scripts/pdf-compare.mjs compares bm's file with it
//   verified        case-level adapters (pinned-oracle probes, Zig / API / chunk / memory tests) check what it asserts
//   partial         adapters check part of it; the reason says what is not covered
//   differs         adapters show a deliberate, documented difference
//   open            adapters show a known difference not resolved yet (listed in scripts/pdf-audit/exceptions.json)
//   not-applicable  unreachable from the public API (Rust internals, raster-only APIs); the reason says why
// `pending-adapter` / `internal-review` are unclassified. Adapters must resolve: a golden fixture name, a probe filter
// that matches a registered probe, a Zig test name, a `npm run test:pdf` check message, a chunks-check case id.
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { ROOT, TAKUMI_TESTS, REVISION, verifyCorpus } from "./takumi-test-corpus.mjs";
import { goldenFixtures } from "../bench/pdf/corpus/golden.mjs";

const argv = process.argv.slice(2);
const manifest = verifyCorpus();
const mapFile = path.join(ROOT, "scripts", "pdf-coverage-map.json");
const previous = existsSync(mapFile) ? JSON.parse(readFileSync(mapFile, "utf8")) : null;
if (previous && previous.revision !== REVISION) throw new Error("Coverage map revision changed; review its case mappings");
const saved = new Map((previous?.cases || []).map((c) => [c.id, c]));
const savedJs = new Map((previous?.javascriptCases || []).map(c => [c.id, c]));
const { fixtures, reason } = await goldenFixtures();
if (!fixtures.length) throw new Error(reason || "No golden adapters loaded");
const names = new Set(fixtures.map((f) => f.fixture));
const STATUSES = ["golden-adapter", "verified", "partial", "differs", "open", "not-applicable"];
const UNCLASSIFIED = ["pending-adapter", "internal-review"];

// Find a Rust function's closing brace, ignoring strings, raw strings and nested comments.
function bodyEnd(s, start) {
  let depth = 0;
  for (let i = start; i < s.length; i++) {
    if (s.startsWith("//", i)) { i = s.indexOf("\n", i); if (i < 0) return s.length; continue; }
    if (s.startsWith("/*", i)) {
      let comments = 1; i += 2;
      while (i < s.length && comments) {
        if (s.startsWith("/*", i)) { comments++; i += 2; }
        else if (s.startsWith("*/", i)) { comments--; i += 2; }
        else i++;
      }
      i--; continue;
    }
    const raw = /^r(#{0,32})"/.exec(s.slice(i, i + 35));
    if (raw) { const end = s.indexOf('"' + raw[1], i + raw[0].length); if (end < 0) throw new Error("Unclosed raw string"); i = end + raw[1].length; continue; }
    if (s[i] === '"' || (s[i] === "'" && /^'(?:\\.|[^'\\\r\n])'/.test(s.slice(i, i + 12)))) {
      const quote = s[i++];
      while (i < s.length && s[i] !== quote) { if (s[i] === "\\") i++; i++; }
      continue;
    }
    if (s[i] === "{") depth++;
    else if (s[i] === "}" && --depth === 0) return i + 1;
  }
  throw new Error("Unclosed Rust test body");
}

/** The goldens a test body writes: string literals naming a fixture, also through `format!("name-{x}")`. */
function goldensOf(body) {
  const out = new Set();
  for (const m of body.matchAll(/"([a-z0-9][a-z0-9{}_-]{3,})"/g)) {
    const lit = m[1];
    if (names.has(lit)) out.add(lit);
    else if (lit.includes("{")) {
      const prefix = lit.slice(0, lit.indexOf("{"));
      if (prefix.length < 4) continue;
      const re = new RegExp("^" + lit.split(/\{[^}]*\}/).map((p) => p.replace(/[.*+?^$()|[\]\\]/g, "\\$&")).join("[a-z0-9-]+") + "$");
      for (const n of names) if (re.test(n)) out.add(n);
    }
  }
  return [...out].sort();
}

const cases = [];
for (const file of manifest.files) {
  if (!file.path.startsWith("takumi-pdf/") || !file.path.endsWith(".rs")) continue;
  const source = readFileSync(path.join(TAKUMI_TESTS, file.path), "utf8");
  for (const attribute of source.matchAll(/#\s*\[\s*test\s*\]/g)) {
    const rest = source.slice(attribute.index + attribute[0].length);
    const fn = /\bfn\s+(\w+)\s*\(/.exec(rest);
    if (!fn) throw new Error(`Test without function: ${file.path}`);
    const fnStart = attribute.index + attribute[0].length + fn.index;
    const start = source.indexOf("{", fnStart);
    const end = bodyEnd(source, start);
    const goldens = goldensOf(source.slice(start, end));
    const line = source.slice(0, fnStart).split("\n").length;
    const id = `${file.path}:${line}:${fn[1]}`;
    const existing = saved.get(id);
    const internal = /\/(?:krilla|subsetter)\//.test(file.path);
    const classified = existing && !UNCLASSIFIED.includes(existing.status);
    const golden = goldens.length && (!classified || existing.status === "golden-adapter");
    cases.push({ id, source: file.path, line, name: fn[1], sourceSha256: file.sha256,
      status: golden ? "golden-adapter" : classified ? existing.status : internal ? "internal-review" : "pending-adapter",
      adapters: golden ? goldens.map((name) => `node scripts/pdf-compare.mjs --strict ${name}`) : existing?.adapters || [],
      reason: golden && existing?.status === "golden-adapter" ? existing.reason
        : golden ? "Golden adapter: scripts/pdf-compare.mjs compares every page operator, fonts, structure tree, annotations, outline, Info/XMP, ids and attachments of the file this test writes with the committed golden; assertions the test makes on the same bytes follow from equal output, or a fixture equivalence is listed in docs/PDF_GOLDEN_DIFFS.md."
        : existing?.reason || "No case-level adapter yet; do not count as executed coverage.",
    });
  }
}
for (const id of saved.keys()) if (!cases.some((c) => c.id === id)) throw new Error(`Stale coverage case: ${id}`);
// Bun test declarations in the PDF wrapper and shared preparation facade. These are
// inventories of source declarations, not a claim that the Bun suite ran against bm.
const javascriptCases = [];
for (const file of manifest.files) {
  if (!/^takumi-pdf-js\/tests\/.*\.test\.tsx?$/.test(file.path) &&
      !/^takumi-(?:bindings-js|helpers)\/tests\/(?:renderer-facade|prepare-images)\.test\.ts$/.test(file.path)) continue;
  const source = readFileSync(path.join(TAKUMI_TESTS, file.path), 'utf8');
  for (const call of source.matchAll(/\b(?:test|it)(?:\.(?:only|skip|todo))?\s*\(\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/g)) {
    const line = source.slice(0, call.index).split('\n').length;
    const name = call[1].slice(1, -1);
    const id = `${file.path}:${line}:${name}`;
    const existing = savedJs.get(id);
    javascriptCases.push({ id, source: file.path, line, name, sourceSha256: file.sha256,
      status: existing?.status || 'pending-adapter', adapters: existing?.adapters || [],
      reason: existing?.reason || 'No case-level adapter yet; do not count as executed coverage.' });
  }
}
for (const id of savedJs.keys()) if (!javascriptCases.some(c => c.id === id)) throw new Error(`Stale JavaScript coverage case: ${id}`);

// ---- adapters must name something that exists
async function probeIds() {
  const dir = path.join(ROOT, "scripts", "pdf-audit");
  const lib = await import(pathToFileURL(path.join(dir, "lib.mjs")).href);
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".probe.mjs")).sort()) await import(pathToFileURL(path.join(dir, f)).href);
  return lib.listProbes().map((p) => p.id);
}
const zigTests = (() => {
  const out = new Set();
  const walk = (dir) => { for (const e of readdirSync(dir, { withFileTypes: true })) { const p = path.join(dir, e.name); if (e.isDirectory()) walk(p); else if (e.name.endsWith(".zig")) for (const m of readFileSync(p, "utf8").matchAll(/^test "((?:\\.|[^"\\])*)"/gm)) out.add(m[1]); } };
  walk(path.join(ROOT, "src"));
  return out;
})();
const apiTests = readFileSync(path.join(ROOT, "scripts", "pdf-test.mjs"), "utf8");
const chunkCases = new Set([...readFileSync(path.join(ROOT, "scripts", "pdf-chunks-check.mjs"), "utf8").matchAll(/\{ id: "([\w-]+)"/g)].map((m) => m[1]));
const probes = argv.includes("--strict") || argv.includes("--check") ? await probeIds() : null;
/** Why an adapter names nothing (null when it resolves); `probeFilters` collects the probe filters. */
function unresolved(adapter, probeFilters) {
  let m;
  if ((m = /^node scripts\/pdf-compare\.mjs --strict (\S+)$/.exec(adapter))) return names.has(m[1]) ? null : `no golden fixture ${m[1]}`;
  if ((m = /^node scripts\/pdf-audit\/run\.mjs --strict (\S+)$/.exec(adapter))) { probeFilters.push(m[1]); return !probes || probes.some((id) => id.includes(m[1])) ? null : `no probe matches ${m[1]}`; }
  if ((m = /^zig build test -Dpdf=true -Dtest-filter="(.+)"$/.exec(adapter))) return zigTests.has(m[1]) ? null : `no Zig test "${m[1]}"`;
  if ((m = /^npm run test:pdf: (.+)$/.exec(adapter))) return apiTests.includes(m[1]) ? null : `no npm run test:pdf check "${m[1]}"`;
  if ((m = /^npm run test:pdf:chunks: (\S+)$/.exec(adapter))) return chunkCases.has(m[1]) ? null : `no chunks-check case ${m[1]}`;
  if (adapter === "npm run test:pdf:memory") return null;
  return "unknown adapter form";
}
const problems = [];
for (const c of [...cases, ...javascriptCases]) {
  if (UNCLASSIFIED.includes(c.status)) { problems.push(`${c.id}: unclassified (${c.status})`); continue; }
  if (!STATUSES.includes(c.status)) problems.push(`${c.id}: unknown status ${c.status}`);
  if (c.status !== "not-applicable" && !c.adapters.length) problems.push(`${c.id}: ${c.status} without an adapter`);
  if (c.status === "not-applicable" && c.reason.length < 40) problems.push(`${c.id}: not-applicable without a reason`);
  const filters = [];
  for (const a of c.adapters) { const why = unresolved(a, filters); if (why) problems.push(`${c.id}: adapter "${a}": ${why}`); }
  c.probeFilters = filters;
}
// ---- against a full pinned audit
const auditArg = argv.find((a) => a.startsWith("--audit="));
if (auditArg) {
  const audit = JSON.parse(readFileSync(path.resolve(auditArg.slice(8)), "utf8"));
  if (!audit.provenance?.oracle?.revision || audit.provenance.oracle.revision !== REVISION) problems.push(`${auditArg.slice(8)}: not an audit against the pinned oracle ${REVISION}`);
  const rows = audit.rows || [];
  for (const c of [...cases, ...javascriptCases]) for (const f of c.probeFilters) {
    const hit = rows.filter((r) => r.id.includes(f));
    if (!hit.length) { problems.push(`${c.id}: probe ${f} did not run in the audit`); continue; }
    const bad = hit.filter((r) => r.status !== "PASS" && r.status !== "EXPECTED");
    if (bad.length) problems.push(`${c.id}: ${bad.map((r) => `${r.id} ${r.status}`).join(", ")}`);
  }
}
for (const c of [...cases, ...javascriptCases]) delete c.probeFilters;

const result = { revision: REVISION, meaning: "Static Rust and JavaScript test declarations of takumi-pdf at the pinned revision, each mapped to the bm-render adapters that check what it asserts (or why none applies). Not runtime counts or code coverage. Statuses: see scripts/pdf-coverage.mjs.",
  goldenAdapters: fixtures.map((f) => ({ name: f.fixture, runner: `node scripts/pdf-compare.mjs --strict ${f.fixture}` })),
  featureAudits: [{ feature: 'SVG-in-OpenType glyph painting', status: 'not-applicable',
    reason: 'Pinned public PDF API falls back to outlines. SerializeSettings.render_svg_glyph_fn defaults to None; the PDF emitter does not replace it.',
    source: 'takumi-pdf/src/krilla/serialize.rs:156',
    adapter: 'node scripts/pdf-audit/run.mjs --strict fonts.svg-opentype-outline-fallback',
    evidence: 'Valid SVG-table font with conspicuous alternate paint; reference and bm emit outline curves, with no SVG rectangle paint and matching extraction.' }],
  cases, javascriptCases };
const encoded = JSON.stringify(result, null, 2) + "\n";
if (argv.includes("--check")) {
  if (!previous || readFileSync(mapFile, "utf8").replace(/\r\n/g, "\n") !== encoded) throw new Error("Coverage inventory changed: regenerate and review scripts/pdf-coverage-map.json");
} else writeFileSync(mapFile, encoded);
const tally = (list) => Object.entries(Object.groupBy(list, (c) => c.status)).map(([k, v]) => `${k}: ${v.length}`).join(", ");
const bySource = Object.entries(Object.groupBy(cases, (c) => c.source.replace(/^takumi-pdf\//, "").replace(/^src\/(krilla|subsetter)\/.*/, "src/$1/*"))).map(([k, v]) => `${k} ${v.length}`).join(", ");
console.log(`${cases.length} Rust test declarations (${bySource}); ${fixtures.length} golden adapters. ${tally(cases)}.`);
console.log(`${javascriptCases.length} JavaScript test declarations. ${tally(javascriptCases)}.`);
for (const p of problems) console.log(`  ${p}`);
if (problems.length) console.log(`${problems.length} problem(s)`);
if (argv.includes("--strict") && problems.length) process.exitCode = 1;

// The strict gate of the PDF audit (scripts/pdf-audit/run.mjs): assertion kinds, the narrow exception list
// (scripts/pdf-audit/exceptions.json) and the provenance every report records.
//
// An assertion's kind comes from its label (the `what` of t.ok / t.same). Kinds are counted apart, so a report says
// separately how page content, page count, page boxes, extracted text, links, tags and font mapping compare.
//
// An exception names ONE probe and ONE kind, a pattern its failure text must match, a status (`deliberate`: bm
// follows CSS / its API on purpose; `open`: a known difference not resolved yet) and the reason. There are no
// wildcards, no probe prefixes and no tolerance: a failure of another probe, of another kind, or whose text the
// pattern does not match is unexpected, and an exception that no longer matches a failure of a probe that ran is
// stale. `--strict` fails on either.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/** Assertion kinds, in the order a label is tested against them (first match wins). */
export const KINDS = [
  ["error", /(^|[\s:])(error|errors|rejects?|throws?|threw|renders?\b.*fail|outcome)\b/i],
  ["page-count", /\bpage count\b|\bpages\b(?! per)(?!:? ?\[)|^pages$|pages written|paginates|blank pages?/i],
  ["page-box", /\b(page )?box(es)?\b|MediaBox|CropBox|TrimBox|page size|\bsize\b|landscape|orientation/i],
  ["tags", /struct|\btag(s|ged|ging)?\b|parent tree|\bMCID|marked[ -]content|\brole\b|artifact|\bLbl\b|\bFigure\b|\bTable elements?\b|\bTR elements?\b|\/Lang|reading order|id tree/i],
  ["links", /\blinks?\b|annot|\bURI\b|destination|\bdests?\b|outline|bookmark|\btitles?\b|href/i],
  ["font-mapping", /font|glyph|subset|ToUnicode|\bCID\b|Type3|\/W\b|\/DW\b|BaseFont|cmap|U\+[0-9A-F]{4}|mapping|matra|text objects/i],
  ["text", /text|extract|words?\b|pdftotext|pdf\.js|ActualText|\blines?\b|reading/i],
  ["metadata", /\bInfo\b|XMP|metadata|Producer|catalog|version|attachment|viewer|\bid\b|\bids\b|\bdate\b|OutputIntent|pdfa|conformance|validat/i],
  ["page-content", /\bpage \d+\b|content|operator|draw|paint|raster|pixel|curve|shading|fill|image|clip|colou?r|gradient|pattern|matrix|axis|centre|scale|shear|calls|loads?\b/i],
];
export const KIND_NAMES = [...KINDS.map(([k]) => k), "other"];

/** The kind of an assertion label (or of a failure text: its first line, up to `: bm ` / `: takumi `). */
export function kindOf(label) {
  const what = String(label).split("\n")[0].split(/: bm |: takumi /)[0];
  for (const [kind, re] of KINDS) if (re.test(what)) return kind;
  return "other";
}

/** Reads and validates the exception list (throws on a malformed entry: a gate must not run on a broken list). */
export function loadExceptions(file) {
  const raw = JSON.parse(readFileSync(file, "utf8"));
  const list = raw.exceptions;
  if (!Array.isArray(list)) throw new Error(`${file}: "exceptions" must be a list`);
  const seen = new Set();
  return list.map((e, i) => {
    const where = `${file}: exception ${i} (${e.probe})`;
    for (const k of ["probe", "kind", "match", "status", "reason"]) if (typeof e[k] !== "string" || !e[k].trim()) throw new Error(`${where}: "${k}" is required`);
    if (/[*?]|\.$/.test(e.probe)) throw new Error(`${where}: an exception names one probe id, not a pattern or prefix`);
    if (!KIND_NAMES.includes(e.kind)) throw new Error(`${where}: unknown kind "${e.kind}" (${KIND_NAMES.join(", ")})`);
    if (!["deliberate", "open"].includes(e.status)) throw new Error(`${where}: status must be "deliberate" or "open"`);
    if (e.reason.trim().length < 40) throw new Error(`${where}: the reason must explain the difference`);
    if (/^\^?\.\*\$?$|^\^?\.\+\$?$|^$/.test(e.match)) throw new Error(`${where}: "match" must name the failure, not match everything`);
    const key = `${e.probe}\u0000${e.kind}\u0000${e.match}`;
    if (seen.has(key)) throw new Error(`${where}: duplicate`);
    seen.add(key);
    return { ...e, re: new RegExp(e.match) };
  });
}

/**
 * Splits the failures of the audit rows into expected (an exception of the same probe and kind matches) and
 * unexpected, and reports the exceptions of probes that ran which matched no failure (stale).
 * Rows are updated: `expected` (failures covered by an exception), `unexpected`, and `status` EXPECTED when every
 * failure of a failing row is expected.
 */
export function applyExceptions(rows, exceptions) {
  const used = new Set();
  const unexpected = [];
  const expected = [];
  for (const row of rows) {
    row.expected = [];
    row.unexpected = [];
    for (const failure of row.failures) {
      const kind = kindOf(failure);
      // (a pattern is matched against the failure's first line: the rest is a dump of the two files)
      const head = failure.split("\n")[0];
      const hit = exceptions.findIndex((e) => e.probe === row.id && e.kind === kind && e.re.test(head));
      if (hit >= 0) { used.add(hit); row.expected.push({ failure, kind, status: exceptions[hit].status }); expected.push({ id: row.id, kind, failure, status: exceptions[hit].status, reason: exceptions[hit].reason }); }
      else { row.unexpected.push({ failure, kind }); unexpected.push({ id: row.id, kind, failure }); }
    }
    if (row.status === "FAIL" && row.unexpected.length === 0) row.status = "EXPECTED";
  }
  const ran = new Set(rows.map((r) => r.id));
  const stale = exceptions.filter((e, i) => ran.has(e.probe) && !used.has(i)).map(({ re, ...e }) => e);
  return { expected, unexpected, stale };
}

const sha256 = (file) => (existsSync(file) ? createHash("sha256").update(readFileSync(file)).digest("hex") : null);
const firstLine = (r) => String((r.stdout || "") + (r.stderr || "")).split(/\r?\n/).find((l) => l.trim()) || null;
function pkgVersion(root, name) {
  for (const base of [path.join(root, "bench", "pdf", "node_modules"), path.join(root, "node_modules")]) {
    const f = path.join(base, name, "package.json");
    if (existsSync(f)) return JSON.parse(readFileSync(f, "utf8")).version;
  }
  return null;
}

/**
 * What a report was produced with: bm source revision (and whether the tree had local changes), backend and the
 * hash of the binary that ran, the oracle (pinned source build with its hashes, or the published package), the fonts
 * the probes loaded (with hashes), the exception list, and tool versions.
 */
export function provenance({ root, backend, oracle, fonts, exceptionsFile, poppler }) {
  const git = (args) => spawnSync("git", args, { cwd: root, encoding: "utf8" });
  const head = git(["rev-parse", "HEAD"]).stdout?.trim() || null;
  const dirty = head ? git(["status", "--porcelain", "--untracked-files=no"]).stdout.trim().length > 0 : null;
  let artifact;
  if (backend === "wasm") artifact = { file: "js/bm_render.pdf.wasm", sha256: sha256(path.join(root, "js", "bm_render.pdf.wasm")) };
  else {
    const name = `${process.platform}-${process.arch}`;
    const forced = process.env.BM_RENDER_NATIVE_PATH;
    const dev = (() => { const dir = path.join(root, "native", "dist"); if (!existsSync(dir)) return null; const n = readdirSync(dir).find((d) => d.startsWith(name)); return n ? path.join(dir, n, `bm-render.${n}.node`) : null; })();
    const file = forced ? path.resolve(forced) : dev && existsSync(dev) ? dev : null;
    artifact = file ? { file: path.relative(root, file), sha256: sha256(file) } : { file: `@hunghg255/bm-render-${name} (the published npm package: NOT this checkout)`, sha256: null };
  }
  return {
    bm: { revision: head, localChanges: dirty, backend, artifact },
    oracle,
    fonts: [...fonts].sort().map((f) => ({ file: f.file, sha256: f.sha256 })),
    exceptions: exceptionsFile ? { file: path.relative(root, exceptionsFile), sha256: sha256(exceptionsFile) } : null,
    tools: {
      node: process.version,
      pdftotext: poppler ? firstLine(spawnSync(poppler, ["-v"], { encoding: "utf8" })) : null,
      "pdfjs-dist": pkgVersion(root, "pdfjs-dist"),
      "@napi-rs/canvas": pkgVersion(root, "@napi-rs/canvas"),
    },
  };
}

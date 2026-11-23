// External validation of bm-render's PDF output (and takumi-pdf's, as the baseline), headless, as a gate.
//
//   node bench/pdf/validate.mjs [--rebuild] [--filter=<regex>] [--max-stress=500] [--no-verapdf] [--jobs=4]
//                               [--gate=all|bm-only|none]
//
// Renders the corpus (lib/build.mjs; reused from bench/out/pdf/pdfs unless --rebuild) and runs on every PDF of
// bm-native, bm-wasm and takumi-pdf:
//   qpdf --check (+ linearization status)      pdfcpu validate -m strict       poppler pdfinfo + pdffonts
//   mupdf.js (MuPDF wasm): open, load every page, extract text, draw it at 72 dpi; every warning it logs
//   pdf.js: parse everything a viewer reads; every warning it logs
//   veraPDF (portable JRE) with the profile of each conformance claim (pdfa 2a/2b/2u/3a/3b/3u/4/4f, tagged ua1/ua2)
// and checks: byte identity bm-native == bm-wasm (and bm-native sync == async), fonts embedded and subset
// (pdffonts; Type 3 fonts are not subset by definition), the XMP claims (pdfaid / pdfuaid) match the options, and
// bm vs takumi-pdf semantically through pdf.js (page count and sizes, text per page in order, links: targets and
// rects within 1 pt, outline, attachments, structure tree roles, metadata).
// Every issue on a bm PDF is classified "shared" when takumi-pdf's PDF of the same input has the same issue
// (same tool, same message), else "bm-only".
// Outputs bench/out/pdf/validation.json and bench/out/pdf/VALIDATION.md. Exit 1 when the gate fails:
//   all (default): any error / warning on a bm PDF, any identity mismatch;  bm-only: only bm-only issues and
//   identity;  none: never (report only).
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import path from "node:path";
import { OUT_DIR, findBin, toolsManifest, ROOT } from "./lib/tools.mjs";
import { corpusBuild, fileOf } from "./lib/build.mjs";
import { inspect } from "./lib/pdfjs.mjs";
import { run, limit, lines } from "./lib/proc.mjs";

const args = Object.fromEntries(process.argv.slice(2).map((a) => { const m = /^--([^=]+)(?:=(.*))?$/.exec(a); return m ? [m[1], m[2] ?? true] : [a, true]; }));
const JOBS = +(args.jobs ?? 4);
const gate = String(args.gate ?? "all");
const log = (...a) => console.error(...a);
const T0 = performance.now();
mkdirSync(OUT_DIR, { recursive: true });
const TMP = path.join(OUT_DIR, "tmp"); mkdirSync(TMP, { recursive: true });

const manifest = await corpusBuild({ rebuild: !!args.rebuild, filter: args.filter ? String(args.filter) : null, maxStress: +(args["max-stress"] ?? 500), log });
const ENG = manifest.engines;
const BM = ENG.filter((e) => e.startsWith("bm-"));
const tools = {
  qpdf: findBin("qpdf", "qpdf"), pdfcpu: findBin("pdfcpu", "pdfcpu"), pdfinfo: findBin("poppler", "pdfinfo"), pdffonts: findBin("poppler", "pdffonts"),
  java: findBin("jre", "java"), verapdf: findBin("verapdf", "jar"),
};
const missing = Object.entries(tools).filter(([, p]) => !p).map(([k]) => k);
if (missing.length) log(`validate: tools not installed (run node bench/pdf/setup.mjs): ${missing.join(", ")}; their checks are skipped and reported as such`);

// ------------------------------------------------------------------------------------------------ per-file tools
const issue = (tool, severity, message, extra = {}) => ({ tool, severity, message: message.trim(), ...extra });

async function qpdfCheck(file) {
  if (!tools.qpdf) return { skipped: true, issues: [] };
  const r = await run(tools.qpdf, ["--check", file]);
  const out = lines(r.out + "\n" + r.err);
  const issues = [];
  for (const l of out) {
    if (/^(checking |PDF Version:|File is not encrypted|File is not linearized|File is linearized|No syntax or stream encoding errors|errors that qpdf cannot detect|R = |P = |User password|Supports print|extract for|Encrypted|stream encryption|string encryption|file encryption)/i.test(l.trim())) continue;
    issues.push(issue("qpdf", /WARNING/i.test(l) ? "warning" : "error", l.replace(file, "<file>")));
  }
  if (r.code !== 0 && !issues.length) issues.push(issue("qpdf", r.code === 3 ? "warning" : "error", `exit code ${r.code}`));
  return { exit: r.code, linearized: out.some((l) => /File is linearized/.test(l)), version: (out.find((l) => /^PDF Version:/.test(l)) || "").split(":")[1]?.trim() ?? null, issues };
}

async function pdfcpuCheck(file) {
  if (!tools.pdfcpu) return { skipped: true, issues: [] };
  const r = await run(tools.pdfcpu, ["validate", "-m", "strict", "-c", "disable", file]);
  const out = lines(r.out + "\n" + r.err).filter((l) => !/^validating\(|^validation ok/.test(l.trim()));
  const issues = out.map((l) => issue("pdfcpu", /warn/i.test(l) ? "warning" : "error", l.replace(file, "<file>")));
  if (r.code !== 0 && !issues.length) issues.push(issue("pdfcpu", "error", `exit code ${r.code}`));
  return { exit: r.code, issues };
}

async function popplerCheck(file) {
  if (!tools.pdfinfo) return { skipped: true, issues: [] };
  const info = await run(tools.pdfinfo, [file]);
  const issues = lines(info.err).map((l) => issue("pdfinfo", /error/i.test(l) ? "error" : "warning", l.replace(file, "<file>")));
  const kv = Object.fromEntries(lines(info.out).map((l) => { const i = l.indexOf(":"); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
  let fonts = [];
  if (tools.pdffonts) {
    const f = await run(tools.pdffonts, [file]);
    for (const l of lines(f.err)) issues.push(issue("pdffonts", /error/i.test(l) ? "error" : "warning", l.replace(file, "<file>")));
    const rows = lines(f.out).slice(2);
    fonts = rows.map((l) => {
      const m = /^(.{36}) (.{17}) (.{16}) (yes|no)\s+(yes|no)\s+(yes|no)\s+(\d+)\s+(\d+)/.exec(l);
      return m ? { name: m[1].trim(), type: m[2].trim(), encoding: m[3].trim(), emb: m[4] === "yes", sub: m[5] === "yes", uni: m[6] === "yes", obj: +m[7] } : { raw: l };
    });
    for (const ft of fonts) {
      if (ft.raw) continue;
      if (!ft.emb) issues.push(issue("fonts", "error", `font not embedded: ${ft.name} (${ft.type})`));
      else if (!ft.sub && ft.type !== "Type 3") issues.push(issue("fonts", "warning", `font embedded but not subset: ${ft.name} (${ft.type})`));
      if (!ft.uni) issues.push(issue("fonts", "warning", `font has no ToUnicode map: ${ft.name} (${ft.type})`));
    }
  }
  if (info.code !== 0) issues.push(issue("pdfinfo", "error", `exit code ${info.code}`));
  return { pages: +kv.Pages || null, version: kv["PDF version"] ?? null, tagged: kv.Tagged ?? null, pageSize: kv["Page size"] ?? null, producer: kv.Producer ?? null, fonts, issues };
}

let mupdf;
async function mupdfCheck(bytes, maxPages) {
  mupdf ??= await import("mupdf");
  const msgs = [];
  mupdf.setLog?.((m) => msgs.push(String(m).trim()));
  const orig = { log: console.log, warn: console.warn, error: console.error };
  const grab = (...a) => msgs.push(a.map(String).join(" ").trim());
  console.log = grab; console.warn = grab; console.error = grab;
  let pages = null, repaired = null, error = null, xmp = null;
  try {
    const d = mupdf.Document.openDocument(bytes, "application/pdf");
    pages = d.countPages();
    for (let i = 0; i < Math.min(pages, maxPages); i++) {
      const p = d.loadPage(i);
      p.toStructuredText().asText();
      const pix = p.toPixmap(mupdf.Matrix.identity, mupdf.ColorSpace.DeviceRGB, false, true);
      pix.destroy?.(); p.destroy?.();
    }
    repaired = d.asPDF?.()?.wasRepaired?.() ?? null;
    try { const md = d.asPDF?.()?.getTrailer().get("Root").get("Metadata"); if (md && !md.isNull()) xmp = md.readStream().asString(); } catch {}
    d.destroy?.();
  } catch (e) { error = String(e.message || e); }
  finally { Object.assign(console, orig); mupdf.setLog?.(null); }
  const issues = msgs.filter(Boolean).map((m) => issue("mupdf", /error/i.test(m) ? "error" : "warning", m));
  if (error) issues.push(issue("mupdf", "error", error));
  if (repaired) issues.push(issue("mupdf", "error", "document needed xref repair"));
  return { pages, repaired, issues, xmp: xmpClaims(xmp) };
}

/** pdfaid / pdfuaid properties of an XMP packet (element or attribute form). */
function xmpClaims(text) {
  if (!text) return null;
  const out = {};
  // <pdfaid:part>2</pdfaid:part> or pdfaid:part="2" (closing tags are not matched: the element form needs "<" before)
  for (const m of text.matchAll(/(?:<|\s)(pdfaid|pdfuaid):(part|conformance|rev|amd)(?:\s*=\s*"([^"]*)"|>([^<]*)<)/g)) (out[m[1]] ??= {})[m[2]] = (m[3] ?? m[4]).trim();
  return out;
}

// ------------------------------------------------------------------------------------------------ veraPDF
const PDFA_PROFILE = { "2a": "2a", "2b": "2b", "2u": "2u", "3a": "3a", "3b": "3b", "3u": "3u", "4": "4", "4f": "4f" };
function profilesOf(doc) {
  const p = [];
  if (doc.pdfa && PDFA_PROFILE[doc.pdfa]) p.push(PDFA_PROFILE[doc.pdfa]);
  if (doc.tagged === "ua1") p.push("ua1");
  if (doc.tagged === "ua2") p.push("ua2");
  return p;
}
async function verapdfBatch(profile, files) {
  // one JVM per (profile, batch of files); the report is JSON (veraPDF's --format json)
  const out = new Map();
  for (let i = 0; i < files.length; i += 40) {
    const batch = files.slice(i, i + 40);
    const r = await run(tools.java, ["-Xmx1g", "-Dfile.encoding=UTF-8", "-cp", tools.verapdf, "org.verapdf.apps.GreenfieldCliWrapper", "-f", profile, "--format", "json", "--maxfailuresdisplayed", "5", ...batch], { timeout: 900000, cwd: path.dirname(tools.verapdf) });
    let j;
    try { j = JSON.parse(r.out.slice(r.out.indexOf("{"))); } catch (e) {
      for (const f of batch) out.set(f, { error: `veraPDF output not JSON (exit ${r.code}): ${(r.err || r.out).slice(0, 300)}` });
      continue;
    }
    for (const job of j.report?.jobs ?? []) {
      const f = path.resolve(job.itemDetails?.name ?? "");
      const vr = Array.isArray(job.validationResult) ? job.validationResult[0] : job.validationResult;
      if (!vr) { out.set(f, { error: job.taskException?.exceptionMessage || job.taskResult?.exceptionMessage || "no validation result" }); continue; }
      out.set(f, {
        compliant: vr.compliant, profile: vr.profileName, failedRules: vr.details?.failedRules ?? null, failedChecks: vr.details?.failedChecks ?? null,
        rules: (vr.details?.ruleSummaries ?? []).filter((x) => x.ruleStatus === "FAILED" || x.status === "failed").map((x) => ({
          spec: x.specification, clause: x.clause, test: x.testNumber, failedChecks: x.failedChecks, description: x.description, object: x.object,
          contexts: (x.checks ?? []).slice(0, 3).map((c) => c.context), message: (x.checks ?? [])[0]?.errorMessage ?? null,
        })),
      });
    }
  }
  return out;
}

// ------------------------------------------------------------------------------------------------ semantic comparison
const near = (a, b, tol) => Math.abs(a - b) <= tol;
function textDiff(a, b) {
  if (a === b) return null;
  const ns = (s) => s.replace(/\s+/g, "");
  let i = 0; while (i < a.length && a[i] === b[i]) i++;
  return { sameIgnoringSpaces: ns(a) === ns(b), at: i, bm: a.slice(Math.max(0, i - 30), i + 50), takumi: b.slice(Math.max(0, i - 30), i + 50), bmLen: a.length, takumiLen: b.length };
}
const structSig = (n) => (n ? n.role + (n.kids ? "(" + n.kids.map(structSig).join(",") + ")" : "") : "");
function semantic(bm, tk) {
  const d = [];
  if (bm.error || tk.error) return [{ what: "parse", bm: bm.error ?? "ok", takumi: tk.error ?? "ok" }];
  if (bm.numPages !== tk.numPages) d.push({ what: "pageCount", bm: bm.numPages, takumi: tk.numPages });
  const n = Math.min(bm.numPages, tk.numPages);
  for (let i = 0; i < n; i++) {
    const a = bm.pages[i], b = tk.pages[i];
    if (!near(a.w, b.w, 0.5) || !near(a.h, b.h, 0.5)) d.push({ what: "pageSize", page: i + 1, bm: [a.w, a.h], takumi: [b.w, b.h] });
    const td = textDiff(a.text, b.text);
    if (td) d.push({ what: td.sameIgnoringSpaces ? "textSpacing" : "text", page: i + 1, ...td });
    const ls = (l) => l.map((x) => `${x.url ?? "#p" + x.destPage}`).join(" | ");
    if (ls(a.links) !== ls(b.links)) d.push({ what: "linkTargets", page: i + 1, bm: ls(a.links), takumi: ls(b.links) });
    else for (let k = 0; k < a.links.length; k++) if (a.links[k].rect.some((v, j) => !near(v, b.links[k].rect[j], 1))) { d.push({ what: "linkRect", page: i + 1, link: k, bm: a.links[k].rect, takumi: b.links[k].rect }); break; }
    if ((a.otherAnnotations || []).join() !== (b.otherAnnotations || []).join()) d.push({ what: "annotations", page: i + 1, bm: a.otherAnnotations, takumi: b.otherAnnotations });
    const sa = structSig(a.structTree), sb = structSig(b.structTree);
    if (sa !== sb) { let k = 0; while (k < sa.length && sa[k] === sb[k]) k++; d.push({ what: "structTree", page: i + 1, at: k, bm: sa.slice(Math.max(0, k - 40), k + 60), takumi: sb.slice(Math.max(0, k - 40), k + 60) }); }
  }
  const ol = (o) => JSON.stringify(o);
  if (ol(bm.outline) !== ol(tk.outline)) d.push({ what: "outline", bm: ol(bm.outline).slice(0, 400), takumi: ol(tk.outline).slice(0, 400) });
  const at = (x) => JSON.stringify(x.attachments.map((a) => [a.name, a.bytes, a.description]).sort());
  if (at(bm) !== at(tk)) d.push({ what: "attachments", bm: at(bm), takumi: at(tk) });
  for (const k of ["version", "title", "author", "subject", "keywords", "creator", "creationDate", "language"]) if ((bm.metadata[k] ?? null) !== (tk.metadata[k] ?? null)) d.push({ what: "metadata." + k, bm: bm.metadata[k], takumi: tk.metadata[k] });
  const xa = JSON.stringify(bm.xmpClaims ?? null), xb = JSON.stringify(tk.xmpClaims ?? null);
  if (xa !== xb) d.push({ what: "xmpConformance", bm: xa, takumi: xb });
  if (JSON.stringify(bm.markInfo) !== JSON.stringify(tk.markInfo)) d.push({ what: "markInfo", bm: bm.markInfo, takumi: tk.markInfo });
  return d;
}

/** The XMP claims of a bm PDF vs the options of its document. */
function claims(doc, x) {
  x = x || {};
  const get = (re) => { const [ns, prop] = re.source.split(":"); return x[ns]?.[prop] ?? null; };
  const out = [];
  if (doc.pdfa) {
    const part = get(/pdfaid:part/i), conf = get(/pdfaid:conformance/i);
    const want = { part: doc.pdfa[0], conf: doc.pdfa.slice(1).toUpperCase() || null };
    if (part !== want.part || (want.conf && (conf || "").toUpperCase() !== want.conf) || (!want.conf && conf)) out.push(issue("claims", "error", `XMP pdfaid part=${part} conformance=${conf}, the options ask for PDF/A-${doc.pdfa}`));
  } else if (get(/pdfaid:part/i)) out.push(issue("claims", "error", `XMP claims PDF/A-${get(/pdfaid:part/i)} without a pdfa option`));
  if (doc.tagged === "ua1" || doc.tagged === "ua2") {
    const part = get(/pdfuaid:part/i);
    if (part !== doc.tagged.slice(2)) out.push(issue("claims", "error", `XMP pdfuaid part=${part}, the options ask for PDF/UA-${doc.tagged.slice(2)}`));
  }
  return out;
}

// ------------------------------------------------------------------------------------------------ run
const results = [];
let chain = Promise.resolve();
const serial = (fn) => { const p = chain.then(fn); chain = p.catch(() => {}); return p; };
const vera = []; // [engine, profile, file, doc id]
const MAX_PAGES = 100000;
let k = 0;
for (const d of manifest.docs) {
  k++;
  const row = { id: d.id, group: d.group, pdfa: d.pdfa, tagged: d.tagged, identity: { nativeEqualsWasm: d.nativeEqualsWasm ?? null, syncEqualsAsync: d.engines["bm-native"]?.syncSameBytes ?? null }, engines: {}, semantic: null };
  const pj = {};
  const tasks = ENG.map((e) => async () => {
    const r = d.engines[e];
    if (!r?.ok) return [e, { renderError: r?.error ?? "not rendered" }];
    const file = fileOf(e, d.id);
    const bytes = new Uint8Array(readFileSync(file));
    const big = bytes.length > 20e6;
    const [q, c, p] = await Promise.all([qpdfCheck(file), pdfcpuCheck(file), popplerCheck(file)]);
    // the in-process parsers capture console output, so they run one at a time
    const [m, j] = await serial(async () => [await mupdfCheck(bytes, big ? 20 : MAX_PAGES), await inspect(bytes, { structure: !big })]);
    pj[e] = j; j.xmpClaims = m.xmp;
    const pjIssues = (j.warnings || []).map((w) => issue("pdfjs", /error/i.test(w) ? "error" : "warning", w));
    if (j.error) pjIssues.push(issue("pdfjs", "error", j.error));
    for (const prof of profilesOf(d)) if (tools.java && tools.verapdf && !args["no-verapdf"]) vera.push([e, prof, file, d.id]);
    const issues = [...q.issues, ...c.issues, ...p.issues, ...m.issues, ...pjIssues, ...(e.startsWith("bm-") ? claims(d, m.xmp) : [])];
    return [e, { xmp: m.xmp, bytes: bytes.length, pages: j.numPages ?? p.pages, version: q.version ?? p.version, linearized: q.linearized, tagged: p.tagged, fonts: p.fonts, issues }];
  });
  for (const [e, v] of await limit(JOBS, tasks)) row.engines[e] = v;
  if (pj["bm-native"] && pj["takumi-pdf"]) row.semantic = semantic(pj["bm-native"], pj["takumi-pdf"]);
  else if (pj["bm-wasm"] && pj["takumi-pdf"]) row.semantic = semantic(pj["bm-wasm"], pj["takumi-pdf"]);
  results.push(row);
  const bmIss = BM.reduce((s, e) => s + (row.engines[e]?.issues?.length ?? 0), 0);
  log(`  [${k}/${manifest.docs.length}] ${d.id.padEnd(44)} bm issues ${bmIss}, takumi ${row.engines["takumi-pdf"]?.issues?.length ?? "-"}, semantic diffs ${row.semantic?.length ?? "-"}`);
}

// veraPDF, grouped by profile (one JVM start per profile and batch)
if (vera.length) {
  const byProfile = new Map();
  for (const v of vera) { if (!byProfile.has(v[1])) byProfile.set(v[1], []); byProfile.get(v[1]).push(v); }
  for (const [prof, list] of byProfile) {
    log(`  veraPDF -f ${prof}: ${list.length} files`);
    const rep = await verapdfBatch(prof, list.map((v) => v[2]));
    for (const [e, , file, id] of list) {
      const r = rep.get(path.resolve(file)) ?? { error: "missing from veraPDF report" };
      const row = results.find((x) => x.id === id);
      (row.engines[e].verapdf ??= {})[prof] = r;
      if (r.error) row.engines[e].issues.push(issue("verapdf", "error", `[${prof}] ${r.error}`));
      else for (const ru of r.rules) row.engines[e].issues.push(issue("verapdf", "error", `[${prof}] ${ru.spec} ${ru.clause}-${ru.test}: ${ru.description}`, { failedChecks: ru.failedChecks, object: ru.object, contexts: ru.contexts, detail: ru.message }));
    }
  }
}

// classify bm issues against takumi-pdf
const key = (i) => i.tool + "|" + i.message.replace(/obj#:?\s*\d+/g, "obj#N").replace(/\d+ 0 (obj|R)/g, "N 0 $1").replace(/object ID \d+/g, "");
for (const row of results) {
  const tk = new Set((row.engines["takumi-pdf"]?.issues ?? []).map(key));
  for (const e of BM) for (const i of row.engines[e]?.issues ?? []) i.class = tk.has(key(i)) ? "shared" : "bm-only";
}

// ------------------------------------------------------------------------------------------------ summary
const summary = { docs: results.length, engines: ENG, byEngine: {}, identity: {}, semantic: {}, verapdf: {}, tools: {} };
for (const e of ENG) {
  const rows = results.map((r) => r.engines[e]).filter(Boolean);
  const iss = rows.flatMap((r) => r.issues ?? []);
  summary.byEngine[e] = {
    rendered: rows.filter((r) => !r.renderError).length, renderErrors: rows.filter((r) => r.renderError).length,
    clean: rows.filter((r) => !r.renderError && !(r.issues ?? []).length).length,
    errors: iss.filter((i) => i.severity === "error").length, warnings: iss.filter((i) => i.severity === "warning").length,
    bmOnly: e.startsWith("bm-") ? iss.filter((i) => i.class === "bm-only").length : null, shared: e.startsWith("bm-") ? iss.filter((i) => i.class === "shared").length : null,
    byTool: iss.reduce((m, i) => ((m[i.tool] = (m[i.tool] ?? 0) + 1), m), {}),
    fontsNotEmbedded: rows.flatMap((r) => r.fonts ?? []).filter((f) => f.emb === false).length,
    fontsNotSubset: rows.flatMap((r) => r.fonts ?? []).filter((f) => f.emb && f.sub === false && f.type !== "Type 3").length,
    linearized: rows.filter((r) => r.linearized).length,
  };
}
const idRows = results.filter((r) => r.identity.nativeEqualsWasm !== null);
summary.identity = { compared: idRows.length, nativeEqualsWasm: idRows.filter((r) => r.identity.nativeEqualsWasm === true).length, sameErrorBoth: idRows.filter((r) => r.identity.nativeEqualsWasm === "same-error").length, mismatches: idRows.filter((r) => r.identity.nativeEqualsWasm === false).map((r) => r.id), syncEqualsAsync: results.filter((r) => r.identity.syncEqualsAsync === true).length, syncMismatches: results.filter((r) => r.identity.syncEqualsAsync === false).map((r) => r.id) };
const semRows = results.filter((r) => r.semantic);
summary.semantic = { compared: semRows.length, identical: semRows.filter((r) => !r.semantic.length).length, byKind: semRows.flatMap((r) => r.semantic).reduce((m, x) => ((m[x.what] = (m[x.what] ?? 0) + 1), m), {}) };
for (const e of ENG) {
  const v = results.flatMap((r) => Object.entries(r.engines[e]?.verapdf ?? {}).map(([p, x]) => ({ id: r.id, p, x })));
  summary.verapdf[e] = { runs: v.length, compliant: v.filter((y) => y.x.compliant).length, failing: v.filter((y) => !y.x.compliant).map((y) => `${y.id} [${y.p}]`) };
}
for (const [k2, p] of Object.entries(tools)) summary.tools[k2] = p ? path.relative(ROOT, p).split(path.sep).join("/") : null;
const tm = toolsManifest().tools;
// (a tool installed outside setup.mjs, e.g. from the system packages on Linux, records its own version in .ok.json)
const installed = (name) => { try { return JSON.parse(readFileSync(path.join(path.dirname(findBin(name, Object.keys(tm[name].bin)[0]) || ''), '.ok.json'), 'utf8')).version; } catch { return null; } };
const tv = (name) => installed(name) ?? tm[name]?.version;
summary.toolVersions = { qpdf: tv('qpdf'), pdfcpu: tv('pdfcpu'), poppler: tv('poppler'), jre: tv('jre'), verapdf: tv('verapdf'), pdfjs: pkgV("pdfjs-dist"), mupdf: pkgV("mupdf"), takumiPdf: manifest.versions?.['takumi-pdf']?.version ?? pkgV("takumi-pdf") };
function pkgV(p) { try { return JSON.parse(readFileSync(path.join(ROOT, "bench", "pdf", "node_modules", ...p.split("/"), "package.json"), "utf8")).version; } catch { return null; } }

const out = { date: new Date().toISOString(), build: { date: manifest.date, versions: manifest.versions, seconds: manifest.seconds }, args: process.argv.slice(2), gate, missingTools: missing, summary, docs: results, seconds: +((performance.now() - T0) / 1000).toFixed(1) };
writeFileSync(path.join(OUT_DIR, "validation.json"), JSON.stringify(out, null, 1));
writeFileSync(path.join(OUT_DIR, "VALIDATION.md"), markdown(out));
rmSync(TMP, { recursive: true, force: true });

// gate
const bmIssues = results.flatMap((r) => BM.flatMap((e) => (r.engines[e]?.issues ?? []).map((i) => ({ ...i, id: r.id, engine: e }))));
const bmRenderErrors = results.flatMap((r) => BM.filter((e) => r.engines[e]?.renderError).map((e) => `${r.id} ${e}: ${r.engines[e].renderError}`));
let failed = summary.identity.mismatches.length + summary.identity.syncMismatches.length;
if (gate === "all") failed += bmIssues.length + bmRenderErrors.length;
if (gate === "bm-only") failed += bmIssues.filter((i) => i.class === "bm-only").length + bmRenderErrors.length;
log(`validate: ${results.length} docs; bm-native ${JSON.stringify(summary.byEngine["bm-native"] ?? {})}`);
log(`  identity native==wasm ${summary.identity.nativeEqualsWasm}/${summary.identity.compared} (mismatch: ${summary.identity.mismatches.join(", ") || "none"}); semantic identical ${summary.semantic.identical}/${summary.semantic.compared}`);
log(`  wrote ${path.join(OUT_DIR, "validation.json")} and VALIDATION.md in ${out.seconds} s; gate=${gate}: ${gate === "none" || !failed ? "pass" : "FAIL (" + failed + ")"}`);
process.exit(gate !== "none" && failed ? 1 : 0);

// ------------------------------------------------------------------------------------------------ report
function markdown(o) {
  const s = o.summary;
  const L = [];
  L.push("# PDF validation (bench/pdf/validate.mjs)", "", `Generated ${o.date} by \`node bench/pdf/validate.mjs\`; do not edit. Build ${o.build.date}.`, "");
  L.push("## Tools", "", "| Tool | Version | Path |", "|:--|:--|:--|");
  for (const [k2, v] of Object.entries(s.toolVersions)) {
    const toolKey = ({ poppler: 'pdfinfo', jre: 'java' })[k2] ?? k2;
    const reference = o.build.versions?.['takumi-pdf'];
    const location = k2 === 'takumiPdf' ? reference?.file ?? 'npm (bench/pdf/node_modules)' : s.tools[toolKey] ?? (['pdfjs', 'mupdf'].includes(k2) ? 'npm (bench/pdf/node_modules)' : 'not installed');
    L.push(`| ${k2} | ${v ?? '—'} | ${location} |`);
  }
  const ref = o.build.versions?.['takumi-pdf']?.reference;
  if (ref) L.push('', `Reference: ${ref.kind}${ref.revision ? ' at ' + ref.revision : ''}.`);
  L.push("", "## Summary per engine", "", "| Engine | rendered | render errors | clean PDFs | errors | warnings | bm-only | shared with takumi-pdf | fonts not embedded / not subset | issues by tool |", "|:--|--:|--:|--:|--:|--:|--:|--:|:--|:--|");
  for (const [e, v] of Object.entries(s.byEngine)) L.push(`| ${e} | ${v.rendered} | ${v.renderErrors} | ${v.clean} | ${v.errors} | ${v.warnings} | ${v.bmOnly ?? "—"} | ${v.shared ?? "—"} | ${v.fontsNotEmbedded} / ${v.fontsNotSubset} | ${Object.entries(v.byTool).map(([t, n]) => `${t} ${n}`).join(", ") || "—"} |`);
  L.push("", `**Identity:** bm-native == bm-wasm byte for byte in ${s.identity.nativeEqualsWasm}/${s.identity.compared} documents (same error on both: ${s.identity.sameErrorBoth}; mismatches: ${s.identity.mismatches.join(", ") || "none"}). bm-native sync == async in ${s.identity.syncEqualsAsync} (mismatches: ${s.identity.syncMismatches.join(", ") || "none"}).`);
  L.push("", `**Semantics vs takumi-pdf (pdf.js):** ${s.semantic.identical}/${s.semantic.compared} documents identical; differences by kind: ${Object.entries(s.semantic.byKind).map(([k2, n]) => `${k2} ${n}`).join(", ") || "none"}.`);
  L.push("", "**veraPDF:** " + Object.entries(s.verapdf).map(([e, v]) => `${e} ${v.compliant}/${v.runs} compliant`).join("; ") + ".");
  L.push("", "## Issues on bm PDFs, grouped", "");
  const groups = new Map();
  for (const r of o.docs) for (const e of ["bm-native", "bm-wasm"]) for (const i of r.engines[e]?.issues ?? []) {
    const g = `${i.class} | ${i.tool} | ${i.severity} | ${i.message}`;
    if (!groups.has(g)) groups.set(g, { i, docs: new Set(), engines: new Set() });
    groups.get(g).docs.add(r.id); groups.get(g).engines.add(e);
  }
  if (!groups.size) L.push("None.");
  else {
    L.push("| class | tool | severity | message (verbatim) | engines | documents |", "|:--|:--|:--|:--|:--|:--|");
    for (const [, g] of [...groups].sort((a, b) => (a[1].i.class === b[1].i.class ? b[1].docs.size - a[1].docs.size : a[1].i.class === "bm-only" ? -1 : 1))) {
      const docs = [...g.docs];
      L.push(`| ${g.i.class} | ${g.i.tool} | ${g.i.severity} | ${g.i.message.replace(/\|/g, "\\|").slice(0, 300)}${g.i.object ? ` (object ${g.i.object}${g.i.contexts?.length ? ", " + g.i.contexts[0] : ""})` : ""} | ${[...g.engines].join(", ")} | ${docs.length}: ${docs.slice(0, 6).map((x) => "`" + x + "`").join(", ")}${docs.length > 6 ? ", …" : ""} |`);
    }
  }
  L.push("", "## Issues on takumi-pdf PDFs (baseline), grouped", "");
  const tg = new Map();
  for (const r of o.docs) for (const i of r.engines["takumi-pdf"]?.issues ?? []) { const g = `${i.tool} | ${i.severity} | ${i.message}`; if (!tg.has(g)) tg.set(g, []); tg.get(g).push(r.id); }
  if (!tg.size) L.push("None.");
  else { L.push("| tool | severity | message | documents |", "|:--|:--|:--|:--|"); for (const [g, ids] of tg) { const [t, sv, ...m] = g.split(" | "); L.push(`| ${t} | ${sv} | ${m.join(" | ").replace(/\|/g, "\\|").slice(0, 300)} | ${ids.length}: ${ids.slice(0, 5).map((x) => "`" + x + "`").join(", ")}${ids.length > 5 ? ", …" : ""} |`); } }
  L.push("", "## Render errors", "");
  const re = o.docs.flatMap((r) => Object.entries(r.engines).filter(([, v]) => v.renderError).map(([e, v]) => `- \`${r.id}\` ${e}: ${v.renderError}`));
  L.push(re.length ? re.join("\n") : "None.");
  L.push("", "## Semantic differences bm-native vs takumi-pdf", "");
  const sd = o.docs.filter((r) => r.semantic?.length);
  if (!sd.length) L.push("None.");
  for (const r of sd) {
    L.push(`- \`${r.id}\`: ` + r.semantic.slice(0, 6).map((x) => {
      if (x.what === "text" || x.what === "textSpacing") return `${x.what} p${x.page} @${x.at}: bm «${x.bm}» vs takumi «${x.takumi}»`;
      return `${x.what}${x.page ? " p" + x.page : ""}: bm ${JSON.stringify(x.bm)} vs takumi ${JSON.stringify(x.takumi)}`;
    }).join("; ").replace(/\|/g, "\\|") + (r.semantic.length > 6 ? `; … (${r.semantic.length})` : ""));
  }
  L.push("", "## Per document", "", "| Document | bm bytes | takumi bytes | pages | bm issues | takumi issues | native==wasm | semantic diffs |", "|:--|--:|--:|--:|--:|--:|:--|--:|");
  for (const r of o.docs) L.push(`| \`${r.id}\` | ${r.engines["bm-native"]?.bytes ?? r.engines["bm-wasm"]?.bytes ?? "err"} | ${r.engines["takumi-pdf"]?.bytes ?? "err"} | ${r.engines["bm-native"]?.pages ?? "—"} / ${r.engines["takumi-pdf"]?.pages ?? "—"} | ${r.engines["bm-native"]?.issues?.length ?? "—"} | ${r.engines["takumi-pdf"]?.issues?.length ?? "—"} | ${r.identity.nativeEqualsWasm} | ${r.semantic?.length ?? "—"} |`);
  return L.join("\n") + "\n";
}

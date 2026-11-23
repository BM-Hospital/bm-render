// Paint probes: what bm-render/pdf and takumi-pdf write into a page for CSS paint features (backgrounds,
// gradients, borders, shadows, filters, compositing, clips, masks, transforms).
//
// The comparison is structural and strict: each page's content stream is tokenised and every resource it names
// (`gs`, `Do`, `scn`, `sh`, `Tf`, `cs`) is replaced by a canonical expansion of the object it points at: an
// ExtGState with its soft mask's form, a form XObject with its `/Group` and its own expanded content, a pattern
// with its shading and functions, an image with its dictionary and a hash of its decoded data. Two pages are
// "identical" when the two token lists are equal with numbers within NUM_TOL. A page that draws the same thing by
// another mechanism (a raster image where the reference writes a shading, a missing soft mask, another operator
// order) therefore fails, and so does an error on one side only.
//
// This file also exports the helpers images.probe.mjs and text-paint.probe.mjs use.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { INTER, Name, Ref, outDir, pdftotext, probe, root, takumiSrc } from "./lib.mjs";

let currentId = "";
/** `probe()` that also remembers the running probe's id (dump file names). */
export function probeAs(id, feature, fn) { probe(id, feature, async (t) => { currentId = id; try { await fn(t); } finally { currentId = ""; } }); }

// ------------------------------------------------------------------------------------------------ canonical pages

const NUM_TOL = 0.011;
const WS = " \t\r\n\f\0";
const DELIM = "()<>[]{}/%";

/** Tokens of a content stream: numbers, `/Name`, `(str)`, `<hex>`, `[`, `]`, `<<`, `>>`, operators. */
export function tokenize(s) {
  const out = [];
  let i = 0;
  const n = s.length;
  while (i < n) {
    const c = s[i];
    if (WS.includes(c)) { i++; continue; }
    if (c === "%") { while (i < n && s[i] !== "\n" && s[i] !== "\r") i++; continue; }
    if (c === "(") {
      let depth = 0; let j = i + 1; let str = "";
      for (; j < n; j++) {
        const ch = s[j];
        if (ch === "\\") { str += ch + s[j + 1]; j++; continue; }
        if (ch === "(") depth++;
        if (ch === ")") { if (depth === 0) break; depth--; }
        str += ch;
      }
      out.push("(" + Buffer.from(str, "latin1").toString("hex") + ")"); i = j + 1; continue;
    }
    if (c === "<" && s[i + 1] === "<") { out.push("<<"); i += 2; continue; }
    if (c === ">" && s[i + 1] === ">") { out.push(">>"); i += 2; continue; }
    if (c === "<") { const e = s.indexOf(">", i); out.push("<" + s.slice(i + 1, e).replace(/\s/g, "").toUpperCase() + ">"); i = e + 1; continue; }
    if (c === "[" || c === "]") { out.push(c); i++; continue; }
    if (c === "/") { let j = i + 1; while (j < n && !WS.includes(s[j]) && !DELIM.includes(s[j])) j++; out.push(s.slice(i, j)); i = j; continue; }
    let j = i; while (j < n && !WS.includes(s[j]) && !DELIM.includes(s[j])) j++;
    if (j === i) { i++; continue; }
    const w = s.slice(i, j);
    out.push(/^[+-]?(\d+\.?\d*|\.\d+)$/.test(w) ? Number(w) : w);
    i = j;
    if (w === "ID") { const e = s.indexOf("EI", i); out.push("<inline " + (e - i) + ">"); i = e < 0 ? n : e; }
  }
  return out;
}

const SKIP_KEYS = new Set(["Length", "Parent", "StructParents", "StructParent", "Resources", "ProcSet", "Contents", "Type", "Metadata", "LastModified", "PieceInfo"]);
const RES_OF_OP = { gs: "ExtGState", Do: "XObject", sh: "Shading", Tf: "Font", scn: "Pattern", SCN: "Pattern", cs: "ColorSpace", CS: "ColorSpace" };
const hash = (buf) => createHash("sha1").update(buf).digest("hex").slice(0, 12);
const isName = (v, s) => v instanceof Name && (s === undefined || v.s === s);

/** Canonical tokens of every page of a described render (lib.mjs `describe`). */
export function canonPages(d) {
  const pdf = d.pdf;
  const stack = new Set();
  const res = (dict) => { let n = dict; while (n && n.Resources === undefined && n.Parent) n = pdf.resolve(n.Parent); return (n && pdf.resolve(n.Resources)) || {}; };

  const value = (v, out, resources) => {
    if (v instanceof Ref) {
      const o = pdf.obj(v);
      if (!o) { out.push("null"); return; }
      if (stack.has(o.n)) { out.push("<cycle>"); return; }
      stack.add(o.n);
      object(o, out, resources);
      stack.delete(o.n);
      return;
    }
    if (typeof v === "number") { out.push(v); return; }
    if (v instanceof Name) { out.push("/" + v.s); return; }
    if (Array.isArray(v)) { out.push("["); for (const x of v) value(x, out, resources); out.push("]"); return; }
    if (v === null || v === undefined) { out.push("null"); return; }
    if (typeof v === "boolean") { out.push(String(v)); return; }
    if (v.hex !== undefined) { out.push("<" + v.hex.toUpperCase() + ">"); return; }
    if (v.str !== undefined) { out.push("(" + Buffer.from(v.str, "latin1").toString("hex") + ")"); return; }
    if (v.op !== undefined) { out.push(v.op); return; }
    dictionary(v, out, resources);
  };
  const dictionary = (dict, out, resources) => {
    out.push("<<");
    for (const k of Object.keys(dict).sort()) { if (SKIP_KEYS.has(k)) continue; out.push("/" + k); value(dict[k], out, resources); }
    out.push(">>");
  };
  const object = (o, out, resources) => {
    const dict = o.dict;
    if (!dict || typeof dict !== "object" || Array.isArray(dict) || dict instanceof Name) { value(dict, out, resources); return; }
    if (isName(dict.Type, "Font") || dict.FontFile2 || dict.FontFile3) { font(dict, out); return; }
    const sub = dict.Subtype instanceof Name ? dict.Subtype.s : "";
    if (sub === "Image") {
      out.push("{Image");
      dictionary(Object.fromEntries(Object.entries(dict).filter(([k]) => k !== "Subtype")), out, resources);
      out.push("data:" + (o.data ? o.data.length + ":" + hash(o.data) : "none"), "}");
      return;
    }
    if (sub === "Form") {
      out.push("{Form");
      dictionary(Object.fromEntries(Object.entries(dict).filter(([k]) => k !== "Subtype" && k !== "Filter")), out, resources);
      content(o.data ? o.data.toString("latin1") : "", pdf.resolve(dict.Resources) || {}, out);
      out.push("}");
      return;
    }
    if (dict.PatternType === 1) {
      out.push("{TilingPattern");
      dictionary(Object.fromEntries(Object.entries(dict).filter(([k]) => k !== "Filter")), out, resources);
      content(o.data ? o.data.toString("latin1") : "", pdf.resolve(dict.Resources) || {}, out);
      out.push("}");
      return;
    }
    if (dict.FunctionType !== undefined && o.data) {
      out.push("{Function");
      dictionary(Object.fromEntries(Object.entries(dict).filter(([k]) => k !== "Filter")), out, resources);
      if (dict.FunctionType === 4) for (const tk of tokenize(o.data.toString("latin1"))) out.push(tk); else out.push("data:" + hash(o.data));
      out.push("}");
      return;
    }
    if (o.data && dict.N !== undefined && (dict.Alternate !== undefined || dict.Range !== undefined || Object.keys(dict).every((k) => ["N", "Length", "Filter", "Range", "Alternate"].includes(k)))) {
      out.push("{ICC n=" + dict.N + " " + o.data.length + ":" + hash(o.data) + "}");
      return;
    }
    if (o.data) { out.push("{Stream"); dictionary(Object.fromEntries(Object.entries(dict).filter(([k]) => k !== "Filter")), out, resources); out.push("data:" + o.data.length + ":" + hash(o.data), "}"); return; }
    dictionary(dict, out, resources);
  };
  const font = (dict, out) => {
    const sub = dict.Subtype instanceof Name ? dict.Subtype.s : "?";
    if (sub !== "Type3") { out.push("{Font " + sub + " " + String(dict.BaseFont || "").replace(/^\/[A-Z]{6}\+/, "") + "}"); return; }
    out.push("{Font Type3");
    out.push("/FontMatrix"); value(dict.FontMatrix, out, {});
    const procs = pdf.resolve(dict.CharProcs) || {};
    const r = pdf.resolve(dict.Resources) || {};
    for (const k of Object.keys(procs).sort()) { const o = pdf.obj(procs[k]); out.push("/" + k, "{"); content(o && o.data ? o.data.toString("latin1") : "", r, out); out.push("}"); }
    out.push("}");
  };
  const content = (text, resources, out) => {
    const toks = tokenize(text);
    const pending = [];
    for (const tk of toks) {
      if (typeof tk === "string" && !/^[/(<[\]>]/.test(tk) && tk !== "<<" && tk !== ">>") {
        // an operator: resolve its name operands
        const kind = RES_OF_OP[tk];
        if (kind) {
          const idx = tk === "Tf" ? pending.length - 2 : pending.length - 1;
          const nm = pending[idx];
          if (typeof nm === "string" && nm.startsWith("/")) {
            const table = pdf.resolve(resources[kind]) || {};
            const target = table[nm.slice(1)];
            if (target !== undefined) {
              const sub = [];
              value(target, sub, resources);
              pending.splice(idx, 1, ...sub);
            }
          }
        }
        for (const p of pending) out.push(p);
        pending.length = 0;
        out.push(tk);
      } else pending.push(tk);
    }
    for (const p of pending) out.push(p);
  };

  return d.pdf.pages.map((p) => {
    const out = [];
    const c = p.dict.Contents; const list = Array.isArray(c) ? c : [c];
    const text = list.map((r) => { const o = pdf.obj(r); return o && o.data ? o.data.toString("latin1") : ""; }).join("\n");
    content(text, res(p.dict), out);
    return out;
  });
}

const OPERATORS = new Set("b B b* B* BDC BI BMC BT BX c cm CS cs d d0 d1 Do DP EI EMC ET EX f F f* G g gs h i ID j J K k l m M MP n q Q re RG rg ri s S SC sc SCN scn sh T* Tc Td TD Tf Tj TJ TL Tm Tr Ts Tw Tz v w W W* y ' \"".split(" "));

/** First difference of two canonical token lists, or null: `{ at, bm, ref }` with the tokens around it. */
export function firstDiff(a, b, tol = NUM_TOL) {
  const n = Math.min(a.length, b.length);
  let i = 0;
  for (; i < n; i++) {
    const x = a[i]; const y = b[i];
    if (typeof x === "number" && typeof y === "number") { if (Math.abs(x - y) > tol + 1e-3 * Math.max(Math.abs(x), Math.abs(y))) break; } else if (x !== y) break;
  }
  if (i === n && a.length === b.length) return null;
  const ctx = (t) => t.slice(Math.max(0, i - 14), i).map(short).join(" ") + " >>>" + t.slice(i, i + 14).map(short).join(" ");
  return { at: i, bm: ctx(a), ref: ctx(b), lens: [a.length, b.length] };
}
const short = (t) => (typeof t === "number" ? String(Math.round(t * 1000) / 1000) : String(t).length > 40 ? String(t).slice(0, 40) + "…" : String(t));

/** The operators of a canonical token list, in order (nested streams included). */
export const opsOnly = (toks) => toks.filter((t) => typeof t === "string" && OPERATORS.has(t));

/** What a page is made of, as a short string: operator counts and the kinds of resources. */
export function summary(toks) {
  const count = new Map();
  const add = (k) => count.set(k, (count.get(k) || 0) + 1);
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (typeof t !== "string") continue;
    if (t === "{Image") {
      const end = toks.indexOf("}", i);
      const seg = toks.slice(i, end < 0 ? i + 60 : end);
      const get = (k) => { const j = seg.indexOf("/" + k); return j < 0 ? undefined : seg[j + 1]; };
      const cs = get("ColorSpace");
      add(`Image ${get("Width")}x${get("Height")} ${cs === "[" ? "[" + seg[seg.indexOf("/ColorSpace") + 2] + "…]" : String(cs).startsWith("{ICC") ? "ICCBased" : cs} bpc${get("BitsPerComponent")} ${get("Filter") || "raw"}${seg.includes("/DecodeParms") ? "+pred" : ""}${seg.includes("/SMask") ? " +SMask" : ""}${seg.includes("/Interpolate") ? " interp=" + get("Interpolate") : ""}`);
    } else if (t === "{Form") add(toks.slice(i, i + 40).includes("/Group") ? "Form+Group" : "Form");
    else if (t === "{TilingPattern") add("TilingPattern");
    else if (t === "/ShadingType") add("Shading" + toks[i + 1]);
    else if (t === "/FunctionType") add("Function" + toks[i + 1]);
    else if (t === "/Luminosity" || t === "/Alpha") add("SMask" + t);
    else if (t === "/BM") add("BM" + toks[i + 1]);
    else if (t === "/ca") add("ca");
    else if (t.startsWith("{Font")) add(t.replace(/[{}]/g, "").split(" ").slice(0, 2).join(":"));
    else if (t.startsWith("{ICC")) add("ICC");
    else if (OPERATORS.has(t) && !["q", "Q", "m", "l", "c", "h", "cm", "gs", "BDC", "EMC", "BMC"].includes(t)) add(t);
  }
  return [...count].map(([k, v]) => (v > 1 ? k + "×" + v : k)).join(", ");
}

// ------------------------------------------------------------------------------------------------ draw lists
// The second level of comparison. Two content streams can differ in form only: takumi closes and reopens a clip
// around every paint chunk where bm-render keeps it open, or folds a translation into another `cm`. `flatten`
// interprets a canonical page (graphics state stack, CTM, clip stack, colours, ExtGState, text matrix) and returns
// the list of things actually drawn, each with its geometry in device space, its paint, its effective clips and its
// transparency parameters. Equal draw lists mean the same marks in the same order under the same clips.

const mul = (m, n) => [m[0] * n[0] + m[1] * n[2], m[0] * n[1] + m[1] * n[3], m[2] * n[0] + m[3] * n[2], m[2] * n[1] + m[3] * n[3], m[4] * n[0] + m[5] * n[2] + n[4], m[4] * n[1] + m[5] * n[3] + n[5]];
const pt = (m, x, y) => [x * m[0] + y * m[2] + m[4], x * m[1] + y * m[3] + m[5]];
const ID = [1, 0, 0, 1, 0, 0];

/** Canonical tokens as a tree: numbers and atoms, `{k:"arr"|"dict"|"grp", head?, items}`. */
function tree(toks) {
  let i = 0;
  const items = (end) => {
    const out = [];
    while (i < toks.length) {
      const t = toks[i++];
      if (t === end) return out;
      if (t === "[") out.push({ k: "arr", items: items("]") });
      else if (t === "<<") out.push({ k: "dict", items: items(">>") });
      else if (typeof t === "string" && t.startsWith("{") && !t.endsWith("}")) out.push({ k: "grp", head: t.slice(1), items: items("}") });
      else out.push(t);
    }
    return out;
  };
  return items(null);
}
const untree = (n, out = []) => {
  if (n === null || typeof n !== "object") { out.push(n); return out; }
  out.push(n.k === "arr" ? "[" : n.k === "dict" ? "<<" : "{" + n.head);
  for (const x of n.items) untree(x, out);
  out.push(n.k === "arr" ? "]" : n.k === "dict" ? ">>" : "}");
  return out;
};
const dictGet = (d, key) => { if (!d || d.k !== "dict") return undefined; for (let j = 0; j + 1 < d.items.length; j += 2) if (d.items[j] === "/" + key) return d.items[j + 1]; return undefined; };
const dictWithout = (d, keys) => { const items = []; for (let j = 0; j + 1 < d.items.length; j += 2) if (!keys.includes(d.items[j])) items.push(d.items[j], d.items[j + 1]); return { k: "dict", items }; };

/** The draw list of one canonical page (see above), as a flat token list for `firstDiff`. */
export function flatten(toks) {
  const out = [];
  const fresh = (ctm) => ({ ctm, clips: [], clipKeys: [], gs: {}, fill: ["g", 0], stroke: ["G", 0], w: 1, J: 0, j: 0, d: [], font: [], Tr: 0, Tc: 0, Tw: 0 });
  const run = (nodes, st0, base) => {
    let st = st0;
    const stack = [];
    let ops = [];
    let path = [];
    let pendingClip = null;
    let tm = ID; let tlm = ID;
    const paint = (which) => {
      const p = which === "fill" ? st.fill : st.stroke;
      for (const x of p) {
        if (x && typeof x === "object" && x.k === "dict" && dictGet(x, "PatternType") !== undefined) {
          const m = dictGet(x, "Matrix");
          out.push("PATTERN", ...mul(m ? m.items : ID, base));
          untree(dictWithout(x, ["/Matrix"]), out);
        } else if (x && typeof x === "object" && x.k === "grp" && x.head === "TilingPattern") {
          const d = x.items[0]; const m = dictGet(d, "Matrix");
          out.push("TILING", ...mul(m ? m.items : ID, base));
          untree(dictWithout(d, ["/Matrix"]), out);
          out.push("TILE[");
          run(x.items.slice(1), fresh(ID), ID);
          out.push("]");
        } else untree(x, out);
      }
    };
    const form = (g, ctm, state) => {
      const d = g.items[0];
      const m = dictGet(d, "Matrix");
      const inner = mul(m ? m.items : ID, ctm);
      const grp = dictGet(d, "Group");
      out.push("FORM[");
      if (grp) untree(grp, out);
      run(g.items.slice(1), { ...state, ctm: inner }, inner);
      out.push("]");
    };
    const context = () => {
      out.push("CLIP[");
      for (const c of st.clips) out.push(...c);
      out.push("]");
      for (const k of Object.keys(st.gs).sort()) {
        const v = st.gs[k];
        if (k === "ca" || k === "CA") { if (v !== 1) out.push(k, v); continue; }
        if (k === "BM") { if (v !== "/Normal") out.push(k, v); continue; }
        if (k === "SMask") {
          if (v.node === "/None") continue;
          out.push("SMASK", dictGet(v.node, "S"), "[");
          const g = dictGet(v.node, "G");
          if (g && g.k === "grp") form(g, v.ctm, fresh(ID));
          out.push("]");
          continue;
        }
        out.push(k); untree(v, out);
      }
    };
    const strokeState = () => {
      const s = Math.sqrt(Math.abs(st.ctm[0] * st.ctm[3] - st.ctm[1] * st.ctm[2]));
      out.push("w", st.w * s, "J", st.J, "j", st.j);
      if (st.d.length) out.push("d", ...st.d.map((x) => x * s));
    };
    for (const n of nodes) {
      if (typeof n !== "string" || !OPERATORS.has(n)) { ops.push(n); continue; }
      const a = ops; ops = [];
      switch (n) {
        case "q": stack.push(st); st = { ...st, clips: st.clips.slice(), clipKeys: st.clipKeys.slice(), gs: { ...st.gs } }; break;
        case "Q": if (stack.length) st = stack.pop(); break;
        case "cm": st = { ...st, ctm: mul(a, st.ctm) }; break;
        case "m": path.push("M", ...pt(st.ctm, a[0], a[1])); break;
        case "l": path.push("L", ...pt(st.ctm, a[0], a[1])); break;
        case "c": path.push("C", ...pt(st.ctm, a[0], a[1]), ...pt(st.ctm, a[2], a[3]), ...pt(st.ctm, a[4], a[5])); break;
        case "h": path.push("Z"); break;
        case "re": { const [x, y, w, h] = a; path.push("M", ...pt(st.ctm, x, y), "L", ...pt(st.ctm, x + w, y), "L", ...pt(st.ctm, x + w, y + h), "L", ...pt(st.ctm, x, y + h), "Z"); break; }
        case "W": case "W*": pendingClip = n; break;
        case "n": case "f": case "F": case "f*": case "S": case "s": case "B": case "B*": case "b": case "b*": {
          if (pendingClip) {
            const c = [pendingClip, ...path];
            const key = JSON.stringify(c.map((x) => (typeof x === "number" ? Math.round(x * 20) / 20 : x)));
            // the same clip pushed again inside itself adds nothing
            if (st.clipKeys[st.clipKeys.length - 1] !== key) { st.clips = [...st.clips, c]; st.clipKeys = [...st.clipKeys, key]; }
            pendingClip = null;
          }
          if (n !== "n") {
            out.push("DRAW:" + n, ...path);
            if (/^[fFbB]/.test(n)) { out.push("FILL"); paint("fill"); }
            if (/^[SsbB]/.test(n)) { out.push("STROKE"); paint("stroke"); strokeState(); }
            context();
          }
          path = [];
          break;
        }
        case "rg": case "g": case "k": case "sc": case "scn": st = { ...st, fill: n === "scn" || n === "sc" ? a : [n, ...a] }; break;
        case "RG": case "G": case "K": case "SC": case "SCN": st = { ...st, stroke: n === "SCN" || n === "SC" ? a : [n, ...a] }; break;
        case "w": st = { ...st, w: a[0] }; break;
        case "J": st = { ...st, J: a[0] }; break;
        case "j": st = { ...st, j: a[0] }; break;
        case "d": st = { ...st, d: a[0] && a[0].items ? a[0].items : [] }; break;
        case "gs": {
          const d = a[0];
          if (d && d.k === "dict") for (let j = 0; j + 1 < d.items.length; j += 2) {
            const key = d.items[j].slice(1); const v = d.items[j + 1];
            st.gs = { ...st.gs, [key]: key === "SMask" ? { node: v, ctm: st.ctm } : v };
          }
          break;
        }
        case "Do": {
          const g = a[a.length - 1];
          if (g && g.k === "grp" && g.head === "Form") { out.push("DO"); context(); form(g, st.ctm, fresh(ID)); } else if (g && g.k === "grp") { out.push("IMAGE", ...st.ctm); untree(g, out); context(); }
          break;
        }
        case "sh": out.push("SH", ...st.ctm); for (const x of a) untree(x, out); context(); break;
        case "BT": tm = ID; tlm = ID; break;
        case "Tm": tm = a.slice(0, 6); tlm = tm; break;
        case "Td": case "TD": tlm = mul([1, 0, 0, 1, a[0], a[1]], tlm); tm = tlm; break;
        case "Tf": st = { ...st, font: a }; break;
        case "Tr": st = { ...st, Tr: a[0] }; break;
        case "Tc": st = { ...st, Tc: a[0] }; break;
        case "Tw": st = { ...st, Tw: a[0] }; break;
        case "Tj": case "TJ": case "'": case "\"": {
          out.push("TEXT", ...mul(tm, st.ctm), "Tr", st.Tr, "Tc", st.Tc, "Tw", st.Tw);
          for (const x of st.font) untree(x, out);
          for (const x of a) untree(x, out);
          if (![1, 3, 7].includes(st.Tr)) { out.push("FILL"); paint("fill"); }
          if ([1, 2, 5, 6].includes(st.Tr)) { out.push("STROKE"); paint("stroke"); strokeState(); }
          context();
          break;
        }
        case "BDC": case "BMC": out.push(n); for (const x of a) untree(x, out); break;
        case "EMC": out.push(n); break;
        default: break;
      }
    }
  };
  run(tree(toks), fresh(ID), ID);
  return out;
}

// ------------------------------------------------------------------------------------------------ the comparison

/**
 * Renders `source` with both engines and compares the canonical pages. Fails on: an error on one side only or
 * different error messages, a different page count, different pages. Notes what takumi wrote (operator / resource
 * summary), so the probe output documents the mechanism.
 * `opt.mode`: "exact" (default), or "ops" to compare only the operator sequence (documented numeric differences).
 */
export async function cmp(t, label, source, options = {}, extra = undefined, opt = {}) {
  const r = await t.both(source, options, extra);
  const { bm, ref } = r;
  const tag = label ? label + ": " : "";
  if (!ref) { t.ok(!bm.error, tag + "bm renders" + (bm.error ? ": " + bm.error : "")); t.same("reference", 0, 0); return r; }
  if (bm.error || ref.error) {
    // bm-render's JS wrapper prefixes every message with "bm-render: " (all entries, not PDF specific): compared without it
    const be = bm.error ? errText(bm.error).replace(/^bm-render: /, "") : null;
    const re = ref.error ? errText(ref.error).replace(/^Error: /, "") : null;
    t.same(tag + "error", be, re);
    t.note(tag + "takumi: " + (re ? "ERROR " + re : "renders") + " | bm: " + (be ? "ERROR " + be : "renders"));
    if (!bm.error) { r.bmCanon = canonPages(bm); t.note(tag + "bm page 1: " + summary(r.bmCanon[0] || [])); }
    if (!ref.error) { r.refCanon = canonPages(ref); t.note(tag + "takumi page 1: " + summary(r.refCanon[0] || [])); }
    return r;
  }
  let a; let b;
  try { a = canonPages(bm); } catch (e) { t.ok(false, tag + "bm PDF not parsable: " + e.message); return r; }
  try { b = canonPages(ref); } catch (e) { t.ok(false, tag + "takumi PDF not parsable: " + e.message); return r; }
  r.bmCanon = a; r.refCanon = b;
  if (process.env.PDF_AUDIT_DUMP && currentId) {
    // PDF_AUDIT_DUMP=1: the canonical pages of both engines, one token per line, for diffing by hand
    const base = path.join(outDir, currentId.replace(/[^A-Za-z0-9_.-]+/g, "_"));
    const dump = (pages) => pages.map((p) => p.map(short).join("\n")).join("\n=== page\n");
    writeFileSync(base + ".bm.txt", dump(a));
    writeFileSync(base + ".takumi.txt", dump(b));
  }
  t.same(tag + "page count", a.length, b.length);
  let identical = a.length === b.length;
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    const d = opt.mode === "ops" ? firstDiff(opsOnly(a[i]), opsOnly(b[i])) : firstDiff(a[i], b[i]);
    if (!d) { t.ok(true, tag + "page " + (i + 1)); continue; }
    identical = false;
    // not token for token the same: the same marks under the same clips (draw lists)?
    let fd; let fa = []; let fb = [];
    try { fa = flatten(a[i]); fb = flatten(b[i]); fd = firstDiff(fa, fb); } catch (e) { fd = { at: -1, bm: "flatten threw: " + e.message, ref: "", lens: [0, 0] }; }
    if (process.env.PDF_AUDIT_DUMP && currentId) {
      const base = path.join(outDir, currentId.replace(/[^A-Za-z0-9_.-]+/g, "_"));
      const lines = (x) => x.map(short).join(" ").replace(/ (DRAW|TEXT|IMAGE|SH|DO|BDC|EMC|BMC)/g, "\n$1");
      writeFileSync(base + ".bm.flat.txt", lines(fa));
      writeFileSync(base + ".takumi.flat.txt", lines(fb));
    }
    if (!fd) {
      t.ok(true, tag + "page " + (i + 1) + " (draw list)");
      t.differs(`${tag}page ${i + 1}: content stream not token-identical, draw list identical (same marks, paints, clips, transparency; only q/Q, clip or cm grouping differs). First token difference: bm ${d.bm.split(">>>")[1]} | takumi ${d.ref.split(">>>")[1]}`);
      continue;
    }
    const sameOps = !firstDiff(opsOnly(a[i]), opsOnly(b[i]));
    t.ok(false, `${tag}page ${i + 1} differs. Content stream at token ${d.at} (${d.lens[0]} vs ${d.lens[1]} tokens; operator sequence ${sameOps ? "identical" : "DIFFERENT"})\n               bm:     ${d.bm}\n               takumi: ${d.ref}\n             draw list at ${fd.at} (${fd.lens[0]} vs ${fd.lens[1]})\n               bm:     ${fd.bm}\n               takumi: ${fd.ref}`);
    if (!sameOps) t.note(`${tag}bm page ${i + 1}: ${summary(a[i])}`);
  }
  r.identical = identical;
  if (b[0] && !opt.quiet) t.note(tag + "takumi: " + (summary(b[0]) || "(nothing drawn)"));
  return r;
}

/** An error message with data: URIs shortened. */
export const errText = (m) => String(m).replace(/data:([\w/+.-]+);base64,[A-Za-z0-9+/=]{24,}/g, "data:$1;base64,…");

/** A page of `w` x `h` CSS px that is exactly the viewport; paint probes exclude tagging. */
export const vp = (w = 200, h = 120) => ({ viewport: { width: w, height: h }, tagged: false });

/** A data: URI of a file (path relative to the repo root or to tests/upstream/takumi). */
export function dataUri(rel, mime) {
  return `data:${mime || mimeOf(rel)};base64,${fileBytes(rel).toString("base64")}`;
}
export function fileBytes(rel) {
  for (const base of [root, takumiSrc]) { try { return readFileSync(path.join(base, rel)); } catch { /* next */ } }
  throw new Error("no such file: " + rel);
}
export function mimeOf(rel) {
  const ext = rel.split(".").pop().toLowerCase();
  return { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", svg: "image/svg+xml", bmp: "image/bmp", ico: "image/x-icon", avif: "image/avif" }[ext] || "application/octet-stream";
}
export const svgUri = (svg) => "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");

/** Registers one probe per case: `cases` is `[[caseId, html, options?, extra?, opt?], ...]`. */
export function cases(prefix, feature, list, defaults = vp()) {
  for (const [id, html, options, extra, opt] of list) {
    probeAs(id ? `${prefix}.${id}` : prefix, feature, async (t) => { await cmp(t, "", html, options || defaults, extra, opt); });
  }
}

const box = (style, inner = "") => `<div style="width:100px;height:60px;margin:20px;${style}">${inner}</div>`;

// ------------------------------------------------------------------------------------------------ backgrounds

const PNG = dataUri("takumi-pdf/tests/images/checker.png");

cases("paint.background", "backgrounds", [
  ["color", box("background:#336699")],
  ["color-alpha", box("background:rgba(255,0,0,.4)")],
  ["page-background", `<html style="background:#eef"><body style="margin:0">${box("background:#fff")}</body></html>`],
  ["layers", box("background:linear-gradient(90deg,rgba(255,0,0,.5),transparent),linear-gradient(blue,green),#ff0")],
  ["image-no-repeat", box(`background:url(${PNG}) no-repeat 10px 5px`)],
  ["image-repeat", box(`background:url(${PNG})`)],
  ["image-repeat-x", box(`background:url(${PNG}) repeat-x center`)],
  ["size-cover", box(`background:url(${PNG}) center/cover no-repeat`)],
  ["size-contain", box(`background:url(${PNG}) center/contain no-repeat`)],
  ["size-px", box(`background:url(${PNG}) 0 0/30px 20px`)],
  ["size-percent", box(`background:linear-gradient(red,blue) 0 0/50% 50% no-repeat`)],
  ["position-keywords", box(`background:url(${PNG}) right 5px bottom 3px/16px 16px no-repeat`)],
  ["repeat-space", box(`background:url(${PNG}) 0 0/30px 25px space`)],
  ["repeat-round", box(`background:url(${PNG}) 0 0/30px 25px round`)],
  ["repeat-space-round", box(`background:url(${PNG}) 0 0/30px 25px space round`)],
  ["gradient-repeat", box(`background:linear-gradient(45deg,red,blue) 0 0/20px 20px`)],
  ["clip-border-box", box("background:#c00;border:8px dashed rgba(0,0,0,.4);background-clip:border-box")],
  ["clip-padding-box", box("background:#c00;border:8px dashed rgba(0,0,0,.4);background-clip:padding-box;padding:6px")],
  ["clip-content-box", box("background:#c00;border:8px dashed rgba(0,0,0,.4);background-clip:content-box;padding:6px")],
  ["clip-content-box-radius", box("background:linear-gradient(red,blue);border:8px solid #0008;background-clip:content-box;padding:6px;border-radius:20px")],
  ["clip-border-area", box("background:linear-gradient(red,blue);border:8px dashed transparent;background-clip:border-area")],
  ["origin-border-box", box(`background:url(${PNG}) no-repeat;border:8px solid #0003;padding:6px;background-origin:border-box`)],
  ["origin-content-box", box(`background:url(${PNG}) no-repeat;border:8px solid #0003;padding:6px;background-origin:content-box`)],
  ["attachment-fixed", box(`background:linear-gradient(red,blue) fixed`)],
  ["attachment-local", box(`background:url(${PNG}) local;overflow:hidden`)],
  ["radius", box("background:#393;border-radius:12px")],
  ["radius-elliptical", box("background:#393;border-radius:40px 10px / 10px 30px")],
  ["blend-mode", box(`background:linear-gradient(red,blue),url(${PNG});background-blend-mode:multiply`)],
  ["blend-mode-list", box(`background:linear-gradient(red,blue),linear-gradient(90deg,#ff0,#0ff),#888;background-blend-mode:screen,overlay`)],
  ["current-color", box("color:#a0f;background:currentColor;border:3px solid")],
  ["image-missing", box(`background:url(https://example.invalid/none.png) #ccc`)],
]);

// ------------------------------------------------------------------------------------------------ gradients

cases("paint.gradient", "gradients", [
  ["linear-2", box("background:linear-gradient(red,blue)")],
  ["linear-angle", box("background:linear-gradient(37deg,red,blue)")],
  ["linear-to-corner", box("background:linear-gradient(to top right,red,lime,blue)")],
  ["linear-stops", box("background:linear-gradient(90deg,red 10%,yellow 10% 40%,blue 90%)")],
  ["linear-hints", box("background:linear-gradient(90deg,red,30%,blue)")],
  ["linear-alpha", box("background:linear-gradient(90deg,rgba(255,0,0,1),rgba(0,0,255,0))")],
  ["linear-transparent", box("background:linear-gradient(90deg,red,transparent)")],
  ["linear-px-stops", box("background:linear-gradient(90deg,red 10px,blue 50px)")],
  ["linear-out-of-range", box("background:linear-gradient(90deg,red -20%,blue 130%)")],
  ["linear-repeating", box("background:repeating-linear-gradient(45deg,red 0 10px,blue 10px 20px)")],
  ["linear-repeating-alpha", box("background:repeating-linear-gradient(90deg,red 0 10px,transparent 10px 20px)")],
  ["linear-single-stop", box("background:linear-gradient(red)")],
  ["linear-in-oklch", box("background:linear-gradient(in oklch,red,blue)")],
  ["linear-in-oklab", box("background:linear-gradient(in oklab 90deg,red,blue)")],
  ["linear-in-hsl-longer", box("background:linear-gradient(in hsl longer hue,red,blue)")],
  ["linear-in-srgb-linear", box("background:linear-gradient(in srgb-linear,red,blue)")],
  ["radial", box("background:radial-gradient(red,blue)")],
  ["radial-circle-at", box("background:radial-gradient(circle at 20% 30%,red,yellow 40%,blue)")],
  ["radial-ellipse-size", box("background:radial-gradient(ellipse 40px 20px at center,red,blue)")],
  ["radial-closest-side", box("background:radial-gradient(closest-side,red,blue)")],
  ["radial-farthest-corner", box("background:radial-gradient(circle farthest-corner at 10px 10px,red,blue)")],
  ["radial-alpha", box("background:radial-gradient(rgba(255,0,0,.8),rgba(0,0,255,0))")],
  ["radial-repeating", box("background:repeating-radial-gradient(circle,red 0 8px,blue 8px 16px)")],
  ["radial-repeating-alpha", box("background:repeating-radial-gradient(circle,red 0 8px,transparent 8px 16px)")],
  ["conic", box("background:conic-gradient(red,yellow,lime,aqua,blue,magenta,red)")],
  ["conic-from-at", box("background:conic-gradient(from 45deg at 30% 40%,red,blue)")],
  ["conic-hard-stops", box("background:conic-gradient(red 0 25%,blue 25% 50%,lime 50% 75%,yellow 75%)")],
  ["conic-alpha", box("background:conic-gradient(red,transparent)")],
  ["conic-repeating", box("background:repeating-conic-gradient(red 0 15deg,blue 15deg 30deg)")],
  ["conic-repeating-percent", box("background:repeating-conic-gradient(red 0% 12.5%,blue 12.5% 25%)")],
  ["conic-repeating-turn", box("background:repeating-conic-gradient(red 0turn .125turn,blue .125turn .25turn)")],
  ["conic-fraction-stops", box("background:conic-gradient(red 0 .25,blue .25 .5,green .5 1)")],
  ["border-radius", box("background:linear-gradient(red,blue);border-radius:50%")],
  ["transformed", box("background:linear-gradient(red,blue);transform:rotate(20deg)")],
  ["tiled-radial", box("background:radial-gradient(red,blue) 0 0/25px 25px")],
  ["tiled-conic", box("background:conic-gradient(red,blue) 0 0/25px 25px")],
]);

// ------------------------------------------------------------------------------------------------ borders, outlines

const sides = (style) => box(`border:6px ${style} #c33`);
cases("paint.border", "borders", [
  ["solid", sides("solid")],
  ["dashed", sides("dashed")],
  ["dotted", sides("dotted")],
  ["double", sides("double")],
  ["groove", sides("groove")],
  ["ridge", sides("ridge")],
  ["inset", sides("inset")],
  ["outset", sides("outset")],
  ["hidden", sides("hidden")],
  ["thin-1px", box("border:1px solid #000")],
  ["hairline", box("border:0.5px solid #000")],
  ["alpha", box("border:6px solid rgba(0,0,255,.3)")],
  ["per-side-colors", box("border:6px solid;border-color:red green blue orange")],
  ["per-side-widths", box("border-style:solid;border-color:#333;border-width:2px 8px 14px 4px")],
  ["per-side-styles", box("border-width:6px;border-color:#333;border-style:solid dashed dotted double")],
  ["one-side", box("border-bottom:4px solid #06c")],
  ["two-sides-colors", box("border-top:10px solid red;border-left:10px solid blue")],
  ["triangle", `<div style="margin:20px;width:0;height:0;border-left:30px solid transparent;border-right:30px solid transparent;border-bottom:50px solid #c33"></div>`],
  ["radius", box("border:6px solid #c33;border-radius:14px")],
  ["radius-colors", box("border:6px solid;border-color:red green blue orange;border-radius:14px")],
  ["radius-widths", box("border-style:solid;border-color:#333;border-width:2px 8px 14px 4px;border-radius:20px")],
  ["radius-elliptical", box("border:6px solid #c33;border-radius:50px 20px / 20px 30px")],
  ["radius-circle", box("border:6px solid #c33;border-radius:50%")],
  ["radius-overflow", box("border:6px solid #c33;border-radius:500px")],
  ["radius-dashed", box("border:6px dashed #c33;border-radius:14px")],
  ["radius-dotted", box("border:6px dotted #c33;border-radius:14px")],
  ["radius-double", box("border:6px double #c33;border-radius:14px")],
  ["radius-groove", box("border:6px groove #c33;border-radius:14px")],
  ["radius-single-corner", box("border:6px solid #c33;border-top-left-radius:30px")],
  ["dashed-wide", box("border:12px dashed #c33")],
  ["dotted-thin", box("border:2px dotted #c33")],
  ["double-thin", box("border:2px double #c33")],
  ["double-per-side-colors", box("border:9px double;border-color:red green blue orange")],
  ["background-under", box("border:6px dashed #c33;background:#ff0")],
  ["image-gradient", box("border:10px solid;border-image:linear-gradient(red,blue) 1")],
  ["image-url-slice", box(`border:10px solid;border-image:url(${PNG}) 2 round`)],
  ["image-url-fill", box(`border:10px solid;border-image:url(${PNG}) 2 fill stretch`)],
  ["box-sizing-inline", `<p style="margin:20px;font:16px Inter">a <span style="border:2px solid red;border-radius:4px;padding:0 3px">inline box</span> b</p>`],
  ["inline-wrapped", `<p style="margin:20px;width:90px;font:16px Inter">a <span style="border:2px solid red;background:#ff0">inline box that wraps lines</span> b</p>`],
]);

cases("paint.outline", "outlines", [
  ["solid", box("outline:4px solid #06c")],
  ["offset", box("outline:4px solid #06c;outline-offset:6px")],
  ["offset-negative", box("outline:4px solid #06c;outline-offset:-10px")],
  ["dashed", box("outline:3px dashed #06c")],
  ["dotted", box("outline:3px dotted #06c")],
  ["double", box("outline:6px double #06c")],
  ["groove", box("outline:6px groove #06c")],
  ["radius", box("outline:4px solid #06c;border-radius:12px;outline-offset:3px")],
  ["with-border", box("outline:4px solid #06c;border:4px solid #c33")],
  ["auto", box("outline:auto")],
  ["inline", `<p style="margin:20px;font:16px Inter">a <span style="outline:2px solid red;outline-offset:2px">inline</span> b</p>`],
  ["inline-wrapped", `<p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:2px solid red">inline box that wraps lines</span> b</p>`],
  ...["solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset"].flatMap((style) => [
    [`inline-${style}`, `<p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:5px ${style} #06c;outline-offset:2px">inline box that wraps lines</span> b</p>`],
    [`inline-${style}-radius`, `<p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:5px ${style} #06c;outline-offset:2px;border-radius:6px 10px">inline box that wraps lines</span> b</p>`],
  ]),
  ...[1, 2, 3, 6].flatMap((width) => [
    [`inline-dotted-${width}px`, `<p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:${width}px dotted #06c">inline box that wraps lines</span> b</p>`],
    [`inline-double-${width}px`, `<p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:${width}px double #06c;border-radius:8px">inline box that wraps lines</span> b</p>`],
  ]),
  ["inline-opacity", `<p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:5px dashed #06c8;opacity:.6;border-radius:8px">inline box that wraps lines</span> b</p>`],
  ["inline-transformed-clip", `<div style="overflow:hidden;width:130px;height:90px;transform:rotate(5deg)"><p style="margin:20px;width:90px;font:16px Inter">a <span style="outline:5px dotted #06c;border-radius:8px">inline box that wraps lines</span> b</p></div>`],
  ["inline-paged", `<p style="margin:20px;width:90px;font:16px Inter;line-height:20px">a <span style="outline:5px double #06c;border-radius:8px">inline box that wraps across many lines and several pages of this short document</span> b</p>`, { size: { width: 150, height: 100 }, margin: 10 }],
  ["over-sibling", box("outline:6px solid #06c;background:#fff") + `<div style="margin:-20px 20px;width:100px;height:20px;background:#f00"></div>`],
  ["image", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;outline:3px solid red">`],
]);

// ------------------------------------------------------------------------------------------------ shadows

cases("paint.box-shadow", "box-shadow", [
  ["offset", box("box-shadow:5px 5px #000")],
  ["alpha", box("box-shadow:5px 5px rgba(0,0,0,.4)")],
  ["spread", box("box-shadow:0 0 0 6px #06c")],
  ["spread-negative", box("box-shadow:0 12px 0 -4px #06c")],
  ["blur", box("box-shadow:0 0 10px #000")],
  ["blur-alpha", box("box-shadow:0 4px 12px rgba(0,0,0,.35)")],
  ["blur-spread", box("box-shadow:2px 3px 8px 4px #c33")],
  ["blur-large", box("box-shadow:0 0 60px #000")],
  ["blur-small", box("box-shadow:0 0 1px #000")],
  ["inset", box("box-shadow:inset 4px 4px #000")],
  ["inset-blur", box("box-shadow:inset 0 0 10px #000")],
  ["inset-blur-alpha", box("box-shadow:inset 0 0 10px rgba(0,0,0,.5)")],
  ["inset-spread", box("box-shadow:inset 0 0 0 5px #06c")],
  ["multiple", box("box-shadow:0 0 0 2px red,0 0 0 4px blue,4px 4px 8px #000,inset 0 0 4px #0f0")],
  ["radius", box("box-shadow:4px 4px 6px #000;border-radius:16px")],
  ["radius-inset", box("box-shadow:inset 4px 4px 6px #000;border-radius:16px")],
  ["radius-elliptical", box("box-shadow:4px 4px 0 3px #000;border-radius:40px 10px / 10px 30px")],
  ["transparent-box", box("box-shadow:5px 5px 4px #000;background:transparent")],
  ["with-background", box("box-shadow:5px 5px 4px #000;background:#fff;border:2px solid #c33")],
  ["current-color", box("color:#c0c;box-shadow:3px 3px")],
  ["transformed", box("box-shadow:5px 5px 6px #000;transform:rotate(10deg)")],
  ["with-opacity", box("box-shadow:5px 5px 6px #000;opacity:.5;background:#fff")],
  ["inline", `<p style="margin:20px;font:16px Inter">a <span style="box-shadow:2px 2px 3px #000">inline</span> b</p>`],
  ["image", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;box-shadow:3px 3px 4px #000">`],
]);

// ------------------------------------------------------------------------------------------------ filters

const filt = (f, inner = "") => box(`filter:${f};background:#c63;border:4px solid #36c;color:#0a0;font:14px Inter`, inner || "Text");
cases("paint.filter", "filter", [
  ["blur", filt("blur(2px)")],
  ["blur-zero", filt("blur(0)")],
  ["brightness", filt("brightness(1.5)")],
  ["contrast", filt("contrast(200%)")],
  ["grayscale", filt("grayscale(1)")],
  ["grayscale-partial", filt("grayscale(40%)")],
  ["hue-rotate", filt("hue-rotate(90deg)")],
  ["invert", filt("invert(1)")],
  ["opacity", filt("opacity(.5)")],
  ["saturate", filt("saturate(3)")],
  ["sepia", filt("sepia(1)")],
  ["drop-shadow", filt("drop-shadow(2px 2px 2px #000)")],
  ["drop-shadow-no-blur", filt("drop-shadow(2px 2px 0 #000)")],
  ["chain", filt("brightness(2) grayscale(1) invert(.2)")],
  ["chain-with-blur", filt("grayscale(1) blur(1px)")],
  ["url-fragment", filt("url(#f)")],
  ["url-fragment-chain", filt("url(#f) grayscale(1)")],
  ["url-file", filt("url(filters.svg#f)")],
  ["none", filt("none")],
  ["nested", box("filter:brightness(.5);background:#888", `<div style="filter:contrast(2);width:40px;height:20px;background:#808080"></div>`)],
  ["gradient", box("filter:grayscale(1);background:linear-gradient(red,blue)")],
  ["gradient-conic", box("filter:invert(1);background:conic-gradient(red,blue)")],
  ["shadow", box("filter:hue-rotate(180deg);box-shadow:4px 4px 4px #f00;background:#fff")],
  ["image-png", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;filter:grayscale(1)">`],
  ["image-jpeg", `<img src="${dataUri("takumi-pdf/tests/images/checker.jpg")}" style="margin:20px;width:40px;height:40px;filter:sepia(1)">`],
  ["image-opacity", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;filter:opacity(.5)">`],
  ["background-image", box(`filter:invert(1);background:url(${PNG})`)],
  ["svg-image", `<img src="${svgUri(`<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#c00"/><circle cx="20" cy="20" r="10" fill="url(#g)"/><defs><linearGradient id="g"><stop stop-color="#0f0"/><stop offset="1" stop-color="#00f"/></linearGradient></defs></svg>`)}" style="margin:20px;filter:grayscale(1)">`],
  ["text-decoration", `<p style="margin:20px;font:16px Inter;color:#c00;text-decoration:underline;filter:hue-rotate(120deg)">Text</p>`],
  ["inline-box", `<p style="margin:20px;font:16px Inter">a <span style="display:inline-block;filter:invert(1);background:#c00;width:20px;height:10px"></span> b</p>`],
  ["inline-image", `<p style="margin:20px;font:16px Inter">a <img src="${PNG}" style="width:20px;height:20px;filter:invert(1)"> b</p>`],
  ["inline-image-blur", `<p style="margin:20px;font:16px Inter">a <img src="${PNG}" style="width:20px;height:20px;filter:blur(1px)"> b</p>`],
]);

cases("paint.backdrop-filter", "backdrop-filter", [
  ["blur", box("background:linear-gradient(red,blue)", `<div style="backdrop-filter:blur(4px);width:50px;height:30px;background:rgba(255,255,255,.3)"></div>`)],
  ["grayscale", box("background:linear-gradient(red,blue)", `<div style="backdrop-filter:grayscale(1);width:50px;height:30px"></div>`)],
  ["webkit", box("background:linear-gradient(red,blue)", `<div style="-webkit-backdrop-filter:invert(1);width:50px;height:30px"></div>`)],
]);

// ------------------------------------------------------------------------------------------------ compositing

const inner = `<div style="width:40px;height:30px;background:#06c"></div><span style="font:14px Inter">Txt</span>`;
cases("paint.opacity", "opacity and transparency groups", [
  ["leaf", box("opacity:.5;background:#c33")],
  ["with-children", box("opacity:.5;background:#c33", inner)],
  ["nested", box("opacity:.5;background:#c33", `<div style="opacity:.5;width:40px;height:30px;background:#06c"></div>`)],
  ["zero", box("opacity:0;background:#c33", inner)],
  ["one", box("opacity:1;background:#c33", inner)],
  ["text-only", `<p style="margin:20px;font:16px Inter;opacity:.4">Faded</p>`],
  ["inline-span", `<p style="margin:20px;font:16px Inter">a <span style="opacity:.4">faded</span> b</p>`],
  ["inline-block", `<p style="margin:20px;font:16px Inter">a <span style="display:inline-block;opacity:.4;background:red;width:20px;height:10px"></span> b</p>`],
  ["image", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;opacity:.5">`],
  ["with-transform", box("opacity:.5;background:#c33;transform:rotate(15deg)", inner)],
  ["color-alpha-vs-opacity", box("background:rgba(204,51,51,.5);border:5px solid rgba(0,0,0,.5)")],
]);

cases("paint.blend", "mix-blend-mode, isolation", [
  ...["multiply", "screen", "overlay", "darken", "lighten", "color-dodge", "color-burn", "hard-light", "soft-light", "difference", "exclusion", "hue", "saturation", "color", "luminosity", "plus-lighter", "plus-darker", "normal"].map((m) => [
    "mode-" + m, box("background:#fc0", `<div style="mix-blend-mode:${m};width:60px;height:40px;background:#06c"></div>`)]),
  ["with-opacity", box("background:#fc0", `<div style="mix-blend-mode:multiply;opacity:.5;width:60px;height:40px;background:#06c"></div>`)],
  ["isolation", box("background:#fc0;isolation:isolate", `<div style="mix-blend-mode:multiply;width:60px;height:40px;background:#06c"></div>`)],
  ["isolation-alone", box("background:#fc0;isolation:isolate", inner)],
  ["text", `<div style="background:#fc0;margin:20px"><p style="font:16px Inter;mix-blend-mode:difference;color:#fff;margin:0">Blend</p></div>`],
  ["image", `<div style="background:#fc0;margin:20px;width:60px"><img src="${PNG}" style="width:40px;height:40px;mix-blend-mode:multiply"></div>`],
]);

// ------------------------------------------------------------------------------------------------ clips and masks

const clip = (c, extraStyle = "") => box(`clip-path:${c};background:linear-gradient(red,blue);${extraStyle}`, inner);
cases("paint.clip-path", "clip-path", [
  ["inset", clip("inset(10px 20px)")],
  ["inset-round", clip("inset(5px round 10px)")],
  ["inset-round-elliptical", clip("inset(5px 10px 15px 20px round 20px 5px / 5px 10px)")],
  ["circle", clip("circle(30px at 50% 50%)")],
  ["circle-default", clip("circle()")],
  ["circle-closest-side", clip("circle(closest-side at 30% 40%)")],
  ["ellipse", clip("ellipse(40px 20px at center)")],
  ["ellipse-default", clip("ellipse()")],
  ["polygon", clip("polygon(50% 0,100% 100%,0 100%)")],
  ["polygon-evenodd", clip("polygon(evenodd,50% 0,80% 100%,0 35%,100% 35%,20% 100%)")],
  ["polygon-nonzero", clip("polygon(nonzero,50% 0,80% 100%,0 35%,100% 35%,20% 100%)")],
  ["path", clip("path('M10 10 H90 V50 Q50 20 10 50 Z')")],
  ["path-evenodd", clip("path(evenodd,'M0 0H100V60H0Z M20 10H80V50H20Z')")],
  ["path-arc", clip("path('M10 30 A20 20 0 1 1 50 30 A20 20 0 1 1 10 30 Z')")],
  ["rect", clip("rect(5px 90px 50px 10px round 8px)")],
  ["xywh", clip("xywh(10px 5px 60px 40px round 6px)")],
  ["shape-fn", clip("shape(from 0 0,line to 100% 0,line to 50% 100%,close)")],
  ["geometry-box", clip("padding-box circle(40%)", "border:5px solid #000;padding:5px")],
  ["margin-box", clip("margin-box")],
  ["content-box-only", clip("content-box", "border:5px solid #000;padding:5px")],
  ["border-box-radius", clip("border-box", "border-radius:20px")],
  ["url", clip("url(#c)")],
  ["none", clip("none")],
  ["empty-polygon", clip("polygon(0 0,0 0,0 0)")],
  ["zero-circle", clip("circle(0)")],
  ["with-transform", clip("circle(30px)", "transform:rotate(30deg)")],
  ["with-opacity", clip("circle(30px)", "opacity:.5")],
  ["nested", clip("inset(5px)", "") .replace(inner, `<div style="clip-path:circle(15px);width:40px;height:30px;background:#0f0"></div>`)],
  ["on-image", `<img src="${PNG}" style="margin:20px;width:60px;height:60px;clip-path:circle(40%)">`],
  ["on-text", `<p style="margin:20px;font:20px Inter;clip-path:inset(0 50% 0 0)">Clipped text</p>`],
]);

const mask = (m, extraStyle = "") => box(`${m};background:#c33;${extraStyle}`, inner);
cases("paint.mask", "mask-image", [
  ["linear", mask("mask-image:linear-gradient(#000,transparent)")],
  ["webkit-prefix", mask("-webkit-mask-image:linear-gradient(#000,transparent)")],
  ["radial", mask("mask-image:radial-gradient(#000 30%,transparent 70%)")],
  ["conic", mask("mask-image:conic-gradient(#000,transparent)")],
  ["opaque-colors", mask("mask-image:linear-gradient(red,blue)")],
  ["image", mask(`mask-image:url(${PNG})`)],
  ["image-alpha", mask(`mask-image:url(${dataUri("assets/images/yeecord.png")})`)],
  ["svg-image", mask(`mask-image:url(${svgUri(`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><circle cx="10" cy="10" r="8"/></svg>`)})`)],
  ["size-position", mask("mask-image:linear-gradient(#000,transparent);mask-size:50% 50%;mask-position:center;mask-repeat:no-repeat")],
  ["repeat", mask("mask-image:radial-gradient(#000 40%,transparent 60%);mask-size:20px 20px")],
  ["repeat-space", mask("mask-image:radial-gradient(#000 40%,transparent 60%);mask-size:30px 25px;mask-repeat:space")],
  ["layers", mask("mask-image:linear-gradient(#000,transparent),radial-gradient(#000 30%,transparent 31%)")],
  ["composite-intersect", mask("mask-image:linear-gradient(#000,transparent),linear-gradient(90deg,#000,transparent);mask-composite:intersect")],
  ["composite-subtract", mask("mask-image:linear-gradient(#000,#000),radial-gradient(#000 30%,transparent 31%);mask-composite:subtract")],
  ["composite-exclude", mask("mask-image:linear-gradient(#000,transparent),linear-gradient(90deg,#000,transparent);mask-composite:exclude")],
  ["mode-luminance", mask("mask-image:linear-gradient(#fff,#000);mask-mode:luminance")],
  ["mode-alpha", mask("mask-image:linear-gradient(#fff,#000);mask-mode:alpha")],
  ["mask-type", mask("mask-image:linear-gradient(#fff,#000);mask-type:luminance")],
  ["clip-content-box", mask("mask-image:linear-gradient(#000,#000);mask-clip:content-box", "padding:10px")],
  ["origin-content-box", mask("mask-image:linear-gradient(#000,transparent);mask-origin:content-box;mask-repeat:no-repeat", "padding:10px")],
  ["shorthand", mask("mask:linear-gradient(#000,transparent) center/50% 50% no-repeat")],
  ["none", mask("mask-image:none")],
  ["url-fragment", mask("mask-image:url(#m)")],
  ["with-opacity", mask("mask-image:linear-gradient(#000,transparent)", "opacity:.5")],
  ["with-filter", mask("mask-image:linear-gradient(#000,transparent)", "filter:grayscale(1)")],
  ["with-transform", mask("mask-image:linear-gradient(#000,transparent)", "transform:rotate(20deg)")],
  ["with-clip-path", mask("mask-image:linear-gradient(#000,transparent)", "clip-path:circle(30px)")],
  ["on-image", `<img src="${PNG}" style="margin:20px;width:60px;height:60px;mask-image:linear-gradient(#000,transparent)">`],
  ["on-text", `<p style="margin:20px;font:20px Inter;mask-image:linear-gradient(90deg,#000,transparent)">Masked text</p>`],
  ["mask-border", mask(`mask-border:url(${PNG}) 2`)],
]);

const scroll = `<div style="width:160px;height:80px;background:linear-gradient(red,blue)"></div><span style="font:14px Inter">overflowing text here</span>`;
cases("paint.overflow", "overflow clip", [
  ["hidden", box("overflow:hidden;background:#eee", scroll)],
  ["clip", box("overflow:clip;background:#eee", scroll)],
  ["clip-margin", box("overflow:clip;overflow-clip-margin:10px;background:#eee", scroll)],
  ["visible", box("overflow:visible;background:#eee", scroll)],
  ["hidden-radius", box("overflow:hidden;border-radius:20px;background:#eee", scroll)],
  ["hidden-radius-border", box("overflow:hidden;border-radius:20px;border:6px solid #333;background:#eee", scroll)],
  ["hidden-radius-elliptical", box("overflow:hidden;border-radius:50px 10px / 20px 30px;border:3px solid #333", scroll)],
  ["hidden-padding", box("overflow:hidden;padding:10px;border:4px solid #333", scroll)],
  ["x-only", box("overflow-x:hidden;overflow-y:visible;background:#eee", scroll)],
  ["y-only", box("overflow-y:hidden;overflow-x:visible;background:#eee", scroll)],
  ["x-clip-y-visible", box("overflow-x:clip;overflow-y:visible;background:#eee", scroll)],
  ["nested", box("overflow:hidden;border-radius:10px", `<div style="overflow:hidden;width:70px;height:40px;margin:5px;border-radius:50%">${scroll}</div>`)],
  ["hidden-transform-child", box("overflow:hidden;background:#eee", `<div style="transform:rotate(30deg);width:120px;height:40px;background:#06c"></div>`)],
  ["hidden-abs-child", box("overflow:hidden;position:relative;background:#eee", `<div style="position:absolute;left:60px;top:30px;width:120px;height:40px;background:#06c"></div>`)],
  ["hidden-abs-escapes", box("overflow:hidden;background:#eee", `<div style="position:absolute;left:60px;top:30px;width:120px;height:40px;background:#06c"></div>`)],
  ["image-radius", `<img src="${PNG}" style="margin:20px;width:60px;height:60px;border-radius:50%">`],
  ["image-radius-border", `<img src="${PNG}" style="margin:20px;width:60px;height:60px;border-radius:20px;border:5px solid #333;padding:4px">`],
]);

// ------------------------------------------------------------------------------------------------ transforms

const tf = (t, extraStyle = "") => box(`${t};background:#c33;border:2px solid #000;font:14px Inter;${extraStyle}`, "Tx");
cases("paint.motion", "CSS motion paths", [
  ["path-line", tf(`offset-path:path('M0 0 L160 80');offset-distance:30%`)],
  ["path-open-clamp", tf(`offset-path:path('M10 20 L80 20');offset-distance:200%;offset-rotate:0deg`)],
  ["path-closed-wrap", tf(`offset-path:path('M10 20 L100 20 L100 80 Z');offset-distance:-20px`)],
  ["ray", tf(`offset-path:ray(45deg sides at 20% 50%);offset-distance:50%;offset-rotate:reverse 20deg`)],
  ["circle", tf(`offset-path:circle(35px at 60px 55px);offset-distance:20%`)],
  ["ellipse", tf(`offset-path:ellipse(45px 25px at 70px 55px);offset-distance:60%`)],
  ["polygon", tf(`offset-path:polygon(10px 10px,140px 10px,80px 90px);offset-distance:40%`)],
  ["inset", tf(`offset-path:inset(10px 20px 30px 40px round 8px);offset-distance:35%`)],
  ["anchor", tf(`offset-path:path('M0 0 L160 80');offset-distance:30%;offset-rotate:auto;offset-anchor:0% 0%`)],
  ["composition", tf(`translate:5px 8px;rotate:10deg;scale:.8;offset-path:path('M0 0 L160 80');offset-distance:30%;transform:translateX(5px)`)],
]);

// Motion paths (task 24) with the pinned reference's syntax: path() / ray() (size, `contain`, `at`) /
// basic shapes / a coordinate box, offset-distance / -rotate / -anchor / -position. The box, its
// text and its link annotation take one transform. A viewport with a height is the reference box;
// paged output has none (takumi-pdf's unbounded column): the box's own height stands in.
{
  const mp = (s, inner = "Tx") => `<div style="position:relative;width:200px;height:120px;margin:10px;border:1px solid #999"><div style="width:60px;height:24px;background:#c33;font:14px Inter;${s}">${inner}</div></div>`;
  const mlink = (s) => mp(s, `<a href="https://example.com/m" style="color:#fff">go</a>`);
  const mblock = (s) => `<div style="position:relative;width:200px;height:120px;margin:10px"><a href="https://example.com/b" style="display:block;width:60px;height:24px;background:#36c;${s}">blk</a></div>`;
  const motion = async (t, html, options) => {
    const r = await cmp(t, "paint", html, options);
    if (r.bm && r.ref && !r.bm.error && !r.ref.error) {
      const { annots, sameWithin } = await import("./filelayer.util.mjs");
      sameWithin(t, "link annotations", annots(r.bm), annots(r.ref));
      t.same("text", r.bm.text, r.ref.text);
    }
  };
  const viewport = { viewport: { width: 240, height: 160 }, tagged: false };
  const paged = { size: { width: 300, height: 400 }, margin: 20 };
  for (const [id, html, options] of [
    ["path-curve-auto-text", mp("offset-path:path('M10 100 C 60 0 140 0 190 100');offset-distance:40%;offset-rotate:auto"), viewport],
    ["ray-closest-side", mp("offset-path:ray(60deg closest-side);offset-distance:80%"), viewport],
    ["ray-contain-at", mp("offset-path:ray(120deg farthest-corner contain at 50% 50%);offset-distance:100%"), viewport],
    ["ray-offset-position", mp("offset-path:ray(30deg);offset-position:20% 30%;offset-distance:50%"), viewport],
    ["circle-fixed-rotate", mp("offset-path:circle(40px at 100px 60px);offset-distance:70%;offset-rotate:45deg"), viewport],
    ["inset-anchor-keywords", mp("offset-path:inset(10px round 10px);offset-distance:55%;offset-anchor:right bottom"), viewport],
    ["polygon-reverse", mp("offset-path:polygon(0 0,100% 0,100% 100%);offset-distance:60%;offset-rotate:reverse"), viewport],
    ["coord-box", mp("offset-path:border-box;offset-distance:30%"), viewport],
    ["url-not-a-path", mp("offset-path:url(#p);offset-distance:30%"), viewport],
    ["distance-calc", mp("offset-path:path('M0 0 H180');offset-distance:calc(20% + 10px)"), viewport],
    ["inline-link", mlink("offset-path:path('M0 0 L160 80');offset-distance:50%;offset-rotate:auto"), viewport],
    ["block-link-ray", mblock("offset-path:ray(45deg sides);offset-distance:40%;offset-rotate:0deg"), viewport],
    ["paged-circle-default", `<p>x</p>${mblock("offset-path:circle();offset-distance:30%")}`, paged],
    ["paged-polygon-percent", `<p>x</p>${mblock("offset-path:polygon(0 0,100% 0,100% 100%);offset-distance:60%")}`, paged],
    ["paged-inset-percent", `<p>x</p>${mblock("offset-path:inset(10%);offset-distance:60%")}`, paged],
    ["paged-coord-box", `<p>x</p>${mblock("offset-path:border-box;offset-distance:60%")}`, paged],
    ["paged-ray-farthest-corner", `<p>x</p>${mblock("offset-path:ray(100deg farthest-corner);offset-distance:30%")}`, paged],
    ["paged-ray-sides-at", `<p>x</p>${mblock("offset-path:ray(200deg sides at 30% 40%);offset-distance:30%")}`, paged],
    ["paged-ray-on-first-page", `<div style="height:20px"></div>${mblock("offset-path:ray(135deg closest-side);offset-distance:70%")}`, paged],
    ["paged-path-vh-distance", `<p>x</p>${mblock("offset-path:path('M0 0 L100 50');offset-distance:10vh")}`, paged],
  ]) probeAs(`paint.motion.${id}`, "CSS motion paths: box, text and link transform", async (t) => { await motion(t, html, options); });
}

for (const overflow of ["scroll", "auto"]) {
  probeAs(`paint.overflow.${overflow}`, `overflow:${overflow} clips at the padding box`, async (t) => {
    const r = await t.bm(box(`overflow:${overflow};background:#eee`, scroll), vp());
    if (r.error) return;
    // The 100x60 CSS-pixel box starts at (20,20); at 0.75 pt/px its PDF clip is
    // x=15..90 and y=30..75. Takumi 0.20.0 clips this case to the 160x80 child instead.
    t.ok(/q\s+15\s+75\s+75\s+-45\s+re\s+W\s+n/.test(r.content(0)), `${overflow} clips at the box's 100x60 padding box`);
  });
}
cases("paint.transform", "transforms", [
  ["translate", tf("transform:translate(10px,5px)")],
  ["translate-percent", tf("transform:translate(10%,-20%)")],
  ["rotate", tf("transform:rotate(30deg)")],
  ["scale", tf("transform:scale(1.2,.6)")],
  ["scale-negative", tf("transform:scaleX(-1)")],
  ["scale-zero", tf("transform:scale(0)")],
  ["skew", tf("transform:skew(10deg,5deg)")],
  ["matrix", tf("transform:matrix(1,.2,.3,1,5,6)")],
  ["chain", tf("transform:translate(10px,5px) rotate(20deg) scale(.8)")],
  ["origin-top-left", tf("transform:rotate(15deg);transform-origin:0 0")],
  ["origin-px", tf("transform:rotate(15deg);transform-origin:10px 50px")],
  ["origin-bottom-right", tf("transform:scale(.5);transform-origin:bottom right")],
  ["transform-box", tf("transform:rotate(15deg);transform-box:content-box;padding:10px")],
  ["prop-rotate", tf("rotate:30deg")],
  ["prop-scale", tf("scale:.5 1.2")],
  ["prop-translate", tf("translate:10px 20px")],
  ["props-combined", tf("translate:10px 5px;rotate:20deg;scale:.8;transform:skewX(10deg)")],
  ["rotate3d", tf("transform:rotate3d(1,1,0,45deg)")],
  ["rotateX", tf("transform:rotateX(45deg)")],
  ["rotateY", tf("transform:rotateY(60deg)")],
  ["translateZ", tf("transform:translateZ(20px)")],
  ["translate3d", tf("transform:translate3d(5px,6px,7px)")],
  ["scale3d", tf("transform:scale3d(.5,.5,2)")],
  ["matrix3d", tf("transform:matrix3d(1,0,0,0,0,1,0,0,0,0,1,0,10,20,0,1)")],
  ["perspective-fn", tf("transform:perspective(200px) rotateY(40deg)")],
  ["perspective-prop", `<div style="perspective:200px;margin:20px">${tf("transform:rotateX(40deg)")}</div>`],
  ["perspective-origin", `<div style="perspective:200px;perspective-origin:0 0;margin:20px">${tf("transform:rotateX(40deg)")}</div>`],
  ["preserve-3d", `<div style="transform-style:preserve-3d;transform:rotateY(30deg);margin:20px">${tf("transform:rotateX(40deg)")}</div>`],
  ["backface-hidden", tf("transform:rotateY(180deg);backface-visibility:hidden")],
  ["nested", box("transform:rotate(10deg);background:#eee", tf("transform:scale(.5) rotate(20deg)"))],
  ["will-change", tf("will-change:transform")],
  ["will-change-opacity", tf("will-change:opacity")],
  ["inline", `<p style="margin:20px;font:16px Inter">a <span style="display:inline-block;transform:rotate(20deg)">tilted</span> b</p>`],
  ["image", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;transform:rotate(45deg)">`],
  ["zoom", tf("zoom:1.5")],
  ["offset-path", tf("offset-path:path('M0 0 L50 30');offset-distance:50%")],
]);

probeAs("paint.transform.rotate-axis-z", "rotate:z 30deg is equivalent to transform:rotate(30deg)", async (t) => {
  const [a, b] = await Promise.all([
    t.bm(tf("rotate:z 30deg"), vp()),
    t.bm(tf("transform:rotate(30deg)"), vp()),
  ]);
  if (a.error || b.error) return t.same("both rotations render", !!a.error, !!b.error);
  t.same("z-axis rotate and 2D rotate paint identical pages", canonPages(a), canonPages(b));
});

// ------------------------------------------------------------------------------------------------ visibility, order

cases("paint.visibility", "visibility, display", [
  ["hidden", box("visibility:hidden;background:#c33", inner)],
  ["hidden-child-visible", box("visibility:hidden;background:#c33", `<div style="visibility:visible;width:40px;height:30px;background:#06c"></div>`)],
  ["collapse", box("visibility:collapse;background:#c33", inner)],
  ["display-none", box("display:none;background:#c33", inner)],
  ["display-contents", box("display:contents;background:#c33;border:5px solid #000", inner)],
  ["hidden-text", `<p style="margin:20px;font:16px Inter">a <span style="visibility:hidden">hidden</span> b</p>`],
  ["hidden-image", `<img src="${PNG}" style="margin:20px;width:40px;height:40px;visibility:hidden">`],
  ["content-visibility", box("content-visibility:hidden;background:#c33", inner)],
]);

const layer = (style) => `<div style="position:absolute;width:60px;height:40px;${style}"></div>`;
cases("paint.stacking", "z-index / stacking order", [
  ["z-index", `<div style="position:relative;margin:20px">${layer("background:red;z-index:3")}${layer("background:lime;left:20px;top:10px;z-index:1")}${layer("background:blue;left:40px;top:20px;z-index:2")}</div>`],
  ["negative", `<div style="margin:20px;background:#ff0;width:100px;height:60px"><div style="position:relative">${layer("background:red;z-index:-1;left:-10px;top:-10px")}</div>in flow</div>`],
  ["negative-in-context", `<div style="margin:20px;background:#ff0;width:100px;height:60px;position:relative;z-index:0"><div style="position:relative">${layer("background:red;z-index:-1;left:-10px;top:-10px")}</div></div>`],
  ["positioned-over-flow", `<div style="margin:20px">${`<div style="position:relative;width:60px;height:40px;background:red"></div>`}<div style="margin-top:-20px;margin-left:20px;width:60px;height:40px;background:blue"></div></div>`],
  ["float-over-block", `<div style="margin:20px;width:120px"><div style="float:left;width:40px;height:40px;background:red"></div><div style="background:blue;height:20px"></div><span style="font:14px Inter">text</span></div>`],
  ["opacity-creates-context", `<div style="margin:20px;position:relative"><div style="opacity:.9">${layer("background:red;z-index:5")}</div>${layer("background:blue;left:20px;top:10px;z-index:1")}</div>`],
  ["transform-creates-context", `<div style="margin:20px;position:relative"><div style="transform:translateX(0)">${layer("background:red;z-index:5")}</div>${layer("background:blue;left:20px;top:10px;z-index:1")}</div>`],
  ["flex-order-z", `<div style="margin:20px;display:flex"><div style="width:50px;height:40px;background:red;z-index:2;margin-right:-20px"></div><div style="width:50px;height:40px;background:blue;z-index:1"></div></div>`],
  ["inline-vs-block-bg", `<div style="margin:20px;font:16px Inter;width:120px">text before<div style="background:#ff0;margin-top:-12px;height:20px"></div></div>`],
  ["fixed", `<div style="position:fixed;right:0;bottom:0;width:30px;height:20px;background:red"></div>${box("background:blue")}`],
  ["sticky", `<div style="position:sticky;top:0;width:30px;height:20px;background:red"></div>${box("background:blue")}`],
]);

// ------------------------------------------------------------------------------------------------ colours

const col = (c) => box(`background:${c};border:4px solid ${c};color:${c};font:14px Inter`, "Tx");
cases("paint.color", "colour spaces", [
  ["hex", col("#123456")],
  ["hex-alpha", col("#12345680")],
  ["named", col("rebeccapurple")],
  ["hsl", col("hsl(200 50% 40%)")],
  ["hwb", col("hwb(200 20% 30%)")],
  ["lab", col("lab(50% 40 -30)")],
  ["lch", col("lch(50% 60 200)")],
  ["oklab", col("oklab(0.6 0.1 -0.1)")],
  ["oklch", col("oklch(0.7 0.25 150)")],
  ["oklch-out-of-gamut", col("oklch(0.9 0.4 150)")],
  ["display-p3", col("color(display-p3 1 0 0)")],
  ["rec2020", col("color(rec2020 0 1 0)")],
  ["srgb-linear", col("color(srgb-linear 0.5 0.5 0.5)")],
  ["a98", col("color(a98-rgb 0 1 0)")],
  ["prophoto", col("color(prophoto-rgb 0 1 0)")],
  ["xyz", col("color(xyz-d65 0.3 0.4 0.5)")],
  ["device-cmyk", col("device-cmyk(0 1 1 0)")],
  ["device-cmyk-fallback", col("device-cmyk(0 1 1 0 / 1, #f00)")],
  ["color-mix", col("color-mix(in oklab, red, blue)")],
  ["color-mix-srgb", col("color-mix(in srgb, red 30%, blue)")],
  ["relative", col("rgb(from red r g 200)")],
  ["light-dark", col("light-dark(#060, #0f0)")],
  ["gray", col("#808080")],
  ["black", col("#000")],
  ["white", col("#fff")],
  ["transparent", col("transparent")],
  ["system-color", col("CanvasText")],
  ["accent-color", col("AccentColor")],
  ["rgb-float", col("rgb(12.5% 50% 87.5%)")],
  ["rgb-none", col("rgb(none 128 0)")],
]);

// Relative colours (task 23): pinned takumi `parse_relative_color` takes keyword channels, numbers,
// percentages, hue angles and `none`, from an origin computed to rgba8; `calc()` channels,
// `color(from ...)` and a `currentColor` origin are invalid (the declaration is dropped). The
// colours resolve before gradients see them, so a stop does not change the interpolation space.
const rel = (c, extra = "") => `<div style="width:60px;height:30px;margin:10px;background:${c};border:4px solid ${c};color:${c};font:14px Inter;${extra}">Tx</div>`;
cases("paint.color-relative", "relative colour syntax", [
  ["channel-swap", rel("rgb(from #336699 b g r)")],
  ["rgba-alias-alpha", rel("rgba(from #336699 r g b / .5)")],
  ["alpha-keyword", rel("rgb(from rgb(10 20 30 / .5) r g b / alpha)")],
  ["alpha-from-origin", rel("rgb(from #33669980 r g b)")],
  ["alpha-percent", rel("rgb(from red r g b / 25%)")],
  ["alpha-clamped", rel("rgb(from red r g b / 3)")],
  ["channel-percent", rel("rgb(from red 50% g b)")],
  ["channel-out-of-range", rel("rgb(from red 300 g -20)")],
  ["none-channel", rel("rgb(from red none g b)")],
  ["hsl", rel("hsl(from #336699 h s 70%)")],
  ["hsl-hue-units", rel("hsl(from #336699 .5turn s l)") + rel("hsl(from #336699 1rad s l)") + rel("hsl(from #336699 100grad s l)")],
  ["hwb", rel("hwb(from #336699 h w 40%)")],
  ["lab", rel("lab(from #336699 l a 40)")],
  ["lch-chroma-percent", rel("lch(from #336699 l 50% h)")],
  ["oklab", rel("oklab(from #336699 l a b)")],
  ["oklch-out-of-gamut-clipped", rel("oklch(from #336699 .9 .4 h)")],
  ["nested-origin", rel("rgb(from hsl(from red 120deg s l) r g b)")],
  ["origin-transparent", rel("rgb(from transparent r g 255 / 1)")],
  ["origin-color-mix", rel("rgb(from color-mix(in srgb, red, blue) r g b)")],
  ["origin-oklch", rel("rgb(from oklch(.7 .1 200) r g b)")],
  ["calc-channel-invalid", rel("rgb(from red calc(r - 100) g b)")],
  ["current-color-origin-invalid", rel("rgb(from currentColor r g b)", "color:#0a0")],
  ["color-function-from-invalid", rel("color(from red srgb r g b)")],
  ["trailing-junk-invalid", rel("rgb(from red r g b junk)")],
  ["var-origin", rel("rgb(from var(--c) r g b)", "--c:#0a0")],
  ["var-channel", rel("rgb(from red var(--g) g b)", "--g:20")],
  ["var-whole-colour", rel("var(--rc)", "--rc:rgb(from #336699 b g r)")],
  ["inherited-as-current-color", `<div style="color:rgb(from #336699 b g r)"><div style="width:60px;height:30px;margin:10px;border:4px solid currentColor;font:14px Inter">Tx</div></div>`],
  ["box-shadow", `<div style="width:40px;height:20px;margin:20px;box-shadow:4px 4px 0 rgb(from #336699 b g r / .5)"></div>`],
  ["text-shadow", `<div style="margin:10px;font:20px Inter;text-shadow:2px 2px 0 rgb(from red r 200 b)">Tx</div>`],
  ["svg-fill-inline", `<div style="margin:10px"><svg width="20" height="20"><rect width="20" height="20" fill="rgb(from #336699 b g r)"/></svg></div>`],
  ["svg-fill-image", `<div style="margin:10px"><img src="${svgUri(`<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="rgb(from #336699 b g r)"/></svg>`)}"></div>`],
], vp(140, 80));

probeAs("paint.color-relative.values", "relative colours: the written colour values", async (t) => {
  const r = await t.bm(rel("rgb(from #336699 b g r / .5)"), vp(140, 80));
  if (r.error) return t.ok(false, r.error);
  // b g r of #336699 = 153 102 51 at half alpha: 0.6 0.4 0.2 rg with a 0.5 fill alpha
  t.ok(/0\.6 0\.4 0\.2 rg/.test(r.content(0)), "channels swapped (0.6 0.4 0.2 rg)");
  const bad = await t.bm(rel("rgb(from red calc(r - 100) g b)", "background:#0a0"), vp(140, 80));
  if (!bad.error) t.ok(!/1 0 0 rg/.test(bad.content(0)), "an unsupported calc() channel drops the declaration (no red)");
});

// A relative colour is not a legacy colour: a gradient with one interpolates in Oklab, as takumi-core
// decides (`peeks_modern_color_function`). takumi-pdf then writes every gradient in sRGB, the
// deliberate difference of paint.gradient.linear-in-oklab (docs/PDF_AUDIT.md), so this probe checks
// bm-render against its own explicit `in oklab` gradient instead of against the reference.
probeAs("paint.color-relative.gradient-interpolation", "relative colours in gradients: Oklab interpolation", async (t) => {
  const grad = (g) => `<div style="width:80px;height:30px;margin:10px;background:linear-gradient(${g})"></div>`;
  for (const [label, relative, explicit] of [
    ["rgb(from)", "90deg, rgb(from red r g 200), rgb(from blue r 128 b)", "90deg in oklab, rgb(255 0 200), rgb(0 128 255)"],
    ["oklch(from)", "90deg, oklch(from red l c h), blue", "90deg in oklab, red, blue"],
  ]) {
    const a = await t.bm(grad(relative), vp(140, 80));
    const b = await t.bm(grad(explicit), vp(140, 80));
    if (a.error || b.error) { t.ok(false, `${label}: ${a.error || b.error}`); continue; }
    t.ok(JSON.stringify(canonPages(a)) === JSON.stringify(canonPages(b)), `${label}: same gradient as an explicit \`in oklab\` one`);
  }
});

// ------------------------------------------------------------------------------------------------ form controls, misc

cases("paint.form-control", "form controls", [
  ["input-text", `<input type="text" value="Hello" style="margin:20px;font:14px Inter">`],
  ["input-placeholder", `<input type="text" placeholder="Name" style="margin:20px;font:14px Inter">`],
  ["input-password", `<input type="password" value="secret" style="margin:20px;font:14px Inter">`],
  ["checkbox", `<input type="checkbox" style="margin:20px">`],
  ["checkbox-checked", `<input type="checkbox" checked style="margin:20px">`],
  ["radio", `<input type="radio" style="margin:20px">`],
  ["radio-checked", `<input type="radio" checked style="margin:20px">`],
  ["range", `<input type="range" value="30" style="margin:20px">`],
  ["color", `<input type="color" value="#ff0000" style="margin:20px">`],
  ["button", `<button style="margin:20px;font:14px Inter">Press</button>`],
  ["input-submit", `<input type="submit" value="Send" style="margin:20px;font:14px Inter">`],
  ["select", `<select style="margin:20px;font:14px Inter"><option>One</option><option selected>Two</option></select>`],
  ["textarea", `<textarea style="margin:20px;font:14px Inter" rows="2" cols="10">Multi\nline</textarea>`],
  ["progress", `<progress value="30" max="100" style="margin:20px"></progress>`],
  ["meter", `<meter value="0.6" style="margin:20px"></meter>`],
  ["details", `<details open style="margin:20px;font:14px Inter"><summary>Sum</summary>Body</details>`],
  ["details-closed", `<details style="margin:20px;font:14px Inter"><summary>Sum</summary>Body</details>`],
  ["hr", `<hr style="margin:20px">`],
  ["fieldset", `<fieldset style="margin:10px;font:14px Inter"><legend>Legend</legend>Body</fieldset>`],
  ["canvas", `<canvas width="40" height="30" style="margin:20px;background:#eee"></canvas>`],
  ["video", `<video width="40" height="30" style="margin:20px;background:#000"></video>`],
  ["iframe", `<iframe width="40" height="30" style="margin:20px"></iframe>`],
  ["object", `<object data="${PNG}" width="40" height="30" style="margin:20px"></object>`],
  ["mark-kbd", `<p style="margin:20px;font:14px Inter"><mark>mark</mark> <kbd>kbd</kbd> <code>code</code> <ins>ins</ins> <del>del</del></p>`],
  ["appearance-none", `<input type="checkbox" checked style="margin:20px;appearance:none;width:20px;height:20px;border:2px solid #000">`],
]);

cases("paint.table", "table painting", [
  ["collapsed-borders", `<table style="margin:10px;border-collapse:collapse;font:12px Inter"><tr><td style="border:2px solid red">a</td><td style="border:4px dashed blue">b</td></tr><tr><td style="border:1px solid #000">c</td><td style="border:3px double green">d</td></tr></table>`],
  ["separate-borders", `<table style="margin:10px;border:2px solid #000;border-spacing:4px;font:12px Inter"><tr><td style="border:1px solid red;background:#ff0">a</td><td style="border:1px solid blue">b</td></tr></table>`],
  ["row-col-backgrounds", `<table style="margin:10px;border-collapse:collapse;font:12px Inter"><colgroup><col style="background:#fee"><col style="background:linear-gradient(red,blue)"></colgroup><tr style="background:rgba(0,255,0,.3)"><td>a</td><td>b</td></tr><tr><td style="background:#00f8">c</td><td>d</td></tr></table>`],
  ["radius-table", `<table style="margin:10px;border:2px solid #000;border-radius:8px;border-spacing:0;font:12px Inter;background:#eee;overflow:hidden"><tr><td style="background:#fc0">a</td><td>b</td></tr></table>`],
  ["empty-cells", `<table style="margin:10px;border-spacing:4px;empty-cells:hide;font:12px Inter"><tr><td style="border:1px solid red;background:#ff0"></td><td style="border:1px solid blue">b</td></tr></table>`],
  ["caption", `<table style="margin:10px;font:12px Inter;border:1px solid #000"><caption style="background:#fee">Cap</caption><tr><td>a</td></tr></table>`],
]);

cases("paint.list-marker", "list markers", [
  ["disc", `<ul style="font:14px Inter"><li>a</li><li>b</li></ul>`],
  ["circle-square", `<ul style="font:14px Inter"><li style="list-style:circle">a</li><li style="list-style:square">b</li></ul>`],
  ["decimal", `<ol style="font:14px Inter"><li>a</li><li>b</li></ol>`],
  ["inside", `<ul style="font:14px Inter;list-style-position:inside"><li>a</li></ul>`],
  ["image", `<ul style="font:14px Inter;list-style-image:url(${PNG})"><li>a</li></ul>`],
  ["marker-color", `<ul style="font:14px Inter;color:#c00"><li>a</li></ul>`],
  ["marker-pseudo", `<style>li::marker{color:red;content:"> "}</style><ul style="font:14px Inter"><li>a</li></ul>`],
]);

cases("paint.pseudo", "generated content painting", [
  ["before-after", `<style>.x::before{content:"";display:block;width:20px;height:10px;background:red}.x::after{content:"z";color:blue}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["first-letter", `<style>p::first-letter{color:red;font-size:30px}</style><p style="margin:20px;font:14px Inter">Drop cap</p>`],
  ["first-line", `<style>p::first-line{color:red}</style><p style="margin:20px;font:14px Inter;width:80px">First line colour here</p>`],
  ["selection-ignored", `<style>p::selection{background:red}</style><p style="margin:20px;font:14px Inter">Sel</p>`],
  ["content-url", `<style>.x::before{content:url(${PNG})}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-url-sized", `<style>.x::before{content:url(${PNG});display:inline-block;width:4px;height:4px}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient", `<style>.x::before{content:linear-gradient(red,blue)}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient-sized", `<style>.x::before{content:linear-gradient(red,blue);display:inline-block;width:24px;height:16px}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient-inline-sized", `<style>.x::before{content:linear-gradient(red,blue);width:24px;height:16px}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient-inline-mixed", `<style>.x::before{content:'before' linear-gradient(red,blue) 'after'}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient-block-auto", `<style>.x::before{content:linear-gradient(red,blue);display:block}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient-atomic-auto", `<style>.x::before{content:linear-gradient(red,blue);display:inline-block}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
  ["content-gradient-mixed", `<style>.x::before{content:'before' radial-gradient(red,blue) 'after';display:block;width:100px;height:80px}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`],
]);

probeAs("paint.pseudo.content-url-mixed", "a generated URL stays inline between surrounding pseudo text", async (t) => {
  const html = `<style>.x::before{content:'before' url(${PNG}) 'after';display:inline-block;width:40px;height:24px}</style><div class="x" style="margin:20px;font:14px Inter">mid</div>`;
  const r = await t.bm(html, vp(), { fonts: [INTER] });
  if (r.error) { t.ok(false, "mixed generated image renders: " + r.error); return; }
  const extracted = pdftotext(r.bytes, "pseudo-content-url-mixed", ["-bbox"]);
  if (!extracted.ok) { t.ok(false, "Poppler bbox extraction: " + extracted.stderr); return; }
  const words = new Map([...extracted.text.matchAll(/<word xMin="[\d.-]+" yMin="([\d.-]+)" xMax="[\d.-]+" yMax="[\d.-]+">([^<]+)<\/word>/g)].map((m) => [m[2], Number(m[1])]));
  const before = words.get("before"); const after = words.get("after"); const mid = words.get("mid");
  if (before === undefined || after === undefined || mid === undefined) { t.ok(false, "extracted generated text keeps before/after/host words"); return; }
  t.ok(Math.abs(after - mid) < 0.02, "host text shares the line after the generated image");
  t.ok(after - before < 24, "mixed generated image does not add a block line before following text");
});

// ------------------------------------------------------------------------------------------------ found while auditing

cases("paint.clip-path-syntax", "clip-path syntax accepted by each engine", [
  ["ellipse-two-value-position", clip("ellipse(40px 20px at 50% 50%)")],
  ["circle-keyword-position", clip("circle(30px at center)")],
  ["circle-top-left", clip("circle(30px at left top)")],
  ["inset-percent", clip("inset(10% 20% 30% 5%)")],
  ["polygon-px-percent", clip("polygon(10px 10px, 90% 10px, 50% 100%)")],
]);

cases("paint.media", "@media print / screen in PDF output", [
  ["print", `<style>.x{background:#888}@media print{.x{background:#0a0}}</style><div class="x" style="margin:20px;width:100px;height:60px"></div>`],
  ["screen", `<style>.x{background:#888}@media screen{.x{background:#c00}}</style><div class="x" style="margin:20px;width:100px;height:60px"></div>`],
  ["not-print", `<style>.x{background:#888}@media not print{.x{background:#c00}}</style><div class="x" style="margin:20px;width:100px;height:60px"></div>`],
  ["print-color-adjust", `<div style="margin:20px;width:100px;height:60px;background:#06c;print-color-adjust:economy"></div>`],
]);

cases("paint.overflow-own-text", "overflow: hidden clips the box's own text", [
  ["wrapped-lines", `<div style="margin:10px;font:20px Inter;width:120px;height:20px;overflow:hidden">A long line that does not fit in the box at all</div>`],
  ["nowrap", `<p style="margin:10px;font:20px Inter;width:120px;white-space:nowrap;overflow:hidden">A long line that does not fit</p>`],
  ["radius", `<p style="margin:10px;font:20px Inter;width:120px;white-space:nowrap;overflow:hidden;border-radius:12px;background:#eee">A long line that does not fit</p>`],
  ["inline-child", `<p style="margin:10px;font:20px Inter;width:120px;white-space:nowrap;overflow:hidden"><b>A long</b> line that does not fit</p>`],
], vp(260, 120));

cases("paint.inline-effects", "effects on inline boxes (span)", [
  ["opacity", `<p style="margin:20px;font:16px Inter">a <span style="opacity:.4">faded</span> b</p>`],
  ["outline", `<p style="margin:20px;font:16px Inter">a <span style="outline:2px solid red">ring</span> b</p>`],
  ["text-shadow", `<p style="margin:20px;font:16px Inter">a <span style="text-shadow:2px 2px red">shade</span> b</p>`],
  ["filter", `<p style="margin:20px;font:16px Inter">a <span style="filter:invert(1);color:#c00">inv</span> b</p>`],
  ["background-border", `<p style="margin:20px;font:16px Inter">a <span style="background:#ff0;border:1px solid red;border-radius:3px">box</span> b</p>`],
  ["box-shadow", `<p style="margin:20px;font:16px Inter">a <span style="box-shadow:0 0 0 2px red">ring</span> b</p>`],
  ["mix-blend-mode", `<p style="margin:20px;font:16px Inter;background:#fc0">a <span style="mix-blend-mode:multiply;color:#06c">mul</span> b</p>`],
  ["transform", `<p style="margin:20px;font:16px Inter">a <span style="transform:rotate(20deg)">rot</span> b</p>`],
  ["position-relative", `<p style="margin:20px;font:16px Inter">a <span style="position:relative;top:5px;color:red">rel</span> b</p>`],
  ["clip-path", `<p style="margin:20px;font:16px Inter">a <span style="clip-path:inset(0 50% 0 0)">clip</span> b</p>`],
  ["mask", `<p style="margin:20px;font:16px Inter">a <span style="mask-image:linear-gradient(90deg,#000,transparent)">mask</span> b</p>`],
  ["underline-inline-block-sibling", `<p style="margin:20px;font:16px Inter;text-decoration:underline">a <span style="display:inline-block">ib</span> b</p>`],
  ["line-through-nested-size", `<p style="margin:20px;font:16px Inter"><s>a<span style="font-size:30px">B</span>c</s></p>`],
]);

// Vertical writing modes (`writing-mode`, `text-orientation`, orthogonal flows) against Chrome.
//
//   node scripts/writing-mode-test.mjs [--no-build] [--out=<dir>] [--case=<name>]   (npm run test:writing-mode)
//
// takumi has no vertical writing modes, so the reference is Chromium (Playwright's, `require("playwright")`;
// the image comparisons are skipped with a note when it is not installed). Every fixture below is rendered
// by bm-render/full (PNG and SVG) and by bm-render/pdf, with Noto Sans TC (a variable CJK font with `vhea` /
// `vmtx` and a `vert` feature, from the takumi test assets) registered in both engines:
//   * PNG vs a Chrome screenshot (deviceScaleFactor 1, same font through @font-face): mean absolute luma
//     difference and the share of pixels that differ by more than 48 after a 3x3 box blur, which keeps glyph
//     anti-aliasing out and catches anything misplaced by a pixel or more. Each fixture has a ceiling.
//   * SVG (rasterized by Chrome) vs the PNG.
//   * PDF: the text layer (`pdftotext`, poppler) reads in logical order.
// Builds js/bm_render.wasm and js/bm_render.pdf.wasm first (`scripts/build.mjs`; --no-build reuses js/).
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath, pathToFileURL } from "node:url";
import { findBin } from "../bench/pdf/lib/tools.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const opt = Object.fromEntries(argv.map((a) => /^--([^=]+)(?:=(.*))?$/.exec(a)).filter(Boolean).map((m) => [m[1], m[2] ?? true]));

if (!opt["no-build"]) {
  for (const p of ["full", "pdf"]) {
    const r = spawnSync(process.execPath, [path.join(root, "scripts", "build.mjs"), `--profile=${p}`], { cwd: root, stdio: "inherit" });
    if (r.status !== 0) { console.error(`FAIL  build of the ${p} profile`); process.exit(1); }
  }
}

const FONT = path.join(root, "tests/upstream/takumi/assets/fonts/noto-sans/NotoSansTC-VariableFont_wght.woff2");
const fontBytes = readFileSync(FONT);
const F = "font-family:'Noto Sans TC';";

/** name -> { w, h, body, max: ceiling of `pctBad` vs Chrome, text: expected PDF text (whitespace removed) in
 * poppler's reading order (`raw`: in content-stream order) } */
const FIXTURES = {
  "rl-mixed": { w: 300, h: 240, max: 1.5, text: "日本語の書き方テキスト。CSS2024年、ABCと123を含む。",
    body: `<body style="margin:0;background:#fff"><div style="writing-mode:vertical-rl;height:200px;${F}font-size:20px;padding:10px;background:#eef;line-height:1.5">日本語の書き方テキスト。CSS 2024年、ABC と 123 を含む。</div></body>` },
  "rl-root": { w: 320, h: 200, max: 4, text: "吾輩は猫である。名前はまだ無い。",
    body: `<body style="writing-mode:vertical-rl;${F}font-size:18px;margin:8px">吾輩は猫である。名前はまだ無い。どこで生れたかとんと見えぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。</body>` },
  // (`raw`: checked in content-stream order, `pdftotext -raw`. Poppler's reading-order reconstruction
  // reads turned lines from right to left, so it reverses vertical-lr columns, and it splits a
  // line of only upright glyphs at the gaps their vertical advances leave.)
  "lr-zh": { w: 300, h: 240, max: 1, text: "春眠不覺曉，處處聞啼鳥。夜來風雨聲，", raw: true,
    body: `<body style="margin:0"><div style="writing-mode:vertical-lr;height:200px;${F}font-size:20px;padding:10px;border:2px solid #c00;background:#efe">春眠不覺曉，處處聞啼鳥。夜來風雨聲，花落知多少。Spring 2024</div></body>` },
  "upright": { w: 200, h: 260, max: 0.5, text: "ABC123東京タワー", raw: true,
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;text-orientation:upright;height:240px;${F}font-size:20px;padding:8px">ABC 123 東京タワー</div></body>` },
  "sideways": { w: 200, h: 260, max: 0.5, text: "東京Tokyo2024年",
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;text-orientation:sideways;height:240px;${F}font-size:20px;padding:8px">東京 Tokyo 2024 年</div></body>` },
  // (Chrome sets the combined units a few px right of the line's centre; bm-render centres them)
  "tate-chu-yoko": { w: 200, h: 260, max: 3.5, text: "平成12年2024年の!?", raw: true,
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;height:240px;${F}font-size:24px;padding:8px">平成<span style="text-combine-upright:all">12</span>年<span style="text-combine-upright:all">2024</span>年の<span style="text-combine-upright:all">!?</span></div></body>` },
  "heading": { w: 400, h: 260, max: 1, text: null,
    body: `<body style="margin:0;${F}font-size:16px"><div style="padding:10px;height:240px"><h1 style="writing-mode:vertical-rl;margin:0;font-size:28px;color:#035;background:#fde">見出し Title</h1><p style="margin:8px 0">横書きの段落です。The heading above is vertical.</p></div></body>` },
  "spans": { w: 300, h: 240, max: 4, text: "普通の赤い文字と背景付きと下線と大きい字。",
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;height:220px;${F}font-size:20px;padding:10px">普通の<span style="color:#c00">赤い文字</span>と<span style="background:#ff0">背景付き</span>と<span style="text-decoration:underline">下線</span>と<span style="font-size:28px">大きい字</span>。</div></body>` },
  "align": { w: 320, h: 240, max: 0.5, text: null,
    body: `<body style="margin:0;${F}font-size:20px"><div style="writing-mode:vertical-rl;height:220px;padding:10px"><p style="margin:0;text-align:center">中央揃え</p><p style="margin:0 10px;text-align:end">末尾揃え</p><p style="margin:0">先頭</p></div></body>` },
  "zh-punct": { w: 300, h: 260, max: 4.5, text: "床前明月光，疑是地上霜。",
    body: `<body style="margin:0"><div lang="zh-Hant" style="writing-mode:vertical-rl;height:240px;${F}font-size:22px;padding:6px;background:#f6f6f6">床前明月光，疑是地上霜。舉頭望明月，低頭思故鄉。（李白）</div></body>` },
  "horizontal-in-vertical": { w: 480, h: 240, max: 1.5, text: null,
    body: `<body style="margin:0;writing-mode:vertical-rl;${F}font-size:18px"><p style="margin:10px">本文の文章。</p><div style="writing-mode:horizontal-tb;background:#def;padding:6px;margin:10px 0">Horizontal box 横書き</div><p style="margin:10px">また縦書き。</p></body>` },
  "blocks": { w: 320, h: 220, max: 1.5, text: null,
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;height:200px;${F}font-size:18px;padding:8px;background:#fafae0"><p style="margin:0 0 0 12px;border-right:3px solid #08c;padding-right:4px">第一段落の文章。</p><p style="margin:0;color:#555">第二段落、少し長い文章があります。</p><p style="margin:0;padding-inline-start:30px">字下げ</p></div></body>` },
  "logical": { w: 300, h: 220, max: 1, text: null,
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;height:200px;${F}font-size:18px;background:#eee"><div style="margin-block-start:20px;padding-inline-start:40px;border-block-start:4px solid #c00;border-inline-start:4px solid #0a0;background:#fff">論理プロパティ</div></div></body>` },
  "flex": { w: 300, h: 220, max: 1, text: null,
    body: `<body style="margin:0"><div style="writing-mode:vertical-rl;display:flex;height:200px;gap:10px;${F}font-size:18px;background:#eef"><div style="background:#fcc;flex:1">一番目</div><div style="background:#cfc">二番目の項目</div></div></body>` },
};

// ---- images

/** PNG (8-bit gray / RGB / RGBA / palette, non-interlaced) -> straight RGBA. */
function decodePng(buf) {
  let p = 8, w = 0, h = 0, ct = 0, bd = 0, plte = null, trns = null;
  const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p), type = buf.toString("latin1", p + 4, p + 8), data = buf.subarray(p + 8, p + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); bd = data[8]; ct = data[9]; if (data[12]) throw new Error("interlaced PNG"); }
    else if (type === "IDAT") idat.push(data);
    else if (type === "PLTE") plte = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IEND") break;
    p += 12 + len;
  }
  const ch = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct];
  if (bd !== 8 && !(ct === 3 && bd <= 8)) throw new Error("PNG bit depth " + bd);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const bpp = ct === 3 ? 1 : ch, stride = ct === 3 ? Math.ceil((w * bd) / 8) : w * ch;
  const out = new Uint8Array(w * h * 4), prev = new Uint8Array(stride), cur = new Uint8Array(stride);
  let q = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[q++];
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
      let v = raw[q++];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      cur[x] = v & 255;
    }
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4, i = x * ch;
      if (ct === 3) {
        const idx = bd === 8 ? cur[x] : (cur[(x * bd) >> 3] >> (8 - bd - ((x * bd) & 7))) & ((1 << bd) - 1);
        out[o] = plte[idx * 3]; out[o + 1] = plte[idx * 3 + 1]; out[o + 2] = plte[idx * 3 + 2]; out[o + 3] = trns && idx < trns.length ? trns[idx] : 255;
      } else if (ch <= 2) { out[o] = out[o + 1] = out[o + 2] = cur[i]; out[o + 3] = ch === 2 ? cur[i + 1] : 255; }
      else { out[o] = cur[i]; out[o + 1] = cur[i + 1]; out[o + 2] = cur[i + 2]; out[o + 3] = ch === 4 ? cur[i + 3] : 255; }
    }
    prev.set(cur);
  }
  return { w, h, data: out };
}

function luma(img) {
  const g = new Float32Array(img.w * img.h);
  for (let i = 0; i < g.length; i++) {
    const a = img.data[i * 4 + 3] / 255;
    g[i] = (0.299 * img.data[i * 4] + 0.587 * img.data[i * 4 + 1] + 0.114 * img.data[i * 4 + 2]) * a + 255 * (1 - a);
  }
  return g;
}
function blur3(g, w, h) {
  const o = new Float32Array(g.length);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let s = 0, n = 0;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      const xx = x + dx, yy = y + dy;
      if (xx >= 0 && yy >= 0 && xx < w && yy < h) { s += g[yy * w + xx]; n++; }
    }
    o[y * w + x] = s / n;
  }
  return o;
}
/** { meanAbs: mean |luma difference|, pctBad: % of pixels differing by > 48 after a 3x3 blur } */
function compare(a, b) {
  if (a.w !== b.w || a.h !== b.h) throw new Error(`size ${a.w}x${a.h} vs ${b.w}x${b.h}`);
  const ga = luma(a), gb = luma(b), ba = blur3(ga, a.w, a.h), bb = blur3(gb, a.w, a.h);
  let sum = 0, bad = 0;
  for (let i = 0; i < ga.length; i++) { sum += Math.abs(ga[i] - gb[i]); if (Math.abs(ba[i] - bb[i]) > 48) bad++; }
  return { meanAbs: sum / ga.length, pctBad: (100 * bad) / ga.length };
}

// ---- run

const full = await import(pathToFileURL(path.join(root, "js", "node-full.mjs")).href);
const pdfMod = await import(pathToFileURL(path.join(root, "js", "node-pdf.mjs")).href);
const r = new full.Renderer();
r.registerFont({ data: fontBytes, name: "Noto Sans TC" });
const pr = new pdfMod.Renderer();
pr.registerFont({ data: fontBytes, name: "Noto Sans TC" });

let chromium = null;
try { chromium = createRequire(import.meta.url)("playwright").chromium; } catch { console.log("NOTE  playwright not found: the Chrome comparisons are skipped"); }
const pdftotext = findBin("poppler", "pdftotext") || "pdftotext";
const hasPoppler = spawnSync(pdftotext, ["-v"]).error == null;
if (!hasPoppler) console.log("NOTE  pdftotext not found: the PDF text checks are skipped");

const outDir = typeof opt.out === "string" ? path.resolve(opt.out) : null;
if (outDir) mkdirSync(outDir, { recursive: true });
const tmp = mkdtempSync(path.join(os.tmpdir(), "bm-wm-"));
let fails = 0, passes = 0;
const check = (cond, msg) => { console.log(`${cond ? "PASS" : "FAIL"}  ${msg}`); cond ? passes++ : fails++; };

const browser = chromium ? await chromium.launch() : null;
const page = browser ? await browser.newPage({ deviceScaleFactor: 1 }) : null;
const fontUrl = "data:font/woff2;base64," + fontBytes.toString("base64");
try {
  for (const [name, fx] of Object.entries(FIXTURES)) {
    if (typeof opt.case === "string" && opt.case !== name) continue;
    const html = `<!doctype html><html><head></head>${fx.body}</html>`;
    const opts = { width: fx.w, height: fx.h, format: "png" };
    const png = Buffer.from(r.renderSync(html, opts));
    const ours = decodePng(png);
    const svg = r.renderSvgSync(html, opts);
    if (outDir) { writeFileSync(path.join(outDir, name + ".bm.png"), png); writeFileSync(path.join(outDir, name + ".bm.svg"), svg); }
    if (page) {
      // (bm-render's initial box-sizing is border-box, as takumi's)
      const chromeHtml = `<!doctype html><html><head><style>*{box-sizing:border-box}@font-face{font-family:"Noto Sans TC";src:url(${fontUrl}) format("woff2");font-weight:100 900}</style></head>${fx.body}</html>`;
      await page.setViewportSize({ width: fx.w, height: fx.h });
      await page.setContent(chromeHtml, { waitUntil: "load" });
      await page.evaluate(() => document.fonts.ready);
      const shot = await page.screenshot();
      if (outDir) writeFileSync(path.join(outDir, name + ".chrome.png"), shot);
      const m = compare(ours, decodePng(shot));
      check(m.pctBad <= fx.max, `${name}: PNG vs Chrome  meanAbs ${m.meanAbs.toFixed(2)}  differing ${m.pctBad.toFixed(2)} % (<= ${fx.max} %)`);
      await page.setContent(`<html><body style="margin:0"><img src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}"></body></html>`, { waitUntil: "load" });
      const sshot = await page.screenshot();
      const ms = compare(ours, decodePng(sshot));
      check(ms.pctBad <= 0.25, `${name}: SVG vs PNG  meanAbs ${ms.meanAbs.toFixed(2)}  differing ${ms.pctBad.toFixed(2)} % (<= 0.25 %)`);
    }
    if (hasPoppler && fx.text) {
      const pdf = await pr.renderPdf(html, { viewport: { width: fx.w, height: fx.h } });
      const file = path.join(tmp, name + ".pdf");
      writeFileSync(file, pdf);
      if (outDir) writeFileSync(path.join(outDir, name + ".pdf"), pdf);
      const t = spawnSync(pdftotext, [...(fx.raw ? ["-raw"] : []), file, "-"], { encoding: "utf8" });
      const got = String(t.stdout).replace(/\s+/g, "");
      check(t.status === 0 && got.includes(fx.text), `${name}: PDF text layer in logical order (${fx.text.slice(0, 12)}...)${got.includes(fx.text) ? "" : `  got: ${got.slice(0, 60)}`}`);
    }
  }
} finally {
  if (browser) await browser.close();
  rmSync(tmp, { recursive: true, force: true });
}
console.log(`\n${passes} passed, ${fails} failed`);
process.exit(fails ? 1 : 0);

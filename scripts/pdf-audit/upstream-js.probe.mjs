// Case-level ports of the takumi-pdf-js / shared-preparation Bun tests (tests/upstream/takumi/takumi-pdf-js/tests,
// takumi-helpers/tests, takumi-bindings-js/tests at the pinned revision) that no other probe or `npm run test:pdf`
// check covers. Each scenario runs on both engines through the public JS API and the observable calls / results are
// compared. scripts/pdf-coverage.mjs maps the Bun declaration to the probe named `upstream.js.<slug>`.
import { bmMod, font, NOTO_TC, probe, refMod, ARCHIVO } from "./lib.mjs";

const latinFace = font(ARCHIVO);
const interFace = font("assets/fonts/Inter-Regular.ttf");
const noto = font(NOTO_TC);
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAE0lEQVR4nGP4z8AAQv8ZQASIBQBDzgf5kLRQ3gAAAABJRU5ErkJggg==", "base64");
const isPdf = (bytes) => bytes instanceof Uint8Array && Buffer.from(bytes.subarray(0, 5)).toString("latin1") === "%PDF-";
const pages = (bytes) => (Buffer.from(bytes).toString("latin1").match(/\/Type\s*\/Page\b(?!s)/g) || []).length;

/** Runs `scenario(mod, log)` on both engines and compares the logs. */
function calls(slug, feature, scenario, { sorted = false, expect } = {}) {
  probe(`upstream.js.${slug}`, feature, async (t) => {
    const run = async (mod) => {
      const log = [];
      try { await scenario(mod, log); } catch (e) { log.push("threw: " + String(e?.message ?? e).replace(/^bm-render: /, "")); }
      return sorted ? log.sort() : log;
    };
    const bm = await run(bmMod);
    t.note("bm: " + JSON.stringify(bm));
    if (expect) t.ok(JSON.stringify(bm) === JSON.stringify(expect), `bm ${JSON.stringify(bm)}, the Bun test expects ${JSON.stringify(expect)}`);
    if (!refMod) { t.same("reference", 0, 0); return; }
    t.same("calls", bm, await run(refMod));
  });
}
const loader = (log, name, range, data) => ({ name, unicodeRange: [range], data: () => { log.push(name); return data; } });

// takumi-pdf-js render.test.ts "keeps a face the page counter needs but the document never uses"
calls("counter-face", "a unicodeRange face only a page counter's style needs is loaded", async (mod, log) => {
  const rows = Array.from({ length: 60 }, (_, i) => `<div style="font-size:16px">Row ${i + 1}</div>`).join("");
  const pdf = await new mod.PdfRenderer().render(`<div style="display:flex;flex-direction:column">${rows}</div>`, {
    size: { width: 400, height: 300 }, margin: 24,
    fonts: [{ name: "Latin", data: () => { log.push("Latin"); return latinFace; } }, loader(log, "Counter CJK", [0x4e00, 0x9fff], noto)],
    footer: `<div style="display:flex;font-size:12px"><span class="totalPages trad-chinese-informal"></span></div>`,
  });
  log.push(isPdf(pdf) && pages(pdf) > 1 ? "paged pdf" : "no paged pdf");
}, { sorted: true, expect: ["Counter CJK", "Latin", "paged pdf"] });

// takumi-pdf-js render.test.ts "loads font subsets for characters only a stylesheet adds"
calls("stylesheet-characters", "the characters a stylesheet's generated content adds reach font subsetting", async (mod, log) => {
  await new mod.PdfRenderer().render(`<div>a</div>`, {
    viewport: { width: 100, height: 100 },
    css: ["div::before { content: 'Ж' }"],
    fonts: [loader(log, "latin", [0x20, 0x7f], interFace), loader(log, "cyrillic", [0x400, 0x4ff], interFace), loader(log, "greek", [0x370, 0x3ff], interFace)],
  });
}, { sorted: true, expect: ["cyrillic", "latin"] });

// takumi-pdf-js render.test.ts "a using block frees the renderer"
calls("using-frees", "a using block (Symbol.dispose) frees the renderer", async (mod, log) => {
  const local = new mod.PdfRenderer();
  local[Symbol.dispose]();
  try { local.clearFonts(); log.push("clearFonts after dispose: ok"); } catch { log.push("clearFonts after dispose: throws"); }
}, { expect: ["clearFonts after dispose: throws"] });

// takumi-helpers / takumi-bindings-js renderer-facade.test.ts "fonts accepts a promise of the list"
calls("fonts-promise", "the fonts option accepts a promise of the list", async (mod, log) => {
  const pdf = await new mod.PdfRenderer().render("<p>A</p>", { viewport: { width: 100, height: 40 }, fonts: Promise.resolve([loader(log, "Fam", [0x41, 0x5a], latinFace)]) });
  log.push(isPdf(pdf) ? "pdf" : "no pdf");
});

// takumi-helpers renderer-facade.test.ts "a face covering list-marker characters stays without list content"
calls("list-marker-face", "a face whose range covers only a list-marker character, with no list in the document", async (mod, log) => {
  const pdf = await new mod.PdfRenderer().render("<p>一</p>", { viewport: { width: 100, height: 40 }, uncoveredText: "blank", fonts: [loader(log, "Bullet", [0x2022, 0x2022], latinFace), loader(log, "CJK", [0x4e00, 0x9fff], noto)] });
  log.push(isPdf(pdf) ? "pdf" : "no pdf");
}, { sorted: true });

// takumi-helpers prepare-images.test.ts "extracts urls from backgroundImage, maskImage, and tw"
calls("image-urls", "prepare fetches the URLs of background-image, mask-image and a Tailwind arbitrary background", async (mod, log) => {
  const fetch = async (url) => { log.push(String(url)); return new Response(png, { headers: { "content-type": "image/png" } }); };
  const html = `<div style="width:20px;height:20px;background-image:url(https://example.com/bg.png);mask-image:url('https://example.com/mask.png')"><div tw="w-4 h-4 bg-[url(https://example.com/tw.png)]"></div></div>`;
  await new mod.PdfRenderer().prepare(html, { viewport: { width: 40, height: 40 }, images: { fetch } });
}, { sorted: true, expect: ["https://example.com/bg.png", "https://example.com/mask.png", "https://example.com/tw.png"] });

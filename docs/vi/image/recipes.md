# Recipes

[English](../../en/image/recipes.md) · [Tiếng Việt](recipes.md)

Các đoạn mã theo tác vụ cho những thứ mọi người hay xây với bm-render: file trên đĩa, endpoint HTTP với
caching đúng cách, batch, worker pool, sinh ảnh lúc build, render trong trình duyệt, đầu ra high-DPI, chữ
vừa khít khung, ảnh từ xa, xử lý lỗi và font đa ngôn ngữ. Mỗi recipe ngắn và đầy đủ; phần lớn import
`getRenderer()` và `card()` từ module `og.js` được mô tả ở
[Frameworks → Mẫu chung](./frameworks/index.md#mẫu-chung).

::: info Trạng thái kiểm chứng
Mọi recipe đều được chạy trên Node 26.13 với tarball bm-render 0.1.0 đã đóng gói
(`docs/examples/frameworks/check-recipes.mjs`, `check-servers.mjs`, `check-browser.mjs`); số đo thời gian
lấy từ một máy thử Windows 11 và chỉ cho biết bậc độ lớn. Recipe Web Worker chạy trong Edge 157 headless.
:::

- [Ghi PNG ra đĩa](#ghi-png-ra-đĩa)
- [Phục vụ qua HTTP với ETag và Cache-Control](#phục-vụ-qua-http-với-etag-và-cache-control)
- [Render hàng loạt nhiều thẻ](#render-hàng-loạt-nhiều-thẻ)
- [Pool worker threads](#pool-worker-threads)
- [Sinh ảnh lúc build](#sinh-ảnh-lúc-build)
- [Render trong Web Worker](#render-trong-web-worker)
- [Đầu ra Retina / high-DPI](#đầu-ra-retina--high-dpi)
- [Làm chữ vừa khít với measure()](#làm-chữ-vừa-khít-với-measure)
- [Nhúng ảnh từ xa](#nhúng-ảnh-từ-xa)
- [Lỗi và timeout](#lỗi-và-timeout)
- [i18n: chuỗi font fallback](#i18n-chuỗi-font-fallback)

## Ghi PNG ra đĩa

```js
import { readFileSync, writeFileSync } from "node:fs";
import { Renderer } from "bm-render/core";

const renderer = new Renderer();
renderer.registerFont({ name: "Inter", data: readFileSync("fonts/Inter-Regular.ttf") });

const png = renderer.renderSync(
  { type: "container", style: { display: "flex", width: "100%", height: "100%", alignItems: "center", justifyContent: "center", backgroundColor: "#0f172a" },
    children: [{ type: "text", text: "Hello", style: { fontFamily: "Inter", fontSize: 96, color: "white" } }] },
  { width: 1200, height: 630 },
);
writeFileSync("og.png", png); // a Uint8Array; no Buffer conversion needed
```

`format: "jpeg"` (kèm `quality`), `"webp"` (lossless) và `"raw"` dùng giống hệt; xem
[Định dạng đầu ra](./formats.md).

## Phục vụ qua HTTP với ETag và Cache-Control

Hãy băm **đầu vào**, không phải đầu ra: khi đó một request có điều kiện được trả lời bằng `304` trước khi
render bất cứ thứ gì.

```js
import { createServer } from "node:http";
import { getRenderer, card } from "./og.js";

const TEMPLATE_VERSION = "card-v1"; // bump when the template or fonts change

async function etagFor(params) {
  const data = new TextEncoder().encode(TEMPLATE_VERSION + "\0" + JSON.stringify(params));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return `"${[...hash.subarray(0, 12)].map((b) => b.toString(16).padStart(2, "0")).join("")}"`;
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname !== "/og.png") return res.writeHead(404).end();
  const params = { title: url.searchParams.get("title") ?? "Hello", description: url.searchParams.get("description") ?? "Rendered with bm-render" };
  const etag = await etagFor(params);
  const headers = { etag, "cache-control": "public, max-age=3600, stale-while-revalidate=86400" };
  if (req.headers["if-none-match"] === etag) return res.writeHead(304, headers).end();
  try {
    const png = await getRenderer().render(card(params), { width: 1200, height: 630 });
    res.writeHead(200, { ...headers, "content-type": "image/png", "content-length": png.byteLength });
    res.end(png);
  } catch (error) {
    console.error(error);
    res.writeHead(500, { "content-type": "text/plain" }).end("Failed to generate image");
  }
}).listen(3000);
```

Đã kiểm chứng: một request lặp lại với `If-None-Match` nhận `304` và renderer chỉ chạy một lần.
`crypto.subtle` là global trong Node 18+, Deno, Bun, Workers và trình duyệt, nên `etagFor` dùng được ở mọi
nơi. Cùng logic này trong Hono, Express và các framework khác nằm ở
[Hono, Express và node:http](./frameworks/hono-express.md); cách chọn giá trị `cache-control` được nói ở
[Frameworks → Header caching](./frameworks/index.md#header-cache).

## Render hàng loạt nhiều thẻ

Dùng lại một renderer: font chỉ được parse một lần, còn cache và bộ nhớ wasm được tái sử dụng qua các lần
render.

```js
import { writeFile } from "node:fs/promises";
import { getRenderer, card } from "./og.js";

const renderer = getRenderer();
for (const post of posts) {
  const png = renderer.renderSync(card(post), { width: 1200, height: 630 });
  await writeFile(`out/${post.slug}.png`, png);
}
```

Số đo: 48 thẻ gradient (mỗi thẻ hai dòng chữ) mất khoảng 0,7 s trên một luồng — khoảng 14 ms mỗi thẻ —
với bộ nhớ wasm giữ ở 6,8 MiB. Nếu tạo một `new Renderer()` cho mỗi thẻ, font sẽ bị đăng ký lại mỗi lần.
Nếu buộc phải tạo renderer sống ngắn, hãy gọi `free()` (hoặc `using`) khi xong. Thêm số liệu:
[Hiệu năng](./performance.md) và [Benchmark](../benchmark.md).

## Pool worker threads

Engine chạy đơn luồng và một lần render chặn luồng của nó. Để tăng throughput, hoặc để giữ event loop của
HTTP server rảnh, hãy chạy một instance bm-render cho mỗi worker. Với backend wasm, `new Renderer({ workers: 4 })`
làm việc này giúp bạn: các hàm async của nó chạy trên một pool dựng sẵn, kể cả font
([chi tiết](../native-vs-wasm.md#wasm-ngoai-main-thread-workers)). Một pool tự viết, không cần dependency, cho bạn
toàn quyền kiểm soát:

```js
// render-worker.js
import { parentPort } from "node:worker_threads";
import { getRenderer, card } from "./og.js"; // each worker imports bm-render: its own wasm instance and fonts

parentPort.on("message", ({ id, props, options }) => {
  try {
    const png = getRenderer().renderSync(card(props), options);
    parentPort.postMessage({ id, png }, [png.buffer]); // transfer, no copy
  } catch (error) {
    parentPort.postMessage({ id, error: String(error?.message ?? error) });
  }
});
```

```js
// pool.js
import { Worker } from "node:worker_threads";
import { availableParallelism } from "node:os";

export function createPool(size = Math.max(1, availableParallelism() - 1), workerUrl = new URL("./render-worker.js", import.meta.url)) {
  const idle = [];
  const queue = [];
  const pending = new Map();
  let nextId = 0;
  const workers = Array.from({ length: size }, () => {
    const w = new Worker(workerUrl);
    w.on("message", ({ id, png, error }) => {
      const p = pending.get(id);
      pending.delete(id);
      error ? p.reject(new Error(error)) : p.resolve(png);
      idle.push(w);
      pump();
    });
    idle.push(w);
    return w;
  });
  function pump() {
    while (idle.length && queue.length) idle.pop().postMessage(queue.shift().msg);
  }
  return {
    render(props, options) {
      return new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        queue.push({ msg: { id, props, options } });
        pump();
      });
    },
    close: () => Promise.all(workers.map((w) => w.terminate())),
  };
}
```

```js
const pool = createPool(4);
const pngs = await Promise.all(posts.map((p) => pool.render(p, { width: 1200, height: 630 })));
await pool.close();
```

Số đo với 4 worker: cùng 48 thẻ trong 0,19–0,27 s (nhanh hơn 2,5–3,9× so với một luồng qua các lần chạy),
byte-identical với đầu ra từ main thread; một lần render không hợp lệ chỉ reject promise của chính nó. Mỗi
worker phải trả chi phí nạp wasm và font một lần (hãy làm nóng pool lúc khởi động). Hãy gửi props thay vì
node tree nếu cây chứa hàm; các object `Renderer` không thể chia sẻ giữa các luồng. Pool này không có cơ chế
phục hồi khi crash: code production nên thay thế worker phát ra `error` hoặc `exit`.

## Sinh ảnh lúc build

Với site tĩnh, hãy render ảnh một lần trong lúc build và phục vụ chúng như file. Script này bỏ qua các bài
viết có đầu vào không đổi kể từ lần chạy trước:

```js
// scripts/build-og.mjs — node scripts/build-og.mjs public/og
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { getRenderer, card } from "../og.js";

const TEMPLATE_VERSION = "card-v1"; // bump when the template or the fonts change

export async function buildOgImages(posts, outDir) {
  await mkdir(outDir, { recursive: true });
  const manifestPath = path.join(outDir, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8").catch(() => "{}"));
  const renderer = getRenderer();
  let rendered = 0;
  for (const post of posts) {
    const key = createHash("sha256").update(TEMPLATE_VERSION + JSON.stringify(post)).digest("hex").slice(0, 16);
    if (manifest[post.slug] === key) continue; // unchanged since the last build
    await writeFile(path.join(outDir, `${post.slug}.png`), renderer.renderSync(card(post), { width: 1200, height: 630 }));
    manifest[post.slug] = key;
    rendered++;
  }
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  return { rendered, skipped: posts.length - rendered };
}
```

Đã kiểm chứng: 5 bài → `{ rendered: 5, skipped: 0 }`; chạy lại → `{ rendered: 0, skipped: 5 }`; đổi một
tiêu đề → `{ rendered: 1, skipped: 4 }`. Hãy gắn nó trước bước build site
(`"build": "node scripts/build-og.mjs public/og && astro build"`), hoặc dùng prerendering của framework bạn
([Astro](./frameworks/astro.md), [SvelteKit](./frameworks/sveltekit.md#prerender-lúc-build),
[Next.js](./frameworks/nextjs.md#4-quy-ước-file-opengraph-image)).

## Render trong Web Worker

Trong trình duyệt, hãy chạy engine trong một module worker và gửi byte về (chuyển quyền sở hữu, không sao
chép):

```js
// render-worker.js
import { init, Renderer } from "bm-render/standard";

const ready = (async () => {
  await init();
  const renderer = new Renderer();
  renderer.registerFont({ name: "Inter", data: await (await fetch("/fonts/Inter-Regular.ttf")).arrayBuffer() });
  return renderer;
})();

self.onmessage = async ({ data: { id, node, options } }) => {
  try {
    const png = (await ready).renderSync(node, options);
    self.postMessage({ id, png }, [png.buffer]);
  } catch (error) {
    self.postMessage({ id, error: String(error?.message ?? error) });
  }
};
```

```js
// main thread
const worker = new Worker(new URL("./render-worker.js", import.meta.url), { type: "module" });
worker.onmessage = async ({ data: { png } }) => {
  const blob = new Blob([png], { type: "image/png" });
  img.src = URL.createObjectURL(blob);                              // as an image
  canvas.getContext("2d").drawImage(await createImageBitmap(blob), 0, 0); // or onto a canvas
};
worker.postMessage({ id: 1, node, options: { width: 1200, height: 630 } });
```

Đã kiểm chứng trong Edge 157 headless (không bundler, module worker, blob URL và `createImageBitmap` đều
cho 1200 × 630). Phần quản lý request/response bằng id và cách thiết lập Vite nằm ở
[Vite và trình duyệt](./frameworks/vite-browser.md#render-trong-web-worker).

## Đầu ra Retina / high-DPI

Nhân kích thước canvas **và** truyền `devicePixelRatio`:

```js
const dpr = 2;
const png = renderer.renderSync(node, { width: 600 * dpr, height: 315 * dpr, devicePixelRatio: dpr });
// display it at 600 × 315 CSS px
```

Đã kiểm chứng: kết quả là 1200 × 630, và chiều rộng các box đo được đúng bằng hai lần giá trị ở 1×. Riêng
`devicePixelRatio` chỉ phóng to nội dung nhưng giữ canvas ở `width × height` (một lần render 600 × 315 với
`devicePixelRatio: 2` vẫn là 600 × 315, với mọi độ dài CSS được nhân đôi bên trong nó). Trong trình duyệt
hãy dùng `window.devicePixelRatio` (có giới hạn trên, ví dụ 3). Xem thêm
[Xử lý sự cố](../troubleshooting.md#ảnh-bị-mờ-trên-màn-hình-dpi-cao).

## Làm chữ vừa khít với measure()

Chọn cỡ chữ lớn nhất mà tiêu đề còn vừa trong N dòng. `measure()` dàn layout mà không vẽ và trả về chiều
cao của box:

```js
function fitFontSize(renderer, text, { width, maxLines, max = 96, min = 32, lineHeight = 1.2, style = {} }) {
  for (let size = max; size > min; size -= 4) {
    const m = renderer.measureSync(
      { type: "container", style: { display: "block", width, fontSize: size, lineHeight, ...style }, children: [{ type: "text", text }] },
      { width },
    );
    if (m.height <= Math.ceil(size * lineHeight) * maxLines) return size;
  }
  return min;
}

const size = fitFontSize(renderer, post.title, { width: 1072, maxLines: 2, style: { fontFamily: "Inter", fontWeight: 700 } });
```

Đã kiểm chứng: "Short title" → 96 px; một tiêu đề 90 ký tự → 48 px, dàn thành 2 dòng (`m.runs.length`, các
line run của block). Hãy đo với cùng font, weight, chiều rộng và line height như lần render cuối. Quét
tuyến tính tốn một lần layout cho mỗi bước; dùng tìm kiếm nhị phân cho khoảng giá trị rộng. Chi tiết về đầu
ra của measure: [Measure](./measure.md). Các lựa chọn CSS không cần đo: `lineClamp` /
`textOverflow: "ellipsis"` (xem [Typography](./typography.md)).

## Nhúng ảnh từ xa

bm-render không bao giờ tải gì về: `src` của ảnh là một key trong option `images`. Hãy tự fetch byte (kèm
timeout), rồi render:

```js
async function fetchImages(urls, timeoutMs = 3000) {
  const entries = await Promise.all(urls.map(async (src) => {
    try {
      const res = await fetch(src, { signal: AbortSignal.timeout(timeoutMs) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return { src, data: new Uint8Array(await res.arrayBuffer()) };
    } catch (error) {
      console.warn(`image ${src} skipped: ${error.message}`);
      return null;
    }
  }));
  return entries.filter(Boolean);
}

const avatar = "https://example.com/avatar.png";
const png = renderer.renderSync(
  { type: "container", style: { display: "flex" }, children: [{ type: "image", src: avatar, width: 64, height: 64 }] },
  { width: 64, height: 64, images: await fetchImages([avatar]) },
);
```

Đã kiểm chứng với một server cục bộ: ảnh được fetch đã được vẽ (pixel ở giữa màu cam); một lỗi 404 và một
request chậm hơn timeout bị bỏ qua, và lần render vẫn thành công — ảnh bị thiếu thì không vẽ gì. Hãy cache
các byte đã tải (một LRU khóa theo URL) nếu cùng các ảnh lặp lại; hãy giới hạn các host được phép fetch nếu
URL đến từ người dùng. Định dạng theo từng profile (SVG và WebP cần `standard`) có ở [Ảnh](./images.md).

## Lỗi và timeout

```js
try {
  const png = await renderer.render(node, { width: 1200, height: 630, signal: AbortSignal.timeout(2000) });
} catch (error) {
  // "bm-render: invalid value for style property width", "bm-render: canvas too large", signal.reason, ...
}
```

Những gì đã được kiểm chứng:

- Một giá trị inline style không hợp lệ sẽ ném lỗi (`bm-render: invalid value for style property width`);
  `width` bằng 0 cũng ném lỗi. Đầu vào stylesheet hoặc Tailwind không hợp lệ thì bị bỏ qua âm thầm.
- `signal` được kiểm tra **trước** khi rasterise, sau khi các `fonts` bất đồng bộ / `images` lazy đã resolve:
  một signal đã abort sẵn sẽ reject với reason của nó, và một signal kích hoạt trong lúc font lazy đang tải
  cũng reject. Một lần render đã bắt đầu thì không thể bị ngắt — nó là đồng bộ.
- Để giới hạn thời gian CPU cho mỗi lần render, hãy render trong một worker và `terminate()` nó khi hết
  timeout (rồi tạo worker mới), đồng thời giới hạn kích thước đầu vào: độ dài chữ, số node và kích thước
  canvas (tối đa 16384 px mỗi cạnh và 40 megapixel).
- Font và ảnh bị thiếu không ném lỗi: chữ không được vẽ, ảnh không vẽ gì. Hãy kiểm tra giá trị trả về của
  `registerFont` lúc khởi động.

Danh sách đầy đủ: [API → Lỗi](./api.md#lỗi).

## i18n: chuỗi font fallback

Một ký tự thiếu trong các font của một element sẽ fallback sang **mọi family đã đăng ký, theo thứ tự đăng
ký**. Hãy đăng ký font chính trước và các font phủ rộng sau nó:

```js
renderer.registerFont(readFileSync("fonts/Inter-Regular.ttf"));       // first choice
renderer.registerFont(readFileSync("fonts/NotoSans-Regular.ttf"));    // Latin / Greek / Cyrillic extensions
renderer.registerFont(readFileSync("fonts/NotoSansJP-Regular.ttf"));  // CJK, if your text needs it (not part of the test)

renderer.renderSync({ type: "text", text: userText.normalize("NFC") }, { width: 1200, height: 630, fontFamilies: ["Inter", "Noto Sans"] });
```

Đã kiểm chứng với Inter + Noto Sans: "Xin chào · Привет · Ԁ" render khác so với chỉ dùng Inter (U+0500 đến từ
Noto Sans), trong khi phần Inter phủ được giống hệt từng pixel ở cả hai. `fontFamilies` đặt font stack gốc
cho các node không có `fontFamily`. Hãy chuẩn hóa đầu vào của người dùng về NFC (tiếng Việt và các chữ có
dấu khác). Emoji màu cần profile `full` và một font emoji màu; bidi và các hệ chữ phức tạp (Arabic, Hebrew,
Indic, Thai) cần `full`. Thêm: [Font](./fonts.md), [Typography](./typography.md).

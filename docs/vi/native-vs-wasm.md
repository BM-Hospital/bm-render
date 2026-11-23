# Native và WebAssembly

Chọn backend theo môi trường chạy. Trên Node.js, package ưu tiên addon native và tự chuyển sang WebAssembly khi addon không dùng được. Xem [Benchmark](benchmark.md) để đọc số đo tốc độ và bộ nhớ.

## Nên dùng backend nào

| Mã của bạn chạy ở đâu | Backend | Cách dùng |
|:--|:--|:--|
| Node.js, Bun, Deno (server, CLI, script build) | **native**, tự động quay về wasm | `import { Renderer, backend } from "bm-render"`; `backend` là `"native"` hoặc `"wasm"` |
| Trình duyệt, Web Worker | wasm (lựa chọn duy nhất) | `bm-render` trỏ tới bản wasm ở đó |
| Cloudflare Workers, Vercel / Netlify Edge, Deno Deploy và các runtime edge khác | wasm (lựa chọn duy nhất) | cùng câu import |
| Node.js nhưng vẫn muốn wasm (ví dụ để tái tạo đúng từng bit ảnh render trong trình duyệt, hoặc trên nền tảng mà addon chưa được kiểm thử) | wasm | `import ... from "bm-render/full"` hoặc `BM_RENDER_BACKEND=wasm` |
| Node.js, Bun, Deno và bạn muốn đầu ra PDF | **native**, tự động quay về profile wasm `pdf` | `import { PdfRenderer, backend } from "bm-render/pdf"`; xem [Đầu ra PDF](./pdf/native-and-wasm.md#backend-native-trên-nodejs) |
| Node.js và muốn báo lỗi thay vì lặng lẽ quay về wasm | native | `import ... from "bm-render/native"` hoặc `BM_RENDER_BACKEND=native` |

Việc quay về wasm diễn ra im lặng: nếu không có addon cho nền tảng, nếu CPU cũ hơn x86-64-v2 (SSE4.2), hoặc nếu
addon không qua bước kiểm tra dấu phẩy động lúc nạp, `bm-render` nạp bản wasm và mọi thứ vẫn chạy, chỉ chậm hơn
và các lời gọi async chạy trên main thread. Hãy ghi log `backend` một lần lúc khởi động nếu bạn cần biết.

`bm-render/pdf` theo cùng quy tắc: trên Node.js nó dùng addon khi đã cài, nếu không thì dùng profile wasm `pdf`, tạo
ra byte PDF giống hệt trên cả hai, và khi chạy native thì các phương thức async chạy trên thread pool của libuv.
Bản thân `bm-render` không cung cấp PDF trên backend nào, dù binary addon có chứa bộ ghi PDF.


## Mô hình thread

Với backend native, cái gì chạy ở đâu:

- `renderSync`, `measureSync`, `renderSvgSync`, `renderAnimationSync`, `registerFont`: trên thread gọi. Chúng chặn
  event loop trong suốt lời gọi, giống hệt bản wasm.
- `render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderAnimation`: đầu vào được sao chép, rồi engine chạy trên
  **một thread của thread pool libuv** và promise được hoàn tất trên thread JavaScript. Event loop vẫn tiếp tục phục
  vụ yêu cầu khác trong lúc render.
- **Một renderer chỉ xử lý một lời gọi tại một thời điểm.** Các lời gọi trên cùng một `Renderer` được xếp hàng theo
  thứ tự (vào trước ra trước). Muốn render song song, hãy tạo nhiều renderer (mỗi cái đăng ký font của nó) và chia
  việc cho chúng:

```js
import { Renderer } from "bm-render";

const fonts = [/* { name, data, weight, style } ... */];
const renderers = Array.from({ length: 4 }, () => {
  const r = new Renderer();
  for (const f of fonts) r.registerFont(f);
  return r;
});
let next = 0;
export function renderPng(node, options) {
  const r = renderers[next++ % renderers.length]; // xoay vòng
  return r.render(node, options); // chạy trên pool của libuv, không chặn event loop
}
```

- **Mức song song bị giới hạn bởi pool của libuv**, `UV_THREADPOOL_SIZE`, **mặc định là 4**. Pool này cũng phục vụ
  `fs`, `dns.lookup`, `crypto` và `zlib`. Muốn render trên nhiều thread hơn, đặt biến môi trường trước khi Node khởi
  động, ví dụ `UV_THREADPOOL_SIZE=8 node server.js` (gán `process.env.UV_THREADPOOL_SIZE` bên trong chương trình chỉ
  có tác dụng nếu chưa có gì dùng tới pool). Nhiều renderer hơn số thread của pool thì không giúp gì thêm.
- Các renderer khác nhau không dùng chung trạng thái nào (mỗi cái có font, cache và bộ nhớ riêng), nên chúng không
  bao giờ phải chờ nhau. Addon cũng nạp được trong `worker_threads`, nhưng với backend native thì một nhóm renderer
  trong một thread đã làm được việc đó mà không cần worker.
- Với backend **wasm**, mặc định các hàm async chạy trên thread gọi; truyền `workers` để chúng chạy trên worker
  thread ([bên dưới](#wasm-ngoai-main-thread-workers)).

## wasm ngoài main thread: `workers`

Với backend wasm (trình duyệt, Deno, Bun, edge runtime có worker, hoặc Node.js không có addon), một lần render chặn
thread mà nó chạy trên đó: trong [benchmark](benchmark.md), một render nặng 2400×2400 làm đứng event loop khoảng
0,5 giây và một animation 60 khung hình khoảng 0,9 giây, kể cả khi gọi qua các hàm async. Hãy bật pool worker cho
từng renderer:

```js
import { Renderer } from "bm-render/full";

const renderer = new Renderer({ workers: 2 }); // tối đa 2 worker, khởi động ở lời gọi async đầu tiên
renderer.registerFont({ name: "Inter", data: interBytes }); // tới được mọi worker
const png = await renderer.render(node, { width: 1200, height: 630 }); // chạy trong một worker
renderer.free(); // kết thúc các worker
```

`PdfRenderer` nhận cùng tùy chọn: `new PdfRenderer({ workers: 2 })`.

| | |
|:--|:--|
| Chạy trong worker | `render`, `renderAsDataUrl`, `renderSvg`, `measure`, `renderPdf`, `measurePdf`, `renderAnimation` (và `render` / `measure` của `PdfRenderer`) |
| Ở lại thread gọi | mọi hàm `*Sync`, `registerFont` / `unregisterFont` / `clearFonts`, `prepare` (chỉ giải quyết `fonts` / `images`), bước dò tài nguyên PDF |
| Đầu ra | giống từng byte với renderer chạy trong thread (mỗi worker chạy cùng module wasm đã biên dịch) |
| Font | đăng ký trên renderer, bằng `registerFont` hoặc tùy chọn `fonts`, và được phát lại trong từng worker trước lời gọi kế tiếp của nó, nên một lời gọi thấy đúng các font tại thời điểm nó được tạo; `unregisterFont` / `clearFonts` cũng vậy |
| Ảnh, tệp đính kèm | được sao chép một lần và bản sao được chuyển (transfer) sang worker; buffer của bạn không bao giờ bị tách (detach); kết quả được transfer về |
| Lỗi | reject với cùng thông điệp `Error` như khi chạy trong thread |
| `signal` | lời gọi đang xếp hàng bị bỏ và reject với `signal.reason`; lời gọi đang chạy reject ngay, worker vẫn làm xong và bỏ kết quả |
| `free()` / `Symbol.dispose` | kết thúc các worker; các lời gọi đang chờ reject với `bm-render: renderer has been freed` |
| Thoát process Node.js | worker rảnh được `unref`, nên một renderer bạn không bao giờ free cũng không giữ process sống |
| Backend native | `workers` bị bỏ qua: addon vốn đã render trên thread pool của libuv |

Đo trên Linux x64 với Node.js 22 (`npm run test:workers`), khoảng trễ dài nhất của một timer 1 ms trong lúc một lời
gọi chạy:

| Công việc | wasm, async trong thread | wasm, `workers: 1` |
|:--|--:|--:|
| PNG 2400×2400 (24 thẻ có blur và bóng đổ) | 440–720 ms | 5–10 ms |
| Animation WebP 800×420, 60 khung hình | 830–1300 ms | 5–10 ms |

Bản thân việc render mất khoảng chừng ấy thời gian (worker thêm vài ms truyền thông điệp), và các lời gọi chạy song
song tới tối đa `workers`. Mỗi worker giữ instance wasm riêng: bộ nhớ riêng, và một bản sao của mọi font đã đăng ký
(renderer cũng giữ một bản trên thread gọi để phát lại font cho các worker khởi động sau). `memoryBytes()` chỉ báo
instance của thread gọi.

Worker đến từ đâu:

- **Trình duyệt, Deno, Bun**: một module Web Worker tạo bằng
  `new Worker(new URL("./worker.mjs", import.meta.url), { type: "module" })`. Vite, webpack 5 và Parcel nhận ra dạng
  này và xuất worker thành một chunk riêng. Worker nhận `WebAssembly.Module` đã biên dịch mà `init()` tạo ra, nên nó
  chạy với mọi đối số của `init()` (bytes, URL, `Response`, module); runtime nào không gửi được module sang worker thì
  worker tải wasm từ URL mà `init()` đã fetch (hoặc reject, khi module được đưa vào dưới dạng bytes).
- **Node.js**: `worker_threads`, với `js/worker.mjs` nằm cạnh module. Khi bundle cho Node.js, hãy để `bm-render` là
  external (như với các tệp wasm của nó).
- Cloudflare Workers và các runtime không có constructor `Worker` không dùng được tùy chọn này.

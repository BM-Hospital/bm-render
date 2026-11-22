// bm-render internal: the render worker of `new Renderer({ workers: N })` (see js/worker-pool.mjs). Runs as a
// Web Worker (browsers, Deno, Bun) or a Node.js worker_threads worker. Messages are handled strictly in order:
//   { type: "init", module | url }   instantiate the wasm (the main thread's compiled module, or load it from url)
//   { type: "font", op, ... }        replay a font operation of the main-thread renderer
//   { type: "job", id, ... }         one serialised render call -> { type: "result", id, ok, value | message, name }
import { createBinding, BACKEND, readFileUrl } from "./engine.mjs";

const binding = createBinding();
let backend = null;
let handle = 0;
let initError = null;
let chain = Promise.resolve();
let post;

async function handleMessage(msg) {
  if (msg.type === "init") {
    try {
      let input = msg.module;
      if (!input) input = msg.url.startsWith("file:") ? await readFileUrl(new URL(msg.url)) : msg.url;
      await binding.init(input);
      backend = binding[BACKEND];
      handle = backend.create();
      if (!handle) throw new Error("bm-render: out of memory");
    } catch (e) {
      initError = e;
    }
    return;
  }
  if (msg.type === "font") {
    if (!handle) return;
    try {
      backend.run(handle, msg.op, msg.arg0, msg.arg1, msg.input, msg.options, msg.bytes ? ["", msg.bytes, 0, 0, 0] : null, msg.op === "registerFont");
    } catch {
      // registered fine on the main thread: the same bytes cannot fail here
    }
    return;
  }
  if (msg.type === "job") {
    try {
      if (!handle) throw initError || new Error("bm-render: render worker is not initialised");
      const value = backend.run(handle, msg.op, msg.kind, 0, msg.text, msg.opts, msg.atts, msg.decode);
      post({ type: "result", id: msg.id, ok: true, value }, typeof value === "string" ? [] : [value.buffer]);
    } catch (e) {
      post({ type: "result", id: msg.id, ok: false, message: e && e.message !== undefined ? e.message : String(e), name: e && e.name });
    }
  }
}

const enqueue = (msg) => { chain = chain.then(() => handleMessage(msg)); };

if (typeof self !== "undefined" && typeof self.postMessage === "function") {
  post = (msg, transfer) => self.postMessage(msg, transfer);
  self.onmessage = (ev) => enqueue(ev.data);
} else {
  // (no top-level await: some bundler targets reject it; parentPort queues messages until a listener is added)
  const name = "node:worker_threads";
  import(/* @vite-ignore */ /* webpackIgnore: true */ name).then(({ parentPort }) => {
    post = (msg, transfer) => parentPort.postMessage(msg, transfer);
    parentPort.on("message", enqueue);
  });
}

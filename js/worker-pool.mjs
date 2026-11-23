// bm-render internal: the worker pool behind `new Renderer({ workers: N })` on the wasm backend (js/engine.mjs).
//
// Each worker (js/worker.mjs) instantiates the same compiled WebAssembly.Module and owns one engine renderer.
// The main thread keeps its own renderer for the sync API and font registration; every font operation is
// appended to a log, and before a job reaches a worker the worker is brought up to the font state the job saw
// when it was made (the log position is snapshotted per job), so a call renders exactly what the in-thread
// renderer would have rendered at that moment. Jobs are the serialised calls of engine.mjs (`#call`,
// `#callPdf`, `#animation`): op, source text, options JSON and image attachments.
//
// Abort: a queued job is dropped and rejects with `signal.reason`; a running job rejects at once and its
// result is discarded when the worker finishes it (the worker is not terminated: respawning would replay
// every registered font). free() terminates every worker and rejects outstanding jobs.
// Node.js: workers are worker_threads, unref'ed while idle, so they never keep the process alive on their own.

const FREED = "bm-render: renderer has been freed";
const ERRORS = { TypeError, RangeError, SyntaxError };

/** A Node.js process without a Web Worker global (Node.js < 23 has none): use worker_threads. */
function useNodeWorkers() {
  return typeof globalThis.Worker !== "function" && typeof process !== "undefined" && !!(process.versions && process.versions.node);
}

let nodeWorkerClass = null;
function loadNodeWorker() {
  // computed name: keeps browser bundlers from resolving node:worker_threads
  const name = "node:worker_threads";
  return (nodeWorkerClass ??= import(/* @vite-ignore */ /* webpackIgnore: true */ name).then((m) => m.Worker));
}

/** The worker script, as the literal `new Worker(new URL("./worker.mjs", import.meta.url), ...)` that bundlers (Vite, webpack 5, Parcel, Rollup plugins) recognise, emit as a worker chunk and resolve. */
function spawnWeb() {
  return new Worker(new URL("./worker.mjs", import.meta.url), { type: "module", name: "bm-render" });
}

/** The parent's Node.js flags minus those that only apply to an `--eval` / stdin entry (they fail a file worker). */
function workerExecArgv() {
  const out = [];
  const argv = process.execArgv || [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--input-type" || a === "-e" || a === "--eval" || a === "-p" || a === "--print") { i++; continue; }
    if (a.startsWith("--input-type=") || a.startsWith("--eval=") || a.startsWith("--print=")) continue;
    out.push(a);
  }
  return out;
}

function spawnNode(NodeWorker) {
  // (not a literal: browser bundlers would copy worker.mjs once more, unbundled, as an asset for this Node.js path;
  // on Node.js keep bm-render external to the bundle, as for its wasm files)
  const file = "./worker.mjs";
  return new NodeWorker(new URL(file, import.meta.url), { name: "bm-render", execArgv: workerExecArgv() });
}

function abortReason(signal) {
  return signal.reason ?? new Error("bm-render: aborted");
}

export class WorkerPool {
  #size;
  /** () => { module, url }: the compiled module of the binding, and where it came from (fallback) */
  #source;
  #workers = [];
  #queue = [];
  /** font operations: { seq, op, arg0, arg1, input, options, bytes } (pruned at clearFonts entries) */
  #log = [];
  #seq = 0;
  #ids = 0;
  #closed = false;

  constructor(size, source) {
    this.#size = size;
    this.#source = source;
  }

  /** Records a font operation that succeeded on the main-thread renderer (bytes are copied: the caller owns them). */
  font(op, arg0, arg1, input, options, bytes) {
    if (this.#closed) return;
    this.#log.push({ seq: ++this.#seq, op, arg0, arg1, input, options, bytes: bytes ? new Uint8Array(bytes) : null });
    this.#prune();
  }

  /** Runs one serialised call on a worker; resolves with what backend.run would have returned. */
  run(job, decode, signal) {
    if (this.#closed) return Promise.reject(new Error(FREED));
    if (signal && signal.aborted) return Promise.reject(abortReason(signal));
    return new Promise((resolve, reject) => {
      const task = { id: ++this.#ids, job, decode, fontSeq: this.#seq, resolve, reject, signal, onAbort: null, done: false };
      if (signal) {
        task.onAbort = () => this.#settle(task, false, abortReason(signal));
        signal.addEventListener("abort", task.onAbort, { once: true });
      }
      this.#queue.push(task);
      this.#pump();
    });
  }

  /** Terminates every worker; outstanding jobs reject. */
  terminate() {
    if (this.#closed) return;
    this.#closed = true;
    const err = () => new Error(FREED);
    for (const t of this.#queue.splice(0)) this.#settle(t, false, err());
    for (const w of this.#workers.splice(0)) {
      if (w.task) this.#settle(w.task, false, err());
      w.dead = true;
      if (w.handle) w.handle.terminate();
    }
    this.#log = [];
  }

  #settle(task, ok, value) {
    if (task.done) return;
    task.done = true;
    const i = this.#queue.indexOf(task);
    if (i >= 0) this.#queue.splice(i, 1);
    if (task.signal) task.signal.removeEventListener("abort", task.onAbort);
    task.job = null;
    (ok ? task.resolve : task.reject)(value);
  }

  /** Drops log entries no future sync needs: everything before the last clearFonts at or below every pending snapshot. */
  #prune() {
    let min = this.#seq;
    for (const t of this.#queue) if (t.fontSeq < min) min = t.fontSeq;
    let cut = -1;
    for (let i = 0; i < this.#log.length && this.#log[i].seq <= min; i++) if (this.#log[i].op === "clearFonts") cut = i;
    if (cut > 0) this.#log.splice(0, cut);
  }

  #pump() {
    while (this.#queue.length && !this.#closed) {
      let w = this.#workers.find((x) => !x.task && !x.dead);
      if (!w) {
        if (this.#workers.length >= this.#size) return;
        w = this.#spawn();
        if (!w) return;
      }
      const task = this.#queue.shift();
      w.task = task;
      try {
        this.#syncFonts(w, task.fontSeq);
        const { op, kind, text, opts, atts } = task.job;
        // Attachment bytes belong to the caller: copy each once and transfer the copy (cloning a view would
        // copy its whole underlying buffer, e.g. a Node.js Buffer pool slab).
        const transfer = [];
        const own = atts ? atts.map((v, i) => {
          if (i % 5 !== 1) return v;
          const copy = new Uint8Array(v); // (not v.slice(): Buffer#slice is a view)
          transfer.push(copy.buffer);
          return copy;
        }) : null;
        this.#post(w, { type: "job", id: task.id, op, kind, text, opts, atts: own, decode: task.decode }, transfer);
        task.job = null;
        if (w.handle && w.handle.ref) w.handle.ref();
      } catch (e) {
        w.task = null;
        this.#settle(task, false, e);
      }
    }
    this.#prune();
  }

  /** Sends `w` the font operations up to `target` it has not seen (from the last clearFonts when pruned past it). */
  #syncFonts(w, target) {
    for (const e of this.#log) {
      if (e.seq <= w.fontSeq) continue;
      if (e.seq > target) break;
      this.#post(w, { type: "font", op: e.op, arg0: e.arg0, arg1: e.arg1, input: e.input, options: e.options, bytes: e.bytes });
      w.fontSeq = e.seq;
    }
  }

  #post(w, msg, transfer) {
    if (w.handle) w.handle.postMessage(msg, transfer || []);
    else w.outbox.push([msg, transfer]);
  }

  #spawn() {
    const w = { handle: null, outbox: [], task: null, fontSeq: 0, dead: false, ran: false };
    const { module, url } = this.#source();
    let init = { type: "init", module };
    const start = (handle) => {
      if (w.dead) { handle.terminate(); return; }
      w.handle = handle;
      const onMessage = (msg) => this.#onMessage(w, msg);
      const onFail = (e) => this.#fail(w, e);
      if (typeof handle.on === "function") {
        handle.on("message", onMessage);
        handle.on("error", onFail);
        handle.on("exit", (code) => onFail(new Error(`bm-render: render worker exited (code ${code})`)));
      } else {
        handle.onmessage = (ev) => onMessage(ev.data);
        handle.onerror = (ev) => { if (ev.preventDefault) ev.preventDefault(); onFail(new Error(ev.message || "bm-render: render worker failed to start")); };
        handle.onmessageerror = () => onFail(new Error("bm-render: render worker message could not be deserialised"));
      }
      // (Node.js worker_threads, Bun) an idle worker does not keep the process alive
      if (!w.task && typeof handle.unref === "function") handle.unref();
      try {
        handle.postMessage(init);
      } catch (e) {
        // A runtime that cannot send a WebAssembly.Module to a worker: let the worker load the wasm itself.
        if (!url) return onFail(new Error("bm-render: this runtime cannot send the WebAssembly.Module to a worker " +
          `(${e && e.message}); init() from a URL to use workers`));
        init = { type: "init", url };
        handle.postMessage(init);
      }
      for (const [msg, transfer] of w.outbox.splice(0)) handle.postMessage(msg, transfer || []);
    };
    this.#workers.push(w);
    try {
      if (useNodeWorkers()) loadNodeWorker().then((NodeWorker) => start(spawnNode(NodeWorker)), (e) => this.#fail(w, e));
      else start(spawnWeb());
    } catch (e) {
      this.#workers.pop();
      const err = new Error("bm-render: cannot start a render worker (" + (e && e.message) + ")");
      for (const t of this.#queue.splice(0)) this.#settle(t, false, err);
      return null;
    }
    return w;
  }

  #onMessage(w, msg) {
    if (!msg || msg.type !== "result") return;
    const task = w.task;
    w.task = null;
    w.ran = true;
    if (w.handle && w.handle.unref) w.handle.unref();
    if (task && task.id === msg.id) {
      if (msg.ok) this.#settle(task, true, msg.value);
      else {
        const E = ERRORS[msg.name] || Error;
        this.#settle(task, false, new E(msg.message));
      }
    }
    this.#pump();
  }

  /** A worker died (failed to load, crashed, exited): its job rejects; the next job spawns a replacement. */
  #fail(w, e) {
    if (w.dead) return;
    w.dead = true;
    const i = this.#workers.indexOf(w);
    if (i >= 0) this.#workers.splice(i, 1);
    const err = e instanceof Error ? e : new Error(String(e && e.message ? e.message : e));
    if (w.task) this.#settle(w.task, false, err);
    w.task = null;
    try { if (w.handle) w.handle.terminate(); } catch {}
    // a worker that never ran anything would fail again: reject what waits rather than respawn in a loop
    if (!w.ran) for (const t of this.#queue.splice(0)) this.#settle(t, false, err);
    else this.#pump();
  }
}

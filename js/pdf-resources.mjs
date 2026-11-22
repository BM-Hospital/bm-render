// PDF resource preparation. Discovery is the engine's cascade-only pass, shared by native/WASM.
const binary = (v) => v instanceof ArrayBuffer || ArrayBuffer.isView(v);

function ranges(value) {
  if (Array.isArray(value)) return value;
  if (typeof value !== "string") return null;
  return value.split(",").map((raw) => {
    const m = /^\s*U\+([0-9a-f?]{1,6})(?:-([0-9a-f]{1,6}))?\s*$/i.exec(raw);
    if (!m) throw new TypeError(`bm-render: invalid unicodeRange: ${raw}`);
    return [parseInt(m[1].replaceAll("?", "0"), 16), parseInt(m[2] ?? m[1].replaceAll("?", "f"), 16)];
  });
}

function uses(text, range) {
  const list = ranges(range);
  if (list === null) return true;
  for (const char of text) {
    const cp = char.codePointAt(0);
    if (list.some(([a, b]) => cp >= a && cp <= b)) return true;
  }
  return false;
}

const lower = (s) => String(s).toLowerCase();
const fontRange = (f) => f && !binary(f) && typeof f === "object" ? f.unicodeRange ?? f.ranges : undefined;
const imageInput = (images) => Array.isArray(images) ? { sources: images } : images && typeof images === "object" ? images : {};

function waitFor(promise, signal) {
  if (!signal) return promise;
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    promise.then((value) => { signal.removeEventListener("abort", abort); resolve(value); }, (error) => { signal.removeEventListener("abort", abort); reject(error); });
  });
}

async function download(url, config, signal) {
  const fetcher = config.fetch ?? globalThis.fetch;
  if (typeof fetcher !== "function") throw new Error(`bm-render: no fetch available for ${url}`);
  const response = await fetcher(url, signal ? { signal } : {});
  if (!response?.ok) throw new Error(`bm-render: fetching ${url} failed${response ? ` (${response.status})` : ""}`);
  const limit = config.maxBytes ?? 33554432;
  if (Number(response.headers?.get("content-length")) > limit) { await response.body?.cancel(); throw new Error(`Response exceeds ${limit} bytes`); }
  if (!response.body?.getReader) {
    const data = await response.arrayBuffer();
    if (data.byteLength > limit) throw new Error(`Response exceeds ${limit} bytes`);
    return data;
  }
  const reader = response.body.getReader();
  const chunks = []; let size = 0;
  try {
    for (;;) {
      signal?.throwIfAborted?.();
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new Error(`Response exceeds ${limit} bytes`); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const data = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.byteLength; }
  return data.buffer;
}

/** A signal aborted by the first of `signals` to abort (AbortSignal.any is missing before Node 20.3). */
function anySignal(signals) {
  const list = signals.filter(Boolean);
  if (list.length <= 1) return list[0];
  if (typeof AbortSignal.any === "function") return AbortSignal.any(list);
  const controller = new AbortController();
  for (const s of list) {
    if (s.aborted) { controller.abort(s.reason); break; }
    s.addEventListener("abort", () => controller.abort(s.reason), { once: true, signal: controller.signal });
  }
  return controller.signal;
}

async function bytes(url, config, signal) {
  if (config.allowUrl && !config.allowUrl(url)) throw new Error(`URL blocked by allowUrl policy: ${url}`);
  const limit = config.maxBytes ?? 33554432;
  const timeout = config.timeout ? AbortSignal.timeout(config.timeout) : undefined;
  const requestSignal = anySignal([signal, timeout]);
  requestSignal?.throwIfAborted?.();
  const cache = config.fetchCache;
  let pending = cache?.get(url);
  if (!pending) {
    // A cached download is shared by every caller: only the timeout may cancel it, never one
    // caller's own signal (each caller stops waiting on its signal through waitFor below).
    pending = download(url, config, cache ? timeout : requestSignal).catch((error) => { cache?.delete(url); throw error; });
    cache?.set(url, pending);
  }
  const data = await waitFor(pending, requestSignal);
  if (data.byteLength > limit) throw new Error(`Response exceeds ${limit} bytes`);
  return new Uint8Array(data);
}

function urls(source) {
  return [...(source ?? "").matchAll(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)/gi)]
    .map((m) => m[1] ?? m[2] ?? m[3]).filter(Boolean);
}

function weightDistance(face, weight) {
  const values = String(face.weight ?? "400").trim().split(/\s+/).map(Number);
  const lo = values[0]; const hi = values[1] ?? lo;
  return Number.isFinite(lo) && Number.isFinite(hi) ? Math.max(lo - weight, weight - hi, 0) : 0;
}

function usedFaces(needs, fallback) {
  const selected = new Map();
  for (const request of needs.requests) {
    const families = request.families.length ? request.families : fallback ?? [];
    for (const family of families) {
      const candidates = needs.faces.filter((face) => lower(face.name) === lower(family) && uses(request.text, face.unicodeRange));
      let best = Infinity;
      for (const face of candidates) best = Math.min(best, weightDistance(face, request.weight) + (lower(face.style ?? "normal") === request.style ? 0 : 10000));
      for (const face of candidates) if (weightDistance(face, request.weight) + (lower(face.style ?? "normal") === request.style ? 0 : 10000) === best) selected.set(JSON.stringify(face), face);
    }
  }
  return selected.values();
}

export async function resourceOptions(renderer, node, options = {}, fetchMissing = false) {
  if (options == null || typeof options !== "object" || Array.isArray(options)) return options;
  const signal = options.signal;
  signal?.throwIfAborted?.();
  const fonts = options.fonts == null ? undefined : await options.fonts;
  if (fonts !== undefined && !Array.isArray(fonts)) throw new TypeError("bm-render: fonts takes an array");
  const subsets = fonts?.some((f) => fontRange(f) !== undefined);
  if (!fetchMissing && !subsets) return fonts === undefined ? options : { ...options, fonts };
  const fallback = options.fontFamilies ?? fonts?.filter((f) => f && !binary(f) && typeof f.name === "string").map((f) => f.name);
  const config = imageInput(options.images);
  const knownSources = (config.sources ?? []).filter((s) => binary(s?.data));
  let needs = renderer.needsPdfSync(node, { ...options, images: knownSources, ...(fallback?.length ? { fontFamilies: fallback } : {}) });
  let result = fonts === undefined ? options : { ...options, fonts: fonts.filter((f) => uses(needs.text, fontRange(f))) };
  if (fallback?.length && options.fontFamilies === undefined) result = { ...result, fontFamilies: fallback };
  if (!fetchMissing) return result;
  const sources = config.sources ?? [];
  const have = new Set(sources.map((s) => s?.src));
  const pending = needs.images.filter((url) => !have.has(url) && !url.startsWith("data:") && (config.fetch !== undefined || /^https?:\/\//i.test(url)));
  const tasks = pending.map(async (src) => ({ src, data: await bytes(src, config, config.signal ?? signal) }));
  const fetched = config.throwOnError === false ? (await Promise.allSettled(tasks)).filter((r) => r.status === "fulfilled").map((r) => r.value) : await Promise.all(tasks);
  result = { ...result, images: [...sources, ...fetched] };
  // Downloaded SVG text can add font-face requests as well as font subsets.
  if (fetched.length) {
    needs = renderer.needsPdfSync(node, { ...result, images: [...knownSources, ...fetched], ...(fallback?.length ? { fontFamilies: fallback } : {}) });
    if (subsets) result.fonts = fonts.filter((f) => uses(needs.text, fontRange(f)));
  }
  const failed = new Set(options.failedFontFiles ?? []);
  const loaded = new Map();
  for (const face of usedFaces(needs, fallback)) {
    for (const url of urls(face.src)) {
      if (failed.has(url)) continue;
      try {
        if (!loaded.has(url)) loaded.set(url, bytes(url, config, signal));
        const data = await loaded.get(url);
        const descriptor = { name: face.name, data, ...(face.style ? { style: face.style } : {}), ...(face.unicodeRange ? { unicodeRange: face.unicodeRange } : {}) };
        if (/^\d+$/.test(face.weight ?? "")) descriptor.weight = Number(face.weight);
        await renderer.registerFont(descriptor);
        break;
      } catch (error) {
        signal?.throwIfAborted?.();
        failed.add(url);
      }
    }
  }
  signal?.throwIfAborted?.();
  return failed.size ? { ...result, failedFontFiles: [...failed] } : result;
}

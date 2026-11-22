# @hunghg255/bm-render-linux-x64-gnu

The native Node-API addon of [bm-render](https://www.npmjs.com/package/bm-render) for **Linux x64, glibc 2.17+**
(`os: linux`, `cpu: x64`, `libc: glibc`).

Do not install this package yourself. `npm install bm-render` lists every platform package as an optional
dependency and your package manager installs only the one that matches the machine. `bm-render` loads it
when present and otherwise uses its WebAssembly build, with the same API and the same output bytes:

```js
import { backend } from "bm-render";
console.log(backend); // "native" when this package is installed and loads, else "wasm"
```

It is released together with `bm-render` at the same version (0.1.3), which pins it exactly; an
addon whose internal interface version does not match the installed `bm-render` is ignored (wasm is used).
Requires Node-API 6 (`engines.node`: `>=10.20.0 <11 || >=12.17.0 <13 || >=14.0.0`); `bm-render` itself requires Node.js 20+.

The x64 binary needs an x86-64-v2 CPU (SSE4.2, 2009+); on older CPUs it refuses to load and `bm-render` uses wasm.

Status: cross-compiled and structurally verified (exports, imported symbols, CPU level), but **not yet executed on this platform** by the project; `bm-render` falls back to WebAssembly if it does not load.

License: MIT. See LICENSE, NOTICE and THIRD-PARTY-NOTICES.md.

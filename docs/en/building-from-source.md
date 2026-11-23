# Building from source

[English](building-from-source.md) · [Tiếng Việt](../vi/building-from-source.md)

This page explains how to build the library, run checks and find source modules. Build only when changing the engine or customizing a profile; the npm package includes prebuilt binaries.

## Prerequisites

- **Zig 0.17.x** (developed with 0.17.1). Not needed to use the package.
- **Node.js ≥ 20** for the build script (it runs `wasm-opt`), the benchmark and the playground.
- `wasm-opt` from binaryen: installed by `npm install` at the repository root (dev dependency
  `binaryen`) or in `bench/`. Without it the build script ships unoptimised binaries and warns.

The build script finds Zig through the `ZIG` environment variable, falling back to `zig` on `PATH`.

## Commands

```sh
npm install                        # root dev dependency: binaryen (wasm-opt)

node scripts/build.mjs             # core + standard + full + pdf + WOFF add-on: zig build (optimize=small) + wasm-opt -Oz
node scripts/build.mjs --profile=core          # one profile (core | standard | full | pdf)
node scripts/build.mjs -- -Dtables=false       # extra zig options for every profile (marked "custom" in the manifest)
node scripts/build.mjs --manifest  # rewrite js/build-manifest.json from the wasm files in js/
node scripts/build.mjs --verify    # check js/*.wasm against the manifest (run by prepublishOnly)
node scripts/build.mjs --test      # zig build test (also: npm test)
```

Outputs: `js/bm_render.core.wasm`, `js/bm_render.standard.wasm`, `js/bm_render.wasm` (full),
`js/bm_render.pdf.wasm` (full + PDF output), `js/bm_woff.wasm`, `zig-out/bin/bm_render.wasm` (full, optimised), `js/build-manifest.json` (profile,
size, sha256 and feature bits per file) and a size table written to `bench/out/sizes.json`.

Plain Zig commands:

```sh
zig build                                   # full profile, optimize=small -> zig-out/bin/bm_render.wasm (+ bm_woff.wasm)
zig build -Dprofile=standard -Dcss=false    # any profile + single-feature flags
zig build -Dwasm-optimize=safe -Dstrip=false  # safety-checked build (for fuzzing / debugging)
zig build addons                            # only the add-on modules
zig build test --summary all                # native unit tests of every module
```

Options: `-Dprofile=core|standard|full|pdf`, one `-D<feature>=true|false` per feature (list in
[Profiles and size](profiles-and-size.md#custom-builds)), `-Dwasm-optimize=small|fast|safe|debug`,
`-Dstrip=false`, `-Dstack-kib=<n>` (shadow stack, default 1024).

In a source checkout, `import "bm-render"` resolved to the repository (or `js/node.mjs` directly)
prefers a fresh `zig-out/bin/bm_render.wasm` over the packaged `js/bm_render.wasm`. `BM_WASM=<path>`
loads any binary.

## Tests

| What | Command | Notes |
|:--|:--|:--|
| Unit tests (native, every module) | `zig build test --summary all` | test data lives next to each module in `testdata/` |
| One module | `zig test src/<module>/<module>.zig` | modules that import siblings are tested through a `src/test_*.zig` root |
| Package smoke test | `npm run test:pack` | `scripts/pack-test.mjs`: packs the npm tarball and imports it |
| Feature probes per profile | `node bench/probe/profiles.mjs` | what each binary does with input of a missing feature; fails on any trap |
| Real browser | `cd bench && npm run browser:quick` | headless Edge / Chrome via puppeteer-core; raw output must equal Node's |
| Fuzzing (whole pipeline) | see below | run on a safety-checked build |
| Fuzzing (parsers, decoders) | `zig build test -Dtest-filter="fuzz: png" --fuzz=200K` | coverage-guided; see [Fuzzing the parsers](#fuzzing-the-parsers) |

Fuzzing the whole pipeline with random node trees on a ReleaseSafe build (a safety violation becomes a
wasm trap instead of silent memory corruption):

```sh
zig build -Dwasm-optimize=safe -Dstrip=false -p /tmp/bmsafe
cd bench
BM_WASM=/tmp/bmsafe/bin/bm_render.wasm node probe/fuzz.mjs 1 3000   # seed, iterations
```

### Fuzzing the parsers

`src/fuzz.zig` has one `std.testing.fuzz` target per component that reads untrusted bytes: `png`,
`jpeg`, `gif`, `webp` (decode + animation walk), `inflate`, `brotli`, `woff` (WOFF/WOFF2 + the font
it decodes to), `font` (TrueType / CFF / collections: metrics, outlines, shaping), `html`, `css`
(parser, selectors, cascade), `json`, `svg` (parse + render to 64x64), `render_html` and
`render_json` (the whole renderer on a 64x64 canvas). Seeds come from the `testdata/` folders
(plus `src/testdata/fuzz/`).

A plain `zig build test` runs each target once per seed (well under a second in total). To
fuzz one target with Zig's coverage-guided fuzzer (no CI runs this):

```sh
zig build test -Dtest-filter="fuzz: png" --fuzz=200K   # iterations; omit the number for the web UI
```

A failure is a panic, a safety check, a leak, or one input taking longer than 8 s (Debug build; the
error is `SlowInput`). Errors returned by the parsers are expected and ignored. Memory per input is
capped at 512 MiB (`error.OutOfMemory`, not a crash). The failing input is saved to
`.zig-cache/f/crash`: its first 4 bytes are a length prefix, the rest is the input. Strip them,
save the input under `src/testdata/fuzz/regress/` and add it to the `regressions` table in
`src/fuzz.zig` together with the fix. The corpus a run builds is kept in `.zig-cache/f/` and
reused by the next run. Run one target per command: two `--fuzz` runs in the same checkout share
that cache.

`zig build fuzz` is a deterministic mutation driver for the same targets (ReleaseSafe, no fuzzing
runtime needed). Its mutations repeat spans up to thousands of times, which finds quadratic and
allocation blow-ups that coverage guidance rarely reaches:

```sh
zig build fuzz -- all --seconds 60                  # every target, 60 s each (default seed 1)
zig build fuzz -- font css --seconds 300 --slow-ms 200 --seed 7
zig build fuzz -- font --replay path/to/input.bin   # re-run one input, prints its time
```

An input slower than `--slow-ms` (default 1000) is saved as `zig-out/fuzz/slow-<target>-<n>.bin`;
on a panic or a hang (20 s) the input is saved as `zig-out/fuzz/crash-<target>.bin` (Linux).

## Checking output

See [Benchmark](benchmark.md) for comparison setup and commands. Examples in `docs/examples/` exercise the documented API behavior.

## Repository layout

```
src/wasm.zig          wasm exports (C ABI), the only entry of the binary
src/config.zig        compile-time feature flags (set from build.zig profiles / -D flags)
src/render.zig        pipeline: source -> DOM -> style -> layout -> paint -> encode; options, caches
src/dom.zig           node tree from JSON, preset / css / tw / style cascade per element
src/json.zig          JSON parser
src/style/            CSS value parsing -> ComputedStyle (props.zig = property table), colours, gradients, calc
src/css/              stylesheet tokenizer / parser, selectors, cascade, @media / @supports
src/tw/               Tailwind compiler + palette
src/html/             HTML tokenizer / tree builder, UA presets, entities
src/layout/           block, inline, flex, grid, table, float layout
src/font/             sfnt / CFF / variations, shaping (GSUB / GPOS, Arabic, Indic), bidi, colour glyphs
src/woff/             WOFF / WOFF2 + brotli;  src/addon_woff.zig = the add-on module
src/raster/           paths, scan conversion (tiny-skia-exact AA), stroking, blur, blending, images
src/paint*.zig        painter (Blink paint order), borders, effects, text, tables, SVG images
src/svg/              SVG parser + renderer (for SVG images)
src/svg_out*.zig      renderSvg (node tree -> SVG document)
src/animate.zig       CSS animation sampling
src/codec/            PNG, JPEG, WebP (lossless + VP8), GIF, ICO, animation encoders, deflate / inflate
src/bump.zig, pages.zig  allocators (per-render bump arena, page allocator)
js/                   ESM wrapper (engine.mjs + entries), typings, prebuilt wasm, build manifest
scripts/              build.mjs (release build, manifest), pack-test.mjs
                      VitePress site config (.vitepress/), browser playground source (playground-app/)
```

## Documentation site

`docs/` is also a [VitePress](https://vitepress.dev/) site (config in `docs/.vitepress/`) with the
playground embedded. It needs Node.js ≥ 18 and `npm install` in the repository root, but not Zig: it uses
the prebuilt `js/*.wasm`.

```sh
npm run docs:dev        # = npm run docs; builds the playground into docs/public/playground-app, dev server on :5173
npm run docs:build      # static site in docs/.vitepress/dist
npm run docs:preview    # serves the build on :4173
```

`vercel.json` in the repository root deploys the site to Vercel (import the repository; no settings or
environment variables needed).

## Developer documents

- [ARCHITECTURE.md](../ARCHITECTURE.md): design, module map, render pipeline, wasm ABI.
- [CONVENTIONS.md](../CONVENTIONS.md): engineering rules (no `std.Io` / libc in library code,
  untrusted-input discipline, size discipline, file ownership).
- [BENCHMARK.md](../BENCHMARK.md), [RESULTS_FULL.md](../RESULTS_FULL.md), [results.json](../results.json):
  measurements.

## Contributing

- Read [CONVENTIONS.md](../CONVENTIONS.md) first: library code takes explicit allocators, never traps
  on untrusted input (bounds checks, no `unreachable`, bounded recursion: the wasm shadow stack is
  1 MiB), and reports its wasm size cost.
- Every optional feature must be guarded by a flag in `src/config.zig` so that it compiles out of the
  smaller profiles; run `node bench/probe/profiles.mjs` after touching feature boundaries.
- For rendering changes, add a fixture that exercises the behavior and run the relevant checks. See [Benchmark](benchmark.md) to measure output and timing.

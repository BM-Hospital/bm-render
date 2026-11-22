// The per-platform npm packages of the native addon (napi-rs style): @hunghg255/bm-render-<name>, one per target, each
// holding only bm-render.<name>.node (its `main`) and restricted with os / cpu / libc so that package managers
// install the matching one of the main package's optionalDependencies and skip the others.
//
//   node scripts/npm-platform-packages.mjs              (npm run build:npm) write npm/<name>/ for all 8 targets:
//                                                        package.json + README.md (committed, regenerated here),
//                                                        the .node file from native/dist/<name>/ (checked against
//                                                        native/dist/manifest.json) and the license files
//   node scripts/npm-platform-packages.mjs --check      version sync only, no binaries needed (part of
//                                                        npm run verify): every npm/<name>/package.json is what
//                                                        this script generates for the root version, and the root
//                                                        optionalDependencies list exactly the 8 packages at
//                                                        exactly the root version. Exit 1 otherwise.
//   node scripts/npm-platform-packages.mjs --set-version <x.y.z>   (npm run version:set -- x.y.z)
//                                                        sets the version in package.json, its optionalDependencies,
//                                                        package-lock.json and every npm/<name>/package.json
//   --out=<dir>        write the packages under <dir>/<name>/ instead of npm/<name>/ (scripts/pack-test.mjs)
//   --target=a,b       only these targets (build:npm)
//   --allow-missing    skip targets whose .node is not built instead of failing
//
// Generated fields come from the root package.json (version, license, author, homepage, repository, bugs) and
// the table below; nothing is invented.
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const opts = {};
const positional = [];
for (let i = 0; i < argv.length; i++) {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(argv[i]);
  if (!m) { positional.push(argv[i]); continue; }
  opts[m[1]] = m[2] ?? true;
}

/** The eight targets: npm name suffix -> os / cpu / libc / human description. */
export const PLATFORMS = {
  "win32-x64-msvc": { os: "win32", cpu: "x64", label: "Windows x64" },
  "win32-arm64-msvc": { os: "win32", cpu: "arm64", label: "Windows arm64" },
  "linux-x64-gnu": { os: "linux", cpu: "x64", libc: "glibc", label: "Linux x64, glibc 2.17+" },
  "linux-x64-musl": { os: "linux", cpu: "x64", libc: "musl", label: "Linux x64, musl (Alpine)" },
  "linux-arm64-gnu": { os: "linux", cpu: "arm64", libc: "glibc", label: "Linux arm64, glibc 2.17+" },
  "linux-arm64-musl": { os: "linux", cpu: "arm64", libc: "musl", label: "Linux arm64, musl (Alpine)" },
  "darwin-x64": { os: "darwin", cpu: "x64", label: "macOS x64 (10.15+)" },
  "darwin-arm64": { os: "darwin", cpu: "arm64", label: "macOS arm64 (11+)" },
};
/** Targets whose binary has been executed (bench/native-identity.mjs + bench/native-tests.mjs) by a maintainer. */
const EXECUTED = new Set(["win32-x64-msvc"]);

/**
 * Node versions with Node-API version 6, the highest version of the functions src/native/napi.zig binds
 * (napi_set_instance_data; everything else is Node-API 1). The main package's own floor is higher (>=18).
 */
export const NAPI_VERSION = 6;
export const NODE_RANGE = ">=10.20.0 <11 || >=12.17.0 <13 || >=14.0.0";
const LICENSE_FILES = ["LICENSE", "NOTICE", "THIRD-PARTY-NOTICES.md"];

const readJson = (f) => JSON.parse(readFileSync(f, "utf8"));
const writeJson = (f, v) => writeFileSync(f, JSON.stringify(v, null, 2) + "\n");
const pkgName = (name) => `@hunghg255/bm-render-${name}`;

/** package.json of one platform package for the given root package.json. */
export function platformManifest(rootPkg, name) {
  const p = PLATFORMS[name];
  const file = `bm-render.${name}.node`;
  const repository = typeof rootPkg.repository === "object" ? { ...rootPkg.repository, directory: `npm/${name}` } : rootPkg.repository;
  const m = {
    name: pkgName(name),
    version: rootPkg.version,
    description: `bm-render native Node-API addon for ${p.label}. Installed automatically by bm-render as an optional dependency; do not depend on it directly.`,
    keywords: ["bm-render", "napi", "native-addon"],
    license: rootPkg.license,
    author: rootPkg.author,
    homepage: rootPkg.homepage,
    repository,
    bugs: rootPkg.bugs,
    os: [p.os],
    cpu: [p.cpu],
  };
  if (p.libc) m.libc = [p.libc];
  Object.assign(m, {
    main: file,
    files: [file, ...LICENSE_FILES],
    engines: { node: NODE_RANGE },
    publishConfig: { access: "public" },
  });
  return m;
}

function readme(rootPkg, name) {
  const p = PLATFORMS[name];
  const status = EXECUTED.has(name)
    ? "This binary is executed by the project's native test suite (byte identity against the wasm build, threading, fuzzing)."
    : "Status: cross-compiled and structurally verified (exports, imported symbols, CPU level), but **not yet executed on this platform** by the project; `bm-render` falls back to WebAssembly if it does not load.";
  return `# ${pkgName(name)}

The native Node-API addon of [bm-render](https://www.npmjs.com/package/bm-render) for **${p.label}**
(\`os: ${p.os}\`, \`cpu: ${p.cpu}\`${p.libc ? `, \`libc: ${p.libc}\`` : ""}).

Do not install this package yourself. \`npm install bm-render\` lists every platform package as an optional
dependency and your package manager installs only the one that matches the machine. \`bm-render\` loads it
when present and otherwise uses its WebAssembly build, with the same API and the same output bytes:

\`\`\`js
import { backend } from "bm-render";
console.log(backend); // "native" when this package is installed and loads, else "wasm"
\`\`\`

It is released together with \`bm-render\` at the same version (${rootPkg.version}), which pins it exactly; an
addon whose internal interface version does not match the installed \`bm-render\` is ignored (wasm is used).
Requires Node-API ${NAPI_VERSION} (\`engines.node\`: \`${NODE_RANGE}\`); \`bm-render\` itself requires Node.js 18+.
${p.cpu === "x64" ? "\nThe x64 binary needs an x86-64-v2 CPU (SSE4.2, 2009+); on older CPUs it refuses to load and `bm-render` uses wasm.\n" : ""}
${status}

License: ${rootPkg.license}. See LICENSE, NOTICE and THIRD-PARTY-NOTICES.md.
`;
}

function targetsFromOpts() {
  if (!opts.target || opts.target === true) return Object.keys(PLATFORMS);
  const t = String(opts.target).split(",").map((s) => s.trim()).filter(Boolean);
  const bad = t.filter((n) => !PLATFORMS[n]);
  if (bad.length) throw new Error(`unknown target(s): ${bad.join(", ")} (known: ${Object.keys(PLATFORMS).join(", ")})`);
  return t;
}

/** Problems with the committed platform package.json files and the root optionalDependencies. */
export function checkSync(rootPkg = readJson(path.join(root, "package.json"))) {
  const problems = [];
  const v = rootPkg.version;
  const opt = rootPkg.optionalDependencies || {};
  for (const name of Object.keys(PLATFORMS)) {
    const want = pkgName(name);
    if (opt[want] !== v) problems.push(`package.json optionalDependencies["${want}"] is ${JSON.stringify(opt[want])}, expected "${v}"`);
    const f = path.join(root, "npm", name, "package.json");
    if (!existsSync(f)) { problems.push(`npm/${name}/package.json is missing`); continue; }
    const have = readJson(f);
    if (have.version !== v) problems.push(`npm/${name}/package.json version ${have.version} != root version ${v}`);
    if (JSON.stringify(have) !== JSON.stringify(platformManifest(rootPkg, name))) problems.push(`npm/${name}/package.json differs from what scripts/npm-platform-packages.mjs generates (run npm run build:npm, or npm run version:set)`);
  }
  for (const dep of Object.keys(opt)) if (!dep.startsWith("@hunghg255/bm-render-") || !PLATFORMS[dep.slice("@hunghg255/bm-render-".length)]) problems.push(`unexpected optionalDependency ${dep}`);
  return problems;
}

function setVersion(v) {
  if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(v || "")) throw new Error(`usage: npm run version:set -- <x.y.z[-pre]> (got ${JSON.stringify(v)})`);
  const pf = path.join(root, "package.json");
  const rootPkg = readJson(pf);
  const old = rootPkg.version;
  rootPkg.version = v;
  rootPkg.optionalDependencies = Object.fromEntries(Object.keys(PLATFORMS).map((n) => [pkgName(n), v]));
  writeJson(pf, rootPkg);
  const lf = path.join(root, "package-lock.json");
  if (existsSync(lf)) {
    const lock = readJson(lf);
    lock.version = v;
    if (lock.packages && lock.packages[""]) {
      lock.packages[""].version = v;
      lock.packages[""].optionalDependencies = { ...rootPkg.optionalDependencies };
    }
    // entries of an installed older platform package would make `npm ci` reject the lock: drop them
    for (const k of Object.keys(lock.packages || {})) if (/(^|\/)node_modules\/@hunghg255\/bm-render-[^/]+$/.test(k)) delete lock.packages[k];
    writeJson(lf, lock);
  }
  for (const name of Object.keys(PLATFORMS)) {
    const dir = path.join(root, "npm", name);
    mkdirSync(dir, { recursive: true });
    writeJson(path.join(dir, "package.json"), platformManifest(rootPkg, name));
    writeFileSync(path.join(dir, "README.md"), readme(rootPkg, name));
  }
  console.log(`version ${old} -> ${v}: package.json (+ optionalDependencies), package-lock.json, npm/*/package.json, npm/*/README.md`);
  console.log(`next: npm run build (rebuilds the wasm and js/build-manifest.json for ${v}; or node scripts/build.mjs --manifest to record the current binaries), npm run build:native, npm run build:npm, npm run verify`);
}

function build() {
  const rootPkg = readJson(path.join(root, "package.json"));
  const out = opts.out && opts.out !== true ? path.resolve(String(opts.out)) : path.join(root, "npm");
  const manifestFile = path.join(root, "native", "dist", "manifest.json");
  const manifest = existsSync(manifestFile) ? readJson(manifestFile) : null;
  const done = [], skipped = [], problems = [];
  for (const name of targetsFromOpts()) {
    const src = path.join(root, "native", "dist", name, `bm-render.${name}.node`);
    if (!existsSync(src)) {
      if (opts["allow-missing"]) { skipped.push(name); continue; }
      problems.push(`${path.relative(root, src)} is missing (npm run build:native)`);
      continue;
    }
    const bytes = readFileSync(src);
    const sha = createHash("sha256").update(bytes).digest("hex");
    const entry = manifest && manifest.files && manifest.files[name];
    if (!entry) problems.push(`native/dist/manifest.json has no entry for ${name} (npm run build:native)`);
    else {
      if (entry.sha256 !== sha) problems.push(`${name}: the .node file does not match native/dist/manifest.json (rebuild or re-verify: node scripts/build-native.mjs --verify-only)`);
      if (entry.verified !== true) problems.push(`${name}: not structurally verified in native/dist/manifest.json`);
    }
    const dir = path.join(out, name);
    mkdirSync(dir, { recursive: true });
    writeJson(path.join(dir, "package.json"), platformManifest(rootPkg, name));
    writeFileSync(path.join(dir, "README.md"), readme(rootPkg, name));
    copyFileSync(src, path.join(dir, `bm-render.${name}.node`));
    for (const f of LICENSE_FILES) copyFileSync(path.join(root, f), path.join(dir, f));
    done.push(`${name} (${(bytes.length / 1048576).toFixed(2)} MiB, sha256 ${sha.slice(0, 12)})`);
  }
  if (!opts.out) problems.push(...checkSync(rootPkg).filter((p) => !p.includes("differs from what")));
  for (const d of done) console.log(`  ${path.relative(root, out) || out}/${d}`);
  if (skipped.length) console.log(`  skipped (not built): ${skipped.join(", ")}`);
  if (problems.length) {
    console.error("bm-render: platform packages:\n  - " + problems.join("\n  - "));
    process.exit(1);
  }
  console.log(`${done.length} platform package(s) ready in ${out}. Publish them before the main package: see docs/en/publishing.md`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (opts["set-version"] !== undefined) setVersion(opts["set-version"] === true ? positional[0] : String(opts["set-version"]));
    else if (opts.check) {
      const problems = checkSync();
      if (problems.length) {
        console.error("bm-render: platform package versions are out of sync:\n  - " + problems.join("\n  - ") +
          "\nFix: npm run version:set -- <version> (rewrites package.json, optionalDependencies, npm/*/package.json).");
        process.exit(1);
      }
      console.log(`bm-render: 8 platform packages and optionalDependencies at ${readJson(path.join(root, "package.json")).version}`);
    } else build();
  } catch (e) {
    console.error("bm-render: " + e.message);
    process.exit(1);
  }
}

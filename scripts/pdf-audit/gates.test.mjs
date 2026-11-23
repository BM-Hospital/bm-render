import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { applyExceptions, kindOf, loadExceptions } from './gate.mjs';
import { fileURLToPath } from 'node:url';
import { fixtureEquivalence } from '../pdf-fixture-equivalence.mjs';
import { parseWordBoxes, wordBoxes } from './paged-helpers.mjs';

test('word geometry rejects empty extraction and retains genuinely empty pages', () => {
  assert.throws(() => parseWordBoxes(''), /no page elements/);
  assert.throws(() => parseWordBoxes('tool failed'), /no page elements/);
  assert.deepEqual(parseWordBoxes('<page width="10" height="10"></page>'), [[]]);
  assert.deepEqual(parseWordBoxes('<page width="10" height="10"><word xMin="1" yMin="2" xMax="3" yMax="4">A</word></page>'), [[['A', 1, 2, 3, 4]]]);
});

const runner = fileURLToPath(new URL('./run.mjs', import.meta.url));
function run(args) {
  const env = { ...process.env, BM_RENDER_BACKEND: 'wasm' };
  delete env.TAKUMI_PDF_REF;
  delete env.TAKUMI_PDF_REF_ENTRY;
  return spawnSync(process.execPath, [runner, ...args], { env, encoding: 'utf8', windowsHide: true, timeout: 120_000 });
}
test('strict audit rejects missing reference even when bm-only assertions pass', () => {
  const r = run(['--strict', 'paint.outline.inline-paged']);
  assert.equal(r.status, 1, r.stderr);
  assert.match(r.stdout, /UNVERIFIED\s+paint\.outline\.inline-paged/);
  assert.match(r.stdout, /0 pass, 0 fail, 0 expected .*1 unverified/);
});
test('a misspelled probe filter cannot create an empty passing gate', () => {
  const r = run(['--strict', 'gate.nonexistent-probe']);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /No PDF audit probes matched/);
});
test('unknown flags cannot silently disable the requested gate', () => {
  const r = run(['--strcit', 'paint.outline.inline-paged']);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /Unknown PDF audit option/);
});

test('a fixture equivalence never applies to another fixture or other instruction differences', async () => {
  const bytes = new Uint8Array();
  assert.equal(await fixtureEquivalence('another-fixture', bytes, bytes, [], [], () => { throw new Error('unexpected comparison'); }), null);
  assert.equal(await fixtureEquivalence('color-glyph-text-shadow', bytes, bytes, ['new paint'], ['old paint'], () => ({ verdict: 'DIFFER' })), null);
});

test('a changed mark cannot pass the form-bounds exception', async () => {
  const { PdfRenderer } = await import('../../js/node-pdf.mjs');
  const renderer = new PdfRenderer();
  const options = { viewport: { width: 64, height: 64 }, tagged: false };
  const red = await renderer.render('<div style="width:40px;height:40px;background:red"></div>', options);
  const blue = await renderer.render('<div style="width:40px;height:40px;background:blue"></div>', options);
  assert.deepEqual(wordBoxes(red), [[]], 'a real blank text page remains verifiable');
  // Even if the structural precondition admitted it, the viewer gate must reject it.
  const result = await fixtureEquivalence('color-glyph-text-shadow', red, blue, [], [], () => ({ verdict: 'CLOSE' }));
  assert.equal(result, null);
  renderer[Symbol.dispose]();
});

// ---- the strict gate's exception list (scripts/pdf-audit/gate.mjs, exceptions.json) ---------------------------

const writeList = (exceptions) => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), 'pdf-gate-')), 'exceptions.json');
  writeFileSync(file, JSON.stringify({ exceptions }));
  return file;
};
const REASON = 'a documented difference: bm-render follows CSS here and takumi does not, see PDF_AUDIT.md';
const row = (id, failures) => ({ id, status: failures.length ? 'FAIL' : 'PASS', failures, pass: 1, fail: failures.length });

test('assertion kinds keep page content, page count, boxes, text, links, tags and font mapping apart', () => {
  assert.equal(kindOf('page 1 differs. Content stream at token 9 (157 vs 148 tokens)\n bm: q'), 'page-content');
  assert.equal(kindOf('wide: page count: bm 5 | takumi 3 (5p ...)'), 'page-count');
  assert.equal(kindOf('wide: page boxes: bm 300x200 | takumi 200x300'), 'page-box');
  assert.equal(kindOf('text per page: bm ["a"] vs takumi ["b"]'), 'text');
  assert.equal(kindOf('full: links: bm 1 vs takumi 0'), 'links');
  assert.equal(kindOf('structure tree: first difference at 23: bm P'), 'tags');
  assert.equal(kindOf('U+200C mappings: bm ["067E200C"] vs takumi ["200C"]'), 'font-mapping');
  assert.equal(kindOf('huge: error: bm "invalid page size" vs takumi "(renders)"'), 'error');
});

test('an exception names one probe and one kind, with a reason; patterns, prefixes and catch-alls are refused', () => {
  const ok = { probe: 'paint.a', kind: 'page-content', match: '^page 1 differs', status: 'deliberate', reason: REASON };
  assert.equal(loadExceptions(writeList([ok])).length, 1);
  assert.throws(() => loadExceptions(writeList([{ ...ok, probe: 'paint.*' }])), /one probe id/);
  assert.throws(() => loadExceptions(writeList([{ ...ok, probe: 'paint.' }])), /one probe id/);
  assert.throws(() => loadExceptions(writeList([{ ...ok, kind: 'anything' }])), /unknown kind/);
  assert.throws(() => loadExceptions(writeList([{ ...ok, match: '.*' }])), /not match everything/);
  assert.throws(() => loadExceptions(writeList([{ ...ok, reason: 'because' }])), /explain/);
  assert.throws(() => loadExceptions(writeList([{ ...ok, status: 'ignored' }])), /status/);
  assert.throws(() => loadExceptions(writeList([ok, ok])), /duplicate/);
});

test('an exception covers only its probe, its kind and its failure text; unused ones are stale', () => {
  const list = loadExceptions(writeList([{ probe: 'paint.a', kind: 'page-content', match: '^page 1 differs', status: 'deliberate', reason: REASON }]));
  const content = 'page 1 differs. Content stream at token 3\n  bm: x';
  // the same failure in another probe, a text failure in the excepted probe, another content failure text
  const rows = [row('paint.a', [content, 'text per page: bm ["a"] vs takumi ["b"]']), row('paint.b', [content]), row('paint.c', ['page 2 differs. Content stream'])];
  const g = applyExceptions(rows, list);
  assert.deepEqual(g.expected.map((e) => e.id), ['paint.a']);
  assert.deepEqual(g.unexpected.map((e) => `${e.id} ${e.kind}`), ['paint.a text', 'paint.b page-content', 'paint.c page-content']);
  assert.equal(rows[0].status, 'FAIL');
  const fixed = applyExceptions([row('paint.a', [])], list);
  assert.equal(fixed.stale.length, 1, 'a fixed difference leaves a stale exception');
  assert.equal(applyExceptions([row('paint.z', [])], list).stale.length, 0, 'only probes that ran can make an exception stale');
  const only = [row('paint.a', [content])];
  applyExceptions(only, list);
  assert.equal(only[0].status, 'EXPECTED');
});

const oracle = fileURLToPath(new URL('../../bench/out/pdf-oracle/node.mjs', import.meta.url));
function runPinned(args, exceptions) {
  const env = { ...process.env, BM_RENDER_BACKEND: 'wasm', TAKUMI_PDF_REF_ENTRY: oracle };
  delete env.TAKUMI_PDF_REF;
  if (exceptions) env.PDF_AUDIT_EXCEPTIONS = exceptions; else delete env.PDF_AUDIT_EXCEPTIONS;
  return spawnSync(process.execPath, [runner, ...args], { env, encoding: 'utf8', windowsHide: true, timeout: 300_000 });
}
test('strict gate against the pinned oracle: a listed difference passes, the same difference unlisted or under another kind fails', { skip: !existsSync(oracle) && 'no pinned oracle at bench/out/pdf-oracle (scripts/build-takumi-pdf-oracle.mjs)' }, () => {
  const listed = runPinned(['--strict', '--quiet', 'paint.stacking.sticky']);
  assert.equal(listed.status, 0, listed.stdout + listed.stderr);
  assert.match(listed.stdout, /0 fail, 1 expected/);
  assert.match(listed.stdout, /provenance: bm \w+.* oracle source-build/);
  const unlisted = runPinned(['--strict', '--quiet', 'paint.stacking.sticky'], writeList([]));
  assert.equal(unlisted.status, 1, 'a difference no exception names is a new difference');
  assert.match(unlisted.stdout, /FAIL\s+paint\.stacking\.sticky/);
  const otherKind = runPinned(['--strict', '--quiet', 'paint.stacking.sticky'], writeList([{ probe: 'paint.stacking.sticky', kind: 'text', match: '^page 1 differs', status: 'deliberate', reason: REASON }]));
  assert.equal(otherKind.status, 1, 'an exception of another kind does not cover it (and is stale)');
  assert.match(otherKind.stdout, /STALE/);
  const passing = runPinned(['--strict', '--quiet', 'paint.stacking.fixed'], writeList([{ probe: 'paint.stacking.fixed', kind: 'page-content', match: '^page 1 differs', status: 'deliberate', reason: REASON }]));
  assert.equal(passing.status, 1, 'an exception for a probe that passes is stale and fails the gate');
});

const compareScript = fileURLToPath(new URL('../pdf-compare.mjs', import.meta.url));
function runCompare(args, exceptions) {
  const env = { ...process.env, BM_RENDER_BACKEND: 'wasm' };
  if (exceptions) env.PDF_AUDIT_EXCEPTIONS = exceptions; else delete env.PDF_AUDIT_EXCEPTIONS;
  return spawnSync(process.execPath, [compareScript, ...args], { env, encoding: 'utf8', windowsHide: true, timeout: 300_000 });
}
const goldenList = (golden) => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), 'pdf-gate-')), 'exceptions.json');
  writeFileSync(file, JSON.stringify({ exceptions: [], golden }));
  return file;
};
test('golden gate: a CLOSE fixture passes --strict only while exceptions.json lists it, and a listed identical fixture is stale', () => {
  const listed = runCompare(['--strict', 'paged-transforms']);
  assert.equal(listed.status, 0, listed.stdout + listed.stderr);
  assert.match(listed.stdout, /gate: 1 differences, 1 listed, 0 unlisted, 0 stale/);
  const unlisted = runCompare(['--strict', 'paged-transforms'], goldenList([]));
  assert.equal(unlisted.status, 1, 'an unlisted CLOSE is a new difference');
  assert.match(unlisted.stdout, /UNLISTED\s+paged-transforms content CLOSE/);
  const gone = runCompare(['--strict', 'box-chrome'], goldenList([{ fixture: 'box-chrome', part: 'content', verdict: 'CLOSE', status: 'noise', reason: REASON }]));
  assert.equal(gone.status, 1, 'a listed difference that is gone fails as stale');
  assert.match(gone.stdout, /STALE\s+box-chrome content CLOSE/);
});

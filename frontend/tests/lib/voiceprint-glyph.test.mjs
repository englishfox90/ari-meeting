import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';
import { fileURLToPath } from 'node:url';

// Load the pure geometry module by transpiling the TS source in a VM — the same
// pattern used by with-timeout.test.mjs. The module is dependency-free.
const modulePath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'src',
  'lib',
  'voiceprint-glyph.ts',
);
const source = fs.readFileSync(modulePath, 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText;
const moduleObj = { exports: {} };
vm.runInNewContext(compiled, { module: moduleObj, exports: moduleObj.exports, Math });
const { buildVoiceprintRing, voiceprintColors } = moduleObj.exports;

// Smallest circular distance between two hues in degrees (handles 0/360 wrap).
const hueDist = (a, b) => {
  const d = Math.abs(a - b) % 360;
  return d > 180 ? 360 - d : d;
};

const sig = (n, fn) => Array.from({ length: n }, (_, i) => fn(i));

test('returns null when there is nothing honest to draw', () => {
  assert.equal(buildVoiceprintRing([]), null);
  assert.equal(buildVoiceprintRing([0.5]), null);
  assert.equal(buildVoiceprintRing([0.2, 0.8]), null);
});

test('produces a closed cubic path with one point per value', () => {
  const values = sig(32, (i) => (Math.sin(i * 0.5) + 1) / 2);
  const ring = buildVoiceprintRing(values);
  assert.ok(ring);
  assert.equal(ring.points.length, 32);
  assert.match(ring.path, /^M /);
  assert.match(ring.path, / C /);
  assert.match(ring.path, / Z$/);
});

test('is deterministic — same signature yields the identical path', () => {
  const values = sig(32, (i) => (Math.cos(i * 0.37) + 1) / 2);
  assert.equal(buildVoiceprintRing(values).path, buildVoiceprintRing(values).path);
});

test('all points sit within the viewBox', () => {
  const values = sig(32, (i) => (i % 5) / 4);
  const ring = buildVoiceprintRing(values, { size: 100 });
  for (const { x, y } of ring.points) {
    assert.ok(x >= 0 && x <= 100, `x=${x} in range`);
    assert.ok(y >= 0 && y <= 100, `y=${y} in range`);
  }
});

test('clamps out-of-range values instead of overflowing', () => {
  const clamped = buildVoiceprintRing(sig(16, () => 5)); // all > 1
  const atMax = buildVoiceprintRing(sig(16, () => 1));
  assert.equal(clamped.path, atMax.path);
  const clampedLow = buildVoiceprintRing(sig(16, () => -3)); // all < 0
  const atMin = buildVoiceprintRing(sig(16, () => 0));
  assert.equal(clampedLow.path, atMin.path);
});

test('similar voiceprints produce similar rings (small change → small move)', () => {
  const base = sig(32, (i) => (Math.sin(i * 0.4) + 1) / 2);
  const near = base.map((v, i) => (i === 3 ? v + 0.02 : v));
  const far = base.map((v) => 1 - v); // an opposite signature

  const dist = (a, b) => {
    const pa = buildVoiceprintRing(a).points;
    const pb = buildVoiceprintRing(b).points;
    let sum = 0;
    for (let i = 0; i < pa.length; i += 1) {
      sum += Math.hypot(pa[i].x - pb[i].x, pa[i].y - pb[i].y);
    }
    return sum;
  };

  assert.ok(dist(base, near) < dist(base, far), 'a near signature is geometrically closer than an opposite one');
});

test('voiceprintColors returns null when there is nothing honest to color', () => {
  assert.equal(voiceprintColors([]), null);
  assert.equal(voiceprintColors([0.5]), null);
  assert.equal(voiceprintColors([0.2, 0.8]), null);
});

test('voiceprintColors is deterministic for the same signature', () => {
  const values = sig(32, (i) => (Math.sin(i * 0.5) + 1) / 2);
  assert.deepEqual(voiceprintColors(values, { theme: 'dark' }), voiceprintColors(values, { theme: 'dark' }));
});

test('voiceprintColors stays in the calm data band and is range-valid', () => {
  for (const seed of [0.13, 0.4, 0.77, 1.9]) {
    const values = sig(32, (i) => (Math.sin(i * seed) + 1) / 2);
    for (const theme of ['light', 'dark']) {
      const c = voiceprintColors(values, { theme });
      assert.ok(c.hueFrom >= 0 && c.hueFrom < 360, `hueFrom ${c.hueFrom} in [0,360)`);
      assert.ok(c.hueTo >= 0 && c.hueTo < 360, `hueTo ${c.hueTo} in [0,360)`);
      assert.ok(c.saturation >= 45 && c.saturation <= 65, `saturation ${c.saturation} in calm band`);
      assert.match(c.from, /^hsl\(\d+ \d+% \d+%\)$/);
      assert.match(c.to, /^hsl\(\d+ \d+% \d+%\)$/);
    }
  }
});

test('voiceprintColors picks per-theme lightness (lighter on dark, deeper on cream)', () => {
  const values = sig(32, (i) => (Math.cos(i * 0.31) + 1) / 2);
  const dark = voiceprintColors(values, { theme: 'dark' });
  const light = voiceprintColors(values, { theme: 'light' });
  assert.ok(dark.lightness > light.lightness, 'dark canvas gets a lighter tint');
  // Hue is a property of the voice, not the theme — it must not shift.
  assert.equal(dark.hueFrom, light.hueFrom);
});

test('similar voiceprints produce nearby hues; opposite ones diverge', () => {
  const base = sig(32, (i) => (Math.sin(i * 0.4) + 1) / 2);
  const near = base.map((v, i) => (i === 5 ? v + 0.02 : v));
  const far = base.map((v) => 1 - v);

  const h = (a) => voiceprintColors(a, { theme: 'dark' }).hueFrom;
  assert.ok(hueDist(h(base), h(near)) < hueDist(h(base), h(far)), 'a near signature is closer in hue than an opposite one');
});

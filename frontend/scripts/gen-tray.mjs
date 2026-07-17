// Generates the 44x44 menu-bar tray template (raw RGBA: black pixels + alpha
// mask; macOS auto-tints per menu-bar appearance). The mark is Marginalia's
// "signature flick" (brand/assets/mark-16.svg) — the terminal waveform of the
// Dictation gesture, the owned menu-bar / recording-state glyph.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const N = 44, SS = 4, PAD = 5;         // fit the glyph within N - 2*PAD
// Flick path in the mark-16.svg 64x64 viewBox: one stroke, chained cubics.
const SW = 9;
const SEGS = [
  [[8, 44], [13, 46], [16, 38], [19, 30]],
  [[19, 30], [21, 25], [24, 24], [26, 27]],
  [[26, 27], [29, 31], [28, 42], [33, 42]],
  [[33, 42], [38, 42], [38, 22], [44, 21]],
  [[44, 21], [49, 20.5], [50, 32], [56, 35]],
];
const SAMPLES = 24;

function cubic(a, b, c, d, t) {
  const u = 1 - t, uu = u * u, tt = t * t;
  const w0 = uu * u, w1 = 3 * uu * t, w2 = 3 * u * tt, w3 = tt * t;
  return [a[0] * w0 + b[0] * w1 + c[0] * w2 + d[0] * w3, a[1] * w0 + b[1] * w1 + c[1] * w2 + d[1] * w3];
}

// Flatten to viewBox-space points, then fit the bbox into the padded canvas.
const raw = [];
for (const [p0, c1, c2, p3] of SEGS) {
  for (let i = raw.length ? 1 : 0; i <= SAMPLES; i++) raw.push(cubic(p0, c1, c2, p3, i / SAMPLES));
}
let minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
for (const [x, y] of raw) { minx = Math.min(minx, x); miny = Math.min(miny, y); maxx = Math.max(maxx, x); maxy = Math.max(maxy, y); }
const scale = (N - 2 * PAD) / Math.max(maxx - minx, maxy - miny);
const ox = (N - (maxx - minx) * scale) / 2 - minx * scale;
const oy = (N - (maxy - miny) * scale) / 2 - miny * scale;
const pts = raw.map(([x, y]) => [x * scale + ox, y * scale + oy]);
const hw = (SW * scale) / 2;

function distSeg(px, py, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1], len2 = dx * dx + dy * dy;
  let t = len2 ? ((px - a[0]) * dx + (py - a[1]) * dy) / len2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  return Math.hypot(a[0] + t * dx - px, a[1] + t * dy - py);
}

const buf = Buffer.alloc(N * N * 4);
for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
  let hits = 0;
  for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
    const px = x + (sx + 0.5) / SS, py = y + (sy + 0.5) / SS;
    for (let k = 1; k < pts.length; k++) {
      if (distSeg(px, py, pts[k - 1], pts[k]) <= hw) { hits++; break; }
    }
  }
  const i = (y * N + x) * 4;
  buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0;
  buf[i + 3] = Math.round(255 * hits / (SS * SS));
}

const out = path.join(fileURLToPath(new URL('..', import.meta.url)), 'src-tauri/icons/tray-icon-template.rgba');
writeFileSync(out, buf);
let zero = 0, nonzero = 0;
for (let i = 3; i < buf.length; i += 4) buf[i] === 0 ? zero++ : nonzero++;
console.log(`wrote ${buf.length} bytes (expect ${N * N * 4}); alpha zero=${zero} nonzero=${nonzero}`);

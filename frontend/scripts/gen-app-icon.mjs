// Generates the Ari Meeting app icon as transparent-corner RGBA PNGs, drawn
// procedurally (no SVG rasterizer available on this toolchain, and qlmanage
// flattens transparency onto white). The mark matches src/components/app-shell/
// ArivoMark.tsx: an amber crescent ring (opening upper-right, bright amber lower-
// left fading deep into the opening) on the #0B1522 deep-navy rail.
import { writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ICONS = path.join(fileURLToPath(new URL('..', import.meta.url)), 'src-tauri/icons');
const PUBLIC = path.join(fileURLToPath(new URL('..', import.meta.url)), 'public');

// ---- geometry (fractions of canvas), matched to ArivoMark proportions ----
const CORNER = 0.2246;   // 230/1024 rounded-rect radius
const R = 0.30;          // ring centerline radius
const SW = 0.058;        // ring stroke width (ArivoMark sw/r = 0.192)
// ArivoMark uses stroke-dasharray "66 20" on a circumference of ~78.54, starting
// at 3 o'clock going clockwise -> drawn arc ~302.5deg, gap ~57.5deg at upper-right.
const ARC_START = 0;                       // radians, 3 o'clock
const ARC_LEN = (66 / (2 * Math.PI * 12.5)) * 2 * Math.PI; // drawn arc length in radians
const NAVY = [11, 21, 34];                 // #0B1522
const STOPS = [                            // amber gradient, lower-left -> upper-right
  [0.0, [232, 160, 32]],   // #E8A020
  [0.55, [180, 116, 26]],  // #B4741A
  [1.0, [90, 58, 18]],     // #5A3A12
];

const lerp = (a, b, t) => a + (b - a) * t;
function gradient(t) {
  t = Math.max(0, Math.min(1, t));
  for (let i = 1; i < STOPS.length; i++) {
    if (t <= STOPS[i][0]) {
      const [t0, c0] = STOPS[i - 1], [t1, c1] = STOPS[i];
      const f = (t - t0) / (t1 - t0);
      return [0, 1, 2].map((k) => Math.round(lerp(c0[k], c1[k], f)));
    }
  }
  return STOPS[STOPS.length - 1][1];
}

// coverage of a rounded rect at point (px,py) for a size-N canvas, inset 0
function inRoundRect(px, py, N, cr) {
  const x = Math.min(px, N - px), y = Math.min(py, N - py);
  if (x >= cr && y >= cr) return true;         // straight edges
  if (x >= cr || y >= cr) return px >= 0 && py >= 0 && px <= N && py <= N;
  const dx = cr - x, dy = cr - y;              // corner quarter-circle
  return dx * dx + dy * dy <= cr * cr;
}

function renderRGBA(N) {
  const SS = 4;                                 // supersample
  const cx = N / 2, cy = N / 2;
  const cr = CORNER * N, r = R * N, hw = (SW * N) / 2;
  const gA = [0.20 * N, 0.80 * N];              // gradient axis: lower-left
  const gB = [0.80 * N, 0.20 * N];              // -> upper-right
  const gdx = gB[0] - gA[0], gdy = gB[1] - gA[1];
  const gLen2 = gdx * gdx + gdy * gdy;
  const endA = [cx + r * Math.cos(ARC_START), cy + r * Math.sin(ARC_START)];
  const endB = [cx + r * Math.cos(ARC_START + ARC_LEN), cy + r * Math.sin(ARC_START + ARC_LEN)];
  const buf = Buffer.alloc(N * N * 4);
  for (let y = 0; y < N; y++) {
    for (let x = 0; x < N; x++) {
      let bgHits = 0, ringHits = 0, gtSum = 0;
      for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
        const fx = x + (sx + 0.5) / SS, fy = y + (sy + 0.5) / SS;
        if (inRoundRect(fx, fy, N, cr)) bgHits++;
        // ring: within stroke band AND (within drawn arc OR within a round cap)
        const dx = fx - cx, dy = fy - cy, dist = Math.hypot(dx, dy);
        if (Math.abs(dist - r) <= hw) {
          let ang = Math.atan2(dy, dx); if (ang < 0) ang += 2 * Math.PI;
          let rel = ang - ARC_START; if (rel < 0) rel += 2 * Math.PI;
          let on = rel <= ARC_LEN;
          if (!on) {
            on = Math.hypot(fx - endA[0], fy - endA[1]) <= hw ||
                 Math.hypot(fx - endB[0], fy - endB[1]) <= hw;
          }
          if (on) {
            ringHits++;
            const t = ((fx - gA[0]) * gdx + (fy - gA[1]) * gdy) / gLen2;
            gtSum += t;
          }
        }
      }
      const tot = SS * SS, i = (y * N + x) * 4;
      const bgA = bgHits / tot, ringA = ringHits / tot;
      // composite ring over navy over transparent
      const navy = NAVY;
      const gc = ringHits ? gradient(gtSum / ringHits) : [0, 0, 0];
      // base = navy with alpha bgA
      let r0 = navy[0], g0 = navy[1], b0 = navy[2], a0 = bgA;
      // over: ring color with alpha ringA (ring only where bg present, so clamp)
      const ra = ringA;
      const outA = ra + a0 * (1 - ra);
      const mix = (cc, bb) => outA === 0 ? 0 : Math.round((cc * ra + bb * a0 * (1 - ra)) / outA);
      buf[i] = mix(gc[0], r0);
      buf[i + 1] = mix(gc[1], g0);
      buf[i + 2] = mix(gc[2], b0);
      buf[i + 3] = Math.round(outA * 255);
    }
  }
  return buf;
}

// ---- minimal PNG encoder (8-bit RGBA) ----
const CRC = (() => { const t = []; for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(buf) { let c = 0xffffffff; for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(type, data) { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type, 'ascii'), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td)); return Buffer.concat([len, td, crc]); }
function encodePNG(rgba, N) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(N, 0); ihdr.writeUInt32BE(N, 4); ihdr[8] = 8; ihdr[9] = 6;
  const stride = N * 4, rawImg = Buffer.alloc((stride + 1) * N);
  for (let y = 0; y < N; y++) { rawImg[y * (stride + 1)] = 0; rgba.copy(rawImg, y * (stride + 1) + 1, y * stride, y * stride + stride); }
  const idat = deflateSync(rawImg, { level: 9 });
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

const cache = new Map();
function png(N) { if (!cache.has(N)) cache.set(N, encodePNG(renderRGBA(N), N)); return cache.get(N); }
const write = (dir, name, N) => writeFileSync(path.join(dir, name), png(N));

// full desktop-packaging raster set
write(ICONS, 'icon.png', 512);
for (const [name, N] of [
  ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
  ['32x32.png', 32], ['64x64.png', 64], ['128x128.png', 128], ['128x128@2x.png', 256],
  ['StoreLogo.png', 50],
  ['Square30x30Logo.png', 30], ['Square44x44Logo.png', 44], ['Square71x71Logo.png', 71],
  ['Square89x89Logo.png', 89], ['Square107x107Logo.png', 107], ['Square142x142Logo.png', 142],
  ['Square150x150Logo.png', 150], ['Square284x284Logo.png', 284], ['Square310x310Logo.png', 310],
]) write(ICONS, name, N);
write(PUBLIC, 'icon_128x128.png', 128);
write(PUBLIC, 'icon_32x32@2x.png', 64);
console.log('app icon raster set generated (transparent corners).');

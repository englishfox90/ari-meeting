// Generates the Ari macOS app icon (Marginalia "Dictation" R2 mark) into
// Ari/App/Assets.xcassets/AppIcon.appiconset as transparent-corner RGBA PNGs.
//
// The art + rendering is ported from frontend/scripts/gen-app-icon.mjs (the frozen
// Tauri app's icon generator) — same drawing, so dock/menu-bar/wordmark all read as
// one mark. Pure Node (no SVG rasterizer on this toolchain): a 1024 master is
// rendered once from the app-icon.svg bezier paths, then area-downscaled to every
// macOS slot. Iron Gall ink (#152C66) on a porcelain field (#FAF8F5), standard
// macOS squircle with the usual transparent grid padding.
//
// Run: node Ari/scripts/gen-appicon.mjs
import { writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const OUT = path.join(
  fileURLToPath(new URL('..', import.meta.url)),
  'App/Assets.xcassets/AppIcon.appiconset'
);

const CORNER = 0.2237; // 22.37% macOS squircle corner radius (of the field)
const MARGIN = 100 / 1024; // Apple macOS icon grid padding (squircle = 824 in 1024)
const FIELD = [250, 248, 245]; // #FAF8F5 porcelain
const INK = [21, 44, 102]; // #152C66 Iron Gall

// R2 "Dictation" app-icon cut, in the app-icon.svg 96x64 viewBox: chains of cubic
// beziers [p0,c1,c2,p3] with a constant stroke width (heavier icon-weight cut).
const MARK = [
  { sw: 10.5, segs: [[[46, 26], [37, 18], [23, 23], [21, 34]], [[21, 34], [19, 46], [31, 54], [41, 48]]] },
  { sw: 5.5, segs: [[[46, 26], [43.5, 23], [40, 21.4], [36.5, 21.6]]] },
  { sw: 10.5, segs: [[[47, 20], [45.3, 30], [45.3, 40], [48, 47]]] },
  { sw: 8, segs: [[[48, 47], [50.5, 51.5], [55, 49.5], [57, 43]], [[57, 43], [58.6, 38], [60, 34.5], [62.5, 34.5]]] },
  { sw: 6, segs: [[[62.5, 34.5], [66, 34.5], [65.5, 45], [69.5, 45]], [[69.5, 45], [73.5, 45], [73.5, 29.5], [78, 29]]] },
  { sw: 4.2, segs: [[[78, 29], [81.5, 28.7], [82, 38], [86, 40]], [[86, 40], [88.3, 41], [90.5, 40], [92.5, 37.5]]] },
];
const T = { tx: 78, ty: 238, s: 7.6 }; // master compositing transform in the 1024 field
const SAMPLES = 22;

function cubic(a, b, c, d, t) {
  const u = 1 - t, uu = u * u, tt = t * t;
  const w0 = uu * u, w1 = 3 * uu * t, w2 = 3 * u * tt, w3 = tt * t;
  return [a[0] * w0 + b[0] * w1 + c[0] * w2 + d[0] * w3, a[1] * w0 + b[1] * w1 + c[1] * w2 + d[1] * w3];
}

function buildSegments(N) {
  const m = MARGIN * N, k = (N - 2 * m) / 1024;
  const map = (p) => [m + k * (T.tx + p[0] * T.s), m + k * (T.ty + p[1] * T.s)];
  const out = [];
  let gminx = Infinity, gminy = Infinity, gmaxx = -Infinity, gmaxy = -Infinity;
  for (const { sw, segs } of MARK) {
    const hw = Math.max((sw * T.s * k) / 2, N < 64 ? 0.9 : 0);
    for (const seg of segs) {
      const [p0, c1, c2, p3] = seg;
      let prev = map(p0);
      for (let i = 1; i <= SAMPLES; i++) {
        const cur = map(cubic(p0, c1, c2, p3, i / SAMPLES));
        const minx = Math.min(prev[0], cur[0]) - hw, maxx = Math.max(prev[0], cur[0]) + hw;
        const miny = Math.min(prev[1], cur[1]) - hw, maxy = Math.max(prev[1], cur[1]) + hw;
        out.push({ ax: prev[0], ay: prev[1], bx: cur[0], by: cur[1], hw, minx, miny, maxx, maxy });
        if (minx < gminx) gminx = minx; if (miny < gminy) gminy = miny;
        if (maxx > gmaxx) gmaxx = maxx; if (maxy > gmaxy) gmaxy = maxy;
        prev = cur;
      }
    }
  }
  return { segs: out, box: [gminx, gminy, gmaxx, gmaxy] };
}

function distSeg(px, py, s) {
  const dx = s.bx - s.ax, dy = s.by - s.ay, len2 = dx * dx + dy * dy;
  let t = len2 ? ((px - s.ax) * dx + (py - s.ay) * dy) / len2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const qx = s.ax + t * dx - px, qy = s.ay + t * dy - py;
  return Math.hypot(qx, qy);
}

function inField(px, py, m, F, cr) {
  const lx = px - m, ly = py - m;
  if (lx < 0 || ly < 0 || lx > F || ly > F) return false;
  const x = Math.min(lx, F - lx), y = Math.min(ly, F - ly);
  if (x >= cr || y >= cr) return true;
  const dx = cr - x, dy = cr - y;
  return dx * dx + dy * dy <= cr * cr;
}

function renderRGBA(N) {
  const SS = 4, m = MARGIN * N, F = N - 2 * m, cr = CORNER * F;
  const { segs, box } = buildSegments(N);
  const buf = Buffer.alloc(N * N * 4);
  for (let y = 0; y < N; y++) {
    for (let x = 0; x < N; x++) {
      const near = x + 1 >= box[0] && x <= box[2] && y + 1 >= box[1] && y <= box[3];
      let fieldHits = 0, inkHits = 0;
      for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
        const fx = x + (sx + 0.5) / SS, fy = y + (sy + 0.5) / SS;
        if (inField(fx, fy, m, F, cr)) fieldHits++;
        if (near) {
          for (let k = 0; k < segs.length; k++) {
            const s = segs[k];
            if (fx < s.minx || fx > s.maxx || fy < s.miny || fy > s.maxy) continue;
            if (distSeg(fx, fy, s) <= s.hw) { inkHits++; break; }
          }
        }
      }
      const tot = SS * SS, i = (y * N + x) * 4;
      const fieldA = fieldHits / tot, inkA = inkHits / tot;
      const outA = inkA + fieldA * (1 - inkA);
      const mix = (ci, cf) => (outA === 0 ? 0 : Math.round((ci * inkA + cf * fieldA * (1 - inkA)) / outA));
      buf[i] = mix(INK[0], FIELD[0]);
      buf[i + 1] = mix(INK[1], FIELD[1]);
      buf[i + 2] = mix(INK[2], FIELD[2]);
      buf[i + 3] = Math.round(outA * 255);
    }
  }
  return buf;
}

function downscale(src, S, N) {
  const pm = Buffer.alloc(S * S * 4);
  for (let i = 0; i < S * S; i++) {
    const a = src[i * 4 + 3] / 255;
    pm[i * 4] = src[i * 4] * a; pm[i * 4 + 1] = src[i * 4 + 1] * a;
    pm[i * 4 + 2] = src[i * 4 + 2] * a; pm[i * 4 + 3] = src[i * 4 + 3];
  }
  const out = Buffer.alloc(N * N * 4), r = S / N;
  for (let ty = 0; ty < N; ty++) for (let tx = 0; tx < N; tx++) {
    const y0 = ty * r, y1 = (ty + 1) * r, x0 = tx * r, x1 = (tx + 1) * r;
    let R = 0, G = 0, B = 0, A = 0, W = 0;
    for (let sy = Math.floor(y0); sy < Math.ceil(y1); sy++) {
      const wy = Math.min(y1, sy + 1) - Math.max(y0, sy);
      for (let sx = Math.floor(x0); sx < Math.ceil(x1); sx++) {
        const wx = Math.min(x1, sx + 1) - Math.max(x0, sx), w = wx * wy;
        const j = (sy * S + sx) * 4;
        R += pm[j] * w; G += pm[j + 1] * w; B += pm[j + 2] * w; A += pm[j + 3] * w; W += w;
      }
    }
    const o = (ty * N + tx) * 4, a = W ? A / W : 0, af = a / 255;
    out[o] = af ? Math.round(R / W / af) : 0;
    out[o + 1] = af ? Math.round(G / W / af) : 0;
    out[o + 2] = af ? Math.round(B / W / af) : 0;
    out[o + 3] = Math.round(a);
  }
  return out;
}

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

const S = 1024;
const master = renderRGBA(S);
const pngCache = new Map();
const png = (N) => {
  if (!pngCache.has(N)) pngCache.set(N, encodePNG(N === S ? master : downscale(master, S, N), N));
  return pngCache.get(N);
};

// macOS asset-catalog slots: [size, scale] → pixel size.
const SLOTS = [
  [16, 1], [16, 2], [32, 1], [32, 2],
  [128, 1], [128, 2], [256, 1], [256, 2], [512, 1], [512, 2],
];
const images = SLOTS.map(([size, scale]) => {
  const px = size * scale;
  const filename = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
  writeFileSync(path.join(OUT, filename), png(px));
  return { size: `${size}x${size}`, idiom: 'mac', filename, scale: `${scale}x` };
});

writeFileSync(
  path.join(OUT, 'Contents.json'),
  `${JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2)}\n`
);

console.log(`Wrote ${images.length} PNGs + Contents.json to ${OUT}`);

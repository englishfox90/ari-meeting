// Generates the Ari Meeting app icon (Marginalia) as transparent-corner RGBA
// PNGs plus the packaged .icns / .ico. Drawn procedurally — no SVG rasterizer
// on this toolchain, and qlmanage flattens transparency onto white. The art is
// the R2 "Dictation" mark (src-tauri/icons/ari-icon.svg / brand/assets/
// app-icon.svg): a cursive "a" whose tail runs out as a hand-drawn waveform,
// in Iron Gall ink (#152C66) on a porcelain paper field (#FAF8F5), standard
// macOS squircle. The 1024 master is rendered once, then area-downscaled
// deterministically to every size (so the byte output is stable / SHA-pinnable).
//
// NOTE: below ~32px Marginalia calls for a simplified heavier cut; the outgoing
// (frozen) Tauri app ships the full gesture at every size with a stroke floor
// so it stays legible. Faithful small-cut handling is a Swift-era concern.
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import path from 'node:path';

const ICONS = path.join(fileURLToPath(new URL('..', import.meta.url)), 'src-tauri/icons');
const PUBLIC = path.join(fileURLToPath(new URL('..', import.meta.url)), 'public');
const FAVICON = path.join(fileURLToPath(new URL('..', import.meta.url)), 'src/app/favicon.ico');

const CORNER = 0.2237;                 // 22.37% macOS squircle corner radius (of the field)
const MARGIN = 100 / 1024;             // Apple macOS icon grid: transparent padding so the
                                       // squircle is 824px in a 1024 canvas (matches other apps)
const FIELD = [250, 248, 245];         // #FAF8F5 porcelain
const INK = [21, 44, 102];             // #152C66 Iron Gall

// R2 "Dictation" mark paths in the app-icon.svg 96x64 viewBox: each path is a
// chain of cubic beziers [p0,c1,c2,p3] with a constant stroke width.
const MARK = [
  { sw: 10.5, segs: [[[46, 26], [37, 18], [23, 23], [21, 34]], [[21, 34], [19, 46], [31, 54], [41, 48]]] },
  { sw: 5.5, segs: [[[46, 26], [43.5, 23], [40, 21.4], [36.5, 21.6]]] },
  { sw: 10.5, segs: [[[47, 20], [45.3, 30], [45.3, 40], [48, 47]]] },
  { sw: 8, segs: [[[48, 47], [50.5, 51.5], [55, 49.5], [57, 43]], [[57, 43], [58.6, 38], [60, 34.5], [62.5, 34.5]]] },
  { sw: 6, segs: [[[62.5, 34.5], [66, 34.5], [65.5, 45], [69.5, 45]], [[69.5, 45], [73.5, 45], [73.5, 29.5], [78, 29]]] },
  { sw: 4.2, segs: [[[78, 29], [81.5, 28.7], [82, 38], [86, 40]], [[86, 40], [88.3, 41], [90.5, 40], [92.5, 37.5]]] },
];
// Master compositing transform (in the 1024 field): translate(78 238) scale(7.6).
const T = { tx: 78, ty: 238, s: 7.6 };
const SAMPLES = 22;                    // flatten samples per bezier segment

function cubic(a, b, c, d, t) {
  const u = 1 - t, uu = u * u, tt = t * t;
  const w0 = uu * u, w1 = 3 * uu * t, w2 = 3 * u * tt, w3 = tt * t;
  return [a[0] * w0 + b[0] * w1 + c[0] * w2 + d[0] * w3, a[1] * w0 + b[1] * w1 + c[1] * w2 + d[1] * w3];
}

// Flatten the mark into line segments in field space, each with its half width
// and a padded bounding box, for a given canvas size N (scaled from the 1024 master).
function buildSegments(N) {
  const m = MARGIN * N, k = (N - 2 * m) / 1024; // inset field origin + field-space scale
  const map = (p) => [m + k * (T.tx + p[0] * T.s), m + k * (T.ty + p[1] * T.s)];
  const out = [];
  let gminx = Infinity, gminy = Infinity, gmaxx = -Infinity, gmaxy = -Infinity;
  for (const { sw, segs } of MARK) {
    const hw = Math.max((sw * T.s * k) / 2, N < 64 ? 0.9 : 0); // legibility floor at tiny sizes
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
  const dx = s.bx - s.ax, dy = s.by - s.ay;
  const len2 = dx * dx + dy * dy;
  let t = len2 ? ((px - s.ax) * dx + (py - s.ay) * dy) / len2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const qx = s.ax + t * dx - px, qy = s.ay + t * dy - py;
  return Math.hypot(qx, qy);
}

// Coverage of the inset squircle field: rect [m, N-m]^2 with corner radius cr.
// Points in the transparent padding (outside [m, N-m]) are not filled.
function inField(px, py, m, F, cr) {
  const lx = px - m, ly = py - m;
  if (lx < 0 || ly < 0 || lx > F || ly > F) return false;
  const x = Math.min(lx, F - lx), y = Math.min(ly, F - ly);
  if (x >= cr || y >= cr) return true;         // straight edges
  const dx = cr - x, dy = cr - y;              // corner quarter-circle
  return dx * dx + dy * dy <= cr * cr;
}

// Render the master at size N (RGBA, straight alpha).
function renderRGBA(N) {
  const SS = 4, m = MARGIN * N, F = N - 2 * m, cr = CORNER * F;
  const { segs, box } = buildSegments(N);
  const buf = Buffer.alloc(N * N * 4);
  for (let y = 0; y < N; y++) {
    for (let x = 0; x < N; x++) {
      // fast reject: pixel wholly outside the mark bbox skips all ink work
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

// Deterministic area-averaging downscale (premultiplied alpha) from the S x S
// master to N x N — avoids re-running the vector render (and dark edge fringes).
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

// ---- ICO container (embedded PNG entries; valid for modern Windows) ----
function encodeICO(entries) { // entries: [{size, png}]
  const dir = Buffer.alloc(6 + entries.length * 16);
  dir.writeUInt16LE(0, 0); dir.writeUInt16LE(1, 2); dir.writeUInt16LE(entries.length, 4);
  let offset = dir.length;
  entries.forEach((e, i) => {
    const o = 6 + i * 16;
    dir[o] = e.size >= 256 ? 0 : e.size; dir[o + 1] = e.size >= 256 ? 0 : e.size;
    dir[o + 2] = 0; dir[o + 3] = 0;
    dir.writeUInt16LE(1, o + 4); dir.writeUInt16LE(32, o + 6);
    dir.writeUInt32LE(e.png.length, o + 8); dir.writeUInt32LE(offset, o + 12);
    offset += e.png.length;
  });
  return Buffer.concat([dir, ...entries.map((e) => e.png)]);
}

// ---- render master once, derive everything ----
const S = 1024;
const master = renderRGBA(S);
const rgbaCache = new Map([[S, master]]);
const rgba = (N) => { if (!rgbaCache.has(N)) rgbaCache.set(N, downscale(master, S, N)); return rgbaCache.get(N); };
const pngCache = new Map();
const png = (N) => { if (!pngCache.has(N)) pngCache.set(N, encodePNG(rgba(N), N)); return pngCache.get(N); };
const write = (dir, name, N) => writeFileSync(path.join(dir, name), png(N));

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

// .icns via iconutil (build a standard .iconset, then convert)
const setDir = mkdtempSync(path.join(tmpdir(), 'ari-iconset-'));
const iconset = path.join(setDir, 'ari.iconset');
execFileSync('mkdir', ['-p', iconset]);
for (const [name, N] of [
  ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
]) writeFileSync(path.join(iconset, name), png(N));
execFileSync('iconutil', ['-c', 'icns', iconset, '-o', path.join(ICONS, 'app_icon.icns')]);
execFileSync('cp', [path.join(ICONS, 'app_icon.icns'), path.join(ICONS, 'icon.icns')]);
rmSync(setDir, { recursive: true, force: true });

// .ico (Windows packaging) + browser favicon
const ico = encodeICO([{ size: 16, png: png(16) }, { size: 32, png: png(32) }, { size: 48, png: png(48) }, { size: 256, png: png(256) }]);
writeFileSync(path.join(ICONS, 'app_icon.ico'), ico);
writeFileSync(path.join(ICONS, 'icon.ico'), ico);
writeFileSync(FAVICON, encodeICO([{ size: 16, png: png(16) }, { size: 32, png: png(32) }, { size: 48, png: png(48) }]));

console.log('Marginalia app icon set generated: PNGs + app_icon.icns + .ico + favicon.');

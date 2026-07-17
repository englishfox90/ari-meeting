// Generates the 44x44 menu-bar tray template (raw RGBA: black pixels + alpha mask,
// macOS auto-tints per menu-bar appearance). Draws the Arivo crescent ring with the
// same opening-upper-right orientation as ArivoMark.tsx / the app icon.
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const N = 44, SS = 4;
const cx = 21.5, cy = 21.5;
const r = 13.0;                 // ring radius (proportional to the app icon)
const hw = 1.6;                 // half stroke width
const ARC_START = 0;            // 3 o'clock
const ARC_LEN = 66 / 12.5;      // ArivoMark drawn arc (~302.5deg); gap at upper-right
const endA = [cx + r * Math.cos(ARC_START), cy + r * Math.sin(ARC_START)];
const endB = [cx + r * Math.cos(ARC_START + ARC_LEN), cy + r * Math.sin(ARC_START + ARC_LEN)];

const buf = Buffer.alloc(N * N * 4);
for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
  let hits = 0;
  for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
    const px = x + (sx + 0.5) / SS, py = y + (sy + 0.5) / SS;
    const dx = px - cx, dy = py - cy, dist = Math.hypot(dx, dy);
    if (Math.abs(dist - r) <= hw) {
      let ang = Math.atan2(dy, dx); if (ang < 0) ang += 2 * Math.PI;
      let rel = ang - ARC_START; if (rel < 0) rel += 2 * Math.PI;
      if (rel <= ARC_LEN) hits++;
      else if (Math.hypot(px - endA[0], py - endA[1]) <= hw ||
               Math.hypot(px - endB[0], py - endB[1]) <= hw) hits++;
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

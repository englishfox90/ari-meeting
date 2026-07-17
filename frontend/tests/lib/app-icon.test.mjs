import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import test from 'node:test';

const frontend = new URL('../../', import.meta.url);
const root = new URL('../', frontend);
const icons = new URL('src-tauri/icons/', frontend);

const pngSize = (file) => [file.readUInt32BE(16), file.readUInt32BE(20)];
const digest = (file) => createHash('sha256').update(file).digest('hex');

test('Arivo Amber icon assets match the configured desktop packaging contract', async () => {
  const requiredPngs = [
    ['icon.png', 512],
    ['icon_16x16.png', 16],
    ['icon_16x16@2x.png', 32],
    ['icon_32x32.png', 32],
    ['icon_32x32@2x.png', 64],
    ['icon_128x128.png', 128],
    ['icon_128x128@2x.png', 256],
    ['icon_256x256.png', 256],
    ['icon_256x256@2x.png', 512],
    ['icon_512x512.png', 512],
  ];
  const [config, infoPlist, svg, ...files] = await Promise.all([
    readFile(new URL('src-tauri/tauri.conf.json', frontend), 'utf8'),
    readFile(new URL('src-tauri/Info.plist', frontend), 'utf8'),
    readFile(new URL('ari-icon.svg', icons), 'utf8'),
    ...requiredPngs.map(([name]) => readFile(new URL(name, icons))),
  ]);

  // macOS/Windows bundling uses the standard rendered .icns / .ico / .png set
  // (the macOS 26 adaptive Icon Composer path was dropped: its SVG rasterizer
  // filled the crescent into a disc and wrapped it in a stray light bezel).
  assert.match(config, /"icons\/icon\.png"/);
  assert.match(config, /"icons\/app_icon\.icns"/);
  assert.match(config, /"icons\/app_icon\.ico"/);
  // No dangling asset-catalog reference — the icon resolves from the .icns.
  assert.doesNotMatch(infoPlist, /CFBundleIconName/);

  // Master art: the Arivo amber crescent-ring mark on the #0B1522 navy rail.
  assert.match(svg, /#E8A020/);
  assert.match(svg, /#0B1522/);
  assert.match(svg, /linearGradient/);
  assert.doesNotMatch(svg, /#E92C78/i);
  assert.equal(digest(Buffer.from(svg)), '0f6e9192e5b375132d3fc7f6a5ba5881ec92dda4c6665d25438b5d7fd4a9093e');

  for (const [index, [, size]] of requiredPngs.entries()) {
    assert.deepEqual(pngSize(files[index]), [size, size]);
  }

  const [icns, ico, publicIcon, sourceIcon] = await Promise.all([
    stat(new URL('app_icon.icns', icons)),
    stat(new URL('app_icon.ico', icons)),
    readFile(new URL('frontend/public/icon_128x128.png', root)),
    readFile(new URL('icon_128x128.png', icons)),
  ]);
  assert.ok(icns.size > 0);
  assert.ok(ico.size > 0);
  assert.equal(digest(await readFile(new URL('icon.png', icons))), '7ba987d66991d6c0540df651b50a6ee0e836bca3ff9f502f4b36bae4e9cf0fc6');
  assert.equal(digest(await readFile(new URL('app_icon.icns', icons))), '1e9fd0193e74062cdfa3575913a13f196516bc657835327ec3d4da8cf1552d4e');
  assert.equal(digest(publicIcon), digest(sourceIcon));
});

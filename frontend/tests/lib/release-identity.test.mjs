import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Release/distribution transport is being migrated off GitHub (GitLab TBD), so this
// suite checks only transport-agnostic release identity: version consistency across
// the manifests and the stable macOS product name + bundle identifier. Re-add
// endpoint/asset assertions once the GitLab release + updater pipeline is defined.
const root = (file) => fileURLToPath(new URL(file, import.meta.url));
const [tauriConfig, cargoManifest, frontendPackage] = await Promise.all([
  readFile(root('../../src-tauri/tauri.conf.json'), 'utf8'),
  readFile(root('../../src-tauri/Cargo.toml'), 'utf8'),
  readFile(root('../../package.json'), 'utf8'),
]);
const frontendSources = await Promise.all([
  readFile(root('../../src/lib/app-version.ts'), 'utf8'),
  readFile(root('../../src/components/Sidebar/index.tsx'), 'utf8'),
  readFile(root('../../src/components/About.tsx'), 'utf8'),
]);

for (const source of [tauriConfig, cargoManifest, frontendPackage]) {
  assert.match(source, /0\.5\.0/, 'ships a consistent release version');
}
assert.match(frontendSources[0], /APP_VERSION = '0\.5\.0'/, 'keeps UI-visible version aligned with release metadata');
assert.match(frontendSources[1], /APP_VERSION_LABEL/, 'sidebar renders the shared app version label');
assert.doesNotMatch(frontendSources.join('\n'), /0\.4\.0/, 'removes stale pre-release version strings from visible UI and analytics examples');

assert.match(tauriConfig, /"productName": "Ari Meeting"/, 'keeps the macOS-visible product name');
assert.match(tauriConfig, /"identifier": "com\.meetily\.ai"/, 'preserves the stable storage and permission identifier');

console.log('release identity source checks passed');

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);

test('QA launcher isolates the native dev instance without changing the release identity', async () => {
  const [packageJson, qaConfig, routesQaConfig, minimumQaConfig, onboardingQaConfig, releaseConfig] = await Promise.all([
    readFile(new URL('package.json', root), 'utf8'),
    readFile(new URL('src-tauri/tauri.qa.conf.json', root), 'utf8'),
    readFile(new URL('src-tauri/tauri.qa.routes.conf.json', root), 'utf8'),
    readFile(new URL('src-tauri/tauri.qa.minimum.conf.json', root), 'utf8'),
    readFile(new URL('src-tauri/tauri.qa.onboarding.conf.json', root), 'utf8'),
    readFile(new URL('src-tauri/tauri.conf.json', root), 'utf8'),
  ]);
  const scripts = JSON.parse(packageJson).scripts;
  const qa = JSON.parse(qaConfig);
  const routesQa = JSON.parse(routesQaConfig);
  const minimumQa = JSON.parse(minimumQaConfig);
  const onboardingQa = JSON.parse(onboardingQaConfig);
  const release = JSON.parse(releaseConfig);

  assert.equal(scripts['tauri:dev:qa'], 'NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE=routes tauri dev --config src-tauri/tauri.qa.routes.conf.json -- --features metal');
  assert.equal(scripts['tauri:build:qa'], 'NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE=routes tauri build --debug --bundles app --config src-tauri/tauri.qa.routes.conf.json --features metal');
  assert.equal(scripts['tauri:dev:qa:minimum'], 'NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE=routes tauri dev --config src-tauri/tauri.qa.minimum.conf.json -- --features metal');
  assert.equal(scripts['tauri:build:qa:minimum'], 'NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE=routes tauri build --debug --bundles app --config src-tauri/tauri.qa.minimum.conf.json --features metal');
  assert.equal(scripts['tauri:dev:qa:onboarding'], 'NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE=onboarding tauri dev --config src-tauri/tauri.qa.onboarding.conf.json -- --features metal');
  assert.equal(scripts['tauri:build:qa:onboarding'], 'NEXT_PUBLIC_MEETILY_NATIVE_QA_MODE=onboarding tauri build --debug --bundles app --config src-tauri/tauri.qa.onboarding.conf.json --features metal');
  assert.equal(qa.identifier, 'com.meetily.improved.qa');
  assert.equal(qa.productName, 'Ari Meeting QA');
  assert.equal(qa.app.windows[0].title, 'Ari Meeting QA');
  assert.equal(routesQa.identifier, 'com.meetily.improved.qa.routes');
  assert.equal(routesQa.productName, 'Ari Meeting QA Routes');
  assert.equal(routesQa.app.windows[0].title, 'Ari Meeting QA Routes');
  assert.equal(minimumQa.identifier, 'com.meetily.improved.qa.minimum');
  assert.equal(minimumQa.productName, 'Ari Meeting QA Minimum');
  assert.equal(minimumQa.app.windows[0].title, 'Ari Meeting QA Minimum');
  assert.equal(onboardingQa.identifier, 'com.meetily.improved.qa.onboarding');
  assert.equal(onboardingQa.productName, 'Ari Meeting QA Onboarding');
  assert.equal(onboardingQa.app.windows[0].title, 'Ari Meeting QA Onboarding');
  // QA variants share a compact 1280×820 window; the release window is larger (1600×1025).
  for (const config of [qa, routesQa, onboardingQa]) {
    assert.equal(config.app.windows[0].width, 1280);
    assert.equal(config.app.windows[0].height, 820);
    assert.equal(config.app.windows[0].minWidth, 1100);
    assert.equal(config.app.windows[0].minHeight, 720);
  }
  assert.equal(release.app.windows[0].width, 1600);
  assert.equal(release.app.windows[0].height, 1025);
  assert.equal(release.app.windows[0].minWidth, 1100);
  assert.equal(release.app.windows[0].minHeight, 720);
  assert.equal(minimumQa.app.windows[0].width, 1100);
  assert.equal(minimumQa.app.windows[0].height, 720);
  assert.equal(minimumQa.app.windows[0].minWidth, 1100);
  assert.equal(minimumQa.app.windows[0].minHeight, 720);
  assert.equal(release.identifier, 'com.meetily.ai');
});

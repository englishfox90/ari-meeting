import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import ts from 'typescript';
import { fileURLToPath } from 'node:url';

const modulePath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'src',
  'lib',
  'summary-provider-visibility.ts',
);
const source = fs.readFileSync(modulePath, 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText;

// The visibility flag is read from process.env at module load, so load the
// module once per env we want to exercise.
function load(flag) {
  const module = { exports: {} };
  vm.runInNewContext(compiled, {
    exports: module.exports,
    module,
    process: { env: flag === undefined ? {} : { NEXT_PUBLIC_ARI_SHOW_ALL_PROVIDERS: flag } },
  });
  return module.exports;
}

// Default build (flag unset): only local / local-install providers are visible.
{
  const { isSummaryProviderVisible, showAllSummaryProviders } = load(undefined);
  assert.equal(showAllSummaryProviders, false);
  assert.equal(isSummaryProviderVisible('builtin-ai'), true);
  assert.equal(isSummaryProviderVisible('ollama'), true);
  assert.equal(isSummaryProviderVisible('claude-cli'), true);
  assert.equal(isSummaryProviderVisible('apple-foundation'), true);
  assert.equal(isSummaryProviderVisible('claude'), false);
  assert.equal(isSummaryProviderVisible('openai'), false);
  assert.equal(isSummaryProviderVisible('groq'), false);
  assert.equal(isSummaryProviderVisible('openrouter'), false);
  assert.equal(isSummaryProviderVisible('custom-openai'), false);

  // A pre-existing cloud selection stays visible so it can still be changed.
  assert.equal(isSummaryProviderVisible('openai', 'openai'), true);
  assert.equal(isSummaryProviderVisible('groq', 'openai'), false);
}

// Advanced build (flag on): every provider is visible.
for (const flag of ['1', 'true']) {
  const { isSummaryProviderVisible, showAllSummaryProviders } = load(flag);
  assert.equal(showAllSummaryProviders, true);
  for (const p of ['builtin-ai', 'ollama', 'claude-cli', 'apple-foundation', 'claude', 'openai', 'groq', 'openrouter', 'custom-openai']) {
    assert.equal(isSummaryProviderVisible(p), true);
  }
}

console.log('summary-provider-visibility tests passed');

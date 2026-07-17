import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import ts from 'typescript';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const modulePath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'src',
  'lib',
  'summary-timestamps.ts',
);
const source = fs.readFileSync(modulePath, 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText;
const module = { exports: {} };
vm.runInNewContext(compiled, { exports: module.exports, module });

const { extractSummaryMoments, matchTimestampTokens } = module.exports;
const j = (v) => JSON.stringify(v);

test('extracts and sorts unique in-range MM:SS timestamps', () => {
  const summary = { markdown: 'Decision made [02:15]. Later, a follow-up [00:45] and again [02:15].' };
  assert.equal(
    j(extractSummaryMoments(summary, 600)),
    j([{ seconds: 45, label: '0:45' }, { seconds: 135, label: '2:15' }]),
  );
});

test('drops timestamps beyond the recording duration (No-Fake-State)', () => {
  const summary = { markdown: 'Real [00:30], fabricated [99:59].' };
  assert.equal(j(extractSummaryMoments(summary, 60)), j([{ seconds: 30, label: '0:30' }]));
});

test('parses H:MM:SS and labels with hours', () => {
  const summary = { markdown: 'Long meeting point [1:02:15].' };
  assert.equal(j(extractSummaryMoments(summary, 4000)), j([{ seconds: 3735, label: '1:02:15' }]));
});

test('walks BlockNote JSON and legacy shapes, not just markdown', () => {
  const blocknote = {
    summary_json: [
      { type: 'paragraph', content: [{ type: 'text', text: 'Point at [00:10]' }] },
      { type: 'bulletListItem', content: [{ type: 'text', text: 'Another at [00:20]' }] },
    ],
  };
  assert.equal(j(extractSummaryMoments(blocknote, 300).map((m) => m.seconds)), j([10, 20]));
});

test('returns nothing when duration is unknown or zero', () => {
  const summary = { markdown: 'Has a [00:30] but no audio.' };
  assert.equal(j(extractSummaryMoments(summary, 0)), j([]));
  assert.equal(j(extractSummaryMoments(summary, NaN)), j([]));
});

test('ignores bracketless numbers and ISO-like text', () => {
  const summary = { markdown: 'Meeting on 2026-07-14T20:15 ran 45:00 minutes.' };
  assert.equal(j(extractSummaryMoments(summary, 100000)), j([]));
});

test('rejects invalid seconds/minutes fields', () => {
  const summary = { markdown: 'Bad [02:99] and good [02:05].' };
  assert.equal(j(extractSummaryMoments(summary, 600)), j([{ seconds: 125, label: '2:05' }]));
});

test('supports the canonical @ref(...) marker alongside the legacy bracket form', () => {
  const summary = { markdown: 'Decision at @ref(02:15). Older note at [00:45]. Repeat @ref(2:15).' };
  assert.equal(
    j(extractSummaryMoments(summary, 600)),
    j([{ seconds: 45, label: '0:45' }, { seconds: 135, label: '2:15' }]),
  );
});

test('@ref(...) supports H:MM:SS and is dropped when out of range', () => {
  const summary = { markdown: 'Long point @ref(1:02:15). Fabricated @ref(99:59:00).' };
  assert.equal(j(extractSummaryMoments(summary, 4000)), j([{ seconds: 3735, label: '1:02:15' }]));
});

test('matchTimestampTokens exposes token position/length for both marker forms', () => {
  const text = 'See @ref(01:14) and also [00:05] here.';
  const tokens = matchTimestampTokens(text);
  assert.equal(tokens.length, 2);
  assert.equal(tokens[0].index, text.indexOf('@ref(01:14)'));
  assert.equal(tokens[0].length, '@ref(01:14)'.length);
  assert.equal(tokens[0].seconds, 74);
  assert.equal(tokens[0].label, '1:14');
  assert.equal(tokens[1].index, text.indexOf('[00:05]'));
  assert.equal(tokens[1].length, '[00:05]'.length);
  assert.equal(tokens[1].seconds, 5);
});

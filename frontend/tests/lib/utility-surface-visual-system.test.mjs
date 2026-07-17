import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const utilityPaths = [
  'src/app/_components/SettingsModal.tsx',
  'src/components/BuiltInModelManager.tsx',
  'src/components/ChunkProgressDisplay.tsx',
  'src/components/ImportAudio/ImportAudioDialog.tsx',
  'src/components/ImportAudio/ImportDropOverlay.tsx',
  'src/components/LanguageSelection.tsx',
  'src/components/ModelSettingsModal.tsx',
  'src/components/ParakeetModelManager.tsx',
  'src/components/TranscriptSettings.tsx',
  'src/components/WhisperModelManager.tsx',
];

test('active utility surfaces use the native visual and icon system', async () => {
  const files = await Promise.all(utilityPaths.map((path) => readFile(new URL(path, root), 'utf8')));
  const combined = files.join('\n');
  const [settingsModals, builtInModels, chunkProgress, , , , , parakeetModels, , whisperModels] = files;

  assert.match(combined, /@heroicons\/react/);
  assert.doesNotMatch(combined, /from ['"]lucide-react['"]/);
  assert.doesNotMatch(combined, /<svg/);
  assert.doesNotMatch(combined, /rounded-\[(?:2|3|4)px\]/);
  assert.doesNotMatch(combined, /[✅❌⚡⏳⏱🎉]/u);
  assert.doesNotMatch(combined, /(?:bg|text|border)-(?:blue|gray|slate|white)-/);

  assert.match(settingsModals, /role="dialog" aria-modal="true"/);
  assert.match(settingsModals, /event\.key === 'Escape'/);
  for (const modelManager of [builtInModels, parakeetModels, whisperModels]) {
    assert.match(modelManager, /divide-y divide-border\/70/);
    assert.doesNotMatch(modelManager, /relative rounded-md border transition-all cursor-pointer/);
  }
  assert.match(chunkProgress, /role="progressbar"/);
  assert.match(chunkProgress, /aria-valuenow=\{completionPercentage\}/);
});

test('native QA can open the real empty import dialog without selecting a file', async () => {
  const [qaMode, layout] = await Promise.all([
    readFile(new URL('src/lib/native-qa-mode.ts', root), 'utf8'),
    readFile(new URL('src/app/layout.tsx', root), 'utf8'),
  ]);

  assert.match(qaMode, /configuredOverlay === 'import-audio'/);
  assert.match(layout, /useState\(openImportDialogForNativeQa\)/);
  assert.match(layout, /\(!betaFeatures\.importAndRetranscribe \|\| isPostProcessing\) && !openImportDialogForNativeQa/);
  assert.match(layout, /isPostProcessing && showImportDialog && !openImportDialogForNativeQa/);
  assert.doesNotMatch(qaMode, /preselectedFile|validateFile|startImport/);
});

test('native QA can open an explicitly supplied real persisted meeting id', async () => {
  const [qaMode, layout] = await Promise.all([
    readFile(new URL('src/lib/native-qa-mode.ts', root), 'utf8'),
    readFile(new URL('src/app/layout.tsx', root), 'utf8'),
  ]);

  assert.match(qaMode, /NEXT_PUBLIC_MEETILY_NATIVE_QA_MEETING_ID/);
  assert.match(qaMode, /configuredRoute === 'meeting'/);
  assert.match(qaMode, /encodeURIComponent\(configuredMeetingId\)/);
  assert.match(layout, /window\.location\.pathname\}\$\{window\.location\.search/);
  assert.doesNotMatch(qaMode, /meeting-[0-9a-f-]{8,}/);
});

test('native QA can open a real settings section without changing its data', async () => {
  const [qaMode, settingsPage] = await Promise.all([
    readFile(new URL('src/lib/native-qa-mode.ts', root), 'utf8'),
    readFile(new URL('src/app/settings/page.tsx', root), 'utf8'),
  ]);

  assert.match(qaMode, /NEXT_PUBLIC_MEETILY_NATIVE_QA_SETTINGS_TAB/);
  assert.match(qaMode, /nativeQaMode === 'routes'/);
  assert.match(settingsPage, /useState\(nativeQaSettingsTab \?\? 'general'\)/);
  assert.doesNotMatch(qaMode, /setTranscriptModelConfig|api_save_transcript_config/);
});

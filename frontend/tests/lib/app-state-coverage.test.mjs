import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);

async function source(path) {
  return readFile(new URL(path, root), 'utf8');
}

test('major Phase 1 routes declare truthful reusable non-happy-path states', async () => {
  const [home, meetings, detail, askConsole, recallService, settings, permissions, preRecording, activeRecording] = await Promise.all([
    source('src/app/page.tsx'),
    source('src/app/meetings/page.tsx'),
    source('src/app/meeting-details/page.tsx'),
    // The /chat page was rebuilt onto the shared Ask engine; its non-happy-path
    // states now live in the reusable AskConsole (loading/error) and the recall
    // service (the invoke). Citations are inline hover-cards (AskMessage), not a rail.
    source('src/components/ask/AskConsole.tsx'),
    source('src/services/recallService.ts'),
    source('src/app/settings/page.tsx'),
    source('src/components/PermissionWarning.tsx'),
    source('src/components/recording/PreRecordingWorkspace.tsx'),
    source('src/components/recording/ActiveRecordingWorkspace.tsx'),
  ]);

  assert.match(home, /kind="empty"/);
  assert.match(home, /does not add sample meetings or fabricated activity/);

  assert.match(meetings, /kind="loading"/);
  assert.match(meetings, /kind="error"/);
  assert.match(meetings, /kind="empty"/);
  assert.match(meetings, /Try again/);
  assert.match(meetings, /Clear search/);

  assert.match(detail, /kind="loading"/);
  assert.match(detail, /kind="error"/);
  assert.match(detail, /Back to saved meetings/);

  assert.match(askConsole, /kind="model"/);
  assert.match(askConsole, /configured local model/);
  assert.match(recallService, /api_answer_meetings_locally/);
  assert.match(askConsole, /Review local model settings/);

  assert.match(settings, /kind="error"/);
  assert.match(permissions, /kind="permission"/);
  assert.match(permissions, /Open microphone settings/);
  assert.match(permissions, /Recheck/);
  assert.match(preRecording, /kind="error"/);
  assert.match(preRecording, /Check setup again/);
  assert.match(activeRecording, /kind="error"/);
});

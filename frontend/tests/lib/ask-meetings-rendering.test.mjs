import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);

test('Ask Meetings renders safe Markdown and dated hover-card citations', async () => {
  // The single-shot /chat page was rebuilt into the shared Ask engine: Markdown
  // rendering AND the citation source preview both live in the AskMessage turn
  // component (reused by the /chat full-window surface AND the app-wide floating
  // overlay). Citations are inline [S<n>] chips whose hover-card shows the dated,
  // meeting-level source — there is no separate source rail. Assert against the
  // canonical component instead of the thin page shell.
  const [askMessage, api] = await Promise.all([
    readFile(new URL('src/components/ask/AskMessage.tsx', root), 'utf8'),
    readFile(new URL('src-tauri/src/api/api.rs', root), 'utf8'),
  ]);

  assert.match(askMessage, /ReactMarkdown/);
  assert.match(askMessage, /remarkPlugins=\{\[remarkGfm\]\}/);
  assert.doesNotMatch(askMessage, /rehypeRaw/);
  // Source preview (dated, meeting-level) now renders inside the citation hover-card.
  assert.match(askMessage, /source\.meetingDate/);
  assert.match(askMessage, /new Date\(source\.meetingDate as string\)\.toLocaleDateString\(\)/);
  assert.match(askMessage, /TooltipContent/);

  assert.match(api, /fn build_global_recall_sources/);
  assert.match(api, /find\(\|source\| source\.meeting_id == item\.id\)/);
  assert.match(api, /MAX_GLOBAL_RECALL_MEETINGS/);
  assert.match(api, /Saved summary:/);
  assert.match(api, /MAX_MEETING_RECALL_CONTEXT_CHARS/);
});

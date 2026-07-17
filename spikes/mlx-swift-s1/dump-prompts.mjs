// dump-prompts.mjs — READ-ONLY one-off script for the mlx-swift-s1 spike.
// Uses tools/prompt-harness/lib/{db,prompt}.mjs as a library (does NOT
// modify anything under tools/prompt-harness/). Writes the exact Call ③
// {system, user} prompt pairs for 2 meetings into spikes/mlx-swift-s1/prompts/
// as JSON, plus transcript time-range metadata for the citation sanity check.

import path from 'node:path';
import fs from 'node:fs';
import * as db from '../../tools/prompt-harness/lib/db.mjs';
import * as promptLib from '../../tools/prompt-harness/lib/prompt.mjs';

const TEMPLATES_DIR = path.resolve('frontend/src-tauri/templates');
const OUT_DIR = path.resolve('spikes/mlx-swift-s1/prompts');

const MEETINGS = [
  { id: 'meeting-d894f3ce-2ffa-4b34-bba6-1265804df866', label: 'adhoc-with-nia' },
  { id: 'meeting-fe110af3-65ca-4acc-a53f-0de694b6f477', label: 'servicing-org-strategy' },
];

fs.mkdirSync(OUT_DIR, { recursive: true });

const conn = db.openReadOnly();

for (const m of MEETINGS) {
  const meeting = db.getMeeting(conn, m.id);
  const transcript = db.loadTranscript(conn, m.id);
  const templateId = meeting?.template_id || 'standard_meeting';
  let template;
  try {
    template = promptLib.loadTemplate(templateId, TEMPLATES_DIR);
  } catch (e) {
    console.error(`template ${templateId} failed, falling back to standard_meeting:`, e.message);
    template = promptLib.loadTemplate('standard_meeting', TEMPLATES_DIR);
  }

  const { system, user } = promptLib.buildCallThreePrompt(transcript.transcriptText, template);

  const starts = transcript.lines.map((l) => l.start).filter((s) => typeof s === 'number');
  const timeRange = { minSeconds: Math.min(...starts), maxSeconds: Math.max(...starts) };

  const out = {
    meetingId: m.id,
    title: meeting?.title,
    templateId,
    lineCount: transcript.lines.length,
    speakers: [...new Set(transcript.lines.map((l) => l.speaker))],
    timeRange,
    system,
    user,
  };

  const outPath = path.join(OUT_DIR, `${m.label}.json`);
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log(`wrote ${outPath} (${transcript.lines.length} lines, template=${templateId}, timeRange=${JSON.stringify(timeRange)})`);
}

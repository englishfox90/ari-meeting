// extract_parakeet.mjs — pull the shipped Parakeet transcript (already the
// production STT output) for the S2 eval meeting set, read-only, and write
// it to results/parakeet/<key>.json alongside plain text for jiwer.
import { openReadOnly, getParakeetTranscript, getMeeting } from './lib/db.mjs';
import fs from 'node:fs';
import path from 'node:path';

const MEETINGS = {
  brian1on1: 'meeting-68bbcdbd-fa7f-4f5d-942b-db6220553861',
  servicing_org: 'meeting-fe110af3-65ca-4acc-a53f-0de694b6f477',
  metro2: 'meeting-cb4afcf7-9c39-4381-91ca-898f2da0927d',
  career_1on1: 'meeting-84182337-e4a8-4713-a5d5-78f39a89a4ae',
  nia: 'meeting-d894f3ce-2ffa-4b34-bba6-1265804df866',
};

const outDir = path.join(process.argv[2] || '.', 'parakeet');
fs.mkdirSync(outDir, { recursive: true });

const db = openReadOnly();
for (const [key, id] of Object.entries(MEETINGS)) {
  const meeting = getMeeting(db, id);
  const { text, segments } = getParakeetTranscript(db, id);
  fs.writeFileSync(
    path.join(outDir, `${key}.json`),
    JSON.stringify({ meetingId: id, title: meeting?.title, text, segments }, null, 2),
  );
  console.log(`${key}: ${segments.length} rows, ${text.length} chars, title="${meeting?.title}"`);
}

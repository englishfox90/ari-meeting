#!/usr/bin/env node
// extract.mjs — picks the S1 fixture set (real meetings from the app's DB)
// and writes fixtures/manifest.json: a committed *pointer* list (meeting ids,
// titles, dates, transcript-line counts) — never the transcript text itself
// (that would be private meeting content committed to git). Re-run this
// script any time to regenerate the manifest against the current DB; run.mjs
// re-extracts the actual transcript text on demand into a gitignored cache.
//
// Usage:
//   node extract.mjs [--db path/to/meeting_minutes.sqlite] [--count 10]

import fs from 'node:fs';
import path from 'node:path';
import { openReadOnly, listCandidateMeetings, DEFAULT_DB_PATH } from './lib/db.mjs';

function parseArgs(argv) {
  const args = { db: DEFAULT_DB_PATH, count: 10 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--db') args.db = argv[++i];
    else if (argv[i] === '--count') args.count = parseInt(argv[++i], 10);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!fs.existsSync(args.db)) {
    console.error(`No DB found at ${args.db}. Run the app once to create it, or pass --db.`);
    process.exit(1);
  }

  const db = openReadOnly(args.db);
  const candidates = listCandidateMeetings(db);

  console.log(`Found ${candidates.length} meeting(s) with at least one transcript row in the DB.`);
  if (candidates.length < args.count) {
    console.log(
      `Fewer than the requested ${args.count} — using all ${candidates.length} available. ` +
        `S1's "≥10 real transcripts" bar cannot be fully met until more meetings accumulate.`,
    );
  }

  const chosen = candidates.slice(0, args.count);

  const manifest = {
    generatedAt: new Date().toISOString(),
    dbPath: args.db,
    requestedCount: args.count,
    availableCount: candidates.length,
    meetings: chosen.map((m) => ({
      id: m.id,
      title: m.title,
      createdAt: m.createdAt,
      transcriptLineCount: m.transcriptCount,
      templateId: m.templateId || null,
      summaryProvider: m.summaryProvider || null,
      summaryModel: m.summaryModel || null,
    })),
  };

  const outDir = path.resolve(import.meta.dirname, 'fixtures');
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, 'manifest.json');
  fs.writeFileSync(outPath, JSON.stringify(manifest, null, 2) + '\n');

  console.log(`Wrote ${manifest.meetings.length} fixture pointer(s) to ${outPath}`);
  for (const m of manifest.meetings) {
    console.log(`  - ${m.id}  "${m.title}"  (${m.transcriptLineCount} lines, template=${m.templateId ?? 'default'})`);
  }
}

main();

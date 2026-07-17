#!/usr/bin/env node
// abtest.mjs — the S1 pass-bar tool.
//
// Given a baseline run dir (e.g. runs/llama-baseline) and a candidate run dir
// (e.g. runs/mlx-candidate-v1), presents each meeting's two summaries BLIND
// (randomized A/B per meeting, source hidden until after you rate) and asks
// for a verdict: which is better, or tied. This is exactly the mechanism
// S1's bar needs: "summaries rated >= current on >= 10 real transcripts,
// blind A/B."
//
// Usage:
//   node abtest.mjs --baseline runs/llama-baseline --candidate runs/mlx-candidate-v1 --out ratings/mlx-v1.json
//
// Ratings are written to the given --out path (default: runs/<candidate-label>-vs-<baseline-label>.ratings.json,
// under the gitignored runs/ tree) as you go, so a Ctrl-C mid-session doesn't lose prior answers.

import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline/promises';

function parseArgs(argv) {
  const args = { out: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--baseline') args.baseline = argv[++i];
    else if (a === '--candidate') args.candidate = argv[++i];
    else if (a === '--out') args.out = argv[++i];
  }
  return args;
}

function loadRunDir(dir) {
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.json') && f !== '_summary.json');
  const byMeetingId = new Map();
  for (const f of files) {
    const record = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    byMeetingId.set(record.meetingId, record);
  }
  return byMeetingId;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.baseline || !args.candidate) {
    console.error('Usage: node abtest.mjs --baseline <dir> --candidate <dir> [--out <ratings.json>]');
    process.exit(1);
  }

  const baselineDir = path.resolve(args.baseline);
  const candidateDir = path.resolve(args.candidate);
  const baseline = loadRunDir(baselineDir);
  const candidate = loadRunDir(candidateDir);

  const meetingIds = [...baseline.keys()].filter((id) => candidate.has(id));
  if (meetingIds.length === 0) {
    console.error('No overlapping meeting ids between the two run dirs — nothing to compare.');
    process.exit(1);
  }

  const outPath =
    args.out ||
    path.resolve(
      import.meta.dirname,
      `runs/${path.basename(candidateDir)}-vs-${path.basename(baselineDir)}.ratings.json`,
    );

  const existing = fs.existsSync(outPath) ? JSON.parse(fs.readFileSync(outPath, 'utf8')) : { ratings: [] };
  const alreadyRated = new Set(existing.ratings.map((r) => r.meetingId));

  const rl = createInterface({ input: process.stdin, output: process.stdout });

  console.log(`Blind A/B: ${baselineDir} (baseline) vs ${candidateDir} (candidate)`);
  console.log(`${meetingIds.length} meeting(s) overlap. ${alreadyRated.size} already rated (resuming).\n`);

  for (const meetingId of meetingIds) {
    if (alreadyRated.has(meetingId)) continue;

    const baseRec = baseline.get(meetingId);
    const candRec = candidate.get(meetingId);

    if (!baseRec.ok || !candRec.ok) {
      console.log(`[skip] "${baseRec.title}" — one side failed to generate (baseline ok=${baseRec.ok}, candidate ok=${candRec.ok})`);
      existing.ratings.push({
        meetingId,
        title: baseRec.title,
        skipped: true,
        reason: `baseline ok=${baseRec.ok}, candidate ok=${candRec.ok}`,
      });
      fs.writeFileSync(outPath, JSON.stringify(existing, null, 2) + '\n');
      continue;
    }

    // Randomize which slot (A/B) holds the baseline vs candidate, hidden until after rating.
    const baselineIsA = Math.random() < 0.5;
    const slotA = baselineIsA ? baseRec.text : candRec.text;
    const slotB = baselineIsA ? candRec.text : baseRec.text;

    console.log('\n' + '='.repeat(72));
    console.log(`Meeting: ${baseRec.title}`);
    console.log('='.repeat(72));
    console.log('\n--- Summary A ---\n');
    console.log(slotA);
    console.log('\n--- Summary B ---\n');
    console.log(slotB);
    console.log();

    let answer;
    while (true) {
      answer = (await rl.question('Which is better? [a/b/tie, or "s" to skip, "q" to quit]: '))
        .trim()
        .toLowerCase();
      if (['a', 'b', 'tie', 's', 'q'].includes(answer)) break;
      console.log('Please enter a, b, tie, s, or q.');
    }

    if (answer === 'q') {
      console.log('Stopping early. Progress saved.');
      break;
    }
    if (answer === 's') {
      console.log('Skipped (not recorded).');
      continue;
    }

    let verdict; // from the CANDIDATE's perspective
    if (answer === 'tie') verdict = 'same';
    else if ((answer === 'a' && !baselineIsA) || (answer === 'b' && baselineIsA)) verdict = 'candidate_better';
    else verdict = 'candidate_worse';

    console.log(
      `  -> revealed: A = ${baselineIsA ? 'baseline' : 'candidate'}, B = ${baselineIsA ? 'candidate' : 'baseline'} (verdict: ${verdict})`,
    );

    existing.ratings.push({
      meetingId,
      title: baseRec.title,
      baselineIsA,
      rawAnswer: answer,
      verdict,
      skipped: false,
    });
    fs.writeFileSync(outPath, JSON.stringify(existing, null, 2) + '\n');
  }

  rl.close();

  const scored = existing.ratings.filter((r) => !r.skipped);
  const better = scored.filter((r) => r.verdict === 'candidate_better').length;
  const same = scored.filter((r) => r.verdict === 'same').length;
  const worse = scored.filter((r) => r.verdict === 'candidate_worse').length;
  const passing = better + same; // candidate >= baseline

  console.log('\n' + '-'.repeat(72));
  console.log(`Verdict tally (candidate vs baseline): better=${better} same=${same} worse=${worse}`);
  console.log(`S1 bar: candidate >= baseline on ${passing}/${scored.length} rated meetings`);
  console.log(`Ratings saved to ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

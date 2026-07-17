#!/usr/bin/env node
// compare.mjs — the S1 "decision-grade data" tool. Reads two or more run
// dirs (as produced by run.mjs), scores each backend's summaries against the
// meeting's REAL transcript (via lib/db.mjs, read-only, same DB the fixture
// set came from), and writes:
//   - runs/comparison.json  (raw per-meeting + aggregate metrics)
//   - runs/COMPARISON.md    (human-readable tables)
//
// This is objective, code-checkable scoring — NOT a substitute for the
// human blind A/B (abtest.mjs). Citation validity is checked against the
// exact set of real [MM:SS]/[H:MM:SS] markers that exist in that meeting's
// transcript (not just "some plausible range"), so a citation is only
// "valid" if it matches a real transcript line — anything else is either
// "unmatched" (a timestamp inside the meeting's duration but not on any
// actual line) or "out-of-range" (past the meeting's end, or negative).
//
// Usage:
//   node compare.mjs --runs runs/llama-baseline runs/mlx-qwen-mlx runs/gemma-gemma-e4b
//   node compare.mjs --runs runs/llama-baseline runs/mlx-qwen-mlx --judge claude
//
// --judge claude is OPTIONAL and ADVISORY (see lib/judge.mjs) — it runs a
// blind pairwise `claude -p` comparison for every (baseline, candidate) pair
// among the given --runs (first run dir is treated as the baseline for
// pairing purposes), and is skipped silently if the `claude` CLI isn't on
// PATH. It is explicitly NOT the S1 pass bar.

import fs from 'node:fs';
import path from 'node:path';
import { openReadOnly, loadTranscript, DEFAULT_DB_PATH } from './lib/db.mjs';
import { loadTemplate } from './lib/prompt.mjs';
import { claudeCliAvailable, judgePairBlind } from './lib/judge.mjs';

const TEMPLATES_DIR = path.resolve(import.meta.dirname, '../../frontend/src-tauri/templates');
const RUNS_DIR = path.resolve(import.meta.dirname, 'runs');

function parseArgs(argv) {
  const args = { runs: [], db: DEFAULT_DB_PATH, judge: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--runs') {
      while (argv[i + 1] && !argv[i + 1].startsWith('--')) args.runs.push(argv[++i]);
    } else if (a === '--db') {
      args.db = argv[++i];
    } else if (a === '--judge') {
      args.judge = argv[++i];
    }
  }
  return args;
}

function loadRunDir(dir) {
  const abs = path.resolve(dir);
  const files = fs.readdirSync(abs).filter((f) => f.endsWith('.json') && f !== '_summary.json');
  const byMeetingId = new Map();
  for (const f of files) {
    const record = JSON.parse(fs.readFileSync(path.join(abs, f), 'utf8'));
    byMeetingId.set(record.meetingId, record);
  }
  return { label: path.basename(abs), dir: abs, byMeetingId };
}

// --- Citation validity -----------------------------------------------------

// Matches @ref(MM:SS) or @ref(H:MM:SS) per TIMESTAMP_CITATION_INSTRUCTION
// (lib/prompt.mjs / frontend/src/lib/summary/summaryCore.ts:38-39).
const CITATION_RE = /@ref\((\d{1,2}(?::\d{2})?):(\d{2})\)/g;

function citationToSeconds(hOrM, ss) {
  const secs = parseInt(ss, 10);
  if (hOrM.includes(':')) {
    const [h, m] = hOrM.split(':').map((n) => parseInt(n, 10));
    return h * 3600 + m * 60 + secs;
  }
  return parseInt(hOrM, 10) * 60 + secs;
}

function extractCitations(text) {
  const out = [];
  let m;
  CITATION_RE.lastIndex = 0;
  while ((m = CITATION_RE.exec(text)) !== null) {
    out.push({ raw: m[0], seconds: citationToSeconds(m[1], m[2]) });
  }
  return out;
}

function scoreCitations(text, transcriptLines) {
  const citations = extractCitations(text);
  const realSeconds = new Set(
    transcriptLines.filter((l) => l.start !== null && l.start !== undefined).map((l) => Math.floor(l.start)),
  );
  const maxSeconds = realSeconds.size > 0 ? Math.max(...realSeconds) : 0;

  let valid = 0;
  let unmatched = 0; // in-range but no real transcript line at that exact second
  let outOfRange = 0;
  for (const c of citations) {
    if (realSeconds.has(c.seconds)) valid++;
    else if (c.seconds < 0 || c.seconds > maxSeconds) outOfRange++;
    else unmatched++;
  }
  return { total: citations.length, valid, unmatched, outOfRange };
}

// --- Speaker attribution sanity ---------------------------------------------
//
// Every built-in template's Action Items section is a markdown table whose
// FIRST column is the owner/name (`| **Owner** | Task | Due | Ref |`, per
// every templates/*.json item_format — verified by reading all seven
// template files). That's the one place the prompt explicitly asks the
// model to attribute a real person's name (build_final_report_system_prompt
// point 8: "attribute decisions, action items, and quotes to that speaker by
// name. Never guess or invent a speaker who isn't named."), so it's the
// precise, low-false-positive place to check attribution — NOT a generic
// "any capitalized word followed by a colon" regex, which (verified by hand)
// matches bolded sub-bullet labels like "**Metro 2 Ownership:**" far more
// often than real names and made every backend look 0% valid.
//
// We also do a second, independent check: does the summary mention any real
// attendee name anywhere in its prose at all ("grounded mentions")? A
// summary with zero grounded mentions across a whole transcript full of
// named speakers is a red flag even if its Action Items table is empty.

const OWNER_PLACEHOLDER_RE = /^(tbd|n\/?a|-|—|team|everyone|all|group|unassigned|)$/i;

function extractActionItemOwners(text) {
  const sectionMatch = text.match(/\*\*Action Items\*\*([\s\S]*?)(?=\n\*\*[^*]|$)/);
  if (!sectionMatch) return [];
  const block = sectionMatch[1];
  const owners = [];
  for (const line of block.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('|')) continue;
    if (/^\|?\s*:?-{2,}/.test(trimmed)) continue; // separator row
    const cells = trimmed.split('|').map((c) => c.trim());
    // cells[0] is '' (before the leading |); the owner is the first real cell.
    const ownerCell = (cells[1] || '').replace(/\*\*/g, '').trim();
    if (/owner/i.test(ownerCell)) continue; // header row
    if (OWNER_PLACEHOLDER_RE.test(ownerCell)) continue; // blank/placeholder, not a claim
    owners.push(ownerCell);
  }
  return owners;
}

function scoreSpeakerAttribution(text, transcriptLines) {
  const realNames = [...new Set(transcriptLines.filter((l) => l.speaker).map((l) => l.speaker.trim()))];
  const realNamesLower = realNames.map((n) => n.toLowerCase());

  const owners = extractActionItemOwners(text);
  let known = 0;
  let unknown = 0;
  const unknownNames = new Set();
  for (const owner of owners) {
    const lower = owner.toLowerCase();
    // Accept exact match, or first/last-name-only match against a real full
    // name ("Sarah" or "Chen" when the transcript says "Sarah Chen" is fine).
    const isKnown = realNamesLower.some(
      (real) => real === lower || real.split(' ').includes(lower) || lower.split(' ').every((tok) => real.includes(tok)),
    );
    if (isKnown) known++;
    else {
      unknown++;
      unknownNames.add(owner);
    }
  }

  let groundedMentions = 0;
  for (const name of realNames) {
    const firstName = name.split(' ')[0];
    if (firstName.length < 2) continue;
    const re = new RegExp(`\\b${firstName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i');
    if (re.test(text)) groundedMentions++;
  }

  return {
    totalMentions: owners.length,
    known,
    unknown,
    unknownNames: [...unknownNames],
    groundedMentions,
    realSpeakerCount: realNames.length,
  };
}

// --- Section completeness ---------------------------------------------------

function scoreSectionCompleteness(text, template) {
  const expectedTitles = template.sections.map((s) => s.title);
  const present = expectedTitles.filter((title) => text.includes(`**${title}**`));
  const hasMainTitle = /^#\s+\S/m.test(text);
  return {
    expected: expectedTitles.length,
    present: present.length,
    missing: expectedTitles.filter((t) => !present.includes(t)),
    hasMainTitle,
  };
}

// --- Format / refusal failures ----------------------------------------------

const REFUSAL_PATTERNS = [
  /\bi cannot\b/i,
  /\bi can'?t assist\b/i,
  /\bas an ai\b/i,
  /\bi'?m sorry,? but\b/i,
  /\bi am unable to\b/i,
];

function scoreFormatFailures(record, sectionScore) {
  if (!record.ok) {
    return { failureType: 'generation_error', detail: record.error };
  }
  const text = record.text || '';
  if (text.trim().length === 0) return { failureType: 'empty', detail: null };
  if (text.trim().length < 80) return { failureType: 'too_short', detail: `${text.trim().length} chars` };
  if (REFUSAL_PATTERNS.some((re) => re.test(text))) return { failureType: 'refusal', detail: null };
  if (!sectionScore.hasMainTitle) return { failureType: 'no_main_title', detail: null };
  if (sectionScore.present === 0 && sectionScore.expected > 0) {
    return { failureType: 'template_ignored', detail: 'no expected section headers found' };
  }
  return { failureType: null, detail: null };
}

// --- Main --------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.runs.length < 1) {
    console.error('Usage: node compare.mjs --runs <dir1> <dir2> [dir3 ...] [--judge claude] [--db PATH]');
    process.exit(1);
  }

  const runDirs = args.runs.map(loadRunDir);
  const db = openReadOnly(args.db);
  const transcriptCache = new Map();
  function getTranscript(meetingId) {
    if (!transcriptCache.has(meetingId)) {
      transcriptCache.set(meetingId, loadTranscript(db, meetingId));
    }
    return transcriptCache.get(meetingId);
  }
  const templateCache = new Map();
  function getTemplate(templateId) {
    const id = templateId || 'standard_meeting';
    if (!templateCache.has(id)) {
      try {
        templateCache.set(id, loadTemplate(id, TEMPLATES_DIR));
      } catch {
        templateCache.set(id, loadTemplate('standard_meeting', TEMPLATES_DIR));
      }
    }
    return templateCache.get(id);
  }

  const perBackend = [];

  for (const { label, byMeetingId } of runDirs) {
    const perMeeting = [];
    for (const [meetingId, record] of byMeetingId) {
      const { lines } = getTranscript(meetingId);
      const template = getTemplate(record.templateId);
      const sectionScore = record.ok ? scoreSectionCompleteness(record.text, template) : null;
      const citationScore = record.ok ? scoreCitations(record.text, lines) : null;
      const attributionScore = record.ok ? scoreSpeakerAttribution(record.text, lines) : null;
      const formatFailure = scoreFormatFailures(record, sectionScore || { hasMainTitle: false, present: 0, expected: 0 });

      perMeeting.push({
        meetingId,
        title: record.title,
        ok: record.ok,
        elapsedMs: record.elapsedMs ?? null,
        latencyMs: record.latencyMs ?? null,
        loadMs: record.loadMs ?? null,
        peakRssMb: record.peakRssMb ?? null,
        textLength: record.ok ? record.text.length : 0,
        citations: citationScore,
        attribution: attributionScore,
        sections: sectionScore,
        formatFailure: formatFailure.failureType,
        formatFailureDetail: formatFailure.detail,
      });
    }

    const okMeetings = perMeeting.filter((m) => m.ok);
    const sum = (arr, f) => arr.reduce((a, m) => a + f(m), 0);
    const avg = (arr, f) => (arr.length ? sum(arr, f) / arr.length : null);

    const aggregate = {
      total: perMeeting.length,
      succeeded: okMeetings.length,
      failed: perMeeting.length - okMeetings.length,
      formatFailures: perMeeting.filter((m) => m.formatFailure).length,
      totalCitations: sum(okMeetings, (m) => m.citations?.total || 0),
      validCitations: sum(okMeetings, (m) => m.citations?.valid || 0),
      unmatchedCitations: sum(okMeetings, (m) => m.citations?.unmatched || 0),
      outOfRangeCitations: sum(okMeetings, (m) => m.citations?.outOfRange || 0),
      // Meetings with zero diarized speakers (e.g. this fixture set's
      // "Metro2") can't be scored for owner-attribution validity — any name
      // the model writes would count as "unknown" even if it's a real
      // person mentioned in the transcript's own dialogue, since there's no
      // speaker label to check against. Exclude those from the validity
      // denominator; still count their raw owner mentions separately.
      diarizedMeetings: okMeetings.filter((m) => (m.attribution?.realSpeakerCount || 0) > 0).length,
      undiarizedMeetings: okMeetings.filter((m) => (m.attribution?.realSpeakerCount || 0) === 0).length,
      totalAttributionMentions: sum(
        okMeetings.filter((m) => (m.attribution?.realSpeakerCount || 0) > 0),
        (m) => m.attribution?.totalMentions || 0,
      ),
      unknownAttributionMentions: sum(
        okMeetings.filter((m) => (m.attribution?.realSpeakerCount || 0) > 0),
        (m) => m.attribution?.unknown || 0,
      ),
      totalGroundedMentions: sum(okMeetings, (m) => m.attribution?.groundedMentions || 0),
      totalRealSpeakers: sum(okMeetings, (m) => m.attribution?.realSpeakerCount || 0),
      avgSectionCompletenessPct:
        avg(
          okMeetings.filter((m) => m.sections && m.sections.expected > 0),
          (m) => (100 * m.sections.present) / m.sections.expected,
        ) ?? null,
      avgElapsedMs: avg(okMeetings, (m) => m.elapsedMs || 0),
      avgLatencyMs: avg(
        okMeetings.filter((m) => m.latencyMs != null),
        (m) => m.latencyMs,
      ),
      avgPeakRssMb: avg(
        okMeetings.filter((m) => m.peakRssMb != null),
        (m) => m.peakRssMb,
      ),
    };
    aggregate.citationValidityPct =
      aggregate.totalCitations > 0 ? (100 * aggregate.validCitations) / aggregate.totalCitations : null;
    aggregate.attributionValidityPct =
      aggregate.totalAttributionMentions > 0
        ? (100 * (aggregate.totalAttributionMentions - aggregate.unknownAttributionMentions)) / aggregate.totalAttributionMentions
        : null;
    aggregate.groundedMentionRatePct =
      aggregate.totalRealSpeakers > 0 ? (100 * aggregate.totalGroundedMentions) / aggregate.totalRealSpeakers : null;

    perBackend.push({ label, perMeeting, aggregate });
  }

  // --- Optional advisory judge pass ---
  let judgeResults = null;
  if (args.judge === 'claude') {
    if (!claudeCliAvailable()) {
      console.log('[judge] --judge claude requested but `claude` CLI not found on PATH — skipping silently.');
    } else if (runDirs.length < 2) {
      console.log('[judge] --judge claude requires at least 2 --runs dirs — skipping.');
    } else {
      console.log('[judge] Running ADVISORY blind pairwise judge via `claude -p` (NOT the S1 gate)...');
      judgeResults = [];
      const baselineRun = runDirs[0];
      for (let i = 1; i < runDirs.length; i++) {
        const candidateRun = runDirs[i];
        console.log(`  [judge] ${candidateRun.label} vs ${baselineRun.label} ...`);
        const result = judgePairBlind(
          baselineRun.label,
          candidateRun.label,
          baselineRun.byMeetingId,
          candidateRun.byMeetingId,
        );
        console.log(
          `    -> candidate_better=${result.tally.candidate_better} baseline_better=${result.tally.baseline_better} tie=${result.tally.tie} unjudged=${result.tally.unjudged}`,
        );
        judgeResults.push(result);
      }
    }
  }

  // --- Write outputs ---
  fs.mkdirSync(RUNS_DIR, { recursive: true });
  const jsonOut = {
    generatedAt: new Date().toISOString(),
    runs: perBackend,
    judge: judgeResults,
  };
  fs.writeFileSync(path.join(RUNS_DIR, 'comparison.json'), JSON.stringify(jsonOut, null, 2) + '\n');

  const md = renderMarkdown(perBackend, judgeResults);
  fs.writeFileSync(path.join(RUNS_DIR, 'COMPARISON.md'), md);

  console.log(`\nWrote ${path.join(RUNS_DIR, 'comparison.json')}`);
  console.log(`Wrote ${path.join(RUNS_DIR, 'COMPARISON.md')}`);
}

function fmt(n, digits = 1) {
  return n === null || n === undefined || Number.isNaN(n) ? '—' : n.toFixed(digits);
}

function renderMarkdown(perBackend, judgeResults) {
  let md = `# S1 Comparison Report\n\nGenerated ${new Date().toISOString()}\n\n`;
  md += `Objective, code-checked scoring across backends. This is decision-grade data, but it is NOT a substitute for the human blind A/B (\`node abtest.mjs\`).\n\n`;

  md += `## Aggregate\n\n`;
  const undiarizedCount = perBackend[0]?.aggregate.undiarizedMeetings || 0;
  if (undiarizedCount > 0) {
    md += `_Note: ${undiarizedCount} of ${perBackend[0].aggregate.total} fixture meeting(s) have no diarized speakers (this fixture set's "Metro2"), so owner-attribution validity is computed only over the remaining ${perBackend[0].aggregate.diarizedMeetings} diarized meeting(s) — see per-meeting detail for the undiarized meeting's raw (unverifiable) owner count._\n\n`;
  }
  md +=
    '| Backend | N | OK | Failed | Format failures | Citations (valid/total) | Citation validity % | Owner attribution valid % (n) | Grounded name mentions % | Avg section completeness % | Avg elapsed ms | Avg latency ms (MLX) | Avg peak RSS MB (MLX) |\n';
  md += '|---|---|---|---|---|---|---|---|---|---|---|---|---|\n';
  for (const { label, aggregate: a } of perBackend) {
    md += `| ${label} | ${a.total} | ${a.succeeded} | ${a.failed} | ${a.formatFailures} | ${a.validCitations}/${a.totalCitations} | ${fmt(a.citationValidityPct)} | ${fmt(a.attributionValidityPct)} (${a.totalAttributionMentions}) | ${fmt(a.groundedMentionRatePct)} | ${fmt(a.avgSectionCompletenessPct)} | ${fmt(a.avgElapsedMs, 0)} | ${fmt(a.avgLatencyMs, 0)} | ${fmt(a.avgPeakRssMb, 0)} |\n`;
  }

  md += `\n## Per-meeting detail\n\n`;
  for (const { label, perMeeting } of perBackend) {
    md += `\n### ${label}\n\n`;
    md += '| Meeting | OK | Chars | Citations valid/unmatched/OOR | Attribution known/unknown | Sections present/expected | Format failure |\n';
    md += '|---|---|---|---|---|---|---|\n';
    for (const m of perMeeting) {
      if (!m.ok) {
        md += `| ${m.title} | FAIL | — | — | — | — | ${m.formatFailure}: ${m.formatFailureDetail || ''} |\n`;
        continue;
      }
      const attributionCell =
        m.attribution.realSpeakerCount === 0
          ? `n/a (undiarized: ${m.attribution.totalMentions} owner(s) unverifiable)`
          : `${m.attribution.known}/${m.attribution.unknown}`;
      md += `| ${m.title} | ok | ${m.textLength} | ${m.citations.valid}/${m.citations.unmatched}/${m.citations.outOfRange} | ${attributionCell} | ${m.sections.present}/${m.sections.expected} | ${m.formatFailure || '—'} |\n`;
    }
  }

  if (judgeResults) {
    md += `\n## ADVISORY — automated pairwise judge (\`claude -p\`, blind A/B)\n\n`;
    md += `**This is advisory only, not the S1 pass bar.** The human blind A/B (\`node abtest.mjs\`) is the real gate.\n\n`;
    md += '| Pair | Candidate better | Baseline better | Tie | Unjudged |\n|---|---|---|---|---|\n';
    for (const r of judgeResults) {
      md += `| ${r.pairLabel} | ${r.tally.candidate_better} | ${r.tally.baseline_better} | ${r.tally.tie} | ${r.tally.unjudged} |\n`;
    }
  }

  return md;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

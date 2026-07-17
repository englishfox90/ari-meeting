// judge.mjs — OPTIONAL, ADVISORY pairwise blind judge using the `claude` CLI
// in print mode (`claude -p`). This is NOT the S1 gate — the human blind A/B
// via abtest.mjs is. This exists only to give a second, automated data point
// when the `claude` CLI happens to be on PATH; if it isn't, callers should
// skip this silently (see compare.mjs).
//
// For each meeting present in both run dirs, shows the judge two anonymized
// summaries (randomized A/B per meeting, same mechanism as abtest.mjs) and
// asks for a single-line verdict we can parse deterministically. We do not
// fabricate a verdict if the CLI call fails or returns unparseable output —
// that meeting is recorded as `judged: false` with the raw error/output kept
// for inspection.

import { spawnSync } from 'node:child_process';

export function claudeCliAvailable() {
  const res = spawnSync('claude', ['--version'], { stdio: 'ignore' });
  return res.status === 0;
}

const VERDICT_LINE_RE = /^VERDICT:\s*(A|B|TIE)\s*$/im;

function buildJudgePrompt(title, summaryA, summaryB) {
  return `You are an impartial judge comparing two AI-generated meeting summaries of the SAME real meeting ("${title}"). Both summarize the same source transcript; you do not have the transcript itself, so judge only on internal coherence, structure, specificity, and usefulness as a meeting record.

Do not guess which model produced which summary — they are anonymized.

--- Summary A ---
${summaryA}

--- Summary B ---
${summaryB}

Which summary is the better meeting summary? Consider: does it look complete and well-structured, does it read as specific and grounded rather than vague, does it avoid inventing details, and would a person who missed the meeting find it useful?

Respond with a brief (2-4 sentence) explanation, then end your response with EXACTLY one line in this format (no other text on that line):
VERDICT: A
or
VERDICT: B
or
VERDICT: TIE`;
}

/**
 * Run one blind judged comparison for a single meeting's two summaries.
 * Returns { judged: true, verdict: 'A'|'B'|'TIE', reasoning } or
 * { judged: false, error }.
 */
function judgeOne(title, summaryA, summaryB, opts = {}) {
  const prompt = buildJudgePrompt(title, summaryA, summaryB);
  const res = spawnSync('claude', ['-p', prompt], {
    encoding: 'utf8',
    timeout: opts.timeoutMs || 120_000,
    maxBuffer: 20 * 1024 * 1024,
  });

  if (res.error) {
    return { judged: false, error: `claude CLI spawn error: ${res.error.message}` };
  }
  if (res.status !== 0) {
    return { judged: false, error: `claude CLI exited ${res.status}: ${(res.stderr || '').slice(0, 500)}` };
  }
  const output = (res.stdout || '').trim();
  const match = output.match(VERDICT_LINE_RE);
  if (!match) {
    return { judged: false, error: `Could not parse VERDICT line from claude output`, rawOutput: output.slice(0, 1000) };
  }
  return { judged: true, verdict: match[1].toUpperCase(), reasoning: output };
}

/**
 * Blind-judge every meeting present in both run maps
 * (Map<meetingId, record> as produced by compare.mjs's loadRunDir).
 * Labeled `baselineDir`/`candidateDir` are names only, for reporting — the
 * judge never sees which is which. Returns
 * { pairLabel, results: [{meetingId, title, judged, verdict, baselineIsA, ...}],
 *   tally: {baseline_better, candidate_better, tie, unjudged} }.
 */
export function judgePairBlind(baselineLabel, candidateLabel, baseline, candidate, opts = {}) {
  const meetingIds = [...baseline.keys()].filter((id) => candidate.has(id));
  const results = [];

  for (const meetingId of meetingIds) {
    const baseRec = baseline.get(meetingId);
    const candRec = candidate.get(meetingId);
    if (!baseRec.ok || !candRec.ok) {
      results.push({ meetingId, title: baseRec.title, judged: false, error: 'one side failed to generate' });
      continue;
    }
    const baselineIsA = Math.random() < 0.5;
    const slotA = baselineIsA ? baseRec.text : candRec.text;
    const slotB = baselineIsA ? candRec.text : baseRec.text;

    const outcome = judgeOne(baseRec.title, slotA, slotB, opts);
    if (!outcome.judged) {
      results.push({ meetingId, title: baseRec.title, judged: false, error: outcome.error });
      continue;
    }

    let verdict; // from candidate's perspective
    if (outcome.verdict === 'TIE') verdict = 'tie';
    else if ((outcome.verdict === 'A' && !baselineIsA) || (outcome.verdict === 'B' && baselineIsA)) verdict = 'candidate_better';
    else verdict = 'baseline_better';

    results.push({
      meetingId,
      title: baseRec.title,
      judged: true,
      baselineIsA,
      rawVerdict: outcome.verdict,
      verdict,
      reasoning: outcome.reasoning,
    });
  }

  const judgedResults = results.filter((r) => r.judged);
  const tally = {
    candidate_better: judgedResults.filter((r) => r.verdict === 'candidate_better').length,
    baseline_better: judgedResults.filter((r) => r.verdict === 'baseline_better').length,
    tie: judgedResults.filter((r) => r.verdict === 'tie').length,
    unjudged: results.length - judgedResults.length,
    total: results.length,
  };

  return { pairLabel: `${candidateLabel} vs ${baselineLabel}`, baselineLabel, candidateLabel, results, tally };
}

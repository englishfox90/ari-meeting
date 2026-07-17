/**
 * Extract playable timestamp references from a generated summary.
 *
 * The summarizer is fed a transcript whose lines are prefixed with real
 * `[MM:SS]` markers (see buildSummaryTranscriptPayload), so any `[MM:SS]` /
 * `[H:MM:SS]` token the model echoes back corresponds to a real recording
 * offset. Newer summaries cite moments with the canonical `@ref(MM:SS)` /
 * `@ref(H:MM:SS)` marker instead (see summary-ref-badge-plugin.ts, which
 * renders these inline as clickable badges); both forms are supported so
 * older saved summaries keep working. We still validate every candidate
 * against the actual recording duration before offering it as a link — never
 * surface an invented moment (No-Fake-State).
 */

export interface SummaryMoment {
  /** Offset into the recording, in seconds. */
  seconds: number;
  /** Canonical label, e.g. "2:15" or "1:02:15". */
  label: string;
}

/** A single timestamp token found in a string, with its position in that string. */
export interface TimestampToken {
  /** Index (in the searched string) where the full token starts. */
  index: number;
  /** Length of the full matched token (e.g. `@ref(01:14)` or `[01:14]`). */
  length: number;
  /** Offset into the recording, in seconds. */
  seconds: number;
  /** Canonical label, e.g. "2:15" or "1:02:15". */
  label: string;
}

// New canonical marker: @ref(M:SS) / @ref(MM:SS) / @ref(H:MM:SS).
const REF_MARKER_RE = /@ref\((\d{1,2}):([0-5]\d)(?::([0-5]\d))?\)/g;

// Backward-compat: bare bracket form used by older summaries.
// Requires literal square brackets, so ISO dates / plain numbers never match.
const BRACKET_TIMESTAMP_RE = /\[(\d{1,2}):([0-5]\d)(?::([0-5]\d))?\]/g;

function formatLabel(totalSeconds: number): string {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  if (h > 0) {
    return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  }
  return `${m}:${s.toString().padStart(2, '0')}`;
}

function secondsFromMatch(match: RegExpMatchArray): number {
  const hasHours = match[3] !== undefined;
  const a = Number(match[1]);
  const b = Number(match[2]);
  const c = hasHours ? Number(match[3]) : 0;
  return hasHours ? a * 3600 + b * 60 + c : a * 60 + b;
}

/**
 * Find every `@ref(...)` and bracket-form timestamp token in a string, in
 * document order. This is the single source of parsing truth shared by the
 * "Referenced moments" strip (`extractSummaryMoments`) and the inline badge
 * decoration plugin (`summary-ref-badge-plugin.ts`) — no duration filtering
 * happens here, callers validate against real recording duration themselves.
 */
export function matchTimestampTokens(text: string): TimestampToken[] {
  const tokens: TimestampToken[] = [];

  for (const match of text.matchAll(REF_MARKER_RE)) {
    const seconds = secondsFromMatch(match);
    tokens.push({
      index: match.index ?? 0,
      length: match[0].length,
      seconds,
      label: formatLabel(seconds),
    });
  }

  for (const match of text.matchAll(BRACKET_TIMESTAMP_RE)) {
    const seconds = secondsFromMatch(match);
    tokens.push({
      index: match.index ?? 0,
      length: match[0].length,
      seconds,
      label: formatLabel(seconds),
    });
  }

  tokens.sort((a, b) => a.index - b.index);
  return tokens;
}

/** Deep-walk any summary payload shape, concatenating every string value. */
function collectStrings(value: unknown, out: string[], depth = 0): void {
  if (depth > 12 || value == null) return;
  if (typeof value === 'string') {
    out.push(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, out, depth + 1);
    return;
  }
  if (typeof value === 'object') {
    for (const v of Object.values(value as Record<string, unknown>)) {
      collectStrings(v, out, depth + 1);
    }
  }
}

/**
 * Pull the unique, in-range timestamps a summary references.
 *
 * @param summaryData  The summary payload (markdown, BlockNote JSON, or legacy).
 * @param durationSeconds  Real recording duration; 0/unknown yields no moments.
 */
export function extractSummaryMoments(
  summaryData: unknown,
  durationSeconds: number,
): SummaryMoment[] {
  if (!summaryData || !Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return [];
  }

  const strings: string[] = [];
  collectStrings(summaryData, strings);
  const haystack = strings.join('\n');

  // Small tolerance so a final-second reference near the tail still validates.
  const maxSeconds = durationSeconds + 2;
  const seen = new Set<number>();
  const moments: SummaryMoment[] = [];

  for (const token of matchTimestampTokens(haystack)) {
    const { seconds, label } = token;
    if (seconds < 0 || seconds > maxSeconds) continue; // out of range → drop
    if (seen.has(seconds)) continue;
    seen.add(seconds);
    moments.push({ seconds, label });
  }

  moments.sort((x, y) => x.seconds - y.seconds);
  return moments;
}

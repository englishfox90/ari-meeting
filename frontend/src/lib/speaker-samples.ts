/**
 * Speaker sample selection (F1 identification evidence).
 *
 * Groups a meeting's transcript segments by their diarized `speakerId` and picks
 * a few representative lines per speaker so the user has something to READ and
 * HEAR when deciding who a "Speaker N" actually is. Pure functions over the
 * segments already loaded in the transcript view — no backend call needed.
 *
 * No-Fake-State: samples are the real transcribed text at real timestamps. When
 * a speaker has no attributed lines, the result is simply empty.
 */

import type { TranscriptSegmentData } from '@/types';

export interface SpeakerSample {
  /** The transcript segment id (stable key). */
  id: string;
  /** The transcribed text of the line. */
  text: string;
  /** Recording-relative start time in seconds (drives clip playback). */
  startSeconds: number;
}

/** Format a recording-relative second offset as `MM:SS`. */
export function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return `${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
}

/**
 * Pick up to `max` representative lines a speaker said. We prefer the most
 * substantive (longest) lines — the best voiceprint evidence — then present
 * them in chronological order so the timestamps read naturally.
 */
export function selectSpeakerSamples(
  segments: TranscriptSegmentData[],
  speakerId: string,
  max = 5,
): SpeakerSample[] {
  const mine = segments.filter(
    (s) => s.speakerId === speakerId && s.text.trim().length > 0,
  );
  return [...mine]
    .sort((a, b) => b.text.trim().length - a.text.trim().length)
    .slice(0, max)
    .sort((a, b) => (a.timestamp ?? 0) - (b.timestamp ?? 0))
    .map((s) => ({
      id: s.id,
      text: s.text.trim(),
      startSeconds: s.timestamp ?? 0,
    }));
}

/** Build a speakerId → representative-samples map for every diarized speaker. */
export function groupSamplesBySpeaker(
  segments: TranscriptSegmentData[],
  max = 5,
): Map<string, SpeakerSample[]> {
  const ids = new Set<string>();
  for (const s of segments) {
    if (s.speakerId) ids.add(s.speakerId);
  }
  const map = new Map<string, SpeakerSample[]>();
  for (const id of ids) {
    map.set(id, selectSpeakerSamples(segments, id, max));
  }
  return map;
}

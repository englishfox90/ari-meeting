/**
 * Speaker Attribution (F1) Service
 *
 * Wraps the Rust `diarize_meeting` / `speaker_*` Tauri commands. Pure 1-to-1
 * invoke wrappers - camelCase argument keys (Tauri v2 maps them onto the
 * snake_case Rust params) and camelCase return shapes matching the
 * `#[serde(rename_all = "camelCase")]` structs on the Rust side. Guards against
 * running outside the Tauri runtime (plain `pnpm run dev` in a browser has no
 * backend).
 */

import { invoke } from '@tauri-apps/api/core';

function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean(window.__TAURI_INTERNALS__);
}

/** The enrollment lifecycle of a diarized speaker. */
export type EnrollmentState = 'provisional' | 'confirmed' | 'owner';

/** Ranking tier for a match suggestion (honest, backend-computed). */
export type MatchTier = 'auto' | 'suggest' | 'anonymous';

/** Result of the offline diarization pass over a meeting. */
export interface DiarizeResult {
  clustersFound: number;
  autoAssigned: number;
  provisionalCreated: number;
  ownerEnrolled: number;
  transcriptsStamped: number;
}

/** One diarized speaker within a meeting, with any resolved identity. */
export interface MeetingSpeaker {
  speakerId: string;
  personId: string | null;
  personName: string | null;
  label: string | null;
  enrollmentState: EnrollmentState;
  segmentCount: number;
}

/**
 * Result of assigning a speaker to a person (P1). The backend may consolidate the
 * assigned voiceprint into a pre-existing canonical row for that person, so
 * `speakerId` is the CANONICAL speaker the identity now lives on (may differ from
 * the id passed in). `retroRelabeled` is how many other historical provisional
 * speakers were auto-merged onto the canonical by retroactive relabel.
 */
export interface SpeakerAssignResult {
  speakerId: string;
  retroRelabeled: number;
}

/** A ranked "looks like {person}" suggestion for a speaker. */
export interface SpeakerMatchSuggestion {
  personId: string;
  personName: string;
  score: number;
  tier: MatchTier;
}

/**
 * A resolved speaker label for a single transcript row. Only rows with a
 * confidently-resolved speaker are returned by the backend — unknown/unassigned
 * rows are omitted, never fabricated.
 */
export interface MeetingSpeakerLabel {
  transcriptId: string;
  speakerName: string;
}

/** Honest counts of what resetting the owner voiceprint cleared. */
export interface ResetOwnerVoiceprintResult {
  transcriptsUnstamped: number;
  segmentsDeleted: number;
  voiceprintsDeleted: number;
}

export class SpeakerService {
  /**
   * Whether the app is running inside the Tauri desktop shell (vs. a plain
   * browser dev server, which has no backend).
   */
  isAvailable(): boolean {
    return isTauriAvailable();
  }

  /**
   * Run the offline diarization pass over a meeting. Slow — intended to be
   * fired-and-forgotten after a recording is saved. Returns honest counts of
   * what was found/assigned.
   */
  async diarizeMeeting(meetingId: string): Promise<DiarizeResult> {
    return invoke<DiarizeResult>('diarize_meeting', { meetingId });
  }

  /**
   * The diarized speakers for a meeting, with any resolved person identity and
   * per-speaker segment counts. Empty when diarization has not run.
   */
  async listForMeeting(meetingId: string): Promise<MeetingSpeaker[]> {
    return invoke<MeetingSpeaker[]>('speaker_list_for_meeting', { meetingId });
  }

  /**
   * Assign a diarized speaker to a known person (confirm-before-enroll). The
   * user always chooses; nothing auto-assigns through this path. Returns the
   * canonical speaker the identity was consolidated onto and how many historical
   * provisional speakers were retroactively relabeled onto it.
   */
  async assignToPerson(speakerId: string, personId: string): Promise<SpeakerAssignResult> {
    return invoke<SpeakerAssignResult>('speaker_assign_to_person', { speakerId, personId });
  }

  /**
   * Ranked (desc) match suggestions for a speaker's voice embedding. May be
   * empty — an empty list is an honest "no close matches".
   */
  async matchSuggestions(speakerId: string): Promise<SpeakerMatchSuggestion[]> {
    return invoke<SpeakerMatchSuggestion[]>('speaker_match_suggestions', { speakerId });
  }

  /**
   * Resolved speaker labels for a meeting's transcript rows, keyed by transcript
   * id. Only rows with a confidently-resolved speaker are returned (unknown rows
   * are omitted). Empty when diarization has not run or produced no matches.
   * Returns `[]` outside the Tauri runtime so callers degrade gracefully.
   */
  async getMeetingSpeakerLabels(meetingId: string): Promise<MeetingSpeakerLabel[]> {
    if (!this.isAvailable()) return [];
    return invoke<MeetingSpeakerLabel[]>('meeting_speaker_labels', { meetingId });
  }

  /**
   * Manually reassign one transcript line's speaker — the per-line correction
   * for a merged/mis-attributed segment or a wrongly-matched cluster. Only this
   * transcript row is touched (no centroid/segment/other-row side effects). Pass
   * `speakerId: null` to clear the line back to unattributed. Returns `false` if
   * no matching row was found (bad transcriptId/meetingId pairing).
   */
  async reassignTranscriptLine(
    meetingId: string,
    transcriptId: string,
    speakerId: string | null
  ): Promise<boolean> {
    return invoke<boolean>('speaker_reassign_transcript_line', {
      meetingId,
      transcriptId,
      speakerId,
    });
  }

  /**
   * Reset the owner's persistent voiceprint — recovery when an in-person meeting
   * folded someone else's voice into it. Deletes the saved voice signature (and its
   * segments/stamps) everywhere; the next diarization run rebuilds it from that
   * meeting's mic. Returns honest counts of what was cleared.
   */
  async resetOwnerVoiceprint(): Promise<ResetOwnerVoiceprintResult> {
    return invoke<ResetOwnerVoiceprintResult>('speaker_reset_owner_voiceprint');
  }
}

// Export singleton instance
export const speakerService = new SpeakerService();

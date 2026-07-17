'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  speakerService,
  type MeetingSpeaker,
} from '@/services/speakerService';
import { voiceprintService } from '@/services/voiceprintService';
import type { ResolvedSpeaker } from '@/components/VirtualizedTranscriptView';

export interface UseMeetingSpeakersResult {
  speakers: MeetingSpeaker[];
  isLoading: boolean;
  /** True once a fetch has completed (so callers can distinguish "empty" from "not-yet-loaded"). */
  hasLoaded: boolean;
  /** Resolve a speakerId to display-ready info; null when unknown. */
  resolveSpeaker: (speakerId: string) => ResolvedSpeaker | null;
  /** Honest display name for a speaker: personName ?? label ?? "Speaker N". */
  displayNameFor: (speakerId: string) => string;
  /** Speakers still awaiting confirmation. */
  provisionalCount: number;
  /** Speakers with no person assigned yet. */
  unassignedCount: number;
  refetch: () => Promise<void>;
}

/**
 * Fetches the diarized speakers for a meeting and derives stable, honest
 * display names. "Speaker N" is assigned from the backend's stable ordering
 * ONLY when a speaker has neither a linked person nor a label — never a fake
 * identity. Degrades to an empty list outside the Tauri runtime.
 */
export function useMeetingSpeakers(meetingId?: string): UseMeetingSpeakersResult {
  const [speakers, setSpeakers] = useState<MeetingSpeaker[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [hasLoaded, setHasLoaded] = useState(false);

  const refetch = useCallback(async () => {
    if (!meetingId || !speakerService.isAvailable()) {
      setSpeakers([]);
      setHasLoaded(true);
      return;
    }
    setIsLoading(true);
    try {
      const result = await speakerService.listForMeeting(meetingId);
      setSpeakers(result);
      // Warm the shared voiceprint-signature cache so identicons (chips, review
      // panel, assign dialog) can resolve by speaker id. Fire-and-forget: a
      // missing signature degrades to a placeholder, never blocks the list.
      void voiceprintService.fetchMeetingSignatures(meetingId, { force: true });
    } catch (reason) {
      // Honest failure: no speakers surfaced rather than fake chips.
      console.error('Failed to load speakers for meeting:', reason);
      setSpeakers([]);
    } finally {
      setIsLoading(false);
      setHasLoaded(true);
    }
  }, [meetingId]);

  useEffect(() => {
    setHasLoaded(false);
    void refetch();
  }, [refetch]);

  // Stable Speaker-N numbering from backend order, only for unlabeled speakers.
  const displayNames = useMemo(() => {
    const map = new Map<string, string>();
    let unlabeledCounter = 0;
    for (const s of speakers) {
      const named = s.personName ?? s.label;
      if (named) {
        map.set(s.speakerId, named);
      } else {
        unlabeledCounter += 1;
        map.set(s.speakerId, `Speaker ${unlabeledCounter}`);
      }
    }
    return map;
  }, [speakers]);

  const stateById = useMemo(() => {
    const map = new Map<string, MeetingSpeaker>();
    for (const s of speakers) map.set(s.speakerId, s);
    return map;
  }, [speakers]);

  const displayNameFor = useCallback(
    (speakerId: string) => displayNames.get(speakerId) ?? 'Unknown speaker',
    [displayNames],
  );

  const resolveSpeaker = useCallback(
    (speakerId: string): ResolvedSpeaker | null => {
      const s = stateById.get(speakerId);
      if (!s) return null;
      return { displayName: displayNames.get(speakerId) ?? 'Unknown speaker', state: s.enrollmentState };
    },
    [stateById, displayNames],
  );

  const provisionalCount = useMemo(
    () => speakers.filter((s) => s.enrollmentState === 'provisional').length,
    [speakers],
  );
  const unassignedCount = useMemo(
    () => speakers.filter((s) => s.personId === null).length,
    [speakers],
  );

  return {
    speakers,
    isLoading,
    hasLoaded,
    resolveSpeaker,
    displayNameFor,
    provisionalCount,
    unassignedCount,
    refetch,
  };
}

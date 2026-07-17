'use client';

// MeetingProcessingContext — the single owner of the post-recording pipeline.
//
// When a recording stops, `useRecordingStop` calls `beginProcessing(meetingId)`.
// This context then runs diarization FIRST and, only once it completes, the
// summary — so the summary always sees resolved speaker labels (fixing the old
// race where the summary was generated on unlabeled transcript). The pipeline
// lives here, high in the provider tree, so it keeps running when the user
// navigates away from the meeting; per-meeting phase is exposed for subtle,
// non-blocking progress UI (a banner on the meeting page + a sidebar dot).
//
// Product decisions encoded here:
//  - ALWAYS WAIT: the summary never runs until diarization completes. There is
//    no unlabeled fallback. A diarization HARD FAILURE stops at an error phase
//    with a Retry affordance (routed to the failed stage) — it never silently
//    summarizes on unlabeled text.
//  - Diarization being UNAVAILABLE (no Tauri / feature off) is not a failure:
//    we skip straight to the summary (nothing to wait for).

import React, {
  createContext,
  useCallback,
  useContext,
  useRef,
  useState,
} from 'react';
import { useSidebar } from '@/components/Sidebar/SidebarProvider';
import { speakerService } from '@/services/speakerService';
import { runSummary } from '@/lib/summary/summaryOrchestrator';

export type ProcessingPhase = 'diarizing' | 'summarizing' | 'complete' | 'error';
export type ProcessingStage = 'diarization' | 'summary';

export interface ProcessingEntry {
  phase: ProcessingPhase;
  /** Which step the current phase / error belongs to (routes Retry). */
  stage: ProcessingStage;
  error?: string;
  /** Whether to proceed into summary after diarization completes. */
  autoSummary: boolean;
}

interface MeetingProcessingContextValue {
  /** Kick off (or no-op if already active) the diarize→summary pipeline. */
  beginProcessing: (meetingId: string, opts: { autoSummary: boolean }) => void;
  /** Re-run from the failed stage after an error. */
  retry: (meetingId: string) => void;
  /** Synchronous read of a meeting's current phase (undefined if none). */
  getState: (meetingId: string) => ProcessingEntry | undefined;
  /** The full map — subscribe by reading it in a component (drives re-render). */
  states: Map<string, ProcessingEntry>;
}

const MeetingProcessingContext = createContext<MeetingProcessingContextValue | null>(null);

export const useMeetingProcessing = (): MeetingProcessingContextValue => {
  const ctx = useContext(MeetingProcessingContext);
  if (!ctx) {
    throw new Error('useMeetingProcessing must be used within a MeetingProcessingProvider');
  }
  return ctx;
};

const NON_TERMINAL: ProcessingPhase[] = ['diarizing', 'summarizing'];

export function MeetingProcessingProvider({ children }: { children: React.ReactNode }) {
  const { startSummaryPolling } = useSidebar();
  const [states, setStates] = useState<Map<string, ProcessingEntry>>(new Map());
  // Ref mirror so the async pipeline reads fresh state without stale closures.
  const statesRef = useRef<Map<string, ProcessingEntry>>(states);

  const setEntry = useCallback((meetingId: string, entry: ProcessingEntry) => {
    const next = new Map(statesRef.current);
    next.set(meetingId, entry);
    statesRef.current = next;
    setStates(next);
  }, []);

  // The diarize→summary pipeline. `startFrom` lets Retry resume at the summary
  // step without re-running a diarization that already succeeded.
  const runPipeline = useCallback(
    async (meetingId: string, autoSummary: boolean, startFrom: ProcessingStage = 'diarization') => {
      if (startFrom === 'diarization') {
        setEntry(meetingId, { phase: 'diarizing', stage: 'diarization', autoSummary });

        // Diarization gate. Unavailable ≠ failure: skip to summary.
        if (speakerService.isAvailable()) {
          try {
            await speakerService.diarizeMeeting(meetingId);
          } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            console.warn('Diarization failed; halting pipeline (no unlabeled fallback):', message);
            setEntry(meetingId, { phase: 'error', stage: 'diarization', error: message, autoSummary });
            return;
          }
        } else {
          console.log('Speaker diarization unavailable; proceeding directly to summary.');
        }

        // ALWAYS WAIT satisfied: diarization is done. If auto-summary is off,
        // stop here at a non-error terminal phase — a later manual summary will
        // still pick up the labels we just produced.
        if (!autoSummary) {
          setEntry(meetingId, { phase: 'complete', stage: 'diarization', autoSummary });
          return;
        }
      }

      setEntry(meetingId, { phase: 'summarizing', stage: 'summary', autoSummary });
      try {
        await runSummary(meetingId, { startSummaryPolling });
        setEntry(meetingId, { phase: 'complete', stage: 'summary', autoSummary });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.warn('Background summary failed:', message);
        setEntry(meetingId, { phase: 'error', stage: 'summary', error: message, autoSummary });
      }
    },
    [setEntry, startSummaryPolling],
  );

  const beginProcessing = useCallback(
    (meetingId: string, opts: { autoSummary: boolean }) => {
      const existing = statesRef.current.get(meetingId);
      if (existing && NON_TERMINAL.includes(existing.phase)) {
        // Already running — idempotent guard against double-trigger.
        return;
      }
      void runPipeline(meetingId, opts.autoSummary, 'diarization');
    },
    [runPipeline],
  );

  const retry = useCallback(
    (meetingId: string) => {
      const existing = statesRef.current.get(meetingId);
      if (!existing || existing.phase !== 'error') return;
      // Resume from whichever stage failed. A summary-stage error means
      // diarization already succeeded, so don't redo it.
      const startFrom: ProcessingStage = existing.stage === 'summary' ? 'summary' : 'diarization';
      void runPipeline(meetingId, existing.autoSummary, startFrom);
    },
    [runPipeline],
  );

  const getState = useCallback((meetingId: string) => statesRef.current.get(meetingId), []);

  return (
    <MeetingProcessingContext.Provider value={{ beginProcessing, retry, getState, states }}>
      {children}
    </MeetingProcessingContext.Provider>
  );
}

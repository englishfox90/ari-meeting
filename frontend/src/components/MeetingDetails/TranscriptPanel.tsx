"use client";

import { Transcript, TranscriptSegmentData } from '@/types';
import { VirtualizedTranscriptView } from '@/components/VirtualizedTranscriptView';
import { TranscriptButtonGroup } from './TranscriptButtonGroup';
import { MeetingAudioPlayer } from './MeetingAudioPlayer';
import { useAudioPlayback } from '@/contexts/AudioPlaybackContext';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { RectangleGroupIcon } from '@heroicons/react/24/outline';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { useMeetingSpeakers } from '@/hooks/meeting-details/useMeetingSpeakers';
import { SpeakerAssignDialog } from './SpeakerAssignDialog';
import { SpeakerReviewPanel } from './SpeakerReviewPanel';
import { speakerService, type MeetingSpeaker } from '@/services/speakerService';
import { personService } from '@/services/personService';
import type { PersonSummary } from '@/types/person';
import { groupSamplesBySpeaker, selectSpeakerSamples } from '@/lib/speaker-samples';

interface TranscriptPanelProps {
  transcripts: Transcript[];
  onCopyTranscript: () => void;
  onOpenMeetingFolder: () => Promise<void>;
  onExportMeeting: () => Promise<void>;
  isRecording: boolean;
  disableAutoScroll?: boolean;

  // Optional pagination props (when using virtualization)
  usePagination?: boolean;
  segments?: TranscriptSegmentData[];
  hasMore?: boolean;
  isLoadingMore?: boolean;
  totalCount?: number;
  loadedCount?: number;
  onLoadMore?: () => void;
  hasSavedSummary?: boolean;

  // Retranscription props
  meetingId?: string;
  meetingFolderPath?: string | null;
  onRefetchTranscripts?: () => Promise<void>;
  transcriptionModel?: string | null;
  summaryModel?: string | null;
  className?: string;
  onCloseInspector?: () => void;
  /**
   * The background diarize→summary pipeline is running for this meeting. While
   * true, the manual "Identify speakers" / "Re-identify" action is disabled so
   * it can't race the pipeline's own diarization pass on the same meeting.
   */
  isBackgroundProcessing?: boolean;
  /** The pipeline is in its diarization step — show an active "Identifying…" label. */
  isBackgroundDiarizing?: boolean;
}

export function TranscriptPanel({
  transcripts,
  onCopyTranscript,
  onOpenMeetingFolder,
  onExportMeeting,
  isRecording,
  disableAutoScroll = false,
  usePagination = false,
  segments,
  hasMore,
  isLoadingMore,
  totalCount,
  loadedCount,
  onLoadMore,
  hasSavedSummary = false,
  meetingId,
  meetingFolderPath,
  onRefetchTranscripts,
  transcriptionModel,
  summaryModel,
  className,
  onCloseInspector,
  isBackgroundProcessing = false,
  isBackgroundDiarizing = false,
}: TranscriptPanelProps) {
  const transcriptCount = usePagination ? (totalCount ?? segments?.length ?? 0) : transcripts.length;

  // Convert transcripts to segments if pagination is not used but we want virtualization
  const convertedSegments = useMemo(() => {
    if (usePagination && segments) {
      return segments;
    }
    // Convert transcripts to segments for virtualization
    return transcripts.map(t => ({
      id: t.id,
      timestamp: t.audio_start_time ?? 0,
      endTime: t.audio_end_time,
      text: t.text,
      confidence: t.confidence,
      speakerId: t.speaker_id,
    }));
  }, [transcripts, usePagination, segments]);

  // ── Audio playback ↔ transcript sync ──────────────────────────────────────
  const player = useAudioPlayback();
  const [activeSegmentId, setActiveSegmentId] = useState<string | null>(null);

  // Ascending start-time index for O(log n) "which segment is playing now?".
  const startTimes = useMemo(
    () => convertedSegments.map(s => s.timestamp ?? 0),
    [convertedSegments],
  );
  const startTimesRef = useRef(startTimes);
  startTimesRef.current = startTimes;
  const segmentsRef = useRef(convertedSegments);
  segmentsRef.current = convertedSegments;

  useEffect(() => {
    if (!player) return;
    return player.subscribeTime((t) => {
      const times = startTimesRef.current;
      const segs = segmentsRef.current;
      if (times.length === 0) return;
      // Largest index whose start-time <= current time.
      let lo = 0;
      let hi = times.length - 1;
      let idx = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (times[mid] <= t) {
          idx = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      const nextId = idx >= 0 ? segs[idx].id : null;
      setActiveSegmentId((prev) => (prev === nextId ? prev : nextId));
    });
  }, [player]);

  // Jump audio to a segment's start and play (called from a timestamp click).
  const seekAndPlay = player?.seekAndPlay;
  const handleSeekToSegment = useCallback(
    (seconds: number) => { seekAndPlay?.(seconds); },
    [seekAndPlay],
  );

  // ── Speaker attribution (F1) ────────────────────────────────────────────
  const speakers = useMeetingSpeakers(meetingId);
  const [selectedSpeakerId, setSelectedSpeakerId] = useState<string | null>(null);
  const [assignDialogOpen, setAssignDialogOpen] = useState(false);
  const [reviewOpen, setReviewOpen] = useState(false);
  const [persons, setPersons] = useState<PersonSummary[]>([]);
  const [participantIds, setParticipantIds] = useState<Set<string>>(new Set());
  const [isIdentifying, setIsIdentifying] = useState(false);
  const [identifyError, setIdentifyError] = useState<string | null>(null);
  const [reassignError, setReassignError] = useState<string | null>(null);
  // When the assign dialog is opened from the review panel, we reopen the panel
  // afterwards so the user can continue tagging speakers one after another.
  const reopenReviewRef = useRef(false);

  // Real audio state for clip playback (No-Fake-State: only "ready" is playable).
  const audioAvailable = player?.status === 'ready';
  const isAudioPlaying = player?.isPlaying ?? false;

  // Per-speaker representative sample lines, derived from the loaded transcript
  // segments (real text at real timestamps — the identification evidence).
  const samplesBySpeaker = useMemo(
    () => groupSamplesBySpeaker(convertedSegments),
    [convertedSegments],
  );
  const selectedSpeakerSamples = useMemo(
    () => (selectedSpeakerId ? selectSpeakerSamples(convertedSegments, selectedSpeakerId) : []),
    [convertedSegments, selectedSpeakerId],
  );

  // Selecting a speaker chip highlights their lines (amber) and opens review.
  // A chip click is a direct review — do NOT bounce back to the review panel.
  const handleSelectSpeaker = useCallback((speakerId: string) => {
    reopenReviewRef.current = false;
    setSelectedSpeakerId(speakerId);
    setAssignDialogOpen(true);
  }, []);

  // Open the per-speaker assign dialog from the review panel, remembering to
  // reopen the panel when the dialog closes.
  const handleAssignFromReview = useCallback((speakerId: string) => {
    reopenReviewRef.current = true;
    setReviewOpen(false);
    setSelectedSpeakerId(speakerId);
    setAssignDialogOpen(true);
  }, []);

  const selectedSpeaker: MeetingSpeaker | null = useMemo(
    () => speakers.speakers.find((s) => s.speakerId === selectedSpeakerId) ?? null,
    [speakers.speakers, selectedSpeakerId],
  );

  // personId → # of OTHER speakers in this meeting already assigned to them, so
  // the picker can flag accidental repeats (the "same person for everyone" trap).
  const assignedByPerson = useMemo(() => {
    const map = new Map<string, number>();
    for (const s of speakers.speakers) {
      if (s.personId && s.speakerId !== selectedSpeakerId) {
        map.set(s.personId, (map.get(s.personId) ?? 0) + 1);
      }
    }
    return map;
  }, [speakers.speakers, selectedSpeakerId]);

  // Load persons + this meeting's participants for the assign picker.
  const reloadPersons = useCallback(async () => {
    if (!personService.isAvailable()) return;
    try {
      const [all, parts] = await Promise.all([
        personService.list(),
        meetingId ? personService.meetingParticipants(meetingId) : Promise.resolve([]),
      ]);
      setPersons(all);
      setParticipantIds(new Set(parts.map((p) => p.id)));
    } catch (reason) {
      console.error('Failed to load persons for speaker assignment:', reason);
    }
  }, [meetingId]);

  // Fetch persons lazily, only when there are speakers to assign.
  useEffect(() => {
    if (speakers.speakers.length === 0) return;
    void reloadPersons();
  }, [reloadPersons, speakers.speakers.length]);

  // Manual diarization — diarize_meeting clears prior results first (idempotent),
  // so a re-run is always safe to offer once transcripts exist.
  const canIdentify =
    speakerService.isAvailable() &&
    Boolean(meetingId) &&
    speakers.hasLoaded &&
    transcriptCount > 0 &&
    !isRecording;

  const handleIdentifySpeakers = useCallback(async () => {
    if (!meetingId) return;
    setIsIdentifying(true);
    setIdentifyError(null);
    try {
      await speakerService.diarizeMeeting(meetingId);
      // Re-stamping assigns fresh speaker ids to transcript rows — reload both.
      await Promise.all([speakers.refetch(), onRefetchTranscripts?.()]);
    } catch (reason) {
      setIdentifyError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setIsIdentifying(false);
    }
  }, [meetingId, speakers, onRefetchTranscripts]);

  const handleAssigned = useCallback(async () => {
    await Promise.all([speakers.refetch(), reloadPersons()]);
  }, [speakers, reloadPersons]);

  const hasSpeakers = speakers.speakers.length > 0;

  // Per-line speaker correction (F1 manual override) — options for the reassign
  // picker rendered on each transcript line.
  const reassignOptions = useMemo(
    () => speakers.speakers.map((s) => ({ speakerId: s.speakerId, displayName: speakers.displayNameFor(s.speakerId) })),
    [speakers],
  );

  const handleReassignLine = useCallback(
    async (transcriptId: string, newSpeakerId: string | null) => {
      if (!meetingId) return;
      setReassignError(null);
      try {
        await speakerService.reassignTranscriptLine(meetingId, transcriptId, newSpeakerId);
        await Promise.all([speakers.refetch(), onRefetchTranscripts?.()]);
      } catch (reason) {
        setReassignError(reason instanceof Error ? reason.message : String(reason));
      }
    },
    [meetingId, speakers, onRefetchTranscripts],
  );

  // Reset the owner voiceprint (global recovery when an in-person meeting folded
  // someone else's voice into it). Refetches so the current meeting reflects the
  // cleared stamps; the voiceprint rebuilds on the next diarization run.
  const handleResetVoiceprint = useCallback(async () => {
    if (!speakerService.isAvailable()) return;
    await speakerService.resetOwnerVoiceprint();
    await Promise.all([speakers.refetch(), onRefetchTranscripts?.()]);
  }, [speakers, onRefetchTranscripts]);

  return (
    <aside
      aria-label="Meeting inspector"
      className={cn(
        'min-w-0 shrink-0 flex-col border-l border-border bg-card xl:bg-secondary/35',
        className,
      )}
    >
      <MeetingAudioPlayer />

      <div className="border-b border-border px-4 py-4">
        <div className="mb-3 flex items-end justify-between gap-3">
          <div>
            <p className="app-eyebrow">Source record</p>
            <h2 className="mt-1 text-base font-semibold tracking-[-0.03em]">Transcript</h2>
          </div>
          <div className="flex items-center gap-2">
            {onCloseInspector && (
              <Button type="button" variant="ghost" size="icon" className="xl:hidden" onClick={onCloseInspector} aria-label="Close inspector">
                <RectangleGroupIcon className="size-4" aria-hidden="true" />
              </Button>
            )}
            <span className="font-mono text-[0.6875rem] text-muted-foreground">
              {usePagination ? (totalCount ?? convertedSegments.length) : convertedSegments.length} segments
            </span>
          </div>
        </div>
        <TranscriptButtonGroup
          transcriptCount={usePagination ? (totalCount ?? convertedSegments.length) : (transcripts?.length || 0)}
          onCopyTranscript={onCopyTranscript}
          onOpenMeetingFolder={onOpenMeetingFolder}
          onExportMeeting={onExportMeeting}
          meetingId={meetingId}
          meetingFolderPath={meetingFolderPath}
          onRefetchTranscripts={onRefetchTranscripts}
        />
        <div className="mt-3 grid gap-1.5 border-t border-border/70 pt-3 text-xs text-muted-foreground">
          <p>
            <span className="font-medium text-foreground">Source:</span>{' '}
            {meetingFolderPath ? 'Recording folder linked' : 'No recording folder linked'}
          </p>
          <p>
            <span className="font-medium text-foreground">Local transcription:</span>{' '}
            {transcriptionModel || 'Not configured'}
          </p>
          {hasSavedSummary && summaryModel ? (
            <p>
              <span className="font-medium text-foreground">Summary model:</span>{' '}
              {summaryModel}
            </p>
          ) : null}
        </div>

        {/* Speaker attribution (F1) — honest, real-state affordances only. */}
        {(hasSpeakers || canIdentify || isIdentifying || isBackgroundDiarizing) && (
          <div className="mt-3 border-t border-border/70 pt-3">
            {hasSpeakers ? (
              <div className="flex items-center justify-between gap-3">
                <p className="text-xs text-muted-foreground">
                  <span className="font-medium text-foreground">{speakers.speakers.length}</span>{' '}
                  {speakers.speakers.length === 1 ? 'speaker' : 'speakers'}
                  {speakers.unassignedCount > 0 ? (
                    <span> · {speakers.unassignedCount} unassigned</span>
                  ) : null}
                </p>
                <div className="flex items-center gap-1.5">
                  {canIdentify && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="h-7 text-xs"
                      disabled={isIdentifying || isBackgroundProcessing}
                      onClick={handleIdentifySpeakers}
                    >
                      {isIdentifying || isBackgroundDiarizing ? 'Re-identifying…' : 'Re-identify'}
                    </Button>
                  )}
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-7 gap-1.5 text-xs"
                    onClick={() => {
                      reopenReviewRef.current = false;
                      setReviewOpen(true);
                    }}
                  >
                    {speakers.provisionalCount > 0 && (
                      <span className="grid size-4 place-items-center rounded-full bg-accent text-[0.625rem] font-semibold text-accent-foreground">
                        {speakers.provisionalCount}
                      </span>
                    )}
                    Review speakers
                  </Button>
                </div>
              </div>
            ) : (
              <div className="flex items-center justify-between gap-3">
                <p className="text-xs text-muted-foreground">
                  {isBackgroundDiarizing ? 'Identifying speakers…' : 'No speakers identified yet.'}
                </p>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-7 text-xs"
                  disabled={isIdentifying || isBackgroundProcessing}
                  onClick={handleIdentifySpeakers}
                >
                  {isIdentifying || isBackgroundDiarizing ? 'Identifying…' : 'Identify speakers'}
                </Button>
              </div>
            )}
            {identifyError && (
              <p className="mt-2 text-xs text-destructive">{identifyError}</p>
            )}
            {reassignError && (
              <p className="mt-2 text-xs text-destructive">{reassignError}</p>
            )}
          </div>
        )}
      </div>

      {/* Transcript content - use virtualized view for better performance */}
      <div className="min-h-0 flex-1 overflow-hidden pb-4">
        <VirtualizedTranscriptView
          segments={convertedSegments}
          isRecording={isRecording}
          isPaused={false}
          isProcessing={false}
          isStopping={false}
          enableStreaming={false}
          showConfidence={true}
          disableAutoScroll={disableAutoScroll}
          hasMore={hasMore}
          isLoadingMore={isLoadingMore}
          totalCount={totalCount}
          loadedCount={loadedCount}
          onLoadMore={onLoadMore}
          onSeekTo={player ? handleSeekToSegment : undefined}
          activeSegmentId={activeSegmentId}
          resolveSpeaker={hasSpeakers ? speakers.resolveSpeaker : undefined}
          selectedSpeakerId={selectedSpeakerId}
          onSelectSpeaker={hasSpeakers ? handleSelectSpeaker : undefined}
          reassignOptions={hasSpeakers ? reassignOptions : undefined}
          onReassignSpeaker={hasSpeakers ? handleReassignLine : undefined}
        />
      </div>

      <SpeakerReviewPanel
        open={reviewOpen}
        onOpenChange={setReviewOpen}
        speakers={speakers.speakers}
        displayNameFor={speakers.displayNameFor}
        samplesBySpeaker={samplesBySpeaker}
        audioAvailable={audioAvailable}
        isPlaying={isAudioPlaying}
        onPlayClip={handleSeekToSegment}
        onAssign={handleAssignFromReview}
        onResetVoiceprint={handleResetVoiceprint}
      />

      <SpeakerAssignDialog
        open={assignDialogOpen}
        onOpenChange={(open) => {
          setAssignDialogOpen(open);
          if (!open) {
            setSelectedSpeakerId(null);
            // Continue the multi-speaker tagging flow if we came from the panel.
            if (reopenReviewRef.current) {
              reopenReviewRef.current = false;
              setReviewOpen(true);
            }
          }
        }}
        speaker={selectedSpeaker}
        speakerDisplayName={selectedSpeakerId ? speakers.displayNameFor(selectedSpeakerId) : ''}
        persons={persons}
        participantIds={participantIds}
        onAssigned={handleAssigned}
        samples={selectedSpeakerSamples}
        audioAvailable={audioAvailable}
        isPlaying={isAudioPlaying}
        onPlayClip={handleSeekToSegment}
        assignedByPerson={assignedByPerson}
      />
    </aside>
  );
}

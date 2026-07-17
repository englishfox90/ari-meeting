'use client';

import { useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import type { MeetingSpeaker } from '@/services/speakerService';
import type { SpeakerSample } from '@/lib/speaker-samples';
import { SpeakerSampleList } from './SpeakerSampleList';
import { VoiceprintGlyph } from './VoiceprintGlyph';

const STATE_LABEL: Record<MeetingSpeaker['enrollmentState'], string> = {
  provisional: 'Provisional',
  confirmed: 'Confirmed',
  owner: 'Owner',
};

export interface SpeakerReviewPanelProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Every diarized speaker in this meeting. */
  speakers: MeetingSpeaker[];
  /** Honest display name (personName ?? label ?? "Speaker N"). */
  displayNameFor: (speakerId: string) => string;
  /** Representative lines per speaker, for read/hear evidence. */
  samplesBySpeaker: Map<string, SpeakerSample[]>;
  /** Whether a playable recording exists. */
  audioAvailable: boolean;
  /** Whether the shared meeting player is currently playing. */
  isPlaying: boolean;
  /** Seek + play a clip so the voice can be heard. */
  onPlayClip: (seconds: number) => void;
  /** Open the full assign dialog for one speaker. */
  onAssign: (speakerId: string) => void;
  /**
   * Reset the owner's persistent voiceprint (global recovery). When provided, a
   * reset control shows in the footer. Resolves after the reset + any refetch.
   */
  onResetVoiceprint?: () => Promise<void>;
}

/**
 * The primary "who is everyone?" surface: one card per diarized speaker, each
 * showing the honest identity state, real segment count, a couple of sample
 * lines you can play to hear the voice, and an Assign action. No fabricated
 * names — provisional speakers read as "Speaker N" until the user confirms.
 */
export function SpeakerReviewPanel({
  open,
  onOpenChange,
  speakers,
  displayNameFor,
  samplesBySpeaker,
  audioAvailable,
  isPlaying,
  onPlayClip,
  onAssign,
  onResetVoiceprint,
}: SpeakerReviewPanelProps) {
  const [confirmingReset, setConfirmingReset] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [resetError, setResetError] = useState<string | null>(null);

  const handleReset = async () => {
    if (!onResetVoiceprint) return;
    setResetting(true);
    setResetError(null);
    try {
      await onResetVoiceprint();
      setConfirmingReset(false);
    } catch (reason) {
      setResetError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setResetting(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-5xl gap-0 p-0">
        <DialogHeader className="border-b border-border px-5 py-4">
          <DialogTitle className="text-base">Review speakers</DialogTitle>
          <DialogDescription className="text-xs">
            {speakers.length === 0
              ? 'No speakers identified yet.'
              : `${speakers.length} speaker${speakers.length === 1 ? '' : 's'} in this meeting. Play a clip to hear each voice, then assign a person.`}
          </DialogDescription>
        </DialogHeader>

        <div className="max-h-[70vh] space-y-3 overflow-y-auto px-5 py-4">
          {speakers.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              Run “Identify speakers” first to diarize this meeting.
            </p>
          ) : (
            speakers.map((s) => {
              const isProvisional = s.enrollmentState === 'provisional';
              return (
                <div
                  key={s.speakerId}
                  className="rounded-lg border border-border bg-card p-3"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="flex min-w-0 items-start gap-3">
                      {/* Real per-voice identicon — deterministic from the centroid. */}
                      <VoiceprintGlyph
                        speakerId={s.speakerId}
                        state={s.enrollmentState}
                        size={48}
                        className="mt-0.5"
                        title={`${displayNameFor(s.speakerId)} — voiceprint`}
                      />
                      <div className="min-w-0">
                      <p className="truncate text-sm font-semibold text-foreground">
                        {displayNameFor(s.speakerId)}
                      </p>
                      <p className="mt-0.5 flex items-center gap-1.5 text-[0.6875rem] text-muted-foreground">
                        <span
                          className={cn(
                            'inline-flex items-center gap-1 rounded-full border px-1.5 py-0.5',
                            'border-border',
                          )}
                        >
                          <span
                            aria-hidden="true"
                            className={cn(
                              'size-1.5 rounded-full border border-muted-foreground',
                              isProvisional ? 'bg-transparent' : 'bg-muted-foreground',
                            )}
                          />
                          {STATE_LABEL[s.enrollmentState]}
                        </span>
                        <span>
                          {s.segmentCount} segment{s.segmentCount === 1 ? '' : 's'}
                        </span>
                      </p>
                      </div>
                    </div>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="h-7 flex-shrink-0 text-xs"
                      onClick={() => onAssign(s.speakerId)}
                    >
                      {s.personId ? 'Reassign' : 'Assign'}
                    </Button>
                  </div>

                  <div className="mt-2.5">
                    <SpeakerSampleList
                      samples={samplesBySpeaker.get(s.speakerId) ?? []}
                      audioAvailable={audioAvailable}
                      isPlaying={isPlaying}
                      onPlayClip={onPlayClip}
                      limit={2}
                      emptyNote="No transcribed lines attributed to this speaker."
                    />
                  </div>
                </div>
              );
            })
          )}
        </div>

        {onResetVoiceprint && (
          <div className="border-t border-border px-5 py-3">
            {confirmingReset ? (
              <div className="flex flex-col gap-2">
                <p className="text-xs text-muted-foreground">
                  This clears your saved voice signature <span className="font-medium text-foreground">everywhere</span>{' '}
                  and un-labels you across meetings. It rebuilds the next time you identify speakers — for the cleanest
                  result, do that on a recording where you&apos;re the main speaker.
                </p>
                {resetError && <p className="text-xs text-destructive">{resetError}</p>}
                <div className="flex items-center gap-2">
                  <Button
                    type="button"
                    variant="destructive"
                    size="sm"
                    className="h-7 text-xs"
                    disabled={resetting}
                    onClick={handleReset}
                  >
                    {resetting ? 'Resetting…' : 'Reset my voiceprint'}
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="h-7 text-xs"
                    disabled={resetting}
                    onClick={() => {
                      setConfirmingReset(false);
                      setResetError(null);
                    }}
                  >
                    Cancel
                  </Button>
                </div>
              </div>
            ) : (
              <div className="flex items-center justify-between gap-3">
                <p className="text-xs text-muted-foreground">
                  Wrongly labeled as you? Reset your voiceprint to rebuild it.
                </p>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="h-7 flex-shrink-0 text-xs text-muted-foreground"
                  onClick={() => setConfirmingReset(true)}
                >
                  Reset my voiceprint
                </Button>
              </div>
            )}
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

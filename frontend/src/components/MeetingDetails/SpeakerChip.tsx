'use client';

import { memo } from 'react';
import { cn } from '@/lib/utils';
import type { EnrollmentState } from '@/services/speakerService';
import { VoiceprintGlyph } from './VoiceprintGlyph';

export interface SpeakerChipProps {
  /** Speaker id (UUID) — drives the inline voiceprint identicon. */
  speakerId: string;
  /** Resolved display name (personName ?? label ?? "Speaker N"). */
  displayName: string;
  /** Enrollment lifecycle — drives the honest "unconfirmed" affordance. */
  state: EnrollmentState;
  /** Whether this speaker is the currently-selected one (amber signal). */
  selected?: boolean;
  /** Click toggles selection / opens the assign affordance. */
  onClick?: () => void;
}

/**
 * A compact, calm speaker label rendered on each transcript line. Neutral
 * (muted ink) by default; amber ONLY when it is the actively-selected speaker
 * — the ≤8% Signal-Desk accent for the one thing that matters. A provisional
 * speaker gets an honest hollow dot (never a fake name).
 */
export const SpeakerChip = memo(function SpeakerChip({
  speakerId,
  displayName,
  state,
  selected = false,
  onClick,
}: SpeakerChipProps) {
  const isProvisional = state === 'provisional';

  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      title={
        isProvisional
          ? `${displayName} — unconfirmed speaker`
          : `${displayName} — click to review`
      }
      className={cn(
        'inline-flex max-w-[9rem] items-center gap-1 rounded-full border px-2 py-0.5 text-[0.6875rem] font-medium leading-none transition-colors',
        selected
          ? 'border-accent bg-accent text-accent-foreground'
          : 'border-border bg-secondary text-muted-foreground hover:text-foreground',
      )}
    >
      {/* The voiceprint identicon replaces the plain dot: a real, per-voice mark.
          Provisional voices render lighter/dashed inside the glyph itself. */}
      <VoiceprintGlyph
        speakerId={speakerId}
        state={state}
        size={16}
        className={selected ? 'text-accent-foreground' : undefined}
      />
      <span className="truncate">{displayName}</span>
    </button>
  );
});

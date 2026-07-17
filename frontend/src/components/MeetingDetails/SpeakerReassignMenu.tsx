'use client';

import { memo } from 'react';
import { CheckIcon, PencilIcon } from '@heroicons/react/24/outline';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { cn } from '@/lib/utils';

export interface SpeakerReassignOption {
  speakerId: string;
  displayName: string;
}

export interface SpeakerReassignMenuProps {
  /** Every speaker diarization found in this meeting, for the picker list. */
  speakers: SpeakerReassignOption[];
  /** This line's current speaker, if any (for the checkmark + a11y label). */
  currentSpeakerId: string | null;
  /** Called with the chosen speaker id, or `null` for "no speaker". */
  onSelect: (speakerId: string | null) => void;
  disabled?: boolean;
}

/**
 * Per-line speaker correction (F1 manual override). Diarization can merge two
 * speakers' turns into one transcript line, or attribute a line to the wrong
 * voice cluster — this lets the user fix a SINGLE line without touching the
 * broader speaker/identity model. A pencil-icon trigger keeps it out of the
 * way of the chip's own click-to-review affordance.
 */
export const SpeakerReassignMenu = memo(function SpeakerReassignMenu({
  speakers,
  currentSpeakerId,
  onSelect,
  disabled = false,
}: SpeakerReassignMenuProps) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label="Reassign this line's speaker"
          title="Reassign this line's speaker"
          className="inline-flex size-5 flex-shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground disabled:pointer-events-none disabled:opacity-50"
        >
          <PencilIcon className="size-3" aria-hidden="true" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-48">
        {speakers.map((s) => (
          <DropdownMenuItem
            key={s.speakerId}
            onSelect={() => onSelect(s.speakerId)}
            className="flex items-center justify-between gap-2"
          >
            <span className="truncate">{s.displayName}</span>
            {s.speakerId === currentSpeakerId ? (
              <CheckIcon className="size-3.5 flex-shrink-0 text-accent" aria-hidden="true" />
            ) : null}
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator />
        <DropdownMenuItem
          onSelect={() => onSelect(null)}
          className={cn(
            'flex items-center justify-between gap-2',
            currentSpeakerId === null && 'text-muted-foreground',
          )}
        >
          <span>No speaker</span>
          {currentSpeakerId === null ? (
            <CheckIcon className="size-3.5 flex-shrink-0 text-accent" aria-hidden="true" />
          ) : null}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
});

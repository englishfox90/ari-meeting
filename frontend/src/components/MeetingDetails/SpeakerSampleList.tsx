'use client';

import { useEffect, useState } from 'react';
import { PlayIcon, SpeakerWaveIcon } from '@heroicons/react/24/outline';
import { cn } from '@/lib/utils';
import { formatClock, type SpeakerSample } from '@/lib/speaker-samples';

export interface SpeakerSampleListProps {
  /** Representative lines the speaker said (already selected/ordered). */
  samples: SpeakerSample[];
  /** Whether a playable recording exists. When false, play is disabled honestly. */
  audioAvailable: boolean;
  /** Whether the shared meeting player is currently playing. */
  isPlaying: boolean;
  /** Seek the meeting audio to `seconds` and start playing that moment. */
  onPlayClip: (seconds: number) => void;
  /** Honest note shown when there are no attributed lines. */
  emptyNote?: string;
  /** Cap how many lines to render (defaults to all provided). */
  limit?: number;
}

/**
 * The evidence a user needs to recognise a "Speaker N": their actual words, at
 * real timestamps, each with a play button that jumps the meeting audio to that
 * moment so the voice can be HEARD. Amber (the ≤8% Signal-Desk accent) marks
 * ONLY the clip that is actively playing — everything else stays calm/neutral.
 */
export function SpeakerSampleList({
  samples,
  audioAvailable,
  isPlaying,
  onPlayClip,
  emptyNote = 'No transcribed lines attributed to this speaker yet.',
  limit,
}: SpeakerSampleListProps) {
  const [activeClipId, setActiveClipId] = useState<string | null>(null);

  // Clear the amber indicator once playback stops.
  useEffect(() => {
    if (!isPlaying) setActiveClipId(null);
  }, [isPlaying]);

  const shown = typeof limit === 'number' ? samples.slice(0, limit) : samples;

  if (shown.length === 0) {
    return <p className="text-xs text-muted-foreground">{emptyNote}</p>;
  }

  return (
    <ul className="space-y-1.5">
      {shown.map((sample) => {
        const active = activeClipId === sample.id && isPlaying;
        return (
          <li
            key={sample.id}
            className={cn(
              'flex items-start gap-2 rounded-md border px-2.5 py-2 text-xs transition-colors',
              active
                ? 'border-accent bg-accent-soft'
                : 'border-border bg-secondary/60',
            )}
          >
            <button
              type="button"
              disabled={!audioAvailable}
              onClick={() => {
                setActiveClipId(sample.id);
                onPlayClip(sample.startSeconds);
              }}
              title={
                audioAvailable
                  ? `Play from ${formatClock(sample.startSeconds)}`
                  : 'No recording audio available'
              }
              aria-label={`Play clip at ${formatClock(sample.startSeconds)}`}
              className={cn(
                'mt-0.5 grid size-6 flex-shrink-0 place-items-center rounded-full border transition-colors disabled:cursor-not-allowed disabled:opacity-40',
                active
                  ? 'border-accent bg-accent text-accent-foreground'
                  : 'border-border bg-card text-muted-foreground hover:text-foreground',
              )}
            >
              {active ? (
                <SpeakerWaveIcon className="size-3.5" aria-hidden="true" />
              ) : (
                <PlayIcon className="size-3.5" aria-hidden="true" />
              )}
            </button>
            <div className="min-w-0 flex-1">
              <span
                className={cn(
                  'font-mono text-[0.625rem]',
                  active ? 'text-accent-foreground/80' : 'text-muted-foreground',
                )}
              >
                [{formatClock(sample.startSeconds)}]
              </span>
              <p className="mt-0.5 leading-5 text-foreground">{sample.text}</p>
            </div>
          </li>
        );
      })}
    </ul>
  );
}

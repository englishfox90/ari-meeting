"use client";

/**
 * SummaryMoments — a read-only strip of clickable "referenced moments" shown
 * above the summary. Each chip is a timestamp the summary cites; clicking it
 * plays the recording from that point. Only timestamps that validate against
 * the real recording duration are shown, and the strip renders nothing when
 * there is no audio or no valid reference (No-Fake-State).
 */

import { useMemo } from 'react';
import { PlayIcon } from '@heroicons/react/24/solid';
import { useAudioPlayback } from '@/contexts/AudioPlaybackContext';
import { extractSummaryMoments } from '@/lib/summary-timestamps';

export function SummaryMoments({ summaryData }: { summaryData: unknown }) {
  const player = useAudioPlayback();
  const duration = player?.duration ?? 0;

  const moments = useMemo(
    () => extractSummaryMoments(summaryData, duration),
    [summaryData, duration],
  );

  // No player, audio not ready, or nothing valid to link — stay out of the way.
  if (!player || player.status !== 'ready' || moments.length === 0) {
    return null;
  }

  return (
    <div className="border-b border-border px-6 py-3 sm:px-8">
      <p className="app-eyebrow mb-2">Referenced moments</p>
      <div className="flex flex-wrap gap-1.5">
        {moments.map((m) => (
          <button
            key={m.seconds}
            type="button"
            onClick={() => player.seekAndPlay(m.seconds)}
            aria-label={`Play recording from ${m.label}`}
            className="inline-flex items-center gap-1 rounded-full border border-border bg-secondary px-2.5 py-1 font-mono text-xs tabular-nums text-foreground transition-colors hover:border-accent hover:bg-accent hover:text-accent-foreground"
          >
            <PlayIcon className="size-3" aria-hidden="true" />
            {m.label}
          </button>
        ))}
      </div>
    </div>
  );
}

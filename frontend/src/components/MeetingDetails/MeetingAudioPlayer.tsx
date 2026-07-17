"use client";

/**
 * MeetingAudioPlayer — compact "listen back" bar shown at the top of the
 * transcript panel. Play/pause + a draggable scrubber over the meeting
 * recording. Reads all state from AudioPlaybackContext; renders honest
 * loading / error states and nothing at all when there is no audio.
 */

import { useEffect, useRef, useState } from 'react';
import { PlayIcon, PauseIcon } from '@heroicons/react/24/solid';
import { useAudioPlayback } from '@/contexts/AudioPlaybackContext';
import { cn } from '@/lib/utils';

function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) {
    return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  }
  return `${m}:${s.toString().padStart(2, '0')}`;
}

export function MeetingAudioPlayer() {
  const player = useAudioPlayback();
  const [currentTime, setCurrentTime] = useState(0);
  const isScrubbingRef = useRef(false);

  // Subscribe to high-frequency time updates locally so only this bar re-renders.
  useEffect(() => {
    if (!player) return;
    return player.subscribeTime((t) => {
      if (!isScrubbingRef.current) setCurrentTime(t);
    });
  }, [player]);

  if (!player) return null;

  const { hasAudioPath, status, duration, isPlaying, error, toggle, seek } = player;

  // Nothing to offer and nothing to explain — stay out of the way.
  if (!hasAudioPath) return null;

  const wrapper =
    'border-b border-border bg-card px-4 py-3';

  if (status === 'loading') {
    return (
      <div className={wrapper}>
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          <div className="h-4 w-4 animate-spin rounded-full border-2 border-border border-t-foreground" />
          <span>Loading recording…</span>
        </div>
      </div>
    );
  }

  if (status === 'error') {
    return (
      <div className={wrapper}>
        <p className="text-xs leading-5 text-muted-foreground">
          <span className="font-medium text-foreground">Recording unavailable.</span>{' '}
          {error ?? 'The audio file for this meeting could not be played.'}
        </p>
      </div>
    );
  }

  const max = duration > 0 ? duration : 0;
  const value = Math.min(currentTime, max);
  const pct = max > 0 ? (value / max) * 100 : 0;

  return (
    <div className={wrapper}>
      <p className="app-eyebrow mb-2">Listen back</p>
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={toggle}
          aria-label={isPlaying ? 'Pause recording' : 'Play recording'}
          className={cn(
            'flex size-9 shrink-0 items-center justify-center rounded-full border transition-colors',
            isPlaying
              ? 'border-accent bg-accent text-accent-foreground'
              : 'border-border bg-secondary text-foreground hover:bg-accent hover:text-accent-foreground hover:border-accent',
          )}
        >
          {isPlaying ? (
            <PauseIcon className="size-4" aria-hidden="true" />
          ) : (
            <PlayIcon className="size-4 translate-x-[1px]" aria-hidden="true" />
          )}
        </button>

        <span className="w-10 shrink-0 text-right font-mono text-[0.6875rem] tabular-nums text-muted-foreground">
          {formatTime(value)}
        </span>

        <input
          type="range"
          min={0}
          max={max || 1}
          step="any"
          value={value}
          disabled={max === 0}
          aria-label="Seek recording"
          onChange={(e) => {
            const next = Number(e.target.value);
            setCurrentTime(next);
            seek(next);
          }}
          onPointerDown={() => { isScrubbingRef.current = true; }}
          onPointerUp={() => { isScrubbingRef.current = false; }}
          onBlur={() => { isScrubbingRef.current = false; }}
          className="ari-audio-scrubber h-1.5 min-w-0 flex-1 cursor-pointer appearance-none rounded-full bg-muted disabled:cursor-not-allowed"
          style={{
            background: `linear-gradient(to right, hsl(var(--accent)) ${pct}%, hsl(var(--muted)) ${pct}%)`,
          }}
        />

        <span className="w-10 shrink-0 font-mono text-[0.6875rem] tabular-nums text-muted-foreground">
          {formatTime(max)}
        </span>
      </div>
    </div>
  );
}

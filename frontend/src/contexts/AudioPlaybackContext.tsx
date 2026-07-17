"use client";

/**
 * AudioPlaybackContext — shared meeting-audio player for the meeting-details view.
 *
 * A single hidden HTMLAudioElement streams the recording directly from disk via
 * Tauri's asset protocol (`convertFileSrc`), which serves the file over range
 * requests — so playback and seeking start immediately without loading the whole
 * file into memory. (Recordings can be 100+ MB; the previous read-into-a-Blob path
 * froze the WebView main thread on open.) Playback state that
 * changes infrequently (status/duration/isPlaying) lives in React state; the
 * high-frequency current-time signal is delivered through `subscribeTime` so that
 * the scrubber and the transcript's active-segment highlight can update smoothly
 * without re-rendering the whole meeting view on every animation frame.
 *
 * Honest states only (No-Fake-State): when there is no audio file, or it can't be
 * read, the player reports `unavailable`/`error` rather than faking a scrubber.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { convertFileSrc } from '@tauri-apps/api/core';

export type AudioPlaybackStatus = 'unavailable' | 'loading' | 'ready' | 'error';

interface AudioPlaybackValue {
  /** Whether a recording folder/audio path was provided at all. */
  hasAudioPath: boolean;
  status: AudioPlaybackStatus;
  /** Duration in seconds (0 until metadata loads). */
  duration: number;
  isPlaying: boolean;
  /** Human-friendly error, when status === 'error'. */
  error: string | null;

  play: () => void;
  pause: () => void;
  toggle: () => void;
  /** Seek without changing play/pause state. Clamped to [0, duration]. */
  seek: (seconds: number) => void;
  /** Seek and start playing (used by transcript / summary jump links). */
  seekAndPlay: (seconds: number) => void;

  /** Subscribe to current-time updates (seconds). Returns an unsubscribe fn. */
  subscribeTime: (cb: (seconds: number) => void) => () => void;
  /** Imperative read of the current time (seconds). */
  getCurrentTime: () => number;
}

const AudioPlaybackContext = createContext<AudioPlaybackValue | null>(null);

export function AudioPlaybackProvider({
  audioPath,
  children,
}: {
  audioPath: string | null;
  children: React.ReactNode;
}) {
  const hasAudioPath = Boolean(audioPath);

  const [status, setStatus] = useState<AudioPlaybackStatus>(
    hasAudioPath ? 'loading' : 'unavailable',
  );
  const [duration, setDuration] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const rafRef = useRef<number | null>(null);
  const subscribersRef = useRef<Set<(t: number) => void>>(new Set());

  const emitTime = useCallback((t: number) => {
    subscribersRef.current.forEach((cb) => {
      try {
        cb(t);
      } catch {
        /* subscriber errors must not break the audio loop */
      }
    });
  }, []);

  const stopRaf = useCallback(() => {
    if (rafRef.current != null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
  }, []);

  const startRaf = useCallback(() => {
    stopRaf();
    const tick = () => {
      const el = audioRef.current;
      if (el) emitTime(el.currentTime);
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }, [emitTime, stopRaf]);

  // Load the audio whenever the path changes; tear down cleanly on change/unmount.
  useEffect(() => {
    let cancelled = false;

    // Reset state for the new source.
    stopRaf();
    setIsPlaying(false);
    setDuration(0);
    setError(null);
    emitTime(0);

    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.src = '';
      audioRef.current = null;
    }

    if (!audioPath || typeof window === 'undefined') {
      setStatus(audioPath ? 'loading' : 'unavailable');
      return;
    }

    setStatus('loading');

    try {
      // Stream the file through Tauri's asset protocol instead of reading it into
      // memory — starts instantly and supports native seeking via range requests.
      const url = convertFileSrc(audioPath);

      const el = new Audio();
      el.preload = 'metadata';
      el.src = url;
      audioRef.current = el;

      el.addEventListener('loadedmetadata', () => {
        if (cancelled) return;
        // Some AAC-in-MP4 files report Infinity until fully buffered; keep 0 in that case.
        setDuration(Number.isFinite(el.duration) ? el.duration : 0);
        setStatus('ready');
      });
      el.addEventListener('durationchange', () => {
        if (cancelled) return;
        if (Number.isFinite(el.duration)) setDuration(el.duration);
      });
      el.addEventListener('play', () => {
        if (cancelled) return;
        setIsPlaying(true);
        startRaf();
      });
      el.addEventListener('pause', () => {
        if (cancelled) return;
        setIsPlaying(false);
        stopRaf();
        emitTime(el.currentTime);
      });
      el.addEventListener('ended', () => {
        if (cancelled) return;
        setIsPlaying(false);
        stopRaf();
        emitTime(el.currentTime);
      });
      el.addEventListener('seeked', () => {
        if (cancelled) return;
        emitTime(el.currentTime);
      });
      el.addEventListener('error', () => {
        if (cancelled) return;
        setStatus('error');
        setError('Could not play this recording');
      });
    } catch (err) {
      if (cancelled) return;
      setStatus('error');
      setError(err instanceof Error ? err.message : 'Could not load this recording');
    }

    return () => {
      cancelled = true;
      stopRaf();
      if (audioRef.current) {
        audioRef.current.pause();
        audioRef.current.src = '';
        audioRef.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [audioPath]);

  const play = useCallback(() => {
    const el = audioRef.current;
    if (!el) return;
    void el.play().catch(() => {
      setStatus('error');
      setError('Could not play this recording');
    });
  }, []);

  const pause = useCallback(() => {
    audioRef.current?.pause();
  }, []);

  const toggle = useCallback(() => {
    const el = audioRef.current;
    if (!el) return;
    if (el.paused) play();
    else el.pause();
  }, [play]);

  const clampSeek = useCallback((seconds: number) => {
    const el = audioRef.current;
    if (!el) return 0;
    const max = Number.isFinite(el.duration) ? el.duration : seconds;
    const next = Math.max(0, Math.min(seconds, max));
    el.currentTime = next;
    emitTime(next);
    return next;
  }, [emitTime]);

  const seek = useCallback((seconds: number) => {
    clampSeek(seconds);
  }, [clampSeek]);

  const seekAndPlay = useCallback((seconds: number) => {
    if (!audioRef.current) return;
    clampSeek(seconds);
    play();
  }, [clampSeek, play]);

  const subscribeTime = useCallback((cb: (t: number) => void) => {
    subscribersRef.current.add(cb);
    // Prime the subscriber with the current value immediately.
    cb(audioRef.current?.currentTime ?? 0);
    return () => {
      subscribersRef.current.delete(cb);
    };
  }, []);

  const getCurrentTime = useCallback(() => audioRef.current?.currentTime ?? 0, []);

  const value = useMemo<AudioPlaybackValue>(() => ({
    hasAudioPath,
    status,
    duration,
    isPlaying,
    error,
    play,
    pause,
    toggle,
    seek,
    seekAndPlay,
    subscribeTime,
    getCurrentTime,
  }), [
    hasAudioPath, status, duration, isPlaying, error,
    play, pause, toggle, seek, seekAndPlay, subscribeTime, getCurrentTime,
  ]);

  return (
    <AudioPlaybackContext.Provider value={value}>
      {children}
    </AudioPlaybackContext.Provider>
  );
}

/**
 * Access the meeting audio player. Returns null when rendered outside a provider
 * (callers should treat null as "no player available").
 */
export function useAudioPlayback(): AudioPlaybackValue | null {
  return useContext(AudioPlaybackContext);
}

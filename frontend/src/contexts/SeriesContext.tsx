'use client';

/**
 * SeriesContext (F9)
 *
 * Holds the list of meeting series plus honest loading/error state, and a
 * `refresh()` that re-reads it from the backend. Also exposes a thin
 * `forMeeting()` passthrough so components can ask which series a meeting
 * belongs to without importing the service directly.
 *
 * Guards Tauri availability: outside the desktop shell there is no backend, so
 * the list is simply empty and loading resolves immediately.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import { seriesService } from '@/services/seriesService';
import type { SeriesForMeeting, SeriesSummary } from '@/types/series';

interface SeriesContextType {
  /** All known series (empty when the backend is unavailable or none exist). */
  series: SeriesSummary[];
  loading: boolean;
  error: string | null;
  /** Re-read the series list from the backend. */
  refresh: () => Promise<void>;
  /** The series a meeting belongs to, or null. Thin service passthrough. */
  forMeeting: (meetingId: string) => Promise<SeriesForMeeting | null>;
  /**
   * Rebuild a series' ledger from its members' existing summaries. The in-flight
   * flag lives here (not in the page) so a rebuild started on the series-details
   * page keeps reporting "Building…" even if the user navigates away and back.
   * Resolves to the rebuilt ledger markdown, or `null` when no member has a
   * usable summary yet. Rejects on backend error (callers show an honest note).
   */
  rebuildLedger: (seriesId: string) => Promise<string | null>;
  /** Whether a rebuild is currently in flight for this series id. */
  isRebuilding: (seriesId: string) => boolean;
}

const SeriesContext = createContext<SeriesContextType | undefined>(undefined);

export function SeriesProvider({ children }: { children: ReactNode }) {
  const [series, setSeries] = useState<SeriesSummary[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  // Series ids with a ledger rebuild in flight. A new Set on every mutation so
  // consumers (React.memo/useMemo) always see a changed reference and re-render.
  const [rebuildingSeriesIds, setRebuildingSeriesIds] = useState<Set<string>>(() => new Set());

  const refresh = useCallback(async () => {
    if (!seriesService.isAvailable()) {
      setSeries([]);
      setError(null);
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);
    try {
      const result = await seriesService.list();
      setSeries(result);
    } catch (err) {
      console.error('[SeriesContext] Failed to load series list:', err);
      setSeries([]);
      setError(err instanceof Error ? err.message : 'Failed to load meeting series.');
    } finally {
      setLoading(false);
    }
  }, []);

  const forMeeting = useCallback(async (meetingId: string): Promise<SeriesForMeeting | null> => {
    if (!seriesService.isAvailable()) return null;
    return seriesService.forMeeting(meetingId);
  }, []);

  const rebuildLedger = useCallback(
    async (seriesId: string): Promise<string | null> => {
      if (!seriesService.isAvailable()) return null;
      setRebuildingSeriesIds((prev) => {
        const next = new Set(prev);
        next.add(seriesId);
        return next;
      });
      try {
        const ledger = await seriesService.rebuildLedger(seriesId);
        // Keep the list fresh (meeting counts / last-meeting time may have moved).
        await refresh();
        return ledger;
      } finally {
        setRebuildingSeriesIds((prev) => {
          const next = new Set(prev);
          next.delete(seriesId);
          return next;
        });
      }
    },
    [refresh],
  );

  const isRebuilding = useCallback(
    (seriesId: string): boolean => rebuildingSeriesIds.has(seriesId),
    [rebuildingSeriesIds],
  );

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const value = useMemo<SeriesContextType>(
    () => ({ series, loading, error, refresh, forMeeting, rebuildLedger, isRebuilding }),
    [series, loading, error, refresh, forMeeting, rebuildLedger, isRebuilding],
  );

  return <SeriesContext.Provider value={value}>{children}</SeriesContext.Provider>;
}

export function useSeries() {
  const context = useContext(SeriesContext);
  if (context === undefined) {
    throw new Error('useSeries must be used within a SeriesProvider');
  }
  return context;
}

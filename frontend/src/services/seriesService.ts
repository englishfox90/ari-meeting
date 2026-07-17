/**
 * Meeting Series (F9) Service
 *
 * Wraps the Rust `series_*` Tauri commands. Pure 1-to-1 invoke wrappers —
 * camelCase argument keys (Tauri v2 maps them onto the snake_case Rust params),
 * camelCase return shapes matching the `#[serde(rename_all = "camelCase")]`
 * structs on the Rust side. Guards against running outside the Tauri runtime
 * (plain `pnpm run dev` in a browser has no backend).
 *
 * Note: `series_update_ledger` is intentionally NOT exposed here — the ledger is
 * written by the summary pipeline, never from the UI.
 */

import { invoke } from '@tauri-apps/api/core';
import type { SeriesDetail, SeriesForMeeting, SeriesSummary } from '@/types/series';

function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean(window.__TAURI_INTERNALS__);
}

export class SeriesService {
  /**
   * Whether the app is running inside the Tauri desktop shell (vs. a plain
   * browser dev server, which has no backend).
   */
  isAvailable(): boolean {
    return isTauriAvailable();
  }

  /**
   * Manually create a new (empty) meeting series. Resolves to the new series id.
   * The backend rejects a blank title.
   */
  async create(
    title: string,
    detectedType?: string | null,
    cadence?: string | null,
  ): Promise<string> {
    return invoke<string>('series_create', { title, detectedType, cadence });
  }

  /**
   * List every known series, with meeting counts and last-meeting time.
   */
  async list(): Promise<SeriesSummary[]> {
    return invoke<SeriesSummary[]>('series_list');
  }

  /**
   * Fetch a series' metadata, ordered members, and running ledger.
   */
  async get(seriesId: string): Promise<SeriesDetail> {
    return invoke<SeriesDetail>('series_get', { seriesId });
  }

  /**
   * The series a meeting belongs to (with position + neighbours), or null.
   */
  async forMeeting(meetingId: string): Promise<SeriesForMeeting | null> {
    return invoke<SeriesForMeeting | null>('series_for_meeting', { meetingId });
  }

  /**
   * Link a meeting into a series.
   */
  async link(meetingId: string, seriesId: string): Promise<void> {
    return invoke<void>('series_link_meeting', { meetingId, seriesId });
  }

  /**
   * Unlink a meeting from a series.
   */
  async unlink(meetingId: string, seriesId: string): Promise<void> {
    return invoke<void>('series_unlink_meeting', { meetingId, seriesId });
  }

  /**
   * Update a series' editable metadata (title, and optionally detected type /
   * cadence).
   */
  async updateMeta(
    seriesId: string,
    title: string,
    detectedType?: string | null,
    cadence?: string | null,
  ): Promise<void> {
    return invoke<void>('series_update_meta', {
      seriesId,
      title,
      detectedType,
      cadence,
    });
  }

  /**
   * Heuristic (non-calendar) series detection: cluster meetings not yet in any
   * series by normalized title and form series from clusters of 2+. Resolves to
   * the number of NEW series created. Idempotent.
   */
  async rescanHeuristic(): Promise<number> {
    return invoke<number>('series_rescan_heuristic');
  }

  /**
   * Remember the summary template a meeting's series settled on, so future
   * occurrences inherit it (F9 template inheritance). No-op if the meeting isn't
   * in a series.
   */
  async setTemplate(meetingId: string, templateId: string): Promise<void> {
    return invoke<void>('series_set_template', { meetingId, templateId });
  }

  /**
   * Rebuild the series ledger from scratch, folding every member meeting's
   * EXISTING finished summary in chronological order. This is the on-demand path
   * for a hand-curated series whose meetings were summarized before being linked
   * (the incremental reduce only fires when a summary is (re)generated after
   * linking). Resolves to the rebuilt ledger markdown, or `null` when no member
   * has a usable summary yet — in which case any existing ledger is left
   * untouched (No-Fake-State).
   */
  async rebuildLedger(seriesId: string): Promise<string | null> {
    return invoke<string | null>('series_rebuild_ledger', { seriesId });
  }
}

// Export singleton instance
export const seriesService = new SeriesService();

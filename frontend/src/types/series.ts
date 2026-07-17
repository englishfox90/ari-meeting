/**
 * Meeting Series (F9) types.
 *
 * These mirror the camelCase JSON shapes returned by the Rust `series_*`
 * commands. The Rust side serializes with `#[serde(rename_all = "camelCase")]`,
 * so these interfaces are the exact wire shape — no transformation needed on
 * the frontend.
 *
 * A "series" groups recurring meetings (e.g. a weekly 1:1) so the app can carry
 * a running ledger and cross-link occurrences.
 */

/** One occurrence (meeting) that belongs to a series. */
export interface SeriesMember {
  meetingId: string;
  title: string;
  occurrenceTime: string;
}

/** A series as it appears in the list view. */
export interface SeriesSummary {
  id: string;
  title: string;
  seriesKey: string;
  detectedType?: string | null;
  cadence?: string | null;
  meetingCount: number;
  lastMeetingTime?: string | null;
}

/** Full series detail, including its members and the running ledger. */
export interface SeriesDetail {
  id: string;
  title: string;
  detectedType?: string | null;
  cadence?: string | null;
  members: SeriesMember[];
  ledgerMarkdown?: string | null;
  ledgerVersion: number;
}

/** The series a given meeting belongs to, with its position and neighbours. */
export interface SeriesForMeeting {
  seriesId: string;
  seriesTitle: string;
  position: number;
  total: number;
  prevMeetingId?: string | null;
  nextMeetingId?: string | null;
  /** The summary template this series settled on, if any (F9 template inheritance). */
  seriesTemplate?: string | null;
}

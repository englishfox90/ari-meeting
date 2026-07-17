export interface SavedMeeting {
  id: string;
  title: string;
}

export interface SavedMeetingMetadata extends SavedMeeting {
  created_at: string;
  updated_at: string;
  folder_path?: string;
}

export interface TranscriptSearchHit extends SavedMeeting {
  matchContext: string;
  timestamp: string;
}

export interface SavedMeetingRow extends SavedMeeting {
  createdAt: string | null;
  updatedAt: string | null;
  metadataAvailable: boolean;
  matchContext: string | null;
}

export type MeetingSortOrder = 'newest' | 'oldest';
export type MeetingHistoryViewState = 'loading' | 'error' | 'empty' | 'searching' | 'no-results' | 'list';

interface MeetingHistoryStateInput {
  isLoading: boolean;
  hasLoadError: boolean;
  totalRows: number;
  visibleRows: number;
  isSearching: boolean;
}

export function deriveMeetingHistoryViewState(
  input: MeetingHistoryStateInput,
): MeetingHistoryViewState {
  if (input.isLoading) return 'loading';
  if (input.hasLoadError) return 'error';
  if (input.totalRows === 0) return 'empty';
  if (input.visibleRows === 0 && input.isSearching) return 'searching';
  if (input.visibleRows === 0) return 'no-results';
  return 'list';
}

export function createMeetingRow(
  meeting: SavedMeeting,
  metadata: SavedMeetingMetadata | null,
): SavedMeetingRow {
  return {
    id: meeting.id,
    title: metadata?.title || meeting.title,
    createdAt: metadata?.created_at || null,
    updatedAt: metadata?.updated_at || null,
    metadataAvailable: metadata !== null,
    matchContext: null,
  };
}

function meetingTime(row: SavedMeetingRow): number | null {
  const value = row.updatedAt || row.createdAt;
  if (!value) return null;

  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? null : timestamp;
}

export function sortMeetingRows(
  rows: SavedMeetingRow[],
  order: MeetingSortOrder,
): SavedMeetingRow[] {
  return rows
    .map((row, index) => ({ row, index, timestamp: meetingTime(row) }))
    .sort((a, b) => {
      if (a.timestamp === null && b.timestamp === null) return a.index - b.index;
      if (a.timestamp === null) return 1;
      if (b.timestamp === null) return -1;
      if (a.timestamp === b.timestamp) return a.index - b.index;
      return order === 'newest'
        ? b.timestamp - a.timestamp
        : a.timestamp - b.timestamp;
    })
    .map(({ row }) => row);
}

/** A meeting's series membership, keyed by meeting id in a lookup map. */
export interface MeetingSeriesRef {
  seriesId: string;
  seriesTitle: string;
}

/** A group of saved-meeting rows: either one series, or the "Other" bucket. */
export interface MeetingGroup {
  /** Stable React key: the series id, or the sentinel for un-grouped meetings. */
  key: string;
  title: string;
  /** null for the "Other meetings" bucket. */
  seriesId: string | null;
  rows: SavedMeetingRow[];
}

export const OTHER_MEETINGS_GROUP_KEY = '__other__';

/**
 * Partition rows into series groups + a trailing "Other meetings" bucket.
 * Series groups appear in the order their first member is encountered (so they
 * inherit the caller's existing sort). Rows with no known membership fall into
 * the "Other meetings" group, which is always last. Pure — the caller owns the
 * membership map (built from the backend) and the input row ordering.
 */
export function groupBySeries(
  rows: SavedMeetingRow[],
  membership: Map<string, MeetingSeriesRef>,
): MeetingGroup[] {
  const seriesGroups = new Map<string, MeetingGroup>();
  const other: SavedMeetingRow[] = [];

  for (const row of rows) {
    const ref = membership.get(row.id);
    if (ref) {
      let group = seriesGroups.get(ref.seriesId);
      if (!group) {
        group = { key: ref.seriesId, title: ref.seriesTitle, seriesId: ref.seriesId, rows: [] };
        seriesGroups.set(ref.seriesId, group);
      }
      group.rows.push(row);
    } else {
      other.push(row);
    }
  }

  const groups = Array.from(seriesGroups.values());
  if (other.length > 0) {
    groups.push({ key: OTHER_MEETINGS_GROUP_KEY, title: 'Other meetings', seriesId: null, rows: other });
  }
  return groups;
}

export function filterMeetingRows(
  rows: SavedMeetingRow[],
  query: string,
  transcriptHits: TranscriptSearchHit[],
): SavedMeetingRow[] {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  if (!normalizedQuery) return rows;

  const hitsByMeeting = new Map<string, TranscriptSearchHit>();
  transcriptHits.forEach((hit) => {
    if (!hitsByMeeting.has(hit.id)) hitsByMeeting.set(hit.id, hit);
  });

  return rows
    .filter((row) => (
      row.title.toLocaleLowerCase().includes(normalizedQuery)
      || hitsByMeeting.has(row.id)
    ))
    .map((row) => ({
      ...row,
      matchContext: hitsByMeeting.get(row.id)?.matchContext || null,
    }));
}

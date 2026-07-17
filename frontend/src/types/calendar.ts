/**
 * Calendar (F4) types.
 *
 * These mirror the camelCase JSON shapes returned by the Rust `calendar_*`
 * commands (see calendar-contract.md). The Rust side serializes with
 * `#[serde(rename_all = "camelCase")]`, so these interfaces are the exact
 * wire shape - no transformation needed on the frontend.
 */

export type CalendarPermissionStatus =
  | 'notDetermined'
  | 'authorized'
  | 'denied'
  | 'restricted'
  | 'fullAccess';

export interface CalendarInfo {
  id: string;
  title: string;
  color?: string | null;
  selected: boolean;
}

export interface Attendee {
  name?: string | null;
  email?: string | null;
}

export interface CalendarEvent {
  id: string;
  calendarId: string;
  calendarTitle?: string | null;
  title: string;
  startTime: string;
  endTime: string;
  isAllDay: boolean;
  location?: string | null;
  notes?: string | null;
  organizer?: string | null;
  attendees: Attendee[];
  meetingId?: string | null;
  linkSource?: 'auto' | 'manual' | null;
}

export interface LinkedMeeting {
  id: string;
  title: string;
  createdAt: string;
  hasSummary: boolean;
  summarySnippet?: string | null;
}

export interface CalendarEventDetail extends CalendarEvent {
  linkedMeeting?: LinkedMeeting | null;
}

export interface MeetingCandidate {
  id: string;
  title: string;
  createdAt: string;
}

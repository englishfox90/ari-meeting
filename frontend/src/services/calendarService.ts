/**
 * Calendar Service (F4)
 *
 * Wraps the Rust `calendar_*` Tauri commands. Pure 1-to-1 invoke wrappers.
 * Argument keys are camelCase: Tauri v2 maps camelCase JS keys onto the
 * snake_case Rust params (e.g. `calendarIds` -> `calendar_ids`), matching the
 * rest of this app (see `api_delete_meeting({ meetingId })`). Return shapes are
 * camelCase, matching the `#[serde(rename_all = "camelCase")]` Rust structs.
 * Guards against running outside the Tauri runtime (plain `pnpm run dev` in a
 * browser has no backend).
 */

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import type {
  CalendarEvent,
  CalendarEventDetail,
  CalendarInfo,
  CalendarPermissionStatus,
  MeetingCandidate,
} from '@/types/calendar';

function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean(window.__TAURI_INTERNALS__);
}

export class CalendarService {
  /**
   * Whether the app is running inside the Tauri desktop shell (vs. a plain
   * browser dev server, which has no backend).
   */
  isAvailable(): boolean {
    return isTauriAvailable();
  }

  /**
   * Current EventKit authorization status, without prompting the user.
   */
  async getPermissionStatus(): Promise<CalendarPermissionStatus> {
    return invoke<CalendarPermissionStatus>('calendar_permission_status');
  }

  /**
   * Trigger the native EventKit permission prompt. Resolves to the
   * resulting status once the user responds.
   */
  async requestAccess(): Promise<CalendarPermissionStatus> {
    return invoke<CalendarPermissionStatus>('calendar_request_access');
  }

  /**
   * List the user's calendars (from EventKit, upserted into local
   * calendar_sync_settings) with their current selected state.
   */
  async listCalendars(): Promise<CalendarInfo[]> {
    return invoke<CalendarInfo[]>('calendar_list_calendars');
  }

  /**
   * Persist exactly which calendars should sync.
   */
  async setSelectedCalendars(calendarIds: string[]): Promise<void> {
    return invoke<void>('calendar_set_selected', { calendarIds });
  }

  /**
   * Pull events from selected calendars into the local database and run
   * auto-matching against saved meetings. Returns the number of events
   * synced.
   */
  async syncEvents(daysPast: number, daysFuture: number): Promise<number> {
    return invoke<number>('calendar_sync_events', { daysPast, daysFuture });
  }

  /**
   * Read locally-synced events within a window, ordered by start time.
   */
  async getEvents(daysPast: number, daysFuture: number): Promise<CalendarEvent[]> {
    return invoke<CalendarEvent[]>('calendar_get_events', { daysPast, daysFuture });
  }

  /**
   * Fetch a single event with its linked meeting (if any).
   */
  async getEvent(eventId: string): Promise<CalendarEventDetail | null> {
    return invoke<CalendarEventDetail | null>('calendar_get_event', { eventId });
  }

  /**
   * Manually link an event to a saved meeting/recording.
   */
  async linkMeeting(eventId: string, meetingId: string): Promise<void> {
    return invoke<void>('calendar_link_meeting', { eventId, meetingId });
  }

  /**
   * Remove a link between an event and a saved meeting/recording.
   */
  async unlinkMeeting(eventId: string): Promise<void> {
    return invoke<void>('calendar_unlink_meeting', { eventId });
  }

  /**
   * Candidate recordings near the event's time window, for manual linking.
   */
  async suggestMeetings(eventId: string): Promise<MeetingCandidate[]> {
    return invoke<MeetingCandidate[]>('calendar_suggest_meetings', { eventId });
  }

  /**
   * Sync events from selected calendars into the local database for an
   * explicit ISO date range (Phase 2 week view). Returns the number synced.
   */
  async syncRange(startIso: string, endIso: string): Promise<number> {
    return invoke<number>('calendar_sync_range', { startIso, endIso });
  }

  /**
   * Read locally-synced events within an explicit ISO date range, ordered by
   * start time (Phase 2 week view).
   */
  async getEventsRange(startIso: string, endIso: string): Promise<CalendarEvent[]> {
    return invoke<CalendarEvent[]>('calendar_get_events_range', { startIso, endIso });
  }

  /**
   * Subscribe to the background auto-sync completion event. Fires whenever
   * the Rust-side periodic sync task refreshes the local database, so open
   * views can reload real data (never inferred/estimated counts).
   */
  async onSyncUpdated(callback: (count: number) => void): Promise<UnlistenFn> {
    return listen<{ count: number }>('calendar-sync-updated', (event) => {
      callback(event.payload.count);
    });
  }
}

// Export singleton instance
export const calendarService = new CalendarService();

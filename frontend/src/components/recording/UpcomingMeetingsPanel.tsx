'use client';

/**
 * Upcoming Meetings panel (F5 in-app surface).
 *
 * Shows the user's synced calendar events that are happening now or about to
 * start, each with a "Record" button that starts a recording pre-named after
 * the event title. Clicking is the user's explicit consent — this never
 * auto-starts anything on its own; it is purely a shortcut over the existing
 * manual "Start recording" flow (same `useRecordingStart` hook, same native
 * capture path), matching what the Ari Notch alert already does today
 * (`notch/bridge.rs` `NotchIntent::StartRecordingForEvent`).
 *
 * Read-only: reuses `calendar_get_events`, which is a DB-only read of
 * already-synced events (no live EventKit call, no permission prompt here).
 * If calendar sync isn't set up yet, or nothing is happening soon, the panel
 * renders nothing — calendar setup itself lives in Settings, this is not
 * another place to nag about it.
 */

import { useEffect, useMemo, useState } from 'react';
import { CalendarDaysIcon, MicrophoneIcon, UsersIcon } from '@heroicons/react/24/outline';
import { Surface } from '@/components/app-shell/Surface';
import { Button } from '@/components/ui/button';
import { calendarService } from '@/services/calendarService';
import type { CalendarEvent, CalendarPermissionStatus } from '@/types/calendar';
import { cn } from '@/lib/utils';

interface UpcomingMeetingsPanelProps {
  /** Starts a recording, optionally naming it after the given title. */
  onRecord: (overrideTitle?: string) => Promise<void>;
  /** Disable Record buttons while a start is already in flight. */
  disabled?: boolean;
  /** Called whenever the panel's rendered/hidden state changes, so a parent can adjust its own layout (e.g. collapse a two-column grid to one column). */
  onVisibilityChange?: (visible: boolean) => void;
  /** Extra classes for the outer surface — lets callers override the default top margin, which assumes the panel sits below other content. */
  className?: string;
}

// How far ahead an event counts as "upcoming enough to offer a shortcut for".
const LOOKAHEAD_HOURS = 3;
// How long after an event's scheduled start a late join still gets a
// shortcut — covers showing up late to a short meeting whose calendar end
// time has already passed by the time you open the app.
const LATE_JOIN_MINUTES = 30;
const MAX_EVENTS = 3;

function isGranted(status: CalendarPermissionStatus | 'checking'): boolean {
  return status === 'authorized' || status === 'fullAccess';
}

function formatEventTime(event: CalendarEvent): string {
  const start = new Date(event.startTime);
  return start.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

export function UpcomingMeetingsPanel({ onRecord, disabled, onVisibilityChange, className }: UpcomingMeetingsPanelProps) {
  const [available] = useState(() => calendarService.isAvailable());
  const [permission, setPermission] = useState<CalendarPermissionStatus | 'checking'>('checking');
  const [events, setEvents] = useState<CalendarEvent[] | null>(null);
  const [recordingEventId, setRecordingEventId] = useState<string | null>(null);

  useEffect(() => {
    if (!available) return;

    let cancelled = false;

    (async () => {
      try {
        const status = await calendarService.getPermissionStatus();
        if (!cancelled) setPermission(status);
      } catch (error) {
        console.error('Failed to read calendar permission status:', error);
        if (!cancelled) setPermission('notDetermined');
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [available]);

  useEffect(() => {
    if (!available || !isGranted(permission)) return;

    let cancelled = false;

    (async () => {
      try {
        // Local DB read only — no EventKit call, no sync trigger. Background
        // auto-sync (see calendar-sync-updated) keeps this fresh.
        //
        // Fetch one day of past events too (`daysPast: 1`), not just the
        // future: `calendar_get_events` filters on `start_time >= now`, so a
        // meeting that already started would be dropped at the DB layer before
        // our late-join grace window (below) could ever apply. Looking a day
        // back lets the grace filter keep meetings that are in progress or
        // started within LATE_JOIN_MINUTES.
        const results = await calendarService.getEvents(1, 1);
        if (!cancelled) setEvents(results);
      } catch (error) {
        console.error('Failed to load upcoming calendar events:', error);
        if (!cancelled) setEvents(null);
      }
    })();

    const unlistenPromise = calendarService.onSyncUpdated(async () => {
      try {
        const results = await calendarService.getEvents(1, 1);
        if (!cancelled) setEvents(results);
      } catch (error) {
        console.error('Failed to refresh upcoming calendar events:', error);
      }
    });

    return () => {
      cancelled = true;
      void unlistenPromise.then(unlisten => unlisten());
    };
  }, [available, permission]);

  const upcoming = useMemo(() => {
    if (!events) return [];
    const now = Date.now();
    const lateJoinMs = LATE_JOIN_MINUTES * 60_000;
    const lookaheadMs = LOOKAHEAD_HOURS * 60 * 60_000;

    return events
      .filter(event => !event.isAllDay)
      // Skip events already linked to a saved meeting — those already have a recording.
      .filter(event => !event.meetingId)
      .filter(event => {
        const start = new Date(event.startTime).getTime();
        const end = new Date(event.endTime).getTime();
        if (Number.isNaN(start) || Number.isNaN(end)) return false;
        // Excludes events too far in the future to be worth a shortcut yet.
        if (start - now > lookaheadMs) return false;
        // Still in progress by the calendar's own end time, or started
        // within the late-join window — whichever gives the longer runway.
        const stillInProgress = now < end;
        const startedRecently = now - start <= lateJoinMs;
        return stillInProgress || startedRecently;
      })
      .sort((a, b) => new Date(a.startTime).getTime() - new Date(b.startTime).getTime())
      .slice(0, MAX_EVENTS);
  }, [events]);

  const isVisible = available && isGranted(permission) && upcoming.length > 0;

  useEffect(() => {
    onVisibilityChange?.(isVisible);
  }, [isVisible, onVisibilityChange]);

  if (!isVisible) {
    return null;
  }

  const handleRecord = async (event: CalendarEvent) => {
    setRecordingEventId(event.id);
    try {
      await onRecord(event.title);
    } finally {
      setRecordingEventId(null);
    }
  };

  return (
    <Surface className={cn('mt-4 p-5', className)}>
      <div className="flex items-center gap-2">
        <CalendarDaysIcon className="size-4 text-muted-foreground" aria-hidden="true" />
        <h2 className="text-sm font-semibold">From your calendar</h2>
      </div>
      <ul className="mt-3 divide-y divide-border/60">
        {upcoming.map(event => {
          const isThisStarting = recordingEventId === event.id;
          return (
            <li key={event.id} className="flex items-center justify-between gap-3 py-3 first:pt-0 last:pb-0">
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium">{event.title}</p>
                <p className="mt-0.5 flex items-center gap-2 text-xs text-muted-foreground">
                  <span>{formatEventTime(event)}</span>
                  {event.attendees.length > 0 && (
                    <span className="flex items-center gap-1">
                      <UsersIcon className="size-3" aria-hidden="true" />
                      {event.attendees.length}
                    </span>
                  )}
                </p>
              </div>
              <Button
                variant="outline"
                size="sm"
                onClick={() => void handleRecord(event)}
                disabled={disabled || recordingEventId !== null}
                className={cn(isThisStarting && 'opacity-70')}
              >
                <MicrophoneIcon className="size-3.5" aria-hidden="true" />
                {isThisStarting ? 'Starting...' : 'Record'}
              </Button>
            </li>
          );
        })}
      </ul>
    </Surface>
  );
}

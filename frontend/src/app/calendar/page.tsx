'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { AppState } from '@/components/app-shell/AppState';
import { PageHeader } from '@/components/app-shell/PageHeader';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { Button } from '@/components/ui/button';
import { calendarService } from '@/services/calendarService';
import type { CalendarEvent, CalendarPermissionStatus } from '@/types/calendar';
import { addDays, formatWeekRangeLabel, startOfWeek } from './_lib/week';
import { WeekGrid } from './_components/WeekGrid';
import { EventDetailSheet } from './_components/EventDetailSheet';

type PermissionState = 'checking' | CalendarPermissionStatus;

function isGranted(status: PermissionState): boolean {
  return status === 'authorized' || status === 'fullAccess';
}

function errorText(error: unknown): string {
  if (typeof error === 'string') return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

const SYNC_DEBOUNCE_MS = 500;
const NOW_REFRESH_MS = 60_000;

export default function CalendarPage() {
  const [available] = useState(() => calendarService.isAvailable());
  const [permissionStatus, setPermissionStatus] = useState<PermissionState>('checking');

  const [weekStart, setWeekStart] = useState(() => startOfWeek(new Date()));
  const days = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)), [weekStart]);
  const weekEnd = useMemo(() => addDays(weekStart, 7), [weekStart]);

  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const interval = setInterval(() => setNow(new Date()), NOW_REFRESH_MS);
    return () => clearInterval(interval);
  }, []);

  const [events, setEvents] = useState<CalendarEvent[] | null>(null);
  const [eventsError, setEventsError] = useState<string | null>(null);
  const [isLoadingEvents, setIsLoadingEvents] = useState(false);

  // calendarId → EventKit color, used to tint event blocks in the week grid.
  const [calendarColors, setCalendarColors] = useState<Record<string, string | null | undefined>>({});

  const [isSyncing, setIsSyncing] = useState(false);
  const [syncError, setSyncError] = useState<string | null>(null);
  const [lastSync, setLastSync] = useState<{ count: number; at: Date } | null>(null);

  const [selectedEvent, setSelectedEvent] = useState<CalendarEvent | null>(null);

  const loadEvents = useCallback(async (start: Date, end: Date) => {
    setIsLoadingEvents(true);
    setEventsError(null);
    try {
      const results = await calendarService.getEventsRange(start.toISOString(), end.toISOString());
      setEvents(results);
      return results;
    } catch (error) {
      console.error('Failed to load calendar events for range:', error);
      setEvents(null);
      setEventsError('Ari Meeting could not read synced calendar events from the local database.');
      return null;
    } finally {
      setIsLoadingEvents(false);
    }
  }, []);

  const checkPermission = useCallback(async () => {
    try {
      const status = await calendarService.getPermissionStatus();
      setPermissionStatus(status);
    } catch (error) {
      console.error('Failed to read calendar permission status:', error);
      setPermissionStatus('notDetermined');
    }
  }, []);

  useEffect(() => {
    if (!available) return;
    void checkPermission();
  }, [available, checkPermission]);

  // Load calendar colors once access is granted so the grid can tint events by
  // their source calendar. Colors are cosmetic — failure just falls back to the
  // neutral block styling, so we swallow errors here.
  useEffect(() => {
    if (!isGranted(permissionStatus)) return;
    calendarService
      .listCalendars()
      .then((calendars) => {
        setCalendarColors(Object.fromEntries(calendars.map((cal) => [cal.id, cal.color])));
      })
      .catch((error) => console.error('Failed to load calendar colors:', error));
  }, [permissionStatus]);

  // Render from the local DB immediately, then debounce a real EventKit
  // sync for the visible range so switching weeks quickly doesn't fire a
  // sync per keystroke of navigation.
  useEffect(() => {
    if (!isGranted(permissionStatus)) return;
    void loadEvents(weekStart, weekEnd);

    const timeout = setTimeout(() => {
      setIsSyncing(true);
      setSyncError(null);
      calendarService
        .syncRange(weekStart.toISOString(), weekEnd.toISOString())
        .then((count) => {
          setLastSync({ count, at: new Date() });
          return loadEvents(weekStart, weekEnd);
        })
        .catch((error) => {
          console.error('Failed to sync calendar range:', error);
          setSyncError(`Background sync failed: ${errorText(error)}`);
        })
        .finally(() => setIsSyncing(false));
    }, SYNC_DEBOUNCE_MS);

    return () => clearTimeout(timeout);
  }, [permissionStatus, weekStart, weekEnd, loadEvents]);

  // Reload the visible week whenever the Rust background auto-sync task
  // (every ~15 min) reports it refreshed the local database.
  useEffect(() => {
    if (!available || !isGranted(permissionStatus)) return;
    let unlisten: (() => void) | undefined;
    calendarService
      .onSyncUpdated(() => {
        void loadEvents(weekStart, weekEnd);
      })
      .then((fn) => {
        unlisten = fn;
      })
      .catch((error) => console.error('Failed to subscribe to calendar sync updates:', error));
    return () => unlisten?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [available, permissionStatus, weekStart, weekEnd]);

  // Keep the open detail sheet in sync with fresh event data (e.g. after a
  // link/unlink) instead of holding a stale copy until it's closed.
  const selectedEventRef = useRef(selectedEvent);
  selectedEventRef.current = selectedEvent;
  useEffect(() => {
    if (!selectedEventRef.current || !events) return;
    const fresh = events.find((event) => event.id === selectedEventRef.current!.id);
    if (fresh) setSelectedEvent(fresh);
  }, [events]);

  const handleManualSync = async () => {
    setIsSyncing(true);
    setSyncError(null);
    try {
      const count = await calendarService.syncRange(weekStart.toISOString(), weekEnd.toISOString());
      setLastSync({ count, at: new Date() });
      await loadEvents(weekStart, weekEnd);
    } catch (error) {
      console.error('Failed to sync calendar range:', error);
      setSyncError(`Sync failed: ${errorText(error)}`);
    } finally {
      setIsSyncing(false);
    }
  };

  if (!available) {
    return (
      <div className="app-page">
        <PageHeader eyebrow="Calendar" title="Calendar" description="See your week and link events to recordings." />
        <div className="mt-7">
          <AppState
            kind="disabled"
            title="Calendar is available in the desktop app"
            description="Run Ari Meeting as a desktop app to read your calendar and link events to recordings."
          />
        </div>
      </div>
    );
  }

  if (permissionStatus === 'checking') {
    return (
      <div className="app-page">
        <PageHeader eyebrow="Calendar" title="Calendar" description="See your week and link events to recordings." />
        <div className="mt-7">
          <AppState kind="loading" title="Checking calendar access" description="Reading calendar permission status." />
        </div>
      </div>
    );
  }

  if (!isGranted(permissionStatus)) {
    return (
      <div className="app-page">
        <PageHeader eyebrow="Calendar" title="Calendar" description="See your week and link events to recordings." />
        <div className="mt-7">
          <AppState
            kind="permission"
            title={permissionStatus === 'denied' ? 'Calendar access denied' : 'Calendar access needed'}
            description={
              permissionStatus === 'denied'
                ? 'Ari Meeting cannot read your calendar. Enable it in System Settings → Privacy & Security → Calendars, then grant access in Settings → Calendar.'
                : 'Ari Meeting needs permission to read your calendar. Grant access and choose which calendars to sync in Settings → Calendar.'
            }
            action={
              <Button asChild variant="outline">
                <Link href="/settings">Open Settings</Link>
              </Button>
            }
          />
        </div>
      </div>
    );
  }

  return (
    <div className="app-page">
      <PageHeader eyebrow="Calendar" title="Calendar" description="See your week and link events to recordings." />

      <div className="mt-7 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <Button variant="outline" size="icon" onClick={() => setWeekStart((w) => addDays(w, -7))} aria-label="Previous week">
              <MeetilyGlyph name="chevron-left" className="size-4" />
            </Button>
            <Button variant="outline" size="icon" onClick={() => setWeekStart((w) => addDays(w, 7))} aria-label="Next week">
              <MeetilyGlyph name="chevron-right" className="size-4" />
            </Button>
            <Button variant="outline" size="sm" onClick={() => setWeekStart(startOfWeek(new Date()))}>
              Today
            </Button>
            <h2 className="ml-2 text-sm font-semibold tracking-[-0.01em]">{formatWeekRangeLabel(weekStart)}</h2>
          </div>

          <div className="flex items-center gap-3">
            <Link href="/settings" className="text-xs font-medium text-muted-foreground underline-offset-2 hover:text-foreground hover:underline">
              Manage calendars in Settings
            </Link>
            <Button variant="outline" size="sm" onClick={() => void handleManualSync()} disabled={isSyncing}>
              {isSyncing ? 'Syncing…' : 'Sync now'}
            </Button>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 px-0.5 text-xs text-muted-foreground">
          {lastSync && (
            <span>
              Synced {lastSync.count} {lastSync.count === 1 ? 'event' : 'events'} at{' '}
              {new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(lastSync.at)}
            </span>
          )}
          <span>Auto-syncs in the background every 15 minutes while Ari Meeting is running.</span>
        </div>

        {syncError && <p className="px-0.5 text-xs text-destructive" role="alert">{syncError}</p>}

        {isLoadingEvents && !events ? (
          <AppState kind="loading" title="Loading your week" description="Reading synced calendar events from your local database." />
        ) : eventsError ? (
          <AppState
            kind="error"
            title="Week could not be loaded"
            description={eventsError}
            action={<Button variant="outline" onClick={() => void loadEvents(weekStart, weekEnd)}>Try again</Button>}
          />
        ) : (
          <WeekGrid days={days} events={events ?? []} now={now} calendarColors={calendarColors} onEventClick={setSelectedEvent} />
        )}
      </div>

      <EventDetailSheet
        event={selectedEvent}
        onClose={() => setSelectedEvent(null)}
        onEventChanged={() => void loadEvents(weekStart, weekEnd)}
      />
    </div>
  );
}

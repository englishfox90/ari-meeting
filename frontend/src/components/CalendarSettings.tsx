'use client';

import { useCallback, useEffect, useState } from 'react';
import { AppState } from '@/components/app-shell/AppState';
import { Surface } from '@/components/app-shell/Surface';
import { Button } from '@/components/ui/button';
import { Switch } from '@/components/ui/switch';
import { calendarService } from '@/services/calendarService';
import type { CalendarInfo, CalendarPermissionStatus } from '@/types/calendar';

type PermissionState = 'checking' | CalendarPermissionStatus;

function isGranted(status: PermissionState): boolean {
  return status === 'authorized' || status === 'fullAccess';
}

// Tauri rejects an `invoke` with the command's `Err(String)` as a plain string;
// surface it verbatim so backend failures are diagnosable from the UI.
function errorText(error: unknown): string {
  if (typeof error === 'string') return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

/**
 * Calendar access + calendar selection settings (Phase 2). Moved out of the
 * calendar page, which is now a pure week view — this is the only place the
 * permission gate and per-calendar toggles live.
 */
export function CalendarSettings() {
  const [available] = useState(() => calendarService.isAvailable());

  const [permissionStatus, setPermissionStatus] = useState<PermissionState>('checking');
  const [permissionError, setPermissionError] = useState<string | null>(null);
  const [isRequestingAccess, setIsRequestingAccess] = useState(false);

  const [calendars, setCalendars] = useState<CalendarInfo[] | null>(null);
  const [calendarsError, setCalendarsError] = useState<string | null>(null);
  const [isLoadingCalendars, setIsLoadingCalendars] = useState(false);
  const [pendingCalendarId, setPendingCalendarId] = useState<string | null>(null);

  const loadCalendars = useCallback(async () => {
    setIsLoadingCalendars(true);
    setCalendarsError(null);
    try {
      const results = await calendarService.listCalendars();
      setCalendars(results);
    } catch (error) {
      console.error('Failed to load calendars:', error);
      setCalendars(null);
      setCalendarsError('Ari Meeting could not read your calendars.');
    } finally {
      setIsLoadingCalendars(false);
    }
  }, []);

  const checkPermission = useCallback(async () => {
    setPermissionError(null);
    try {
      const status = await calendarService.getPermissionStatus();
      setPermissionStatus(status);
    } catch (error) {
      console.error('Failed to read calendar permission status:', error);
      setPermissionError('Ari Meeting could not check calendar access.');
      setPermissionStatus('notDetermined');
    }
  }, []);

  useEffect(() => {
    if (!available) return;
    void checkPermission();
  }, [available, checkPermission]);

  useEffect(() => {
    if (!isGranted(permissionStatus)) return;
    void loadCalendars();
  }, [permissionStatus, loadCalendars]);

  const handleRequestAccess = async () => {
    setIsRequestingAccess(true);
    setPermissionError(null);
    try {
      const status = await calendarService.requestAccess();
      setPermissionStatus(status);
    } catch (error) {
      console.error('Failed to request calendar access:', error);
      setPermissionError('Ari Meeting could not request calendar access.');
    } finally {
      setIsRequestingAccess(false);
    }
  };

  const handleToggleCalendar = async (calendarId: string, nextSelected: boolean) => {
    if (!calendars) return;
    const nextCalendars = calendars.map((cal) => (cal.id === calendarId ? { ...cal, selected: nextSelected } : cal));
    setCalendars(nextCalendars);
    setPendingCalendarId(calendarId);
    setCalendarsError(null);

    try {
      const selectedIds = nextCalendars.filter((cal) => cal.selected).map((cal) => cal.id);
      await calendarService.setSelectedCalendars(selectedIds);
    } catch (error) {
      console.error('Failed to update calendar selection:', error);
      setCalendars(calendars);
      setCalendarsError(`Could not save your calendar selection: ${errorText(error)}`);
    } finally {
      setPendingCalendarId(null);
    }
  };

  if (!available) {
    return (
      <AppState
        kind="disabled"
        title="Calendar is available in the desktop app"
        description="Run Ari Meeting as a desktop app to read your calendar and link events to recordings."
      />
    );
  }

  if (permissionStatus === 'checking') {
    return <AppState kind="loading" title="Checking calendar access" description="Reading calendar permission status." />;
  }

  if (!isGranted(permissionStatus)) {
    return (
      <AppState
        kind="permission"
        title={permissionStatus === 'denied' ? 'Calendar access denied' : 'Calendar access needed'}
        description={
          permissionStatus === 'denied'
            ? 'Ari Meeting cannot read your calendar. Enable it in System Settings → Privacy & Security → Calendars, then come back to this page.'
            : 'Ari Meeting needs permission to read your calendar to surface upcoming meetings and link them to recordings.'
        }
        action={
          permissionStatus === 'denied' ? undefined : (
            <Button onClick={() => void handleRequestAccess()} disabled={isRequestingAccess}>
              {isRequestingAccess ? 'Requesting…' : 'Grant calendar access'}
            </Button>
          )
        }
      />
    );
  }

  return (
    <div className="space-y-4">
      {permissionError && <p className="px-1 text-xs text-destructive" role="alert">{permissionError}</p>}

      <Surface className="p-4">
        <div>
          <h3 className="text-sm font-semibold tracking-[-0.01em]">Calendars to sync</h3>
          <p className="mt-0.5 text-xs leading-5 text-muted-foreground">
            Choose which calendars Ari Meeting reads. The calendar page and background sync only use these.
          </p>
        </div>

        {calendarsError && <p className="mt-3 text-xs text-destructive" role="alert">{calendarsError}</p>}

        <div className="mt-4 divide-y divide-border/70">
          {isLoadingCalendars ? (
            <p className="py-3 text-sm text-muted-foreground">Loading calendars…</p>
          ) : !calendars || calendars.length === 0 ? (
            <p className="py-3 text-sm text-muted-foreground">No calendars found on this Mac.</p>
          ) : (
            calendars.map((cal) => (
              <div key={cal.id} className="flex items-center justify-between gap-3 py-2.5">
                <div className="flex min-w-0 items-center gap-2.5">
                  <span
                    className="size-4 shrink-0 rounded-full border border-border shadow-sm"
                    style={cal.color ? { backgroundColor: cal.color } : undefined}
                    aria-hidden="true"
                  />
                  <span className="truncate text-sm">{cal.title}</span>
                </div>
                <Switch
                  checked={cal.selected}
                  onCheckedChange={(checked) => void handleToggleCalendar(cal.id, checked)}
                  disabled={pendingCalendarId === cal.id}
                  aria-label={`Sync ${cal.title}`}
                />
              </div>
            ))
          )}
        </div>
      </Surface>
    </div>
  );
}

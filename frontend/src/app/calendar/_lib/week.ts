/**
 * Pure date-math helpers for the Monday-start week view (Phase 2). No Tauri
 * calls here — kept separate so the grid/header components can stay focused
 * on rendering.
 */

/** Midnight (local time) on the Monday of the week containing `date`. */
export function startOfWeek(date: Date): Date {
  const result = new Date(date);
  result.setHours(0, 0, 0, 0);
  // getDay(): 0 = Sunday .. 6 = Saturday. Shift so Monday = 0.
  const dayIndex = (result.getDay() + 6) % 7;
  result.setDate(result.getDate() - dayIndex);
  return result;
}

export function addDays(date: Date, days: number): Date {
  const result = new Date(date);
  result.setDate(result.getDate() + days);
  return result;
}

export function isSameLocalDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/** Minutes since local midnight, clamped to [0, 24*60]. */
export function minutesSinceMidnight(date: Date): number {
  return Math.min(24 * 60, Math.max(0, date.getHours() * 60 + date.getMinutes()));
}

export function weekDays(monday: Date): Date[] {
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i));
}

/** e.g. "Jul 14 – 20, 2026" or "Jul 28 – Aug 3, 2026" across a month boundary. */
export function formatWeekRangeLabel(monday: Date): string {
  const sunday = addDays(monday, 6);
  const sameMonth = monday.getMonth() === sunday.getMonth() && monday.getFullYear() === sunday.getFullYear();
  const monthDay = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });
  const dayOnly = new Intl.DateTimeFormat(undefined, { day: 'numeric' });
  const start = monthDay.format(monday);
  const end = sameMonth ? dayOnly.format(sunday) : monthDay.format(sunday);
  return `${start} – ${end}, ${sunday.getFullYear()}`;
}

export function formatDayColumnHeading(date: Date): { weekday: string; dayNumber: string } {
  return {
    weekday: new Intl.DateTimeFormat(undefined, { weekday: 'short' }).format(date),
    dayNumber: new Intl.DateTimeFormat(undefined, { day: 'numeric' }).format(date),
  };
}

export function formatHourLabel(hour: number): string {
  const date = new Date(2000, 0, 1, hour, 0, 0);
  return new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).format(date);
}

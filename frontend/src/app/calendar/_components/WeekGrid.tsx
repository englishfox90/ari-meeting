'use client';

import { useEffect, useMemo, useRef } from 'react';
import type { CSSProperties } from 'react';
import { cn } from '@/lib/utils';
import type { CalendarEvent } from '@/types/calendar';
import { formatDayColumnHeading, formatHourLabel, isSameLocalDay, minutesSinceMidnight } from '../_lib/week';

const HOUR_HEIGHT_PX = 48;
const HOURS = Array.from({ length: 24 }, (_, i) => i);
const INITIAL_SCROLL_HOUR = 7;

function pxFromMinutes(minutes: number): number {
  return (minutes / 60) * HOUR_HEIGHT_PX;
}

/**
 * Tint an event block with its source calendar's own color (the same color
 * macOS shows for that calendar). We blend toward the card background so the
 * fill stays subtle in both light and dark themes, then use the raw color for
 * a solid left accent bar so overlapping calendars stay distinguishable.
 * Colors are real data from EventKit — not design tokens — so inlining them
 * here is intentional (mirrors the color dot in Calendar settings).
 */
function eventColorStyle(color: string | null | undefined): CSSProperties {
  if (!color) return {};
  return {
    backgroundColor: `color-mix(in srgb, ${color} 18%, hsl(var(--card)))`,
    borderColor: `color-mix(in srgb, ${color} 45%, hsl(var(--border)))`,
    borderLeft: `3px solid ${color}`,
  };
}

interface PositionedEvent {
  event: CalendarEvent;
  top: number;
  height: number;
  startMinutes: number;
  endMinutes: number;
  /** Column index within its overlap cluster, and total columns in that cluster. */
  col: number;
  cols: number;
}

function layoutDay(day: Date, events: CalendarEvent[]): PositionedEvent[] {
  const items: PositionedEvent[] = events
    .filter((event) => !event.isAllDay)
    .filter((event) => {
      const start = new Date(event.startTime);
      return !Number.isNaN(start.getTime()) && isSameLocalDay(start, day);
    })
    .map((event) => {
      const start = new Date(event.startTime);
      const end = new Date(event.endTime);
      const startMinutes = minutesSinceMidnight(start);
      const endMinutes = Number.isNaN(end.getTime()) ? startMinutes + 30 : Math.max(startMinutes + 15, minutesSinceMidnight(end));
      return {
        event,
        top: pxFromMinutes(startMinutes),
        height: Math.max(pxFromMinutes(endMinutes - startMinutes), 22),
        startMinutes,
        endMinutes,
        col: 0,
        cols: 1,
      };
    })
    .sort((a, b) => a.startMinutes - b.startMinutes || a.endMinutes - b.endMinutes);

  // Google-style side-by-side layout: pack each transitively-overlapping
  // cluster into the fewest columns (first column whose last event has ended),
  // then give every event in the cluster the same column count so widths match.
  let cluster: PositionedEvent[] = [];
  let clusterEnd = -1;
  let colEnds: number[] = [];

  const flush = () => {
    const cols = colEnds.length;
    for (const it of cluster) it.cols = cols;
    cluster = [];
    colEnds = [];
    clusterEnd = -1;
  };

  for (const it of items) {
    if (it.startMinutes >= clusterEnd) flush();
    let placed = colEnds.findIndex((end) => end <= it.startMinutes);
    if (placed === -1) {
      placed = colEnds.length;
      colEnds.push(it.endMinutes);
    } else {
      colEnds[placed] = it.endMinutes;
    }
    it.col = placed;
    cluster.push(it);
    clusterEnd = Math.max(clusterEnd, it.endMinutes);
  }
  flush();

  return items;
}

function allDayForDay(day: Date, events: CalendarEvent[]): CalendarEvent[] {
  return events.filter((event) => {
    if (!event.isAllDay) return false;
    const start = new Date(event.startTime);
    const end = new Date(event.endTime);
    if (Number.isNaN(start.getTime())) return false;
    const effectiveEnd = Number.isNaN(end.getTime()) ? start : end;
    // EventKit all-day ranges are typically exclusive on the end date; a
    // same-day all-day event still has start === end at midnight.
    const dayStart = new Date(day);
    dayStart.setHours(0, 0, 0, 0);
    const dayEnd = new Date(dayStart);
    dayEnd.setDate(dayEnd.getDate() + 1);
    return start < dayEnd && effectiveEnd >= dayStart;
  });
}

interface WeekGridProps {
  days: Date[];
  events: CalendarEvent[];
  now: Date;
  /** Map of calendarId → CSS color (from EventKit) used to tint event blocks. */
  calendarColors: Record<string, string | null | undefined>;
  onEventClick: (event: CalendarEvent) => void;
}

export function WeekGrid({ days, events, now, calendarColors, onEventClick }: WeekGridProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const hasScrolledRef = useRef(false);

  useEffect(() => {
    if (hasScrolledRef.current || !scrollRef.current) return;
    scrollRef.current.scrollTop = INITIAL_SCROLL_HOUR * HOUR_HEIGHT_PX;
    hasScrolledRef.current = true;
  }, []);

  const allDayByDay = useMemo(() => days.map((day) => allDayForDay(day, events)), [days, events]);
  const timedByDay = useMemo(() => days.map((day) => layoutDay(day, events)), [days, events]);
  const hasAnyAllDay = allDayByDay.some((list) => list.length > 0);
  const todayIndex = days.findIndex((day) => isSameLocalDay(day, now));
  const nowTop = pxFromMinutes(minutesSinceMidnight(now));

  return (
    // A single scroll container holds the header, all-day row, and hour grid so
    // all three share the exact same content width and scrollbar gutter — this
    // is what keeps the day columns aligned once a vertical scrollbar appears
    // (a separate, non-scrolling header would drift by the scrollbar width).
    <div
      ref={scrollRef}
      className="max-h-[40rem] overflow-y-auto rounded-[10px] border border-border bg-card"
    >
      {/* Day-of-week header + all-day row, pinned together while hours scroll */}
      <div className="sticky top-0 z-20 bg-card">
        <div className="grid grid-cols-[3.5rem_repeat(7,1fr)] border-b border-border">
          <div />
          {days.map((day) => {
            const { weekday, dayNumber } = formatDayColumnHeading(day);
            const isToday = isSameLocalDay(day, now);
            return (
              <div key={day.toISOString()} className="flex flex-col items-center gap-0.5 border-l border-border py-2">
                <span className="app-eyebrow">{weekday}</span>
                <span
                  className={cn(
                    'grid size-6 place-items-center rounded-full text-sm font-semibold tracking-[-0.01em]',
                    isToday && 'bg-secondary text-foreground ring-1 ring-inset ring-border',
                  )}
                >
                  {dayNumber}
                </span>
              </div>
            );
          })}
        </div>

        {hasAnyAllDay && (
          <div className="grid grid-cols-[3.5rem_repeat(7,1fr)] border-b border-border bg-secondary/30">
            <div className="flex items-start justify-end px-1.5 pt-2 font-mono text-[0.6rem] font-medium uppercase leading-tight tracking-[0.02em] text-muted-foreground">
              All day
            </div>
            {allDayByDay.map((dayEvents, index) => (
              // min-w-0 is load-bearing: without it the truncating (nowrap) pill's
              // min-content inflates this grid track, so the all-day row's columns
              // stop lining up with the evenly-sized header and hour-grid columns.
              <div key={days[index].toISOString()} className="flex min-w-0 flex-col gap-1 border-l border-border px-0.5 py-2">
                {dayEvents.map((event) => (
                  <button
                    key={event.id}
                    type="button"
                    onClick={() => onEventClick(event)}
                    className="truncate rounded-md border border-border bg-secondary px-1.5 py-0.5 text-left text-xs font-medium text-foreground transition-[filter] hover:brightness-95"
                    style={eventColorStyle(calendarColors[event.calendarId])}
                    title={event.title}
                  >
                    {event.title}
                  </button>
                ))}
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Scrollable hour grid */}
      <div className="relative grid grid-cols-[3.5rem_repeat(7,1fr)]">
        {/* Hour labels */}
        <div className="relative">
          {HOURS.map((hour) => (
            <div
              key={hour}
              className="border-t border-border/60 pr-2 text-right text-[0.65rem] text-muted-foreground first:border-t-0"
              style={{ height: HOUR_HEIGHT_PX }}
            >
              <span className="-translate-y-1/2 relative top-0 inline-block">{hour === 0 ? '' : formatHourLabel(hour)}</span>
            </div>
          ))}
        </div>

        {/* Day columns */}
        {days.map((day, dayIndex) => (
          <div key={day.toISOString()} className="relative border-l border-border">
            {HOURS.map((hour) => (
              <div key={hour} className="border-t border-border/60 first:border-t-0" style={{ height: HOUR_HEIGHT_PX }} />
            ))}

            {timedByDay[dayIndex].map(({ event, top, height, col, cols }) => (
              <button
                key={event.id}
                type="button"
                onClick={() => onEventClick(event)}
                className="absolute overflow-hidden rounded-md border border-border bg-secondary px-1.5 py-1 text-left text-xs leading-tight text-foreground transition-[filter] hover:brightness-95"
                style={{
                  top,
                  height,
                  left: `calc(${(col / cols) * 100}% + 1px)`,
                  width: `calc(${100 / cols}% - 2px)`,
                  ...eventColorStyle(calendarColors[event.calendarId]),
                }}
                title={event.title}
              >
                <span className="block truncate font-medium">{event.title}</span>
              </button>
            ))}

            {dayIndex === todayIndex && (
              <div
                className="pointer-events-none absolute inset-x-0 z-10 flex items-center"
                style={{ top: nowTop }}
                aria-hidden="true"
              >
                <span className="size-1.5 shrink-0 rounded-full bg-accent" />
                <span className="h-px flex-1 bg-accent" />
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

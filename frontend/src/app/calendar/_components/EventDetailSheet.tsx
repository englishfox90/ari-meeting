'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { UserGroupIcon } from '@heroicons/react/24/outline';
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { calendarService } from '@/services/calendarService';
import type { CalendarEvent, LinkedMeeting } from '@/types/calendar';
import { LinkPickerDialog } from './LinkPickerDialog';

/**
 * Calendar descriptions (esp. Google) arrive as HTML. Convert to readable
 * plain text for display — we never set innerHTML, so this is purely cosmetic
 * and XSS-safe (React escapes the resulting string). Anchors keep their link
 * text and append the URL when it isn't already visible in the text.
 */
function htmlToPlainText(input: string): string {
  // Fast path: no tags and no entities → return as-is.
  if (!/[<&]/.test(input)) return input.trim();

  let s = input.replace(
    /<a\b[^>]*href=["']([^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi,
    (_match, href: string, text: string) => {
      const label = text.replace(/<[^>]+>/g, '').trim();
      if (!label) return href;
      return label.includes(href) || href.includes(label) ? label : `${label} (${href})`;
    },
  );
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<li[^>]*>/gi, '\n• ');
  s = s.replace(/<\/(p|div|li|tr|h[1-6]|ul|ol)>/gi, '\n');
  s = s.replace(/<[^>]+>/g, '');

  // Decode HTML entities via a detached textarea (RCDATA — decodes entities,
  // does not parse tags), guarded for any non-DOM render context.
  if (typeof document !== 'undefined') {
    const el = document.createElement('textarea');
    el.innerHTML = s;
    s = el.value;
  } else {
    s = s
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'");
  }

  return s.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

function formatTimeRange(event: CalendarEvent): string {
  if (event.isAllDay) return 'All day';
  const start = new Date(event.startTime);
  const end = new Date(event.endTime);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return 'Time unavailable';
  const dateFormatter = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
  const timeFormatter = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
  return `${dateFormatter.format(start)} · ${timeFormatter.format(start)} – ${timeFormatter.format(end)}`;
}

interface EventDetailSheetProps {
  event: CalendarEvent | null;
  onClose: () => void;
  onEventChanged: () => void;
}

/**
 * Slide-over detail panel for a single calendar event. `event` (from the
 * week-view list) carries every field except `linkedMeeting` (title/summary
 * of a linked recording), which is only present on `calendar_get_event`'s
 * `CalendarEventDetail` — fetched separately so we never invent a linked
 * recording's title while it loads.
 */
export function EventDetailSheet({ event, onClose, onEventChanged }: EventDetailSheetProps) {
  const router = useRouter();
  const [linkedMeeting, setLinkedMeeting] = useState<LinkedMeeting | null>(null);
  const [isLoadingDetail, setIsLoadingDetail] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [isUnlinking, setIsUnlinking] = useState(false);
  const [isPickerOpen, setIsPickerOpen] = useState(false);

  useEffect(() => {
    setLinkedMeeting(null);
    setDetailError(null);
    if (!event?.meetingId) return;

    let cancelled = false;
    setIsLoadingDetail(true);
    calendarService
      .getEvent(event.id)
      .then((detail) => {
        if (!cancelled) setLinkedMeeting(detail?.linkedMeeting ?? null);
      })
      .catch((error) => {
        console.error('Failed to load event detail:', error);
        if (!cancelled) setDetailError('Could not load the linked recording for this event.');
      })
      .finally(() => {
        if (!cancelled) setIsLoadingDetail(false);
      });

    return () => {
      cancelled = true;
    };
  }, [event?.id, event?.meetingId]);

  const handleUnlink = async () => {
    if (!event) return;
    setIsUnlinking(true);
    try {
      await calendarService.unlinkMeeting(event.id);
      setLinkedMeeting(null);
      onEventChanged();
    } catch (error) {
      console.error('Failed to unlink meeting:', error);
      setDetailError('Could not unlink this recording. Try again.');
    } finally {
      setIsUnlinking(false);
    }
  };

  return (
    <>
      <Sheet open={event !== null} onOpenChange={(open) => !open && onClose()}>
        <SheetContent side="right" className="flex w-full flex-col overflow-y-auto sm:max-w-md">
          {event && (
            <>
              <SheetHeader>
                <SheetTitle>{event.title}</SheetTitle>
                <SheetDescription>{formatTimeRange(event)}</SheetDescription>
              </SheetHeader>

              <div className="mt-6 space-y-5 text-sm">
                {event.calendarTitle && (
                  <DetailRow label="Calendar" value={event.calendarTitle} />
                )}
                {event.location && <DetailRow label="Location" value={event.location} />}
                {event.organizer && <DetailRow label="Organizer" value={event.organizer} />}

                <div>
                  <p className="app-eyebrow mb-1.5 flex items-center gap-1.5">
                    <UserGroupIcon className="size-3.5" aria-hidden="true" />
                    Attendees
                  </p>
                  {event.attendees.length === 0 ? (
                    <p className="text-sm text-muted-foreground">No attendees listed.</p>
                  ) : (
                    <ul className="space-y-1">
                      {event.attendees.map((attendee, index) => (
                        <li key={`${attendee.email ?? attendee.name ?? 'attendee'}-${index}`} className="text-sm">
                          <span className="text-foreground">{attendee.name ?? attendee.email ?? 'Unnamed attendee'}</span>
                          {attendee.name && attendee.email && (
                            <span className="ml-1.5 text-xs text-muted-foreground">{attendee.email}</span>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>

                <div>
                  <p className="app-eyebrow mb-1.5">Description</p>
                  {event.notes ? (
                    <p className="whitespace-pre-wrap text-sm leading-6 text-muted-foreground">{htmlToPlainText(event.notes)}</p>
                  ) : (
                    <p className="text-sm text-muted-foreground">No description.</p>
                  )}
                </div>

                <div className="border-t border-border pt-4">
                  <p className="app-eyebrow mb-2">Recording</p>
                  {detailError && <p className="mb-2 text-xs text-destructive" role="alert">{detailError}</p>}
                  {event.meetingId ? (
                    isLoadingDetail ? (
                      <p className="text-sm text-muted-foreground">Loading linked recording…</p>
                    ) : (
                      <div className="space-y-2">
                        <button
                          type="button"
                          onClick={() => router.push(`/meeting-details?id=${event.meetingId}`)}
                          className="flex w-full items-center gap-2 rounded-md border border-border bg-secondary/60 px-3 py-2 text-left text-sm font-medium transition-colors hover:bg-secondary"
                        >
                          <MeetilyGlyph name="recall" className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                          <span className="min-w-0 flex-1 truncate">{linkedMeeting?.title ?? 'Linked recording'}</span>
                        </button>
                        {linkedMeeting?.hasSummary && linkedMeeting.summarySnippet && (
                          <p className="line-clamp-3 text-xs leading-5 text-muted-foreground">{linkedMeeting.summarySnippet}</p>
                        )}
                        <Button variant="outline" size="sm" onClick={() => void handleUnlink()} disabled={isUnlinking}>
                          {isUnlinking ? 'Unlinking…' : 'Unlink'}
                        </Button>
                      </div>
                    )
                  ) : (
                    <Button variant="outline" size="sm" onClick={() => setIsPickerOpen(true)}>
                      Link recording
                    </Button>
                  )}
                </div>
              </div>
            </>
          )}
        </SheetContent>
      </Sheet>

      <LinkPickerDialog
        eventId={isPickerOpen ? event?.id ?? null : null}
        eventTitle={event?.title}
        onClose={() => setIsPickerOpen(false)}
        onLinked={() => {
          setIsPickerOpen(false);
          onEventChanged();
        }}
      />
    </>
  );
}

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="app-eyebrow mb-1">{label}</p>
      <p className="text-sm text-foreground">{value}</p>
    </div>
  );
}

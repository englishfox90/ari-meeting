'use client';

import { useEffect, useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { calendarService } from '@/services/calendarService';
import type { MeetingCandidate } from '@/types/calendar';

function formatCandidateDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'Date unavailable';
  return new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(date);
}

interface LinkPickerDialogProps {
  eventId: string | null;
  eventTitle?: string;
  onClose: () => void;
  onLinked: (meetingId: string) => void;
}

/**
 * Small modal for manually linking a calendar event to a saved recording.
 * Populated from `calendar_suggest_meetings` — real candidates only, no
 * invented matches.
 */
export function LinkPickerDialog({ eventId, eventTitle, onClose, onLinked }: LinkPickerDialogProps) {
  const [candidates, setCandidates] = useState<MeetingCandidate[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [linkingId, setLinkingId] = useState<string | null>(null);

  useEffect(() => {
    if (!eventId) return;
    let cancelled = false;
    setIsLoading(true);
    setError(null);
    setCandidates([]);

    calendarService
      .suggestMeetings(eventId)
      .then((results) => {
        if (!cancelled) setCandidates(results);
      })
      .catch((err) => {
        console.error('Failed to load link candidates:', err);
        if (!cancelled) setError('Could not load recordings near this event.');
      })
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [eventId]);

  const handleLink = async (meetingId: string) => {
    if (!eventId) return;
    setLinkingId(meetingId);
    try {
      await calendarService.linkMeeting(eventId, meetingId);
      onLinked(meetingId);
    } catch (err) {
      console.error('Failed to link meeting:', err);
      setError('Could not link this recording. Try again.');
    } finally {
      setLinkingId(null);
    }
  };

  return (
    <Dialog open={eventId !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-[28rem]">
        <DialogHeader>
          <DialogTitle>Link a recording</DialogTitle>
          <DialogDescription>
            {eventTitle ? `Choose a recording near “${eventTitle}”.` : 'Choose a recording near this event.'}
          </DialogDescription>
        </DialogHeader>

        {isLoading ? (
          <div className="flex items-center gap-2 py-6 text-sm text-muted-foreground" role="status">
            <MeetilyGlyph name="theme-system" className="size-4 animate-spin" />
            Looking for nearby recordings…
          </div>
        ) : error ? (
          <p className="py-4 text-sm text-destructive" role="alert">{error}</p>
        ) : candidates.length === 0 ? (
          <p className="py-4 text-sm text-muted-foreground">
            No recordings were made near this event&apos;s time.
          </p>
        ) : (
          <ul className="max-h-72 space-y-1 overflow-y-auto">
            {candidates.map((candidate) => (
              <li key={candidate.id}>
                <button
                  type="button"
                  onClick={() => void handleLink(candidate.id)}
                  disabled={linkingId !== null}
                  className="flex w-full items-center justify-between gap-3 rounded-md px-3 py-2.5 text-left transition-colors hover:bg-secondary disabled:cursor-not-allowed disabled:opacity-60"
                >
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-medium">{candidate.title}</span>
                    <span className="mt-0.5 block text-xs text-muted-foreground">{formatCandidateDate(candidate.createdAt)}</span>
                  </span>
                  {linkingId === candidate.id ? (
                    <MeetilyGlyph name="theme-system" className="size-4 shrink-0 animate-spin text-muted-foreground" />
                  ) : (
                    <span className="shrink-0 text-xs font-medium text-muted-foreground group-hover:text-foreground">Link</span>
                  )}
                </button>
              </li>
            ))}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

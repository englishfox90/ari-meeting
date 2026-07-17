'use client';

// A subtle, non-blocking strip shown at the top of the meeting-details view
// while the post-recording pipeline runs for THIS meeting. It reflects the real
// per-meeting phase from MeetingProcessingContext (No-Fake-State: no invented
// counts or percentages) and lets the user keep working / navigate away.
//
// Renders nothing unless the meeting has an active or errored pipeline entry.

import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { useMeetingProcessing } from '@/contexts/MeetingProcessingContext';

interface MeetingProcessingBannerProps {
  meetingId: string;
}

export function MeetingProcessingBanner({ meetingId }: MeetingProcessingBannerProps) {
  const { states, retry } = useMeetingProcessing();
  const entry = states.get(meetingId);

  // Nothing to show for no-entry or terminal-success.
  if (!entry || entry.phase === 'complete') return null;

  if (entry.phase === 'error') {
    const what = entry.stage === 'diarization' ? 'identify speakers' : 'generate the summary';
    return (
      <div
        className={cn(
          'flex items-center gap-3 border-b border-destructive/25 bg-destructive/5 px-6 py-2.5 text-sm sm:px-8',
        )}
      >
        <span className="flex-1 text-destructive">
          Couldn&rsquo;t {what}
          {entry.error ? ` — ${entry.error}` : '.'}
        </span>
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="shrink-0"
          onClick={() => retry(meetingId)}
        >
          Retry
        </Button>
      </div>
    );
  }

  const label =
    entry.phase === 'diarizing' ? 'Identifying speakers…' : 'Generating summary…';

  return (
    <div
      className={cn(
        'flex items-center gap-3 border-b border-border bg-secondary/40 px-6 py-2.5 text-sm sm:px-8',
      )}
    >
      <span
        aria-hidden="true"
        className="size-4 shrink-0 animate-spin rounded-full border-2 border-accent/25 border-t-accent motion-reduce:animate-none"
      />
      <span className="text-muted-foreground">{label}</span>
    </div>
  );
}

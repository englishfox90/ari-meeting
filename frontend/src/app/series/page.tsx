'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowRightIcon } from '@heroicons/react/24/outline';
import { AppState } from '@/components/app-shell/AppState';
import { PageHeader } from '@/components/app-shell/PageHeader';
import { Surface } from '@/components/app-shell/Surface';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Popover, PopoverTrigger, PopoverContent } from '@/components/ui/popover';
import { useSeries } from '@/contexts/SeriesContext';
import { seriesService } from '@/services/seriesService';
import { cn } from '@/lib/utils';
import type { SeriesSummary } from '@/types/series';

function formatRelativeTime(value: string | null | undefined): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;

  const diffMs = Date.now() - date.getTime();
  const diffMinutes = Math.round(diffMs / 60_000);
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

  if (Math.abs(diffMinutes) < 60) return rtf.format(-diffMinutes, 'minute');
  const diffHours = Math.round(diffMinutes / 60);
  if (Math.abs(diffHours) < 24) return rtf.format(-diffHours, 'hour');
  const diffDays = Math.round(diffHours / 24);
  if (Math.abs(diffDays) < 30) return rtf.format(-diffDays, 'day');
  const diffMonths = Math.round(diffDays / 30);
  if (Math.abs(diffMonths) < 12) return rtf.format(-diffMonths, 'month');
  return rtf.format(-Math.round(diffMonths / 12), 'year');
}

function SeriesRow({ series }: { series: SeriesSummary }) {
  const router = useRouter();
  const lastMeeting = formatRelativeTime(series.lastMeetingTime);

  return (
    <button
      type="button"
      onClick={() => router.push(`/series-details?id=${series.id}`)}
      className="group flex min-h-[4.75rem] w-full items-start justify-between gap-5 px-5 py-4 text-left transition-[background,transform] hover:bg-secondary/70 active:translate-y-px focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
    >
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-2">
          <span className="truncate text-sm font-semibold tracking-[-0.01em]">{series.title}</span>
          {series.detectedType && (
            <span className="shrink-0 rounded-full border border-border bg-secondary px-2 py-0.5 text-[0.6875rem] font-medium capitalize text-muted-foreground">
              {series.detectedType}
            </span>
          )}
        </span>
        <span className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-muted-foreground">
          <span>{series.meetingCount} {series.meetingCount === 1 ? 'meeting' : 'meetings'}</span>
          {lastMeeting && (
            <>
              <span aria-hidden="true">·</span>
              <span>Last {lastMeeting}</span>
            </>
          )}
          {series.cadence && (
            <>
              <span aria-hidden="true">·</span>
              <span className="capitalize">{series.cadence}</span>
            </>
          )}
        </span>
      </span>
      <ArrowRightIcon className="mt-1 size-4 shrink-0 text-muted-foreground transition-transform group-hover:translate-x-0.5 motion-reduce:transform-none" aria-hidden="true" />
    </button>
  );
}

export default function SeriesPage() {
  const router = useRouter();
  const { series, loading, error, refresh } = useSeries();
  const [rescanning, setRescanning] = useState(false);
  const [rescanNote, setRescanNote] = useState<string | null>(null);
  const [createOpen, setCreateOpen] = useState(false);
  const [newTitle, setNewTitle] = useState('');
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  // The series list lives in a context that loads once at app startup, so a
  // series created after boot (via New series / attach-in-note) wouldn't appear
  // until relaunch. Re-read on every visit to this page so it's always current.
  useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleCreate = async () => {
    const title = newTitle.trim();
    if (!title) return;
    setCreating(true);
    setCreateError(null);
    try {
      const newId = await seriesService.create(title);
      setCreateOpen(false);
      setNewTitle('');
      router.push(`/series-details?id=${newId}`);
    } catch (err) {
      setCreateError(
        err instanceof Error ? err.message : 'Could not create series.',
      );
    } finally {
      setCreating(false);
    }
  };

  const handleRescan = async () => {
    setRescanning(true);
    setRescanNote(null);
    try {
      const created = await seriesService.rescanHeuristic();
      await refresh();
      setRescanNote(
        created === 0
          ? 'No new series found from titles.'
          : `Detected ${created} new ${created === 1 ? 'series' : 'series'} from titles.`,
      );
    } catch (err) {
      setRescanNote(
        err instanceof Error ? err.message : 'Could not detect series from titles.',
      );
    } finally {
      setRescanning(false);
    }
  };

  if (!seriesService.isAvailable()) {
    return (
      <div className="app-page">
        <PageHeader eyebrow="Recurring" title="Series" description="Recurring meetings grouped into a connected record." />
        <div className="mt-7">
          <AppState
            kind="disabled"
            title="Series are available in the desktop app"
            description="Run Ari Meeting as a desktop app to see meetings grouped into recurring series."
          />
        </div>
      </div>
    );
  }

  return (
    <div className="app-page">
      <PageHeader
        eyebrow="Recurring"
        title="Series"
        description="Recurring meetings grouped into a connected record."
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => void handleRescan()} disabled={rescanning}>
              {rescanning ? 'Detecting…' : 'Detect from titles'}
            </Button>
            <Popover
              open={createOpen}
              onOpenChange={(next) => {
                setCreateOpen(next);
                if (next) {
                  setCreateError(null);
                  setNewTitle('');
                }
              }}
            >
              <PopoverTrigger asChild>
                <Button variant="outline" size="sm">New series</Button>
              </PopoverTrigger>
              <PopoverContent align="end" className="w-72 p-3">
                <p className="mb-1.5 text-[0.6875rem] font-medium uppercase tracking-wide text-muted-foreground">
                  New series
                </p>
                <div className="flex items-center gap-2">
                  <Input
                    autoFocus
                    value={newTitle}
                    onChange={(e) => setNewTitle(e.target.value)}
                    placeholder="Series title"
                    aria-label="New series title"
                    disabled={creating}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') {
                        e.preventDefault();
                        void handleCreate();
                      }
                    }}
                    className="h-8 text-sm"
                  />
                  <Button
                    size="sm"
                    disabled={creating || newTitle.trim().length === 0}
                    onClick={() => void handleCreate()}
                  >
                    {creating ? 'Creating…' : 'Create'}
                  </Button>
                </div>
                {createError && (
                  <p className="mt-2 text-xs text-destructive" role="alert">{createError}</p>
                )}
              </PopoverContent>
            </Popover>
          </div>
        }
      />
      {rescanNote && (
        <p className={cn('mt-4 text-xs text-muted-foreground')} role="status" aria-live="polite">
          {rescanNote}
        </p>
      )}
      <section aria-label="Meeting series list" className="mt-7">
        {loading ? (
          <AppState
            kind="loading"
            title="Loading series"
            description="Reading recurring meeting series from your local database."
          />
        ) : error ? (
          <AppState
            kind="error"
            title="Series could not be loaded"
            description={error}
            action={<Button variant="outline" onClick={() => void refresh()}>Try again</Button>}
          />
        ) : series.length === 0 ? (
          <AppState
            kind="empty"
            title="No recurring series yet"
            description="Series form automatically when you record meetings linked to a recurring calendar event."
          />
        ) : (
          <Surface className="divide-y divide-border/70 overflow-hidden p-0">
            {series.map((item) => (
              <SeriesRow key={item.id} series={item} />
            ))}
          </Surface>
        )}
      </section>
    </div>
  );
}

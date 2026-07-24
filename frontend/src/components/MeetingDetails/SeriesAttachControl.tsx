"use client";

import { useCallback, useEffect, useState } from 'react';
import { PlusIcon, EllipsisHorizontalIcon } from '@heroicons/react/24/outline';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  Popover,
  PopoverTrigger,
  PopoverContent,
} from '@/components/ui/popover';
import {
  Command,
  CommandInput,
  CommandList,
  CommandEmpty,
  CommandGroup,
  CommandItem,
} from '@/components/ui/command';
import { seriesService } from '@/services/seriesService';
import { cn } from '@/lib/utils';
import type { SeriesForMeeting, SeriesSummary } from '@/types/series';

interface SeriesAttachControlProps {
  meetingId: string;
  meetingTitle: string;
  seriesInfo: SeriesForMeeting | null;
  onChanged: () => void;
}

type View = 'menu' | 'picker';

/**
 * Secondary control in the meeting-note eyebrow row for attaching/detaching a
 * meeting to a series. Deliberately quiet (Signal Rule — no amber; this is not
 * the primary action on the screen). Honest empty/loading/error states — never
 * fakes a series list. All mutations call `onChanged()` so the panel re-fetches
 * membership and the breadcrumb updates live.
 */
export function SeriesAttachControl({
  meetingId,
  meetingTitle,
  seriesInfo,
  onChanged,
}: SeriesAttachControlProps) {
  const inSeries = seriesInfo !== null;
  const [open, setOpen] = useState(false);
  const [view, setView] = useState<View>(inSeries ? 'menu' : 'picker');
  const [list, setList] = useState<SeriesSummary[] | null>(null);
  const [listLoading, setListLoading] = useState(false);
  const [listError, setListError] = useState<string | null>(null);
  const [newTitle, setNewTitle] = useState(meetingTitle);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  // meetingTitle can arrive/settle after this component has already mounted
  // (or been reused across a client-side navigation); keep the suggested
  // series name in sync whenever it changes and the popover isn't mid-edit.
  useEffect(() => {
    if (!open) {
      setNewTitle(meetingTitle);
    }
  }, [meetingTitle, open]);

  const loadList = useCallback(async () => {
    setListLoading(true);
    setListError(null);
    try {
      const rows = await seriesService.list();
      setList(rows);
    } catch (err) {
      setListError(
        err instanceof Error ? err.message : 'Could not load series.',
      );
      setList(null);
    } finally {
      setListLoading(false);
    }
  }, []);

  const handleOpenChange = useCallback(
    (next: boolean) => {
      setOpen(next);
      if (next) {
        // Reset transient state each time the popover opens.
        setView(inSeries ? 'menu' : 'picker');
        setActionError(null);
        setNewTitle(meetingTitle);
        void loadList();
      }
    },
    [inSeries, meetingTitle, loadList],
  );

  const finish = useCallback(() => {
    setOpen(false);
    onChanged();
  }, [onChanged]);

  // Link this meeting to `seriesId`, first unlinking the current series (if any)
  // so a meeting only ever belongs to one series here.
  const attachTo = useCallback(
    async (seriesId: string) => {
      setBusy(true);
      setActionError(null);
      try {
        if (seriesInfo && seriesInfo.seriesId !== seriesId) {
          await seriesService.unlink(meetingId, seriesInfo.seriesId);
        }
        await seriesService.link(meetingId, seriesId);
        finish();
      } catch (err) {
        setActionError(
          err instanceof Error ? err.message : 'Could not attach to series.',
        );
      } finally {
        setBusy(false);
      }
    },
    [meetingId, seriesInfo, finish],
  );

  const createAndAttach = useCallback(async () => {
    const title = newTitle.trim();
    if (!title) return;
    setBusy(true);
    setActionError(null);
    try {
      const newId = await seriesService.create(title);
      if (seriesInfo) {
        await seriesService.unlink(meetingId, seriesInfo.seriesId);
      }
      await seriesService.link(meetingId, newId);
      finish();
    } catch (err) {
      setActionError(
        err instanceof Error ? err.message : 'Could not create series.',
      );
    } finally {
      setBusy(false);
    }
  }, [newTitle, meetingId, seriesInfo, finish]);

  const removeFromSeries = useCallback(async () => {
    if (!seriesInfo) return;
    setBusy(true);
    setActionError(null);
    try {
      await seriesService.unlink(meetingId, seriesInfo.seriesId);
      finish();
    } catch (err) {
      setActionError(
        err instanceof Error ? err.message : 'Could not remove from series.',
      );
    } finally {
      setBusy(false);
    }
  }, [meetingId, seriesInfo, finish]);

  if (!seriesService.isAvailable()) return null;

  const triggerClasses =
    'inline-flex items-center gap-1 rounded-sm px-1.5 py-0.5 text-[0.6875rem] font-medium text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring';

  const pickerBody = (
    <div className="flex flex-col">
      <Command shouldFilter={!inSeries}>
        <CommandInput placeholder="Search series…" />
        <CommandList>
          {listLoading ? (
            <p className="px-3 py-4 text-xs text-muted-foreground">Loading series…</p>
          ) : listError ? (
            <p className="px-3 py-4 text-xs text-destructive">{listError}</p>
          ) : (
            <>
              <CommandEmpty>No series yet.</CommandEmpty>
              {list && list.length > 0 && (
                <CommandGroup heading="Existing series">
                  {list
                    .filter((s) => s.id !== seriesInfo?.seriesId)
                    .map((s) => (
                      <CommandItem
                        key={s.id}
                        value={s.title}
                        disabled={busy}
                        onSelect={() => void attachTo(s.id)}
                      >
                        <span className="truncate">{s.title}</span>
                        <span className="ml-auto shrink-0 text-[0.6875rem] text-muted-foreground">
                          {s.meetingCount} {s.meetingCount === 1 ? 'meeting' : 'meetings'}
                        </span>
                      </CommandItem>
                    ))}
                </CommandGroup>
              )}
            </>
          )}
        </CommandList>
      </Command>
      <div className="border-t border-border p-2.5">
        <p className="mb-1.5 px-1 text-[0.6875rem] font-medium uppercase tracking-wide text-muted-foreground">
          Create new series
        </p>
        <div className="flex items-center gap-2">
          <Input
            value={newTitle}
            onChange={(e) => setNewTitle(e.target.value)}
            placeholder="Series title"
            aria-label="New series title"
            disabled={busy}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                void createAndAttach();
              }
            }}
            className="h-8 text-sm"
          />
          <Button
            size="sm"
            variant="outline"
            disabled={busy || newTitle.trim().length === 0}
            onClick={() => void createAndAttach()}
          >
            Create
          </Button>
        </div>
      </div>
    </div>
  );

  const menuBody = (
    <div className="flex flex-col p-1">
      <button
        type="button"
        disabled={busy}
        onClick={() => setView('picker')}
        className={cn(
          'flex w-full items-center rounded-sm px-2.5 py-2 text-left text-sm transition-colors hover:bg-secondary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring disabled:opacity-50',
        )}
      >
        Move to another series
      </button>
      <button
        type="button"
        disabled={busy}
        onClick={() => void removeFromSeries()}
        className={cn(
          'flex w-full items-center rounded-sm px-2.5 py-2 text-left text-sm text-destructive transition-colors hover:bg-secondary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring disabled:opacity-50',
        )}
      >
        Remove from series
      </button>
    </div>
  );

  return (
    <Popover open={open} onOpenChange={handleOpenChange}>
      <PopoverTrigger asChild>
        {inSeries ? (
          <button
            type="button"
            className={cn('grid size-5 place-items-center', triggerClasses)}
            aria-label="Change series membership"
            title="Change series"
          >
            <EllipsisHorizontalIcon className="size-4" aria-hidden="true" />
          </button>
        ) : (
          <button type="button" className={triggerClasses} aria-label="Add meeting to a series">
            <PlusIcon className="size-3.5" aria-hidden="true" />
            <span>Add to series</span>
          </button>
        )}
      </PopoverTrigger>
      <PopoverContent align="start" className="w-80 p-0">
        {actionError && (
          <p className="border-b border-border px-3 py-2 text-xs text-destructive" role="alert">
            {actionError}
          </p>
        )}
        {view === 'menu' ? menuBody : pickerBody}
      </PopoverContent>
    </Popover>
  );
}

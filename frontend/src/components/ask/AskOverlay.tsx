'use client';

/**
 * AskOverlay — the floating, expandable Ask window (a custom fixed panel anchored
 * bottom-right, above the launcher). Header shows the auto-derived scope, a scope
 * toggle when on a meeting, and a recent-conversations menu (last 7 days) with
 * new + delete. Body is the shared AskConsole. Escape closes it.
 */

import { useEffect } from 'react';
import { XMarkIcon, PlusIcon, ClockIcon, TrashIcon } from '@heroicons/react/24/outline';
import { useAsk } from '@/contexts/AskContext';
import { AskConsole } from './AskConsole';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
} from '@/components/ui/dropdown-menu';
import { cn } from '@/lib/utils';

export function AskOverlay() {
  const {
    isOpen,
    close,
    scope,
    setScope,
    conversations,
    newConversation,
    loadConversation,
    removeConversation,
  } = useAsk();

  useEffect(() => {
    if (!isOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') close();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [isOpen, close]);

  if (!isOpen) return null;

  const scopeLabel = scope.isMeetingScoped
    ? `Asking: ${scope.meetingTitle ?? 'this meeting'}`
    : scope.isSeriesScoped
      ? `Asking: ${scope.seriesTitle ?? 'this series'}`
      : 'Asking all meetings';

  // The scope toggle appears whenever a narrower scope than "all" is available: on a meeting,
  // on a series, or on a meeting that belongs to a series.
  const showScopeToggle = scope.onMeeting || scope.hasSeries;
  const pillClass = (active: boolean) =>
    cn(
      'rounded-full border px-2.5 py-0.5 text-[0.6875rem] font-medium transition-colors',
      active
        ? 'border-accent bg-accent text-accent-foreground'
        : 'border-border bg-secondary text-muted-foreground hover:text-foreground',
    );

  return (
    <div
      role="dialog"
      aria-modal="false"
      aria-label="Ask meetings"
      className="fixed bottom-24 right-6 z-40 flex h-[min(70vh,600px)] w-[min(calc(100vw-3rem),420px)] flex-col overflow-hidden rounded-[14px] border border-border bg-background shadow-lg"
    >
      <header className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
        <div className="min-w-0">
          <p className="app-eyebrow">Local recall</p>
          <p className="truncate text-sm font-medium text-foreground" title={scopeLabel}>
            {scopeLabel}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon" aria-label="Recent conversations">
                <ClockIcon className="size-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-64">
              <DropdownMenuItem onSelect={() => newConversation()}>
                <PlusIcon className="size-4" />
                New conversation
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuLabel>Recent (7 days)</DropdownMenuLabel>
              {conversations.length === 0 ? (
                <p className="px-2 py-1.5 text-xs text-muted-foreground">No recent conversations.</p>
              ) : (
                <div className="max-h-56 overflow-y-auto">
                  {conversations.map((conversation) => (
                    <div
                      key={conversation.id}
                      className="flex items-center gap-1 rounded-sm px-1 hover:bg-secondary"
                    >
                      <button
                        type="button"
                        onClick={() => loadConversation(conversation.id)}
                        className="min-w-0 flex-1 truncate px-1 py-1.5 text-left text-xs text-foreground"
                        title={conversation.title ?? 'Untitled conversation'}
                      >
                        {conversation.title ?? 'Untitled conversation'}
                      </button>
                      <button
                        type="button"
                        onClick={() => removeConversation(conversation.id)}
                        aria-label="Delete conversation"
                        className="shrink-0 rounded-sm p-1 text-muted-foreground hover:text-foreground"
                      >
                        <TrashIcon className="size-3.5" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
          <Button variant="ghost" size="icon" onClick={close} aria-label="Close Ask">
            <XMarkIcon className="size-4" />
          </Button>
        </div>
      </header>

      {showScopeToggle && (
        <div className="flex items-center gap-1 border-b border-border px-4 py-2">
          {scope.onMeeting && (
            <button
              type="button"
              onClick={() => setScope('meeting')}
              aria-pressed={scope.isMeetingScoped}
              className={pillClass(scope.isMeetingScoped)}
            >
              This meeting
            </button>
          )}
          {scope.hasSeries && (
            <button
              type="button"
              onClick={() => setScope('series')}
              aria-pressed={scope.isSeriesScoped}
              className={pillClass(scope.isSeriesScoped)}
            >
              This series
            </button>
          )}
          <button
            type="button"
            onClick={() => setScope('global')}
            aria-pressed={!scope.isMeetingScoped && !scope.isSeriesScoped}
            className={pillClass(!scope.isMeetingScoped && !scope.isSeriesScoped)}
          >
            All meetings
          </button>
        </div>
      )}

      <AskConsole variant="overlay" />
    </div>
  );
}

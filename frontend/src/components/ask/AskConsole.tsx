'use client';

/**
 * AskConsole — the shared body of the Ask engine: the message log, the honest
 * empty / loading / error states, and the composer. Both surfaces render it:
 * the floating AskOverlay and the full-window /chat page. It reads everything
 * from AskContext, so the two surfaces stay in lockstep automatically.
 *
 * Audio: badges seek-and-play only when a meeting audio player is actually
 * mounted (useAudioPlayback() is non-null and ready). App-wide the overlay sits
 * outside any player, so badges are display-only there — never faked.
 */

import { KeyboardEvent, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { PaperAirplaneIcon } from '@heroicons/react/24/outline';
import { useAsk } from '@/contexts/AskContext';
import { useAudioPlayback } from '@/contexts/AudioPlaybackContext';
import { AppState } from '@/components/app-shell/AppState';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { cn } from '@/lib/utils';
import { AskMessage } from './AskMessage';

const MEETING_PROMPTS = [
  'Summarize the key decisions',
  'What action items came up?',
  'What did we disagree on?',
];

const SERIES_PROMPTS = [
  'What changed since last time?',
  'What are the recurring themes?',
  'Which action items are still open?',
];

const GLOBAL_PROMPTS = [
  'What decisions were made recently?',
  'Which meetings mention the roadmap?',
  'What action items are still open?',
];

export function AskConsole({ variant = 'overlay' }: { variant?: 'overlay' | 'page' }) {
  const router = useRouter();
  const { scope, messages, isAsking, error, ask, meetingAudio } = useAsk();
  const player = useAudioPlayback();
  const [draft, setDraft] = useState('');
  const logRef = useRef<HTMLDivElement | null>(null);

  // Seek helper only when the thread is scoped to a meeting AND we have a way to play it:
  // an in-tree player (e.g. /chat inside a provider), or the meeting-details page's player
  // bridged in via AskContext (the usual case for the global overlay). Otherwise badges are
  // display-only (No-Fake-State).
  const onSeek = useMemo(() => {
    if (!scope.isMeetingScoped || !scope.meetingId) return undefined;
    if (player && player.status === 'ready') return (seconds: number) => player.seekAndPlay(seconds);
    if (meetingAudio && meetingAudio.meetingId === scope.meetingId) return meetingAudio.seek;
    return undefined;
  }, [player, scope.isMeetingScoped, scope.meetingId, meetingAudio]);

  const suggestions = scope.isMeetingScoped
    ? MEETING_PROMPTS
    : scope.isSeriesScoped
      ? SERIES_PROMPTS
      : GLOBAL_PROMPTS;
  const isEmpty = messages.length === 0;

  // Once the streaming answer has produced its first token, the assistant bubble
  // renders the text — so we swap the "thinking" dots out for the live answer.
  const lastMessage = messages[messages.length - 1];
  const hasStreamingText =
    isAsking && lastMessage?.role === 'assistant' && lastMessage.content !== '';

  // Auto-scroll to the newest turn.
  useEffect(() => {
    const el = logRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, isAsking]);

  const submit = () => {
    const trimmed = draft.trim();
    if (!trimmed || isAsking) return;
    setDraft('');
    void ask(trimmed);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div
        ref={logRef}
        role="log"
        aria-live="polite"
        aria-label="Ask conversation"
        className={cn(
          'min-h-0 flex-1 space-y-4 overflow-y-auto',
          variant === 'overlay' ? 'px-4 py-4' : 'py-6',
        )}
      >
        {isEmpty && !error && (
          <div className="flex h-full flex-col items-center justify-center px-2 text-center">
            <span className="mb-3 grid size-10 place-items-center rounded-md bg-secondary text-muted-foreground">
              <MeetilyGlyph name="recall" className="size-5" />
            </span>
            <p className="text-sm font-medium text-foreground">
              {scope.isMeetingScoped
                ? 'Ask about this meeting'
                : scope.isSeriesScoped
                  ? 'Ask about this series'
                  : 'Ask across all your meetings'}
            </p>
            <p className="mt-1 max-w-xs text-xs leading-5 text-muted-foreground">
              Questions and excerpts stay on this device and use only your configured local model.
            </p>
            <div className="mt-4 flex flex-wrap justify-center gap-2">
              {suggestions.map((prompt) => (
                <button
                  key={prompt}
                  type="button"
                  onClick={() => ask(prompt)}
                  className="rounded-full border border-border bg-secondary px-3 py-1 text-xs text-muted-foreground transition-colors hover:border-accent hover:text-foreground"
                >
                  {prompt}
                </button>
              ))}
            </div>
          </div>
        )}

        {messages.map((message) => {
          // While streaming, an assistant bubble starts empty — don't render an
          // empty box; the thinking indicator below stands in until text arrives.
          if (message.role === 'assistant' && message.content === '') return null;
          return (
            <div key={message.id}>
              <AskMessage message={message} onSeek={onSeek} />
            </div>
          );
        })}

        {isAsking && !hasStreamingText && (
          <div className="flex items-center gap-2 text-xs text-muted-foreground" aria-live="polite">
            <span className="flex items-center gap-1" aria-hidden="true">
              <span
                className="ask-thinking-dot size-1.5 rounded-full bg-current"
                style={{ animationDelay: '-0.32s' }}
              />
              <span
                className="ask-thinking-dot size-1.5 rounded-full bg-current"
                style={{ animationDelay: '-0.16s' }}
              />
              <span className="ask-thinking-dot size-1.5 rounded-full bg-current" />
            </span>
            Searching local meeting excerpts…
          </div>
        )}

        {error && (
          <AppState
            kind="model"
            compact
            title="Local recall is unavailable"
            description={`${error} — check your configured local model in settings.`}
            action={
              <Button variant="outline" size="sm" onClick={() => router.push('/settings')}>
                <MeetilyGlyph name="settings" className="size-4" />
                Review local model settings
              </Button>
            }
          />
        )}
      </div>

      <div
        className={cn(
          'border-t border-border',
          variant === 'overlay' ? 'p-3' : 'pt-4',
        )}
      >
        <div className="flex items-end gap-2">
          <Textarea
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={onKeyDown}
            rows={variant === 'overlay' ? 2 : 3}
            maxLength={1000}
            placeholder={
              scope.isMeetingScoped
                ? 'Ask about this meeting…'
                : scope.isSeriesScoped
                  ? 'Ask about this series…'
                  : 'Ask about your meetings…'
            }
            className="min-h-0 flex-1 resize-none"
            aria-label="Your question"
          />
          <Button type="button" size="icon" onClick={submit} disabled={!draft.trim() || isAsking} aria-label="Ask">
            <PaperAirplaneIcon className="size-4" />
          </Button>
        </div>
        <p className="mt-1.5 text-[0.65rem] text-muted-foreground">
          Enter to send · Shift+Enter for a new line
        </p>
      </div>
    </div>
  );
}

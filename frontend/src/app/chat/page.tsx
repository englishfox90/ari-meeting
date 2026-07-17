'use client';

/**
 * /chat — the full-window version of the shared Ask engine. Same AskContext,
 * same message + source components, same composer as the floating overlay; this
 * is just the roomy surface with the recent-conversation rail. Multi-turn,
 * local-only recall (No-Fake-State: honest empty / loading / error states, and
 * citations are inline [S<n>] chips with a hover-card preview, not a separate rail).
 */

import { PlusIcon, TrashIcon } from '@heroicons/react/24/outline';
import { PageHeader } from '@/components/app-shell/PageHeader';
import { AskConsole } from '@/components/ask/AskConsole';
import { useAsk } from '@/contexts/AskContext';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

export default function ChatPage() {
  const {
    scope,
    conversationId,
    conversations,
    newConversation,
    loadConversation,
    removeConversation,
  } = useAsk();

  const scopeLabel = scope.isMeetingScoped
    ? `Asking: ${scope.meetingTitle ?? 'this meeting'}`
    : scope.isSeriesScoped
      ? `Asking: ${scope.seriesTitle ?? 'this series'}`
      : 'Asking all meetings';

  return (
    <div className="app-page flex min-h-0 flex-col">
      <PageHeader
        eyebrow="Local meeting recall"
        title="Ask meetings"
        description="Questions and excerpts stay on this device and use only your configured local model."
        actions={
          <Button variant="outline" size="sm" onClick={() => newConversation()}>
            <PlusIcon className="size-4" />
            New conversation
          </Button>
        }
      />

      <div className="mt-6 grid min-h-0 flex-1 gap-8 xl:grid-cols-[minmax(0,1fr)_16rem]">
        <div className="flex min-h-0 flex-col">
          <p className="app-eyebrow">{scopeLabel}</p>
          <AskConsole variant="page" />
        </div>

        <aside aria-label="Recent conversations" className="hidden xl:block xl:border-l xl:border-border xl:pl-6">
          <p className="app-eyebrow">Recent (7 days)</p>
          {conversations.length === 0 ? (
            <p className="mt-3 text-xs text-muted-foreground">
              No recent conversations. Ask a question to start one.
            </p>
          ) : (
            <ul className="mt-3 space-y-1">
              {conversations.map((conversation) => (
                <li
                  key={conversation.id}
                  className={cn(
                    'flex items-center gap-1 rounded-md border px-1 transition-colors',
                    conversation.id === conversationId
                      ? 'border-accent bg-secondary'
                      : 'border-transparent hover:bg-secondary',
                  )}
                >
                  <button
                    type="button"
                    onClick={() => loadConversation(conversation.id)}
                    className="min-w-0 flex-1 truncate px-1.5 py-1.5 text-left text-xs text-foreground"
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
                </li>
              ))}
            </ul>
          )}
        </aside>
      </div>
    </div>
  );
}

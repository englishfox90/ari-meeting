'use client';

/**
 * AskMessage — one turn in the Ask thread.
 *
 * User turns render as a right-aligned bubble. Assistant turns render as a
 * left-aligned block of safe Markdown (ReactMarkdown + remarkGfm only, no
 * raw-HTML plugin — untrusted model output is never rendered as raw HTML), with
 * two kinds of inline decoration applied to the text:
 *
 *  - `[S<n>]` SOURCE CITATIONS → a small chip linking to source n (the backend
 *    has already dropped any out-of-range n, so every chip resolves to a real
 *    source; No-Fake-State). Clicking navigates to that meeting.
 *  - `@ref(MM:SS)` / legacy `[MM:SS]` TIMESTAMPS → an inline play-badge. In
 *    meeting-scoped mode with an audio player (`onSeek`) it seeks-and-plays;
 *    otherwise it's an honest display-only pill (no faked playback).
 *
 * Answers with neither token render as plain Markdown.
 */

import { Children, Fragment, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import ReactMarkdown, { type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { matchTimestampTokens } from '@/lib/summary-timestamps';
import { cn } from '@/lib/utils';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import type { AskMessage as AskMessageModel, LocalRecallSource } from '@/services/recallService';

// Inline timestamp play-badge (mirrors BADGE_CLASSNAME from summary-ref-badge-plugin.ts).
const BADGE_CLASSNAME =
  'inline-flex items-center gap-0.5 rounded-full border border-border bg-secondary ' +
  'px-1.5 py-0.5 font-mono text-xs tabular-nums text-foreground align-baseline ' +
  'transition-colors hover:border-accent hover:bg-accent hover:text-accent-foreground ' +
  'cursor-pointer select-none';

const BADGE_STATIC_CLASSNAME =
  'inline-flex items-center gap-0.5 rounded-full border border-border bg-secondary ' +
  'px-1.5 py-0.5 font-mono text-xs tabular-nums text-muted-foreground align-baseline select-none';

// Small superscript source-citation chip.
const CITE_CLASSNAME =
  'ml-0.5 inline-flex items-center rounded border border-border bg-secondary px-1 ' +
  'align-super text-[10px] font-semibold leading-none text-muted-foreground ' +
  'transition-colors hover:border-accent hover:bg-accent hover:text-accent-foreground ' +
  'cursor-pointer select-none';

const CITE_RE = /\[S(\d+)\]/g;

interface DecoratorContext {
  onSeek?: (seconds: number) => void;
  sources?: LocalRecallSource[];
  onCite: (source: LocalRecallSource) => void;
}

interface DecorToken {
  index: number;
  length: number;
  kind: 'time' | 'cite';
  seconds?: number;
  label?: string;
  sourceIndex?: number;
}

function collectTokens(text: string): DecorToken[] {
  const tokens: DecorToken[] = matchTimestampTokens(text).map((t) => ({
    index: t.index,
    length: t.length,
    kind: 'time' as const,
    seconds: t.seconds,
    label: t.label,
  }));
  CITE_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = CITE_RE.exec(text)) !== null) {
    tokens.push({ index: match.index, length: match[0].length, kind: 'cite', sourceIndex: Number(match[1]) });
  }
  return tokens.sort((a, b) => a.index - b.index);
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" className="size-3">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M4.5 5.653c0-1.427 1.529-2.33 2.779-1.643l11.54 6.347c1.295.712 1.295 2.573 0 3.286L7.28 19.99c-1.25.687-2.779-.217-2.779-1.643V5.653Z"
      />
    </svg>
  );
}

/** Hover-card contents for a [S<n>] citation: the meeting, its date, who spoke, and the
 *  cited excerpt — so citations don't clutter the chat as a separate rail. */
function SourcePreview({ source, number }: { source: LocalRecallSource; number: number }) {
  const dateValid = source.meetingDate && !Number.isNaN(new Date(source.meetingDate).getTime());
  const speakers = source.speakers.slice(0, 4);
  return (
    <div className="max-w-xs space-y-1">
      <p className="text-xs font-semibold text-foreground">
        <span className="mr-1 text-muted-foreground">S{number}</span>
        {source.title}
      </p>
      {dateValid && (
        <p className="text-[0.7rem] text-muted-foreground">
          {new Date(source.meetingDate as string).toLocaleDateString()}
        </p>
      )}
      {speakers.length > 0 && (
        <p className="text-[0.7rem] text-muted-foreground">{speakers.join(', ')}</p>
      )}
      {source.matchContext && (
        <p className="line-clamp-4 text-xs leading-5 text-muted-foreground">{source.matchContext}</p>
      )}
      <p className="text-[0.7rem] text-muted-foreground underline">Open meeting →</p>
    </div>
  );
}

/** Split one plain string into text + inline decoration nodes. */
function splitString(text: string, ctx: DecoratorContext): ReactNode {
  const tokens = collectTokens(text);
  if (tokens.length === 0) return text;

  const nodes: ReactNode[] = [];
  let cursor = 0;
  tokens.forEach((token, index) => {
    if (token.index < cursor) return; // safety: skip any overlap
    if (token.index > cursor) {
      nodes.push(<Fragment key={`text-${index}`}>{text.slice(cursor, token.index)}</Fragment>);
    }

    if (token.kind === 'time') {
      if (ctx.onSeek) {
        nodes.push(
          <button
            key={`time-${index}`}
            type="button"
            className={BADGE_CLASSNAME}
            aria-label={`Play recording from ${token.label}`}
            onClick={() => ctx.onSeek?.(token.seconds ?? 0)}
          >
            <PlayIcon />
            <span>{token.label}</span>
          </button>,
        );
      } else {
        nodes.push(
          <span key={`time-${index}`} className={BADGE_STATIC_CLASSNAME} aria-label={`Recording moment ${token.label}`}>
            {token.label}
          </span>,
        );
      }
    } else {
      const number = token.sourceIndex ?? 0;
      const source = ctx.sources?.[number - 1];
      if (source) {
        nodes.push(
          <Tooltip key={`cite-${index}`}>
            <TooltipTrigger asChild>
              <button
                type="button"
                className={CITE_CLASSNAME}
                aria-label={`Source ${number}: ${source.title}`}
                onClick={() => ctx.onCite(source)}
              >
                S{number}
              </button>
            </TooltipTrigger>
            <TooltipContent side="top" align="start" className="p-2.5">
              <SourcePreview source={source} number={number} />
            </TooltipContent>
          </Tooltip>,
        );
      } else {
        // No matching source (shouldn't happen post-verify) — keep the literal text.
        nodes.push(<Fragment key={`cite-${index}`}>{text.slice(token.index, token.index + token.length)}</Fragment>);
      }
    }
    cursor = token.index + token.length;
  });
  if (cursor < text.length) {
    nodes.push(<Fragment key="text-last">{text.slice(cursor)}</Fragment>);
  }
  return <>{nodes}</>;
}

function decorateChildren(children: ReactNode, ctx: DecoratorContext): ReactNode {
  return Children.map(children, (child) => (typeof child === 'string' ? splitString(child, ctx) : child));
}

function decoratedComponents(ctx: DecoratorContext): Components {
  const wrap = (Tag: keyof JSX.IntrinsicElements) =>
    function Wrapped({ node: _node, children, ...props }: { node?: unknown; children?: ReactNode }) {
      return <Tag {...props}>{decorateChildren(children, ctx)}</Tag>;
    };
  return {
    p: wrap('p'),
    li: wrap('li'),
    td: wrap('td'),
    th: wrap('th'),
    strong: wrap('strong'),
    em: wrap('em'),
  } as Components;
}

export function AskMessage({
  message,
  onSeek,
}: {
  message: AskMessageModel;
  onSeek?: (seconds: number) => void;
}) {
  const router = useRouter();

  if (message.role === 'user') {
    return (
      <div className="flex justify-end">
        <div className="max-w-[85%] whitespace-pre-wrap rounded-[14px] rounded-br-sm border border-border bg-secondary px-3 py-2 text-sm leading-6 text-foreground">
          {message.content}
        </div>
      </div>
    );
  }

  const hasDecorations = collectTokens(message.content).length > 0;
  const ctx: DecoratorContext = {
    onSeek,
    sources: message.sources,
    onCite: (source) => router.push(`/meeting-details?id=${source.meeting_id}`),
  };

  return (
    <div className="flex justify-start">
      <article
        aria-label="Local meeting answer"
        className={cn(
          'prose prose-sm min-w-0 max-w-none dark:prose-invert',
          'prose-headings:font-semibold prose-headings:tracking-[-0.02em] prose-p:leading-6 prose-li:my-0.5 prose-strong:font-semibold',
        )}
      >
        <ReactMarkdown remarkPlugins={[remarkGfm]} components={hasDecorations ? decoratedComponents(ctx) : undefined}>
          {message.content}
        </ReactMarkdown>
      </article>
    </div>
  );
}

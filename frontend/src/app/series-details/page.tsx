'use client';

import { Suspense, useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import ReactMarkdown, { type Components } from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ArrowRightIcon } from '@heroicons/react/24/outline';
import { PlayIcon } from '@heroicons/react/24/solid';
import { AppState } from '@/components/app-shell/AppState';
import { PageHeader } from '@/components/app-shell/PageHeader';
import { Surface } from '@/components/app-shell/Surface';
import { Button } from '@/components/ui/button';
import { useAsk } from '@/contexts/AskContext';
import { useSeries } from '@/contexts/SeriesContext';
import { matchTimestampTokens } from '@/lib/summary-timestamps';
import { cn } from '@/lib/utils';
import { seriesService } from '@/services/seriesService';
import type { SeriesDetail, SeriesMember } from '@/types/series';

function formatOccurrence(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'Date unavailable';
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

/* ------------------------------------------------------------------ *
 * Ledger @mref citations → clickable play badges
 *
 * The ledger markdown embeds meeting-attributed citation tokens of the form
 *   @mref(m<N>@<TS>)
 * where N is 1-based into `detail.members` and <TS> is M:SS / MM:SS / H:MM:SS.
 * We resolve N → meetingId and <TS> → integer seconds inside a remark plugin
 * (AST-level, so it works inside GFM table cells AND prose/bullets, and never
 * mangles the surrounding markdown by string-replacing rendered HTML).
 *
 * The plugin splits text nodes on the token pattern and emits a custom `mref`
 * node (via mdast `data.hName`/`data.hProperties`), rendered by the matching
 * entry in ReactMarkdown `components`. Timestamp parsing reuses the shared
 * matchTimestampTokens() so the badge label matches the summary badges exactly.
 * ------------------------------------------------------------------ */

const MREF_TOKEN_RE = /@mref\(m(\d+)@(\d{1,2}:[0-5]\d(?::[0-5]\d)?)\)/g;

// Mirrors the inline badge look from summary-ref-badge-plugin.ts.
const MREF_BADGE_CLASSNAME =
  'inline-flex items-center gap-0.5 rounded-full border border-border bg-secondary ' +
  'px-1.5 py-0.5 align-baseline font-mono text-xs tabular-nums text-foreground ' +
  'transition-colors hover:border-accent hover:bg-accent hover:text-accent-foreground';

interface MrefResolved {
  /** Meeting id the citation points at, or null when N is out of range. */
  meetingId: string | null;
  /** Integer recording offset in seconds. */
  seconds: number;
  /** Canonical label, e.g. "2:15" (from the shared timestamp parser). */
  label: string;
}

/** Resolve one raw `@mref` token against the ordered members list. */
function resolveMref(indexOneBased: number, rawTs: string, members: SeriesMember[]): MrefResolved | null {
  // Reuse the shared parser by feeding it the bracket form it understands.
  const [token] = matchTimestampTokens(`[${rawTs}]`);
  if (!token) return null;
  const inRange = indexOneBased >= 1 && indexOneBased <= members.length;
  const meetingId = inRange ? members[indexOneBased - 1]?.meetingId ?? null : null;
  return { meetingId: meetingId || null, seconds: token.seconds, label: token.label };
}

/** Minimal mdast node shape — enough to walk + rewrite without @types/mdast. */
interface MdNode {
  type: string;
  value?: string;
  children?: MdNode[];
  data?: { hName?: string; hProperties?: Record<string, unknown> };
}

/**
 * remark plugin factory. Walks the tree, splitting text nodes that contain
 * `@mref(...)` tokens into (text | mref) node sequences.
 */
function remarkMrefBadges(members: SeriesMember[]) {
  return () => (tree: MdNode) => {
    const walk = (node: MdNode) => {
      if (!node.children || node.children.length === 0) return;
      const nextChildren: MdNode[] = [];
      for (const child of node.children) {
        if (child.type === 'text' && typeof child.value === 'string' && child.value.includes('@mref(')) {
          nextChildren.push(...splitTextNode(child.value, members));
        } else {
          walk(child);
          nextChildren.push(child);
        }
      }
      node.children = nextChildren;
    };
    walk(tree);
  };
}

/** Split one text node's value into text + mref nodes. */
function splitTextNode(value: string, members: SeriesMember[]): MdNode[] {
  const out: MdNode[] = [];
  let lastIndex = 0;
  MREF_TOKEN_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = MREF_TOKEN_RE.exec(value)) !== null) {
    if (match.index > lastIndex) {
      out.push({ type: 'text', value: value.slice(lastIndex, match.index) });
    }
    const resolved = resolveMref(Number(match[1]), match[2], members);
    if (resolved) {
      out.push({
        type: 'mref',
        data: {
          hName: 'mref',
          hProperties: {
            meetingId: resolved.meetingId ?? '',
            seconds: String(resolved.seconds),
            label: resolved.label,
          },
        },
      });
    } else {
      // Unparseable timestamp → keep the raw text untouched (No-Fake-State).
      out.push({ type: 'text', value: match[0] });
    }
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < value.length) {
    out.push({ type: 'text', value: value.slice(lastIndex) });
  }
  return out;
}

/** The rendered badge for a resolved `@mref` node. */
function MrefBadge({
  meetingId,
  seconds,
  label,
  onPlay,
}: {
  meetingId: string;
  seconds: number;
  label: string;
  onPlay: (meetingId: string, seconds: number) => void;
}) {
  // No-Fake-State: out-of-range / missing member → plain muted time, not a dead badge.
  if (!meetingId) {
    return <span className="font-mono text-xs tabular-nums text-muted-foreground">{label}</span>;
  }
  return (
    <button
      type="button"
      onClick={() => onPlay(meetingId, seconds)}
      className={cn(MREF_BADGE_CLASSNAME, 'cursor-pointer')}
      aria-label={`Open the meeting at ${label}`}
    >
      <PlayIcon className="size-3" aria-hidden="true" />
      <span>{label}</span>
    </button>
  );
}

function SeriesDetailsContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const seriesId = searchParams.get('id');
  const { rebuildLedger, isRebuilding } = useSeries();
  const { openSeriesAsk } = useAsk();

  const [detail, setDetail] = useState<SeriesDetail | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [rebuildNote, setRebuildNote] = useState<string | null>(null);
  const [rebuildError, setRebuildError] = useState<string | null>(null);

  const rebuilding = seriesId ? isRebuilding(seriesId) : false;

  const loadDetail = useCallback(async () => {
    if (!seriesId) {
      setError('No series selected.');
      setIsLoading(false);
      return;
    }
    setIsLoading(true);
    setError(null);
    try {
      const result = await seriesService.get(seriesId);
      setDetail(result);
    } catch (err) {
      console.error('Failed to load series detail:', err);
      setDetail(null);
      setError(err instanceof Error ? err.message : 'Ari Meeting could not read this series from the local database.');
    } finally {
      setIsLoading(false);
    }
  }, [seriesId]);

  useEffect(() => {
    void loadDetail();
  }, [loadDetail]);

  const handlePlayMref = useCallback(
    (meetingId: string, seconds: number) => {
      router.push(`/meeting-details?id=${meetingId}&t=${seconds}`);
    },
    [router],
  );

  const handleRebuildLedger = useCallback(async () => {
    if (!seriesId) return;
    setRebuildNote(null);
    setRebuildError(null);
    try {
      // In-flight state lives in SeriesContext, so it survives navigation.
      const ledger = await rebuildLedger(seriesId);
      if (ledger) {
        // A real ledger came back — reload so the panel renders the persisted copy.
        await loadDetail();
        setRebuildNote('Ledger rebuilt from this series’ summarized meetings.');
      } else {
        // No-Fake-State: nothing to build from, so nothing is shown as a ledger.
        setRebuildNote(
          'No summarized meetings yet — generate a summary for a meeting in this series first.',
        );
      }
    } catch (err) {
      console.error('Failed to rebuild series ledger:', err);
      setRebuildError(
        err instanceof Error ? err.message : 'Ari Meeting could not rebuild this series ledger.',
      );
    }
  }, [seriesId, rebuildLedger, loadDetail]);

  const handleStartRecording = useCallback(() => {
    if (!detail || !seriesService.isAvailable()) return;
    // Hand off to the recorder (mirrors the calendar "record" handoff). The
    // deferred series link is consumed at save time by useRecordingStop.
    sessionStorage.setItem('pendingSeriesLinkId', detail.id);
    sessionStorage.setItem('pendingCalendarRecordTitle', detail.title);
    router.push('/new-meeting');
  }, [detail, router]);

  // Rebuild the markdown components map only when the members list changes, so
  // @mref nodes resolve against the current series.
  const members = detail?.members;
  const markdownComponents = useMemo(() => {
    // Custom `mref` element emitted by remarkMrefBadges. `node` carries our
    // hProperties verbatim (mdast-util-to-hast copies them into properties).
    const renderMref = ({ node }: { node?: { properties?: Record<string, unknown> } }) => {
      const props = node?.properties ?? {};
      const meetingId = typeof props.meetingId === 'string' ? props.meetingId : '';
      const label = typeof props.label === 'string' ? props.label : '';
      const seconds = Number(props.seconds);
      return (
        <MrefBadge
          meetingId={meetingId}
          seconds={Number.isFinite(seconds) ? seconds : 0}
          label={label}
          onPlay={handlePlayMref}
        />
      );
    };
    return { mref: renderMref } as unknown as Components;
  }, [handlePlayMref]);

  const remarkPlugins = useMemo(
    () => [remarkGfm, remarkMrefBadges(members ?? [])],
    [members],
  );

  if (!seriesService.isAvailable()) {
    return (
      <div className="app-page">
        <PageHeader eyebrow="Series" title="Series" description="Recurring meetings grouped into a connected record." />
        <div className="mt-7">
          <AppState
            kind="disabled"
            title="Series are available in the desktop app"
            description="Run Ari Meeting as a desktop app to view a recurring meeting series."
          />
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="app-page">
        <h1 className="sr-only">Opening series</h1>
        <AppState kind="loading" title="Opening series" description="Loading the series and its ledger from this device." />
      </div>
    );
  }

  if (error || !detail) {
    return (
      <div className="app-page">
        <h1 className="sr-only">Series unavailable</h1>
        <AppState
          kind="error"
          title="Series could not be opened"
          description={error || 'This series could not be found on this device.'}
          action={<Button variant="outline" onClick={() => router.push('/series')}>Back to series</Button>}
        />
      </div>
    );
  }

  const hasLedger = Boolean(detail.ledgerMarkdown && detail.ledgerMarkdown.trim().length > 0);

  return (
    <div className="app-page">
      <PageHeader
        eyebrow="Series"
        title={detail.title}
        description={
          [detail.detectedType, detail.cadence].filter(Boolean).join(' · ') || undefined
        }
        actions={
          <div className="flex flex-wrap items-center justify-end gap-2">
            {/* Primary action — amber is acceptable here per the Signal Rule. */}
            <Button size="sm" onClick={handleStartRecording}>
              Start recording
            </Button>
            {/* Secondary actions stay quiet. */}
            <Button variant="outline" size="sm" onClick={() => openSeriesAsk(detail.id, detail.title)}>
              Ask about this series
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={handleRebuildLedger}
              disabled={rebuilding}
            >
              {rebuilding ? 'Building…' : hasLedger ? 'Rebuild ledger' : 'Build ledger'}
            </Button>
            <Button variant="outline" size="sm" onClick={() => router.push('/series')}>
              All series
            </Button>
          </div>
        }
      />

      <div className="mt-7 space-y-6">
        <section aria-label="Series ledger">
          <p className="app-eyebrow mb-3">Ledger</p>
          {rebuildError ? (
            <p className="mb-3 text-xs text-destructive">{rebuildError}</p>
          ) : rebuildNote ? (
            <p className="mb-3 text-xs text-muted-foreground">{rebuildNote}</p>
          ) : null}
          {hasLedger ? (
            <Surface className="p-6">
              <article className="prose prose-sm min-w-0 max-w-none dark:prose-invert prose-headings:font-semibold prose-headings:tracking-[-0.02em] prose-p:leading-6 prose-li:my-0.5 prose-strong:font-semibold">
                <ReactMarkdown remarkPlugins={remarkPlugins} components={markdownComponents}>
                  {detail.ledgerMarkdown as string}
                </ReactMarkdown>
              </article>
            </Surface>
          ) : (
            <AppState
              kind="empty"
              title="No ledger yet"
              description="The ledger builds automatically after a meeting in this series is summarized — or build it now from the meetings already summarized with the button above."
            />
          )}
        </section>

        <section aria-label="Series timeline">
          <p className="app-eyebrow mb-3">
            Timeline · {detail.members.length} {detail.members.length === 1 ? 'meeting' : 'meetings'}
          </p>
          {detail.members.length === 0 ? (
            <AppState
              kind="empty"
              title="No meetings linked yet"
              description="Meetings linked to this series will appear here in order."
            />
          ) : (
            <Surface className="divide-y divide-border/70 overflow-hidden p-0">
              {detail.members.map((member) => (
                <button
                  key={member.meetingId}
                  type="button"
                  onClick={() => router.push(`/meeting-details?id=${member.meetingId}`)}
                  className="group flex min-h-[4.25rem] w-full items-start justify-between gap-5 px-5 py-4 text-left transition-[background,transform] hover:bg-secondary/70 active:translate-y-px focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
                >
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-semibold tracking-[-0.01em]">{member.title}</span>
                    <span className="mt-1 block text-xs text-muted-foreground">{formatOccurrence(member.occurrenceTime)}</span>
                  </span>
                  <ArrowRightIcon className="mt-1 size-4 shrink-0 text-muted-foreground transition-transform group-hover:translate-x-0.5 motion-reduce:transform-none" aria-hidden="true" />
                </button>
              ))}
            </Surface>
          )}
        </section>
      </div>
    </div>
  );
}

export default function SeriesDetailsPage() {
  return (
    <Suspense
      fallback={
        <div className="app-page">
          <h1 className="sr-only">Opening series</h1>
          <AppState kind="loading" title="Opening series" description="Loading local series data." />
        </div>
      }
    >
      <SeriesDetailsContent />
    </Suspense>
  );
}

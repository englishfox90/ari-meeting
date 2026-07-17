'use client';

/**
 * AskContext — the single shared engine behind BOTH "Ask" entry points: the
 * app-wide floating launcher (AskOverlay) and the full-window /chat page. One
 * conversation state, one ask() path, two surfaces.
 *
 * Auto-scoping: on the meeting-details route the launcher asks about THAT
 * meeting (meetingId from the `id` search param); everywhere else it asks
 * globally. On a meeting the user may toggle to "all meetings" for one session.
 *
 * Persistence is best-effort (see recallService): if the `ask_*` commands are
 * not registered the chat still works fully in-memory. We never crash on a
 * missing command, and we never fabricate an answer or a source (No-Fake-State).
 */

import {
  createContext,
  Suspense,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { usePathname, useSearchParams } from 'next/navigation';
import { useSeries } from '@/contexts/SeriesContext';
import {
  answerMeetingsLocallyStream,
  appendMessage as persistMessage,
  createConversation,
  deleteConversation as persistDeleteConversation,
  getConversation,
  getMeetingTitle,
  listConversations,
  type AskConversation,
  type AskMessage,
  type LocalRecallSource,
} from '@/services/recallService';

/** The three scopes Ask can answer from. Precedence when several are available:
 *  meeting > series > global. */
export type AskScopeMode = 'meeting' | 'series' | 'global';

interface AskScope {
  /** Effective meeting id the next question is scoped to; undefined unless meeting-scoped. */
  meetingId?: string;
  /** Resolved title of the scoped meeting, when known. */
  meetingTitle?: string;
  /** Effective series id the next question is scoped to; undefined unless series-scoped. */
  seriesId?: string;
  /** Title of the scoped series, when known. */
  seriesTitle?: string;
  /** Whether the current route is a meeting (enables the "this meeting" pill). */
  onMeeting: boolean;
  /** Whether a series is available to scope to in the current context (enables the
   *  "this series" pill): the route is a series, or the current meeting belongs to one. */
  hasSeries: boolean;
  /** True when the effective scope is a single meeting. */
  isMeetingScoped: boolean;
  /** True when the effective scope is a single series. */
  isSeriesScoped: boolean;
}

interface AskContextValue {
  isOpen: boolean;
  open: () => void;
  close: () => void;
  toggle: () => void;

  scope: AskScope;
  /** Select the effective scope explicitly. Availability is validated: picking a scope with
   *  no backing context falls back to the best available (meeting > series > global). */
  setScope: (mode: AskScopeMode) => void;
  /** Legacy two-way toggle (this meeting ⇄ all meetings). Kept for callers that predate
   *  series scope; maps onto {@link setScope}. */
  setAskAll: (askAll: boolean) => void;
  /** Open the overlay pre-set to a specific series' scope. Lets other surfaces (e.g. the
   *  series-details page) launch "Ask about this series" for an exact series id + title,
   *  independent of the current route. */
  openSeriesAsk: (seriesId: string, seriesTitle: string) => void;

  messages: AskMessage[];
  conversationId: string | null;
  isAsking: boolean;
  error: string | null;

  ask: (question: string) => Promise<void>;

  conversations: AskConversation[];
  refreshConversations: () => Promise<void>;
  newConversation: () => void;
  loadConversation: (id: string) => Promise<void>;
  removeConversation: (id: string) => Promise<void>;

  /** The current meeting's audio seek, bridged in by the meeting-details page so the
   *  (global) overlay can play @ref badges when scoped to that meeting. */
  meetingAudio: { meetingId: string; seek: (seconds: number) => void } | null;
  setMeetingAudio: (meetingId: string, seek: (seconds: number) => void) => void;
  clearMeetingAudio: (meetingId: string) => void;
}

const AskCtx = createContext<AskContextValue | null>(null);

const MEETING_ROUTE = '/meeting-details';
const SERIES_ROUTE = '/series-details';
/** Backend history window: last N prior turns. */
const HISTORY_WINDOW = 8;

function tempId(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Isolated reader for the current route's meeting id. `useSearchParams()` forces
 * a client-side-rendering bailout that must sit under a <Suspense> boundary
 * (Next.js static export). Keeping it in a leaf component — rather than at the
 * top of AskProvider — lets us wrap ONLY this read in Suspense, so the provider
 * still renders `children` (and their `useAsk()` calls) normally during prerender.
 */
function RouteScopeBridge({
  onChange,
}: {
  onChange: (ids: { meetingId?: string; seriesId?: string }) => void;
}) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const routeId = searchParams.get('id') ?? undefined;
  const routeMeetingId = pathname === MEETING_ROUTE ? routeId : undefined;
  // On /series-details the `?id=` param is the SERIES id (analogous to the meeting route).
  const routeSeriesId = pathname === SERIES_ROUTE ? routeId : undefined;

  useEffect(() => {
    onChange({ meetingId: routeMeetingId, seriesId: routeSeriesId });
  }, [routeMeetingId, routeSeriesId, onChange]);

  return null;
}

export function AskProvider({ children }: { children: React.ReactNode }) {
  const { series: seriesList, forMeeting } = useSeries();

  const [routeMeetingId, setRouteMeetingId] = useState<string | undefined>(undefined);
  const [routeSeriesId, setRouteSeriesId] = useState<string | undefined>(undefined);
  const onMeeting = Boolean(routeMeetingId);

  const [isOpen, setIsOpen] = useState(false);
  // Explicit user scope pick for this context; null = use the route default. Reset when the
  // route context changes.
  const [scopeOverride, setScopeOverride] = useState<AskScopeMode | null>(null);
  // Series pushed in programmatically (e.g. the series-details "Ask about this series" button),
  // independent of the route. Carries the exact title so we don't wait on the series list.
  const [programmaticSeries, setProgrammaticSeries] = useState<
    { seriesId: string; seriesTitle: string } | null
  >(null);
  // The series the current meeting belongs to (resolved from the meeting route), if any.
  const [meetingSeries, setMeetingSeries] = useState<
    { seriesId: string; seriesTitle: string } | null
  >(null);
  const [meetingTitle, setMeetingTitle] = useState<string | undefined>(undefined);

  const [messages, setMessages] = useState<AskMessage[]>([]);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [isAsking, setIsAsking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conversations, setConversations] = useState<AskConversation[]>([]);
  const [meetingAudio, setMeetingAudioState] = useState<{
    meetingId: string;
    seek: (seconds: number) => void;
  } | null>(null);

  // The series available to scope to in the current context, in precedence order:
  // a programmatic push, then the series route, then the current meeting's series.
  const routeSeries = useMemo(() => {
    if (!routeSeriesId) return null;
    const found = seriesList.find((s) => s.id === routeSeriesId);
    return { seriesId: routeSeriesId, seriesTitle: found?.title ?? 'this series' };
  }, [routeSeriesId, seriesList]);
  const contextSeries = programmaticSeries ?? routeSeries ?? meetingSeries;

  // Effective scope, precedence meeting > series > global. Start from the user's explicit pick
  // (or the route default), then downgrade to the best available if that scope has no backing.
  const defaultMode: AskScopeMode = routeMeetingId ? 'meeting' : contextSeries ? 'series' : 'global';
  let effectiveMode: AskScopeMode = scopeOverride ?? defaultMode;
  if (effectiveMode === 'meeting' && !routeMeetingId) {
    effectiveMode = contextSeries ? 'series' : 'global';
  }
  if (effectiveMode === 'series' && !contextSeries) {
    effectiveMode = routeMeetingId ? 'meeting' : 'global';
  }
  const effectiveMeetingId = effectiveMode === 'meeting' ? routeMeetingId : undefined;
  const effectiveSeriesId = effectiveMode === 'series' ? contextSeries?.seriesId : undefined;
  const effectiveSeriesTitle = effectiveMode === 'series' ? contextSeries?.seriesTitle : undefined;

  // Latest messages, for building the history window inside async ask().
  const messagesRef = useRef<AskMessage[]>(messages);
  messagesRef.current = messages;

  // Resolve the scoped meeting's title (best-effort, for the header).
  useEffect(() => {
    let cancelled = false;
    if (!routeMeetingId) {
      setMeetingTitle(undefined);
      return;
    }
    getMeetingTitle(routeMeetingId).then((title) => {
      if (!cancelled) setMeetingTitle(title ?? undefined);
    });
    return () => {
      cancelled = true;
    };
  }, [routeMeetingId]);

  // Resolve the series the current meeting belongs to (best-effort), so "this series" becomes
  // available as a third scope on a meeting that is part of a series.
  useEffect(() => {
    let cancelled = false;
    if (!routeMeetingId) {
      setMeetingSeries(null);
      return;
    }
    forMeeting(routeMeetingId)
      .then((s) => {
        if (!cancelled) {
          setMeetingSeries(s ? { seriesId: s.seriesId, seriesTitle: s.seriesTitle } : null);
        }
      })
      .catch(() => {
        if (!cancelled) setMeetingSeries(null);
      });
    return () => {
      cancelled = true;
    };
  }, [routeMeetingId, forMeeting]);

  // When the route context changes, drop any explicit scope pick and programmatic series so the
  // new route's default scope applies.
  useEffect(() => {
    setScopeOverride(null);
    setProgrammaticSeries(null);
  }, [routeMeetingId, routeSeriesId]);

  const refreshConversations = useCallback(async () => {
    const list = await listConversations(effectiveMeetingId, effectiveSeriesId);
    setConversations(list);
  }, [effectiveMeetingId, effectiveSeriesId]);

  // When the scope flips (route change, or toggle), reset the thread and reload that scope's
  // recent conversations. Conversations are scope-bound (meeting, series, or global).
  useEffect(() => {
    setMessages([]);
    setConversationId(null);
    setError(null);
    refreshConversations();
  }, [effectiveMeetingId, effectiveSeriesId, refreshConversations]);

  const open = useCallback(() => setIsOpen(true), []);
  const close = useCallback(() => setIsOpen(false), []);
  const toggle = useCallback(() => setIsOpen((v) => !v), []);

  const handleRouteScope = useCallback((ids: { meetingId?: string; seriesId?: string }) => {
    setRouteMeetingId(ids.meetingId);
    setRouteSeriesId(ids.seriesId);
  }, []);

  const setScope = useCallback((mode: AskScopeMode) => {
    setScopeOverride(mode);
  }, []);

  const setAskAll = useCallback((value: boolean) => {
    setScopeOverride(value ? 'global' : 'meeting');
  }, []);

  const openSeriesAsk = useCallback((seriesId: string, seriesTitle: string) => {
    setProgrammaticSeries({ seriesId, seriesTitle });
    setScopeOverride('series');
    setIsOpen(true);
  }, []);

  const setMeetingAudio = useCallback((meetingId: string, seek: (seconds: number) => void) => {
    // Store the function itself (not a call result) — the updater form would invoke it.
    setMeetingAudioState({ meetingId, seek });
  }, []);

  const clearMeetingAudio = useCallback((meetingId: string) => {
    setMeetingAudioState((current) => (current?.meetingId === meetingId ? null : current));
  }, []);

  const newConversation = useCallback(() => {
    setMessages([]);
    setConversationId(null);
    setError(null);
  }, []);

  const loadConversation = useCallback(async (id: string) => {
    setError(null);
    const loaded = await getConversation(id);
    if (!loaded) return;
    setConversationId(loaded.conversation.id);
    setMessages(loaded.messages);
  }, []);

  const removeConversation = useCallback(
    async (id: string) => {
      await persistDeleteConversation(id);
      if (id === conversationId) newConversation();
      await refreshConversations();
    },
    [conversationId, newConversation, refreshConversations],
  );

  const ask = useCallback(
    async (rawQuestion: string) => {
      const question = rawQuestion.trim();
      if (!question || isAsking) return;

      // History window BEFORE this turn (last N prior role/content pairs).
      const history = messagesRef.current
        .slice(-HISTORY_WINDOW)
        .map(({ role, content }) => ({ role, content }));

      const now = new Date().toISOString();
      const userMsg: AskMessage = {
        id: tempId('user'),
        conversationId: conversationId ?? 'pending',
        role: 'user',
        content: question,
        createdAt: now,
      };
      setMessages((cur) => [...cur, userMsg]);
      setIsAsking(true);
      setError(null);

      // Ensure a persisted conversation exists (best-effort). Title = first question.
      let convId = conversationId;
      if (!convId) {
        convId = await createConversation({
          meetingId: effectiveMeetingId,
          seriesId: effectiveSeriesId,
          title: question.slice(0, 80),
        });
        if (convId) setConversationId(convId);
      }
      if (convId) {
        void persistMessage({ conversationId: convId, role: 'user', content: question });
      }

      // Placeholder assistant bubble that fills in as tokens stream. It stays empty
      // (so the "thinking" indicator shows, not an empty box) until the first delta.
      const assistantId = tempId('assistant');
      const assistantMsg: AskMessage = {
        id: assistantId,
        conversationId: convId ?? 'pending',
        role: 'assistant',
        content: '',
        sources: [],
        createdAt: new Date().toISOString(),
      };
      setMessages((cur) => [...cur, assistantMsg]);

      try {
        await answerMeetingsLocallyStream(
          { question, meetingId: effectiveMeetingId, seriesId: effectiveSeriesId, history },
          {
            onDelta: (delta) => {
              setMessages((cur) =>
                cur.map((m) => (m.id === assistantId ? { ...m, content: m.content + delta } : m)),
              );
            },
            onDone: (answer, sources) => {
              // Replace streamed text with the verified final answer (citations
              // reconciled, timestamps checked) and attach the real sources.
              const finalSources: LocalRecallSource[] = sources ?? [];
              setMessages((cur) =>
                cur.map((m) =>
                  m.id === assistantId ? { ...m, content: answer, sources: finalSources } : m,
                ),
              );
              if (convId) {
                void persistMessage({
                  conversationId: convId,
                  role: 'assistant',
                  content: answer,
                  sources: finalSources,
                });
              }
              // updatedAt changed — refresh the recent list (best-effort).
              void refreshConversations();
            },
          },
        );
      } catch (reason) {
        // Drop the placeholder/partial bubble; the error state stands in for it.
        setMessages((cur) => cur.filter((m) => m.id !== assistantId));
        setError(reason instanceof Error ? reason.message : String(reason));
      } finally {
        setIsAsking(false);
      }
    },
    [conversationId, effectiveMeetingId, effectiveSeriesId, isAsking, refreshConversations],
  );

  const scope = useMemo<AskScope>(
    () => ({
      meetingId: effectiveMeetingId,
      meetingTitle: effectiveMeetingId ? meetingTitle : undefined,
      seriesId: effectiveSeriesId,
      seriesTitle: effectiveSeriesId ? effectiveSeriesTitle : undefined,
      onMeeting,
      hasSeries: Boolean(contextSeries),
      isMeetingScoped: Boolean(effectiveMeetingId),
      isSeriesScoped: Boolean(effectiveSeriesId),
    }),
    [
      effectiveMeetingId,
      meetingTitle,
      effectiveSeriesId,
      effectiveSeriesTitle,
      onMeeting,
      contextSeries,
    ],
  );

  const value = useMemo<AskContextValue>(
    () => ({
      isOpen,
      open,
      close,
      toggle,
      scope,
      setScope,
      setAskAll,
      openSeriesAsk,
      messages,
      conversationId,
      isAsking,
      error,
      ask,
      conversations,
      refreshConversations,
      newConversation,
      loadConversation,
      removeConversation,
      meetingAudio,
      setMeetingAudio,
      clearMeetingAudio,
    }),
    [
      isOpen,
      open,
      close,
      toggle,
      scope,
      setScope,
      setAskAll,
      openSeriesAsk,
      messages,
      conversationId,
      isAsking,
      error,
      ask,
      conversations,
      refreshConversations,
      newConversation,
      loadConversation,
      removeConversation,
      meetingAudio,
      setMeetingAudio,
      clearMeetingAudio,
    ],
  );

  return (
    <AskCtx.Provider value={value}>
      <Suspense fallback={null}>
        <RouteScopeBridge onChange={handleRouteScope} />
      </Suspense>
      {children}
    </AskCtx.Provider>
  );
}

export function useAsk(): AskContextValue {
  const ctx = useContext(AskCtx);
  if (!ctx) {
    throw new Error('useAsk must be used within an AskProvider');
  }
  return ctx;
}

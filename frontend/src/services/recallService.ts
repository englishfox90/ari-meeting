/**
 * Recall / "Ask" Service
 *
 * Single wrapper around the local meeting-recall backend (`api_answer_meetings_locally`,
 * the `recall_*` index commands) and the last-7-days conversation persistence
 * commands (`ask_conversation_*` / `ask_message_append`).
 *
 * Argument keys are camelCase — Tauri v2 maps them onto the snake_case Rust
 * params (`meetingId` -> `meeting_id`). Every call guards Tauri availability so
 * plain-browser (`pnpm run dev`, no backend) never throws at import/use time.
 *
 * Persistence is BEST-EFFORT: the `ask_*` commands may not be registered yet.
 * Those wrappers swallow errors (including "command not found") and degrade to a
 * null/empty result so the chat keeps working purely in-memory. Never crash the
 * UI on a missing command.
 */

import { invoke } from '@tauri-apps/api/core';

export function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean((window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__);
}

// ---------------------------------------------------------------------------
// Shared types (canonical — imported by AskContext + the ask/* components)
// ---------------------------------------------------------------------------

/** One excerpt the local model was allowed to see, returned SEPARATELY from the
 *  answer text (never trust model-authored citations — No-Fake-State). */
export interface LocalRecallSource {
  meeting_id: string;
  title: string;
  matchContext: string;
  timestamp: string;
  meetingDate?: string;
  summary?: string;
  speakers: string[];
}

export interface LocalRecallResponse {
  answer: string;
  sources: LocalRecallSource[];
}

/** A prior turn, in the shape the backend history window expects. */
export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

export interface AskConversation {
  id: string;
  meetingId: string | null;
  title: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface AskMessage {
  id: string;
  conversationId: string;
  role: 'user' | 'assistant';
  content: string;
  sources?: LocalRecallSource[];
  createdAt: string;
}

export interface RecallIndexStatus {
  indexed_meetings: number;
  total_meetings: number;
  chunk_count: number;
  embedded_count: number;
  embedding_ready: boolean;
  reindex_running: boolean;
}

/** Which embedder powers semantic search. 'apple' = on-device (default, no download). */
export type EmbedderId = 'apple' | 'nomic-gguf' | 'ollama';

/** Download state for a downloadable embedding model (mirrors the built-in-AI model shape). */
export interface EmbedderModelInfo {
  name: string;
  display_name: string;
  status:
    | { type: 'not_downloaded' }
    | { type: 'downloading'; progress: number }
    | { type: 'available' }
    | { type: 'error'; message?: string }
    | { type: string };
  size_mb: number;
  description?: string;
}

// ---------------------------------------------------------------------------
// Core recall (required — surfaces real errors so the UI can show them)
// ---------------------------------------------------------------------------

/**
 * Ask the local meeting store a question. Pass `meetingId` to scope to one
 * meeting, omit for a global (all-meetings) answer. `history` is the last few
 * prior turns (caller windows to 8).
 */
export async function answerMeetingsLocally(params: {
  question: string;
  meetingId?: string;
  seriesId?: string;
  history: ChatMessage[];
}): Promise<LocalRecallResponse> {
  if (!isTauriAvailable()) {
    throw new Error('Local recall is only available in the desktop app.');
  }
  const args: Record<string, unknown> = {
    question: params.question,
    history: params.history,
  };
  // Only send meetingId when scoped — omitting it selects the global path.
  if (params.meetingId) args.meetingId = params.meetingId;
  // Series scope (F9): omitted unless a series is the effective scope. Ignored by the
  // backend when meetingId is also present (meeting scope wins there).
  if (params.seriesId) args.seriesId = params.seriesId;
  return invoke<LocalRecallResponse>('api_answer_meetings_locally', args);
}

/** Callbacks for {@link answerMeetingsLocallyStream}. */
export interface AskStreamHandlers {
  /** Fired for each incremental chunk of answer text as it is generated. */
  onDelta: (delta: string) => void;
  /** Fired once with the authoritative, citation-reconciled answer + sources.
   *  Callers should REPLACE any accumulated delta text with `answer` here — it is
   *  the verified final result (invented citations dropped, timestamps checked). */
  onDone: (answer: string, sources: LocalRecallSource[]) => void;
}

/**
 * Streaming counterpart of {@link answerMeetingsLocally}: the answer arrives token
 * by token via `onDelta`, then `onDone` delivers the verified final text + sources.
 * Resolves when the answer is complete; rejects (surfacing a real error) if the
 * backend command fails. Same scoping rules as the non-streaming call.
 */
export async function answerMeetingsLocallyStream(
  params: { question: string; meetingId?: string; seriesId?: string; history: ChatMessage[] },
  handlers: AskStreamHandlers,
): Promise<void> {
  if (!isTauriAvailable()) {
    throw new Error('Local recall is only available in the desktop app.');
  }
  const { listen } = await import('@tauri-apps/api/event');
  const streamId = `ask-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  let resolveDone!: () => void;
  const done = new Promise<void>((resolve) => {
    resolveDone = resolve;
  });

  const unlistenDelta = await listen<{ streamId: string; delta: string }>(
    'ask-stream-delta',
    (event) => {
      if (event.payload.streamId !== streamId) return;
      handlers.onDelta(event.payload.delta);
    },
  );
  const unlistenDone = await listen<{
    streamId: string;
    answer: string;
    sources: LocalRecallSource[];
  }>('ask-stream-done', (event) => {
    if (event.payload.streamId !== streamId) return;
    handlers.onDone(event.payload.answer, event.payload.sources ?? []);
    resolveDone();
  });

  const args: Record<string, unknown> = {
    streamId,
    question: params.question,
    history: params.history,
  };
  if (params.meetingId) args.meetingId = params.meetingId;
  if (params.seriesId) args.seriesId = params.seriesId;

  try {
    // The command emits `ask-stream-done` and then resolves; await both so we
    // don't unlisten before the terminal event is delivered to the webview.
    await invoke('api_answer_meetings_locally_stream', args);
    await done;
  } finally {
    unlistenDelta();
    unlistenDone();
  }
}

export async function recallIndexStatus(): Promise<RecallIndexStatus | null> {
  if (!isTauriAvailable()) return null;
  try {
    return await invoke<RecallIndexStatus>('recall_index_status');
  } catch {
    return null;
  }
}

export async function recallReindex(force = false): Promise<number> {
  if (!isTauriAvailable()) return 0;
  return invoke<number>('recall_reindex', { force });
}

// ---------------------------------------------------------------------------
// Conversation persistence (BEST-EFFORT — never throws to callers)
// ---------------------------------------------------------------------------

/** List conversations for a scope (last 7 days, pruned server-side). Global
 *  when meetingId is omitted; that meeting's when provided. */
export async function listConversations(
  meetingId?: string,
  seriesId?: string,
): Promise<AskConversation[]> {
  if (!isTauriAvailable()) return [];
  try {
    const args: Record<string, unknown> = {};
    if (meetingId) args.meetingId = meetingId;
    // Forward the series scope so series threads stay scope-bound once the backend
    // conversation store learns about series (harmlessly ignored until then).
    if (seriesId) args.seriesId = seriesId;
    return (await invoke<AskConversation[]>('ask_conversation_list', args)) ?? [];
  } catch {
    return [];
  }
}

export async function getConversation(
  conversationId: string,
): Promise<{ conversation: AskConversation; messages: AskMessage[] } | null> {
  if (!isTauriAvailable()) return null;
  try {
    return await invoke<{ conversation: AskConversation; messages: AskMessage[] }>('ask_conversation_get', {
      conversationId,
    });
  } catch {
    return null;
  }
}

export async function createConversation(params: {
  meetingId?: string;
  seriesId?: string;
  title?: string;
}): Promise<string | null> {
  if (!isTauriAvailable()) return null;
  try {
    const args: Record<string, unknown> = {};
    if (params.meetingId) args.meetingId = params.meetingId;
    if (params.seriesId) args.seriesId = params.seriesId;
    if (params.title) args.title = params.title;
    return await invoke<string>('ask_conversation_create', args);
  } catch {
    return null;
  }
}

export async function appendMessage(params: {
  conversationId: string;
  role: 'user' | 'assistant';
  content: string;
  sources?: LocalRecallSource[];
}): Promise<string | null> {
  if (!isTauriAvailable()) return null;
  try {
    const args: Record<string, unknown> = {
      conversationId: params.conversationId,
      role: params.role,
      content: params.content,
    };
    if (params.sources) args.sources = params.sources;
    return await invoke<string>('ask_message_append', args);
  } catch {
    return null;
  }
}

export async function deleteConversation(conversationId: string): Promise<void> {
  if (!isTauriAvailable()) return;
  try {
    await invoke('ask_conversation_delete', { conversationId });
  } catch {
    /* best-effort: a missing command must not break the UI */
  }
}

/** Resolve a meeting's display title for the scope header. Best-effort. */
export async function getMeetingTitle(meetingId: string): Promise<string | null> {
  if (!isTauriAvailable()) return null;
  try {
    const meeting = await invoke<{ title?: string }>('api_get_meeting', { meetingId });
    return meeting?.title ?? null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Embedder selection + downloadable embedding models (best-effort)
// ---------------------------------------------------------------------------

/** Currently selected embedder. Defaults to 'apple' if unavailable/unset. */
export async function getRecallEmbedder(): Promise<EmbedderId> {
  if (!isTauriAvailable()) return 'apple';
  try {
    return (await invoke<EmbedderId>('recall_get_embedder')) ?? 'apple';
  } catch {
    return 'apple';
  }
}

/** Persist the selected embedder. Caller should follow with recallReindex(true). */
export async function setRecallEmbedder(embedder: EmbedderId): Promise<void> {
  if (!isTauriAvailable()) return;
  await invoke('recall_set_embedder', { embedder });
}

/** List downloadable embedding models with their download status. Best-effort. */
export async function listEmbedderModels(): Promise<EmbedderModelInfo[]> {
  if (!isTauriAvailable()) return [];
  try {
    return (await invoke<EmbedderModelInfo[]>('recall_embedder_list_models')) ?? [];
  } catch {
    return [];
  }
}

export async function downloadEmbedderModel(modelName: string): Promise<void> {
  if (!isTauriAvailable()) return;
  await invoke('recall_embedder_download_model', { modelName });
}

export async function cancelEmbedderDownload(): Promise<void> {
  if (!isTauriAvailable()) return;
  try {
    await invoke('recall_embedder_cancel_download');
  } catch {
    /* best-effort */
  }
}

export async function deleteEmbedderModel(modelName: string): Promise<void> {
  if (!isTauriAvailable()) return;
  try {
    await invoke('recall_embedder_delete_model', { modelName });
  } catch {
    /* best-effort */
  }
}

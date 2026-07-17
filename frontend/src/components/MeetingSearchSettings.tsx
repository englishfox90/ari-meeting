'use client';

import { useCallback, useEffect, useState } from 'react';
import {
  cancelEmbedderDownload,
  deleteEmbedderModel,
  downloadEmbedderModel,
  getRecallEmbedder,
  listEmbedderModels,
  recallIndexStatus,
  recallReindex,
  setRecallEmbedder,
  type EmbedderId,
  type EmbedderModelInfo,
  type RecallIndexStatus,
} from '@/services/recallService';
import { cn } from '@/lib/utils';
import { Button } from './ui/button';

// Plain-browser (`pnpm run dev`) has no Tauri runtime; every invoke would throw.
function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean((window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__);
}

interface EmbedderOption {
  id: EmbedderId;
  label: string;
  description: string;
}

const EMBEDDERS: EmbedderOption[] = [
  { id: 'apple', label: 'On-device (Apple)', description: 'Private, offline, no download. Recommended.' },
  { id: 'nomic-gguf', label: 'Nomic Embed Text', description: 'Higher-quality semantic matching. One-time download.' },
  { id: 'ollama', label: 'Ollama', description: 'Use a local Ollama server (advanced).' },
];

/**
 * "Meeting search index" card. Powers Ask Meetings' semantic + keyword retrieval.
 * Lets the user choose the embedder (on-device Apple by default, an optional downloadable
 * Nomic model, or Ollama), shows the REAL index status from `recall_index_status`, and
 * rebuilds via `recall_reindex`. No-Fake-State: every number/state is backend-backed.
 */
export function MeetingSearchSettings() {
  const [available] = useState(() => isTauriAvailable());
  const [status, setStatus] = useState<RecallIndexStatus | null>(null);
  const [embedder, setEmbedder] = useState<EmbedderId>('apple');
  const [models, setModels] = useState<EmbedderModelInfo[]>([]);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [download, setDownload] = useState<{ progress: number; status: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setStatus(await recallIndexStatus());
    setModels(await listEmbedderModels());
  }, []);

  useEffect(() => {
    if (!available) return;
    void (async () => {
      setEmbedder(await getRecallEmbedder());
      await refresh();
    })();

    let unlisten: Array<() => void> = [];
    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      unlisten.push(
        await listen<{ done: number; total: number }>('recall-reindex-progress', (e) => setProgress(e.payload)),
      );
      unlisten.push(
        await listen('recall-reindex-complete', () => {
          setProgress(null);
          setBusy(false);
          void refresh();
        }),
      );
      unlisten.push(
        await listen<{ progress: number; status: string }>('recall-embedder-download-progress', (e) => {
          const { progress: p, status: s } = e.payload;
          if (s === 'completed' || s === 'cancelled' || s === 'error') {
            setDownload(null);
            void refresh();
          } else {
            setDownload({ progress: p, status: s });
          }
        }),
      );
    })();

    return () => unlisten.forEach((u) => u());
  }, [available, refresh]);

  const running = busy || status?.reindex_running === true;

  const rebuild = useCallback(async (force: boolean) => {
    setError(null);
    setProgress(null);
    setBusy(true);
    try {
      const queued = await recallReindex(force);
      if (queued === 0) {
        setBusy(false);
        await refresh();
      }
    } catch {
      setError('Ari Meeting could not rebuild the search index. Try again.');
      setBusy(false);
    }
  }, [refresh]);

  const chooseEmbedder = async (id: EmbedderId) => {
    if (id === embedder) return;
    setError(null);
    setEmbedder(id);
    try {
      await setRecallEmbedder(id);
      // Vectors from different embedders aren't comparable — re-embed everything.
      await rebuild(true);
    } catch {
      setError('Ari Meeting could not switch the embedder. Try again.');
    }
  };

  // The single downloadable model (nomic) — status drives the download affordance.
  const nomic = models[0];
  const nomicStatus = nomic?.status.type;
  const nomicReady = nomicStatus === 'available';
  const nomicDownloading = nomicStatus === 'downloading' || download !== null;

  const startDownload = async () => {
    if (!nomic) return;
    setError(null);
    setDownload({ progress: 0, status: 'downloading' });
    try {
      await downloadEmbedderModel(nomic.name);
    } catch {
      setDownload(null);
      setError('Ari Meeting could not download the embedding model. Try again.');
    }
  };

  const modeLabel =
    status && status.chunk_count > 0 ? (status.embedding_ready ? 'Semantic + keyword' : 'Keyword only') : null;

  return (
    <section aria-labelledby="meeting-search-heading" className="settings-card">
      <div className="flex items-start justify-between gap-6">
        <div>
          <p className="app-eyebrow mb-2">Ask Meetings</p>
          <h3 id="meeting-search-heading" className="text-lg font-semibold tracking-[-0.03em]">
            Meeting search index
          </h3>
          <p id="meeting-search-description" className="mt-1 text-sm text-muted-foreground">
            Powers Ask Meetings. Meetings index automatically as they’re saved; rebuild if answers
            seem to miss recent recordings.
          </p>
        </div>
        <Button variant="outline" disabled={!available || running} onClick={() => rebuild(false)}>
          {running ? 'Rebuilding…' : 'Rebuild index'}
        </Button>
      </div>

      {available && (
        <div className="mt-4">
          <p className="app-eyebrow mb-2">Search embedding</p>
          <div className="grid gap-2 sm:grid-cols-3">
            {EMBEDDERS.map((option) => {
              const selected = embedder === option.id;
              return (
                <button
                  key={option.id}
                  type="button"
                  onClick={() => chooseEmbedder(option.id)}
                  disabled={running}
                  aria-pressed={selected}
                  className={cn(
                    'rounded-[10px] border p-3 text-left transition-colors',
                    selected ? 'border-accent bg-accent/10' : 'border-border bg-card hover:border-accent/50',
                    running && 'opacity-60',
                  )}
                >
                  <span className="block text-sm font-medium text-foreground">{option.label}</span>
                  <span className="mt-0.5 block text-xs leading-4 text-muted-foreground">
                    {option.description}
                  </span>
                </button>
              );
            })}
          </div>

          {/* Download affordance for the Nomic model. */}
          {embedder === 'nomic-gguf' && nomic && (
            <div className="mt-2 flex items-center justify-between gap-3 rounded-[10px] border border-border bg-card p-3">
              <div className="min-w-0">
                <p className="text-sm font-medium text-foreground">{nomic.display_name}</p>
                <p className="text-xs text-muted-foreground">
                  {nomicReady
                    ? 'Downloaded and ready.'
                    : nomicDownloading
                      ? `Downloading… ${Math.round(download?.progress ?? 0)}%`
                      : `~${nomic.size_mb} MB one-time download.`}
                </p>
              </div>
              {nomicReady ? (
                <Button variant="ghost" size="sm" onClick={() => deleteEmbedderModel(nomic.name).then(refresh)}>
                  Remove
                </Button>
              ) : nomicDownloading ? (
                <Button variant="ghost" size="sm" onClick={() => cancelEmbedderDownload()}>
                  Cancel
                </Button>
              ) : (
                <Button variant="outline" size="sm" onClick={startDownload}>
                  Download
                </Button>
              )}
            </div>
          )}
        </div>
      )}

      {available && status && (
        <dl className="mt-4 grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
          <div>
            <dt className="text-xs text-muted-foreground">Meetings indexed</dt>
            <dd className="font-mono tabular-nums">
              {status.indexed_meetings} / {status.total_meetings}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Indexed passages</dt>
            <dd className="font-mono tabular-nums">{status.chunk_count}</dd>
          </div>
          {modeLabel && (
            <div>
              <dt className="text-xs text-muted-foreground">Search mode</dt>
              <dd>{modeLabel}</dd>
            </div>
          )}
        </dl>
      )}

      {running && progress && (
        <p className="mt-3 text-sm text-muted-foreground" role="status" aria-live="polite">
          Rebuilding… {progress.done} of {progress.total} meetings.
        </p>
      )}

      {available && status && status.chunk_count > 0 && !status.embedding_ready && !running && (
        <p className="mt-3 text-sm text-muted-foreground">
          {embedder === 'nomic-gguf' && !nomicReady
            ? 'Download the Nomic model above, then rebuild to enable semantic matching.'
            : embedder === 'ollama'
              ? 'Semantic search needs Ollama running with the nomic-embed-text model. Until then, Ask uses keyword search.'
              : 'Ask is using keyword search. Rebuild to enable semantic matching.'}
        </p>
      )}

      {!available && (
        <p className="mt-3 text-sm text-muted-foreground">
          The meeting search index is only available in the desktop app.
        </p>
      )}

      {error && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      )}
    </section>
  );
}

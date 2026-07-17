// summaryCore — the enriched, mount-independent core of summary generation.
//
// These helpers were extracted verbatim from `hooks/meeting-details/useSummaryGeneration.ts`
// so that BOTH the interactive hook (which keeps all its React state, toasts, and
// model-settings UX) AND the headless background orchestrator (`summaryOrchestrator.ts`,
// which runs the post-recording pipeline even when the meeting page is not mounted)
// share ONE source of truth for prompt/context/label/payload assembly. There is no
// backend-only summary path here — the enriched frontend behaviour (F1 speaker labels,
// F3 person+calendar context, F6 templates, timestamp citations) is preserved in both.
//
// Nothing here touches React or the DOM. UI concerns (toasts) are injected via an
// optional `notify` adapter so the interactive path can surface warnings while the
// background path stays silent.

import { Transcript } from '@/types';
import { invoke as invokeTauri } from '@tauri-apps/api/core';
import { isOllamaNotInstalledError } from '@/lib/utils';
import { BuiltInModelInfo } from '@/lib/builtin-ai';
import {
  detectAndCacheSummaryLanguage,
  readMeetingSummaryLanguage,
  readCachedDetectedSummaryLanguage,
} from '@/lib/summary-language-preferences';
import { personService } from '@/services/personService';
import { speakerService } from '@/services/speakerService';

/** Optional UI notifier. The interactive hook wires this to `sonner`'s toast;
 *  the background orchestrator omits it (silent). */
export type Notify = (
  level: 'info' | 'warning' | 'error',
  message: string,
  opts?: { description?: string },
) => void;

// Ask the model to cite the real [MM:SS] markers already present on every
// transcript line (see buildSummaryTranscriptPayload) so the summary's
// "Referenced moments" can link back into the recording. Kept terse to avoid
// prompt bloat; validated on render, so an ignored instruction just yields no
// moments rather than fake ones.
export const TIMESTAMP_CITATION_INSTRUCTION =
  "When you cite a specific action item, key decision, or notable claim, mark it inline with a citation in the exact format @ref(MM:SS) — for example @ref(01:05) — copying MM:SS verbatim from the [MM:SS] marker at the start of the relevant transcript line (use @ref(H:MM:SS) for meetings over an hour). Every @ref(...) MUST match a real [MM:SS] marker present in the transcript — never invent, estimate, or round one. Cite the moment for each action item and key decision when identifiable; if you genuinely cannot, leave it uncited (do not write 'None').";

// F3: best-effort owner + participant + calendar-event context, prepended to the
// summary's custom prompt. Never blocks summarization if the person store is empty,
// unavailable, or errors. (Calendar-event details — title/description/attendees —
// are folded into this same block by the backend `summary_context_for_meeting`.)
export async function resolvePersonContextPrefix(meetingId: string): Promise<string> {
  try {
    if (!personService.isAvailable()) return '';
    const context = await personService.summaryContextForMeeting(meetingId);
    return context && context.trim().length > 0 ? context : '';
  } catch (err) {
    console.warn('Failed to assemble person/owner context for summary:', err);
    return '';
  }
}

// F1: best-effort speaker labels for a meeting's transcript rows, keyed by
// transcript id. Used to prefix each summary transcript line with "Name: " so
// the LLM can attribute statements to real people. Never blocks summarization:
// on any failure (or outside Tauri) it returns an empty map and the payload
// stays exactly as it is today (unlabeled). Only resolved rows are labeled —
// no fabricated names.
export async function resolveSpeakerLabelMap(meetingId: string): Promise<Map<string, string>> {
  try {
    if (!speakerService.isAvailable()) return new Map();
    const labels = await speakerService.getMeetingSpeakerLabels(meetingId);
    return new Map(labels.map(l => [l.transcriptId, l.speakerName]));
  } catch (err) {
    console.warn('Failed to load speaker labels for summary (non-blocking):', err);
    return new Map();
  }
}

// F2 auto-reconciliation: fire-and-forget after a summary completes. Reconciles each
// participant's facts (add/keep/supersede/remove against their CURRENT set) rather than
// blindly appending new pending facts — keeps profiles small and de-duplicated. New "add"
// facts still land as 'pending' and require confirm-before-enroll on /people.
export function triggerFactExtraction(meetingId: string): void {
  if (!personService.isAvailable()) return;
  personService
    .reconcileFactsForMeeting(meetingId)
    .then((result) => {
      console.log('Person fact reconciliation completed:', result);
    })
    .catch((err) => {
      console.warn('Person fact reconciliation failed (non-blocking):', err);
    });
}

// Resolve the summary output language: explicit per-meeting override first, then a
// cached detection, then a fresh detection. `notify` (optional) surfaces the two
// non-fatal warnings the interactive path shows; the background path passes nothing.
export async function resolveSummaryLanguage(
  meetingId: string,
  transcriptTexts: string[],
  notify?: Notify,
): Promise<string | null> {
  try {
    const perMeeting = await readMeetingSummaryLanguage(meetingId);
    if (perMeeting.language) return perMeeting.language;
  } catch (err) {
    console.warn('Failed to load meeting summary language:', err);
    notify?.('warning', 'Could not load saved summary language', {
      description: 'Using Auto for this generation.',
    });
  }

  try {
    const cachedDetected = await readCachedDetectedSummaryLanguage(meetingId);
    if (cachedDetected) return cachedDetected;
  } catch (err) {
    console.warn('Failed to load cached detected summary language:', err);
  }

  try {
    const detection = await detectAndCacheSummaryLanguage(meetingId, transcriptTexts);
    if (detection.reason === 'tie') {
      notify?.('warning', 'Bilingual transcript detected', {
        description: 'Pick a summary language manually if Auto chooses the wrong fallback.',
      });
    }
    return detection.language;
  } catch (err) {
    console.warn('Failed to detect transcript summary language:', err);
    return null;
  }
}

// Fetch ALL transcripts for a meeting (not the paginated view state). `notify`
// (optional) surfaces the fetch-failure toast the interactive path shows.
export async function fetchAllTranscripts(
  meetingId: string,
  notify?: Notify,
): Promise<Transcript[]> {
  try {
    console.log('📊 Fetching all transcripts for meeting:', meetingId);

    // First, get total count by fetching first page
    const firstPage = await invokeTauri('api_get_meeting_transcripts', {
      meetingId,
      limit: 1,
      offset: 0,
    }) as { transcripts: Transcript[]; total_count: number; has_more: boolean };

    const totalCount = firstPage.total_count;
    console.log(`📊 Total transcripts in database: ${totalCount}`);

    if (totalCount === 0) {
      return [];
    }

    // Fetch all transcripts in one call
    const allData = await invokeTauri('api_get_meeting_transcripts', {
      meetingId,
      limit: totalCount,
      offset: 0,
    }) as { transcripts: Transcript[]; total_count: number; has_more: boolean };

    console.log(`✅ Fetched ${allData.transcripts.length} transcripts from database`);
    return allData.transcripts;
  } catch (error) {
    console.error('❌ Error fetching all transcripts:', error);
    notify?.('error', 'Failed to fetch transcripts for summary generation');
    return [];
  }
}

// F1: `speakerLabels` maps transcript id → resolved speaker name. When a row
// has a label, the line becomes "[MM:SS] Name: text" so the summary LLM can
// attribute statements; unlabeled rows keep the exact "[MM:SS] text" shape
// used by the timestamp-citation feature. An empty/absent map reproduces
// today's behavior verbatim (no regression, no fabricated names).
export function buildSummaryTranscriptPayload(
  allTranscripts: Transcript[],
  speakerLabels?: Map<string, string>,
): { transcriptText: string; transcriptTexts: string[] } {
  const formatTime = (seconds: number | undefined, fallbackTimestamp: string): string => {
    if (seconds === undefined) {
      return fallbackTimestamp;
    }
    const totalSecs = Math.floor(seconds);
    const mins = Math.floor(totalSecs / 60);
    const secs = totalSecs % 60;
    return `[${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}]`;
  };

  return {
    transcriptText: allTranscripts
      .map(t => {
        const speakerName = speakerLabels?.get(t.id);
        const speakerPrefix = speakerName ? `${speakerName}: ` : '';
        return `${formatTime(t.audio_start_time, t.timestamp)} ${speakerPrefix}${t.text}`;
      })
      .join('\n'),
    transcriptTexts: allTranscripts.map(t => t.text),
  };
}

/** Structured provider-readiness result. `ok:false` carries a human-readable
 *  message the caller renders (toast for the hook, error phase for the
 *  orchestrator). Used by the HEADLESS orchestrator; the interactive hook keeps
 *  its own richer inline checks (download links, auto-open settings). */
export type ProviderReadiness =
  | { ok: true }
  | { ok: false; message: string };

/** Minimal model-config shape the readiness check needs — decoupled from the
 *  two structural `ModelConfig` definitions (ModelSettingsModal / configService). */
export interface ReadinessModelConfig {
  provider: string;
  model: string;
  ollamaEndpoint?: string | null;
}

// Headless provider-readiness check for the background summary path. Mirrors the
// interactive hook's PER-PROVIDER gates (ollama: models exist; builtin-ai: model
// selected + ready; other providers: no gate) but returns a plain result instead
// of firing toasts or opening settings modals. Note: an empty `model` is NOT a
// global error — ollama accepts it and the backend picks a default (matches the
// prior behavior); only builtin-ai requires an explicit model.
export async function checkProviderReadiness(modelConfig: ReadinessModelConfig): Promise<ProviderReadiness> {
  if (modelConfig.provider === 'ollama') {
    try {
      const endpoint = modelConfig.ollamaEndpoint || null;
      const models = await invokeTauri('get_ollama_models', { endpoint }) as any[];
      if (!models || models.length === 0) {
        return { ok: false, message: 'No Ollama models found. Download a model from Model Settings.' };
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      if (isOllamaNotInstalledError(errorMessage)) {
        return { ok: false, message: 'Ollama is not installed. Install it to use local models.' };
      }
      return { ok: false, message: 'Failed to reach Ollama. Ensure it is running.' };
    }
  }

  if (modelConfig.provider === 'builtin-ai') {
    if (!modelConfig.model || !modelConfig.model.trim()) {
      return { ok: false, message: 'No built-in AI model is selected. Choose one in Model Settings.' };
    }
    try {
      const isReady = await invokeTauri<boolean>('builtin_ai_is_model_ready', {
        modelName: modelConfig.model,
        refresh: true,
      });
      if (!isReady) {
        const modelInfo = await invokeTauri<BuiltInModelInfo | null>('builtin_ai_get_model_info', {
          modelName: modelConfig.model,
        });
        const status = modelInfo?.status;
        if (status?.type === 'downloading') {
          return { ok: false, message: `${modelConfig.model} is still downloading (${status.progress}%).` };
        }
        if (status?.type === 'not_downloaded') {
          return { ok: false, message: `${modelConfig.model} is not downloaded. Download it in Model Settings.` };
        }
        return { ok: false, message: `${modelConfig.model} is not ready. Check Model Settings.` };
      }
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      return { ok: false, message: `Failed to validate built-in AI model: ${msg}` };
    }
  }

  return { ok: true };
}

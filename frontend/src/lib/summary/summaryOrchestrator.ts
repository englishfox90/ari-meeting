// summaryOrchestrator — the HEADLESS, mount-independent summary path.
//
// Runs the exact same enriched summary generation as the interactive hook
// (F1 speaker labels, F3 person+calendar context, F6 template suggestion,
// timestamp citations) but WITHOUT any React/page dependency, so the
// post-recording pipeline (MeetingProcessingContext) can generate a summary
// even after the user has navigated away from the meeting.
//
// Model configuration is read from BACKEND settings (`configService`), not from
// React state — this is what makes it mount-independent. The backend persists
// the finished summary to SQLite; the meeting page reloads it from the DB when
// the pipeline reports completion, so this module never touches the summary
// React state or formatting.

import { invoke as invokeTauri } from '@tauri-apps/api/core';
import { configService } from '@/services/configService';
import { templateService } from '@/services/templateService';
import { seriesService } from '@/services/seriesService';
import {
  TIMESTAMP_CITATION_INSTRUCTION,
  resolvePersonContextPrefix,
  resolveSpeakerLabelMap,
  resolveSummaryLanguage,
  triggerFactExtraction,
  fetchAllTranscripts,
  buildSummaryTranscriptPayload,
  checkProviderReadiness,
} from '@/lib/summary/summaryCore';

/** The one dependency we inject: the SidebarProvider poll manager, which owns
 *  the poll interval and — crucially — survives route changes, so the summary
 *  keeps being polled while the user is on another page. */
export interface RunSummaryDeps {
  startSummaryPolling: (
    meetingId: string,
    processId: string,
    onUpdate: (result: any) => void,
  ) => void;
}

// Resolve the summary model config from backend settings.
//  - custom-openai: fill the model from its dedicated config when omitted.
//  - no model configured at all: adopt ollama + gemma3:1b as the initial default
//    IF that model is installed — preserving the first-run convenience that the
//    meeting-details page used to provide before summaries moved to this
//    background path. (The backend fills the concrete model for an empty ollama
//    model string, matching the prior behavior.)
async function resolveModelConfig() {
  const base = await configService.getModelConfig();

  if (base.provider === 'custom-openai' && (!base.model || !base.model.trim())) {
    try {
      const custom = await configService.getCustomOpenAIConfig();
      if (custom?.model) {
        return { ...base, model: custom.model };
      }
    } catch (err) {
      console.warn('Failed to load custom-openai config for background summary:', err);
    }
    return base;
  }

  // Nothing meaningful configured yet — try the gemma3:1b default.
  if (!base.model || !base.model.trim()) {
    try {
      const models = await invokeTauri('get_ollama_models', { endpoint: null }) as any[];
      const hasGemma = Array.isArray(models) && models.some((m: any) => m?.name === 'gemma3:1b');
      if (hasGemma) {
        console.log('💾 No summary model configured; adopting ollama/gemma3:1b default.');
        await invokeTauri('api_save_model_config', {
          provider: 'ollama',
          model: '',
          whisperModel: 'large-v3',
          apiKey: null,
          ollamaEndpoint: null,
        });
        return { ...base, provider: 'ollama' as const, model: '' };
      }
    } catch (err) {
      console.warn('Failed to probe ollama for the gemma3:1b default:', err);
    }
  }

  return base;
}

/**
 * Generate a summary for `meetingId` headlessly. Resolves when the summary
 * completes (and fact extraction has been kicked off), rejects with a
 * human-readable message on any failure. Diarization must already have run
 * (the caller sequences it) so speaker labels are present.
 */
export async function runSummary(meetingId: string, deps: RunSummaryDeps): Promise<void> {
  const modelConfig = await resolveModelConfig();

  const readiness = await checkProviderReadiness(modelConfig);
  if (!readiness.ok) {
    throw new Error(readiness.message);
  }

  const allTranscripts = await fetchAllTranscripts(meetingId);
  if (!allTranscripts.length) {
    throw new Error('No transcripts available for summary');
  }

  // F1: labels now exist because diarization completed before we were called.
  const speakerLabels = await resolveSpeakerLabelMap(meetingId);
  const payload = buildSummaryTranscriptPayload(allTranscripts, speakerLabels);

  // F3: owner + participant + calendar-event context prefix. Same assembly as
  // the interactive path. Resolved before F6 so the classifier can use it too.
  const personContextPrefix = await resolvePersonContextPrefix(meetingId);

  // F6: auto-select a template from the transcript. Best-effort — the backend
  // degrades to its default template if this is omitted or fails. Speaker
  // count and calendar context help distinguish call types (e.g. a 1:1) that
  // a transcript excerpt alone doesn't reliably signal.
  // F9 template inheritance: if this meeting belongs to a series that already settled on a
  // template, reuse it directly and SKIP the LLM classification — more consistent across the
  // series and one fewer LLM call. Otherwise fall back to the existing suggestTemplate flow.
  let templateId: string | undefined;
  let inheritedTemplate = false;
  try {
    const series = await seriesService.forMeeting(meetingId);
    if (series?.seriesTemplate) {
      templateId = series.seriesTemplate;
      inheritedTemplate = true;
      console.log(`[series] inheriting template ${templateId}`);
    }
  } catch (err) {
    console.warn('Series template lookup failed; falling back to auto-selection:', err);
  }

  if (!inheritedTemplate) {
    try {
      const distinctSpeakerCount = new Set(speakerLabels.values()).size;
      const suggestion = await templateService.suggestTemplate(
        payload.transcriptText,
        distinctSpeakerCount,
        personContextPrefix,
      );
      templateId = suggestion?.id;
    } catch (err) {
      console.warn('Background template auto-selection failed; using backend default:', err);
    }
  }

  const promptWithPersonContext = personContextPrefix ? `${personContextPrefix}\n` : '';
  const promptWithTimestamps = promptWithPersonContext
    ? `${promptWithPersonContext}\n\n${TIMESTAMP_CITATION_INSTRUCTION}`
    : TIMESTAMP_CITATION_INSTRUCTION;

  const summaryLanguage = await resolveSummaryLanguage(meetingId, payload.transcriptTexts);

  const result = await invokeTauri('api_process_transcript', {
    text: payload.transcriptText,
    model: modelConfig.provider,
    modelName: modelConfig.model,
    meetingId,
    chunkSize: 40000,
    overlap: 1000,
    customPrompt: promptWithTimestamps,
    templateId,
    summaryLanguage,
  }) as any;

  const processId = result?.process_id;
  if (!processId) {
    throw new Error('Summary backend did not return a process id');
  }

  // Poll to completion via the SidebarProvider's shared, navigation-surviving
  // poll manager. Resolve on completion, reject on any terminal failure.
  await new Promise<void>((resolve, reject) => {
    deps.startSummaryPolling(meetingId, processId, (pollingResult) => {
      const status = pollingResult?.status;
      if (status === 'completed') {
        // F2: reconcile person facts now that a summary exists. Fire-and-forget.
        triggerFactExtraction(meetingId);
        // F9: fold this meeting's summary into its series ledger (if it belongs to a
        // series). Fire-and-forget — a ledger failure must never affect the summary flow.
        invokeTauri('series_update_ledger', { meetingId }).catch(() => {});
        // F9: remember the template actually used, so future occurrences in this series
        // inherit it. No-op backend-side if the meeting isn't in a series. Fire-and-forget.
        if (templateId) {
          seriesService.setTemplate(meetingId, templateId).catch(() => {});
        }
        resolve();
      } else if (status === 'error' || status === 'failed') {
        reject(new Error(pollingResult?.error || 'Summary generation failed'));
      } else if (status === 'cancelled') {
        reject(new Error('Summary generation was cancelled'));
      }
      // Non-terminal statuses (processing/idle) are ignored; the poll manager
      // keeps calling us until a terminal status or its own timeout.
    });
  });
}

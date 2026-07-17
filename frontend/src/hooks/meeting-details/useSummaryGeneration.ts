import { useState, useCallback, MutableRefObject } from 'react';
import { Transcript, Summary } from '@/types';
import { ModelConfig } from '@/components/ModelSettingsModal';
import { CurrentMeeting, useSidebar } from '@/components/Sidebar/SidebarProvider';
import { invoke as invokeTauri } from '@tauri-apps/api/core';
import { toast } from 'sonner';
import Analytics from '@/lib/analytics';
import { isOllamaNotInstalledError } from '@/lib/utils';
import { BuiltInModelInfo } from '@/lib/builtin-ai';
import { templateService } from '@/services/templateService';
import { seriesService } from '@/services/seriesService';
import {
  TIMESTAMP_CITATION_INSTRUCTION,
  resolvePersonContextPrefix,
  resolveSpeakerLabelMap,
  triggerFactExtraction,
  resolveSummaryLanguage,
  fetchAllTranscripts as fetchAllTranscriptsCore,
  buildSummaryTranscriptPayload as buildSummaryTranscriptPayloadCore,
  type Notify,
} from '@/lib/summary/summaryCore';

// The prompt/context/label/payload helpers that used to live here now live in
// `@/lib/summary/summaryCore` so the headless background orchestrator can reuse
// the exact same enriched assembly. Imported above.

// Bridge the shared `Notify` adapter to sonner so extracted helpers keep showing
// the same toasts on the interactive path.
const toastNotify: Notify = (level, message, opts) => {
  toast[level](message, opts);
};

type SummaryStatus = 'idle' | 'processing' | 'summarizing' | 'regenerating' | 'completed' | 'error';

interface UseSummaryGenerationProps {
  meeting: any;
  transcripts: Transcript[];
  modelConfig: ModelConfig;
  isModelConfigLoading: boolean;
  selectedTemplate: string;
  onMeetingUpdated?: () => Promise<void>;
  updateMeetingTitle: (title: string) => void;
  setAiSummary: (summary: Summary | null) => void;
  // Whether this meeting already has a summary. F6 auto-selection should only
  // run on the meeting's first summary generation — once a summary exists,
  // the template that produced it (or the user's later pick) is authoritative.
  hasSummary?: boolean;
  onOpenModelSettings?: () => void;
  // F6 auto-template-selection: reflect the auto-picked template in the UI and
  // read whether the user has overridden it. Optional so callers that don't
  // wire them fall back to the passed-in selectedTemplate.
  applySuggestedTemplate?: (templateId: string) => void;
  userSelectedTemplateRef?: MutableRefObject<boolean>;
}

export function useSummaryGeneration({
  meeting,
  transcripts,
  modelConfig,
  isModelConfigLoading,
  selectedTemplate,
  onMeetingUpdated,
  updateMeetingTitle,
  setAiSummary,
  hasSummary = false,
  onOpenModelSettings,
  applySuggestedTemplate,
  userSelectedTemplateRef,
}: UseSummaryGenerationProps) {
  const [summaryStatus, setSummaryStatus] = useState<SummaryStatus>('idle');
  const [summaryError, setSummaryError] = useState<string | null>(null);

  const { startSummaryPolling, stopSummaryPolling } = useSidebar();

  // Helper to get status message
  const getSummaryStatusMessage = useCallback((status: SummaryStatus) => {
    switch (status) {
      case 'processing':
        return 'Processing transcript...';
      case 'summarizing':
        return 'Generating summary...';
      case 'regenerating':
        return 'Regenerating summary...';
      case 'completed':
        return 'Summary completed';
      case 'error':
        return 'Error generating summary';
      default:
        return '';
    }
  }, []);

  // Unified summary processing logic
  const processSummary = useCallback(async ({
    transcriptText,
    transcriptTexts,
    customPrompt = '',
    isRegeneration = false,
    templateId,
  }: {
    transcriptText: string;
    transcriptTexts?: string[];
    customPrompt?: string;
    isRegeneration?: boolean;
    // F6: overrides the picker's selectedTemplate for this run (auto-selection).
    templateId?: string;
  }) => {
    setSummaryStatus(isRegeneration ? 'regenerating' : 'processing');
    setSummaryError(null);

    try {
      if (!transcriptText.trim()) {
        throw new Error('No transcript text available. Please add some text first.');
      }

      const effectiveTemplate = templateId ?? selectedTemplate;
      console.log('Processing transcript with template:', effectiveTemplate);

      // Calculate time since recording
      const timeSinceRecording = (Date.now() - new Date(meeting.created_at).getTime()) / 60000; // minutes

      // Track summary generation started
      await Analytics.trackSummaryGenerationStarted(
        modelConfig.provider,
        modelConfig.model,
        transcriptText.length,
        timeSinceRecording
      );

      // Track custom prompt usage if present
      if (customPrompt.trim().length > 0) {
        await Analytics.trackCustomPromptUsed(customPrompt.trim().length);
      }

      // Show toast notification for generation start
      toast.info(`${isRegeneration ? 'Regenerating' : 'Generating'} summary...`, {
        description: `Using ${modelConfig.provider}/${modelConfig.model}`,
        duration: 3000,
      });

      // Resolve explicit metadata override first; Auto detects the transcript language.
      const summaryLanguage = await resolveSummaryLanguage(
        meeting.id,
        transcriptTexts?.length ? transcriptTexts : [transcriptText],
        toastNotify,
      );

      // F3: prepend owner + participant context to the custom prompt, if any
      // is known. Guarded above - never throws, falls back to "" so the
      // original custom_prompt is preserved untouched.
      const personContextPrefix = await resolvePersonContextPrefix(meeting.id);
      const promptWithPersonContext = personContextPrefix
        ? `${personContextPrefix}\n${customPrompt}`
        : customPrompt;

      // Append the timestamp-citation instruction so referenced moments become
      // playable. Additive to whatever context/prompt already exists.
      const promptWithTimestamps = promptWithPersonContext
        ? `${promptWithPersonContext}\n\n${TIMESTAMP_CITATION_INSTRUCTION}`
        : TIMESTAMP_CITATION_INSTRUCTION;

      // Process transcript and get process_id
      const result = await invokeTauri('api_process_transcript', {
        text: transcriptText,
        model: modelConfig.provider,
        modelName: modelConfig.model,
        meetingId: meeting.id,
        chunkSize: 40000,
        overlap: 1000,
        customPrompt: promptWithTimestamps,
        templateId: effectiveTemplate,
        summaryLanguage,
      }) as any;

      const process_id = result.process_id;
      console.log('Process ID:', process_id);

      // Start global polling via context
      startSummaryPolling(meeting.id, process_id, async (pollingResult) => {
        console.log('Summary status:', pollingResult);

        // Handle cancellation
        if (pollingResult.status === 'cancelled') {
          console.log('Summary generation was cancelled');

          // Reload summary from database (backend has already restored from backup)
          try {
            const existingSummary = await invokeTauri('api_get_summary', {
              meetingId: meeting.id
            }) as any;

            if (existingSummary?.data) {
              console.log('Restored previous summary after cancellation');
              setAiSummary(existingSummary.data);
              setSummaryStatus('completed');
            } else {
              setSummaryStatus('idle');
            }
          } catch (error) {
            console.error('Failed to reload summary after cancellation:', error);
            setSummaryStatus('idle');
          }

          setSummaryError(null);
          return;
        }

        // Handle errors
        if (pollingResult.status === 'error' || pollingResult.status === 'failed') {
          console.error('Backend returned error:', pollingResult.error);
          const errorMessage = pollingResult.error || `Summary ${isRegeneration ? 'regeneration' : 'generation'} failed`;

          // If this was a regeneration, try to restore previous summary from database
          if (isRegeneration) {
            try {
              const existingSummary = await invokeTauri('api_get_summary', {
                meetingId: meeting.id
              }) as any;

              if (existingSummary?.data) {
                console.log('Restored previous summary after regeneration failure');
                setAiSummary(existingSummary.data);
                setSummaryStatus('completed');
                setSummaryError(null);

                // Show error toast with restoration message
                toast.error(`Failed to regenerate summary`, {
                  description: `${errorMessage}. Your previous summary has been restored.`,
                });

                await Analytics.trackSummaryGenerationCompleted(
                  modelConfig.provider,
                  modelConfig.model,
                  false,
                  undefined,
                  errorMessage
                );
                return;
              }
            } catch (error) {
              console.error('Failed to reload summary after error:', error);
            }
          }

          // Continue with normal error handling if not regeneration or reload failed
          setSummaryError(errorMessage);
          setSummaryStatus('error');

          // Check if this is a "model is required" error
          const isModelRequiredError = errorMessage.includes('model is required') ||
            errorMessage.includes('"model":"required"') ||
            errorMessage.toLowerCase().includes('model') && errorMessage.toLowerCase().includes('required');

          // Show error toast
          toast.error(`Failed to ${isRegeneration ? 'regenerate' : 'generate'} summary`, {
            description: errorMessage.includes('Connection refused')
              ? 'Could not connect to LLM service. Please ensure Ollama or your configured LLM provider is running.'
              : errorMessage,
          });

          // Auto-open model settings modal if model is missing
          if (isModelRequiredError && onOpenModelSettings) {
            console.log('🔧 Model required error detected, opening model settings...');
            onOpenModelSettings();
          }

          await Analytics.trackSummaryGenerationCompleted(
            modelConfig.provider,
            modelConfig.model,
            false,
            undefined,
            errorMessage
          );
          return;
        }

        // Handle successful completion
        if (pollingResult.status === 'completed' && pollingResult.data) {
          console.log('Summary generation completed:', pollingResult.data);

          // Update meeting title if available
          const meetingName = pollingResult.data.MeetingName || pollingResult.meetingName;
          if (meetingName) {
            updateMeetingTitle(meetingName);
          }

          // Check if backend returned markdown format (new flow)
          if (pollingResult.data.markdown) {
            console.log('Received markdown format from backend');
            setAiSummary({ markdown: pollingResult.data.markdown } as any);
            setSummaryStatus('completed');

            // Show success toast
            toast.success('Summary generated successfully!', {
              description: 'Your meeting summary is ready',
              duration: 4000,
            });

            // F2: auto-extract facts now that a summary exists. Fire-and-forget.
            triggerFactExtraction(meeting.id);
            // F9: fold this (re)generated summary into its series ledger, mirroring the
            // headless orchestrator. Fires only here — after the summary row is persisted
            // (the backend writes it before reporting 'completed'), so the reduce can read
            // it from the DB. No-op backend-side if the meeting isn't in a series.
            // Fire-and-forget — a ledger failure must never affect the summary flow.
            invokeTauri('series_update_ledger', { meetingId: meeting.id }).catch(() => {});

            if (meetingName && onMeetingUpdated) {
              await onMeetingUpdated();
            }

            await Analytics.trackSummaryGenerationCompleted(
              modelConfig.provider,
              modelConfig.model,
              true
            );
            return;
          }

          // Legacy format handling
          const summarySections = Object.entries(pollingResult.data).filter(([key]) => key !== 'MeetingName');
          const allEmpty = summarySections.every(([, section]) => !(section as any).blocks || (section as any).blocks.length === 0);

          if (allEmpty) {
            console.error('Summary completed but all sections empty');
            setSummaryError('Summary generation completed but returned empty content.');
            setSummaryStatus('error');

            await Analytics.trackSummaryGenerationCompleted(
              modelConfig.provider,
              modelConfig.model,
              false,
              undefined,
              'Empty summary generated'
            );
            return;
          }

          // Remove MeetingName from data before formatting
          const { MeetingName, ...summaryData } = pollingResult.data;

          // Format legacy summary data
          const formattedSummary: Summary = {};
          const sectionKeys = pollingResult.data._section_order || Object.keys(summaryData);

          for (const key of sectionKeys) {
            try {
              const section = summaryData[key];
              if (section && typeof section === 'object' && 'title' in section && 'blocks' in section) {
                const typedSection = section as { title?: string; blocks?: any[] };

                if (Array.isArray(typedSection.blocks)) {
                  formattedSummary[key] = {
                    title: typedSection.title || key,
                    blocks: typedSection.blocks.map((block: any) => ({
                      ...block,
                      color: 'default',
                      content: block?.content?.trim() || ''
                    }))
                  };
                } else {
                  formattedSummary[key] = {
                    title: typedSection.title || key,
                    blocks: []
                  };
                }
              }
            } catch (error) {
              console.warn(`Error processing section ${key}:`, error);
            }
          }

          setAiSummary(formattedSummary);
          setSummaryStatus('completed');

          // Show success toast
          toast.success('Summary generated successfully!', {
            description: 'Your meeting summary is ready',
            duration: 4000,
          });

          // F2: auto-extract facts now that a summary exists. Fire-and-forget.
          triggerFactExtraction(meeting.id);
          // F9: fold this (re)generated summary into its series ledger (see the markdown
          // branch above). Fires after persistence; no-op if not in a series. Fire-and-forget.
          invokeTauri('series_update_ledger', { meetingId: meeting.id }).catch(() => {});

          await Analytics.trackSummaryGenerationCompleted(
            modelConfig.provider,
            modelConfig.model,
            true
          );

          if (meetingName && onMeetingUpdated) {
            await onMeetingUpdated();
          }
        }
      });
    } catch (error) {
      console.error(`Failed to ${isRegeneration ? 'regenerate' : 'generate'} summary:`, error);
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      setSummaryError(errorMessage);
      setSummaryStatus('error');
      // Note: We don't clear the summary here because the backend has already restored from backup

      toast.error(`Failed to ${isRegeneration ? 'regenerate' : 'generate'} summary`, {
        description: errorMessage,
      });

      await Analytics.trackSummaryGenerationCompleted(
        modelConfig.provider,
        modelConfig.model,
        false,
        undefined,
        errorMessage
      );
    }
  }, [
    meeting.id,
    meeting.created_at,
    modelConfig,
    selectedTemplate,
    startSummaryPolling,
    setAiSummary,
    updateMeetingTitle,
    onMeetingUpdated,
  ]);

  // Thin wrappers around the shared summaryCore helpers, keeping stable
  // identities for the callbacks that depend on them. The interactive path
  // passes the toast adapter so fetch failures still surface a toast.
  const fetchAllTranscripts = useCallback(
    (meetingId: string): Promise<Transcript[]> => fetchAllTranscriptsCore(meetingId, toastNotify),
    [],
  );

  const buildSummaryTranscriptPayload = useCallback(
    (allTranscripts: Transcript[], speakerLabels?: Map<string, string>) =>
      buildSummaryTranscriptPayloadCore(allTranscripts, speakerLabels),
    [],
  );

  // Public API: Generate summary from transcripts
  const handleGenerateSummary = useCallback(async (customPrompt: string = '') => {
    // Check if model config is still loading
    if (isModelConfigLoading) {
      console.log('⏳ Model configuration is still loading, please wait...');
      toast.info('Loading model configuration, please wait...');
      return;
    }

    // Show the loading UI immediately — everything below (transcript fetch,
    // provider checks, F6 template auto-selection) can take several seconds
    // before processSummary() would otherwise set this itself.
    setSummaryStatus('processing');
    setSummaryError(null);

    // CHANGE: Fetch ALL transcripts from database, not from pagination state
    console.log('📊 Fetching all transcripts for summary generation...');
    const allTranscripts = await fetchAllTranscripts(meeting.id);

    if (!allTranscripts.length) {
      const error_msg = 'No transcripts available for summary';
      console.log(error_msg);
      toast.error(error_msg);
      setSummaryStatus('idle');
      return;
    }

    console.log(`✅ Proceeding with ${allTranscripts.length} transcripts`);

    console.log('🚀 Starting summary generation with config:', {
      provider: modelConfig.provider,
      model: modelConfig.model,
      template: selectedTemplate
    });

    // Check if Ollama provider has models available
    if (modelConfig.provider === 'ollama') {
      try {
        const endpoint = modelConfig.ollamaEndpoint || null;
        const models = await invokeTauri('get_ollama_models', { endpoint }) as any[];

        if (!models || models.length === 0) {
          toast.error(
            'No Ollama models found. Please download gemma3:1b from Model Settings.',
            { duration: 5000 }
          );
          setSummaryStatus('idle');
          return;
        }
      } catch (error) {
        console.error('Error checking Ollama models:', error);
        const errorMessage = error instanceof Error ? error.message : String(error);

        if (isOllamaNotInstalledError(errorMessage)) {
          // Ollama is not installed - show specific message with download link
          toast.error(
            'Ollama is not installed',
            {
              description: 'Please download and install Ollama to use local models.',
              duration: 7000,
              action: {
                label: 'Download',
                onClick: () => invokeTauri('open_external_url', { url: 'https://ollama.com/download' })
              }
            }
          );
        } else {
          // Other error - generic message
          toast.error(
            'Failed to check Ollama models. Please ensure Ollama is running and download a model from Settings.',
            { duration: 5000 }
          );
        }
        setSummaryStatus('idle');
        return;
      }
    }

    // Check if built-in AI provider has models available
    if (modelConfig.provider === 'builtin-ai') {
      try {
        const selectedModel = modelConfig.model;

        if (!selectedModel) {
          toast.error('No built-in AI model selected', {
            description: 'Please select a model in settings',
            duration: 5000,
          });
          if (onOpenModelSettings) {
            onOpenModelSettings();
          }
          setSummaryStatus('idle');
          return;
        }

        // Check model readiness with filesystem refresh
        const isReady = await invokeTauri<boolean>('builtin_ai_is_model_ready', {
          modelName: selectedModel,
          refresh: true,
        });

        if (!isReady) {
          // Get detailed model status
          const modelInfo = await invokeTauri<BuiltInModelInfo | null>('builtin_ai_get_model_info', {
            modelName: selectedModel,
          });

          if (modelInfo) {
            const status = modelInfo.status;

            if (status.type === 'downloading') {
              toast.info('Model download in progress', {
                description: `${selectedModel} is downloading (${status.progress}%). Please wait until download completes.`,
                duration: 5000,
              });
              setSummaryStatus('idle');
              return;
            }

            if (status.type === 'not_downloaded') {
              toast.error('Built-in AI model not downloaded', {
                description: `${selectedModel} needs to be downloaded. Please download it in model settings.`,
                duration: 7000,
              });
              if (onOpenModelSettings) {
                onOpenModelSettings();
              }
              setSummaryStatus('idle');
              return;
            }

            if (status.type === 'corrupted' || status.type === 'error') {
              const errorDesc = status.type === 'error'
                ? status.Error || 'The model file has an error'
                : 'The model file is corrupted';
              toast.error('Built-in AI model not available', {
                description: `${errorDesc}. Please check model settings.`,
                duration: 7000,
              });
              if (onOpenModelSettings) {
                onOpenModelSettings();
              }
              setSummaryStatus('idle');
              return;
            }
          }

          // Fallback if we couldn't get model info
          toast.error('Built-in AI model not ready', {
            description: 'Please ensure the model is downloaded in settings',
            duration: 5000,
          });
          if (onOpenModelSettings) {
            onOpenModelSettings();
          }
          setSummaryStatus('idle');
          return;
        }

        // Model is ready, continue to backend call
      } catch (error) {
        console.error('Error validating built-in AI model:', error);
        toast.error('Failed to validate built-in AI model', {
          description: error instanceof Error ? error.message : String(error),
          duration: 5000,
        });
        setSummaryStatus('idle');
        return;
      }
    }

    // F1: fetch resolved speaker labels once and prefix each transcript line
    // with the speaker's name. Best-effort — degrades to unlabeled on failure.
    const speakerLabels = await resolveSpeakerLabelMap(meeting.id);
    const summaryPayload = buildSummaryTranscriptPayload(allTranscripts, speakerLabels);

    // F6: auto-select the template from the transcript unless the user has
    // explicitly chosen one, or a summary already exists for this meeting.
    // Auto-selection is for first generation only — once a summary exists,
    // re-suggesting on every regenerate would override a template that was
    // already deliberately chosen (including in an earlier session, after
    // userSelectedTemplateRef has reset). Best-effort — the backend degrades
    // to standard_meeting, and any failure here just leaves the current
    // selection.
    let templateOverride: string | undefined;
    if (!userSelectedTemplateRef?.current && !hasSummary) {
      try {
        // Give the classifier the same signals F3/F1 already compute elsewhere
        // in this flow — a transcript excerpt alone often can't tell a 1:1
        // from a standard meeting, but speaker count and calendar context can.
        const calendarContext = await resolvePersonContextPrefix(meeting.id);
        const distinctSpeakerCount = new Set(speakerLabels.values()).size;
        const suggestion = await templateService.suggestTemplate(
          summaryPayload.transcriptText,
          distinctSpeakerCount,
          calendarContext,
        );
        templateOverride = suggestion.id;
        applySuggestedTemplate?.(suggestion.id);
        console.log(`🎯 Auto-selected template: ${suggestion.id} (${suggestion.name})`);
      } catch (err) {
        console.warn('Template auto-selection failed; using current selection:', err);
      }
    }

    await processSummary({
      ...summaryPayload,
      customPrompt,
      templateId: templateOverride,
    });
  }, [meeting.id, fetchAllTranscripts, buildSummaryTranscriptPayload, processSummary, modelConfig, isModelConfigLoading, selectedTemplate, applySuggestedTemplate, userSelectedTemplateRef, hasSummary]);

  // Public API: Regenerate summary from the current saved transcript
  const handleRegenerateSummary = useCallback(async () => {
    const allTranscripts = await fetchAllTranscripts(meeting.id);

    if (!allTranscripts.length) {
      console.error('No transcripts available for regeneration');
      toast.error('No transcripts available for summary regeneration');
      return;
    }

    // F1: same speaker-labeling as the initial generation path.
    const speakerLabels = await resolveSpeakerLabelMap(meeting.id);

    await processSummary({
      ...buildSummaryTranscriptPayload(allTranscripts, speakerLabels),
      isRegeneration: true
    });
  }, [meeting.id, fetchAllTranscripts, buildSummaryTranscriptPayload, processSummary]);

  // Public API: Stop ongoing summary generation
  const handleStopGeneration = useCallback(async () => {
    console.log('Stopping summary generation for meeting:', meeting.id);

    try {
      // Call backend to cancel the summary generation
      await invokeTauri('api_cancel_summary', {
        meetingId: meeting.id
      });
      console.log('✓ Backend cancellation request sent for meeting:', meeting.id);
    } catch (error) {
      console.error('Failed to cancel summary generation:', error);
      // Continue with frontend cleanup even if backend call fails
    }

    // Stop polling
    stopSummaryPolling(meeting.id);

    // Reset status to idle
    setSummaryStatus('idle');
    setSummaryError(null);

    // Show toast notification
    toast.info('Summary generation stopped', {
      description: 'You can generate a new summary anytime',
      duration: 3000,
    });
  }, [meeting.id, stopSummaryPolling]);

  return {
    summaryStatus,
    summaryError,
    handleGenerateSummary,
    handleRegenerateSummary,
    handleStopGeneration,
    getSummaryStatusMessage,
  };
}

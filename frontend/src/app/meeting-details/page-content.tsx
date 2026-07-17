"use client";
import { useState, useEffect, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import { motion } from 'framer-motion';
import { Summary, SummaryResponse } from '@/types';
import { useSidebar } from '@/components/Sidebar/SidebarProvider';
import Analytics from '@/lib/analytics';
import { invoke } from '@tauri-apps/api/core';
import { toast } from 'sonner';
import { TranscriptPanel } from '@/components/MeetingDetails/TranscriptPanel';
import { SummaryPanel } from '@/components/MeetingDetails/SummaryPanel';
import { ModelConfig } from '@/components/ModelSettingsModal';

// Custom hooks
import { useMeetingData } from '@/hooks/meeting-details/useMeetingData';
import { useSummaryGeneration } from '@/hooks/meeting-details/useSummaryGeneration';
import { useTemplates } from '@/hooks/meeting-details/useTemplates';
import { useCopyOperations } from '@/hooks/meeting-details/useCopyOperations';
import { useMeetingOperations } from '@/hooks/meeting-details/useMeetingOperations';
import { useConfig } from '@/contexts/ConfigContext';
import { Button } from '@/components/ui/button';
import { ViewColumnsIcon } from '@heroicons/react/24/outline';
import { cn } from '@/lib/utils';
import { ResizeHandle } from '@/components/MeetingDetails/ResizeHandle';
import { AudioPlaybackProvider, useAudioPlayback } from '@/contexts/AudioPlaybackContext';
import { AskAudioBridge } from '@/components/ask/AskAudioBridge';
import { MeetingProcessingBanner } from '@/components/MeetingDetails/MeetingProcessingBanner';
import type { ProcessingEntry } from '@/contexts/MeetingProcessingContext';

// Bounds for the drag-resizable transcript panel (inline `xl` layout only).
const TRANSCRIPT_MIN_WIDTH = 300;
const TRANSCRIPT_MAX_WIDTH = 680;
const TRANSCRIPT_WIDTH_STORAGE_KEY = 'ari:transcriptPanelWidth';

/**
 * Deep-link seek: when the meeting is opened with `?t=<seconds>` (e.g. from a series-ledger
 * `@mref` badge), seek the recording to that offset and start playing ONCE the audio is
 * ready. Renders nothing.
 *
 * No-Fake-State: only seeks when `t` is a finite, in-range offset ([0, duration]); an
 * absent/invalid/out-of-range `t` is ignored so we never seek to a fabricated moment. `t`
 * is integer seconds (the badge converts its `MM:SS` timestamp to seconds).
 */
function DeepLinkSeek() {
  const searchParams = useSearchParams();
  const audio = useAudioPlayback();
  const didSeekRef = useRef(false);

  const tRaw = searchParams.get('t');

  useEffect(() => {
    if (!audio) return;
    if (didSeekRef.current) return;
    if (tRaw == null) return;
    if (audio.status !== 'ready') return;

    const t = Number(tRaw);
    if (!Number.isFinite(t) || t < 0) return;
    // Duration must be known and the target within it — otherwise ignore (No-Fake-State).
    if (!(audio.duration > 0) || t > audio.duration) return;

    didSeekRef.current = true;
    audio.seekAndPlay(t);
  }, [audio, tRaw]);

  return null;
}

export default function PageContent({
  meeting,
  summaryData,
  processing,
  onMeetingUpdated,
  onRefetchTranscripts,
  // Pagination props for efficient transcript loading
  segments,
  hasMore,
  isLoadingMore,
  totalCount,
  loadedCount,
  onLoadMore,
}: {
  meeting: any;
  summaryData: Summary | null;
  // Background diarize→summary pipeline state for this meeting (undefined if none).
  processing?: ProcessingEntry;
  onMeetingUpdated?: () => Promise<void>;
  onRefetchTranscripts?: () => Promise<void>;
  // Pagination props
  segments?: any[];
  hasMore?: boolean;
  isLoadingMore?: boolean;
  totalCount?: number;
  loadedCount?: number;
  onLoadMore?: () => void;
}) {
  console.log('📄 PAGE CONTENT: Initializing with data:', {
    meetingId: meeting.id,
    summaryDataKeys: summaryData ? Object.keys(summaryData) : null,
    transcriptsCount: meeting.transcripts?.length
  });

  // State
  const [customPrompt, setCustomPrompt] = useState<string>('');
  const [isRecording] = useState(false);
  const [summaryResponse] = useState<SummaryResponse | null>(null);
  const [isInspectorOpen, setIsInspectorOpen] = useState(false);

  // Drag-resizable transcript panel width (px). null → use the CSS default.
  const panelRowRef = useRef<HTMLDivElement>(null);
  const [transcriptWidth, setTranscriptWidth] = useState<number | null>(null);

  useEffect(() => {
    const stored = Number(window.localStorage.getItem(TRANSCRIPT_WIDTH_STORAGE_KEY));
    if (Number.isFinite(stored) && stored >= TRANSCRIPT_MIN_WIDTH && stored <= TRANSCRIPT_MAX_WIDTH) {
      setTranscriptWidth(stored);
    }
  }, []);

  const handleTranscriptResize = (next: number) => {
    setTranscriptWidth(next);
    window.localStorage.setItem(TRANSCRIPT_WIDTH_STORAGE_KEY, String(Math.round(next)));
  };

  useEffect(() => {
    if (!isInspectorOpen) return;

    const closeInspectorOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setIsInspectorOpen(false);
      }
    };

    window.addEventListener('keydown', closeInspectorOnEscape);
    return () => window.removeEventListener('keydown', closeInspectorOnEscape);
  }, [isInspectorOpen]);

  // Ref to store the modal open function from SummaryGeneratorButtonGroup
  const openModelSettingsRef = useRef<(() => void) | null>(null);

  // Sidebar context
  const { serverAddress } = useSidebar();

  // Get model config from ConfigContext
  const { modelConfig, setModelConfig, transcriptModelConfig } = useConfig();

  // Human label for the transcription engine that produced THIS meeting.
  // Prefers the per-meeting provenance record (provider + model captured at
  // transcribe time) so the label reflects what actually ran. Falls back to
  // the current TRANSCRIPT config only for legacy meetings recorded before
  // provenance existed (null provider). The summary config's static
  // `whisperModel` field is the last resort — it's always "large-v3" and
  // mislabels every meeting.
  const labelFor = (p?: string, m?: string): string | null => {
    if (p === 'apple') return 'Apple (on-device)';
    if (p === 'parakeet') return 'Parakeet';
    if (p === 'localWhisper') return m ? `Whisper ${m}` : 'Whisper';
    if (p) return m ? `${p} ${m}` : p;
    return null;
  };
  const transcriptionEngineLabel =
    labelFor(meeting.transcription_provider, meeting.transcription_model) ??
    labelFor(transcriptModelConfig?.provider, transcriptModelConfig?.model) ??
    modelConfig.whisperModel ??
    'Not configured';

  // Human label for the LLM that produced THIS meeting's summary. Prefers the
  // per-meeting provenance record (provider + model captured at summary time);
  // falls back to the currently configured summary model only for legacy
  // meetings summarized before provenance existed (null provider).
  const labelForSummary = (p?: string, m?: string): string | null => {
    if (!p) return null;
    const providerNames: Record<string, string> = {
      claude: 'Claude',
      'claude-cli': 'Claude CLI',
      openai: 'OpenAI',
      groq: 'Groq',
      ollama: 'Ollama',
      openrouter: 'OpenRouter',
      'custom-openai': 'Custom OpenAI',
      'apple-foundation': 'Apple (on-device)',
      'builtin-ai': 'Built-in AI',
    };
    const name = providerNames[p] ?? p;
    return m ? `${name} · ${m}` : name;
  };
  const summaryEngineLabel =
    labelForSummary(meeting.summary_provider, meeting.summary_model) ??
    labelForSummary(modelConfig.provider, modelConfig.model) ??
    'Not configured';

  // Custom hooks
  const meetingData = useMeetingData({ meeting, summaryData, onMeetingUpdated });
  const templates = useTemplates(meeting.id);

  // Callback to register the modal open function
  const handleRegisterModalOpen = (openFn: () => void) => {
    console.log('📝 Registering modal open function in PageContent');
    openModelSettingsRef.current = openFn;
  };

  // Callback to trigger modal open (called from error handler)
  const handleOpenModelSettings = () => {
    console.log('🔔 Opening model settings from PageContent');
    if (openModelSettingsRef.current) {
      openModelSettingsRef.current();
    } else {
      console.warn('⚠️ Modal open function not yet registered');
    }
  };

  // Save model config to backend database and sync via event
  const handleSaveModelConfig = async (config?: ModelConfig) => {
    if (!config) return;
    try {
      await invoke('api_save_model_config', {
        provider: config.provider,
        model: config.model,
        whisperModel: config.whisperModel,
        apiKey: config.apiKey ?? null,
        ollamaEndpoint: config.ollamaEndpoint ?? null,
      });

      // Emit event so ConfigContext and other listeners stay in sync
      const { emit } = await import('@tauri-apps/api/event');
      await emit('model-config-updated', config);

      toast.success('Model settings saved successfully');
    } catch (error) {
      console.error('Failed to save model config:', error);
      toast.error('Failed to save model settings');
    }
  };

  const summaryGeneration = useSummaryGeneration({
    meeting,
    transcripts: meetingData.transcripts,
    modelConfig: modelConfig,
    isModelConfigLoading: false, // ConfigContext loads on mount
    selectedTemplate: templates.selectedTemplate,
    onMeetingUpdated,
    updateMeetingTitle: meetingData.updateMeetingTitle,
    setAiSummary: meetingData.setAiSummary,
    hasSummary: !!meetingData.aiSummary,
    onOpenModelSettings: handleOpenModelSettings,
    applySuggestedTemplate: templates.applySuggestedTemplate,
    userSelectedTemplateRef: templates.userSelectedTemplateRef,
  });

  const copyOperations = useCopyOperations({
    meeting,
    transcripts: meetingData.transcripts,
    meetingTitle: meetingData.meetingTitle,
    aiSummary: meetingData.aiSummary,
    blockNoteSummaryRef: meetingData.blockNoteSummaryRef,
  });

  const meetingOperations = useMeetingOperations({
    meeting,
  });

  // Track page view
  useEffect(() => {
    Analytics.trackPageView('meeting_details');
  }, []);

  // Post-recording summaries are triggered by the background pipeline
  // (MeetingProcessingContext), not by this page — so the old racy on-mount
  // auto-generate has been removed. While that pipeline is actively diarizing
  // or summarizing THIS meeting, gate the manual generate/regenerate buttons so
  // the user can't kick off a second concurrent summary for the same meeting.
  const isBackgroundProcessing =
    processing?.phase === 'diarizing' || processing?.phase === 'summarizing';

  const handleManualGenerate = async (customPromptArg: string = '') => {
    if (isBackgroundProcessing) {
      toast.info('Still working on this meeting', {
        description: 'Speaker labeling and the summary are finishing up in the background.',
      });
      return;
    }
    await summaryGeneration.handleGenerateSummary(customPromptArg);
  };

  const handleManualRegenerate = async () => {
    if (isBackgroundProcessing) {
      toast.info('Still working on this meeting', {
        description: 'Speaker labeling and the summary are finishing up in the background.',
      });
      return;
    }
    await summaryGeneration.handleRegenerateSummary();
  };

  // Recording audio lives at <folder>/audio.mp4; null when no folder is linked.
  const audioPath = meeting.folder_path ? `${meeting.folder_path}/audio.mp4` : null;

  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.3, ease: 'easeOut' }}
      className="flex h-full flex-col bg-background"
    >
      <AudioPlaybackProvider audioPath={audioPath}>
      {/* Bridge this meeting's audio player into AskContext so the global Ask overlay can
          play @ref(MM:SS) badges when scoped to this meeting. Renders nothing. */}
      <AskAudioBridge meetingId={meeting.id} />
      {/* Deep-link seek: honor `?t=<seconds>` (series-ledger @mref badges) once ready. */}
      <DeepLinkSeek />
      {/* Subtle, non-blocking background-processing strip (diarize → summary).
          Renders nothing unless this meeting has an active/errored pipeline. */}
      <MeetingProcessingBanner meetingId={meeting.id} />
      <div
        ref={panelRowRef}
        className="flex flex-1 overflow-hidden"
        style={
          transcriptWidth
            ? ({ ['--transcript-w' as string]: `${transcriptWidth}px` } as React.CSSProperties)
            : undefined
        }
      >
        <SummaryPanel
          meeting={meeting}
          meetingTitle={meetingData.meetingTitle}
          onTitleChange={meetingData.handleTitleChange}
          isEditingTitle={meetingData.isEditingTitle}
          onStartEditTitle={() => meetingData.setIsEditingTitle(true)}
          onFinishEditTitle={async () => {
            if (!meetingData.isTitleDirty || await meetingData.handleSaveMeetingTitle()) {
              meetingData.setIsEditingTitle(false);
            }
          }}
          isTitleDirty={meetingData.isTitleDirty}
          summaryRef={meetingData.blockNoteSummaryRef}
          isSaving={meetingData.isSaving}
          onSaveAll={meetingData.saveAllChanges}
          onCopySummary={copyOperations.handleCopySummary}
          onOpenFolder={meetingOperations.handleOpenMeetingFolder}
          aiSummary={meetingData.aiSummary}
          summaryStatus={summaryGeneration.summaryStatus}
          transcripts={meetingData.transcripts}
          modelConfig={modelConfig}
          setModelConfig={setModelConfig}
          onSaveModelConfig={handleSaveModelConfig}
          onGenerateSummary={handleManualGenerate}
          onStopGeneration={summaryGeneration.handleStopGeneration}
          customPrompt={customPrompt}
          onPromptChange={setCustomPrompt}
          summaryResponse={summaryResponse}
          onSaveSummary={meetingData.handleSaveSummary}
          onSummaryChange={meetingData.handleSummaryChange}
          onDirtyChange={meetingData.setIsSummaryDirty}
          summaryError={summaryGeneration.summaryError}
          onRegenerateSummary={handleManualRegenerate}
          getSummaryStatusMessage={summaryGeneration.getSummaryStatusMessage}
          availableTemplates={templates.availableTemplates}
          selectedTemplate={templates.selectedTemplate}
          onTemplateSelect={templates.handleTemplateSelection}
          isModelConfigLoading={false}
          onOpenModelSettings={handleRegisterModalOpen}
          isBackgroundProcessing={isBackgroundProcessing}
          backgroundStage={processing?.stage}
          inspectorControl={
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="shrink-0 xl:hidden"
              onClick={() => setIsInspectorOpen(true)}
            >
              <ViewColumnsIcon className="size-4" aria-hidden="true" />
              Transcript
            </Button>
          }
        />
        <ResizeHandle
          containerRef={panelRowRef}
          width={transcriptWidth ?? 352}
          min={TRANSCRIPT_MIN_WIDTH}
          max={TRANSCRIPT_MAX_WIDTH}
          onChange={handleTranscriptResize}
        />
        <TranscriptPanel
          transcripts={meetingData.transcripts}
          onCopyTranscript={copyOperations.handleCopyTranscript}
          onOpenMeetingFolder={meetingOperations.handleOpenMeetingFolder}
          onExportMeeting={meetingOperations.handleExportMeeting}
          isRecording={isRecording}
          disableAutoScroll={true}
          usePagination={true}
          segments={segments}
          hasMore={hasMore}
          isLoadingMore={isLoadingMore}
          totalCount={totalCount}
          loadedCount={loadedCount}
          onLoadMore={onLoadMore}
          hasSavedSummary={summaryData !== null}
          meetingId={meeting.id}
          meetingFolderPath={meeting.folder_path}
          onRefetchTranscripts={onRefetchTranscripts}
          isBackgroundProcessing={isBackgroundProcessing}
          isBackgroundDiarizing={processing?.phase === 'diarizing'}
          transcriptionModel={transcriptionEngineLabel}
          summaryModel={summaryEngineLabel}
          onCloseInspector={() => setIsInspectorOpen(false)}
          className={cn(
            'fixed inset-y-12 right-0 z-40 w-[min(28rem,100vw)] shadow-[-16px_0_32px_hsl(var(--foreground)/0.12)]',
            'xl:static xl:z-auto xl:w-[var(--transcript-w,22rem)] xl:shadow-none',
            isInspectorOpen ? 'flex' : 'hidden xl:flex',
          )}
        />
      </div>
      </AudioPlaybackProvider>
    </motion.div>
  );
}

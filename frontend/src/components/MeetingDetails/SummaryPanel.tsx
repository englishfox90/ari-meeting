"use client";

import { Summary, SummaryResponse, Transcript } from '@/types';
import type { BlockNoteSummaryViewRef } from '@/components/AISummary/BlockNoteSummaryView';
import { SummarySkeleton } from '@/components/AISummary/SummarySkeleton';
import { EmptyStateSummary } from '@/components/EmptyStateSummary';
import { ModelConfig } from '@/components/ModelSettingsModal';
import { SummaryGeneratorButtonGroup } from './SummaryGeneratorButtonGroup';
import { SummaryUpdaterButtonGroup } from './SummaryUpdaterButtonGroup';
import { SummaryMoments } from './SummaryMoments';
import Analytics from '@/lib/analytics';
import { lazy, Suspense, useCallback, useEffect, useRef, useState, RefObject, ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { ChevronDownIcon, ChevronLeftIcon, ChevronRightIcon, LanguageIcon, PencilIcon } from '@heroicons/react/24/outline';
import { Button } from '@/components/ui/button';
import { seriesService } from '@/services/seriesService';
import { SeriesAttachControl } from './SeriesAttachControl';
import type { SeriesForMeeting } from '@/types/series';
import { Popover, PopoverTrigger, PopoverContent } from '@/components/ui/popover';
import { LanguagePickerPopover } from '@/components/LanguagePickerPopover';
import { useRecentLanguages } from '@/hooks/useRecentLanguages';
import { labelForCode } from '@/lib/summary-languages';
import {
  readMeetingSummaryLanguage,
  saveMeetingSummaryLanguage,
  SummaryLanguageStorage,
} from '@/lib/summary-language-preferences';

// The BlockNote/ProseMirror summary editor is heavy to load and mount. Code-split
// it so opening a meeting paints the shell + transcript immediately and shows a
// skeleton, instead of blocking the main thread on the editor mount (which kept
// the "Opening meeting" loader visible on larger meetings). React.lazy forwards
// the ref to the underlying forwardRef component.
const BlockNoteSummaryView = lazy(() =>
  import('@/components/AISummary/BlockNoteSummaryView').then((m) => ({
    default: m.BlockNoteSummaryView,
  })),
);

interface SummaryPanelProps {
  meeting: {
    id: string;
    title: string;
    created_at: string;
  };
  meetingTitle: string;
  onTitleChange: (title: string) => void;
  isEditingTitle: boolean;
  onStartEditTitle: () => void;
  onFinishEditTitle: () => void | Promise<void>;
  isTitleDirty: boolean;
  summaryRef: RefObject<BlockNoteSummaryViewRef>;
  isSaving: boolean;
  onSaveAll: () => Promise<void>;
  onCopySummary: () => Promise<void>;
  onOpenFolder: () => Promise<void>;
  aiSummary: Summary | null;
  summaryStatus: 'idle' | 'processing' | 'summarizing' | 'regenerating' | 'completed' | 'error';
  transcripts: Transcript[];
  modelConfig: ModelConfig;
  setModelConfig: (config: ModelConfig | ((prev: ModelConfig) => ModelConfig)) => void;
  onSaveModelConfig: (config?: ModelConfig) => Promise<void>;
  onGenerateSummary: (customPrompt: string) => Promise<void>;
  onStopGeneration: () => void;
  customPrompt: string;
  onPromptChange: (value: string) => void;
  summaryResponse: SummaryResponse | null;
  onSaveSummary: (summary: Summary | { markdown?: string; summary_json?: any[] }) => Promise<void>;
  onSummaryChange: (summary: Summary) => void;
  onDirtyChange: (isDirty: boolean) => void;
  summaryError: string | null;
  onRegenerateSummary: () => Promise<void>;
  getSummaryStatusMessage: (status: 'idle' | 'processing' | 'summarizing' | 'regenerating' | 'completed' | 'error') => string;
  availableTemplates: Array<{ id: string, name: string, description: string }>;
  selectedTemplate: string;
  onTemplateSelect: (templateId: string, templateName: string) => void;
  isModelConfigLoading?: boolean;
  onOpenModelSettings?: (openFn: () => void) => void;
  inspectorControl?: ReactNode;
  /**
   * The background diarize→summary pipeline (MeetingProcessingContext) is
   * actively running for THIS meeting. While true, the summary window shows the
   * live pipeline phase instead of a pressable "Generate summary" affordance,
   * and the manual generate/regenerate action is disabled — the summary is
   * already being produced.
   */
  isBackgroundProcessing?: boolean;
  /** Which pipeline step is running, so the window shows an honest phase label. */
  backgroundStage?: 'diarization' | 'summary';
}

export function SummaryPanel({
  meeting,
  meetingTitle,
  onTitleChange,
  isEditingTitle,
  onStartEditTitle,
  onFinishEditTitle,
  isTitleDirty,
  summaryRef,
  isSaving,
  onSaveAll,
  onCopySummary,
  onOpenFolder,
  aiSummary,
  summaryStatus,
  transcripts,
  modelConfig,
  setModelConfig,
  onSaveModelConfig,
  onGenerateSummary,
  onStopGeneration,
  customPrompt,
  onPromptChange,
  summaryResponse,
  onSaveSummary,
  onSummaryChange,
  onDirtyChange,
  summaryError,
  onRegenerateSummary,
  getSummaryStatusMessage,
  availableTemplates,
  selectedTemplate,
  onTemplateSelect,
  isModelConfigLoading = false,
  onOpenModelSettings,
  inspectorControl,
  isBackgroundProcessing = false,
  backgroundStage,
}: SummaryPanelProps) {
  const [summaryLang, setSummaryLang] = useState<string | null>(null);
  const [summaryLangStorage, setSummaryLangStorage] = useState<SummaryLanguageStorage>('metadata');
  const [langPickerOpen, setLangPickerOpen] = useState(false);
  const languageLoadVersionRef = useRef(0);
  const activeMeetingIdRef = useRef(meeting.id);
  const languageSaveVersionRef = useRef(0);
  const languageSaveLoopRunningRef = useRef(false);
  const latestLanguageSaveRequestRef = useRef<{
    version: number;
    meetingId: string;
    language: string | null;
    rollback: {
      language: string | null;
      storage: SummaryLanguageStorage;
    };
  } | null>(null);
  activeMeetingIdRef.current = meeting.id;
  const { addRecent } = useRecentLanguages();
  const router = useRouter();

  // Which series (if any) this meeting belongs to, for the breadcrumb. Fetched
  // locally to avoid prop-drilling through the whole meeting-details tree.
  // No-Fake-State: null (nothing rendered) until a real membership is known.
  const [seriesInfo, setSeriesInfo] = useState<SeriesForMeeting | null>(null);
  const refreshSeriesInfo = useCallback(async () => {
    if (!seriesService.isAvailable()) {
      setSeriesInfo(null);
      return;
    }
    try {
      const info = await seriesService.forMeeting(meeting.id);
      setSeriesInfo(info);
    } catch (err) {
      console.error('Failed to load series membership for meeting:', err);
      setSeriesInfo(null);
    }
  }, [meeting.id]);
  useEffect(() => {
    let cancelled = false;
    setSeriesInfo(null);
    if (!seriesService.isAvailable()) return;
    seriesService
      .forMeeting(meeting.id)
      .then((info) => {
        if (!cancelled) setSeriesInfo(info);
      })
      .catch((err) => {
        console.error('Failed to load series membership for meeting:', err);
        if (!cancelled) setSeriesInfo(null);
      });
    return () => {
      cancelled = true;
    };
  }, [meeting.id]);

  const effectiveLangLabel = summaryLang ? labelForCode(summaryLang) : 'Auto';
  const isLocalFallbackLanguage = summaryLangStorage === 'local_fallback';
  const autoSubtitle = isLocalFallbackLanguage
    ? 'Saved on this device for folderless meetings'
    : 'Uses dominant transcript language';

  useEffect(() => {
    let cancelled = false;
    const loadVersion = languageLoadVersionRef.current + 1;
    languageLoadVersionRef.current = loadVersion;

    const loadSummaryLanguage = async () => {
      try {
        const stored = await readMeetingSummaryLanguage(meeting.id);
        if (!cancelled && languageLoadVersionRef.current === loadVersion) {
          setSummaryLang(stored.language);
          setSummaryLangStorage(stored.storage);
        }
      } catch (err) {
        console.error('Failed to load summary language:', err);
        toast.warning('Could not load saved summary language', {
          description: 'Using Auto until meeting metadata can be read.',
        });
        if (!cancelled && languageLoadVersionRef.current === loadVersion) setSummaryLang(null);
      }
    };

    loadSummaryLanguage();

    return () => {
      cancelled = true;
    };
  }, [meeting.id]);

  const persistLatestLanguageSelection = async () => {
    if (languageSaveLoopRunningRef.current) return;
    languageSaveLoopRunningRef.current = true;

    try {
      while (true) {
        const request = latestLanguageSaveRequestRef.current;
        if (!request) return;

        try {
          const saved = await saveMeetingSummaryLanguage(request.meetingId, request.language);
          const latest = latestLanguageSaveRequestRef.current;
          if (
            latest?.version === request.version &&
            activeMeetingIdRef.current === request.meetingId
          ) {
            setSummaryLang(saved.language);
            setSummaryLangStorage(saved.storage);
            if (saved.storage === 'local_fallback') {
              toast.info('Summary language saved on this device', {
                description: 'This meeting has no recording folder, so the preference cannot be written to meeting metadata.',
              });
            }
            if (request.language) {
              addRecent(request.language);
            }
            return;
          }

          if (latest?.version === request.version) return;
        } catch (err) {
          const latest = latestLanguageSaveRequestRef.current;
          if (
            latest?.version === request.version &&
            activeMeetingIdRef.current === request.meetingId
          ) {
            console.error('Failed to persist summary language:', err);
            toast.error('Failed to save summary language');
            setSummaryLang(request.rollback.language);
            setSummaryLangStorage(request.rollback.storage);
            return;
          }

          console.warn('Ignoring failed stale summary language save:', err);
          if (latest?.version === request.version) return;
        }
      }
    } finally {
      languageSaveLoopRunningRef.current = false;
    }
  };

  const handleLangChange = (code: string | null) => {
    const previous = summaryLang;
    const previousStorage = summaryLangStorage;
    const nextStored = code;
    languageLoadVersionRef.current += 1;
    latestLanguageSaveRequestRef.current = {
      version: languageSaveVersionRef.current + 1,
      meetingId: meeting.id,
      language: nextStored,
      rollback: {
        language: previous,
        storage: previousStorage,
      },
    };
    languageSaveVersionRef.current += 1;
    setSummaryLang(nextStored);
    setLangPickerOpen(false);
    void persistLatestLanguageSelection();
  };

  const isSummaryLoading = summaryStatus === 'processing' || summaryStatus === 'summarizing' || summaryStatus === 'regenerating';
  // The background pipeline (diarize → summary) owns the summary window while it
  // runs and no summary exists yet: show its live phase here instead of a
  // pressable Generate affordance. An already-saved summary is never hidden;
  // manual generation (isSummaryLoading) takes precedence — they never overlap
  // because the manual buttons are disabled while the pipeline is active.
  const showBackgroundProcessing = isBackgroundProcessing && !isSummaryLoading && !aiSummary;
  const backgroundLabel =
    backgroundStage === 'summary' ? 'Generating summary…' : 'Identifying speakers…';
  const meetingDate = new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(meeting.created_at));

  const languageSlot = (
    <Popover open={langPickerOpen} onOpenChange={setLangPickerOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          title={`Summary language: ${effectiveLangLabel}${isLocalFallbackLanguage ? ' (saved on this device)' : ''}`}
          aria-label="Set summary language"
        >
          <LanguageIcon className="size-[18px]" aria-hidden="true" />
          <span className="hidden lg:inline">{effectiveLangLabel}</span>
          <ChevronDownIcon className="size-3.5 text-muted-foreground" aria-hidden="true" />
        </Button>
      </PopoverTrigger>
      <PopoverContent
        align="end"
        className="w-auto p-0 border-0 shadow-none bg-transparent"
      >
        <LanguagePickerPopover
          value={summaryLang}
          onChange={handleLangChange}
          onClose={() => setLangPickerOpen(false)}
          autoSubtitle={autoSubtitle}
        />
      </PopoverContent>
    </Popover>
  );

  return (
    <section aria-label="Meeting summary" className="flex min-w-0 flex-1 flex-col overflow-hidden bg-card">
      <div className="border-b border-border px-6 pb-4 pt-5 sm:px-8">
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2.5">
              <p className="app-eyebrow">Meeting note</p>
              <span className="text-border" aria-hidden="true">/</span>
              <time className="truncate text-[0.6875rem] text-muted-foreground" dateTime={meeting.created_at}>{meetingDate}</time>
              {seriesInfo && (
                <>
                  <span className="text-border" aria-hidden="true">/</span>
                  <span className="flex items-center gap-1">
                    <button
                      type="button"
                      onClick={() => seriesInfo.prevMeetingId && router.push(`/meeting-details?id=${seriesInfo.prevMeetingId}`)}
                      disabled={!seriesInfo.prevMeetingId}
                      aria-label="Previous meeting in series"
                      className="grid size-5 place-items-center rounded-sm text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
                    >
                      <ChevronLeftIcon className="size-3.5" aria-hidden="true" />
                    </button>
                    <button
                      type="button"
                      onClick={() => router.push(`/series-details?id=${seriesInfo.seriesId}`)}
                      className="truncate rounded-sm text-[0.6875rem] font-medium text-muted-foreground transition-colors hover:text-foreground"
                    >
                      {seriesInfo.seriesTitle} · Session {seriesInfo.position} of {seriesInfo.total}
                    </button>
                    <button
                      type="button"
                      onClick={() => seriesInfo.nextMeetingId && router.push(`/meeting-details?id=${seriesInfo.nextMeetingId}`)}
                      disabled={!seriesInfo.nextMeetingId}
                      aria-label="Next meeting in series"
                      className="grid size-5 place-items-center rounded-sm text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
                    >
                      <ChevronRightIcon className="size-3.5" aria-hidden="true" />
                    </button>
                  </span>
                </>
              )}
              <SeriesAttachControl
                meetingId={meeting.id}
                meetingTitle={meeting.title}
                seriesInfo={seriesInfo}
                onChanged={() => void refreshSeriesInfo()}
              />
            </div>
            <div className="mt-2 min-w-0">
              {isEditingTitle ? (
                <input
                  autoFocus
                  value={meetingTitle}
                  onChange={(event) => onTitleChange(event.target.value)}
                  onBlur={() => void onFinishEditTitle()}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') {
                      event.preventDefault();
                      event.currentTarget.blur();
                    }
                  }}
                  aria-label="Meeting title"
                  className="w-full border-0 border-b border-accent bg-transparent pb-1 text-[1.625rem] font-semibold leading-tight tracking-[-0.045em] outline-none"
                />
              ) : (
                <button
                  type="button"
                  onClick={onStartEditTitle}
                  className="group/title flex max-w-full items-center gap-2 rounded-sm text-left"
                  aria-label={`Rename ${meetingTitle}`}
                >
                  <h1 className="truncate text-[1.625rem] font-semibold leading-tight tracking-[-0.045em]">{meetingTitle}</h1>
                  <PencilIcon className="size-3.5 shrink-0 text-muted-foreground opacity-0 transition-opacity group-hover/title:opacity-100 group-focus-visible/title:opacity-100" aria-hidden="true" />
                </button>
              )}
            </div>
          </div>
          {inspectorControl}
        </div>
        {aiSummary && !isSummaryLoading && (
          <div className="mt-4 flex flex-wrap items-center justify-between gap-2 border-t border-border/70 pt-3">
            <div className="min-w-0 shrink-0">
              <SummaryGeneratorButtonGroup
                modelConfig={modelConfig}
                setModelConfig={setModelConfig}
                onSaveModelConfig={onSaveModelConfig}
                onGenerateSummary={onGenerateSummary}
                onRegenerateSummary={onRegenerateSummary}
                onStopGeneration={onStopGeneration}
                customPrompt={customPrompt}
                onPromptChange={onPromptChange}
                summaryStatus={summaryStatus}
                availableTemplates={availableTemplates}
                selectedTemplate={selectedTemplate}
                onTemplateSelect={onTemplateSelect}
                hasTranscripts={transcripts.length > 0}
                hasSummary={!!aiSummary}
                isModelConfigLoading={isModelConfigLoading}
                onOpenModelSettings={onOpenModelSettings}
                languageSlot={languageSlot}
                disabled={isBackgroundProcessing}
              />
            </div>

            <div className="ml-auto shrink-0">
              <SummaryUpdaterButtonGroup
                isSaving={isSaving}
                isDirty={isTitleDirty || (summaryRef.current?.isDirty || false)}
                onSave={onSaveAll}
                onCopy={onCopySummary}
                onFind={() => {
                  // TODO: Implement find in summary functionality
                  console.log('Find in summary clicked');
                }}
                onOpenFolder={onOpenFolder}
                hasSummary={!!aiSummary}
              />
            </div>
          </div>
        )}
      </div>

      {isSummaryLoading ? (
        <div className="flex flex-col h-full">
          {/* Show button group during generation */}
          <div className="flex items-center justify-center border-b border-border px-6 py-5">
            <SummaryGeneratorButtonGroup
              modelConfig={modelConfig}
              setModelConfig={setModelConfig}
              onSaveModelConfig={onSaveModelConfig}
              onGenerateSummary={onGenerateSummary}
              onStopGeneration={onStopGeneration}
              customPrompt={customPrompt}
              onPromptChange={onPromptChange}
              summaryStatus={summaryStatus}
              availableTemplates={availableTemplates}
              selectedTemplate={selectedTemplate}
              onTemplateSelect={onTemplateSelect}
              hasTranscripts={transcripts.length > 0}
              isModelConfigLoading={isModelConfigLoading}
              onOpenModelSettings={onOpenModelSettings}
            />
          </div>
          {/* Loading spinner */}
          <div className="flex items-center justify-center flex-1">
            <div className="text-center">
              <div className="mb-4 inline-block size-10 animate-spin rounded-full border-2 border-accent/25 border-t-accent"></div>
              <p className="text-sm text-muted-foreground">Generating AI summary...</p>
            </div>
          </div>
        </div>
      ) : showBackgroundProcessing ? (
        // The post-recording pipeline is running for this meeting. Reflect its
        // live phase in the summary window (No-Fake-State: real phase, no counts
        // or percentages) rather than offering a Generate button that would race
        // the pipeline. The summary appears automatically when it completes.
        <div className="flex flex-1 items-center justify-center">
          <div className="text-center">
            <div className="mb-4 inline-block size-10 animate-spin rounded-full border-2 border-accent/25 border-t-accent motion-reduce:animate-none"></div>
            <p className="text-sm font-medium text-foreground">{backgroundLabel}</p>
            <p className="mt-1 text-xs text-muted-foreground">
              This finishes automatically — no need to do anything.
            </p>
          </div>
        </div>
      ) : !aiSummary ? (
        <div className="flex flex-col h-full">
          {/* Centered Summary Generator Button Group when no summary */}
          <div className="flex items-center justify-center gap-2 border-b border-border px-6 py-5">
            <SummaryGeneratorButtonGroup
              modelConfig={modelConfig}
              setModelConfig={setModelConfig}
              onSaveModelConfig={onSaveModelConfig}
              onGenerateSummary={onGenerateSummary}
              onStopGeneration={onStopGeneration}
              customPrompt={customPrompt}
              onPromptChange={onPromptChange}
              summaryStatus={summaryStatus}
              availableTemplates={availableTemplates}
              selectedTemplate={selectedTemplate}
              onTemplateSelect={onTemplateSelect}
              hasTranscripts={transcripts.length > 0}
              hasSummary={false}
              isModelConfigLoading={isModelConfigLoading}
              onOpenModelSettings={onOpenModelSettings}
              languageSlot={transcripts.length > 0 ? languageSlot : undefined}
            />
          </div>
          {/* Empty state message */}
          <EmptyStateSummary
            onGenerate={() => onGenerateSummary(customPrompt)}
            hasModel={modelConfig.provider !== null && modelConfig.model !== null}
            isGenerating={isSummaryLoading}
          />
        </div>
      ) : transcripts?.length > 0 && (
        <div className="flex-1 overflow-y-auto min-h-0">
          {summaryResponse && (
            <div className="mb-6 border border-border bg-secondary/40 p-4">
              <h3 className="text-lg font-semibold mb-2">Meeting Summary</h3>
              <div className="grid gap-4 md:grid-cols-2">
                <div className="rounded-md border border-border bg-secondary p-4">
                  <h4 className="font-medium mb-1">Key Points</h4>
                  <ul className="list-disc pl-4">
                    {summaryResponse.summary.key_points.blocks.map((block, i) => (
                      <li key={i} className="text-sm">{block.content}</li>
                    ))}
                  </ul>
                </div>
                <div className="mt-4 rounded-md border border-border bg-secondary p-4">
                  <h4 className="font-medium mb-1">Action Items</h4>
                  <ul className="list-disc pl-4">
                    {summaryResponse.summary.action_items.blocks.map((block, i) => (
                      <li key={i} className="text-sm">{block.content}</li>
                    ))}
                  </ul>
                </div>
                <div className="mt-4 rounded-md border border-border bg-secondary p-4">
                  <h4 className="font-medium mb-1">Decisions</h4>
                  <ul className="list-disc pl-4">
                    {summaryResponse.summary.decisions.blocks.map((block, i) => (
                      <li key={i} className="text-sm">{block.content}</li>
                    ))}
                  </ul>
                </div>
                <div className="mt-4 rounded-md border border-border bg-secondary p-4">
                  <h4 className="font-medium mb-1">Main Topics</h4>
                  <ul className="list-disc pl-4">
                    {summaryResponse.summary.main_topics.blocks.map((block, i) => (
                      <li key={i} className="text-sm">{block.content}</li>
                    ))}
                  </ul>
                </div>
              </div>
              {summaryResponse.raw_summary ? (
                <div className="mt-4">
                  <h4 className="font-medium mb-1">Full Summary</h4>
                  <p className="text-sm whitespace-pre-wrap">{summaryResponse.raw_summary}</p>
                </div>
              ) : null}
            </div>
          )}
          <SummaryMoments summaryData={aiSummary} />
          <div className="w-full p-6 sm:p-8">
            <Suspense fallback={<SummarySkeleton className="p-0" />}>
              <BlockNoteSummaryView
                ref={summaryRef}
                summaryData={aiSummary}
                onSave={onSaveSummary}
                onSummaryChange={onSummaryChange}
                onDirtyChange={onDirtyChange}
                status={summaryStatus}
                error={summaryError}
                onRegenerateSummary={() => {
                  Analytics.trackButtonClick('regenerate_summary', 'meeting_details');
                  onRegenerateSummary();
                }}
                meeting={{
                  id: meeting.id,
                  title: meetingTitle,
                  created_at: meeting.created_at
                }}
              />
            </Suspense>
          </div>
          {summaryStatus !== 'idle' && (
            <div className={`mx-6 mb-6 rounded-md border p-4 text-sm sm:mx-8 ${summaryStatus === 'error' ? 'border-destructive/25 bg-destructive/5 text-destructive' :
              summaryStatus === 'completed' ? 'border-[hsl(var(--success)/0.25)] bg-[hsl(var(--success)/0.08)] text-[hsl(var(--success))]' :
                'border-accent/25 bg-[hsl(var(--accent-soft))] text-foreground'
              }`}>
              <p className="font-medium">{getSummaryStatusMessage(summaryStatus)}</p>
            </div>
          )}
        </div>
      )}
    </section>
  );
}

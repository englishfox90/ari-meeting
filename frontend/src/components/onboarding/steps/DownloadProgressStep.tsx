import React, { useEffect, useState, useRef } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { ArrowDownTrayIcon, ArrowPathIcon, CheckIcon, CpuChipIcon, LanguageIcon } from '@heroicons/react/24/outline';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { OnboardingContainer } from '../OnboardingContainer';
import { useOnboarding } from '@/contexts/OnboardingContext';
import { toast } from 'sonner';
import { motion, AnimatePresence } from 'framer-motion';
import { getSummaryModelSizeLabel, getSummaryModelSizeMb } from '@/lib/onboarding-summary-model';
import { isNativeQaMode } from '@/lib/native-qa-mode';
import { MODEL_TIERS } from '@/lib/model-tiers';
import { ensureSpeechAssets } from '@/services/appleService';

const PARAKEET_MODEL = 'parakeet-tdt-0.6b-v3-int8';
const WHISPER_MODEL = 'large-v3-turbo';

type DownloadStatus = 'waiting' | 'downloading' | 'completed' | 'error';

interface DownloadState {
  status: DownloadStatus;
  progress: number;
  downloadedMb: number;
  totalMb: number;
  speedMbps: number;
  error?: string;
}

export function DownloadProgressStep() {
  const {
    goNext,
    selectedTier,
    appleAssetsInstalled,
    selectedSummaryModel,
    setSelectedSummaryModel,
    parakeetDownloaded,
    setParakeetDownloaded,
    summaryModelDownloaded,
    setSummaryModelDownloaded,
    startBackgroundDownloads,
    completeOnboarding,
  } = useOnboarding();

  const tier = MODEL_TIERS[selectedTier];

  const [isMac, setIsMac] = useState(false);

  const [parakeetState, setParakeetState] = useState<DownloadState>({
    status: parakeetDownloaded ? 'completed' : 'waiting',
    progress: parakeetDownloaded ? 100 : 0,
    downloadedMb: 0,
    totalMb: 670,
    speedMbps: 0,
  });

  const [summaryState, setSummaryState] = useState<DownloadState>({
    status: summaryModelDownloaded ? 'completed' : 'waiting',
    progress: summaryModelDownloaded ? 100 : 0,
    downloadedMb: 0,
    totalMb: 0,
    speedMbps: 0,
  });

  const [whisperState, setWhisperState] = useState<DownloadState>({
    status: 'waiting',
    progress: 0,
    downloadedMb: 0,
    totalMb: 0,
    speedMbps: 0,
  });
  const [whisperDownloaded, setWhisperDownloaded] = useState(false);

  // Apple on-device speech assets (Express tier only).
  const [speechAssetsReady, setSpeechAssetsReady] = useState(false);
  const [speechAssetFraction, setSpeechAssetFraction] = useState(0);
  const [speechAssetError, setSpeechAssetError] = useState<string | null>(null);

  const [isCompleting, setIsCompleting] = useState(false);
  const parakeetDownloadStartedRef = useRef(false);
  const summaryDownloadStartedRef = useRef(false);
  const whisperDownloadStartedRef = useRef(false);
  const appleAssetsStartedRef = useRef(false);
  const retryingRef = useRef(false);
  const retryingSummaryRef = useRef(false);
  const retryingWhisperRef = useRef(false);

  // Readiness derived from the selected tier's providers.
  const transcriptionReady =
    tier.transcription.provider === 'apple'
      ? speechAssetsReady
      : tier.transcription.provider === 'localWhisper'
        ? whisperDownloaded
        : parakeetDownloaded;

  const summaryReady =
    tier.summary.provider === 'apple-foundation' ? true : summaryModelDownloaded;

  // Retry Parakeet download handler
  const handleRetryDownload = async () => {
    if (retryingRef.current) {
      console.log('[DownloadProgressStep] Retry already in progress, ignoring');
      return;
    }

    console.log('[DownloadProgressStep] Retrying Parakeet download');
    retryingRef.current = true;

    setParakeetState((prev) => ({
      ...prev,
      status: 'waiting',
      error: undefined,
      progress: 0,
      downloadedMb: 0,
      speedMbps: 0,
    }));

    try {
      await invoke('parakeet_retry_download', { modelName: PARAKEET_MODEL });
    } catch (error) {
      console.error('[DownloadProgressStep] Retry failed:', error);
      setParakeetState((prev) => ({
        ...prev,
        status: 'error',
        error: error instanceof Error ? error.message : 'Retry failed',
      }));

      toast.error('Download retry failed', {
        description: 'Please check your connection and try again.',
      });
    } finally {
      setTimeout(() => {
        retryingRef.current = false;
      }, 2000);
    }
  };

  // Retry Whisper download handler
  const handleRetryWhisperDownload = async () => {
    if (retryingWhisperRef.current) {
      console.log('[DownloadProgressStep] Whisper retry already in progress, ignoring');
      return;
    }

    console.log('[DownloadProgressStep] Retrying Whisper download');
    retryingWhisperRef.current = true;

    setWhisperState((prev) => ({
      ...prev,
      status: 'downloading',
      error: undefined,
      progress: 0,
    }));

    try {
      await invoke('whisper_init');
      await invoke('whisper_download_model', { modelName: WHISPER_MODEL });
    } catch (error) {
      console.error('[DownloadProgressStep] Whisper retry failed:', error);
      setWhisperState((prev) => ({
        ...prev,
        status: 'error',
        error: error instanceof Error ? error.message : 'Retry failed',
      }));

      toast.error('Download retry failed', {
        description: 'Please check your connection and try again.',
      });
    } finally {
      setTimeout(() => {
        retryingWhisperRef.current = false;
      }, 2000);
    }
  };

  // Retry summary download handler
  const handleRetrySummaryDownload = async () => {
    if (retryingSummaryRef.current) {
      console.log('[DownloadProgressStep] Summary retry already in progress, ignoring');
      return;
    }

    console.log('[DownloadProgressStep] Retrying summary model download');
    retryingSummaryRef.current = true;

    const modelName = tier.summary.model;
    setSummaryState((prev) => ({
      ...prev,
      status: 'downloading',
      error: undefined,
      progress: 0,
      downloadedMb: 0,
      totalMb: getSummaryModelSizeMb(modelName),
      speedMbps: 0,
    }));

    try {
      await invoke('builtin_ai_download_model', { modelName });
    } catch (error) {
      console.error('[DownloadProgressStep] Summary retry failed:', error);
      setSummaryState((prev) => ({
        ...prev,
        status: 'error',
        error: error instanceof Error ? error.message : 'Retry failed',
      }));

      toast.error('Summary model download retry failed', {
        description: 'Please check your connection and try again.',
      });
    } finally {
      setTimeout(() => {
        retryingSummaryRef.current = false;
      }, 2000);
    }
  };

  // Detect platform on mount
  useEffect(() => {
    const checkPlatform = async () => {
      try {
        const { platform } = await import('@tauri-apps/plugin-os');
        setIsMac(platform() === 'macos');
      } catch (e) {
        setIsMac(navigator.userAgent.includes('Mac'));
      }
    };

    checkPlatform();
  }, []);

  // Keep the builtin-ai summary download target in sync with the selected tier.
  useEffect(() => {
    if (tier.summary.provider === 'builtin-ai' && selectedSummaryModel !== tier.summary.model) {
      setSelectedSummaryModel(tier.summary.model);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTier]);

  // Parakeet transcription download (Balanced tier).
  useEffect(() => {
    if (isNativeQaMode) return;
    if (tier.transcription.provider !== 'parakeet') return;
    if (parakeetDownloadStartedRef.current) return;
    parakeetDownloadStartedRef.current = true;

    if (!parakeetDownloaded) {
      setParakeetState((prev) => ({ ...prev, status: 'downloading' }));
    }

    startBackgroundDownloads({
      includeParakeet: true,
      includeSummary: false,
    }).catch((error) => {
      console.error('Failed to start Parakeet download:', error);
      if (!parakeetDownloaded) {
        setParakeetState((prev) => ({ ...prev, status: 'error', error: String(error) }));
      }
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTier]);

  // Whisper transcription download (Demanding tier).
  useEffect(() => {
    if (isNativeQaMode) return;
    if (tier.transcription.provider !== 'localWhisper') return;
    if (whisperDownloadStartedRef.current) return;
    whisperDownloadStartedRef.current = true;

    startWhisperDownload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTier]);

  // Apple on-device speech assets (Express tier).
  useEffect(() => {
    if (isNativeQaMode) return;
    if (tier.transcription.provider !== 'apple') return;
    if (appleAssetsStartedRef.current) return;
    appleAssetsStartedRef.current = true;

    if (appleAssetsInstalled) {
      setSpeechAssetsReady(true);
      return;
    }

    ensureSpeechAssets((fraction) => setSpeechAssetFraction(fraction))
      .then((installed) => {
        setSpeechAssetsReady(installed);
        if (!installed) {
          setSpeechAssetError('Speech assets did not finish installing.');
        }
      })
      .catch((error) => {
        console.error('[DownloadProgressStep] Speech asset install failed:', error);
        setSpeechAssetError(error instanceof Error ? error.message : String(error));
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTier, appleAssetsInstalled]);

  // Summary model download for builtin-ai tiers.
  useEffect(() => {
    if (isNativeQaMode) return;
    if (tier.summary.provider !== 'builtin-ai') return;
    if (summaryDownloadStartedRef.current) return;
    if (!selectedSummaryModel || selectedSummaryModel !== tier.summary.model) return;
    summaryDownloadStartedRef.current = true;

    startSummaryDownload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedSummaryModel, selectedTier]);

  // Listen to Parakeet download progress
  useEffect(() => {
    const unlistenProgress = listen<{
      modelName: string;
      progress: number;
      downloaded_mb?: number;
      total_mb?: number;
      speed_mbps?: number;
      status?: string;
    }>('parakeet-model-download-progress', (event) => {
      const { modelName, progress, downloaded_mb, total_mb, speed_mbps, status } = event.payload;
      if (modelName === PARAKEET_MODEL) {
        setParakeetState((prev) => ({
          ...prev,
          status: status === 'completed' ? 'completed' : 'downloading',
          progress,
          downloadedMb: downloaded_mb ?? prev.downloadedMb,
          totalMb: total_mb ?? prev.totalMb,
          speedMbps: speed_mbps ?? prev.speedMbps,
        }));

        if (status === 'completed' || progress >= 100) {
          setParakeetDownloaded(true);
        }
      }
    });

    const unlistenComplete = listen<{ modelName: string }>(
      'parakeet-model-download-complete',
      (event) => {
        if (event.payload.modelName === PARAKEET_MODEL) {
          setParakeetState((prev) => ({ ...prev, status: 'completed', progress: 100 }));
          setParakeetDownloaded(true);
        }
      }
    );

    const unlistenError = listen<{ modelName: string; error: string }>(
      'parakeet-model-download-error',
      (event) => {
        if (event.payload.modelName === PARAKEET_MODEL) {
          setParakeetState((prev) => ({
            ...prev,
            status: 'error',
            error: event.payload.error,
          }));
        }
      }
    );

    return () => {
      unlistenProgress.then((fn) => fn());
      unlistenComplete.then((fn) => fn());
      unlistenError.then((fn) => fn());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Listen to Whisper download progress (percent-only events — no size fields).
  useEffect(() => {
    const unlistenProgress = listen<{ modelName: string; progress: number }>(
      'model-download-progress',
      (event) => {
        if (event.payload.modelName === WHISPER_MODEL) {
          const progress = event.payload.progress;
          setWhisperState((prev) => ({
            ...prev,
            status: progress >= 100 ? 'completed' : 'downloading',
            progress,
          }));
          if (progress >= 100) {
            setWhisperDownloaded(true);
          }
        }
      }
    );

    const unlistenComplete = listen<{ modelName: string }>(
      'model-download-complete',
      (event) => {
        if (event.payload.modelName === WHISPER_MODEL) {
          setWhisperState((prev) => ({ ...prev, status: 'completed', progress: 100 }));
          setWhisperDownloaded(true);
        }
      }
    );

    const unlistenError = listen<{ modelName: string; error: string }>(
      'model-download-error',
      (event) => {
        if (event.payload.modelName === WHISPER_MODEL) {
          setWhisperState((prev) => ({
            ...prev,
            status: 'error',
            error: event.payload.error,
          }));
        }
      }
    );

    return () => {
      unlistenProgress.then((fn) => fn());
      unlistenComplete.then((fn) => fn());
      unlistenError.then((fn) => fn());
    };
  }, []);

  // Listen to Summary Model download progress (builtin-ai tiers).
  useEffect(() => {
    const unlisten = listen<{
      model: string;
      progress: number;
      downloaded_mb?: number;
      total_mb?: number;
      speed_mbps?: number;
      status: string;
      error?: string;
    }>('builtin-ai-download-progress', (event) => {
      const { model, progress, downloaded_mb, total_mb, speed_mbps, status, error } = event.payload;
      if (model === tier.summary.model) {
        setSummaryState((prev) => ({
          ...prev,
          status: status === 'completed'
            ? 'completed'
            : status === 'error'
            ? 'error'
            : 'downloading',
          progress,
          downloadedMb: downloaded_mb ?? prev.downloadedMb,
          totalMb: (total_mb ?? prev.totalMb) || getSummaryModelSizeMb(model),
          speedMbps: speed_mbps ?? prev.speedMbps,
          error: status === 'error' ? error : undefined,
        }));

        if (status === 'completed' || progress >= 100) {
          setSummaryModelDownloaded(true);
        }
      }
    });

    return () => {
      unlisten.then((fn) => fn());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTier]);

  // Reflect a known-complete summary state when the tier's model is already on disk.
  useEffect(() => {
    if (tier.summary.provider !== 'builtin-ai') return;

    setSummaryState((prev) => ({
      ...prev,
      status: summaryModelDownloaded ? 'completed' : prev.status,
      progress: summaryModelDownloaded ? 100 : prev.progress,
      totalMb: prev.totalMb || getSummaryModelSizeMb(tier.summary.model),
    }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTier, summaryModelDownloaded]);

  const startWhisperDownload = async () => {
    try {
      await invoke('whisper_init');
      // Fast-path: skip the download if the model is already available on disk.
      const models = await invoke<Array<{ name: string; status: unknown }>>('whisper_get_available_models');
      const existing = models.find((m) => m.name === WHISPER_MODEL);
      if (existing && existing.status === 'Available') {
        setWhisperState((prev) => ({ ...prev, status: 'completed', progress: 100 }));
        setWhisperDownloaded(true);
        return;
      }
    } catch (error) {
      console.warn('[DownloadProgressStep] Whisper availability check failed:', error);
    }

    setWhisperState((prev) => ({ ...prev, status: 'downloading' }));
    try {
      await invoke('whisper_download_model', { modelName: WHISPER_MODEL });
    } catch (error) {
      console.error('[DownloadProgressStep] Whisper download failed:', error);
      setWhisperState((prev) => ({
        ...prev,
        status: 'error',
        error: error instanceof Error ? error.message : String(error),
      }));
    }
  };

  const startSummaryDownload = async () => {
    const modelName = tier.summary.model;
    if (!summaryModelDownloaded && modelName) {
      try {
        setSummaryState((prev) => ({
          ...prev,
          status: 'downloading',
          totalMb: getSummaryModelSizeMb(modelName),
        }));
        await startBackgroundDownloads({
          includeParakeet: false,
          includeSummary: true,
          summaryModel: modelName,
        });
      } catch (error) {
        console.error('Failed to start summary model download:', error);
        setSummaryState((prev) => ({ ...prev, status: 'error', error: String(error) }));
      }
    }
  };

  const handleContinue = async () => {
    // Verify transcription availability to catch state drift (Parakeet path).
    if (tier.transcription.provider === 'parakeet') {
      try {
        await invoke('parakeet_init');
        const actuallyAvailable = await invoke<boolean>('parakeet_has_available_models');

        if (actuallyAvailable && !parakeetDownloaded) {
          console.log('[DownloadProgressStep] Model available but state not updated');
          setParakeetDownloaded(true);
          setParakeetState((prev) => ({ ...prev, status: 'completed', progress: 100 }));
        } else if (!actuallyAvailable && parakeetState.status === 'error') {
          toast.error('Transcription engine required', {
            description: 'Please retry the download before continuing.',
          });
          return;
        }
      } catch (error) {
        console.warn('[DownloadProgressStep] Failed to verify model:', error);
      }
    }

    const downloadsComplete = transcriptionReady && summaryReady;

    if (!downloadsComplete) {
      toast.info('Downloads will continue in the background', {
        description: 'You can start using the app. Recording will be available once speech recognition is ready.',
        duration: 5000,
      });
    }

    if (isMac) {
      // macOS: Go to Permissions step (onboarding completes after permissions).
      goNext();
    } else {
      // Non-macOS: Complete onboarding immediately (downloads continue in background).
      setIsCompleting(true);
      try {
        await completeOnboarding();
        await new Promise((resolve) => setTimeout(resolve, 100));
        window.location.reload();
      } catch (error) {
        console.error('Failed to complete onboarding:', error);
        toast.error('Failed to complete setup', {
          description: 'Please try again.',
        });
        setIsCompleting(false);
      }
    }
  };

  const renderDownloadCard = (
    title: string,
    icon: React.ReactNode,
    state: DownloadState,
    modelSize: string,
    options: { sizeUnit?: string; percentOnly?: boolean; onRetry?: () => void } = {}
  ) => {
    const { sizeUnit = 'MB', percentOnly = false, onRetry } = options;
    return (
      <div className="py-5">
        <div className="mb-4 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="grid size-9 place-items-center rounded-[9px] border border-border bg-card [&_svg]:size-[18px]">
              {icon}
            </div>
            <div>
              <h3 className="text-[13px] font-medium">{title}</h3>
              <p className="mt-0.5 text-[11px] text-muted-foreground">{modelSize}</p>
            </div>
          </div>
          <div>
            {state.status === 'waiting' && (
              <span className="text-[11px] text-muted-foreground">Waiting</span>
            )}
            {state.status === 'downloading' && (
              <ArrowPathIcon className="size-4 animate-spin text-muted-foreground motion-reduce:animate-none" />
            )}
            {state.status === 'completed' && (
              <div className="grid size-5 place-items-center rounded-full bg-[hsl(var(--success)/0.1)]">
                <CheckIcon className="size-3.5 text-success" />
              </div>
            )}
            {state.status === 'error' && (
              <span className="text-[11px] font-medium text-destructive">Failed</span>
            )}
          </div>
        </div>

        {/* Progress Bar */}
        {(state.status === 'downloading' || state.status === 'completed') && (
          <div className="space-y-2">
            <div className="h-1 w-full overflow-hidden rounded-full bg-secondary" role="progressbar" aria-label={`${title} download progress`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(state.progress)}>
              <div
                className="h-full rounded-full bg-accent transition-[width] duration-300"
                style={{ width: `${state.progress}%` }}
              />
            </div>
            <div className="flex items-center justify-between font-mono text-[10px]">
              {percentOnly ? (
                <span />
              ) : (
                <span className="text-muted-foreground">
                  {state.downloadedMb.toFixed(1)} {sizeUnit} / {state.totalMb.toFixed(1)} {sizeUnit}
                </span>
              )}
              <div className="flex items-center gap-2">
                {!percentOnly && state.speedMbps > 0 && (
                  <span className="text-muted-foreground">
                    {state.speedMbps.toFixed(1)} {sizeUnit}/s
                  </span>
                )}
                <span className="font-medium text-foreground">
                  {Math.round(state.progress)}%
                </span>
              </div>
            </div>
          </div>
        )}

        {state.status === 'error' && state.error && (
          <div className="mt-3 border-l-2 border-destructive pl-3">
            <p className="text-[12px] font-medium text-destructive">Download couldn&apos;t finish</p>
            <p className="mt-1 text-[11px] leading-5 text-muted-foreground">{state.error}</p>
            {onRetry && (
              <button
                onClick={onRetry}
                className="mt-3 inline-flex h-8 items-center justify-center gap-2 rounded-md border border-input bg-card px-3 text-xs font-medium text-foreground transition-colors hover:bg-secondary"
              >
                <ArrowPathIcon className="size-4" />
                Try Again
              </button>
            )}
          </div>
        )}
      </div>
    );
  };

  // No-download ready card (Apple on-device models).
  const renderReadyCard = (title: string, subtitle: string, icon: React.ReactNode) => (
    <div className="py-5">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="grid size-9 place-items-center rounded-[9px] border border-border bg-card [&_svg]:size-[18px]">
            {icon}
          </div>
          <div>
            <h3 className="text-[13px] font-medium">{title}</h3>
            <p className="mt-0.5 text-[11px] text-muted-foreground">{subtitle}</p>
          </div>
        </div>
        <div className="grid size-5 place-items-center rounded-full bg-[hsl(var(--success)/0.1)]">
          <CheckIcon className="size-3.5 text-success" />
        </div>
      </div>
    </div>
  );

  // Apple speech assets installing card (Express, assets not yet on device).
  const renderSpeechAssetsCard = () => (
    <div className="py-5">
      <div className="mb-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="grid size-9 place-items-center rounded-[9px] border border-border bg-card [&_svg]:size-[18px]">
            <LanguageIcon className="text-muted-foreground" />
          </div>
          <div>
            <h3 className="text-[13px] font-medium">{tier.transcription.label}</h3>
            <p className="mt-0.5 text-[11px] text-muted-foreground">Installing on-device speech assets</p>
          </div>
        </div>
        <div>
          {speechAssetError ? (
            <span className="text-[11px] font-medium text-destructive">Failed</span>
          ) : (
            <ArrowPathIcon className="size-4 animate-spin text-muted-foreground motion-reduce:animate-none" />
          )}
        </div>
      </div>

      {!speechAssetError && (
        <div className="space-y-2">
          <Progress value={Math.round(speechAssetFraction * 100)} className="h-1" />
          <div className="flex items-center justify-end font-mono text-[10px]">
            <span className="font-medium text-foreground">{Math.round(speechAssetFraction * 100)}%</span>
          </div>
        </div>
      )}

      {speechAssetError && (
        <div className="mt-3 border-l-2 border-destructive pl-3">
          <p className="text-[12px] font-medium text-destructive">Download couldn&apos;t finish</p>
          <p className="mt-1 text-[11px] leading-5 text-muted-foreground">{speechAssetError}</p>
        </div>
      )}
    </div>
  );

  const renderTranscriptionCard = () => {
    if (tier.transcription.provider === 'apple') {
      return speechAssetsReady
        ? renderReadyCard(
            tier.transcription.label,
            'Apple on-device — no download',
            <LanguageIcon className="text-muted-foreground" />,
          )
        : renderSpeechAssetsCard();
    }

    if (tier.transcription.provider === 'localWhisper') {
      return renderDownloadCard(
        tier.transcription.label,
        <LanguageIcon className="text-muted-foreground" />,
        whisperState,
        '~1.5 GB',
        { percentOnly: true, onRetry: handleRetryWhisperDownload },
      );
    }

    return renderDownloadCard(
      tier.transcription.label,
      <LanguageIcon className="text-muted-foreground" />,
      parakeetState,
      '~670 MB',
      { onRetry: handleRetryDownload },
    );
  };

  const renderSummaryCard = () => {
    if (tier.summary.provider === 'apple-foundation') {
      return renderReadyCard(
        tier.summary.label,
        'Apple on-device — no download',
        <CpuChipIcon className="text-muted-foreground" />,
      );
    }

    return renderDownloadCard(
      tier.summary.label,
      <CpuChipIcon className="text-muted-foreground" />,
      summaryState,
      getSummaryModelSizeLabel(tier.summary.model),
      { sizeUnit: 'MiB', onRetry: handleRetrySummaryDownload },
    );
  };

  const isExpress = tier.transcription.provider === 'apple' && tier.summary.provider === 'apple-foundation';

  return (
    <OnboardingContainer
      title="Getting things ready"
      description={
        isExpress
          ? "Apple's on-device models are used — nothing to download."
          : 'You can start using Ari Meeting once the transcription model is ready.'
      }
      step={3}
      totalSteps={isMac ? 4 : 3}
    >
      <div className="max-w-[680px]">
        {/* Download / ready cards */}
        <div className="divide-y divide-border border-y border-border">
          {renderTranscriptionCard()}
          {renderSummaryCard()}
        </div>

        {/* Express: no-downloads note */}
        {isExpress && speechAssetsReady && (
          <div className="mt-5 border-l-2 border-border pl-3 text-foreground">
            <div className="flex items-start gap-3">
              <CheckIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
              <div>
                <p className="text-[12px] font-medium">No downloads needed</p>
                <p className="mt-1 text-[11px] text-muted-foreground">
                  Apple&apos;s on-device models are ready to use.
                </p>
              </div>
            </div>
          </div>
        )}

        {/* Background-download note for local-model tiers */}
        <AnimatePresence>
          {!isExpress && transcriptionReady && !summaryReady && (
            <motion.div
              initial={{ opacity: 0, y: -10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              transition={{ duration: 0.3, ease: 'easeOut' }}
              className="mt-5 border-l-2 border-border pl-3 text-foreground"
            >
              <div className="flex items-start gap-3">
                <ArrowDownTrayIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                <div>
                  <p className="text-[12px] font-medium">You can continue while this finishes</p>
                  <p className="mt-1 text-[11px] text-muted-foreground">
                    Download will continue in the background.
                  </p>
                </div>
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Continue Button */}
        <div className="mt-8">
          <Button
            onClick={handleContinue}
            disabled={!transcriptionReady || isCompleting}
            className="h-9 min-w-[116px] disabled:cursor-not-allowed"
          >
            {(isCompleting || !transcriptionReady) ? (
              <ArrowPathIcon className="size-4 animate-spin motion-reduce:animate-none" />
            ) : (
              'Continue'
            )}
          </Button>
        </div>
      </div>
    </OnboardingContainer>
  );
}

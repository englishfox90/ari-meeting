'use client';

import { useEffect, useState } from 'react';
import { CheckCircleIcon, XCircleIcon, ArrowPathIcon } from '@heroicons/react/24/outline';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import {
  probeApple,
  ensureSpeechAssets,
  isTauriAvailable,
  type AppleProbeStatus,
} from '@/services/appleService';

/**
 * Honest, read-only availability panel for Apple's on-device intelligence
 * (Phase 1). Runs the `apple_probe` command and reports which capabilities are
 * usable on this Mac — nothing is faked (No-Fake-State): capability rows reflect
 * real framework queries, and every unavailable path shows a truthful reason.
 *
 * This is the foundation the later phases build on: the summary (FoundationModels)
 * and transcription (Speech) provider options are only offered when the matching
 * capability here reports available.
 */
export function AppleModelStatus() {
  const [available] = useState(() => isTauriAvailable());
  const [status, setStatus] = useState<AppleProbeStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [installing, setInstalling] = useState(false);
  const [installProgress, setInstallProgress] = useState(0);
  const [installError, setInstallError] = useState<string | null>(null);

  useEffect(() => {
    if (!available) return;
    let cancelled = false;
    setLoading(true);
    probeApple()
      .then((next) => {
        if (!cancelled) setStatus(next);
      })
      .catch((err) => {
        // The command is designed not to throw, but stay honest if it ever does.
        if (!cancelled) {
          setStatus({
            speechAvailable: false,
            foundationAvailable: false,
            osOk: false,
            appleIntelligence: false,
            speechAssetsInstalled: false,
            error: err instanceof Error ? err.message : 'The on-device availability check failed.',
          });
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [available]);

  const handleInstallSpeech = async () => {
    setInstalling(true);
    setInstallProgress(0);
    setInstallError(null);
    try {
      const installed = await ensureSpeechAssets((fraction) => setInstallProgress(fraction));
      if (installed) {
        // Re-probe so the Transcription row flips to "Ready" from a real query.
        setStatus(await probeApple());
      } else {
        setInstallError('Speech models did not finish installing. Please try again.');
      }
    } catch (err) {
      setInstallError(err instanceof Error ? err.message : 'Installing speech models failed.');
    } finally {
      setInstalling(false);
    }
  };

  return (
    <section aria-labelledby="apple-heading" className="settings-card">
      <p className="app-eyebrow mb-2">On-device intelligence</p>
      <h3 id="apple-heading" className="text-lg font-semibold tracking-[-0.03em]">Apple on-device models</h3>
      <p className="mt-1 text-sm text-muted-foreground">
        Transcription (Speech) and summaries (FoundationModels) that run entirely on this Mac using
        Apple Intelligence — no cloud, no API key, no downloaded model files.
      </p>

      {!available ? (
        <p className="mt-3 text-sm text-muted-foreground">
          Apple on-device models are only available in the desktop app.
        </p>
      ) : loading || status === null ? (
        <p className="mt-4 flex items-center gap-2 text-sm text-muted-foreground">
          <ArrowPathIcon className="size-4 animate-spin" aria-hidden />
          Checking availability on this Mac…
        </p>
      ) : (
        <div className="mt-4 space-y-3">
          <CapabilityRow
            label="Summaries — FoundationModels"
            ok={status.foundationAvailable}
            okNote="Ready to summarize meetings on-device."
            failNote={appleUnavailableReason(status)}
          />
          <CapabilityRow
            label="Transcription — Speech"
            ok={status.speechAvailable}
            okNote={
              status.speechAssetsInstalled
                ? 'Ready to transcribe on-device.'
                : 'Available — speech models are not installed yet.'
            }
            failNote={appleUnavailableReason(status)}
          />

          {status.speechAvailable && !status.speechAssetsInstalled && (
            <div className="rounded-[10px] border bg-muted/30 p-3">
              {installing ? (
                <div className="space-y-2">
                  <p className="flex items-center gap-2 text-sm text-muted-foreground">
                    <ArrowPathIcon className="size-4 animate-spin" aria-hidden />
                    Installing speech models… {Math.round(installProgress * 100)}%
                  </p>
                  <Progress value={Math.round(installProgress * 100)} aria-label="Speech model download progress" />
                </div>
              ) : (
                <div className="space-y-2">
                  <p className="text-sm text-muted-foreground">
                    On-device transcription needs a one-time speech-model download for your language.
                  </p>
                  {installError && (
                    <p role="alert" className="text-sm text-destructive">{installError}</p>
                  )}
                  <Button variant="outline" size="sm" onClick={handleInstallSpeech}>
                    {installError ? 'Retry install' : 'Install speech models'}
                  </Button>
                </div>
              )}
            </div>
          )}

          {status.error && (
            <p className="text-xs text-muted-foreground">{status.error}</p>
          )}
          {status.foundationAvailable && (
            <p className="pt-1 text-xs text-muted-foreground">
              These are compact on-device models. They’re fast and fully private, but produce shorter,
              less detailed results than cloud models and may not follow complex formatting reliably —
              best for quick, offline use.
            </p>
          )}
        </div>
      )}
    </section>
  );
}

/** A single honest capability row: a real available/unavailable state + note. */
function CapabilityRow({
  label,
  ok,
  okNote,
  failNote,
}: {
  label: string;
  ok: boolean;
  okNote: string;
  failNote: string;
}) {
  const Icon = ok ? CheckCircleIcon : XCircleIcon;
  return (
    <div className="flex items-start gap-3">
      <Icon
        className={cn('mt-0.5 size-5 shrink-0', ok ? 'text-foreground' : 'text-muted-foreground')}
        aria-hidden
      />
      <div>
        <p className="text-sm font-medium text-foreground">{label}</p>
        <p className="text-sm text-muted-foreground">{ok ? okNote : failNote}</p>
      </div>
    </div>
  );
}

/**
 * A truthful, human-readable reason the on-device stack is unavailable, derived
 * from the probe booleans (No-Fake-State — never a generic "unavailable").
 */
function appleUnavailableReason(status: AppleProbeStatus): string {
  if (!status.osOk) return 'Requires macOS 26 or newer.';
  if (!status.appleIntelligence) return 'Turn on Apple Intelligence in System Settings to enable this.';
  if (status.error) return status.error;
  return 'Not available on this Mac.';
}

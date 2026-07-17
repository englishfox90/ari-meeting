/**
 * Apple on-device intelligence service.
 *
 * Thin 1-to-1 wrapper over the `apple_probe` Tauri command (Phase 1). Reports
 * which parts of Apple's on-device stack — Speech (SpeechAnalyzer) for
 * transcription and FoundationModels for summaries — are actually usable on this
 * machine. Every field is a real runtime query from the `apple-helper` sidecar;
 * nothing here is faked (No-Fake-State).
 */

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

/**
 * Availability snapshot, mirroring the Rust `helper::ProbeStatus` struct
 * (camelCase over the wire). `error` is populated only when the stack is
 * unavailable (sidecar missing, spawn/timeout failure, or an error reply).
 */
export interface AppleProbeStatus {
  speechAvailable: boolean;
  foundationAvailable: boolean;
  osOk: boolean;
  appleIntelligence: boolean;
  speechAssetsInstalled: boolean;
  error?: string | null;
}

/**
 * Plain-browser (`pnpm run dev`) has no Tauri runtime; every `invoke` would
 * throw. Mirror the guard used in `calendarService` / `NotchSettings`.
 */
export function isTauriAvailable(): boolean {
  return (
    typeof window !== 'undefined' &&
    Boolean((window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__)
  );
}

/**
 * Probe Apple on-device availability. Always resolves to an honest status — the
 * command returns an all-false status with a populated `error` rather than
 * throwing when the stack is unavailable.
 */
export async function probeApple(): Promise<AppleProbeStatus> {
  return invoke<AppleProbeStatus>('apple_probe');
}

/**
 * Download + install the on-device Speech model assets, reporting REAL progress.
 *
 * The `apple_ensure_assets` command streams `apple-assets-progress` events
 * (`{ fraction: 0..1 }`) as the download advances, then resolves to whether the
 * assets are installed. `onProgress` receives only real fractions from the
 * sidecar (No-Fake-State — never a simulated bar). The event listener is torn
 * down when the install settles.
 */
export async function ensureSpeechAssets(
  onProgress: (fraction: number) => void,
): Promise<boolean> {
  const unlisten = await listen<{ fraction: number }>('apple-assets-progress', (event) => {
    onProgress(event.payload.fraction);
  });
  try {
    return await invoke<boolean>('apple_ensure_assets', { which: 'speech' });
  } finally {
    unlisten();
  }
}

'use client';

import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Switch } from './ui/switch';

// Snapshot returned by the `notch_status` command.
interface NotchStatus {
  enabled: boolean;
  connected: boolean;
  hasBinary: boolean;
}

// Plain-browser (`pnpm run dev`) has no Tauri runtime; every `invoke`/store call
// would throw. Mirror the guard used in `calendarService`.
function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean((window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__);
}

/**
 * "Ari Notch" toggle. Persists the boolean to the `settings.json` store under
 * `showNotch` — the exact file + key the Rust bridge reads at startup
 * (`notch/bridge.rs` `read_show_notch_pref`) — then drives the live bridge via
 * `notch_enable` / `notch_disable`. Reads `notch_status` so the current state
 * (and honest "helper unavailable" case) is real, not faked.
 */
export function NotchSettings() {
  const [available] = useState(() => isTauriAvailable());
  const [showNotch, setShowNotch] = useState<boolean | null>(null);
  const [status, setStatus] = useState<NotchStatus | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!available) return;

    const load = async () => {
      try {
        const { Store } = await import('@tauri-apps/plugin-store');
        const store = await Store.load('settings.json');
        const persisted = (await store.get<boolean>('showNotch')) ?? false;
        setShowNotch(persisted);
      } catch (err) {
        console.error('Failed to load notch preference:', err);
        setShowNotch(false);
      }

      try {
        const next = await invoke<NotchStatus>('notch_status');
        setStatus(next);
      } catch (err) {
        console.error('Failed to read notch status:', err);
      }
    };

    load();
  }, [available]);

  const handleToggle = async (enabled: boolean) => {
    const previous = showNotch;
    setShowNotch(enabled);
    setError(null);

    try {
      const { Store } = await import('@tauri-apps/plugin-store');
      const store = await Store.load('settings.json');
      await store.set('showNotch', enabled);
      await store.save();

      await invoke(enabled ? 'notch_enable' : 'notch_disable');

      const next = await invoke<NotchStatus>('notch_status');
      setStatus(next);
    } catch (err) {
      console.error('Failed to update notch preference:', err);
      setShowNotch(previous);
      setError('Ari Meeting could not update the meeting notch. Try again.');
    }
  };

  // Honest unavailable states (No-Fake-State): outside the desktop app, or when
  // the notch helper binary isn't present the toggle can't do anything.
  const hasBinary = status?.hasBinary ?? true;
  const unavailableNote = !available
    ? 'The meeting notch is only available in the desktop app.'
    : status && !hasBinary
      ? 'The notch helper isn’t installed on this Mac yet, so it can’t be turned on.'
      : null;

  const switchDisabled = !available || showNotch === null || !hasBinary;

  return (
    <section aria-labelledby="notch-heading" className="settings-card">
      <div className="flex items-center justify-between gap-6">
        <div>
          <p className="app-eyebrow mb-2">Desktop</p>
          <h3 id="notch-heading" className="text-lg font-semibold tracking-[-0.03em]">Show meeting notch</h3>
          <p id="notch-description" className="mt-1 text-sm text-muted-foreground">
            Display upcoming meetings and recording status in a small panel below the notch at the top of your screen.
          </p>
        </div>
        <Switch
          aria-label="Show meeting notch"
          aria-describedby="notch-description"
          checked={showNotch ?? false}
          disabled={switchDisabled}
          onCheckedChange={handleToggle}
        />
      </div>
      {unavailableNote && <p className="mt-3 text-sm text-muted-foreground">{unavailableNote}</p>}
      {error && <p role="alert" className="mt-3 text-sm text-destructive">{error}</p>}
    </section>
  );
}

/**
 * Voiceprint Identicon Service (F1 visual mark)
 *
 * Wraps the Rust `speaker_voiceprint_signatures` command. A signature is the
 * REAL CAM++ voiceprint centroid, down-sampled server-side to a small array of
 * values in [0, 1] — the input to the deterministic "voice ring" identicon.
 *
 * Speaker ids are globally-unique UUIDs, so signatures are cached in a single
 * module-level `Map<speakerId, values>`. Warming the cache for a meeting (via
 * `fetchMeetingSignatures`) lets any glyph — even ones deep inside dialogs that
 * never receive a meetingId — resolve its signature by speaker id alone. A tiny
 * subscription lets glyphs re-render when the cache is warmed asynchronously.
 *
 * Guards against running outside the Tauri runtime (plain `pnpm run dev` in a
 * browser has no backend).
 */

import { invoke } from '@tauri-apps/api/core';

function isTauriAvailable(): boolean {
  return typeof window !== 'undefined' && Boolean(window.__TAURI_INTERNALS__);
}

/** One speaker's render-ready voiceprint signature (values normalized to [0,1]). */
export interface VoiceprintSignature {
  speakerId: string;
  values: number[];
}

/** One person's render-ready voiceprint signature (from their canonical speaker). */
export interface PersonVoiceprintSignature {
  personId: string;
  values: number[];
}

// speakerId (UUID) → signature values. Absent = unknown / no usable centroid.
const cache = new Map<string, number[]>();
// personId (UUID) → canonical signature values. Kept separate from `cache`
// because a person and their canonical speaker are distinct ids.
const personCache = new Map<string, number[]>();
// Meetings whose fetch is in-flight or done, so we don't refetch on every render.
const meetingFetches = new Map<string, Promise<void>>();
// Per-person fetches in flight/done, so a re-render doesn't refetch.
const personFetches = new Map<string, Promise<void>>();
// The one-shot "all persons" fetch (People list warm-up).
let allPersonsFetch: Promise<void> | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  for (const listener of listeners) listener();
}

export class VoiceprintService {
  /** Whether the app is running inside the Tauri desktop shell. */
  isAvailable(): boolean {
    return isTauriAvailable();
  }

  /**
   * Fetch and cache every speaker signature for a meeting. Idempotent per
   * meeting (subsequent calls reuse the in-flight/settled promise). Failures are
   * swallowed to a warning — an absent signature honestly degrades to a
   * placeholder, never a fabricated glyph. Call `{ force: true }` after a
   * re-diarization to refresh.
   */
  fetchMeetingSignatures(meetingId: string, opts?: { force?: boolean }): Promise<void> {
    if (!meetingId || !this.isAvailable()) return Promise.resolve();
    if (!opts?.force && meetingFetches.has(meetingId)) {
      return meetingFetches.get(meetingId)!;
    }
    const run = invoke<VoiceprintSignature[]>('speaker_voiceprint_signatures', { meetingId })
      .then((signatures) => {
        for (const sig of signatures) cache.set(sig.speakerId, sig.values);
        notify();
      })
      .catch((reason) => {
        console.error('Failed to load voiceprint signatures:', reason);
        // Leave the meeting un-cached so a later attempt can retry.
        meetingFetches.delete(meetingId);
      });
    meetingFetches.set(meetingId, run);
    return run;
  }

  /** The cached signature for a speaker, or `undefined` if unknown / no centroid. */
  getSignature(speakerId: string): number[] | undefined {
    return cache.get(speakerId);
  }

  /**
   * Fetch and cache ONE person's canonical voiceprint signature. Idempotent per
   * person. A person with no enrolled voiceprint stays un-cached (the glyph then
   * renders nothing — No-Fake-State). Call `{ force: true }` to refresh after an
   * enrollment change.
   */
  fetchPersonSignature(personId: string, opts?: { force?: boolean }): Promise<void> {
    if (!personId || !this.isAvailable()) return Promise.resolve();
    if (!opts?.force && personFetches.has(personId)) {
      return personFetches.get(personId)!;
    }
    const run = invoke<PersonVoiceprintSignature | null>('person_voiceprint_signature', { personId })
      .then((signature) => {
        if (signature) {
          personCache.set(signature.personId, signature.values);
          notify();
        }
      })
      .catch((reason) => {
        console.error('Failed to load person voiceprint signature:', reason);
        personFetches.delete(personId);
      });
    personFetches.set(personId, run);
    return run;
  }

  /**
   * Fetch and cache every enrolled person's canonical signature in one call
   * (People list warm-up). Idempotent; `{ force: true }` refreshes.
   */
  fetchAllPersonSignatures(opts?: { force?: boolean }): Promise<void> {
    if (!this.isAvailable()) return Promise.resolve();
    if (!opts?.force && allPersonsFetch) return allPersonsFetch;
    const run = invoke<PersonVoiceprintSignature[]>('person_voiceprint_signatures')
      .then((signatures) => {
        for (const sig of signatures) personCache.set(sig.personId, sig.values);
        notify();
      })
      .catch((reason) => {
        console.error('Failed to load person voiceprint signatures:', reason);
        allPersonsFetch = null;
      });
    allPersonsFetch = run;
    return run;
  }

  /** The cached canonical signature for a person, or `undefined` if none. */
  getPersonSignature(personId: string): number[] | undefined {
    return personCache.get(personId);
  }

  /** Subscribe to cache updates; returns an unsubscribe function. */
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }
}

export const voiceprintService = new VoiceprintService();

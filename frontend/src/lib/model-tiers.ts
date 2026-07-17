/**
 * Onboarding model tiers.
 *
 * The first-run setup offers three bundled STT + summary pairs so a user picks
 * one experience instead of individual models. Everything here is local/private;
 * tiers trade off download size, speed, accuracy, and RAM. All of it can be
 * changed later in Settings (Transcription + Summary model pickers).
 *
 * Model ids/sizes are mirrored from the Rust catalogs:
 *   - Parakeet: parakeet_engine (parakeet-tdt-0.6b-v3-int8, ~670 MB)
 *   - Whisper:  config.rs WHISPER_MODEL_CATALOG (large-v3-turbo, ~1549 MB)
 *   - Built-in summary (GGUF): summary/summary_engine/models.rs (qwen3.5:2b ~1221, qwen3.5:4b ~2614)
 *   - Apple: on-device Speech + FoundationModels (no downloadable model files)
 */

export type ModelTier = 'express' | 'balanced' | 'demanding';

export interface TierComponent {
  /** Provider string persisted to config (e.g. 'apple', 'parakeet', 'localWhisper', 'builtin-ai', 'apple-foundation'). */
  provider: string;
  /** Model id persisted to config (empty for Apple's single system model). */
  model: string;
  /** Short human label, e.g. "Parakeet v3". */
  label: string;
  /** Approximate download size in MB (0 = nothing to download). */
  sizeMb: number;
}

export interface TierDef {
  id: ModelTier;
  name: string;
  /** One-line hook shown under the name. */
  tagline: string;
  /** A short paragraph of honest context. */
  description: string;
  transcription: TierComponent;
  summary: TierComponent;
  /** Only offered when the Apple on-device stack is available (macOS 26 + Apple Intelligence). */
  requiresAppleEligible: boolean;
}

export const MODEL_TIERS: Record<ModelTier, TierDef> = {
  express: {
    id: 'express',
    name: 'Express',
    tagline: 'Fastest start · no downloads',
    description:
      "Uses Apple's built-in on-device models — nothing to download, fully private. Summaries and transcription are fast but more basic. Requires macOS 26 with Apple Intelligence enabled.",
    transcription: { provider: 'apple', model: '', label: 'Apple Speech', sizeMb: 0 },
    summary: { provider: 'apple-foundation', model: 'default', label: 'Apple FoundationModels', sizeMb: 0 },
    requiresAppleEligible: true,
  },
  balanced: {
    id: 'balanced',
    name: 'Balanced',
    tagline: 'Good speed and quality for most Macs',
    description:
      'Parakeet transcription with a compact Qwen summary model — accurate and quick on most Macs, with a modest download.',
    transcription: { provider: 'parakeet', model: 'parakeet-tdt-0.6b-v3-int8', label: 'Parakeet v3', sizeMb: 670 },
    summary: { provider: 'builtin-ai', model: 'qwen3.5:2b', label: 'Qwen 3.5 2B', sizeMb: 1221 },
    requiresAppleEligible: false,
  },
  demanding: {
    id: 'demanding',
    name: 'Demanding',
    tagline: 'Highest quality · needs more RAM',
    description:
      'Whisper Large v3 Turbo transcription with a larger Qwen summary model — best accuracy, but a bigger download and more memory. Recommended for Macs with 16 GB or more.',
    transcription: { provider: 'localWhisper', model: 'large-v3-turbo', label: 'Whisper Large v3 Turbo', sizeMb: 1549 },
    summary: { provider: 'builtin-ai', model: 'qwen3.5:4b', label: 'Qwen 3.5 4B', sizeMb: 2614 },
    requiresAppleEligible: false,
  },
};

export const TIER_ORDER: ModelTier[] = ['express', 'balanced', 'demanding'];

/** Total download for a tier in MB (0 for Express). */
export function tierTotalMb(tier: TierDef): number {
  return tier.transcription.sizeMb + tier.summary.sizeMb;
}

/** Human size label, e.g. "No downloads", "1.9 GB". */
export function formatTierSize(mb: number): string {
  if (mb <= 0) return 'No downloads';
  const gb = mb / 1024;
  return gb >= 1 ? `${gb.toFixed(1)} GB` : `${mb} MB`;
}

/**
 * Recommend a tier from detected RAM and Apple eligibility (No-Fake-State: only
 * recommend Express when Apple is actually available). Thresholds:
 *   - < 12 GB  → Express if Apple-eligible, else Balanced (Demanding is too heavy)
 *   - 12–20 GB → Balanced
 *   - ≥ 20 GB  → Demanding
 */
export function recommendTier(ramGb: number, appleEligible: boolean): ModelTier {
  if (!Number.isFinite(ramGb) || ramGb <= 0) {
    // Unknown RAM: safest broadly-runnable default.
    return appleEligible ? 'express' : 'balanced';
  }
  if (ramGb < 12) return appleEligible ? 'express' : 'balanced';
  if (ramGb < 20) return 'balanced';
  return 'demanding';
}

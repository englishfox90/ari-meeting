'use client';

import { memo, useCallback, useId, useSyncExternalStore } from 'react';
import { cn } from '@/lib/utils';
import { buildVoiceprintRing, voiceprintColors } from '@/lib/voiceprint-glyph';
import { voiceprintService } from '@/services/voiceprintService';
import { useTheme } from '@/contexts/ThemeContext';
import type { EnrollmentState } from '@/services/speakerService';

/**
 * Read a cached voiceprint signature by speaker OR person id, re-rendering when
 * the shared cache is warmed (see `voiceprintService.fetch*Signatures`). Exactly
 * one of the two ids is set; the other resolves from a distinct cache.
 */
function useVoiceprintSignature(source: {
  speakerId?: string;
  personId?: string;
}): number[] | undefined {
  const { speakerId, personId } = source;
  const subscribe = useCallback(
    (onChange: () => void) => voiceprintService.subscribe(onChange),
    [],
  );
  const getSnapshot = useCallback(() => {
    if (personId) return voiceprintService.getPersonSignature(personId);
    if (speakerId) return voiceprintService.getSignature(speakerId);
    return undefined;
  }, [speakerId, personId]);
  // No signatures exist during static prerender (no backend) → undefined.
  return useSyncExternalStore(subscribe, getSnapshot, () => undefined);
}

export interface VoiceprintGlyphProps {
  /** The speaker whose real voiceprint drives the ring (meeting-scoped path). */
  speakerId?: string;
  /**
   * The person whose CANONICAL enrolled voiceprint drives the ring (person
   * drill-down). Provide exactly one of `speakerId` / `personId`.
   */
  personId?: string;
  /** Enrollment lifecycle — provisional voices read lighter / dashed. */
  state?: EnrollmentState;
  /** Rendered edge length in px. Elegant from 16px (chip) to 64px (cards). */
  size?: number;
  /**
   * Amber signal — use ONLY while this speaker's clip is actively playing (the
   * one-thing-that-matters accent). Off by default; the glyph is warm-neutral.
   */
  active?: boolean;
  className?: string;
  /** Accessible label; falls back to a neutral description. */
  title?: string;
}

/**
 * A speaker's "voiceprint identicon": a compact circular ring whose outline is
 * deterministically shaped by their REAL voiceprint centroid (down-sampled
 * server-side). Same voice → same ring; as the voiceprint refines across
 * meetings the ring evolves with it. Cosine-similar voices look similar.
 *
 * Honours No-Fake-State: a speaker with no usable centroid renders a neutral
 * placeholder dot, never an invented shape. Rendered in warm-neutral ink via
 * `currentColor`; amber appears only when `active` (a clip is playing).
 */
export const VoiceprintGlyph = memo(function VoiceprintGlyph({
  speakerId,
  personId,
  state,
  size = 24,
  active = false,
  className,
  title,
}: VoiceprintGlyphProps) {
  const { resolvedTheme } = useTheme();
  const gradientId = useId();
  const values = useVoiceprintSignature({ speakerId, personId });
  const ring = values ? buildVoiceprintRing(values) : null;
  const isProvisional = state === 'provisional';
  const label = title ?? (ring ? 'Voiceprint' : 'No voiceprint yet');

  // Voice-derived color: a stable projection of the SAME signature (never a
  // hash). Amber is reserved for the `active` signal, so a playing clip always
  // overrides the data color with `currentColor` (text-accent).
  const colors = active || !values ? null : voiceprintColors(values, { theme: resolvedTheme });
  const colorClass = active ? 'text-accent' : 'text-muted-foreground';

  // No real signature → honest neutral placeholder dot (never a fake ring).
  if (!ring) {
    return (
      <span
        role="img"
        aria-label={label}
        className={cn('inline-flex flex-shrink-0 items-center justify-center', className)}
        style={{ width: size, height: size }}
      >
        <span
          aria-hidden="true"
          className="rounded-full bg-muted-foreground/40"
          style={{ width: Math.max(3, size * 0.16), height: Math.max(3, size * 0.16) }}
        />
      </span>
    );
  }

  const strokeWidth = size <= 20 ? 1.25 : 1.5;
  // Data color drives stroke + faint fill via a two-stop gradient; when there's
  // no derived color (active/amber signal), fall back to currentColor.
  const paint = colors ? `url(#${gradientId})` : 'currentColor';

  return (
    <svg
      role="img"
      aria-label={label}
      viewBox={`0 0 ${ring.size} ${ring.size}`}
      width={size}
      height={size}
      className={cn('flex-shrink-0', !colors && colorClass, isProvisional && 'opacity-70', className)}
    >
      <title>{label}</title>
      {colors && (
        <linearGradient id={gradientId} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor={colors.from} />
          <stop offset="100%" stopColor={colors.to} />
        </linearGradient>
      )}
      <path
        d={ring.path}
        fill={paint}
        // Provisional voices read lighter (dashed outline, no fill body) so a
        // confirmed identity is visually distinct from an unconfirmed one. They
        // still carry their real derived tint — clearly subordinate to confirmed.
        fillOpacity={isProvisional ? 0 : 0.1}
        stroke={paint}
        strokeWidth={strokeWidth}
        strokeLinejoin="round"
        strokeDasharray={isProvisional ? '2.5 2' : undefined}
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
});

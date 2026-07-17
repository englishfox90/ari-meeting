/**
 * Voiceprint identicon geometry — a pure, dependency-free mapping from a
 * speaker's real voiceprint signature (the backend-downsampled centroid, values
 * in [0, 1]) to a smooth closed "voice ring" SVG path.
 *
 * Deterministic by construction: the same signature always yields the same
 * path, and because the backend mapping is a direct down-sample (never a hash),
 * cosine-similar voices produce visually similar rings. As a voiceprint refines
 * across meetings, its ring evolves smoothly with it.
 *
 * Kept free of any React / DOM / import dependency so it is unit-testable in a
 * plain Node VM (see tests/lib/voiceprint-glyph.test.mjs).
 */

export interface VoiceprintRingOptions {
  /** Square viewport edge length in user units. Default 100 (path is scaled by CSS). */
  size?: number;
  /**
   * Inner/outer radius as a fraction of half the size. The ring breathes
   * between these; a value of 0 sits at `minRadiusRatio`, 1 at `maxRadiusRatio`.
   */
  minRadiusRatio?: number;
  maxRadiusRatio?: number;
  /** Decimal places to round coordinates to (keeps the path string compact). */
  precision?: number;
}

export interface VoiceprintRing {
  /** SVG path `d` for the smooth closed blob. */
  path: string;
  /** The viewBox edge the path is authored against. */
  size: number;
  /** Sampled radial points (center-relative), useful for tests / alt renders. */
  points: Array<{ x: number; y: number }>;
}

const DEFAULTS: Required<VoiceprintRingOptions> = {
  size: 100,
  minRadiusRatio: 0.46,
  maxRadiusRatio: 0.94,
  precision: 2,
};

function round(value: number, precision: number): number {
  const f = 10 ** precision;
  return Math.round(value * f) / f;
}

/**
 * Build a smooth closed ring path from a signature. Values are expected in
 * [0, 1]; anything outside is clamped. Returns `null` when there is nothing
 * honest to draw (empty or single-point signature) so the caller can fall back
 * to a neutral placeholder rather than invent a shape.
 */
export function buildVoiceprintRing(
  values: readonly number[],
  options: VoiceprintRingOptions = {},
): VoiceprintRing | null {
  const opts = { ...DEFAULTS, ...options };
  const n = values.length;
  if (n < 3) return null;

  const half = opts.size / 2;
  const rMin = half * opts.minRadiusRatio;
  const rSpan = half * (opts.maxRadiusRatio - opts.minRadiusRatio);

  // Sample radii around the circle, starting at 12 o'clock and going clockwise.
  const points: Array<{ x: number; y: number }> = new Array(n);
  for (let i = 0; i < n; i += 1) {
    const v = Math.min(1, Math.max(0, values[i]));
    const radius = rMin + v * rSpan;
    const angle = (i / n) * Math.PI * 2 - Math.PI / 2;
    points[i] = {
      x: half + radius * Math.cos(angle),
      y: half + radius * Math.sin(angle),
    };
  }

  // Closed Catmull-Rom spline → cubic beziers for a calm, organic outline.
  const p = opts.precision;
  const at = (i: number) => points[((i % n) + n) % n];
  let d = `M ${round(points[0].x, p)} ${round(points[0].y, p)}`;
  for (let i = 0; i < n; i += 1) {
    const p0 = at(i - 1);
    const p1 = at(i);
    const p2 = at(i + 1);
    const p3 = at(i + 2);
    const c1x = p1.x + (p2.x - p0.x) / 6;
    const c1y = p1.y + (p2.y - p0.y) / 6;
    const c2x = p2.x - (p3.x - p1.x) / 6;
    const c2y = p2.y - (p3.y - p1.y) / 6;
    d +=
      ` C ${round(c1x, p)} ${round(c1y, p)}` +
      ` ${round(c2x, p)} ${round(c2y, p)}` +
      ` ${round(p2.x, p)} ${round(p2.y, p)}`;
  }
  d += ' Z';

  return { path: d, size: opts.size, points };
}

/**
 * A voice-derived stroke color: two HSL stops for a subtle gradient along the
 * ring. Like the shape, the color IS the voice — it is a stable projection of
 * the SAME signature, never a hash of the name/id. Cosine-similar voices
 * therefore land on nearby hues (an honest, emergent property).
 */
export interface VoiceprintColors {
  /** Primary gradient stop — `hsl(...)` string. */
  from: string;
  /** Secondary gradient stop — `hsl(...)` string. */
  to: string;
  /** Primary hue in degrees `[0, 360)` (exposed for tests / debugging). */
  hueFrom: number;
  /** Secondary hue in degrees `[0, 360)`. */
  hueTo: number;
  /** Shared saturation percentage (kept in the calm data band). */
  saturation: number;
  /** Shared lightness percentage (theme-dependent). */
  lightness: number;
}

export interface VoiceprintColorOptions {
  /**
   * Resolved theme. Dark navy canvas wants lighter/softer data tints; the warm
   * cream canvas wants deeper tones. Defaults to `'dark'` (the app default).
   */
  theme?: 'light' | 'dark';
}

/**
 * Derive a deterministic, voice-based color from a signature.
 *
 * ## Method (documented, deterministic)
 * The 32 bucket values are treated as weights on evenly-spaced angles around a
 * circle (bucket `i` → angle `2π·i/n`). The **circular mean** of that weighted
 * vector — `atan2(Σ vᵢ·sin θᵢ, Σ vᵢ·cos θᵢ)` — gives the primary hue in
 * `[0, 360)`. This is a rotation-of-emphasis measure: where a voice's energy
 * concentrates around the ring fixes its hue, so similar voiceprints (similar
 * bucket profiles) yield nearby hues. A second, independent projection over the
 * **odd-indexed buckets only** gives the secondary hue, which drives a tasteful
 * two-stop gradient along the stroke (the "multi-color" feel). Saturation is
 * taken from the concentration (vector magnitude) of the primary projection,
 * clamped into a calm 46–64% band — this is DATA color, never the amber accent.
 * Lightness is chosen per theme (lighter on dark, deeper on cream).
 *
 * Returns `null` for a signature too short to be meaningful (matching
 * `buildVoiceprintRing`), so the caller can fall back to a neutral treatment.
 */
export function voiceprintColors(
  values: readonly number[],
  options: VoiceprintColorOptions = {},
): VoiceprintColors | null {
  const n = values.length;
  if (n < 3) return null;

  const theme = options.theme === 'light' ? 'light' : 'dark';
  const v = values.map((x) => Math.min(1, Math.max(0, x)));

  // Circular mean over a chosen subset of buckets. Returns the mean direction
  // (hue) plus its concentration (magnitude of the resultant, normalized to the
  // weight sum → 0 = evenly spread, 1 = fully peaked).
  const project = (keep: (i: number) => boolean): { hue: number; mag: number } => {
    let sx = 0;
    let sy = 0;
    let sw = 0;
    for (let i = 0; i < n; i += 1) {
      if (!keep(i)) continue;
      const angle = (i / n) * Math.PI * 2;
      sx += v[i] * Math.cos(angle);
      sy += v[i] * Math.sin(angle);
      sw += v[i];
    }
    const hue = ((Math.atan2(sy, sx) * 180) / Math.PI + 360) % 360;
    const mag = sw > 0 ? Math.min(1, Math.hypot(sx, sy) / sw) : 0;
    return { hue, mag };
  };

  const primary = project(() => true);
  const secondary = project((i) => i % 2 === 1);

  // DATA color: moderate saturation from the primary concentration (46–64%).
  const saturation = Math.round(46 + primary.mag * 18);
  // Lighter, calmer tints on dark navy; deeper tones on warm cream.
  const lightness = theme === 'dark' ? 66 : 40;

  const hueFrom = Math.round(primary.hue) % 360;
  const hueTo = Math.round(secondary.hue) % 360;

  return {
    hueFrom,
    hueTo,
    saturation,
    lightness,
    from: `hsl(${hueFrom} ${saturation}% ${lightness}%)`,
    to: `hsl(${hueTo} ${saturation}% ${lightness}%)`,
  };
}

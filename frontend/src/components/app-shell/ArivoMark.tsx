import type { SVGProps } from 'react';

/**
 * The Arivo brand mark — the amber crescent ring that encircles the ARIVO
 * wordmark, isolated as a standalone glyph for the collapsed sidebar rail.
 * Drawn as an open ring (bright amber lower-left, fading to deep amber into
 * the opening at upper-right) so it reads identically on the cream canvas and
 * the navy rail without needing a light/dark asset swap.
 */
export function ArivoMark({ className, ...props }: SVGProps<SVGSVGElement>) {
  return (
    <svg
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      aria-hidden="true"
      {...props}
    >
      <defs>
        <linearGradient id="arivo-mark-ring" x1="4" y1="28" x2="28" y2="4" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#E8A020" />
          <stop offset="0.55" stopColor="#B4741A" />
          <stop offset="1" stopColor="#5A3A12" />
        </linearGradient>
      </defs>
      <circle
        cx="16"
        cy="16"
        r="12.5"
        stroke="url(#arivo-mark-ring)"
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeDasharray="66 20"
      />
    </svg>
  );
}

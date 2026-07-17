import type { SVGProps } from 'react';

/**
 * The Ari Meetings brand mark — Marginalia's R2 "Dictation" gesture: one
 * continuous hand-drawn line, a cursive lowercase "a" whose exit stroke rises
 * into a hand-drawn waveform (the letter is the record; the run-out is the
 * voice still speaking). Ink-only, single color via `currentColor` — tint it
 * with Shin-kai (accent, preferred), heading/body ink, or paper white on dark.
 * Source art: brand/assets/mark-full.svg (full) and mark-16.svg (flick).
 *
 * `variant="flick"` is the signature flick — the terminal wave alone — used
 * below ~32px (collapsed rail, menu-bar scale) where the full gesture would
 * lose its irregular peaks.
 */
export function AriMark({ variant = 'full', ...props }: SVGProps<SVGSVGElement> & { variant?: 'full' | 'flick' }) {
  if (variant === 'flick') {
    return (
      <svg viewBox="0 0 64 64" fill="none" stroke="currentColor" strokeLinecap="round" aria-hidden="true" {...props}>
        <path d="M8 44 C13 46 16 38 19 30 C21 25 24 24 26 27 C29 31 28 42 33 42 C38 42 38 22 44 21 C49 20.5 50 32 56 35" strokeWidth="9" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 96 64" fill="none" stroke="currentColor" strokeLinecap="round" aria-hidden="true" {...props}>
      <path d="M46 26 C37 18 23 23 21 34 C19 46 31 54 41 48" strokeWidth="8" />
      <path d="M46 26 C43.5 23 40 21.4 36.5 21.6" strokeWidth="4.2" />
      <path d="M47 20 C45.3 30 45.3 40 48 47" strokeWidth="8" />
      <path d="M48 47 C50.5 51.5 55 49.5 57 43 C58.6 38 60 34.5 62.5 34.5" strokeWidth="6" />
      <path d="M62.5 34.5 C66 34.5 65.5 45 69.5 45 C73.5 45 73.5 29.5 78 29" strokeWidth="4.4" />
      <path d="M78 29 C81.5 28.7 82 38 86 40 C88.3 41 90.5 40 92.5 37.5" strokeWidth="2.8" />
    </svg>
  );
}

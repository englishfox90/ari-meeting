'use client';

/**
 * AskLauncher — the app-wide floating entry point to the Ask engine. An amber FAB
 * (bottom-right): amber is the one primary call-to-action here, standing out from
 * the navy canvas (the ≤8% Signal-Desk accent — a single small control). It stays
 * visible while the overlay is open and acts as its toggle; the glyph pulses while
 * an answer is in flight. Renders the AskOverlay as its sibling. Mounted only in
 * the real app (never onboarding — see layout).
 */

import { useAsk } from '@/contexts/AskContext';
import { MeetilyGlyph } from '@/components/app-shell/MeetilyGlyph';
import { cn } from '@/lib/utils';
import { AskOverlay } from './AskOverlay';

export function AskLauncher() {
  const { isOpen, toggle, isAsking } = useAsk();

  return (
    <>
      <button
        type="button"
        onClick={toggle}
        aria-label={isOpen ? 'Close Ask' : 'Ask your meetings'}
        aria-expanded={isOpen}
        className={cn(
          'fixed bottom-6 right-6 z-40 grid size-14 place-items-center rounded-full border border-accent bg-accent text-accent-foreground shadow-lg transition-colors hover:bg-accent/90',
        )}
      >
        <MeetilyGlyph name="ai" className={cn('size-6', isAsking && 'animate-pulse')} />
      </button>
      <AskOverlay />
    </>
  );
}

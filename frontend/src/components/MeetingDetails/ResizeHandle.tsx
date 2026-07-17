'use client';

import React, { useCallback, useRef } from 'react';
import { cn } from '@/lib/utils';

interface ResizeHandleProps {
  /** The flex row the panels live in; its right edge anchors the width math. */
  containerRef: React.RefObject<HTMLElement>;
  /** Current width of the right-hand panel, in px. */
  width: number;
  /** Clamp bounds, in px. */
  min: number;
  max: number;
  /** Called with the next clamped width as the user drags or nudges. */
  onChange: (next: number) => void;
  className?: string;
  ariaLabel?: string;
}

/**
 * A thin vertical divider that resizes the panel to its RIGHT by dragging.
 * Only rendered inline at `xl` (below that the transcript is an overlay drawer
 * with its own width, so resizing is meaningless there). Keyboard-operable:
 * ArrowLeft grows the panel, ArrowRight shrinks it (Shift = larger step).
 */
export function ResizeHandle({
  containerRef,
  width,
  min,
  max,
  onChange,
  className,
  ariaLabel = 'Resize transcript panel',
}: ResizeHandleProps) {
  const draggingRef = useRef(false);

  const onPointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      const container = containerRef.current;
      if (!container) return;
      e.preventDefault();
      draggingRef.current = true;
      const rect = container.getBoundingClientRect();
      document.body.style.cursor = 'col-resize';
      document.body.style.userSelect = 'none';

      const onMove = (ev: PointerEvent) => {
        if (!draggingRef.current) return;
        // Panel is on the right: its width is the distance from the pointer
        // to the container's right edge.
        const next = Math.min(max, Math.max(min, rect.right - ev.clientX));
        onChange(next);
      };
      const onUp = () => {
        draggingRef.current = false;
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    },
    [containerRef, min, max, onChange],
  );

  const onKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      const step = e.shiftKey ? 48 : 16;
      if (e.key === 'ArrowLeft') {
        e.preventDefault();
        onChange(Math.min(max, width + step));
      } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        onChange(Math.max(min, width - step));
      }
    },
    [width, min, max, onChange],
  );

  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label={ariaLabel}
      tabIndex={0}
      onPointerDown={onPointerDown}
      onKeyDown={onKeyDown}
      className={cn(
        'group relative hidden w-px shrink-0 cursor-col-resize touch-none bg-border transition-colors hover:bg-ring/60 xl:block',
        className,
      )}
    >
      {/* Widen the hit area beyond the 1px visual line. */}
      <span aria-hidden="true" className="absolute inset-y-0 -left-2 -right-2" />
    </div>
  );
}

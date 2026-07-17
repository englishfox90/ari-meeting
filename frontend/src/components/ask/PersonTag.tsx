'use client';

import { cn } from '@/lib/utils';

/**
 * A calm, neutral person pill (a speaker name attached to a recall source).
 * Muted ink by default — amber is reserved for active/selected signals
 * elsewhere, never for a plain label (Signal Rule).
 */
export function PersonTag({ name, className }: { name: string; className?: string }) {
  return (
    <span
      className={cn(
        'inline-flex max-w-[9rem] items-center rounded-full border border-border bg-secondary px-2 py-0.5 text-[0.6875rem] font-medium leading-none text-muted-foreground',
        className,
      )}
      title={name}
    >
      <span className="truncate">{name}</span>
    </span>
  );
}

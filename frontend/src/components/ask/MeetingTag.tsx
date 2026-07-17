'use client';

import { cn } from '@/lib/utils';

/**
 * A clickable meeting pill — the title of a recall source. Navigating opens the
 * meeting-details view. Neutral by default; a light hover affordance only.
 */
export function MeetingTag({
  title,
  onClick,
  className,
}: {
  title: string;
  onClick?: () => void;
  className?: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={title}
      className={cn(
        'inline-flex max-w-full items-center rounded-full border border-border bg-secondary px-2 py-0.5 text-[0.6875rem] font-medium leading-none text-foreground transition-colors hover:border-accent hover:text-accent-foreground hover:bg-accent',
        className,
      )}
    >
      <span className="truncate">{title}</span>
    </button>
  );
}

import type { ReactNode } from 'react';

interface PageHeaderProps {
  eyebrow?: string;
  title: string;
  description?: string;
  actions?: ReactNode;
  /** Optional visual rendered to the left of the title block (e.g. a voice ring). */
  leading?: ReactNode;
}

export function PageHeader({ eyebrow, title, description, actions, leading }: PageHeaderProps) {
  return (
    <header className="flex flex-col gap-6 border-b border-border pb-7 xl:flex-row xl:items-end xl:justify-between">
      <div className="flex min-w-0 max-w-3xl items-center gap-5">
        {leading && <div className="shrink-0">{leading}</div>}
        <div className="min-w-0">
          {eyebrow && (
            <p className="app-eyebrow mb-3">
              {eyebrow}
            </p>
          )}
          <h1 className="app-display text-foreground xl:text-[2.5rem]">
            {title}
          </h1>
          {description && (
            <p className="mt-3 max-w-[42rem] text-[0.9375rem] leading-6 text-muted-foreground">
              {description}
            </p>
          )}
        </div>
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2 pb-0.5">{actions}</div>}
    </header>
  );
}

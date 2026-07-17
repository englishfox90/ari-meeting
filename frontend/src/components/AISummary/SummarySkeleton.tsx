"use client";

import { cn } from "@/lib/utils";

/**
 * Placeholder shown while the BlockNote summary editor chunk loads and mounts.
 *
 * The editor (@blocknote/*) is code-split and lazily loaded, so opening a
 * meeting can paint its shell immediately instead of blocking the main thread
 * on the editor mount. This skeleton fills the summary column in the meantime.
 *
 * No-Fake-State: this is an honest loading affordance (marked aria-busy), not
 * invented content — every bar is a neutral placeholder, no real values.
 */
export function SummarySkeleton({ className }: { className?: string }) {
  return (
    <div
      role="status"
      aria-busy="true"
      aria-label="Loading summary"
      className={cn("w-full animate-pulse p-6 sm:p-8", className)}
    >
      <span className="sr-only">Loading summary…</span>

      {/* Title line */}
      <div className="h-6 w-1/2 rounded bg-secondary" />

      {/* Section blocks */}
      <div className="mt-8 space-y-8">
        {[0, 1, 2].map((section) => (
          <div key={section} className="space-y-3">
            {/* Section heading */}
            <div className="h-4 w-1/3 rounded bg-secondary" />
            {/* Bulleted lines */}
            <div className="space-y-2 pl-1">
              <div className="h-3 w-[92%] rounded bg-muted" />
              <div className="h-3 w-[85%] rounded bg-muted" />
              <div className="h-3 w-[68%] rounded bg-muted" />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

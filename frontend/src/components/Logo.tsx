import React from "react";
import { Dialog, DialogContent, DialogTitle, DialogTrigger } from "./ui/dialog";
import { VisuallyHidden } from "./ui/visually-hidden";
import { AriMark } from "./app-shell/AriMark";
import { About } from "./About";

interface LogoProps {
    isCollapsed: boolean;
}

const Logo = React.forwardRef<HTMLButtonElement, LogoProps>(({ isCollapsed }, ref) => {
  return (
    <Dialog aria-describedby={undefined}>
      {isCollapsed ? (
        <DialogTrigger asChild>
          <button ref={ref} aria-label="About Ari Meeting" className="grid size-10 place-items-center rounded-[3px] text-[hsl(var(--accent))] transition-colors hover:bg-[hsl(var(--sidebar-hover))]">
            <AriMark variant="flick" className="h-6 w-auto" />
          </button>
        </DialogTrigger>
      ) : (
        <DialogTrigger asChild>
          <button ref={ref} className="flex min-h-11 w-full flex-col items-start gap-2.5 rounded-[3px] px-2 py-2 text-left transition-colors hover:bg-[hsl(var(--sidebar-hover))]">
            {/* Marginalia "Dictation" mark — Shin-kai ink, reads on the warm paper rail in both modes */}
            <AriMark className="h-7 w-auto text-[hsl(var(--accent))]" />
            <span className="leading-none">
              <span className="block font-display text-[0.95rem] font-semibold tracking-[-0.02em] text-[hsl(var(--heading))]">Ari Meeting</span>
              <span className="mt-1.5 block font-mono text-[0.625rem] uppercase tracking-[0.1em] text-[hsl(var(--sidebar-muted))]">local meeting desk</span>
            </span>
          </button>
        </DialogTrigger>
      )}
      <DialogContent className="sm:max-w-2xl">
        <VisuallyHidden>
          <DialogTitle>About Ari Meeting</DialogTitle>
        </VisuallyHidden>
        <About />
      </DialogContent>
    </Dialog>
  );
});

Logo.displayName = "Logo";

export default Logo;

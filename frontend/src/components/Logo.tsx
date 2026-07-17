import React from "react";
import Image from "next/image";
import { Dialog, DialogContent, DialogTitle, DialogTrigger } from "./ui/dialog";
import { VisuallyHidden } from "./ui/visually-hidden";
import { ArivoMark } from "./app-shell/ArivoMark";
import { About } from "./About";

interface LogoProps {
    isCollapsed: boolean;
}

const Logo = React.forwardRef<HTMLButtonElement, LogoProps>(({ isCollapsed }, ref) => {
  return (
    <Dialog aria-describedby={undefined}>
      {isCollapsed ? (
        <DialogTrigger asChild>
          <button ref={ref} aria-label="About Ari Meeting" className="grid size-10 place-items-center rounded-[3px] transition-colors hover:bg-[hsl(var(--sidebar-hover))]">
            <ArivoMark className="size-7" />
          </button>
        </DialogTrigger>
      ) : (
        <DialogTrigger asChild>
          <button ref={ref} className="flex min-h-11 w-full flex-col items-start gap-3 rounded-[3px] px-2 py-2 text-left transition-colors hover:bg-[hsl(var(--sidebar-hover))]">
            {/* Arivo brand mark — gray wordmark on light, white wordmark on the dark rail */}
            <Image src="/arivo-logo.png" alt="Arivo" width={144} height={80} priority className="block h-8 w-auto dark:hidden" />
            <Image src="/arivo-logo-white.png" alt="Arivo" width={144} height={80} priority className="hidden h-8 w-auto dark:block" />
            <span className="leading-none">
              <span className="block text-[0.95rem] font-semibold tracking-[-0.045em] text-[hsl(var(--sidebar-foreground))]">Ari Meeting</span>
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

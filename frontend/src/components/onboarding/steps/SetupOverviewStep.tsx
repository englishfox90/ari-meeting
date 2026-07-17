import React, { useEffect, useState } from 'react';
import { ArrowRightIcon, CheckCircleIcon, InformationCircleIcon } from '@heroicons/react/24/outline';
import { Button } from '@/components/ui/button';
import { OnboardingContainer } from '../OnboardingContainer';
import { useOnboarding } from '@/contexts/OnboardingContext';
import { cn } from '@/lib/utils';
import {
  MODEL_TIERS,
  TIER_ORDER,
  tierTotalMb,
  formatTierSize,
  type TierDef,
} from '@/lib/model-tiers';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";

export function SetupOverviewStep() {
  const {
    goNext,
    selectedTier,
    setSelectedTier,
    recommendedTier,
    appleEligible,
  } = useOnboarding();
  const [isMac, setIsMac] = useState(false);

  useEffect(() => {
    const checkPlatform = async () => {
      try {
        const { platform } = await import('@tauri-apps/plugin-os');
        setIsMac(platform() === 'macos');
      } catch (e) {
        setIsMac(navigator.userAgent.includes('Mac'));
      }
    };
    checkPlatform();
  }, []);

  const handleContinue = () => {
    goNext();
  };

  const renderTierCard = (tier: TierDef) => {
    const isSelected = selectedTier === tier.id;
    const isRecommended = recommendedTier === tier.id;
    const disabled = tier.requiresAppleEligible && !appleEligible;
    const sizeLabel = formatTierSize(tierTotalMb(tier));

    return (
      <button
        key={tier.id}
        type="button"
        role="radio"
        aria-checked={isSelected}
        aria-disabled={disabled}
        disabled={disabled}
        onClick={() => {
          if (!disabled) setSelectedTier(tier.id);
        }}
        className={cn(
          'group relative w-full rounded-[10px] border p-4 text-left transition-colors',
          'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background',
          disabled
            ? 'cursor-not-allowed border-border bg-muted/40 opacity-60'
            : isSelected
              ? 'border-primary bg-primary/5 ring-1 ring-primary'
              : 'border-border bg-card hover:border-muted-foreground/40',
        )}
      >
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-2">
            <span
              className={cn(
                'grid size-4 place-items-center rounded-full border',
                isSelected ? 'border-primary' : 'border-muted-foreground/40',
              )}
              aria-hidden="true"
            >
              {isSelected && <span className="size-2 rounded-full bg-primary" />}
            </span>
            <h3 className="text-[14px] font-medium tracking-[-0.01em]">{tier.name}</h3>
          </div>
          <span className="shrink-0 rounded-full border border-border bg-background px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
            {sizeLabel}
          </span>
        </div>

        <p className="mt-1.5 text-[12px] text-muted-foreground">{tier.tagline}</p>

        {isRecommended && !disabled && (
          <span className="mt-3 inline-flex items-center gap-1 rounded-full bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground">
            <CheckCircleIcon className="size-3" />
            Recommended for your Mac
          </span>
        )}

        <div className="mt-3 space-y-1 border-t border-border pt-3 text-[11px]">
          <div className="flex items-center justify-between gap-2">
            <span className="text-muted-foreground">Transcription</span>
            <span className="font-medium text-foreground">{tier.transcription.label}</span>
          </div>
          <div className="flex items-center justify-between gap-2">
            <span className="text-muted-foreground">Summaries</span>
            <span className="font-medium text-foreground">{tier.summary.label}</span>
          </div>
        </div>

        <p className="mt-3 text-[11px] leading-5 text-muted-foreground">{tier.description}</p>

        {disabled && (
          <p className="mt-2 text-[11px] font-medium text-foreground">
            Requires macOS 26 + Apple Intelligence
          </p>
        )}
      </button>
    );
  };

  return (
    <OnboardingContainer
      title="Choose your models."
      description="Pick a bundle of on-device transcription and summary models. Everything runs locally and privately."
      step={2}
      totalSteps={isMac ? 4 : 3}
    >
      <div className="max-w-[680px]">
        <div
          role="radiogroup"
          aria-label="Model tier"
          className="grid gap-3 sm:grid-cols-3"
        >
          {TIER_ORDER.map((id) => renderTierCard(MODEL_TIERS[id]))}
        </div>

        <div className="mt-4 flex items-start gap-2 text-[11px] leading-5 text-muted-foreground">
          <InformationCircleIcon className="mt-0.5 size-3.5 shrink-0" />
          <span>
            You can change transcription and summary models anytime in Settings — including
            external providers like{' '}
            <TooltipProvider>
              <Tooltip>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label="About external providers"
                    className="font-medium text-foreground underline decoration-dotted underline-offset-2"
                  >
                    OpenAI, Claude, or Ollama
                  </button>
                </TooltipTrigger>
                <TooltipContent className="max-w-xs text-sm">
                  External AI providers can be configured for summary generation in Settings after
                  setup.
                </TooltipContent>
              </Tooltip>
            </TooltipProvider>
            .
          </span>
        </div>

        {/* CTA Section */}
        <div className="mt-8 flex items-center gap-4">
          <Button onClick={handleContinue} className="h-9">
            Continue <ArrowRightIcon className="size-4" />
          </Button>
          <div>
            <a
              href="https://github.com/henryvn27/meetily_improved/issues"
              target="_blank"
              rel="noopener noreferrer"
              className="text-[11px] text-muted-foreground hover:text-foreground hover:underline"
            >
              Report issues on GitHub
            </a>
          </div>
        </div>
      </div>
    </OnboardingContainer>
  );
}

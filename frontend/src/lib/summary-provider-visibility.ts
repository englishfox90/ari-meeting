/**
 * Which summary-model providers are offered in the picker.
 *
 * This is a private, local-first build: by default we expose only on-device /
 * local-install providers (Built-in AI, Ollama, Claude CLI). The remaining
 * cloud/API providers (Claude API, OpenAI, Groq, OpenRouter, Custom Server)
 * are hidden behind a compile-time flag so the default surface stays calm and
 * local-only.
 *
 * Reveal every provider by building with:
 *   NEXT_PUBLIC_ARI_SHOW_ALL_PROVIDERS=1   (or "true")
 *
 * Apple on-device (FoundationModels) is another always-on local provider; it
 * joins DEFAULT_VISIBLE_PROVIDERS below.
 */

/** Providers always shown, regardless of the advanced flag. */
export const DEFAULT_VISIBLE_PROVIDERS: readonly string[] = ['builtin-ai', 'ollama', 'claude-cli', 'apple-foundation'];

const configuredFlag = process.env.NEXT_PUBLIC_ARI_SHOW_ALL_PROVIDERS;

/** True when the build opts into exposing the cloud/API providers. */
export const showAllSummaryProviders: boolean = configuredFlag === '1' || configuredFlag === 'true';

/**
 * Whether a given summary provider should appear in the picker.
 *
 * The currently-selected provider is always visible even when it would
 * otherwise be hidden — so a pre-existing cloud selection is shown honestly
 * and can still be changed, rather than silently vanishing from the dropdown.
 */
export function isSummaryProviderVisible(provider: string, currentProvider?: string | null): boolean {
  if (showAllSummaryProviders) return true;
  if (provider === currentProvider) return true;
  return DEFAULT_VISIBLE_PROVIDERS.includes(provider);
}

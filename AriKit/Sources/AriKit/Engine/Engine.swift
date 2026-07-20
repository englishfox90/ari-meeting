///
///  Engine.swift — module namespace for the ported Summary + LLM provider layer
///  (docs/plans/arikit-engine-providers.md).
///
///  Phase 3.4 replaces the frozen Rust `ari_engine::summary` + provider clients
///  (`anthropic`/`openai`/`groq`/`ollama`/`openrouter` + `claude_cli` + `apple`) with Swift under
///  `Engine/`. Landed so far:
///  - **Slice A** (`Providers/`) — the `LLMClient` protocol, `LLMRequest`, `ProviderKind`,
///    `ProviderConfig`, `LLMError`, the `ProviderFactory` skeleton (loopback gate + MLX injection
///    point), and the `#if DEBUG` `StubLLMClient` test double.
///  - **Slice B** (`Providers/`) — `OpenAICompatibleClient` (OpenAI/Groq/OpenRouter/Ollama/
///    CustomOpenAI over `URLSession` + SSE) and `AnthropicClient` (Claude messages API + SSE).
///    `ProviderFactory` now returns real conformers for all of these kinds.
///  - **Slice C** (`Providers/`) — `ClaudeCLIClient` (`#if os(macOS)`): shells out to a locally
///    installed Claude Code CLI (`Process`) rather than making an HTTP request. No streaming
///    (relies on the `LLMClient` extension's single-yield fallback).
///
///  Later slices (see the plan's dependency-ordered slice list, §5) add the on-device conformer
///  (D), the MLX conformer in a separate `AriKitEngineMLX` product (E), the summary pipeline
///  (F/G), persons extraction/reconciliation (H), and series detection/ledger (I).
///
public enum Engine {}

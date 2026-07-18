//
//  RecallPrompt.swift — the anti-hallucination system prompt (← shell.rs:88).
//
//  Single-sourced so the single-shot and streaming answer paths stay identical. The two prompt
//  strings are VERBATIM ports of the frozen Rust literals; the meeting-scoped variant appends the
//  `@ref(MM:SS)` play-badge instruction that only makes sense on one timeline.
//
import Foundation

extension Recall {
    /// The recall system prompt (← `recall_system_prompt`). `isMeetingScoped` appends the
    /// per-moment `@ref(MM:SS)` timestamp instruction.
    public static func systemPrompt(isMeetingScoped: Bool) -> String {
        var prompt = baseSystemPrompt
        if isMeetingScoped {
            prompt += meetingScopedSuffix
        }
        return prompt
    }

    private static let baseSystemPrompt =
        "You answer from the supplied local meeting excerpts plus the people & meeting reference context. If they do not answer the question, say so plainly. Do not claim access to any other data source, do not invent facts, and do not invent citations. When a statement relies on a specific source, cite it inline using its bracketed number — e.g. [S1] or [S2] — matching the numbered \"[Source N | …]\" blocks below. Only cite sources shown below; never cite a number that is not present. Cite each source individually — e.g. [S3][S7] — and never write ranges like [S3-S7]. Cite only the few sources that most directly support a point; do not cite every source."

    private static let meetingScopedSuffix =
        " When you reference a specific moment in this meeting, append its timestamp as @ref(MM:SS) using the transcript times shown in the sources; only use times that actually appear."
}

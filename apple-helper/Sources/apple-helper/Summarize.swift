//
//  Summarize.swift
//  apple-helper
//
//  On-device summarization for the `summarize` request, factored out of
//  main.swift so it is unit-testable and so the framework calls are isolated.
//
//  Backed by Apple's FoundationModels on-device LLM (macOS 26+, Apple
//  Intelligence). Every result reflects a REAL model generation — this function
//  NEVER fabricates a summary (No-Fake-State). On ANY failure (model
//  unavailable, guardrail refusal, thrown error, or empty output) it THROWS a
//  descriptive `SummarizeError`; main.swift catches and emits an
//  `AppleResponse.error(message:)` instead of a fake summary.
//
//  Symbols verified against the macOS 26 SDK swiftinterface
//  (FoundationModels.framework, arm64e-apple-macos.swiftinterface):
//    - `SystemLanguageModel.default.availability` → `.available` |
//      `.unavailable(UnavailableReason)`  (same as Probe.swift).
//    - `LanguageModelSession(model:tools:instructions:)` convenience init with
//      `instructions: String?`  (line 338).
//    - `session.respond(to prompt: String, options: GenerationOptions) async
//      throws -> LanguageModelSession.Response<String>`  (line 357); the
//      generated text is `response.content` (`Response.content: Content`,
//      `Content == String` here — line 347).
//    - `GenerationOptions(sampling:temperature:maximumResponseTokens:)` with
//      `maximumResponseTokens: Int?`  (lines 1309–1324). THIS is the real
//      token-limit knob (the prompt guessed "maximumResponseTokens" — confirmed
//      correct).
//    - Generation failures surface as
//      `LanguageModelSession.GenerationError` (e.g. `.guardrailViolation`,
//      `.exceededContextWindowSize`, `.refusal`) — we catch generically and
//      report the localized description.
//
//  ENTITLEMENTS: on-device FoundationModels generation needs NO special
//  entitlement — it is an in-process, on-device inference API (no network, no
//  TCC-guarded resource like mic/speech). Verified: the SDK exposes no
//  entitlement key for FoundationModels, and Apple's guidance is that the
//  built-in system model is available to any app running on an
//  Apple-Intelligence-eligible device once the user has enabled it. No
//  entitlements file was added. (Contrast: Speech recognition and calendar DO
//  need entitlements; FoundationModels does not.)
//

import Foundation
import FoundationModels

/// A descriptive, honest failure from the summarize path. Its `message` is what
/// the sidecar surfaces to the Rust core as `AppleResponse.error(message:)`.
struct SummarizeError: Error, Equatable {
    let message: String
}

enum Summarize {

    /// Generate a summary of `text` following `instruction`, bounded by
    /// `maxTokens`, using the on-device FoundationModels LLM.
    ///
    /// - Throws: `SummarizeError` with a truthful reason on model
    ///   unavailability, guardrail refusal, a thrown generation error, or empty
    ///   output. Never returns a fabricated summary.
    static func run(text: String, instruction: String, maxTokens: Int) async throws -> String {
        // 1. Gate on real model availability first (mirrors Probe.swift). If the
        //    model can't run, say WHY — never proceed to fake a summary.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw SummarizeError(message: unavailabilityMessage(reason))
        @unknown default:
            throw SummarizeError(message: "Apple on-device model unavailable: unrecognized availability state")
        }

        // 2. Compose the session: the caller's instruction becomes the session
        //    instructions; the transcript text becomes the prompt content.
        let session = LanguageModelSession(instructions: instruction)

        // 3. Build the prompt asking the model to apply the instruction over the
        //    supplied transcript text.
        let prompt = """
        \(instruction)

        Transcript:
        \(text)
        """

        // 4. Respect the requested token budget via the real GenerationOptions
        //    knob. A non-positive budget means "no explicit cap".
        let options = GenerationOptions(
            maximumResponseTokens: maxTokens > 0 ? maxTokens : nil
        )

        // 5. Generate. Any thrown GenerationError (guardrail refusal, context
        //    overflow, etc.) is turned into an honest SummarizeError.
        let output: String
        do {
            let response = try await session.respond(to: prompt, options: options)
            output = response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw SummarizeError(message: "on-device generation failed: \(error.localizedDescription)")
        } catch {
            throw SummarizeError(message: "on-device generation failed: \(error.localizedDescription)")
        }

        // 6. Empty output is a failure, not a summary.
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizeError(message: "on-device model returned an empty summary")
        }
        return trimmed
    }

    /// Human-readable, truthful reason for an unavailable system language model.
    private static func unavailabilityMessage(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled — enable it in System Settings to use on-device summarization"
        case .deviceNotEligible:
            return "this device is not eligible for Apple Intelligence on-device summarization"
        case .modelNotReady:
            return "the Apple on-device model is not ready yet (still downloading or preparing) — try again shortly"
        @unknown default:
            return "the Apple on-device model is unavailable for an unrecognized reason"
        }
    }
}

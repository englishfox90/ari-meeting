//
//  FoundationModelsClientTests.swift — plan §6 Slice D.
//
//  `FoundationModelsAvailabilityTests` exercises the honest unavailable → `.providerUnavailable`
//  path (and the available/failure/empty-output paths) entirely through the client's injectable
//  `unavailableReason`/`respond` seams — never a real `LanguageModelSession` — so the suite runs
//  headlessly regardless of whether Apple Intelligence is enabled on the machine running
//  `swift test` (plan: "device-gated smoke test only" for real generation). The pure
//  `unavailabilityMessage(_:)` mapping is additionally checked directly against literal
//  `SystemLanguageModel.Availability.UnavailableReason` cases — no live model needed either way.
//
import FoundationModels
import Testing
@testable import AriKit

/// Test-only actor capturing the `maxTokens` value a fake `respond` seam observed — actor
/// isolation (not `@unchecked Sendable`) makes cross-task recording safe under strict concurrency.
private actor ObservedMaxTokens {
    private(set) var value: Int?

    func record(_ maxTokens: Int?) {
        value = maxTokens
    }
}

struct FoundationModelsAvailabilityTests {
    @Test func unavailableReasonThrowsProviderUnavailableAndNeverCallsRespond() async {
        let client = FoundationModelsClient(
            unavailableReason: { "Apple Intelligence is not enabled" },
            respond: { _, _, _ in
                Issue.record("respond must never be called when the model reports unavailable")
                return "FABRICATED SUMMARY"
            }
        )

        do {
            _ = try await client.generate(LLMRequest(system: "s", user: "u"))
            Issue.record("expected .providerUnavailable")
        } catch let LLMError.providerUnavailable(reason) {
            #expect(reason == "Apple Intelligence is not enabled")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func availableRoutesSystemAndUserThroughAndStripsPlaceholderTimestamps() async throws {
        let client = FoundationModelsClient(
            unavailableReason: { nil },
            respond: { system, user, _ in
                #expect(system == "sys prompt")
                #expect(user == "user prompt")
                return "Decision made [MM:SS] about scope."
            }
        )

        let result = try await client.generate(LLMRequest(system: "sys prompt", user: "user prompt"))
        #expect(result == "Decision made about scope.")
    }

    @Test func emptyOutputThrowsRequestFailedNotProviderUnavailable() async {
        let client = FoundationModelsClient(unavailableReason: { nil }, respond: { _, _, _ in "   " })

        do {
            _ = try await client.generate(LLMRequest(system: "s", user: "u"))
            Issue.record("expected .requestFailed")
        } catch LLMError.requestFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func thrownGenerationErrorWrapsAsRequestFailed() async {
        struct FakeGenerationFailure: Error {}
        let client = FoundationModelsClient(
            unavailableReason: { nil },
            respond: { _, _, _ in throw FakeGenerationFailure() }
        )

        do {
            _ = try await client.generate(LLMRequest(system: "s", user: "u"))
            Issue.record("expected .requestFailed")
        } catch LLMError.requestFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // ---- max-tokens default resolution (← `llm_client.rs:175`: `max_tokens.unwrap_or(512)`) ----

    @Test func nilRequestMaxTokensResolvesToFiveTwelveDefault() async throws {
        let observed = ObservedMaxTokens()
        let client = FoundationModelsClient(
            unavailableReason: { nil },
            respond: { _, _, maxTokens in
                await observed.record(maxTokens)
                return "ok"
            }
        )

        _ = try await client.generate(LLMRequest(system: "s", user: "u"))
        #expect(await observed.value == 512)
    }

    @Test func explicitRequestMaxTokensIsPassedThroughUnchanged() async throws {
        let observed = ObservedMaxTokens()
        let client = FoundationModelsClient(
            unavailableReason: { nil },
            respond: { _, _, maxTokens in
                await observed.record(maxTokens)
                return "ok"
            }
        )

        _ = try await client.generate(LLMRequest(system: "s", user: "u", maxTokens: 128))
        #expect(await observed.value == 128)
    }

    // ---- bounded generation timeout (← `SUMMARIZE_TIMEOUT`, `apple/helper.rs:32,192`) ----

    @Test func wedgedRespondTimesOutInsteadOfHangingForever() async throws {
        // Injects a test-scale `timeout:` (production always uses the real 180s default — see
        // `FoundationModelsClient.generationTimeout`) so this asserts the timeout RACE fires
        // without the test actually waiting 180 real seconds.
        let client = FoundationModelsClient(
            unavailableReason: { nil },
            respond: { _, _, _ in
                // Never voluntarily returns; the client's own timeout race must win.
                try await Task.sleep(for: .seconds(60))
                return "should never get here"
            },
            timeout: .milliseconds(50)
        )

        do {
            _ = try await client.generate(LLMRequest(system: "s", user: "u"))
            Issue.record("expected a timeout failure")
        } catch LLMError.requestFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func kindIsAppleFoundation() {
        let client = FoundationModelsClient(unavailableReason: { nil }, respond: { _, _, _ in "hi" })
        #expect(client.kind == .appleFoundation)
    }

    @Test func publicInitRejectsWrongProviderKind() {
        let config = ProviderConfig(kind: .openAI, model: "gpt-4")
        #expect(throws: LLMError.self) {
            _ = try FoundationModelsClient(config: config)
        }
    }

    @Test func publicInitAcceptsAppleFoundationKind() throws {
        let config = ProviderConfig(kind: .appleFoundation, model: "on-device")
        let client = try FoundationModelsClient(config: config)
        #expect(client.kind == .appleFoundation)
    }

    // ---- Pure availability-reason mapping (← `Summarize.swift:112-126`) — no live model needed ----

    @Test func appleIntelligenceNotEnabledMapsToAnActionableMessage() {
        let message = FoundationModelsClient.unavailabilityMessage(.appleIntelligenceNotEnabled)
        #expect(message.contains("Apple Intelligence is not enabled"))
    }

    @Test func deviceNotEligibleMapsToAnHonestMessage() {
        let message = FoundationModelsClient.unavailabilityMessage(.deviceNotEligible)
        #expect(message.contains("not eligible"))
    }

    @Test func modelNotReadyMapsToATryAgainMessage() {
        let message = FoundationModelsClient.unavailabilityMessage(.modelNotReady)
        #expect(message.contains("not ready yet"))
    }
}

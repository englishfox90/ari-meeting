//
//  OnboardingViewModelTests.swift — acceptance test 9 (docs/plans/onboarding-install-flow.md §7):
//  fan-out/fan-in of three fake `OnboardingInstallableComponent` conformers (one
//  slow-with-progress, one fast-cached, one erroring) produces the expected per-row state
//  transitions and an overall "all done" signal only when all three genuinely succeed — never
//  optimistic-completes on a still-in-flight or errored component.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

private struct SlowWithProgressComponent: OnboardingInstallableComponent {
    let componentID: OnboardingComponentID = .summaryModel
    let displayName = "Slow component"

    func quickPresenceHint() async -> Bool {
        false
    }

    func ensureReady(progress: (@Sendable (OnboardingInstallProgress) -> Void)?) async throws {
        progress?(.checking)
        progress?(.downloading(fractionCompleted: 0.5))
        progress?(.downloading(fractionCompleted: 1.0))
        progress?(.compiling)
    }
}

private struct FastCachedComponent: OnboardingInstallableComponent {
    let componentID: OnboardingComponentID = .diarization
    let displayName = "Fast cached component"

    func quickPresenceHint() async -> Bool {
        true
    }

    func ensureReady(progress _: (@Sendable (OnboardingInstallProgress) -> Void)?) async throws {
        // Already cached — resolves immediately, no progress events at all (honest: nothing to
        // report on).
    }
}

private struct ErroringComponent: OnboardingInstallableComponent {
    struct InstallError: Error, CustomStringConvertible {
        var description: String {
            "install failed"
        }
    }

    let componentID: OnboardingComponentID = .embedding
    let displayName = "Erroring component"

    func quickPresenceHint() async -> Bool {
        false
    }

    func ensureReady(progress: (@Sendable (OnboardingInstallProgress) -> Void)?) async throws {
        progress?(.checking)
        throw InstallError()
    }
}

@Suite("OnboardingViewModel")
@MainActor
struct OnboardingViewModelTests {
    private func makeViewModel(
        components: [any OnboardingInstallableComponent]
    ) async throws -> OnboardingViewModel {
        let db = try AppDatabase.makeInMemory()
        return OnboardingViewModel(components: components, settings: db.settings)
    }

    @Test("rows are seeded in the injected component order, all notStarted before install")
    func rowsSeededInComponentOrder() async throws {
        let vm = try await makeViewModel(components: [
            FastCachedComponent(), SlowWithProgressComponent(), ErroringComponent()
        ])
        #expect(vm.rows.map(\.componentID) == [.diarization, .summaryModel, .embedding])
        #expect(vm.allComponentsReady == false)
    }

    @Test("loadPresenceHints reflects each component's real quickPresenceHint, never fabricated")
    func loadPresenceHintsReflectsRealHints() async throws {
        let vm = try await makeViewModel(components: [FastCachedComponent(), SlowWithProgressComponent()])
        await vm.loadPresenceHints()

        let cachedRow = try #require(vm.rows.first { $0.componentID == .diarization })
        guard case let .notStarted(presenceHint) = cachedRow.state else {
            Issue.record("expected .notStarted, got \(cachedRow.state)")
            return
        }
        #expect(presenceHint == true)

        let slowRow = try #require(vm.rows.first { $0.componentID == .summaryModel })
        guard case let .notStarted(presenceHint: slowHint) = slowRow.state else {
            Issue.record("expected .notStarted, got \(slowRow.state)")
            return
        }
        #expect(slowHint == false)
    }

    @Test("startInstall: a fast-cached + slow-with-progress mix both reach .completed")
    func startInstallCompletesSuccessfulComponents() async throws {
        let vm = try await makeViewModel(components: [FastCachedComponent(), SlowWithProgressComponent()])
        await vm.startInstall()

        #expect(vm.allComponentsReady == true)
        for row in vm.rows {
            #expect(row.state == .completed)
        }
    }

    @Test("startInstall: an erroring component surfaces .failed, never a fake-ready .completed")
    func startInstallSurfacesHonestFailure() async throws {
        let vm = try await makeViewModel(components: [ErroringComponent()])
        await vm.startInstall()

        let row = try #require(vm.rows.first { $0.componentID == .embedding })
        guard case .failed = row.state else {
            Issue.record("expected .failed, got \(row.state)")
            return
        }
        #expect(vm.allComponentsReady == false)
    }

    @Test("startInstall: allComponentsReady is true ONLY when every component genuinely succeeded")
    func allComponentsReadyRequiresEveryComponentToSucceed() async throws {
        let vm = try await makeViewModel(components: [
            FastCachedComponent(), SlowWithProgressComponent(), ErroringComponent()
        ])
        await vm.startInstall()

        #expect(vm.allComponentsReady == false)
        let succeeded = vm.rows.filter { $0.state == .completed }
        #expect(succeeded.count == 2)
        let failed = vm.rows.first { $0.componentID == .embedding }
        guard case .failed = failed?.state else {
            Issue.record("expected the erroring component to be .failed")
            return
        }
    }

    @Test("retry re-attempts only the named component, leaving the others untouched")
    func retryOnlyReattemptsNamedComponent() async throws {
        let vm = try await makeViewModel(components: [FastCachedComponent(), ErroringComponent()])
        await vm.startInstall()
        #expect(vm.rows.first { $0.componentID == .diarization }?.state == .completed)

        await vm.retry(.embedding)
        // Still fails (the fake always throws) — but the point is only that row was touched, and
        // the completed row is untouched.
        let embeddingRow = try #require(vm.rows.first { $0.componentID == .embedding })
        guard case .failed = embeddingRow.state else {
            Issue.record("expected the erroring component to remain .failed after retry")
            return
        }
        #expect(vm.rows.first { $0.componentID == .diarization }?.state == .completed)
    }

    @Test("markOnboardingCompleted persists true through the settings repository")
    func markOnboardingCompletedPersists() async throws {
        let db = try AppDatabase.makeInMemory()
        let vm = OnboardingViewModel(components: [FastCachedComponent()], settings: db.settings)

        let before = try await db.settings.bool(forKey: .onboardingCompleted)
        #expect(before == nil)

        await vm.markOnboardingCompleted()

        let after = try await db.settings.bool(forKey: .onboardingCompleted)
        #expect(after == true)
    }

    @Test("summaryModelComfort is informational only, never derived to block install")
    func summaryModelComfortIsInformationalOnly() async throws {
        let lowMemory = HardwareCapability(physicalMemoryGB: 8.0, processorCount: 8, isAppleSilicon: true)
        let db = try AppDatabase.makeInMemory()
        let vm = OnboardingViewModel(
            components: [FastCachedComponent()],
            settings: db.settings,
            hardware: lowMemory
        )
        #expect(vm.summaryModelComfort == .belowComfortThreshold(recommendedGB: 16.0))

        // Below-threshold hardware never prevents install from running to completion.
        await vm.startInstall()
        #expect(vm.allComponentsReady == true)
    }
}

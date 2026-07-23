//
//  OnboardingViewModel.swift — the first-run install/education flow's view model (docs/plans/
//  onboarding-install-flow.md §3, §5). Composes the three `OnboardingInstallableComponent`
//  conformers (diarization, summary model, embedding) injected by the app's composition root
//  (`AppEnvironment.bootstrap()`) — this view model itself never imports FluidAudio/MLX, only the
//  `OnboardingInstallableComponent` seam from core `AriKit`, mirroring `MeetingProcessingCoordinator`'s
//  "app assembles the concrete collaborators, the VM only knows the protocol" shape.
//
//  Concurrency (plan §3): the three `ensureReady` calls run CONCURRENTLY via a `TaskGroup`, since
//  they touch independent caches (FluidAudio's CoreML repo dir, the HF hub cache, `NaturalLanguage`'s
//  private asset store) — no shared mutable state between them. Per-component progress is fanned
//  into a per-component `@Observable` state, NEVER a single merged/combined fraction — three
//  differently-sized, differently-phased downloads don't sum into one honest percentage
//  (No-Fake-State).
//
import AriKit
import Foundation
import Observation
import os

@MainActor
@Observable
public final class OnboardingViewModel {
    private static let log = Logger(subsystem: "com.arivo.ari.AriViewModels", category: "onboarding")

    /// Honest per-component state (No-Fake-State): every value traces to a real
    /// `quickPresenceHint()`/`ensureReady` callback, never fabricated.
    public enum ComponentState: Equatable {
        /// Not yet attempted this session. `presenceHint` is the best-effort, non-authoritative
        /// filesystem hint (`quickPresenceHint()`) used only for the initial UI copy — never
        /// gates whether `ensureReady` runs.
        case notStarted(presenceHint: Bool)
        case inProgress(OnboardingInstallProgress)
        case completed
        case failed(String)
    }

    /// One row's static identity + live state, in the order the components were injected
    /// (stable UI row order — plan §5.3 "one row each for diarization / summary model / embedding").
    public struct Row: Identifiable, Equatable {
        public var id: OnboardingComponentID {
            componentID
        }

        public let componentID: OnboardingComponentID
        public let displayName: String
        public var state: ComponentState
    }

    public private(set) var rows: [Row]
    /// Real hardware readout (plan §2.5) — informational only, computed once at construction.
    public let hardware: HardwareCapability
    /// Informational-only assessment (plan §2.5/§5.2) — NEVER blocks `continue`/`skip`.
    public let summaryModelComfort: SummaryModelComfort
    /// True while `startInstall()` is running (disables re-tapping Continue while in flight).
    public private(set) var isInstalling = false
    /// True once every row has genuinely reached `.completed` — never optimistic-completes on a
    /// still-in-flight or errored component (test 9's core assertion).
    public var allComponentsReady: Bool {
        rows.allSatisfy {
            if case .completed = $0.state {
                return true
            }; return false
        }
    }

    private let components: [any OnboardingInstallableComponent]
    private let settings: SettingsRepository

    public init(
        components: [any OnboardingInstallableComponent],
        settings: SettingsRepository,
        hardware: HardwareCapability = .current(),
        comfortThresholdGB: Double = 16.0
    ) {
        self.components = components
        self.settings = settings
        self.hardware = hardware
        summaryModelComfort = HardwareAssessment.assessSummaryModelComfort(hardware, thresholdGB: comfortThresholdGB)
        rows = components.map { Row(
            componentID: $0.componentID,
            displayName: $0.displayName,
            state: .notStarted(presenceHint: false)
        ) }
    }

    /// Best-effort initial UI copy (plan §5.3) — refreshes each row's `presenceHint` before any
    /// download is attempted. Never gates `startInstall()`; a stale/wrong hint here only affects
    /// the label shown, not correctness.
    public func loadPresenceHints() async {
        for component in components {
            let hint = await component.quickPresenceHint()
            updateRow(for: component.componentID) { $0.state = .notStarted(presenceHint: hint) }
        }
    }

    /// Fans out `ensureReady` across all components CONCURRENTLY (plan §3) and waits for all to
    /// settle. A component's own failure never cancels the others — each row's error is reported
    /// independently, so e.g. a network hiccup on the summary-model download doesn't block the
    /// (already-cached, instantly-ready) diarization row from showing complete.
    public func startInstall() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }

        await withTaskGroup(of: Void.self) { group in
            for component in components {
                group.addTask { [weak self] in
                    await self?.runInstall(for: component)
                }
            }
            await group.waitForAll()
        }
    }

    private func runInstall(for component: any OnboardingInstallableComponent) async {
        let componentID = component.componentID
        updateRow(for: componentID) { $0.state = .inProgress(.checking) }
        do {
            try await component.ensureReady(progress: { [weak self] progress in
                Task { @MainActor in
                    self?.updateRow(for: componentID) { $0.state = .inProgress(progress) }
                }
            })
            updateRow(for: componentID) { $0.state = .completed }
        } catch {
            updateRow(for: componentID) { $0.state = .failed(UserFacingError.message(error)) }
        }
    }

    /// Re-attempts ONE component's install (the per-row Retry action, plan §5.3) — leaves every
    /// other row's state untouched.
    public func retry(_ componentID: OnboardingComponentID) async {
        guard let component = components.first(where: { $0.componentID == componentID }) else { return }
        await runInstall(for: component)
    }

    /// Marks onboarding permanently complete (plan "Decisions (resolved 2026-07-23)" #2 —
    /// "Skip for now" and completing normally both write `true`; never re-nag). Persisted through
    /// `SettingsRepository` only (single-DB-owner, plan §4) — no new table, no second writer.
    public func markOnboardingCompleted() async {
        do {
            try await settings.setBool(true, forKey: .onboardingCompleted)
        } catch {
            // Non-fatal: onboarding simply re-shows next launch (an acceptable re-nag fallback,
            // not data loss). Logged so a persistent write failure is still discoverable.
            Self.log.error("failed to persist onboardingCompleted: \(error, privacy: .public)")
        }
    }

    private func updateRow(for componentID: OnboardingComponentID, _ mutate: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.componentID == componentID }) else { return }
        mutate(&rows[index])
    }
}

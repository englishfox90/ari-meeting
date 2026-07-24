//
//  OnboardingView.swift — the first-run install/education flow (docs/plans/
//  onboarding-install-flow.md §5). Deliberately ONE screen, no wizard chrome (no page dots, no
//  back/next) — the product owner's explicit "really easy… not lots of options" direction.
//
//  No-Fake-State throughout: every per-row state traces to a real `OnboardingViewModel.Row.state`
//  transition (itself sourced from a real provider callback); the hardware readout is a real
//  `ProcessInfo` reading; the comfort warning only renders when genuinely below the threshold; a
//  real `ProgressView(value:)` is used only where a provider reports a genuine fraction, an
//  indeterminate spinner + phase label everywhere else — never a fabricated percentage.
//
import AriKit
import AriViewModels
import SwiftUI

struct OnboardingView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinished: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isContinuing = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: MarginaliaSpacing.xl.value) {
                    header
                    hardwareReadout
                    componentRows
                }
                .padding(MarginaliaSpacing.xl.value)
            }
            actions
        }
        .frame(width: 560, height: 660)
        .background(Color.marginalia(.canvas, in: scheme))
        .task { await viewModel.loadPresenceHints() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: MarginaliaSpacing.sm.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 56)
                .foregroundStyle(Color.marginalia(.accent, in: scheme))

            Text("Setting up Ari")
                .marginaliaTextStyle(.title1, in: scheme)

            // Reuses the register already established in brand/BRAND.md §1 "What stays local" —
            // not new privacy copy, the same operational claim restated for this screen.
            Text(
                "Ari runs its speaker identification, meeting summaries, and search entirely on "
                    + "this Mac. Everything stays local. Nothing leaves this machine unless you "
                    + "deliberately configure a cloud provider yourself."
            )
            .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Hardware readout

    private var hardwareReadout: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(
                "This Mac has \(Self.formattedGB(viewModel.hardware.physicalMemoryGB)) GB of memory."
            )
            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)

            if case .belowComfortThreshold = viewModel.summaryModelComfort {
                // Soft warning only — never `.recordingRed` (reserved for capture, BRAND.md
                // §3.4/§4), never a disabled Continue button. The product owner was explicit
                // this is informational, not a block.
                Text("Summaries may run slowly on this hardware — the app will still work.")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func formattedGB(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    // MARK: - Component rows

    private var componentRows: some View {
        VStack(spacing: MarginaliaSpacing.sm.value) {
            ForEach(viewModel.rows) { row in
                componentRow(row)
            }
        }
    }

    private func componentRow(_ row: OnboardingViewModel.Row) -> some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.md.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(row.displayName)
                    .marginaliaTextStyle(.subheadline, in: scheme)
                Text(Self.purpose(for: row.componentID))
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                statusView(for: row)
            }
            Spacer(minLength: 0)
            trailingGlyph(for: row.state)
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func statusView(for row: OnboardingViewModel.Row) -> some View {
        switch row.state {
        case let .notStarted(presenceHint):
            Text(presenceHint ? "Already on this Mac" : "Not yet installed")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
        case let .inProgress(progress):
            progressView(for: progress)
        case .completed:
            Text("Ready")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
        case let .failed(message):
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(message)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                Button("Retry") {
                    Task { await viewModel.retry(row.componentID) }
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            }
        }
    }

    @ViewBuilder
    private func progressView(for progress: OnboardingInstallProgress) -> some View {
        switch progress {
        case .checking:
            HStack(spacing: MarginaliaSpacing.xs.value) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        case let .downloading(fractionCompleted):
            // A REAL fraction — the only case that renders a determinate bar.
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                ProgressView(value: fractionCompleted)
                Text("Downloading… \(Int((fractionCompleted * 100).rounded()))%")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        case .compiling:
            HStack(spacing: MarginaliaSpacing.xs.value) {
                ProgressView().controlSize(.small)
                Text("Compiling…")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        case let .indeterminate(phase):
            HStack(spacing: MarginaliaSpacing.xs.value) {
                ProgressView().controlSize(.small)
                Text(phase)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        }
    }

    @ViewBuilder
    private func trailingGlyph(for state: OnboardingViewModel.ComponentState) -> some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.marginalia(.success, in: scheme))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.marginalia(.error, in: scheme))
        case .notStarted, .inProgress:
            EmptyView()
        }
    }

    private static func purpose(for componentID: OnboardingComponentID) -> String {
        switch componentID {
        case .diarization:
            "Tells speakers apart in a recording"
        case .summaryModel:
            "Writes your meeting summaries"
        case .embedding:
            "Powers \u{2018}Ask my meetings\u{2019} search"
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Button("Skip for now") {
                Task {
                    await viewModel.markOnboardingCompleted()
                    onFinished()
                }
            }
            .buttonStyle(.marginalia(.quiet, .large, in: scheme))

            Spacer()

            Button("Continue") {
                guard !isContinuing else { return }
                isContinuing = true
                Task {
                    await viewModel.startInstall()
                    await viewModel.markOnboardingCompleted()
                    isContinuing = false
                    onFinished()
                }
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
            .disabled(isContinuing)
        }
        .padding(MarginaliaSpacing.xl.value)
        .background {
            Color.marginalia(.surface, in: scheme)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.marginalia(.hairline, in: scheme))
                        .frame(height: 1)
                }
        }
    }
}

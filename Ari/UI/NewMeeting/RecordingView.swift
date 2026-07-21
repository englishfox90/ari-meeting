//
//  RecordingView.swift — the recording page (docs/plans/ari-recording-page.md §4.3, slice R2).
//
//  Renders `RecordingSession.phase` — never owns capture state itself (plan §4.1: "no `.task`-
//  scoped work in `RecordingView` may be load-bearing for the recording"). The session is owned
//  above this view (`AppEnvironment`), so navigating away and back reattaches trivially.
//
//  Marginalia + Liquid Glass v2: `MarginaliaCanvasWash` ground, content on paper surfaces, ONE
//  recording-red Signal per screen — the Record/Stop action — never decorative elsewhere (a live
//  "Recording" label or level meter must NOT also render in recording-red). Every readiness
//  readout is real `CaptureAvailability`/`TranscriberReadiness` state (No-Fake-State): the R2 app
//  ships honest "isn't built yet" reasons until R3–R6 wire real capture, and the Record button
//  stays disabled with that reason visible rather than pretending it can start.
//
import AriKit
import AriViewModels
import SwiftUI

struct RecordingView: View {
    @Bindable var session: RecordingSession
    let onOpenMeeting: (MeetingID) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background(MarginaliaCanvasWash(scheme: scheme))
            .navigationTitle("New meeting")
            .sheet(isPresented: consentSheetPresented) {
                ConsentSheet(
                    onRecord: { Task { await session.confirmConsent() } },
                    onCancel: { session.cancelConsent() }
                )
            }
    }

    /// `true` only in `.consentPrompt` — dismissing the stock sheet without an explicit choice
    /// (swipe-down, Esc) routes through `cancelConsent()`, same as tapping "Cancel" (plan §4.3).
    private var consentSheetPresented: Binding<Bool> {
        Binding(
            get: { session.phase == .consentPrompt },
            set: { isPresented in
                if !isPresented {
                    session.cancelConsent()
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .consentPrompt:
            idleContent
        case .starting:
            transitionContent(message: "Starting — connecting audio sources.")
        case let .recording(startedAt):
            recordingContent(startedAt: startedAt)
        case .stopping:
            transitionContent(message: "Finishing — saving audio and final transcript.")
        case let .saved(meetingId):
            savedContent(meetingId: meetingId)
        case let .failed(message):
            failedContent(message: message)
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xl.value) {
                titleField
                sourceReadinessSection
                transcriberReadinessSection
                recordAction
            }
            .padding(MarginaliaSpacing.lg.value)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            SectionHeader(title: "TITLE")
            MarginaliaTextField(text: $session.pendingTitle, prompt: "Untitled meeting", scheme: scheme)
        }
    }

    private var sourceReadinessSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            SectionHeader(title: "SOURCES")
            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                readinessRow(title: "Microphone", availability: session.micStatus)
                readinessRow(title: "System audio", availability: session.systemStatus)
            }
            .padding(MarginaliaSpacing.md.value)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.surface, in: scheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                            .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                    }
            }
        }
    }

    private func readinessRow(title: String, availability: CaptureAvailability) -> some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
            Image(systemName: symbol(for: availability))
                .foregroundStyle(Color.marginalia(ink(for: availability), in: scheme))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(title)
                    .marginaliaTextStyle(.body, in: scheme)
                Text(detail(for: availability))
                    .marginaliaTextStyle(.callout, in: scheme, ink: ink(for: availability))
            }
            Spacer(minLength: 0)
        }
    }

    private func symbol(for availability: CaptureAvailability) -> String {
        switch availability {
        case .ready: "checkmark.circle"
        case .notDetermined: "questionmark.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private func ink(for availability: CaptureAvailability) -> MarginaliaColorRole {
        switch availability {
        case .ready: .success
        case .notDetermined: .inkSecondary
        case .unavailable: .error
        }
    }

    private func detail(for availability: CaptureAvailability) -> String {
        switch availability {
        case .ready: "Ready"
        case .notDetermined: "Not yet determined — will be requested when recording starts"
        case let .unavailable(reason): reason
        }
    }

    private var transcriberReadinessSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            SectionHeader(title: "LIVE TRANSCRIPTION")
            transcriberReadinessRow
                .padding(MarginaliaSpacing.md.value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .fill(Color.marginalia(.surface, in: scheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                        }
                }
        }
    }

    @ViewBuilder
    private var transcriberReadinessRow: some View {
        switch session.transcriberReadiness {
        case let .ready(locale):
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color.marginalia(.success, in: scheme))
                Text("Ready (\(locale))")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .success)
            }
        case let .downloadingAssets(progress):
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text("Downloading the on-device speech model…")
                    .marginaliaTextStyle(.callout, in: scheme)
                // The framework's own fraction, verbatim — never an invented percentage.
                ProgressView(value: progress)
            }
        case let .unavailable(reason):
            HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.marginalia(.error, in: scheme))
                Text(reason)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
            }
        }
    }

    /// The one Signal on the idle screen — recording-red glass, disabled honestly when the
    /// transcriber can't run or neither capture source can start (plan §4.3).
    private var recordAction: some View {
        Button("Record") { session.requestStart() }
            .buttonStyle(.marginalia(.recording, .large, in: scheme))
            .disabled(!canStartRecording)
    }

    private var canStartRecording: Bool {
        guard case .ready = session.transcriberReadiness else { return false }
        if case .unavailable = session.micStatus, case .unavailable = session.systemStatus {
            return false
        }
        return true
    }

    // MARK: - Starting / stopping

    private func transitionContent(message: String) -> some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .marginaliaTextStyle(.body, in: scheme)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }

    // MARK: - Recording

    private func recordingContent(startedAt: Date) -> some View {
        VStack(spacing: 0) {
            recordingHeader(startedAt: startedAt)
            degradedSourceBanner
            liveTranscriptList
        }
        .safeAreaInset(edge: .bottom) {
            stopBar
        }
    }

    /// No recording-red here — the Stop button below is the one Signal for this screen (the
    /// exclusivity rule, plan §7). "Recording" renders in heading ink; the elapsed clock is a
    /// real derivation of `startedAt`, never an accumulated counter that can drift.
    private func recordingHeader(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Text("Recording")
                    .marginaliaTextStyle(.headline, in: scheme)
                Spacer(minLength: MarginaliaSpacing.sm.value)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(MarginaliaTimecode.mmss(context.date.timeIntervalSince(startedAt)))
                        .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
                }
            }
            levelMeter
        }
        .padding(MarginaliaSpacing.md.value)
    }

    /// A real level readout — animation of real state is sanctioned (BRAND.md §9). Uses the
    /// accent ink, not recording-red (that channel is reserved for the Record/Stop action).
    private var levelMeter: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(min(max(session.liveLevel, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.marginalia(.hairline, in: scheme))
                Capsule()
                    .fill(Color.marginalia(.accent, in: scheme))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.1), value: session.liveLevel)
    }

    @ViewBuilder
    private var degradedSourceBanner: some View {
        if case .unavailable = session.systemStatus, session.micStatus == .ready {
            MarginaliaBanner(
                kind: .info,
                message: "System audio unavailable — recording microphone only.",
                scheme: scheme
            )
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.bottom, MarginaliaSpacing.sm.value)
        } else if case .unavailable = session.micStatus, session.systemStatus == .ready {
            MarginaliaBanner(
                kind: .info,
                message: "Microphone unavailable — recording system audio only.",
                scheme: scheme
            )
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.bottom, MarginaliaSpacing.sm.value)
        }
    }

    /// Finalized segments only, in arrival order, auto-scrolled to the tail as new ones land.
    private var liveTranscriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    if session.segments.isEmpty {
                        Text("Listening — the transcript appears here as speech is recognized.")
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, MarginaliaSpacing.lg.value)
                    } else {
                        ForEach(session.segments) { segment in
                            TranscriptSegmentRow(line: segment, speakerName: nil, onSeek: { _ in })
                                .id(segment.id)
                        }
                    }
                }
                .padding(MarginaliaSpacing.md.value)
            }
            .onChange(of: session.segments.count) { _, _ in
                guard let lastId = session.segments.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    private var stopBar: some View {
        HStack {
            Spacer()
            Button("Stop") { Task { await session.stop() } }
                .buttonStyle(.marginalia(.recording, .large, in: scheme))
            Spacer()
        }
        .padding(MarginaliaSpacing.md.value)
    }

    // MARK: - Saved / failed

    private func savedContent(meetingId: MeetingID) -> some View {
        VStack(spacing: MarginaliaSpacing.lg.value) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.marginalia(.success, in: scheme))
            Text("Recording saved")
                .marginaliaTextStyle(.title2, in: scheme)
            Text(segmentCountLine)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            HStack(spacing: MarginaliaSpacing.md.value) {
                Button("New recording") { session.reset() }
                    .buttonStyle(.marginalia(.secondary, .large, in: scheme))
                Button("Open meeting") { onOpenMeeting(meetingId) }
                    .buttonStyle(.marginalia(.primary, .large, in: scheme))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }

    private var segmentCountLine: String {
        let count = session.segments.count
        return "\(count) transcript \(count == 1 ? "segment" : "segments") saved."
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.marginalia(.error, in: scheme))
            Text(message)
                .marginaliaTextStyle(.body, in: scheme, ink: .error)
                .multilineTextAlignment(.center)
            Button("Try again") { session.reset() }
                .buttonStyle(.marginalia(.secondary, .large, in: scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }
}

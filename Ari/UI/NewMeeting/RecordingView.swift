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

    /// Read only for the saved-screen's live pipeline status line (docs/plans/
    /// swift-meeting-generation-flow.md, Track 2) — this view never triggers the coordinator
    /// itself (`RootSplitView`'s mount-independent `.onChange` does that), it only reflects it.
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background(MarginaliaCanvasWash(scheme: scheme))
            .navigationTitle("New meeting")
            .sheet(isPresented: consentSheetPresented) {
                ConsentSheet(
                    // Synchronous edge (review H3): the phase flips to `.starting` before the
                    // sheet's dismiss can run `cancelConsent()` — Record can never lose the race.
                    onRecord: { session.confirmConsentRequested() },
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
            pendingCalendarLinkChip
        }
    }

    /// The Calendar page's "Start meeting" handoff intent, visible and removable (plan §5,
    /// No-Fake-State): a stale intent must never silently link the wrong event. Renders only the
    /// event title carried on the intent — the linked-meeting fact itself only ever shows up in
    /// the calendar event's own detail sheet, read back from the real persisted `meetingId`.
    @ViewBuilder
    private var pendingCalendarLinkChip: some View {
        if let pending = session.pendingCalendarLink {
            HStack(spacing: MarginaliaSpacing.xs.value) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                Text("Will link to: \(pending.eventTitle)")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .accent)
                    .lineLimit(1)
                Button {
                    session.pendingCalendarLink = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.marginalia(.accent, in: scheme))
            .padding(.horizontal, MarginaliaSpacing.sm.value)
            .padding(.vertical, MarginaliaSpacing.xs.value)
            .background {
                Capsule().fill(Color.marginalia(.selectionWash, in: scheme))
            }
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
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            processingStatusSection(meetingId: meetingId)
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

    /// Honest either way (No-Fake-State): the real segment count, or — when there is none — what
    /// that actually means, phrased as the observation it is rather than a bare "0 segments".
    private var segmentCountLine: String {
        let count = session.segments.count
        guard count > 0 else {
            return "No speech was recognized, so this meeting has no transcript. "
                + "The audio was still saved — you can open the meeting to play it back."
        }
        return "\(count) transcript \(count == 1 ? "segment" : "segments") saved."
    }

    /// The post-recording pipeline's live status (docs/plans/swift-meeting-generation-flow.md,
    /// Track 2 "UI integration" #2) — rendered only while `processingCoordinator` is actively
    /// tracking THIS meeting. Every label reflects a real `MeetingProcessingCoordinator.Phase`;
    /// never a fabricated percentage or step (No-Fake-State). The coordinator itself was already
    /// kicked off by `RootSplitView`'s mount-independent `.onChange` the moment this phase became
    /// `.saved` — this section only observes it.
    @ViewBuilder
    private func processingStatusSection(meetingId: MeetingID) -> some View {
        if let coordinator = environment.processingCoordinator, coordinator.activeMeetingID == meetingId {
            VStack(spacing: MarginaliaSpacing.xs.value) {
                HStack(spacing: MarginaliaSpacing.sm.value) {
                    if isPipelineActive(coordinator.phase) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(processingStatusLabel(coordinator.phase))
                        .marginaliaTextStyle(.callout, in: scheme, ink: processingStatusInk(coordinator.phase))
                }
                // Honest, non-fatal note (decision 3): diarization hiccuped but the pipeline
                // continued to summary regardless — never a blocking error, just a soft banner.
                if let note = coordinator.diarizationNote {
                    Text(note)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func isPipelineActive(_ phase: MeetingProcessingCoordinator.Phase) -> Bool {
        switch phase {
        case .identifyingSpeakers, .selectingTemplate, .summarizing:
            true
        case .idle, .needsSpeakerCount, .completed, .skipped, .failed:
            false
        }
    }

    private func processingStatusLabel(_ phase: MeetingProcessingCoordinator.Phase) -> String {
        switch phase {
        case .idle:
            "" // unreachable here — this section only renders while a run is tracked/finished.
        case .identifyingSpeakers:
            "Identifying speakers…"
        case .needsSpeakerCount:
            "Waiting for a speaker count — see the prompt to continue."
        case .selectingTemplate:
            "Choosing a template…"
        case .summarizing:
            "Generating summary…"
        case .completed:
            "Processing complete."
        case let .skipped(message), let .failed(message):
            message
        }
    }

    private func processingStatusInk(_ phase: MeetingProcessingCoordinator.Phase) -> MarginaliaColorRole {
        // `.skipped` stays secondary ink: a recording with no speech is a fact, not a fault.
        if case .failed = phase { return .error }
        return .inkSecondary
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

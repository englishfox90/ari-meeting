//
//  ImportMeetingSheet.swift — the "import an existing recording" sheet (docs/plans/audio-import.md).
//
//  Owns the form state (picked file, title, and — the feature — the meeting's date & time); the
//  actual copy → transcribe → persist operation is delegated to `MeetingImportSession` (owned by
//  `AppEnvironment`). `RootSplitView` presents this sheet and, on the session reaching
//  `.saved(meetingID)`, dismisses + kicks the post-recording pipeline + navigates — mirroring the
//  recording `.saved` handler, so this view never touches the coordinator itself.
//
//  `AudioFileInfo` + the AVFoundation probe live here in the app target so `AriViewModels` stays
//  AVFoundation-free. No-Fake-State: duration/format/size shown are real (probed) or absent; the
//  progress states are the session's real stages; failures show the session's honest reason.
//
import AriKit
import AriViewModels
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Display-only metadata about a picked audio file (probed, never fabricated).
struct AudioFileInfo: Equatable {
    let url: URL
    let displayName: String
    let format: String
    let durationSeconds: Double?
    let byteSize: Int64?
    /// The file's own recording date (creation, falling back to last-modified), used as the smart
    /// default for the meeting date so an old recording doesn't default to "today". `nil` if the
    /// filesystem exposes neither.
    let recordedAt: Date?
}

/// Reads a picked file's real audio metadata. Returns `nil` when the file cannot be opened as
/// audio — an honest rejection at pick time, before any copy/transcribe is attempted.
enum AudioFileProbe {
    static func inspect(url: URL) -> AudioFileInfo? {
        // Duration is authoritative proof the file is real, openable audio; if `AVAudioFile`
        // can't open it, neither can the transcriber, so reject it now.
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : nil

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = attributes?[.size] as? Int64
        let recordedAt = (attributes?[.creationDate] as? Date)
            ?? (attributes?[.modificationDate] as? Date)

        return AudioFileInfo(
            url: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            format: url.pathExtension.uppercased(),
            durationSeconds: duration,
            byteSize: byteSize,
            recordedAt: recordedAt
        )
    }
}

struct ImportMeetingSheet: View {
    let session: MeetingImportSession
    /// Dismiss without importing (Cancel / swipe-down). The session keeps whatever terminal state
    /// it had; `RootSplitView` resets it on the next successful save.
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    @State private var pickedFile: AudioFileInfo?
    @State private var title: String = ""
    @State private var meetingDate: Date = .init()
    @State private var showFileImporter = false
    /// A pick-time error (couldn't read the chosen file), distinct from the session's import error.
    @State private var pickError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
            header

            if session.isImporting {
                importingView
            } else {
                form
                if let errorMessage {
                    MarginaliaBanner(kind: .error, message: errorMessage, scheme: scheme)
                }
                footer
            }
        }
        .padding(MarginaliaSpacing.xl.value)
        .frame(minWidth: 460)
        .fileImporter(
            isPresented: $showFileImporter,
            // `.audio` alone excludes MPEG-4/QuickTime containers (an `.mp4`/`.mov` is typed
            // `public.mpeg-4`/`.movie`, not audio) — yet those are what the app records into and
            // what the old importer accepted. Include the movie containers too; the `AudioFileProbe`
            // below still honestly rejects anything `AVAudioFile` can't open as audio.
            allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("Import a recording")
                .marginaliaTextStyle(.title2, in: scheme)
            Text("Ari transcribes the file on this device and saves it as a meeting. Set the date it "
                + "actually happened so it lands in the right place in your history.")
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
        }
    }

    @ViewBuilder
    private var form: some View {
        if let file = pickedFile {
            selectedFileCard(file)

            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Text("Meeting title")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                MarginaliaTextField(text: $title, prompt: "Meeting title", scheme: scheme)
            }

            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Text("When did this meeting happen?")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                DatePicker(
                    "",
                    selection: $meetingDate,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }
        } else {
            chooseFilePrompt
        }
    }

    private var chooseFilePrompt: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Button {
                showFileImporter = true
            } label: {
                Label("Choose audio file", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.marginalia(.secondary, .large, in: scheme))

            Text("Supported: \(MeetingImportSession.supportedExtensionsDisplay)")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
        }
    }

    private func selectedFileCard(_ file: AudioFileInfo) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.marginalia(.accent, in: scheme))
                Text(file.url.lastPathComponent)
                    .marginaliaTextStyle(.headline, in: scheme)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            HStack(spacing: MarginaliaSpacing.md.value) {
                if let duration = file.durationSeconds {
                    metaLabel(systemImage: "clock", text: Self.formatDuration(duration))
                }
                metaLabel(systemImage: "doc", text: file.format)
                if let size = file.byteSize {
                    metaLabel(systemImage: "internaldrive", text: Self.formatBytes(size))
                }
                Spacer(minLength: 0)
                Button("Choose a different file") { showFileImporter = true }
                    .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
        }
    }

    private func metaLabel(systemImage: String, text: String) -> some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            Image(systemName: systemImage)
            Text(text)
        }
        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
    }

    private var importingView: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                ProgressView()
                    .controlSize(.small)
                Text(stageLabel)
                    .marginaliaTextStyle(.body, in: scheme)
            }
            Text("Keep this window open until the import finishes.")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
        }
    }

    private var footer: some View {
        HStack(spacing: MarginaliaSpacing.md.value) {
            Button("Cancel") { onCancel() }
                .buttonStyle(.marginalia(.quiet, .large, in: scheme))
            Spacer(minLength: 0)
            Button("Import meeting") { startImport() }
                .buttonStyle(.marginalia(.primary, .large, in: scheme))
                .disabled(pickedFile == nil)
        }
    }

    // MARK: - Derived

    private var stageLabel: String {
        guard case let .importing(stage) = session.phase else { return "Importing…" }
        switch stage {
        case .preparing: return "Copying audio into your library…"
        case .transcribing: return "Transcribing on-device… this can take a while for long recordings."
        case .saving: return "Saving the meeting…"
        }
    }

    private var errorMessage: String? {
        if let pickError { return pickError }
        if case let .failed(reason) = session.phase { return reason }
        return nil
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let info = AudioFileProbe.inspect(url: url) else {
                pickError = "That file couldn’t be read as audio. Try a different recording."
                return
            }
            pickedFile = info
            pickError = nil
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = info.displayName
            }
            // Smart default: the file's own recording date (clamped to now, matching the picker's
            // range), so an imported old recording doesn't default to "today" — the user can still
            // adjust it. Falls back to the current default when the file exposes no date.
            if let recordedAt = info.recordedAt {
                meetingDate = min(recordedAt, Date())
            }
        case let .failure(error):
            pickError = "Could not open that file: \(error.localizedDescription)"
        }
    }

    private func startImport() {
        guard let file = pickedFile else { return }
        let url = file.url
        let title = title
        let meetingDate = meetingDate
        Task {
            // Hold the security scope across the whole async import (incl. the off-main copy), so a
            // future sandboxed build can still read the picked file. Harmless when unsandboxed
            // (`scoped` is then false and no scope is needed).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await session.importFile(at: url, title: title, meetingDate: meetingDate)
        }
    }

    // MARK: - Formatting

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

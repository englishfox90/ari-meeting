//
//  AudioAvailability.swift — honest audio-file resolution (plan §5, §7 Lane 1).
//
//  `Meeting.audioReference` wraps the recording *folder*; the audio file itself is
//  `<audioReference.path>/audio.mp4` (plan §5 URL resolution). `AudioAvailabilityResolver`
//  is a pure, `Sendable` function — no `FileManager` baked in — so it tests headlessly via
//  an injected `fileExists` closure instead of touching the real filesystem
//  (`MeetingDetailAudioTests`).
//
import AriKit
import Foundation

/// Whether a meeting's audio file resolved to a real, on-disk location (plan §2.3).
public enum AudioAvailability: Sendable, Equatable {
    case unresolved
    case available(URL)
    /// Honest reason the audio couldn't be resolved — never a dead scrubber with no
    /// explanation (No-Fake-State).
    case missing(String)
}

public enum AudioAvailabilityResolver {
    /// The audio file names a recording folder may contain, in resolution order:
    /// `audio.m4a` is what the native Swift recorder writes (`CaptureCoordinator.finish()`);
    /// `audio.mp4` is the frozen Rust app's name, present in the imported legacy library.
    public static let audioFileNames = ["audio.m4a", "audio.mp4"]

    /// Resolves a meeting's `audioReference` to `.available`/`.missing`, honestly. A `nil`
    /// reference resolves to `.missing` too (plan §5: "nil reference -> bar absent" is a
    /// VIEW-layer decision — this resolver only reports availability; the caller decides
    /// whether to render a bar at all based on `meeting.audioReference == nil`).
    public static func resolve(
        audioReference: LocalAudioReference?,
        fileExists: (URL) -> Bool
    ) -> AudioAvailability {
        guard let audioReference else {
            return .missing("This meeting has no recorded audio.")
        }

        // Two reference shapes exist: the legacy import stores the FULL FILE path
        // (`…/audio.mp4`, see ImporterFixtureTests), the native recorder stores the meeting
        // FOLDER. A path with an extension is treated as a direct file reference.
        let base = URL(fileURLWithPath: audioReference.path)
        if !base.pathExtension.isEmpty {
            return fileExists(base)
                ? .available(base)
                : .missing("Recording file not found at \(base.path)")
        }

        let folderURL = URL(fileURLWithPath: audioReference.path, isDirectory: true)
        for name in audioFileNames {
            let fileURL = folderURL.appendingPathComponent(name, isDirectory: false)
            if fileExists(fileURL) {
                return .available(fileURL)
            }
        }
        return .missing("No recording file found in \(folderURL.path)")
    }
}

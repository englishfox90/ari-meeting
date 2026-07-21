//
//  MeetingDetailAudioTests.swift — `.available` vs. honest `.missing` vs. `nil` reference
//  (docs/plans/arikit-native-read-ui.md §5, §7 Lane 1). Exercises the pure
//  `AudioAvailabilityResolver` headlessly via an injected `fileExists` closure — no real
//  filesystem access.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("AudioAvailabilityResolver")
struct MeetingDetailAudioTests {

    @Test("available when audio.mp4 exists at the referenced folder")
    func availableWhenFileExists() {
        let reference = LocalAudioReference(path: "/Users/owner/Recordings/meeting-1")
        let result = AudioAvailabilityResolver.resolve(audioReference: reference) { url in
            url.path == "/Users/owner/Recordings/meeting-1/audio.mp4"
        }
        guard case let .available(url) = result else {
            Issue.record("expected .available, got \(result)")
            return
        }
        #expect(url.path == "/Users/owner/Recordings/meeting-1/audio.mp4")
    }

    @Test("honest missing when audio.mp4 does not exist at the referenced folder")
    func missingWhenFileAbsent() {
        let reference = LocalAudioReference(path: "/Users/owner/Recordings/meeting-2")
        let result = AudioAvailabilityResolver.resolve(audioReference: reference) { _ in false }
        guard case let .missing(reason) = result else {
            Issue.record("expected .missing, got \(result)")
            return
        }
        #expect(reason.contains("/Users/owner/Recordings/meeting-2/audio.mp4"))
    }

    @Test("honest missing (never .available) when the meeting has no audio reference at all")
    func missingWhenReferenceIsNil() {
        let result = AudioAvailabilityResolver.resolve(audioReference: nil) { _ in true }
        guard case .missing = result else {
            Issue.record("expected .missing for a nil reference, got \(result)")
            return
        }
    }
}

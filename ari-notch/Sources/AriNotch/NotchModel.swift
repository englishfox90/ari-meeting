//
//  NotchModel.swift
//  ari-notch
//
//  Observable UI state, driven by decoded inbound messages. SwiftUI views
//  (the WS-C HUD, the placeholder) observe this. Mutations happen on the main
//  actor only — the stdin reader hops to `@MainActor` before calling `apply`.
//
//  `@Observable` (the Observation framework) requires macOS 14+, which is the
//  package platform floor. Well below the app's macOS 26 runtime floor.
//

import Foundation
import Observation

@MainActor
@Observable
final class NotchModel {

    // MARK: Recording

    var isRecording: Bool = false
    var isPaused: Bool = false
    var meetingName: String?
    var elapsedSeconds: UInt64 = 0
    var linkedEventId: String?

    // MARK: Upcoming meeting (prompt-to-record surface)

    var upcomingMeeting: UpcomingMeeting?

    // MARK: Live signals

    /// Latest transcribed line (text + optional speaker).
    var latestTranscript: (text: String, speaker: String?)?
    /// Instantaneous audio level, normalized 0.0–1.0.
    var audioLevel: Double = 0.0

    // MARK: Config

    var showTranscriptLine: Bool = true
    var theme: String = "dark"

    // MARK: - Inbound application

    /// Fold an inbound message into the model. Returns `false` for `.shutdown`
    /// so the caller can tear down; every other message returns `true`.
    @discardableResult
    func apply(_ message: NotchInbound) -> Bool {
        switch message {
        case let .upcomingMeeting(m):
            upcomingMeeting = m

        case let .dismissUpcoming(eventId):
            if upcomingMeeting?.eventId == eventId {
                upcomingMeeting = nil
            }

        case let .recordingState(s):
            isRecording = s.isRecording
            isPaused = s.isPaused
            meetingName = s.meetingName
            elapsedSeconds = s.elapsedSeconds
            linkedEventId = s.linkedEventId

        case let .audioLevel(level):
            audioLevel = level

        case let .transcriptLine(text, speaker):
            latestTranscript = (text, speaker)

        case let .config(showTranscriptLine, theme):
            self.showTranscriptLine = showTranscriptLine
            self.theme = theme

        case .shutdown:
            return false

        case .unknown:
            // Forward-compat: ignore unrecognized messages.
            break
        }
        return true
    }
}

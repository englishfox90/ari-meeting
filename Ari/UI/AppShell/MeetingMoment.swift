//
//  MeetingMoment.swift — a navigation value that opens a meeting AT a specific moment.
//
//  Pushing a plain `MeetingID` opens a meeting at its start; pushing a `MeetingMoment` opens the
//  same detail view but positions the audio scrubber at `seconds`. It's what a series ledger's
//  cross-meeting citation chip (`@mref`) navigates to — jump straight to the cited moment in the
//  source meeting. Distinct value type so it gets its own `navigationDestination` without
//  disturbing the bare-`MeetingID` push used everywhere else.
//
import AriKit
import Foundation

struct MeetingMoment: Hashable {
    let meetingId: MeetingID
    /// Recording-relative seconds to position the scrubber at on open.
    let seconds: Double
}

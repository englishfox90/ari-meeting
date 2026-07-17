//
//  NotchRootView.swift
//  ari-notch
//
//  Content router (moved verbatim out of main.swift for clarity — logic
//  UNCHANGED). Selects which panel content to show based on the shared
//  @Observable model. When a calendar meeting is imminent (`upcomingMeeting`
//  set), the UC1 prompt-to-record alert (WS-G) takes priority; otherwise the
//  UC2 recording HUD (WS-C) is shown. Because this is a SwiftUI `View`, reading
//  `model.upcomingMeeting` in `body` establishes an Observation dependency, so
//  the panel swaps reactively as inbound `upcoming_meeting` / `dismiss_upcoming`
//  messages fold into the model.
//
//  WS-H hosts this inside `IslandContainerView` (the black island chrome)
//  instead of the dropped DynamicNotchKit panel.
//

import SwiftUI

struct NotchRootView: View {
    var model: NotchModel
    let emitter: any NotchActionEmitter

    var body: some View {
        if model.upcomingMeeting != nil {
            UpcomingMeetingView(model: model, emitter: emitter)
        } else {
            RecordingHUDView(model: model, emitter: emitter)
        }
    }
}

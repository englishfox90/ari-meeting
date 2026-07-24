//
//  NotchRootView.swift — content router, ported verbatim (logic unchanged) from
//  ari-notch/Sources/AriNotch/NotchRootView.swift (docs/plans/notch-panel-absorption.md §2, §10
//  step 2).
//
//  Selects which panel content to show based on the shared `NotchOverlayModel`. When an
//  upcoming meeting is present (`model.upcomingMeeting`), the upcoming alert takes priority;
//  otherwise the recording HUD is shown. Because this is a SwiftUI `View`, reading
//  `model.upcomingMeeting` in `body` establishes an Observation dependency, so the panel swaps
//  reactively as `NotchUpcomingScheduler` (the live driver behind the upcoming seam) updates.
//
//  `IslandContainerView` hosts this inside the black island chrome.
//
import AriViewModels
import SwiftUI

struct NotchRootView: View {
    var model: NotchOverlayModel

    var body: some View {
        if model.upcomingMeeting != nil {
            NotchUpcomingMeetingView(model: model)
        } else {
            NotchRecordingHUDView(model: model)
        }
    }
}

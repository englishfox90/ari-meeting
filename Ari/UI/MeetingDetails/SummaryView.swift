//
//  SummaryView.swift — renders `Summary.bodyMarkdown`, or an honest "No summary yet" when
//  `nil` (plan §2.2 MeetingDetails, No-Fake-State).
//
import AriKit
import AriViewModels
import SwiftUI

struct SummaryView: View {
    let summary: Summary?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let summary {
            ScrollView {
                MarkdownText(markdown: summary.bodyMarkdown)
                    .padding(MarginaliaSpacing.md.value)
            }
        } else {
            VStack(spacing: MarginaliaSpacing.xs.value) {
                Text("No summary yet")
                    .marginaliaTextStyle(.body, in: scheme)
                Text("A summary hasn't been generated for this meeting.")
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(MarginaliaSpacing.xl.value)
        }
    }
}

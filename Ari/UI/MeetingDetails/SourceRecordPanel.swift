//
//  SourceRecordPanel.swift — provenance for the meeting's source record: how it was transcribed,
//  which model wrote the summary, and how many transcript segments exist.
//
//  Every row is backed by a real field — a row is omitted entirely when its value is absent,
//  never shown as "Unknown" or a fabricated default (No-Fake-State).
//
import AriKit
import SwiftUI

struct SourceRecordPanel: View {
    let meeting: Meeting
    let summary: Summary?
    let segmentCount: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Text("Source record")
                    .marginaliaTextStyle(.caption, in: scheme)
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    ForEach(rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline, spacing: MarginaliaSpacing.sm.value) {
                            Text(row.label)
                                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                                .frame(width: 96, alignment: .leading)
                            Text(row.value)
                                .marginaliaTextStyle(.callout, in: scheme, ink: .inkBody)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(MarginaliaSpacing.md.value)
        }
    }

    private struct Row {
        let label: String
        let value: String
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let transcription = provenance(meeting.transcriptionProvider, meeting.transcriptionModel) {
            rows.append(Row(label: "Transcription", value: transcription))
        }
        if let summaryModel = provenance(
            summary?.provider ?? meeting.summaryProvider,
            summary?.model ?? meeting.summaryModel
        ) {
            rows.append(Row(label: "Summary model", value: summaryModel))
        }
        if segmentCount > 0 {
            rows.append(Row(label: "Segments", value: "\(segmentCount)"))
        }
        return rows
    }

    /// "Provider · model", "provider", or "model" — whichever parts exist; `nil` when neither.
    private func provenance(_ provider: String?, _ model: String?) -> String? {
        let parts = [provider, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}

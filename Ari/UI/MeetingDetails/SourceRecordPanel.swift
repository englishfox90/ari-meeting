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
        if let summaryModel = summaryProvenance(
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

    /// The user-facing summary-model name — Settings-aligned and free of internal ids. Known
    /// providers get their friendly label (the same copy the Settings model picker shows); the
    /// on-device Qwen repo id is dropped (the label already conveys it, mirroring how transcription
    /// shows "Apple Speech" not the asset id). A user-set Claude CLI model override is kept visible.
    /// Everything else falls back to the generic "provider · model" shape.
    private func summaryProvenance(_ providerRaw: String?, _ modelRaw: String?) -> String? {
        let provider = providerRaw?.trimmingCharacters(in: .whitespaces)
        let model = modelRaw?.trimmingCharacters(in: .whitespaces) ?? ""

        if let provider, let kind = ProviderKind.from(provider) {
            switch kind {
            case .mlx:
                return "Qwen 4B (on-device)"
            case .claudeCLI:
                return model.isEmpty ? "Claude CLI" : "Claude CLI · \(model)"
            default:
                break
            }
        }
        return provenance(providerRaw, modelRaw)
    }

    /// "Provider · model", "provider", or "model" — whichever parts exist; `nil` when neither.
    private func provenance(_ provider: String?, _ model: String?) -> String? {
        let parts = [provider.map(Self.displayProviderName), model]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Map internal provider ids to the user-facing name. The Apple on-device transcriber is stored
    /// as `speech-transcriber` (live path) / `speechanalyzer` (AriKit provider) but shown as
    /// "Apple Speech" — the same label the Settings engine card uses. Unknown ids pass through.
    private static func displayProviderName(_ raw: String) -> String {
        switch raw {
        case "speech-transcriber", "speechanalyzer":
            "Apple Speech"
        default:
            raw
        }
    }
}

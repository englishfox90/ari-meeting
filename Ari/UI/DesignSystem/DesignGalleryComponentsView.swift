#if DEBUG
//
    //  DesignGalleryComponentsView.swift — section 6 of `DesignGalleryView` (DEBUG only): the
    //  real `SectionHeader` / `CardRow` / `StateContainer` app components, not re-implementations.
//
    import AriKit
    import AriViewModels
    import SwiftUI

    /// Local, gallery-only sample item — a simple `Identifiable` to drive the `CardListScaffold`
    /// sample without depending on a real domain model.
    private struct GallerySampleCardItem: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let metadata: String?
    }

    struct DesignGalleryComponentsSection: View {
        let scheme: ColorScheme
        let glass: Bool

        private let sampleNames = ["Dana Kim", "Priya Shah", "Elliott Marsh"]

        /// A deterministic 32-bucket signature so the gallery shows a real voiceprint ring rather
        /// than the placeholder dot — demo data only, not a fabricated live value.
        private static let sampleVoiceprintSignature: [Float] = (0 ..< 32).map { i in
            let x = Double(i)
            let value = 0.5 + 0.35 * sin(x * 0.9) + 0.12 * cos(x * 2.3)
            return Float(value)
        }

        private let sampleTranscriptLines: [Transcript] = [
            Transcript(
                id: "gallery-transcript-1",
                meetingId: "gallery-meeting",
                transcript: "Let's start with the roadmap review — where are we on the Q3 milestones?",
                timestamp: "00:00",
                audioStartTime: 4.0
            ),
            Transcript(
                id: "gallery-transcript-2",
                meetingId: "gallery-meeting",
                transcript: "On track. The Store port lands this week; Recall UI is next.",
                timestamp: "00:12",
                audioStartTime: 91.6
            )
        ]

        private let sampleCardItems: [GallerySampleCardItem] = [
            GallerySampleCardItem(id: "1", title: "1:1 with Dana", metadata: "Yesterday · 32 min"),
            GallerySampleCardItem(id: "2", title: "Weekly sync", metadata: "Recurring · Thursdays"),
            GallerySampleCardItem(id: "3", title: "Design review", metadata: "3 attendees")
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                SectionHeader(title: "COMPONENTS")

                Text("SectionHeader + CardRow")
                    .marginaliaTextStyle(.callout, in: scheme)
                surfaceCard

                Text("StateContainer — all four LoadState cases")
                    .marginaliaTextStyle(.callout, in: scheme)
                stateContainerGrid

                Text("TranscriptSegmentRow")
                    .marginaliaTextStyle(.callout, in: scheme)
                transcriptSegmentRowSample

                Text("CardListScaffold")
                    .marginaliaTextStyle(.callout, in: scheme)
                cardListScaffoldSample
            }
        }

        private var transcriptSegmentRowSample: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sampleTranscriptLines) { line in
                    TranscriptSegmentRow(
                        line: line,
                        speakerName: "Priya Shah",
                        speakerSignature: Self.sampleVoiceprintSignature,
                        onSeek: { _ in }
                    )
                }
            }
            .padding(MarginaliaSpacing.md.value)
            .galleryComponentSurface(glass: glass, scheme: scheme)
        }

        private var cardListScaffoldSample: some View {
            NavigationStack {
                CardListScaffold(
                    state: .loaded(sampleCardItems),
                    emptyTitle: "No items yet",
                    emptyMessage: "Sample empty state for the gallery.",
                    navigationTitle: "Sample list",
                    destination: { $0.id },
                    rowTitle: { $0.title },
                    rowMetadata: { $0.metadata }
                )
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
            )
        }

        private var surfaceCard: some View {
            VStack(alignment: .leading, spacing: 0) {
                CardRow(title: "1:1 with Dana", metadata: "Yesterday · 32 min")
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                CardRow(title: "Weekly sync", metadata: "Recurring · Thursdays")
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                CardRow(title: "Design review", metadata: "3 attendees")
            }
            .galleryComponentSurface(glass: glass, scheme: scheme)
        }

        private var stateContainerGrid: some View {
            VStack(spacing: MarginaliaSpacing.md.value) {
                stateContainerSample(title: "Loading", state: .loading)
                stateContainerSample(title: "Loaded", state: .loaded(sampleNames))
                stateContainerSample(title: "Empty", state: .empty)
                stateContainerSample(
                    title: "Failed",
                    state: .failed("The database connection was lost.")
                )
            }
        }

        private func stateContainerSample(title: String, state: LoadState<[String]>) -> some View {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(title)
                    .marginaliaTextStyle(.caption, in: scheme)
                StateContainer(
                    state: state,
                    emptyTitle: "No people yet",
                    emptyMessage: "Sample empty state for the gallery."
                ) { names in
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        ForEach(names, id: \.self) { name in
                            Text(name).marginaliaTextStyle(.body, in: scheme)
                        }
                    }
                    .padding(MarginaliaSpacing.md.value)
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .background(Color.marginalia(.surface, in: scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous))
            }
        }
    }
#endif

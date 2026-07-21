#if DEBUG
//
//  DesignGalleryComponentsView.swift — section 6 of `DesignGalleryView` (DEBUG only): the
//  real `SectionHeader` / `CardRow` / `StateContainer` app components, not re-implementations.
//
import AriKit
import AriViewModels
import SwiftUI

struct DesignGalleryComponentsSection: View {
    let scheme: ColorScheme
    let glass: Bool

    private let sampleNames = ["Dana Kim", "Priya Shah", "Elliott Marsh"]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "COMPONENTS")

            Text("SectionHeader + CardRow")
                .marginaliaTextStyle(.callout, in: scheme)
            surfaceCard

            Text("StateContainer — all four LoadState cases")
                .marginaliaTextStyle(.callout, in: scheme)
            stateContainerGrid
        }
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

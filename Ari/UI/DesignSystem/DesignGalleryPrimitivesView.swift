#if DEBUG
//
//  DesignGalleryPrimitivesView.swift — Tier-1 AriKit/DesignSystem primitives gallery
//  section (DEBUG only), docs/plans/arikit-component-library.md §5/§6.
//
//  Renders every Tier-1 primitive LIVE with real `@State` bindings — field/search text,
//  toggle, segmented selection, menu selection — plus static badge/banner style matrices.
//
import AriKit
import SwiftUI

struct DesignGalleryPrimitivesSection: View {
    let scheme: ColorScheme
    let glass: Bool

    @State private var fieldText = ""
    @State private var searchText = ""
    @State private var toggleOn = true
    @State private var segmentSelection = "Transcript"
    @State private var menuSelection = "Newest first"

    private let segments = [
        MarginaliaSegment(value: "Transcript", title: "Transcript"),
        MarginaliaSegment(value: "Summary", title: "Summary"),
        MarginaliaSegment(value: "Notes", title: "Notes"),
    ]

    private let menuOptions = ["Newest first", "Oldest first", "By speaker"]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "PRIMITIVES")

            Text("Text field / search field")
                .marginaliaTextStyle(.callout, in: scheme)
            fieldsRow

            Text("Menu label")
                .marginaliaTextStyle(.callout, in: scheme)
            menuRow

            Text("Segmented control")
                .marginaliaTextStyle(.callout, in: scheme)
            MarginaliaSegmentedControl(selection: $segmentSelection, segments: segments, scheme: scheme)

            Text("Toggle row")
                .marginaliaTextStyle(.callout, in: scheme)
            toggleRow

            Text("Badges")
                .marginaliaTextStyle(.callout, in: scheme)
            badgesRow

            Text("Banners")
                .marginaliaTextStyle(.callout, in: scheme)
            bannersColumn
        }
    }

    private var fieldsRow: some View {
        HStack(spacing: MarginaliaSpacing.md.value) {
            MarginaliaTextField(text: $fieldText, prompt: "Meeting title", scheme: scheme)
            MarginaliaSearchField(text: $searchText, prompt: "Search meetings", scheme: scheme) {}
        }
    }

    private var menuRow: some View {
        Menu {
            ForEach(menuOptions, id: \.self) { option in
                Button(option) { menuSelection = option }
            }
        } label: {
            MarginaliaMenuLabel(title: menuSelection, scheme: scheme)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: 220)
    }

    private var toggleRow: some View {
        MarginaliaToggleRow(
            "Auto-suggest a template",
            description: "Match the summary format to the meeting's call type.",
            isOn: $toggleOn,
            scheme: scheme
        )
    }

    private var badgesRow: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            MarginaliaBadge("Draft", style: .neutral, scheme: scheme)
            MarginaliaBadge("[S1]", style: .accent, symbol: "text.quote", scheme: scheme) {}
            MarginaliaBadge("Confirmed", style: .success, scheme: scheme)
            MarginaliaBadge("Recording", style: .recording, scheme: scheme)
        }
    }

    private var bannersColumn: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            MarginaliaBanner(kind: .info, message: "Calendar sync runs every 15 minutes.", scheme: scheme)
            MarginaliaBanner(kind: .success, message: "Speaker identity confirmed.", scheme: scheme)
            MarginaliaBanner(
                kind: .error,
                message: "Could not reach the local model.",
                action: (title: "Retry", handler: {}),
                scheme: scheme
            )
        }
        .padding(MarginaliaSpacing.md.value)
        .galleryComponentSurface(glass: glass, scheme: scheme)
    }
}
#endif

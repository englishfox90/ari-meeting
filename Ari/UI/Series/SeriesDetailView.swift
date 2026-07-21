//
//  SeriesDetailView.swift — series ledger render + member meetings (plan §2.2 Series, §9 S6f).
//
import AriKit
import AriViewModels
import SwiftUI

struct SeriesDetailView: View {
    let database: AppDatabase
    let seriesId: SeriesID

    @State private var viewModel: SeriesDetailViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, seriesId: SeriesID) {
        self.database = database
        self.seriesId = seriesId
        _viewModel = State(initialValue: SeriesDetailViewModel(database: database))
    }

    // No own `NavigationStack`: this view is pushed onto the shell's outer stack, which owns the
    // `navigationDestination(for: MeetingID.self)`. Member-meeting rows push via `NavigationLink
    // (value:)` so back-navigation and the toolbar stay consistent (no nested stack / double bar).
    var body: some View {
        StateContainer(
            state: viewModel.series,
            emptyTitle: "No series",
            emptyMessage: nil
        ) { series in
            content(for: series)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle(viewModel.series.value?.title ?? "Series")
        .task(id: seriesId) {
            await viewModel.load(seriesId)
        }
    }

    private func content(for series: Series) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                header(for: series)
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                ledgerSection(for: series)
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                meetingsSection
            }
            .padding(MarginaliaSpacing.md.value)
        }
    }

    private func header(for series: Series) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(series.title)
                .marginaliaTextStyle(.title1, in: scheme)
            if let detectedType = series.detectedType {
                Text(detectedType)
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            if let cadence = series.cadence {
                Text(cadence)
                    .marginaliaTextStyle(.callout, in: scheme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func ledgerSection(for series: Series) -> some View {
        SectionHeader(title: "Ledger")
        if let ledgerMarkdown = series.ledgerMarkdown, !ledgerMarkdown.isEmpty {
            MarkdownText(markdown: ledgerMarkdown)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        } else {
            Text("No ledger yet")
                .marginaliaTextStyle(.callout, in: scheme)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        }
    }

    @ViewBuilder
    private var meetingsSection: some View {
        SectionHeader(title: "Meetings")
        if viewModel.memberMeetings.isEmpty {
            Text("No meetings in this series yet.")
                .marginaliaTextStyle(.callout, in: scheme)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        } else {
            VStack(spacing: 0) {
                ForEach(viewModel.memberMeetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        CardRow(
                            title: meeting.title,
                            metadata: meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

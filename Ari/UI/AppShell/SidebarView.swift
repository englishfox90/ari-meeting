//
//  SidebarView.swift — the left rail (sidebar rework): wordmark, global search, WORKBENCH
//  nav, MEETING LEDGER recents, and a pinned bottom action stack. SF Symbols only — never
//  emoji.
//
//  ONE material owns the rail: the stock NavigationSplitView sidebar material (brand §10 —
//  "the system applies the sidebar material; never replace it"). No view here paints its
//  own `.regularMaterial`; the earlier version layered three, which read as mismatched
//  bands at the top and bottom. Pinned regions are laid out with a plain `VStack` (not
//  `safeAreaInset`), so scroll content never slides underneath and nothing needs a
//  backdrop of its own.
//
//  Search is the rail's global find (Apple Music's pattern): typing swaps the nav for
//  grouped matches — meetings, people, series — by title/name only (transcript-content
//  search is the Ask surface, not this field). Rows push real detail screens via the
//  shared `NavigationStack` callbacks.
//
//  Still a hand-built rail (not `List(selection:)`) so the selected WORKBENCH row can get
//  the exact accent + `selectionWash` treatment, and so ledger/search rows can push
//  without their own selection state.
//
import AriKit
import AriViewModels
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection
    let database: AppDatabase
    let onSelectMeeting: (MeetingID) -> Void
    let onSelectPerson: (PersonID) -> Void
    let onSelectSeries: (SeriesID) -> Void

    @State private var viewModel: HomeViewModel
    @State private var searchViewModel: SidebarSearchViewModel
    @State private var query = ""
    @Environment(\.colorScheme) private var scheme

    init(
        selection: Binding<SidebarSection>,
        database: AppDatabase,
        onSelectMeeting: @escaping (MeetingID) -> Void,
        onSelectPerson: @escaping (PersonID) -> Void,
        onSelectSeries: @escaping (SeriesID) -> Void
    ) {
        _selection = selection
        self.database = database
        self.onSelectMeeting = onSelectMeeting
        self.onSelectPerson = onSelectPerson
        self.onSelectSeries = onSelectSeries
        _viewModel = State(initialValue: HomeViewModel(database: database))
        _searchViewModel = State(initialValue: SidebarSearchViewModel(database: database))
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            wordmark
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xl.value) {
                    if isSearching {
                        searchResults
                    } else {
                        workbenchSection
                        ledgerSection
                    }
                }
                .padding(.top, MarginaliaSpacing.md.value)
                .padding(.bottom, MarginaliaSpacing.md.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            pinnedBottom
        }
        .navigationTitle("")
        .task { await viewModel.observe() }
        .onChange(of: query) { _, newValue in
            searchViewModel.search(newValue)
        }
    }

    /// The Dictation mark + "Ari Meetings". Top padding clears the floating traffic lights
    /// under the frameless/unified title bar.
    private var wordmark: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 30)
                .foregroundStyle(Color.marginalia(.accent, in: scheme))
            Text("Ari Meetings")
                .marginaliaTextStyle(.headline, in: scheme)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.xxl.value)
        .padding(.bottom, MarginaliaSpacing.sm.value)
    }

    private var searchField: some View {
        MarginaliaSearchField(text: $query, prompt: "Search", scheme: scheme)
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.bottom, MarginaliaSpacing.xs.value)
    }

    // MARK: - Workbench + ledger (default rail)

    private var workbenchSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            SectionHeader(title: "WORKBENCH")
            ForEach(SidebarSection.workbench) { section in
                workbenchRow(section)
            }
        }
    }

    private func workbenchRow(_ section: SidebarSection) -> some View {
        let isSelected = section == selection
        return Button {
            selection = section
        } label: {
            Label(section.title, systemImage: section.symbolName)
                .marginaliaTextStyle(.body, in: scheme, ink: isSelected ? .accent : .inkBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, MarginaliaSpacing.xs.value)
                .padding(.horizontal, MarginaliaSpacing.sm.value)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                            .fill(Color.marginalia(.selectionWash, in: scheme))
                    }
                }
                // Unselected rows have no fill, and `.plain` buttons only hit-test opaque
                // pixels — without an explicit content shape, only the text/symbol is
                // clickable, not the full row.
                .contentShape(RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MarginaliaSpacing.sm.value)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            SectionHeader(title: "MEETING LEDGER")
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, MarginaliaSpacing.md.value)
            case let .loaded(meetings):
                ForEach(meetings) { meeting in
                    railRow(meeting.title) { onSelectMeeting(meeting.id) }
                }
            case .empty:
                Text("No meetings yet")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    .padding(.horizontal, MarginaliaSpacing.md.value)
            case let .failed(message):
                Text(message)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
                    .padding(.horizontal, MarginaliaSpacing.md.value)
            }
        }
    }

    // MARK: - Search results

    /// Grouped matches replace the nav while a query is live. Copy is honest: a no-match
    /// query says so plainly, and a failed read shows the real error, never blank results.
    @ViewBuilder
    private var searchResults: some View {
        if let failureMessage = searchViewModel.failureMessage {
            Text(failureMessage)
                .marginaliaTextStyle(.callout, in: scheme, ink: .error)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        } else if searchViewModel.results.isEmpty {
            Text("Nothing matches \u{201C}\(query)\u{201D}.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        } else {
            let results = searchViewModel.results
            if !results.meetings.isEmpty {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    SectionHeader(title: "MEETINGS")
                    ForEach(results.meetings) { meeting in
                        railRow(meeting.title) { onSelectMeeting(meeting.id) }
                    }
                }
            }
            if !results.persons.isEmpty {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    SectionHeader(title: "PEOPLE")
                    ForEach(results.persons) { person in
                        railRow(person.displayName) { onSelectPerson(person.id) }
                    }
                }
            }
            if !results.series.isEmpty {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    SectionHeader(title: "SERIES")
                    ForEach(results.series) { series in
                        railRow(series.title) { onSelectSeries(series.id) }
                    }
                }
            }
        }
    }

    /// Shared plain rail row — used by the ledger and every search group. Padding lives
    /// INSIDE the button label (plus an explicit content shape) so the entire row is
    /// clickable, not just the text's own pixels.
    private func railRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkBody)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, MarginaliaSpacing.xs.value)
                .padding(.horizontal, MarginaliaSpacing.md.value)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// New meeting / Import audio route to the honest `.newMeeting` placeholder — capture
    /// isn't built yet (No-Fake-State). Settings/About have no destination at all yet, so
    /// they render as explicitly disabled rows rather than claiming one (finding #14 — a
    /// Label alone reads as an enabled row to assistive tech).
    private var pinnedBottom: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Divider().overlay(Color.marginalia(.hairline, in: scheme))

            // Accent (primary), NOT recording-red: recording-red is reserved for the LIVE capture
            // state only (brand Signal Rule) — this is the affordance to begin, so it's the one
            // primary action on the rail.
            Button("New meeting") {
                selection = .newMeeting
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.top, MarginaliaSpacing.sm.value)

            Button {
                selection = .newMeeting
            } label: {
                Label("Import audio", systemImage: "square.and.arrow.down")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MarginaliaSpacing.md.value)

            Button {} label: {
                Label("Settings", systemImage: "gearshape")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityRemoveTraits(.isButton)
            .padding(.horizontal, MarginaliaSpacing.md.value)

            Button {} label: {
                HStack {
                    Label("About", systemImage: "info.circle")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    Spacer(minLength: MarginaliaSpacing.sm.value)
                    Text(Self.appVersionString)
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityRemoveTraits(.isButton)
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.bottom, MarginaliaSpacing.sm.value)
        }
    }

    /// The app's real `CFBundleShortVersionString` (No-Fake-State — never a fabricated version
    /// number). Falls back to an honest placeholder if the bundle has no version yet.
    private static var appVersionString: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "v—"
        }
        return "v\(version)"
    }
}

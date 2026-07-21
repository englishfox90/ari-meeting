//
//  SidebarView.swift — the left rail: wordmark, WORKBENCH nav, MEETING LEDGER recents, and a
//  pinned bottom action stack (home + left-rail rework). SF Symbols only — never emoji.
//
//  A hand-built rail (not `List(selection:)`) so the selected WORKBENCH row can get the exact
//  accent + `selectionWash` treatment the reference layout calls for, and so the MEETING
//  LEDGER rows can push straight onto the shared detail `NavigationStack` via `onSelectMeeting`
//  without needing their own selection state.
//
import AriKit
import AriViewModels
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection
    let database: AppDatabase
    let onSelectMeeting: (MeetingID) -> Void

    @State private var viewModel: HomeViewModel
    @Environment(\.colorScheme) private var scheme

    init(selection: Binding<SidebarSection>, database: AppDatabase, onSelectMeeting: @escaping (MeetingID) -> Void) {
        _selection = selection
        self.database = database
        self.onSelectMeeting = onSelectMeeting
        _viewModel = State(initialValue: HomeViewModel(database: database))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xl.value) {
                workbenchSection
                ledgerSection
            }
            .padding(.bottom, MarginaliaSpacing.md.value)
        }
        .safeAreaInset(edge: .top, spacing: 0) { wordmark }
        .safeAreaInset(edge: .bottom, spacing: 0) { pinnedBottom }
        // Stock translucent system material, not a flat Marginalia surface — the macOS 26 sidebar
        // reads as system Liquid Glass chrome (docs/plans/liquid-glass-adoption.md §2). Still
        // satisfies the two-world rail↔canvas separation; content stays opaque `.canvas`.
        .background(.regularMaterial)
        .navigationTitle("")
        .task { await viewModel.observe() }
    }

    /// The Dictation mark + "Ari Meetings", with a small uppercase eyebrow beneath. Top padding
    /// clears the floating traffic lights under the frameless/unified title bar.
    private var wordmark: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
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
            Text("LOCAL MEETING DESK")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.xxl.value)
        .padding(.bottom, MarginaliaSpacing.sm.value)
        .background(.regularMaterial)
    }

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
                    ledgerRow(meeting)
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

    private func ledgerRow(_ meeting: Meeting) -> some View {
        Button {
            onSelectMeeting(meeting.id)
        } label: {
            Text(meeting.title)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkBody)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, MarginaliaSpacing.xs.value)
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }

    /// New meeting / Import audio route to the honest `.newMeeting` placeholder — capture
    /// isn't built yet (No-Fake-State), so these buttons take the owner to the same "coming
    /// soon" screen rather than pretending to start/import anything. Settings/About have no
    /// destination at all yet, so they render as explicitly disabled rows rather than claiming
    /// one (finding #14 — a Label alone reads as an enabled row to assistive tech).
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
        .background(.regularMaterial)
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

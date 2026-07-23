//
//  HomeView.swift — the Home screen (Apple Music-inspired shelf layout, Marginalia language).
//
//  Structure borrows Apple Music's home grammar — bold Bricolage section headers, a
//  horizontally scrolling "Recent meetings" shelf, and a browse-style destination grid —
//  rendered in the two-ink paper system instead of photo tiles (warm surfaces, hairlines,
//  Shin-kai only where you can act).
//
//  Everything on the page is real state (No-Fake-State): the date is today's date, the
//  ledger line and grid counts come from the repositories via `HomeViewModel`, and the
//  Ask/Calendar tiles say plainly that those destinations aren't built yet — their routes
//  land on the same honest placeholders the sidebar uses. Capture isn't built either, so
//  the hero's button routes to the `.newMeeting` placeholder rather than pretending to
//  record.
//
import AriKit
import AriViewModels
import SwiftUI

struct HomeView: View {
    let database: AppDatabase
    /// `nil` until `AppEnvironment.bootstrap()` constructs the real session — the calendar brief's
    /// Record buttons stay honestly disabled until then, same posture as the Calendar page.
    let recordingSession: RecordingSession?
    @Binding var selection: SidebarSection

    @State private var viewModel: HomeViewModel
    @State private var brief: CalendarBriefViewModel
    @Environment(\.colorScheme) private var scheme

    /// Reading measure for the page — shelves and grids stay calm instead of stretching
    /// edge-to-edge on wide windows.
    private static let contentMaxWidth: CGFloat = 920

    init(
        database: AppDatabase,
        calendarSource: (any CalendarSourcing)?,
        recordingSession: RecordingSession?,
        selection: Binding<SidebarSection>
    ) {
        self.database = database
        self.recordingSession = recordingSession
        _selection = selection
        _viewModel = State(initialValue: HomeViewModel(database: database))
        _brief = State(initialValue: CalendarBriefViewModel(database: database, source: calendarSource))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xxl.value) {
                header
                captureHero
                CalendarBriefSection(
                    viewModel: brief,
                    scheme: scheme,
                    canRecord: recordingSession != nil && !(recordingSession?.isActive ?? true),
                    onRecord: { startMeeting(from: $0) }
                )
                recentShelf
                recordGrid
                localFootnote
            }
            .padding(MarginaliaSpacing.xl.value)
            .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Soft scroll-edge effect keeps the header legible as it scrolls under the floating
        // title-bar chrome; the ambient wash (canvas → elevated) gives the glass sidebar and
        // toolbar tonal variation to refract (liquid-glass-adoption.md v2).
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle("Home")
        .task { await viewModel.observe() }
        // Re-reads on every appearance against a fresh `now` — a meeting that has since started or
        // passed re-sorts or drops off the brief when the owner returns to Home.
        .task { await brief.load() }
    }

    // MARK: - Calendar brief → recording handoff

    /// Start a recording pre-named after a calendar event, mirroring `CalendarPageView.startMeeting`
    /// exactly (S7 Slice 3 handoff): reset a parked terminal session, seed the title only when the
    /// field is blank, attach the pending calendar link, then route to the recording page. The
    /// `canRecord` gate already disables the button while active/pre-bootstrap; this re-guards
    /// defensively so a stale tap can never start a second recording.
    private func startMeeting(from event: CalendarEvent) {
        guard let recordingSession, !recordingSession.isActive else { return }
        recordingSession.reset()
        if recordingSession.pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordingSession.pendingTitle = event.title
        }
        recordingSession.pendingCalendarLink = RecordingSession.PendingCalendarLink(
            eventId: event.id, eventTitle: event.title
        )
        selection = .newMeeting
    }

    // MARK: - Header

    /// A notebook page opens with the date. The title is a time-of-day greeting to the
    /// owner — the sanctioned Home-only exception to "the largest type names the work"
    /// (brand §5, owner decision 2026-07-20). The greeting phrase renders in Shin-kai, the
    /// name in heading ink; the ledger line beneath is the library's true size in tabular
    /// SF Mono — a ledger, not a boast.
    private var header: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text(Date.now.formatted(date: .complete, time: .omitted))
                .marginaliaTextStyle(.caption, in: scheme)
            greetingTitle
            Text(ledgerLine)
                .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
        }
    }

    /// The two-ink greeting, built from concatenated `Text` runs so the phrase and the
    /// name can carry different inks inside one display-size line.
    private var greetingTitle: some View {
        var line = Text(greetingPhrase)
            .foregroundStyle(Color.marginalia(.accent, in: scheme))
        if let name = ownerFirstName {
            line = line
                + Text(", ").foregroundStyle(Color.marginalia(.accent, in: scheme))
                + Text(name).foregroundStyle(Color.marginalia(.inkHeading, in: scheme))
        }
        return line.font(MarginaliaTextStyle.display.font)
    }

    /// Deterministic time-of-day greeting — a fixed list, not a generated line, so it's
    /// instant, offline, and never theatrical.
    private var greetingPhrase: String {
        switch Calendar.current.component(.hour, from: Date.now) {
        case 5 ..< 12: "Good morning"
        case 12 ..< 18: "Good afternoon"
        case 18 ..< 23: "Good evening"
        default: "Hello"
        }
    }

    /// The owner's first name, from the owner profile only (persons table, `isOwner`). The
    /// profile is seeded from the macOS account name at launch (`AppEnvironment.bootstrap`), so
    /// this reflects whatever the user has authored in the People owner card — editing the name
    /// there drives the greeting. `nil`/blank (no owner, or an owner whose name was cleared)
    /// renders the greeting phrase alone — never a placeholder name.
    private var ownerFirstName: String? {
        guard let full = viewModel.ownerName,
              let first = full.split(separator: " ").first, !first.isEmpty else { return nil }
        return String(first)
    }

    private var ledgerLine: String {
        [
            counted(viewModel.meetingCount, "meeting", "meetings"),
            counted(viewModel.personCount, "person", "people"),
            counted(viewModel.seriesCount, "series", "series")
        ].joined(separator: " · ")
    }

    private func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    // MARK: - Capture hero

    /// The one primary action on the page. No Dictation mark here — the wordmark already
    /// carries it in the rail, and one more copy on the hero read as repetition.
    private var captureHero: some View {
        HStack(alignment: .center, spacing: MarginaliaSpacing.lg.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text("Start a meeting")
                    .marginaliaTextStyle(.title2, in: scheme)
                Text("Record system and microphone audio without adding a bot to the call.")
                    .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            }
            Spacer(minLength: MarginaliaSpacing.lg.value)
            Button("New meeting") {
                selection = .newMeeting
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
        }
        .padding(MarginaliaSpacing.lg.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.dialog.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.dialog.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }

    // MARK: - Recent meetings shelf

    /// Bold Bricolage section header (the Apple Music note) — not an uppercase eyebrow.
    private func shelfHeader(_ title: String, viewAll: SidebarSection? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .marginaliaTextStyle(.title2, in: scheme)
            Spacer()
            if let viewAll {
                Button("View all") {
                    selection = viewAll
                }
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            }
        }
    }

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            shelfHeader("Recent meetings", viewAll: .savedMeetings)
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(MarginaliaSpacing.lg.value)
            case let .loaded(meetings):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MarginaliaSpacing.md.value) {
                        ForEach(meetings) { meeting in
                            shelfCard(meeting)
                        }
                    }
                }
                .scrollClipDisabled()
            case .empty:
                emptyLibrary
            case let .failed(message):
                Text(message)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
            }
        }
    }

    private func shelfCard(_ meeting: Meeting) -> some View {
        NavigationLink(value: meeting.id) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Text(meeting.title)
                    .marginaliaTextStyle(.headline, in: scheme)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
            }
            .padding(MarginaliaSpacing.md.value)
            .frame(width: 208, height: 112, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.surface, in: scheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                            .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    /// The empty state renders the mark in secondary ink — the sanctioned de-emphasized
    /// rendering for a placeholder (brand §6) — with the brand's own empty-library copy.
    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 56)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text("No meetings yet. Record one, or import an audio file.")
                .marginaliaTextStyle(.callout, in: scheme)
        }
        .padding(.vertical, MarginaliaSpacing.md.value)
    }

    // MARK: - The record grid

    /// The browse grid (Apple Music's category grid, in ink): every corner of the record,
    /// each tile carrying its true count. Unbuilt destinations state that plainly instead
    /// of a count — their tiles still route, to the same honest placeholders as the sidebar.
    private var recordGrid: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            shelfHeader("Your record")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: MarginaliaSpacing.md.value)],
                alignment: .leading,
                spacing: MarginaliaSpacing.md.value
            ) {
                recordTile(.savedMeetings, detail: counted(viewModel.meetingCount, "meeting", "meetings"))
                recordTile(.people, detail: counted(viewModel.personCount, "person", "people"))
                recordTile(.series, detail: counted(viewModel.seriesCount, "series", "series"))
            }
        }
    }

    private func recordTile(_ section: SidebarSection, detail: String, isBuilt: Bool = true) -> some View {
        Button {
            selection = section
        } label: {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.marginalia(isBuilt ? .accent : .inkSecondary, in: scheme))
                Spacer(minLength: 0)
                Text(section.title)
                    .marginaliaTextStyle(.subheadline, in: scheme)
                if isBuilt {
                    Text(detail)
                        .marginaliaTextStyle(.timecode, in: scheme, ink: .inkSecondary)
                } else {
                    Text(detail)
                        .marginaliaTextStyle(.callout, in: scheme)
                }
            }
            .padding(MarginaliaSpacing.md.value)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.elevated, in: scheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                            .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footnote

    /// The privacy pillar in its operational register (brand §1) — true of this build:
    /// the store is a local GRDB file and nothing here makes an outbound request.
    private var localFootnote: some View {
        Text("Everything stays on this Mac.")
            .marginaliaTextStyle(.callout, in: scheme)
    }
}

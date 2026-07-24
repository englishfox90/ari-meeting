//
//  AskConsoleView.swift — the shared "Ask" console body (docs/plans/ari-ask-ui.md §7/§8): message
//  log with auto-scroll, an empty state (scope-aware heading + privacy line + suggestion chips +
//  a recent-conversations list), a "thinking" row, an error row (verbatim message + optional
//  "Open Settings"), and a composer. Hosted by both `AskPageView` (the `.ask` route) and
//  `AskOverlayHost`'s floating panel — neither reimplements any of this.
//
import AriKit
import AriViewModels
import SwiftUI

struct AskConsoleView: View {
    @Bindable var viewModel: AskViewModel
    let onOpenMeeting: (String) -> Void
    let onOpenPerson: (String) -> Void
    let onOpenSeries: (String) -> Void
    let onOpenSettings: () -> Void
    @Environment(\.colorScheme) private var scheme

    private static let composerCharacterLimit = 1000

    var body: some View {
        VStack(spacing: 0) {
            // Only shown mid-thread (`newConversation()` already existed on the view model but was
            // never wired to anything — caught live 2026-07-23: once you'd asked a question there
            // was no way back to the recent-conversations/suggestion-chip empty state short of
            // navigating away entirely). Absent on the empty state itself — there's nothing to go
            // "back" from yet.
            if !viewModel.items.isEmpty {
                backToRecentHeader
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
            }
            // The log/empty area claims all remaining vertical space so the composer stays a
            // bounded strip pinned at the bottom instead of a greedy `TextEditor` that expands to
            // fill and overlaps the content above it.
            Group {
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    messageList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.marginalia(.hairline, in: scheme))
            composer
        }
        .task(id: viewModel.scope) {
            await viewModel.loadRecent()
        }
    }

    private var backToRecentHeader: some View {
        HStack {
            Button {
                viewModel.newConversation()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            Spacer()
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.vertical, MarginaliaSpacing.sm.value)
    }

    // MARK: - Message log

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    ForEach(viewModel.items) { item in
                        row(for: item).id(item.id)
                    }
                }
                .padding(MarginaliaSpacing.md.value)
            }
            .onChange(of: viewModel.items.count) { _, _ in scrollToLast(proxy) }
            .onChange(of: viewModel.items.last?.kind) { _, _ in scrollToLast(proxy) }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard let lastId = viewModel.items.last?.id else { return }
        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
    }

    @ViewBuilder
    private func row(for item: AskTranscriptItem) -> some View {
        switch item.kind {
        case let .user(text):
            userRow(text)
        case let .assistant(text, sources, streaming, cards):
            assistantRow(text: text, sources: sources, streaming: streaming, cards: cards)
        case let .thinking(text, folded):
            AskThinkingRow(text: text, folded: folded)
        case let .toolActivity(_, label, running, ok):
            AskToolActivityRow(label: label, running: running, ok: ok)
        case let .error(message, showSettings):
            errorRow(message: message, showSettings: showSettings)
        }
    }

    private func userRow(_ text: String) -> some View {
        HStack {
            Spacer(minLength: MarginaliaSpacing.xxl.value)
            Text(text)
                .marginaliaTextStyle(.body, in: scheme)
                .padding(MarginaliaSpacing.sm.value)
                .background {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .fill(Color.marginalia(.elevated, in: scheme))
                }
        }
    }

    @ViewBuilder
    private func assistantRow(
        text: String, sources: [RecallSource], streaming: Bool, cards: [RecallCardPayload]
    ) -> some View {
        // While the placeholder is still empty (deltas haven't arrived yet), the separate
        // `.thinking` row already conveys progress — an empty card here would be a hollow,
        // fake-looking box (No-Fake-State).
        if text.isEmpty, streaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                // Every resolved entity card, when present, is the direct structured answer — they
                // render ABOVE the prose, stacked, inside the same bordered container (plan §5.4 —
                // a tool-first ask can resolve more than one entity, e.g. a person + a calendar
                // event).
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    AskEntityCard(
                        card: card,
                        onOpenMeeting: onOpenMeeting,
                        onOpenPerson: onOpenPerson,
                        onOpenSeries: onOpenSeries
                    )
                }
                AskAnswerText(text: text, sources: sources, onOpenMeeting: onOpenMeeting)
                // When the model cited nothing inline, still disclose the REAL sources the engine
                // retrieved and answered from (they arrive separately from the answer text — the
                // recall invariant — so this fabricates nothing). Inline chips already cover the
                // cited case; showing both would be noise.
                if !streaming, !sources.isEmpty, !Self.hasInlineCitations(text) {
                    sourcesFooter(sources)
                }
            }
            .padding(MarginaliaSpacing.sm.value)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.surface, in: scheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
            }
        }
    }

    private static func hasInlineCitations(_ text: String) -> Bool {
        AskAnswerTokenizer.tokenize(text).contains { segment in
            if case .citation = segment { return true }
            return false
        }
    }

    /// Compact "Sources" disclosure for an answer with no inline `[S<n>]` chips: one tappable
    /// chip per retrieved source (same popover as inline citations), capped for readability with
    /// an honest "+N more" count.
    private func sourcesFooter(_ sources: [RecallSource]) -> some View {
        let visibleCount = min(sources.count, 8)
        return VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Divider().overlay(Color.marginalia(.hairline, in: scheme))
            MarginaliaFlowLayout(spacing: MarginaliaSpacing.xs.value, lineSpacing: MarginaliaSpacing.xs.value) {
                Text("Sources")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                ForEach(0 ..< visibleCount, id: \.self) { index in
                    AskSourcePopover(index: index + 1, source: sources[index], onOpenMeeting: onOpenMeeting)
                }
                if sources.count > visibleCount {
                    Text("+\(sources.count - visibleCount) more")
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                }
            }
        }
    }

    private func errorRow(message: String, showSettings: Bool) -> some View {
        MarginaliaBanner(
            kind: .error,
            message: message,
            action: showSettings ? ("Open Settings", onOpenSettings) : nil,
            scheme: scheme
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: MarginaliaSpacing.lg.value) {
                Image("DictationMark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(96.0 / 64.0, contentMode: .fit)
                    .frame(width: 72)
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                VStack(spacing: MarginaliaSpacing.xs.value) {
                    Text(emptyStateHeading)
                        .marginaliaTextStyle(.title2, in: scheme, ink: .inkHeading)
                    Text("Answers come only from your saved local meetings.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
                if !viewModel.suggestionChips.isEmpty {
                    suggestionChipsRow
                }
                if !viewModel.recentConversations.isEmpty {
                    recentConversationsSection
                }
            }
            .frame(maxWidth: .infinity)
            .padding(MarginaliaSpacing.lg.value)
        }
    }

    private var emptyStateHeading: String {
        switch viewModel.scope {
        case .global:
            "Ask your meetings"
        case let .series(_, title):
            "Ask about \(title)"
        case let .meeting(_, title):
            "Ask about \(title)"
        }
    }

    private var suggestionChipsRow: some View {
        MarginaliaFlowLayout(spacing: MarginaliaSpacing.xs.value, lineSpacing: MarginaliaSpacing.xs.value) {
            ForEach(viewModel.suggestionChips, id: \.self) { chip in
                Button(chip) {
                    viewModel.composerText = chip
                    sendIfPossible()
                }
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            }
        }
    }

    // MARK: - Recent conversations

    private var recentConversationsSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("Recent")
                .marginaliaTextStyle(.caption, in: scheme)
            ForEach(viewModel.recentConversations) { conversation in
                recentConversationRow(conversation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentConversationRow(_ conversation: AskConversation) -> some View {
        HStack {
            Button {
                Task { await viewModel.load(conversation.id) }
            } label: {
                Text(conversationTitle(conversation))
                    .marginaliaTextStyle(.body, in: scheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                Task { await viewModel.delete(conversation.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            .help("Delete conversation")
        }
        .padding(.horizontal, MarginaliaSpacing.sm.value)
        .padding(.vertical, MarginaliaSpacing.xs.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private func conversationTitle(_ conversation: AskConversation) -> String {
        guard let title = conversation.title, !title.isEmpty else { return "Untitled" }
        return title
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            MarginaliaTextEditor(
                text: $viewModel.composerText,
                prompt: composerPlaceholder,
                scheme: scheme,
                minHeight: 44,
                maxHeight: 120
            )
            .onKeyPress(.return, phases: .down) { press in
                guard !press.modifiers.contains(.shift) else { return .ignored }
                sendIfPossible()
                return .handled
            }
            .onChange(of: viewModel.composerText) { _, newValue in
                if newValue.count > Self.composerCharacterLimit {
                    viewModel.composerText = String(newValue.prefix(Self.composerCharacterLimit))
                }
            }
            HStack {
                Text("\(viewModel.composerText.count)/\(Self.composerCharacterLimit)")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                Spacer()
                Button("Ask") { sendIfPossible() }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(sendDisabled)
            }
        }
        .padding(MarginaliaSpacing.md.value)
    }

    private var sendDisabled: Bool {
        viewModel.isStreaming || viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendIfPossible() {
        guard !sendDisabled else { return }
        viewModel.send()
    }

    private var composerPlaceholder: String {
        switch viewModel.scope {
        case .global:
            "Ask about any saved meeting…"
        case let .series(_, title):
            "Ask about \(title)…"
        case let .meeting(_, title):
            "Ask about \(title)…"
        }
    }
}

/// A shared leading-icon width for every trace row (thinking sections AND tool-activity rows) so
/// their icons — and therefore their label text — share one consistent leading edge regardless of
/// which SF Symbol/spinner is showing (owner polish request, 2026-07-23: the two row kinds had
/// mismatched indentation, breaking the interleaved trace's read as one flow).
private enum AskTraceRowMetrics {
    static let iconColumnWidth: CGFloat = 16
    static let iconTextSpacing = MarginaliaSpacing.sm.value
}

/// One "Thinking" icon + label, at the shared trace leading edge (`AskTraceRowMetrics`) — factored
/// out so a folded disclosure's label and an unfolded row's label align identically.
private struct AskThinkingRowHeader: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: AskTraceRowMetrics.iconTextSpacing) {
            Image(systemName: "ellipsis.bubble")
                .frame(width: AskTraceRowMetrics.iconColumnWidth, alignment: .center)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text("Thinking")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
    }
}

/// The thinking row (plan §5.5, `ask-meetings-agentic-tools.md`; interleaved-trace amendment
/// 2026-07-23): the honest bouncing-dots placeholder before ANY reasoning/answer delta has arrived
/// (`text.isEmpty`), live streaming reasoning text while unfolded, and a collapsed one-line
/// disclosure once the answer starts (`folded == true`) — the user can re-expand it to read the
/// model's reasoning. An ask can show SEVERAL of these rows (one per interleaved section); all are
/// RETAINED after `.done` (owner decision), never removed, session-view-only.
private struct AskThinkingRow: View {
    let text: String
    let folded: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false

    var body: some View {
        if folded {
            DisclosureGroup(isExpanded: $expanded) {
                if !text.isEmpty {
                    Text(text)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, MarginaliaSpacing.xs.value)
                        .padding(.leading, AskTraceRowMetrics.iconColumnWidth + AskTraceRowMetrics.iconTextSpacing)
                }
            } label: {
                AskThinkingRowHeader()
            }
        } else if text.isEmpty {
            AskThinkingPulse()
        } else {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                AskThinkingRowHeader()
                Text(text)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    .italic()
                    .padding(.leading, AskTraceRowMetrics.iconColumnWidth + AskTraceRowMetrics.iconTextSpacing)
            }
        }
    }
}

/// One tool's dispatch lifecycle (plan §5.5), at the shared trace leading edge
/// (`AskTraceRowMetrics`, 2026-07-23 alignment polish): a small icon + its Swift-computed
/// `displayLabel` + a spinner while `running`, swapped for a checkmark (success) or a subtle
/// failure mark once finished. Shown only for a tool that actually ran (No-Fake-State) — never a
/// fabricated progress indicator. RETAINED after `.done` (owner decision), never removed.
private struct AskToolActivityRow: View {
    let label: String
    let running: Bool
    let ok: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: AskTraceRowMetrics.iconTextSpacing) {
            statusIcon
                .frame(width: AskTraceRowMetrics.iconColumnWidth, alignment: .center)
            Text(label)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if running {
            ProgressView()
                .controlSize(.small)
        } else if ok {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.marginalia(.success, in: scheme))
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.marginalia(.error, in: scheme))
        }
    }
}

/// The honest "searching local meeting excerpts…" placeholder (plan §8): three dots that bounce
/// up and down in sequence, static under Reduce Motion (BRAND.md §8 — "pulses become static").
private struct AskThinkingPulse: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped once per wave to (re)trigger every dot's keyframe track; the `.task` paces the bumps,
    /// leaving a beat of stillness between waves.
    @State private var wave = 0

    private static let dotCount = 3
    private static let bounceHeight: CGFloat = 4
    /// Per-dot start delay, so the three dots read as one travelling wave rather than a blink.
    private static let stagger = 0.12
    /// One dot's full rise-and-fall duration — deliberately ~2× the Marginalia `.standard` (260ms)
    /// step, i.e. "half speed", so the wave reads as a calm thinking pulse rather than a fast blink.
    private static let travel = 0.5
    /// A beat of stillness after each full wave: the dots settle, hold, then travel again — a
    /// gentle breathing cadence instead of a relentless loop.
    private static let restBetweenCycles = 0.55

    /// The pair of properties one dot's keyframe tracks animate together.
    private struct Bounce: Equatable {
        var offset: CGFloat = 0
        var opacity: Double = 0.5
    }

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: 3) {
                ForEach(0 ..< Self.dotCount, id: \.self) { index in
                    dot(index: index)
                }
            }
            // A dot rises above its resting line during a bounce; reserve that band so the row's
            // height (and the text baseline beside it) stays put.
            .padding(.vertical, Self.bounceHeight)
            // Deliberately scope-agnostic and mechanism-agnostic: this same row is shown for a
            // global cross-meeting search, a single meeting-scoped read, a series-scoped ask, AND
            // (Slice B) a direct person/meeting/series entity lookup — "searching excerpts" was
            // literally true only for the first of those (flagged live, 2026-07-23).
            Text("Thinking through your meetings…")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        // Pace the cadence by hand: bump `wave` (which restarts every dot's keyframe track), then
        // wait out the full wave PLUS a rest before the next bump. `repeatForever(autoreverses:)`
        // can do neither the pause nor a clean settle — exactly the never-resting loop we replaced.
        // Each dot's own staggered keyframes shape the single up-and-down; the task only paces it.
        // The task cancels with the view, so it stops the moment the answer arrives.
        .task {
            guard !reduceMotion else { return }
            let waveSpan = Self.travel + Double(Self.dotCount - 1) * Self.stagger
            while !Task.isCancelled {
                wave += 1
                try? await Task.sleep(for: .seconds(waveSpan + Self.restBetweenCycles))
            }
        }
    }

    @ViewBuilder
    private func dot(index: Int) -> some View {
        let circle = Circle()
            .fill(Color.marginalia(.inkSecondary, in: scheme))
            .frame(width: 5, height: 5)
        if reduceMotion {
            // BRAND.md §8 — "pulses become static": a still, slightly-dimmed dot, no motion.
            circle.opacity(0.6)
        } else {
            circle.keyframeAnimator(initialValue: Bounce(), trigger: wave) { view, value in
                view.offset(y: value.offset).opacity(value.opacity)
            } keyframes: { _ in
                // Hold at rest through this dot's stagger delay, then a single rise-and-fall.
                KeyframeTrack(\.offset) {
                    LinearKeyframe(0, duration: Double(index) * Self.stagger)
                    SpringKeyframe(-Self.bounceHeight, duration: Self.travel / 2)
                    SpringKeyframe(0, duration: Self.travel / 2)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.5, duration: Double(index) * Self.stagger)
                    LinearKeyframe(1, duration: Self.travel / 2)
                    LinearKeyframe(0.5, duration: Self.travel / 2)
                }
            }
        }
    }
}

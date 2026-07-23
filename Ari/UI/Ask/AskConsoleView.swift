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
    let onOpenSettings: () -> Void
    @Environment(\.colorScheme) private var scheme

    private static let composerCharacterLimit = 1000

    var body: some View {
        VStack(spacing: 0) {
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
        case let .assistant(text, sources, streaming):
            assistantRow(text: text, sources: sources, streaming: streaming)
        case .thinking:
            AskThinkingRow()
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
    private func assistantRow(text: String, sources: [RecallSource], streaming: Bool) -> some View {
        // While the placeholder is still empty (deltas haven't arrived yet), the separate
        // `.thinking` row already conveys progress — an empty card here would be a hollow,
        // fake-looking box (No-Fake-State).
        if text.isEmpty, streaming {
            EmptyView()
        } else {
            AskAnswerText(text: text, sources: sources, onOpenMeeting: onOpenMeeting)
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

/// The honest "searching local meeting excerpts…" placeholder (plan §8): three dots that bounce
/// up and down in sequence, static under Reduce Motion (BRAND.md §8 — "pulses become static").
private struct AskThinkingRow: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false

    private static let dotCount = 3
    private static let bounceHeight: CGFloat = 3
    /// Per-dot start offset, so the three dots read as one travelling wave rather than a blink.
    private static let stagger = 0.14

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: 3) {
                ForEach(0 ..< Self.dotCount, id: \.self) { index in
                    Circle()
                        .fill(Color.marginalia(.inkSecondary, in: scheme))
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.6 : (bounce ? 1 : 0.5))
                        .offset(y: (reduceMotion || !bounce) ? Self.bounceHeight : -Self.bounceHeight)
                        .animation(animation(for: index), value: bounce)
                }
            }
            // The dots swing above and below their resting line; reserve that band so the row's
            // height (and the text baseline beside it) stays put.
            .padding(.vertical, Self.bounceHeight)
            Text("Searching local meeting excerpts…")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .onAppear {
            guard !reduceMotion else { return }
            bounce = true
        }
    }

    private func animation(for index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return MarginaliaMotion.animation(.standard)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * Self.stagger)
    }
}

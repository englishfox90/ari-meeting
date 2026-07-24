//
//  AskViewModel.swift — the headless "Ask" console view model (docs/plans/ari-ask-ui.md
//  Phase A §3/§4/§10).
//
//  `@MainActor @Observable`, closure-injected in the designated `init` (mirrors
//  `MeetingSummaryViewModel`'s shape) so it tests with hand-built fakes/streams — no real
//  `RecallEngine`/`AskConversationStore` required. The `public convenience init(recallEngine:
//  conversationStore:scope:)` composes the real engine + store for app wiring.
//
//  No-Fake-State: this VM never fabricates sources, counts, or person tags. It only accumulates
//  `.delta` text and, on the single `.done`, replaces that accumulated text with the engine's own
//  reconciled `response.answer` and attaches `response.sources` — the engine already verified
//  citations before the UI ever sees them (plan §0). Errors are surfaced via
//  `error.localizedDescription`, verbatim, never paraphrased.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class AskViewModel {

    // MARK: - State (honest, no fabricated defaults)

    public private(set) var scope: AskScope
    public private(set) var availableScopes: [AskScope]
    public private(set) var items: [AskTranscriptItem] = []
    /// Bound by the composer text field.
    public var composerText: String = ""
    public private(set) var isStreaming = false
    public private(set) var recentConversations: [AskConversation] = []
    public private(set) var activeConversationId: AskConversationID?
    /// Scope-aware STATIC suggestion copy — never fabricated data, just fixed prompts.
    public private(set) var suggestionChips: [String]

    // MARK: - Injected operations

    public typealias StreamAnswerOperation = @Sendable (
        _ question: String,
        _ meetingId: MeetingID?,
        _ seriesId: SeriesID?,
        _ history: [RecallTurn]
    ) -> AsyncThrowingStream<RecallStreamEvent, Error>

    public typealias ListConversationsOperation = @Sendable (
        _ meetingId: MeetingID?,
        _ seriesId: SeriesID?
    ) async throws -> [AskConversation]

    public typealias LoadConversationOperation = @Sendable (
        _ id: AskConversationID
    ) async throws -> AskConversationDetail?

    public typealias CreateConversationOperation = @Sendable (
        _ meetingId: MeetingID?,
        _ seriesId: SeriesID?,
        _ title: String?
    ) async throws -> AskConversation

    public typealias AppendMessageOperation = @Sendable (
        _ conversationId: AskConversationID,
        _ role: String,
        _ content: String,
        _ sources: [RecallSource],
        _ cards: [RecallCardPayload]
    ) async throws -> AskMessage

    public typealias DeleteConversationOperation = @Sendable (
        _ id: AskConversationID
    ) async throws -> Void

    private let streamAnswerOp: StreamAnswerOperation
    private let listConversationsOp: ListConversationsOperation
    private let loadConversationOp: LoadConversationOperation
    private let createConversationOp: CreateConversationOperation
    private let appendMessageOp: AppendMessageOperation
    private let deleteConversationOp: DeleteConversationOperation

    /// The in-flight streaming task, if any. `send()`/`setScope(_:)` cancel it before starting
    /// (or discarding) the next one. Internal (not `private`) so `@testable` tests can `await
    /// viewModel.streamTask?.value` instead of polling for completion.
    var streamTask: Task<Void, Never>?
    /// Bumped every time a NEW ask starts (or the thread is reset). A stale task's callbacks
    /// check this before mutating `items`, so a just-cancelled task can never race a fresh one's
    /// state (plan §4's "scope change drops the half-streamed placeholder").
    private var streamGeneration = 0

    /// Ids of every `.thinking` SECTION row created by the CURRENT (in-flight or just-completing)
    /// ask, in creation order — an interleaved trace can open more than one section (a tool call
    /// closes the current section; the next `.thinking` delta opens a new one, plan §5.3
    /// amendment, 2026-07-23). Used to (a) fold ALL sections at once (on the first answer delta,
    /// or defensively at `.done`) and (b) scope `dropInFlightPlaceholders`/the error-cleanup path
    /// to exactly THIS ask's own rows — an already-completed prior ask's RETAINED trace (owner
    /// decision: the trace survives `.done`, folded) must never be touched by a new question.
    private var currentThinkingItemIds: [String] = []
    /// Same id-scoping bookkeeping for `.toolActivity` rows, one entry per row ever created this
    /// ask (both running and finished).
    private var currentToolActivityItemIds: [String] = []
    /// The currently OPEN thinking section, if any — `nil` right after a `.toolActivity` event
    /// closes it, so the next `.thinking` delta starts a fresh section instead of merging into the
    /// prior one (the interleaved-trace fix, plan §5.3 amendment).
    private var openThinkingItemId: String?

    // MARK: - Init

    /// Real app wiring: composes `RecallEngine.answerMeetingsLocallyStream` +
    /// `AskConversationStore`'s operations into the closures below (plan §3).
    public convenience init(
        recallEngine: RecallEngine,
        conversationStore: AskConversationStore,
        scope: AskScope,
        availableScopes: [AskScope] = [.global]
    ) {
        self.init(
            scope: scope,
            availableScopes: availableScopes,
            streamAnswer: { question, meetingId, seriesId, history in
                recallEngine.answerMeetingsLocallyStream(
                    question: question,
                    meetingId: meetingId,
                    seriesId: seriesId,
                    history: history
                )
            },
            listConversations: { meetingId, seriesId in
                try await conversationStore.list(meetingId: meetingId, seriesId: seriesId)
            },
            loadConversation: { id in
                try await conversationStore.get(id)
            },
            createConversation: { meetingId, seriesId, title in
                try await conversationStore.create(meetingId: meetingId, seriesId: seriesId, title: title)
            },
            appendMessage: { conversationId, role, content, sources, cards in
                try await conversationStore.appendMessage(
                    conversationId: conversationId, role: role, content: content, sources: sources, cards: cards
                )
            },
            deleteConversation: { id in
                try await conversationStore.delete(id)
            }
        )
    }

    init(
        scope: AskScope,
        availableScopes: [AskScope] = [.global],
        streamAnswer: @escaping StreamAnswerOperation,
        listConversations: @escaping ListConversationsOperation,
        loadConversation: @escaping LoadConversationOperation,
        createConversation: @escaping CreateConversationOperation,
        appendMessage: @escaping AppendMessageOperation,
        deleteConversation: @escaping DeleteConversationOperation
    ) {
        self.scope = scope
        self.availableScopes = availableScopes
        suggestionChips = Self.suggestionChips(for: scope)
        streamAnswerOp = streamAnswer
        listConversationsOp = listConversations
        loadConversationOp = loadConversation
        createConversationOp = createConversation
        appendMessageOp = appendMessage
        deleteConversationOp = deleteConversation
    }

    // MARK: - Scope

    /// Changes the active scope. Cancels any in-flight ask, drops its half-streamed placeholder,
    /// and starts a fresh (unpersisted-until-first-message) thread — never carries a mid-stream
    /// answer or history across a scope boundary (No-Fake-State).
    public func setScope(_ newScope: AskScope) {
        resetThread()
        scope = newScope
        suggestionChips = Self.suggestionChips(for: scope)
    }

    public func setAvailableScopes(_ scopes: [AskScope]) {
        availableScopes = scopes
    }

    // MARK: - Sending a question

    /// Sends `composerText` as a question. A no-op for an empty/whitespace-only composer. Cancels
    /// any prior in-flight ask first (a new question always wins over a stale one, plan §10 test 9).
    public func send() {
        let question = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        composerText = ""

        streamTask?.cancel()
        streamGeneration += 1
        let generation = streamGeneration
        // A new question supersedes any still-in-flight one: drop the prior ask's live placeholder
        // + thinking/tool rows (scoped to exactly ITS OWN row ids, never a retained COMPLETED prior
        // ask's trace) so they can't linger forever once its task returns on the generation guard.
        // (Unreachable from the UI today — the composer disables send while streaming — but the VM
        // contract promises "a new question always wins", so honor it here.)
        dropInFlightPlaceholders()

        let history = lastHistoryTurns()
        items.append(AskTranscriptItem(kind: .user(question)))
        // No assistant placeholder is created here (2026-07-23 live-testing fix): an eagerly-created
        // empty bubble used to sit ABOVE the thinking/tool rows that append after it, rendering as a
        // hollow white pill during generation. The thinking row is now the ONLY in-flight placeholder;
        // the assistant bubble is created lazily, appended AFTER whatever thinking/tool rows already
        // exist, on the first non-empty answer delta (see the `.delta` case below).
        let thinkingId = UUID().uuidString
        items.append(AskTranscriptItem(id: thinkingId, kind: .thinking(text: "", folded: false)))
        currentThinkingItemIds = [thinkingId]
        currentToolActivityItemIds = []
        openThinkingItemId = thinkingId
        isStreaming = true

        let scopeKey = scope.engineScope
        let persistenceKey = scope.persistenceKey

        streamTask = Task { [weak self] in
            guard let self else { return }
            // Nil until the FIRST non-empty answer delta arrives — that is the moment the
            // assistant bubble is actually created and appended (at the END of `items`, i.e. below
            // any thinking/tool rows that already exist). An empty-delta-only stream (edge case)
            // never creates a bubble at all; `.done` creates one directly if none exists yet (e.g.
            // a fallback that emits no deltas before its terminal event). Declared OUTSIDE the
            // `do` block so the `catch` below can clean it up if it was created before a mid-stream
            // throw.
            var assistantItemId: String?
            do {
                let conversationId = try await ensureConversation(
                    meetingId: persistenceKey.meetingId,
                    seriesId: persistenceKey.seriesId,
                    firstQuestion: question,
                    generation: generation
                )
                _ = try await appendMessageOp(conversationId, "user", question, [], [])

                var accumulated = ""
                // The item id(s) of the currently-running row(s) for a given tool name, oldest
                // first (a FIFO queue) — robust to the SAME tool name running twice concurrently
                // within one ask (finding L1): a `.finished` event completes the EARLIEST still-
                // running row for that name, never clobbering the wrong one.
                var runningToolItemIds: [String: [String]] = [:]
                let stream = streamAnswerOp(question, scopeKey.meetingId, scopeKey.seriesId, history)
                for try await event in stream {
                    guard streamGeneration == generation else { return }
                    switch event {
                    case let .delta(delta):
                        guard !delta.isEmpty else { continue }
                        accumulated += delta
                        if let assistantItemId {
                            updateAssistant(
                                id: assistantItemId, text: accumulated, sources: [], streaming: true, cards: []
                            )
                        } else {
                            // First non-empty answer delta: fold every thinking SECTION opened so
                            // far (not just one) and create the bubble now, appended after every
                            // thinking/tool row so far.
                            foldAllThinkingSections()
                            let newId = UUID().uuidString
                            assistantItemId = newId
                            items.append(
                                AskTranscriptItem(
                                    id: newId,
                                    kind: .assistant(text: accumulated, sources: [], streaming: true, cards: [])
                                )
                            )
                        }
                    case let .thinking(delta):
                        appendThinking(delta: delta, beforeAssistantItemId: assistantItemId)
                    case let .toolActivity(activity):
                        applyToolActivity(
                            activity, runningToolItemIds: &runningToolItemIds, beforeAssistantItemId: assistantItemId
                        )
                    case let .done(response):
                        // Owner decision, 2026-07-23 (supersedes plan §5.3's original "removed at
                        // .done"): the trace (thinking sections, folded; tool rows, completed) is
                        // RETAINED above the answer — visible for later inspection, session-view-
                        // only (persistence below still carries only answer/sources/cards, never
                        // the trace). Fold defensively here too, in case no answer delta ever
                        // arrived to trigger the fold above (e.g. a rung that emits only `.done`).
                        foldAllThinkingSections()
                        if let assistantItemId {
                            updateAssistant(
                                id: assistantItemId, text: response.answer, sources: response.sources,
                                streaming: false, cards: response.cards
                            )
                        } else {
                            // No bubble was ever created (e.g. a rung that emits only `.done`, no
                            // deltas) — create it now, final and non-streaming, at the end of items.
                            items.append(
                                AskTranscriptItem(
                                    kind: .assistant(
                                        text: response.answer, sources: response.sources,
                                        streaming: false, cards: response.cards
                                    )
                                )
                            )
                        }
                        _ = try await appendMessageOp(
                            conversationId, "assistant", response.answer, response.sources, response.cards
                        )
                        // This ask is now COMPLETE — its trace is retained in `items`, but its row
                        // ids must stop being treated as "this ask's in-flight rows": otherwise the
                        // NEXT ask's `dropInFlightPlaceholders()` (or an error-cleanup path, were one
                        // to somehow still reference these ids) would remove a fully completed,
                        // retained trace instead of only ever removing an unfinished one.
                        currentThinkingItemIds = []
                        currentToolActivityItemIds = []
                        openThinkingItemId = nil
                    }
                }
                guard streamGeneration == generation else { return }
                isStreaming = false
                // Surface the just-persisted thread in the recent list now, so it's already present
                // when the user starts a new conversation and returns to the empty state.
                await loadRecent()
            } catch is CancellationError {
                // A user-initiated cancel (new question / scope change) — already handled by
                // whichever call site bumped `streamGeneration`; nothing further to surface.
            } catch {
                guard streamGeneration == generation else { return }
                // Scoped to exactly THIS ask's own thinking/tool rows (never a blanket "remove
                // every .thinking/.toolActivity item" — a prior, already-completed ask's RETAINED
                // trace must survive an unrelated later ask's error).
                let inFlightIds = Set(currentThinkingItemIds + currentToolActivityItemIds)
                items.removeAll { inFlightIds.contains($0.id) }
                if let assistantItemId {
                    removeItem(id: assistantItemId)
                }
                items.append(
                    AskTranscriptItem(kind: .error(
                        error.localizedDescription,
                        showSettings: Self.showSettings(for: error)
                    ))
                )
                isStreaming = false
            }
        }
    }

    private static func showSettings(for error: Error) -> Bool {
        guard let recallError = error as? RecallEngineError else { return false }
        switch recallError {
        case .modelNotConfigured, .loopbackViolation:
            return true
        default:
            return false
        }
    }

    private func removeItem(id: String) {
        items.removeAll { $0.id == id }
    }

    /// Removes any still-live in-flight thinking/tool row (id-scoped to the JUST-superseded ask,
    /// `currentThinkingItemIds`/`currentToolActivityItemIds` — never a blanket kind-based sweep,
    /// which would also erase an already-completed prior ask's RETAINED trace) and any still-
    /// STREAMING assistant bubble (whether or not it has accumulated any text yet) — a new question
    /// fully replaces the prior ask's UNFINISHED state, partial answer included (No-Fake-State: no
    /// perpetual spinner, no orphaned tool row, no stale partial bubble left behind).
    private func dropInFlightPlaceholders() {
        let inFlightIds = Set(currentThinkingItemIds + currentToolActivityItemIds)
        items.removeAll { item in
            if inFlightIds.contains(item.id) {
                return true
            }
            switch item.kind {
            case .thinking, .toolActivity:
                // A retained, COMPLETED prior ask's row shares these KINDS but a different id — kind
                // alone must never drive removal anymore (owner decision: retain the trace).
                return false
            case let .assistant(_, _, streaming, _):
                return streaming
            case .user, .error:
                return false
            }
        }
    }

    private func updateAssistant(
        id: String, text: String, sources: [RecallSource], streaming: Bool, cards: [RecallCardPayload]
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = .assistant(text: text, sources: sources, streaming: streaming, cards: cards)
    }

    /// The index at which a NEW ephemeral row (a thinking section or a tool-activity row) should be
    /// inserted: immediately BEFORE the assistant bubble if one already exists, so the trace never
    /// renders below an in-progress answer even if an event arrives after the bubble was created
    /// (defensive ordering, finding L1) — else at the end of `items`.
    private func insertionIndex(beforeAssistantItemId assistantItemId: String?) -> Int {
        guard let assistantItemId, let index = items.firstIndex(where: { $0.id == assistantItemId }) else {
            return items.endIndex
        }
        return index
    }

    /// Appends a reasoning delta. If a thinking SECTION is currently open (`openThinkingItemId`),
    /// the delta folds into that section's accumulated text; otherwise a FRESH section is created
    /// — inserted immediately before the assistant bubble if one already exists, else at the end
    /// (interleaved trace, plan §5.3 amendment, 2026-07-23: a `.toolActivity` event CLOSES the
    /// current section, so the model's later reasoning after a tool call reads as its own new
    /// section rather than merging into the original blob).
    private func appendThinking(delta: String, beforeAssistantItemId: String?) {
        if let openId = openThinkingItemId, let index = items.firstIndex(where: { $0.id == openId }) {
            guard case let .thinking(text, folded) = items[index].kind else { return }
            items[index].kind = .thinking(text: text + delta, folded: folded)
            return
        }
        let newId = UUID().uuidString
        let insertAt = insertionIndex(beforeAssistantItemId: beforeAssistantItemId)
        items.insert(AskTranscriptItem(id: newId, kind: .thinking(text: delta, folded: false)), at: insertAt)
        openThinkingItemId = newId
        currentThinkingItemIds.append(newId)
    }

    /// Collapses EVERY thinking section opened so far to its folded (one-line disclosure)
    /// presentation — called on the FIRST answer `.delta`, and defensively again at `.done` in case
    /// no delta ever arrived. Sections are never removed here; they're RETAINED (owner decision,
    /// 2026-07-23) until a later ask supersedes/errors this one.
    private func foldAllThinkingSections() {
        for id in currentThinkingItemIds {
            guard let index = items.firstIndex(where: { $0.id == id }),
                  case let .thinking(text, _) = items[index].kind
            else { continue }
            items[index].kind = .thinking(text: text, folded: true)
        }
    }

    /// Applies one tool-dispatch lifecycle event: `.started` CLOSES the currently-open thinking
    /// section (so a later `.thinking` delta opens a fresh one, interleaved-trace amendment) and
    /// inserts a new running row (before the assistant bubble if one exists, finding L1); `.finished`
    /// completes the EARLIEST still-running row for that same tool name — a FIFO queue per tool
    /// name, robust to the SAME tool running twice concurrently within one ask (finding L1) instead
    /// of a single id that a second concurrent run would silently clobber. `runningToolItemIds` is
    /// owned by the calling `send()` task (one per in-flight ask).
    private func applyToolActivity(
        _ activity: ToolActivity,
        runningToolItemIds: inout [String: [String]],
        beforeAssistantItemId: String?
    ) {
        switch activity.phase {
        case .started:
            openThinkingItemId = nil
            let id = UUID().uuidString
            runningToolItemIds[activity.toolName, default: []].append(id)
            currentToolActivityItemIds.append(id)
            let insertAt = insertionIndex(beforeAssistantItemId: beforeAssistantItemId)
            items.insert(
                AskTranscriptItem(
                    id: id,
                    kind: .toolActivity(
                        toolName: activity.toolName,
                        label: activity.displayLabel,
                        running: true,
                        ok: true
                    )
                ),
                at: insertAt
            )
        case let .finished(ok):
            guard var ids = runningToolItemIds[activity.toolName], !ids.isEmpty else { return }
            let id = ids.removeFirst()
            if ids.isEmpty {
                runningToolItemIds.removeValue(forKey: activity.toolName)
            } else {
                runningToolItemIds[activity.toolName] = ids
            }
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].kind = .toolActivity(
                toolName: activity.toolName, label: activity.displayLabel, running: false, ok: ok
            )
        }
    }

    /// Trailing history for the NEXT ask, alternating roles, newest kept (← `RecallBounds.
    /// maxHistoryTurns`, the engine's own cap — the engine re-clamps regardless, plan §9).
    private func lastHistoryTurns() -> [RecallTurn] {
        var turns: [RecallTurn] = []
        for item in items {
            switch item.kind {
            case let .user(text):
                turns.append(RecallTurn(role: "user", content: text))
            case let .assistant(text, _, streaming, _):
                guard !streaming, !text.isEmpty else { continue }
                turns.append(RecallTurn(role: "assistant", content: text))
            case .thinking, .toolActivity, .error:
                continue
            }
        }
        return Array(turns.suffix(RecallBounds.maxHistoryTurns))
    }

    /// Lazily creates the backing conversation on the FIRST user message of a thread (title = the
    /// first ~40 characters of that question). Guarded by `generation` so a cancelled ask never
    /// mints a conversation for a thread the user has already left.
    private func ensureConversation(
        meetingId: MeetingID?,
        seriesId: SeriesID?,
        firstQuestion: String,
        generation: Int
    ) async throws -> AskConversationID {
        if let activeConversationId {
            return activeConversationId
        }
        let title = String(firstQuestion.prefix(40))
        let conversation = try await createConversationOp(meetingId, seriesId, title)
        if streamGeneration == generation {
            activeConversationId = conversation.id
        }
        return conversation.id
    }

    // MARK: - Conversation lifecycle

    /// Cancels any in-flight ask and starts a brand-new, unpersisted thread.
    public func newConversation() {
        resetThread()
    }

    private func resetThread() {
        streamTask?.cancel()
        streamTask = nil
        streamGeneration += 1
        isStreaming = false
        items = []
        activeConversationId = nil
        currentThinkingItemIds = []
        currentToolActivityItemIds = []
        openThinkingItemId = nil
    }

    /// Hydrates `items` from a saved conversation's full detail, in order, sources included.
    public func load(_ id: AskConversationID) async {
        resetThread()
        guard let detail = try? await loadConversationOp(id) else { return }
        activeConversationId = detail.conversation.id
        items = detail.messages.map { message in
            let kind: AskTranscriptItemKind = message.role == "user"
                ? .user(message.content)
                : .assistant(text: message.content, sources: message.sources, streaming: false, cards: message.cards)
            return AskTranscriptItem(id: message.id.rawValue, kind: kind)
        }
    }

    /// Refreshes `recentConversations` for the CURRENT scope's persistence key.
    public func loadRecent() async {
        let key = scope.persistenceKey
        recentConversations = await (try? listConversationsOp(key.meetingId, key.seriesId)) ?? []
    }

    /// Deletes a saved conversation (and its messages). If it was the active thread, starts a
    /// fresh one. Refreshes the recent list either way.
    public func delete(_ id: AskConversationID) async {
        try? await deleteConversationOp(id)
        if activeConversationId == id {
            resetThread()
        }
        await loadRecent()
    }

    // MARK: - Suggestion chips (static, scope-aware copy)

    private static func suggestionChips(for scope: AskScope) -> [String] {
        switch scope {
        case .global:
            [
                "What decisions were made recently?",
                "Summarize what I've been working on",
                "What action items are still open?"
            ]
        case .series:
            [
                "What's changed since last time?",
                "What decisions has this series made?",
                "What action items are open in this series?"
            ]
        case .meeting:
            [
                "What did we decide?",
                "What are the action items?",
                "Who said what about this?"
            ]
        }
    }
}

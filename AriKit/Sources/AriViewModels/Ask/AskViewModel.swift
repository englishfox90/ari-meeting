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
        // + thinking rows so they can't linger forever once its task returns on the generation
        // guard. (Unreachable from the UI today — the composer disables send while streaming — but
        // the VM contract promises "a new question always wins", so honor it here.)
        dropInFlightPlaceholders()

        let history = lastHistoryTurns()
        items.append(AskTranscriptItem(kind: .user(question)))
        let placeholderId = UUID().uuidString
        items.append(
            AskTranscriptItem(
                id: placeholderId, kind: .assistant(text: "", sources: [], streaming: true, cards: [])
            )
        )
        let thinkingId = UUID().uuidString
        items.append(AskTranscriptItem(id: thinkingId, kind: .thinking(text: "", folded: false)))
        isStreaming = true

        let scopeKey = scope.engineScope
        let persistenceKey = scope.persistenceKey

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conversationId = try await ensureConversation(
                    meetingId: persistenceKey.meetingId,
                    seriesId: persistenceKey.seriesId,
                    firstQuestion: question,
                    generation: generation
                )
                _ = try await appendMessageOp(conversationId, "user", question, [], [])

                var accumulated = ""
                var sawFirstDelta = false
                // The item id of the currently-running row for a given tool name, so a `.finished`
                // event updates the SAME row a `.started` event created (plan §5.3: "match the
                // latest running row with the same toolName").
                var runningToolItemIds: [String: String] = [:]
                let stream = streamAnswerOp(question, scopeKey.meetingId, scopeKey.seriesId, history)
                for try await event in stream {
                    guard streamGeneration == generation else { return }
                    switch event {
                    case let .delta(delta):
                        if !sawFirstDelta {
                            sawFirstDelta = true
                            foldThinking(id: thinkingId)
                        }
                        accumulated += delta
                        updateAssistant(id: placeholderId, text: accumulated, sources: [], streaming: true, cards: [])
                    case let .thinking(delta):
                        appendThinking(id: thinkingId, delta: delta)
                    case let .toolActivity(activity):
                        applyToolActivity(activity, runningToolItemIds: &runningToolItemIds)
                    case let .done(response):
                        // Ephemeral rows never survive the terminal event (plan §5.3 — thinking and
                        // tool-activity rows are never persisted, and never linger in the UI once
                        // the real answer has landed).
                        removeItem(id: thinkingId)
                        removeToolActivityRows()
                        updateAssistant(
                            id: placeholderId, text: response.answer, sources: response.sources,
                            streaming: false, cards: response.cards
                        )
                        _ = try await appendMessageOp(
                            conversationId, "assistant", response.answer, response.sources, response.cards
                        )
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
                removeItem(id: thinkingId)
                removeToolActivityRows()
                removeItem(id: placeholderId)
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

    /// Removes any still-live `.thinking`/`.toolActivity` row and empty streaming assistant
    /// placeholder left by a prior in-flight ask that a new question is superseding (No-Fake-State:
    /// no perpetual spinner, no orphaned tool row).
    private func dropInFlightPlaceholders() {
        items.removeAll { item in
            switch item.kind {
            case .thinking, .toolActivity:
                true
            case let .assistant(text, _, streaming, _):
                streaming && text.isEmpty
            case .user, .error:
                false
            }
        }
    }

    private func updateAssistant(
        id: String, text: String, sources: [RecallSource], streaming: Bool, cards: [RecallCardPayload]
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = .assistant(text: text, sources: sources, streaming: streaming, cards: cards)
    }

    /// Appends a reasoning delta to the thinking row, creating it (unfolded) if a prior removal
    /// somehow already dropped it — defensive; in the normal flow the placeholder row added at the
    /// start of `send()` always exists until `.done`/error/supersession.
    private func appendThinking(id: String, delta: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            items.append(AskTranscriptItem(id: id, kind: .thinking(text: delta, folded: false)))
            return
        }
        guard case let .thinking(text, folded) = items[index].kind else { return }
        items[index].kind = .thinking(text: text + delta, folded: folded)
    }

    /// Collapses the thinking row to its folded (one-line disclosure) presentation — called once,
    /// on the FIRST answer `.delta` (plan §5.3). The row is never removed here; only `.done`/error/
    /// supersession removes it.
    private func foldThinking(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case let .thinking(text, _) = items[index].kind
        else { return }
        items[index].kind = .thinking(text: text, folded: true)
    }

    /// Applies one tool-dispatch lifecycle event: `.started` appends a new running row; `.finished`
    /// completes the MOST RECENT running row for that same tool name (plan §5.3).
    /// `runningToolItemIds` is owned by the calling `send()` task (one per in-flight ask).
    private func applyToolActivity(_ activity: ToolActivity, runningToolItemIds: inout [String: String]) {
        switch activity.phase {
        case .started:
            let id = UUID().uuidString
            runningToolItemIds[activity.toolName] = id
            items.append(
                AskTranscriptItem(
                    id: id,
                    kind: .toolActivity(
                        toolName: activity.toolName,
                        label: activity.displayLabel,
                        running: true,
                        ok: true
                    )
                )
            )
        case let .finished(ok):
            guard let id = runningToolItemIds[activity.toolName],
                  let index = items.firstIndex(where: { $0.id == id })
            else { return }
            items[index].kind = .toolActivity(
                toolName: activity.toolName, label: activity.displayLabel, running: false, ok: ok
            )
            runningToolItemIds.removeValue(forKey: activity.toolName)
        }
    }

    /// Removes every `.toolActivity` row — ephemeral, never persisted (plan §5.3); called on the
    /// terminal `.done` and on error, mirroring the thinking row's own removal.
    private func removeToolActivityRows() {
        items.removeAll { item in
            if case .toolActivity = item.kind {
                true
            } else {
                false
            }
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

//
//  AskViewModelTests.swift — plan §10 tests 1-6, 8-13 (docs/plans/ari-ask-ui.md). Test 14
//  (`AskAnswerText` tokenizer) is a VIEW-level test, out of scope here (app-target UI task).
//
//  The designated closure-injected `init` is exercised directly with hand-built fakes — no real
//  `RecallEngine`/`AppDatabase`/`AskConversationStore` involved, mirroring
//  `MeetingSummaryViewModelTests`'s shape. Streaming tests either build a fully-scripted
//  `AsyncThrowingStream` (deltas already queued) and `await viewModel.streamTask?.value`, or — when
//  a test needs to observe TRUE mid-stream state or race a cancellation — a `ControllableAskStream`
//  the test drives by hand.
//
import Foundation
import Synchronization
import Testing
@testable import AriKit
@testable import AriViewModels

/// A stream that yields the given events synchronously then finishes — fine for tests that only
/// need the FINAL state (`await viewModel.streamTask?.value` drains it fully). `nonisolated` (a
/// free function, not a method on the `@MainActor` suite) because `AskViewModel.
/// StreamAnswerOperation` is a plain (non-actor-isolated) `@Sendable` closure type.
private func scriptedStream(_ events: [RecallStreamEvent]) -> AsyncThrowingStream<RecallStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

private func throwingStream(_ error: Error) -> AsyncThrowingStream<RecallStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
    }
}

/// Polls `condition` on the current (`@MainActor`) executor, giving the VM's background
/// `streamTask` a chance to make progress between checks. A bare `Task.yield()` loop is NOT
/// reliable enough under a heavily-loaded parallel test run (the polling task can be rescheduled
/// ahead of the one it's waiting on, effectively spinning) — a short real `Task.sleep` forces an
/// actual scheduler quantum to pass each iteration, up to `timeout`.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("AskViewModel")
@MainActor
struct AskViewModelTests {

    // MARK: - Fixtures

    private func makeSource(meetingId: String = "meeting-1", speakers: [String] = []) -> RecallSource {
        RecallSource(
            meetingId: meetingId,
            title: "Weekly sync",
            matchContext: "We decided to ship the recall port.",
            timestamp: "00:42",
            meetingDate: "2026-07-18",
            summary: "Shipped the recall port.",
            speakers: speakers
        )
    }

    /// A hand-driven stream + its continuation, for tests that need to pace events themselves
    /// (mid-stream inspection, cancel-in-flight races). `AsyncThrowingStream.Continuation` is
    /// `Sendable`, so this struct is unconditionally `Sendable` too — no `@unchecked` needed.
    private struct ControllableAskStream: Sendable {
        let stream: AsyncThrowingStream<RecallStreamEvent, Error>
        let continuation: AsyncThrowingStream<RecallStreamEvent, Error>.Continuation
    }

    private func makeControllableStream() -> ControllableAskStream {
        var continuation: AsyncThrowingStream<RecallStreamEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<RecallStreamEvent, Error> { continuation = $0 }
        return ControllableAskStream(stream: stream, continuation: continuation)
    }

    /// Default no-op persistence closures — tests that care about persistence override the
    /// specific closure(s) they're asserting on.
    private func makeViewModel(
        scope: AskScope = .global,
        availableScopes: [AskScope] = [.global],
        streamAnswer: @escaping AskViewModel.StreamAnswerOperation = { _, _, _, _ in
            AsyncThrowingStream { $0.finish() }
        },
        listConversations: @escaping AskViewModel.ListConversationsOperation = { _, _ in [] },
        loadConversation: @escaping AskViewModel.LoadConversationOperation = { _ in nil },
        createConversation: @escaping AskViewModel.CreateConversationOperation = { meetingId, seriesId, title in
            AskConversation(
                id: AskConversationID(UUID().uuidString), meetingId: meetingId, seriesId: seriesId,
                title: title, createdAt: "now", updatedAt: "now"
            )
        },
        appendMessage: @escaping AskViewModel
            .AppendMessageOperation = { conversationId, role, content, sources, cards in
                AskMessage(
                    id: AskMessageID(UUID().uuidString), conversationId: conversationId, role: role,
                    content: content, sources: sources, cards: cards, createdAt: "now"
                )
            },
        deleteConversation: @escaping AskViewModel.DeleteConversationOperation = { _ in }
    ) -> AskViewModel {
        AskViewModel(
            scope: scope,
            availableScopes: availableScopes,
            streamAnswer: streamAnswer,
            listConversations: listConversations,
            loadConversation: loadConversation,
            createConversation: createConversation,
            appendMessage: appendMessage,
            deleteConversation: deleteConversation
        )
    }

    // MARK: - Test 1: streaming accumulation shows deltas mid-stream

    @Test("deltas accumulate and are visible mid-stream, before .done lands")
    func streamingAccumulationShowsDeltasMidStream() async throws {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "What did we decide?"
        viewModel.send()

        controllable.continuation.yield(.delta("Hello"))
        await waitUntil {
            if case let .assistant(text, _, _, _)? = viewModel.items
                .first(where: {
                    if case .assistant = $0.kind {
                        true
                    } else {
                        false
                    }
                })?.kind {
                return text == "Hello"
            }
            return false
        }

        let assistantMidStream = try #require(viewModel.items.first { item in
            if case .assistant = item.kind {
                return true
            }
            return false
        })
        guard case let .assistant(text, sources, streaming, cards) = assistantMidStream.kind else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(text == "Hello")
        #expect(cards.isEmpty)
        #expect(sources.isEmpty)
        #expect(streaming)
        #expect(viewModel.isStreaming)
        // The "thinking" row is FOLDED (not removed) once the first answer delta arrives.
        let thinkingItem = try #require(viewModel.items.first {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
        guard case let .thinking(_, folded) = thinkingItem.kind else {
            Issue.record("expected a thinking row"); return
        }
        #expect(folded)

        controllable.continuation.yield(.delta(", world"))
        controllable.continuation.yield(.done(RecallResponse(answer: "Hello, world (final)", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        #expect(!viewModel.isStreaming)
        // The thinking row is finally REMOVED at `.done` (ephemeral, never lingers).
        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
    }

    // MARK: - Test 2: final .done replaces the accumulated raw text

    @Test(".done REPLACES the accumulated text with the reconciled answer, not the raw concatenation")
    func doneReplacesAccumulatedText() async throws {
        let response = RecallResponse(answer: "The reconciled final answer with [S1].", sources: [makeSource()])
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            scriptedStream([.delta("raw "), .delta("partial "), .delta("chunks"), .done(response)])
        })

        viewModel.composerText = "What did we decide?"
        viewModel.send()
        await viewModel.streamTask?.value

        let assistantItem = try #require(viewModel.items.last)
        guard case let .assistant(text, sources, streaming, cards) = assistantItem.kind else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(text == response.answer)
        #expect(text != "raw partial chunks")
        #expect(sources == response.sources)
        #expect(!streaming)
        #expect(cards.isEmpty)
    }

    // MARK: - Test 3: sources attach only from .done; no person tags when speakers:[]

    @Test("sources are empty until .done, then attach exactly the engine's sources (no fabricated tags)")
    func sourcesAttachOnlyFromDone() async throws {
        let source = makeSource(speakers: [])
        let response = RecallResponse(answer: "Answer.", sources: [source])
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Question"
        viewModel.send()
        controllable.continuation.yield(.delta("partial"))
        await waitUntil {
            viewModel.items.contains {
                if case .assistant = $0.kind {
                    true
                } else {
                    false
                }
            }
        }

        let midStream = try #require(viewModel.items
            .first {
                if case .assistant = $0.kind {
                    return true
                }; return false
            })
        guard case let .assistant(_, midSources, _, _) = midStream.kind else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(midSources.isEmpty)

        controllable.continuation.yield(.done(response))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        let finalItem = try #require(viewModel.items.last)
        guard case let .assistant(_, finalSources, _, _) = finalItem.kind else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(finalSources == [source])
        // A key path here makes `#expect`'s macro expansion of `allSatisfy` ambiguous between
        // throwing/non-throwing overloads (a real Swift Testing macro limitation, not a style
        // preference) and fails to build — keep this as an explicit closure.
        // swiftformat:disable:next preferKeyPath
        let allSpeakersEmpty = finalSources.allSatisfy { source in source.speakers.isEmpty }
        #expect(allSpeakersEmpty)
    }

    // MARK: - Test 4: error surfacing verbatim + settings flag

    @Test(
        "a thrown error drops the placeholder and appends the error verbatim, with showSettings for modelNotConfigured"
    )
    func errorSurfacesVerbatimWithSettingsFlagForModelNotConfigured() async throws {
        let error = RecallEngineError.modelNotConfigured("Configure Built-in AI or Ollama before asking meetings.")
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in throwingStream(error) })

        viewModel.composerText = "Question"
        viewModel.send()
        await viewModel.streamTask?.value

        #expect(!viewModel.items.contains {
            if case .assistant = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
        let errorItem = try #require(viewModel.items.last)
        guard case let .error(message, showSettings) = errorItem.kind else {
            Issue.record("expected an error row")
            return
        }
        #expect(message == error.localizedDescription)
        #expect(showSettings)
        #expect(!viewModel.isStreaming)
    }

    @Test("loopbackViolation also sets showSettings; generationFailed does not")
    func showSettingsFlagIsScopedToConfigurationErrors() async throws {
        let loopbackVM = makeViewModel(streamAnswer: { _, _, _, _ in
            throwingStream(RecallEngineError.loopbackViolation)
        })
        loopbackVM.composerText = "Question"
        loopbackVM.send()
        await loopbackVM.streamTask?.value
        guard case let .error(_, showSettings) = try #require(loopbackVM.items.last).kind else {
            Issue.record("expected an error row"); return
        }
        #expect(showSettings)

        let generationFailedVM = makeViewModel(streamAnswer: { _, _, _, _ in
            throwingStream(RecallEngineError.generationFailed("The local model could not answer: boom"))
        })
        generationFailedVM.composerText = "Question"
        generationFailedVM.send()
        await generationFailedVM.streamTask?.value
        guard case let .error(message, showSettings2) = try #require(generationFailedVM.items.last).kind else {
            Issue.record("expected an error row"); return
        }
        #expect(message == "The local model could not answer: boom")
        #expect(!showSettings2)
    }

    // MARK: - Test 5: empty-question guard

    @Test("send() is a no-op for an empty or whitespace-only composer")
    func emptyQuestionGuardIsNoOp() {
        let viewModel = makeViewModel()

        viewModel.composerText = "   \n\t "
        viewModel.send()

        #expect(viewModel.items.isEmpty)
        #expect(!viewModel.isStreaming)
        #expect(viewModel.streamTask == nil)
    }

    // MARK: - Test 6: history windowing to last 8, alternating roles, newest kept

    @Test("history passed to the next ask is the last 8 turns, alternating roles, newest kept")
    func historyWindowsToLastEightTurnsNewestKept() async throws {
        let capturedHistory = Mutex<[[RecallTurn]]>([])
        let viewModel = makeViewModel(streamAnswer: { question, _, _, history in
            capturedHistory.withLock { $0.append(history) }
            return scriptedStream([.done(RecallResponse(answer: "Answer to \(question)", sources: []))])
        })

        // 6 full user/assistant round trips = 12 turns, more than the 8-turn cap.
        for index in 1 ... 6 {
            viewModel.composerText = "Question \(index)"
            viewModel.send()
            await viewModel.streamTask?.value
        }

        let lastCallHistory = try #require(capturedHistory.withLock { $0.last })
        #expect(lastCallHistory.count == RecallBounds.maxHistoryTurns)
        // Alternating roles, and the tail is the most recent exchange (question 5 + its answer).
        let roles = lastCallHistory.map(\.role)
        #expect(roles == Array(repeating: ["user", "assistant"], count: 4).flatMap(\.self))
        #expect(lastCallHistory.last?.content == "Answer to Question 5")
        // Turns before question 6's own ask: 10 total (Q1..Q5 + their answers); suffix(8) drops
        // the oldest pair (Q1's turn), keeping Q2's user turn through Q5's assistant turn.
        #expect(lastCallHistory.first?.content == "Question 2")
    }

    // MARK: - Test 8: scope override cancels in-flight + drops placeholder + clears thread

    @Test("setScope cancels an in-flight ask, drops its placeholder, and clears the active thread")
    func scopeOverrideCancelsInFlightAndClearsThread() async {
        let controllable = makeControllableStream()
        let createCallCount = Mutex<Int>(0)
        let viewModel = makeViewModel(
            scope: .meeting("meeting-1", title: "Standup"),
            availableScopes: [.meeting("meeting-1", title: "Standup"), .global],
            streamAnswer: { _, _, _, _ in controllable.stream },
            createConversation: { meetingId, seriesId, title in
                let count = createCallCount.withLock { $0 += 1; return $0 }
                return AskConversation(
                    id: AskConversationID("conversation-\(count)"), meetingId: meetingId,
                    seriesId: seriesId, title: title, createdAt: "now", updatedAt: "now"
                )
            }
        )

        viewModel.composerText = "In-flight question"
        viewModel.send()
        await waitUntil { viewModel.activeConversationId != nil }
        let priorTask = viewModel.streamTask
        #expect(viewModel.activeConversationId != nil)

        viewModel.setScope(.global)

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.activeConversationId == nil)
        #expect(!viewModel.isStreaming)
        #expect(viewModel.scope == .global)

        controllable.continuation.finish()
        await priorTask?.value
        // The stale task's completion must not resurrect any state after the scope change.
        #expect(viewModel.items.isEmpty)
    }

    // MARK: - Test 9: new question mid-stream cancels prior

    @Test("a new question mid-stream cancels the prior in-flight task")
    func newQuestionMidStreamCancelsPrior() async throws {
        let firstControllable = makeControllableStream()
        let secondControllable = makeControllableStream()
        let callCount = Mutex<Int>(0)
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            let count = callCount.withLock { $0 += 1; return $0 }
            return count == 1 ? firstControllable.stream : secondControllable.stream
        })

        viewModel.composerText = "First question"
        viewModel.send()
        await Task.yield()
        let firstTask = try #require(viewModel.streamTask)

        viewModel.composerText = "Second question"
        viewModel.send()

        #expect(firstTask.isCancelled)

        secondControllable.continuation.yield(.done(RecallResponse(answer: "Second answer", sources: [])))
        secondControllable.continuation.finish()
        await viewModel.streamTask?.value
        firstControllable.continuation.finish()

        #expect(viewModel.items.contains {
            if case .user("Second question") = $0.kind {
                true
            } else {
                false
            }
        })
        let lastAssistant = try #require(viewModel.items.last)
        guard case let .assistant(text, _, _, _) = lastAssistant.kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(text == "Second answer")
    }

    // MARK: - Test 10: conversation persist — create once, append user then assistant-with-sources

    private struct CreateCall: Sendable, Equatable {
        let meetingId: MeetingID?
        let seriesId: SeriesID?
        let title: String?
    }

    private struct AppendCall: Sendable, Equatable {
        let conversationId: AskConversationID
        let role: String
        let content: String
        let sources: [RecallSource]
        let cards: [RecallCardPayload]
    }

    @Test("the conversation is created once (first message), then user then assistant-with-sources are appended")
    func conversationPersistsCreateOnceThenAppendsUserAndAssistant() async {
        let createCalls = Mutex<[CreateCall]>([])
        let appendCalls = Mutex<[AppendCall]>([])
        let source = makeSource()
        let card = RecallCardPayload.person(
            PersonCardPayload(personId: "p1", displayName: "Sarah Ammon", meetingCount: 3)
        )
        let viewModel = makeViewModel(
            streamAnswer: { _, _, _, _ in scriptedStream([.done(RecallResponse(
                answer: "Answer one",
                sources: [source],
                cards: [card]
            ))]) },
            createConversation: { meetingId, seriesId, title in
                createCalls.withLock { $0.append(CreateCall(meetingId: meetingId, seriesId: seriesId, title: title)) }
                return AskConversation(
                    id: AskConversationID("conversation-1"), meetingId: meetingId, seriesId: seriesId,
                    title: title, createdAt: "now", updatedAt: "now"
                )
            },
            appendMessage: { conversationId, role, content, sources, appendedCards in
                appendCalls.withLock {
                    $0.append(AppendCall(
                        conversationId: conversationId,
                        role: role,
                        content: content,
                        sources: sources,
                        cards: appendedCards
                    ))
                }
                return AskMessage(
                    id: AskMessageID(UUID().uuidString), conversationId: conversationId, role: role,
                    content: content, sources: sources, cards: appendedCards, createdAt: "now"
                )
            }
        )

        viewModel.composerText = "What did we decide about launch timing, exactly, in detail?"
        viewModel.send()
        await viewModel.streamTask?.value

        // A second message in the SAME thread must NOT create a second conversation.
        viewModel.composerText = "Follow-up question"
        viewModel.send()
        await viewModel.streamTask?.value

        let createSnapshot = createCalls.withLock { $0 }
        let appendSnapshot = appendCalls.withLock { $0 }

        #expect(createSnapshot.count == 1)
        #expect(createSnapshot[0]
            .title == String("What did we decide about launch timing, exactly, in detail?".prefix(40)))

        #expect(appendSnapshot.count == 4)
        #expect(appendSnapshot[0].role == "user")
        #expect(appendSnapshot[0].content == "What did we decide about launch timing, exactly, in detail?")
        #expect(appendSnapshot[1].role == "assistant")
        #expect(appendSnapshot[1].content == "Answer one")
        #expect(appendSnapshot[1].sources == [source])
        // The resolved card threads through to the persisted assistant message, verbatim — never
        // a fabricated/estimated re-derivation (No-Fake-State).
        #expect(appendSnapshot[1].cards == [card])
        // The user turn's append call never carries a card (only the entity-resolved assistant
        // turn can). Also asserts the ephemeral-rows contract (plan §5.3): the append call for the
        // assistant turn carries ONLY answer/sources/cards — never a thinking or tool-activity
        // payload (there is no such field to carry it in — the closure's own signature enforces
        // this structurally).
        #expect(appendSnapshot[0].cards.isEmpty)
        #expect(appendSnapshot[2].role == "user")
        #expect(appendSnapshot[2].content == "Follow-up question")
        #expect(appendSnapshot[0].conversationId == "conversation-1")
        #expect(appendSnapshot[2].conversationId == "conversation-1")

        // The in-memory transcript item also carries the same card (plan §5.2/§5.4 wiring).
        guard case let .assistant(_, _, _, itemCards) = viewModel.items[1].kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(itemCards == [card])
    }

    // MARK: - Test 11: conversation load hydration in order, incl. sources

    @Test("load(_:) hydrates items from the conversation detail in order, sources included")
    func loadHydratesItemsInOrderWithSources() async {
        let source = makeSource()
        let conversationId = AskConversationID("conversation-1")
        let detail = AskConversationDetail(
            conversation: AskConversation(
                id: conversationId, meetingId: nil, title: "Saved", createdAt: "t0", updatedAt: "t1"
            ),
            messages: [
                AskMessage(
                    id: "m1",
                    conversationId: conversationId,
                    role: "user",
                    content: "First question",
                    createdAt: "t0"
                ),
                AskMessage(
                    id: "m2", conversationId: conversationId, role: "assistant", content: "First answer",
                    sources: [source], createdAt: "t1"
                )
            ]
        )
        let viewModel = makeViewModel(loadConversation: { id in id == conversationId ? detail : nil })

        await viewModel.load(conversationId)

        #expect(viewModel.activeConversationId == conversationId)
        #expect(viewModel.items.count == 2)
        guard case let .user(firstText) = viewModel.items[0].kind else {
            Issue.record("expected a user row first"); return
        }
        #expect(firstText == "First question")
        guard case let .assistant(text, sources, streaming, cards) = viewModel.items[1].kind else {
            Issue.record("expected an assistant row second"); return
        }
        #expect(text == "First answer")
        #expect(sources == [source])
        #expect(!streaming)
        #expect(cards.isEmpty)
    }

    @Test("load(_:) hydrates a persisted assistant message's cards verbatim (plan §5.4)")
    func loadHydratesAssistantCard() async {
        let conversationId = AskConversationID("conversation-2")
        let card = RecallCardPayload.series(
            SeriesCardPayload(seriesId: "s1", title: "Design sync", meetingCount: 4, lastMeetingDate: "2026-07-01")
        )
        let detail = AskConversationDetail(
            conversation: AskConversation(
                id: conversationId, seriesId: "s1", title: "Saved", createdAt: "t0", updatedAt: "t1"
            ),
            messages: [
                AskMessage(
                    id: "m1", conversationId: conversationId, role: "user",
                    content: "When did the design sync meet?", createdAt: "t0"
                ),
                AskMessage(
                    id: "m2", conversationId: conversationId, role: "assistant", content: "It met 4 times.",
                    cards: [card], createdAt: "t1"
                )
            ]
        )
        let viewModel = makeViewModel(loadConversation: { id in id == conversationId ? detail : nil })

        await viewModel.load(conversationId)

        guard case let .assistant(_, _, _, hydratedCards) = viewModel.items[1].kind else {
            Issue.record("expected an assistant row second"); return
        }
        #expect(hydratedCards == [card])
    }

    // MARK: - Test 12: recent list keyed to scope (nil for global)

    private struct ScopeKey: Sendable, Equatable {
        let meetingId: MeetingID?
        let seriesId: SeriesID?
    }

    @Test("loadRecent() keys the list request to the CURRENT scope (nil/nil for global)")
    func recentListIsKeyedToScope() async {
        let capturedKeys = Mutex<[ScopeKey]>([])
        let globalVM = makeViewModel(scope: .global, listConversations: { meetingId, seriesId in
            capturedKeys.withLock { $0.append(ScopeKey(meetingId: meetingId, seriesId: seriesId)) }
            return []
        })
        await globalVM.loadRecent()
        #expect(capturedKeys.withLock { $0.last }?.meetingId == nil)
        #expect(capturedKeys.withLock { $0.last }?.seriesId == nil)

        let meetingVM = makeViewModel(
            scope: .meeting("meeting-9", title: "Standup"),
            listConversations: { meetingId, seriesId in
                capturedKeys.withLock { $0.append(ScopeKey(meetingId: meetingId, seriesId: seriesId)) }
                return []
            }
        )
        await meetingVM.loadRecent()
        #expect(capturedKeys.withLock { $0.last }?.meetingId == "meeting-9")
        #expect(capturedKeys.withLock { $0.last }?.seriesId == nil)

        let seriesVM = makeViewModel(
            scope: .series("series-9", title: "Sprint review"),
            listConversations: { meetingId, seriesId in
                capturedKeys.withLock { $0.append(ScopeKey(meetingId: meetingId, seriesId: seriesId)) }
                return []
            }
        )
        await seriesVM.loadRecent()
        #expect(capturedKeys.withLock { $0.last }?.meetingId == nil)
        #expect(capturedKeys.withLock { $0.last }?.seriesId == "series-9")
    }

    // MARK: - Test 13: unsupported-question frozen refusal copy verbatim

    @Test("an unsupported question surfaces the frozen refusal copy verbatim, with no settings affordance")
    func unsupportedQuestionSurfacesFrozenRefusalCopyVerbatim() async throws {
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            throwingStream(RecallEngineError.unsupportedQuestion)
        })

        viewModel.composerText = "What's the weather in Paris?"
        viewModel.send()
        await viewModel.streamTask?.value

        guard case let .error(message, showSettings) = try #require(viewModel.items.last).kind else {
            Issue.record("expected an error row"); return
        }
        #expect(
            message ==
                "Ask Meetings can answer only from saved local Ari Meeting transcripts, plus real calendar scheduling facts for today's events (event times and attendees) when supplied — a calendar entry means something is scheduled, never that it was recorded or discussed. It cannot access email, accounts, internet search, files outside Ari Meeting, or calendar dates other than today."
        )
        #expect(!showSettings)
    }

    // MARK: - Test 15 (`ask-meetings-agentic-tools.md` §8.8): thinking accumulates, folds, removed

    @Test("thinking deltas accumulate; first answer delta folds (not removes) the row; .done removes it")
    func thinkingAccumulatesFoldsThenIsRemoved() async throws {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Remind me about the meeting with Landon"
        viewModel.send()

        controllable.continuation.yield(.thinking("Let me "))
        controllable.continuation.yield(.thinking("check that."))
        await waitUntil {
            guard case let .thinking(text, _)? = viewModel.items.first(where: {
                if case .thinking = $0.kind {
                    true
                } else {
                    false
                }
            })?.kind else { return false }
            return text == "Let me check that."
        }
        let midThinking = try #require(viewModel.items.first {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
        guard case let .thinking(midText, midFolded) = midThinking.kind else {
            Issue.record("expected a thinking row"); return
        }
        #expect(midText == "Let me check that.")
        #expect(!midFolded, "must stay unfolded (live-visible) until the first ANSWER delta")

        controllable.continuation.yield(.delta("Landon Star's meeting was..."))
        await waitUntil {
            guard case let .thinking(_, folded)? = viewModel.items.first(where: {
                if case .thinking = $0.kind {
                    true
                } else {
                    false
                }
            })?.kind else { return false }
            return folded
        }
        // The thinking row's accumulated text survives the fold — folding is a presentation
        // change, not a truncation.
        guard case let .thinking(foldedText, folded) = try #require(viewModel.items.first {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        }).kind else {
            Issue.record("expected a thinking row"); return
        }
        #expect(foldedText == "Let me check that.")
        #expect(folded)

        controllable.continuation.yield(.done(RecallResponse(answer: "Landon Star's meeting was...", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
    }

    // MARK: - Test 16: tool-activity rows appear on start, complete on finish, removed at .done

    @Test("toolActivity rows appear running on .started, complete on .finished, and are removed at .done")
    func toolActivityRowsAppearCompleteThenAreRemoved() async {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Who is in the 6pm meeting later"
        viewModel.send()

        controllable.continuation.yield(.toolActivity(
            ToolActivity(toolName: "todays_events", displayLabel: "Checking today's calendar", phase: .started)
        ))
        await waitUntil {
            viewModel.items.contains {
                if case let .toolActivity(_, _, running, _) = $0.kind {
                    running
                } else {
                    false
                }
            }
        }
        guard let runningItem = viewModel.items.first(where: {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        }), case let .toolActivity(toolName, label, running, _) = runningItem.kind else {
            Issue.record("expected a running toolActivity row"); return
        }
        #expect(toolName == "todays_events")
        #expect(label == "Checking today's calendar")
        #expect(running)

        controllable.continuation.yield(.toolActivity(
            ToolActivity(
                toolName: "todays_events",
                displayLabel: "Checking today's calendar",
                phase: .finished(ok: true)
            )
        ))
        await waitUntil {
            viewModel.items.contains {
                if case let .toolActivity(_, _, running, ok) = $0.kind {
                    !running && ok
                } else {
                    false
                }
            }
        }
        // Same row updated in place, not a second row appended.
        #expect(viewModel.items.filter {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        }.count == 1)

        controllable.continuation.yield(.done(RecallResponse(answer: "Alex and Priya are attending.", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        // Ephemeral: no toolActivity row survives the terminal event (plan §5.3, never persisted).
        #expect(!viewModel.items.contains {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        })
    }

    @Test("a tool's failure surfaces ok: false on the completed row, still ephemeral at .done")
    func toolActivityFailureSurfacesOkFalse() async {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Find the meeting about pricing"
        viewModel.send()

        controllable.continuation.yield(.toolActivity(
            ToolActivity(toolName: "find_meeting", displayLabel: "Looking up meeting", phase: .started)
        ))
        controllable.continuation.yield(.toolActivity(
            ToolActivity(toolName: "find_meeting", displayLabel: "Looking up meeting", phase: .finished(ok: false))
        ))
        await waitUntil {
            viewModel.items.contains {
                if case let .toolActivity(_, _, running, ok) = $0.kind {
                    !running && !ok
                } else {
                    false
                }
            }
        }

        controllable.continuation.yield(.done(RecallResponse(answer: "I couldn't find that meeting.", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        #expect(!viewModel.items.contains {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        })
    }

    // MARK: - Test 17: superseding ask drops in-flight thinking + tool rows

    @Test("a new question mid-stream drops the prior ask's in-flight thinking and tool-activity rows")
    func newQuestionDropsInFlightThinkingAndToolRows() async throws {
        let firstControllable = makeControllableStream()
        let secondControllable = makeControllableStream()
        let callCount = Mutex<Int>(0)
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            let count = callCount.withLock { $0 += 1; return $0 }
            return count == 1 ? firstControllable.stream : secondControllable.stream
        })

        viewModel.composerText = "First question"
        viewModel.send()
        firstControllable.continuation.yield(.thinking("Thinking about the first one..."))
        firstControllable.continuation.yield(.toolActivity(
            ToolActivity(toolName: "search_transcripts", displayLabel: "Searching transcripts", phase: .started)
        ))
        await waitUntil {
            viewModel.items.contains {
                if case .toolActivity = $0.kind {
                    true
                } else {
                    false
                }
            }
        }

        viewModel.composerText = "Second question"
        viewModel.send()

        // The first ask's thinking/tool rows are gone the instant the second `send()` runs —
        // synchronous within `dropInFlightPlaceholders()`, not merely eventually consistent. The
        // second ask immediately adds its OWN fresh (empty, unfolded) thinking placeholder right
        // after — so the assertion is "no STALE thinking row survives", not "zero thinking rows".
        let thinkingRowsAfterSupersede = viewModel.items.compactMap { item -> (String, Bool)? in
            guard case let .thinking(text, folded) = item.kind else { return nil }
            return (text, folded)
        }
        #expect(thinkingRowsAfterSupersede.count == 1)
        #expect(thinkingRowsAfterSupersede.first?.0 == "", "the stale accumulated reasoning text must not survive")
        #expect(thinkingRowsAfterSupersede.first?.1 == false, "the fresh placeholder starts unfolded")
        #expect(!viewModel.items.contains {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        })

        secondControllable.continuation.yield(.done(RecallResponse(answer: "Second answer", sources: [])))
        secondControllable.continuation.finish()
        await viewModel.streamTask?.value
        firstControllable.continuation.finish()

        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(!viewModel.items.contains {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        })
        let lastAssistant = try #require(viewModel.items.last)
        guard case let .assistant(text, _, _, _) = lastAssistant.kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(text == "Second answer")
    }

    // MARK: - Test 18 (2026-07-23 live-testing fix): no eager assistant bubble; ordering; edge cases

    @Test("no assistant item exists before the first non-empty answer delta")
    func noAssistantItemBeforeFirstNonEmptyDelta() async {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Question"
        viewModel.send()

        // Immediately after send(): only the user row + the (empty, unfolded) thinking placeholder
        // — no assistant bubble yet.
        #expect(viewModel.items.count == 2)
        #expect(!viewModel.items.contains {
            if case .assistant = $0.kind {
                true
            } else {
                false
            }
        })

        controllable.continuation.yield(.thinking("Considering the question..."))
        await waitUntil {
            guard case let .thinking(text, _)? = viewModel.items.first(where: {
                if case .thinking = $0.kind {
                    true
                } else {
                    false
                }
            })?.kind else { return false }
            return text == "Considering the question..."
        }
        // Thinking deltas alone still must not create a bubble.
        #expect(!viewModel.items.contains {
            if case .assistant = $0.kind {
                true
            } else {
                false
            }
        })

        controllable.continuation.yield(.done(RecallResponse(answer: "Final answer", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value
    }

    @Test("after the first delta, ordering is [user, thinking(folded), toolActivity…, assistant]")
    func orderingAfterFirstDeltaIsUserThinkingToolsAssistant() async {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Who is in the 6pm meeting later"
        viewModel.send()

        controllable.continuation.yield(.toolActivity(
            ToolActivity(toolName: "todays_events", displayLabel: "Checking today's calendar", phase: .started)
        ))
        await waitUntil {
            viewModel.items.contains {
                if case .toolActivity = $0.kind {
                    true
                } else {
                    false
                }
            }
        }
        controllable.continuation.yield(.toolActivity(
            ToolActivity(
                toolName: "todays_events",
                displayLabel: "Checking today's calendar",
                phase: .finished(ok: true)
            )
        ))
        controllable.continuation.yield(.delta("Alex and Priya are attending."))
        await waitUntil {
            viewModel.items.contains {
                if case .assistant = $0.kind {
                    true
                } else {
                    false
                }
            }
        }

        // No new rows land after the bubble appears in this test, so the array itself reflects the
        // final in-flight ordering: user, thinking (folded), tool row, assistant (last).
        let kinds = viewModel.items.map(\.kind)
        guard case .user = kinds[0] else { Issue.record("expected user first"); return }
        guard case let .thinking(_, folded) = kinds[1] else { Issue.record("expected thinking second"); return }
        #expect(folded)
        guard case .toolActivity = kinds[2] else { Issue.record("expected toolActivity third"); return }
        guard case .assistant = kinds[3] else { Issue.record("expected assistant LAST"); return }
        #expect(kinds.count == 4)

        controllable.continuation.yield(.done(RecallResponse(answer: "Alex and Priya are attending.", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        // `.done` leaves exactly [user, assistant] — thinking + tool rows are ephemeral, removed.
        let finalKinds = viewModel.items.map(\.kind)
        #expect(finalKinds.count == 2)
        guard case .user = finalKinds[0] else { Issue.record("expected user first"); return }
        guard case .assistant = finalKinds[1] else { Issue.record("expected assistant second"); return }
    }

    @Test("an empty-delta-only stream never creates a bubble; .done creates it directly")
    func emptyDeltaOnlyStreamNeverCreatesBubbleUntilDone() async throws {
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            scriptedStream([
                .delta(""), .delta(""),
                .done(RecallResponse(answer: "Direct final answer", sources: []))
            ])
        })

        viewModel.composerText = "Question"
        viewModel.send()
        await viewModel.streamTask?.value

        // Only [user, assistant] survive — the empty deltas never created a bubble; `.done` created
        // it directly since none existed yet.
        #expect(viewModel.items.count == 2)
        guard case let .assistant(text, _, streaming, _) = try #require(viewModel.items.last).kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(text == "Direct final answer")
        #expect(!streaming)
    }

    @Test("supersession before any delta drops thinking/tools cleanly with no bubble ever created")
    func supersessionBeforeFirstDeltaCleansUpWithNoBubble() async throws {
        let firstControllable = makeControllableStream()
        let secondControllable = makeControllableStream()
        let callCount = Mutex<Int>(0)
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            let count = callCount.withLock { $0 += 1; return $0 }
            return count == 1 ? firstControllable.stream : secondControllable.stream
        })

        viewModel.composerText = "First question"
        viewModel.send()
        firstControllable.continuation.yield(.thinking("Reasoning about the first one..."))
        await waitUntil {
            guard case let .thinking(text, _)? = viewModel.items.first(where: {
                if case .thinking = $0.kind {
                    true
                } else {
                    false
                }
            })?.kind else { return false }
            return !text.isEmpty
        }
        // No bubble was ever created for the first ask (superseded before its first delta).
        #expect(!viewModel.items.contains {
            if case .assistant = $0.kind {
                true
            } else {
                false
            }
        })

        viewModel.composerText = "Second question"
        viewModel.send()

        secondControllable.continuation.yield(.done(RecallResponse(answer: "Second answer", sources: [])))
        secondControllable.continuation.finish()
        await viewModel.streamTask?.value
        firstControllable.continuation.finish()

        // [user1, user2, assistant2] — the first ask's user row is never removed (only its
        // ephemeral thinking/tool rows and any bubble are), so 3 rows survive, not 2.
        #expect(viewModel.items.count == 3)
        guard case let .assistant(text, _, _, _) = try #require(viewModel.items.last).kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(text == "Second answer")
    }

    @Test("supersession AFTER a bubble was created (partial answer streaming) drops the partial bubble too")
    func supersessionAfterBubbleCreatedDropsPartialBubble() async throws {
        let firstControllable = makeControllableStream()
        let secondControllable = makeControllableStream()
        let callCount = Mutex<Int>(0)
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in
            let count = callCount.withLock { $0 += 1; return $0 }
            return count == 1 ? firstControllable.stream : secondControllable.stream
        })

        viewModel.composerText = "First question"
        viewModel.send()
        firstControllable.continuation.yield(.delta("Partial first answer"))
        await waitUntil {
            viewModel.items.contains {
                if case .assistant = $0.kind {
                    true
                } else {
                    false
                }
            }
        }

        viewModel.composerText = "Second question"
        viewModel.send()

        // The partial bubble from the first (now-superseded) ask must not survive.
        #expect(!viewModel.items.contains {
            if case let .assistant(text, _, _, _) = $0.kind {
                text == "Partial first answer"
            } else {
                false
            }
        })

        secondControllable.continuation.yield(.done(RecallResponse(answer: "Second answer", sources: [])))
        secondControllable.continuation.finish()
        await viewModel.streamTask?.value
        firstControllable.continuation.finish()

        guard case let .assistant(text, _, _, _) = try #require(viewModel.items.last).kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(text == "Second answer")
    }

    @Test("an error thrown AFTER a bubble was created removes that partial bubble too")
    func errorAfterBubbleCreatedRemovesPartialBubble() async {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Question"
        viewModel.send()
        controllable.continuation.yield(.delta("Partial text before the failure"))
        await waitUntil {
            viewModel.items.contains {
                if case .assistant = $0.kind {
                    true
                } else {
                    false
                }
            }
        }

        controllable.continuation.finish(throwing: RecallEngineError.generationFailed("boom"))
        await viewModel.streamTask?.value

        #expect(!viewModel.items.contains {
            if case .assistant = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
        let errorItem = try? #require(viewModel.items.last)
        guard case let .error(message, _) = errorItem?.kind else {
            Issue.record("expected an error row"); return
        }
        #expect(message == "boom")
    }

    @Test("a thrown error drops any in-flight thinking and tool-activity rows too")
    func errorDropsThinkingAndToolActivityRows() async {
        let controllable = makeControllableStream()
        let viewModel = makeViewModel(streamAnswer: { _, _, _, _ in controllable.stream })

        viewModel.composerText = "Question"
        viewModel.send()
        controllable.continuation.yield(.thinking("Reasoning..."))
        controllable.continuation.yield(.toolActivity(
            ToolActivity(toolName: "search_transcripts", displayLabel: "Searching transcripts", phase: .started)
        ))
        await waitUntil {
            viewModel.items.contains {
                if case .toolActivity = $0.kind {
                    true
                } else {
                    false
                }
            }
        }

        controllable.continuation.finish(throwing: RecallEngineError.generationFailed("boom"))
        await viewModel.streamTask?.value

        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(!viewModel.items.contains {
            if case .toolActivity = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(viewModel.items.contains {
            if case .error = $0.kind {
                true
            } else {
                false
            }
        })
    }
}

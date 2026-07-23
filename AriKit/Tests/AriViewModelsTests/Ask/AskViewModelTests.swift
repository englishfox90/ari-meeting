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
        appendMessage: @escaping AskViewModel.AppendMessageOperation = { conversationId, role, content, sources, card in
            AskMessage(
                id: AskMessageID(UUID().uuidString), conversationId: conversationId, role: role,
                content: content, sources: sources, card: card, createdAt: "now"
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
        guard case let .assistant(text, sources, streaming, card) = assistantMidStream.kind else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(text == "Hello")
        #expect(card == nil)
        #expect(sources.isEmpty)
        #expect(streaming)
        #expect(viewModel.isStreaming)
        // The "thinking" placeholder is dropped once the first delta arrives.
        #expect(!viewModel.items.contains {
            if case .thinking = $0.kind {
                true
            } else {
                false
            }
        })

        controllable.continuation.yield(.delta(", world"))
        controllable.continuation.yield(.done(RecallResponse(answer: "Hello, world (final)", sources: [])))
        controllable.continuation.finish()
        await viewModel.streamTask?.value

        #expect(!viewModel.isStreaming)
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
        guard case let .assistant(text, sources, streaming, card) = assistantItem.kind else {
            Issue.record("expected an assistant row")
            return
        }
        #expect(text == response.answer)
        #expect(text != "raw partial chunks")
        #expect(sources == response.sources)
        #expect(!streaming)
        #expect(card == nil)
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
        let card: RecallCardPayload?
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
                card: card
            ))]) },
            createConversation: { meetingId, seriesId, title in
                createCalls.withLock { $0.append(CreateCall(meetingId: meetingId, seriesId: seriesId, title: title)) }
                return AskConversation(
                    id: AskConversationID("conversation-1"), meetingId: meetingId, seriesId: seriesId,
                    title: title, createdAt: "now", updatedAt: "now"
                )
            },
            appendMessage: { conversationId, role, content, sources, appendedCard in
                appendCalls.withLock {
                    $0.append(AppendCall(
                        conversationId: conversationId,
                        role: role,
                        content: content,
                        sources: sources,
                        card: appendedCard
                    ))
                }
                return AskMessage(
                    id: AskMessageID(UUID().uuidString), conversationId: conversationId, role: role,
                    content: content, sources: sources, card: appendedCard, createdAt: "now"
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
        #expect(appendSnapshot[1].card == card)
        // The user turn's append call never carries a card (only the entity-resolved assistant
        // turn can).
        #expect(appendSnapshot[0].card == nil)
        #expect(appendSnapshot[2].role == "user")
        #expect(appendSnapshot[2].content == "Follow-up question")
        #expect(appendSnapshot[0].conversationId == "conversation-1")
        #expect(appendSnapshot[2].conversationId == "conversation-1")

        // The in-memory transcript item also carries the same card (plan §5.2 wiring).
        guard case let .assistant(_, _, _, itemCard) = viewModel.items[1].kind else {
            Issue.record("expected an assistant row"); return
        }
        #expect(itemCard == card)
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
        guard case let .assistant(text, sources, streaming, card) = viewModel.items[1].kind else {
            Issue.record("expected an assistant row second"); return
        }
        #expect(text == "First answer")
        #expect(sources == [source])
        #expect(!streaming)
        #expect(card == nil)
    }

    @Test("load(_:) hydrates a persisted assistant message's card verbatim (Slice C)")
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
                    card: card, createdAt: "t1"
                )
            ]
        )
        let viewModel = makeViewModel(loadConversation: { id in id == conversationId ? detail : nil })

        await viewModel.load(conversationId)

        guard case let .assistant(_, _, _, hydratedCard) = viewModel.items[1].kind else {
            Issue.record("expected an assistant row second"); return
        }
        #expect(hydratedCard == card)
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
                "Ask Meetings can answer only from saved local Ari Meeting transcripts, plus real calendar scheduling facts (event times and attendees) when supplied — a calendar entry means something is scheduled, never that it was recorded or discussed. It cannot access email, accounts, internet search, or files outside Ari Meeting."
        )
        #expect(!showSettings)
    }
}

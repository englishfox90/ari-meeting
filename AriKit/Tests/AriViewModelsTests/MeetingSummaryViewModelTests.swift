//
//  MeetingSummaryViewModelTests.swift — docs/plans/swift-meeting-generation-flow.md, Track 1 §1.
//
//  Closure-level tests (mirrors `SpeakerIdentificationViewModelTests`): the designated
//  closure-injected `init` is exercised directly rather than a real `SummaryRunner`, so these
//  tests stay headless and independent of `AppDatabase`/`SummaryService` wiring (that coverage
//  lives in `SummaryRunnerTests`).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingSummaryViewModel")
@MainActor
struct MeetingSummaryViewModelTests {
    private let meetingId: MeetingID = "meeting-1"

    private struct StubError: Error {}

    private actor CallSpy {
        private(set) var callCount = 0
        func record() { callCount += 1 }
    }

    private func makeSummary(templateId: String? = "standard_meeting") -> Summary {
        Summary(
            id: "summary-1", meetingId: meetingId, bodyMarkdown: "# Recap",
            templateId: templateId, createdAt: Date(), updatedAt: Date()
        )
    }

    private func makeViewModel(
        generateOperation: @escaping MeetingSummaryViewModel.GenerateOperation = { _, _, _, _ in
            Summary(id: "summary-1", meetingId: "meeting-1", bodyMarkdown: "# Recap", createdAt: Date(), updatedAt: Date())
        },
        cancelOperation: @escaping MeetingSummaryViewModel.CancelOperation = { _ in },
        loadTemplatesOperation: @escaping MeetingSummaryViewModel.LoadTemplatesOperation = { [] }
    ) -> MeetingSummaryViewModel {
        MeetingSummaryViewModel(
            generateOperation: generateOperation,
            cancelOperation: cancelOperation,
            loadTemplatesOperation: loadTemplatesOperation
        )
    }

    @Test("honest idle before any generate call")
    func honestIdleBeforeGenerate() {
        let viewModel = makeViewModel()
        #expect(viewModel.state == .idle)
        #expect(viewModel.templates.isEmpty)
        #expect(viewModel.selectedTemplateID == nil)
    }

    @Test("generate success sets .idle and returns the real summary")
    func generateSuccessReturnsSummary() async {
        let expected = makeSummary()
        let viewModel = makeViewModel(generateOperation: { _, _, _, _ in expected })

        let result = await viewModel.generate(meetingId: meetingId, speakerCount: 3)

        #expect(result?.id == expected.id)
        #expect(result?.bodyMarkdown == expected.bodyMarkdown)
        #expect(viewModel.state == .idle)
    }

    @Test("generate failure surfaces .failed honestly and returns nil")
    func generateFailureSurfacesFailedState() async {
        let viewModel = makeViewModel(generateOperation: { _, _, _, _ in throw StubError() })

        let result = await viewModel.generate(meetingId: meetingId, speakerCount: nil)

        #expect(result == nil)
        guard case let .failed(message) = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("Swift cancellation maps to .idle, not .failed")
    func swiftCancellationMapsToIdle() async {
        let viewModel = makeViewModel(generateOperation: { _, _, _, _ in throw CancellationError() })

        let result = await viewModel.generate(meetingId: meetingId, speakerCount: nil)

        #expect(result == nil)
        #expect(viewModel.state == .idle)
    }

    @Test("LLMError.cancelled maps to .idle, not .failed")
    func llmCancelledMapsToIdle() async {
        let viewModel = makeViewModel(generateOperation: { _, _, _, _ in throw LLMError.cancelled })

        let result = await viewModel.generate(meetingId: meetingId, speakerCount: nil)

        #expect(result == nil)
        #expect(viewModel.state == .idle)
    }

    @Test("a non-cancellation LLMError still surfaces .failed honestly")
    func nonCancellationLLMErrorSurfacesFailed() async {
        let viewModel = makeViewModel(generateOperation: { _, _, _, _ in
            throw LLMError.notConfigured("no model configured")
        })

        let result = await viewModel.generate(meetingId: meetingId, speakerCount: nil)

        #expect(result == nil)
        guard case .failed = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
    }

    @Test("a second generate() call while already generating is refused, not interleaved")
    func reentrantGenerateIsRefused() async {
        let spy = CallSpy()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let viewModel = makeViewModel(generateOperation: { _, _, _, _ in
            await spy.record()
            for await _ in gate { break }
            return Summary(id: "summary-1", meetingId: "meeting-1", bodyMarkdown: "# Recap", createdAt: Date(), updatedAt: Date())
        })

        let firstRun = Task { await viewModel.generate(meetingId: meetingId, speakerCount: nil) }
        while viewModel.state != .generating {
            await Task.yield()
        }

        let second = await viewModel.generate(meetingId: meetingId, speakerCount: nil)
        #expect(second == nil)
        #expect(await spy.callCount == 1, "the reentrant call must not start a second underlying generation")

        gateContinuation.finish()
        let first = await firstRun.value
        #expect(first != nil)
        #expect(viewModel.state == .idle)
    }

    @Test("loadTemplates yields whatever the operation returns, honestly empty otherwise")
    func loadTemplatesYieldsOperationResult() {
        let viewModel = makeViewModel(loadTemplatesOperation: {
            [
                TemplateOption(id: "daily_standup", name: "Daily Standup"),
                TemplateOption(id: "standard_meeting", name: "Standard Meeting Notes")
            ]
        })

        viewModel.loadTemplates()

        #expect(viewModel.templates.map(\.id).sorted() == ["daily_standup", "standard_meeting"])
    }

    @Test("generate forwards the selected template id and trimmed custom instructions")
    func generateForwardsTemplateAndInstructions() async {
        actor Captured {
            var templateID: String?
            var instructions: String?
            func store(_ template: String?, _ instructions: String) {
                templateID = template
                self.instructions = instructions
            }
        }
        let captured = Captured()
        let viewModel = makeViewModel(generateOperation: { _, templateID, _, instructions in
            await captured.store(templateID, instructions)
            return Summary(id: "s", meetingId: "meeting-1", bodyMarkdown: "# Recap", createdAt: Date(), updatedAt: Date())
        })
        viewModel.selectedTemplateID = "one_on_one"
        viewModel.customInstructions = "  Focus on decisions.  "

        _ = await viewModel.generate(meetingId: meetingId, speakerCount: nil)

        #expect(await captured.templateID == "one_on_one")
        #expect(await captured.instructions == "Focus on decisions.")
    }

    @Test("reset clears custom instructions so they never bleed across meetings")
    func resetClearsCustomInstructions() {
        let viewModel = makeViewModel()
        viewModel.customInstructions = "Only for meeting A"
        viewModel.reset()
        #expect(viewModel.customInstructions.isEmpty)
    }

    @Test("restoreSelection mirrors the summary's templateId, or nil for Auto")
    func restoreSelectionMirrorsSummaryTemplateId() {
        let viewModel = makeViewModel()

        viewModel.restoreSelection(from: makeSummary(templateId: "daily_standup"))
        #expect(viewModel.selectedTemplateID == "daily_standup")

        viewModel.restoreSelection(from: makeSummary(templateId: nil))
        #expect(viewModel.selectedTemplateID == nil)

        viewModel.selectedTemplateID = "daily_standup"
        viewModel.restoreSelection(from: nil)
        #expect(viewModel.selectedTemplateID == nil)
    }

    @Test("reset clears a stale .failed/.generating state back to .idle")
    func resetClearsStaleState() async {
        // .failed → .idle (the cross-meeting bleed guard: a previous meeting's error must not
        // survive onto the next meeting the shared view model is reused for).
        let failing = makeViewModel(generateOperation: { _, _, _, _ in throw StubError() })
        _ = await failing.generate(meetingId: meetingId, speakerCount: nil)
        guard case .failed = failing.state else {
            Issue.record("precondition: expected .failed, got \(failing.state)")
            return
        }
        failing.reset()
        #expect(failing.state == .idle)
    }

    @Test("cancel forwards to the injected cancel operation")
    func cancelForwardsToOperation() async {
        let spy = CallSpy()
        let viewModel = makeViewModel(cancelOperation: { _ in await spy.record() })

        await viewModel.cancel(meetingId: meetingId)

        #expect(await spy.callCount == 1)
    }
}

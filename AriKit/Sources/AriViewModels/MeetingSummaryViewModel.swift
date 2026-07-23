//
//  MeetingSummaryViewModel.swift — the saved-meeting's manual summary actions (docs/plans/
//  swift-meeting-generation-flow.md, Track 1 §1).
//
//  Headless (no app-target dependency), mirroring `SpeakerIdentificationViewModel`'s
//  closure-injected shape: a designated `init` takes plain operations, tested with fakes; a
//  `public convenience init(runner:customTemplateDirectory:)` is the real app wiring, composing
//  `SummaryRunner`'s operations into the closures below (same pattern as
//  `SpeakerIdentificationViewModel`'s `service`-composing convenience initializer).
//
//  Honest state spine (No-Fake-State, invariant I2): `.idle` until asked to generate, `.generating`
//  while in flight, `.failed(String)` with the real error text on failure — never a fabricated
//  summary or progress step. On failure the VM has no summary state of its own to clobber; the
//  view keeps showing whatever summary it already loaded (`MeetingDetailViewModel.summary`)
//  alongside this VM's honest error line.
//
//  Reentrancy guard (mirrors `SpeakerIdentificationViewModel.run`): a second `generate` call while
//  already `.generating` is refused rather than starting a second in-flight generation that could
//  race the first's Store writes.
//
import AriKit
import Foundation
import Observation

/// Honest generation-state spine for the saved-meeting summary actions.
public enum SummaryGenerationState: Equatable {
    case idle
    case generating
    case failed(String)
}

/// One selectable template in the "Change template" picker (← `TemplateRegistry`/`Template.name`).
public struct TemplateOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
@Observable
public final class MeetingSummaryViewModel {
    public private(set) var state: SummaryGenerationState = .idle
    /// The built-in (and, later, custom-directory) templates available to the picker. Honest
    /// empty array until `loadTemplates()` runs — never fabricated.
    public private(set) var templates: [TemplateOption] = []
    /// `nil` ⇒ "Auto (suggest)". Set from the picker, or restored from an existing summary's
    /// `templateId` via `restoreSelection(from:)`.
    public var selectedTemplateID: String?
    /// Free-text steering for the summary LLM (← the old app's "Instructions" toolbar control).
    /// Empty ⇒ no extra context injected (the engine only appends a `<user_context>` block when
    /// this is non-empty). Bound directly by the summary-actions "Instructions" field.
    public var customInstructions: String = ""

    private let generateOperation: GenerateOperation
    private let cancelOperation: CancelOperation
    private let loadTemplatesOperation: LoadTemplatesOperation

    typealias GenerateOperation = @Sendable (
        _ meetingId: MeetingID,
        _ templateId: String?,
        _ speakerCount: Int?,
        _ customInstructions: String
    ) async throws -> Summary

    typealias CancelOperation = @Sendable (_ meetingId: MeetingID) async -> Void

    typealias LoadTemplatesOperation = @Sendable () -> [TemplateOption]

    public convenience init(runner: SummaryRunner, customTemplateDirectory: URL? = nil) {
        self.init(
            generateOperation: { meetingId, templateId, speakerCount, customInstructions in
                try await runner.generate(
                    meetingId: meetingId,
                    templateId: templateId,
                    speakerCount: speakerCount,
                    customInstructions: customInstructions
                )
            },
            cancelOperation: { meetingId in
                _ = await runner.cancel(meetingId)
            },
            loadTemplatesOperation: {
                TemplateRegistry.listTemplateIDs(customDirectory: customTemplateDirectory).compactMap { id in
                    guard let template = try? TemplateRegistry.template(
                        id: id,
                        customDirectory: customTemplateDirectory
                    ) else {
                        return nil
                    }
                    return TemplateOption(id: id, name: template.name)
                }
            }
        )
    }

    init(
        generateOperation: @escaping GenerateOperation,
        cancelOperation: @escaping CancelOperation,
        loadTemplatesOperation: @escaping LoadTemplatesOperation
    ) {
        self.generateOperation = generateOperation
        self.cancelOperation = cancelOperation
        self.loadTemplatesOperation = loadTemplatesOperation
    }

    /// Loads the available templates for the picker. Synchronous — `TemplateRegistry` is a pure,
    /// in-memory lookup (no I/O beyond an optional custom-directory listing).
    public func loadTemplates() {
        templates = loadTemplatesOperation()
    }

    /// Restores the picker's selection from an existing summary's provenance, so re-opening
    /// "Change template" reflects what actually generated the summary on screen — never a
    /// fabricated default. `nil` (no summary, or a summary with no recorded `templateId`) restores
    /// to "Auto (suggest)".
    public func restoreSelection(from summary: Summary?) {
        selectedTemplateID = summary?.templateId
    }

    /// Generates (or regenerates) the summary for `meetingId` using `selectedTemplateID`
    /// (`nil` ⇒ auto-suggest, handled by `SummaryRunner`). Refuses a second concurrent call while
    /// already `.generating` (reentrancy guard). Cancellation (either Swift's cooperative
    /// `CancellationError` or the engine's `LLMError.cancelled`) maps to `.idle`, not `.failed` —
    /// a user-initiated cancel is not a failure.
    public func generate(meetingId: MeetingID, speakerCount: Int?) async -> Summary? {
        if case .generating = state {
            return nil
        }
        state = .generating
        do {
            let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = try await generateOperation(meetingId, selectedTemplateID, speakerCount, instructions)
            state = .idle
            return summary
        } catch is CancellationError {
            state = .idle
            return nil
        } catch let error as LLMError {
            if case .cancelled = error {
                state = .idle
                return nil
            }
            state = .failed(UserFacingError.message(error))
            return nil
        } catch {
            state = .failed(UserFacingError.message(error))
            return nil
        }
    }

    /// Cancels an in-flight generation for `meetingId`, if any.
    public func cancel(meetingId: MeetingID) async {
        await cancelOperation(meetingId)
    }

    /// Clears transient generation state back to `.idle`. Called when the host detail view is
    /// reused for a DIFFERENT meeting (the view model is a single `@State` shared across the split
    /// detail column), so a `.failed` error — or a stale `.generating` indicator — from the
    /// previous meeting never bleeds onto the next one (No-Fake-State). `templates` are
    /// meeting-independent and left intact; `selectedTemplateID` is re-derived by
    /// `restoreSelection(from:)` at the same call site. `customInstructions` is user-entered
    /// steering for THIS meeting, so it is cleared too — a stale instruction from the previously
    /// shown meeting must never silently apply to the next one's regenerate (No-Fake-State).
    public func reset() {
        state = .idle
        customInstructions = ""
    }
}

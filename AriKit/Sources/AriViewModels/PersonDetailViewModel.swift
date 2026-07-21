//
//  PersonDetailViewModel.swift — the Person detail screen's view model
//  (docs/plans/arikit-native-read-ui.md §2.3/§9 S6e).
//
//  One-shot read (no live observation, mirroring `MeetingDetailViewModel`'s detail-VM pattern).
//  A thrown error maps to `.failed(String)`.
//
//  TODO(S6): there is no person→meetings reverse query today — `PersonRepository` only exposes
//  `participants(inMeeting:)` (meeting → persons), not the reverse. Composing it here by scanning
//  every meeting via `MeetingRepository.all()` + `PersonRepository.participants(inMeeting:)` would
//  be an O(n) meetings scan hidden in a "detail" screen and was explicitly ruled out (plan
//  instructions: do not add repository methods, do not fabricate a meeting list) — so
//  `participantMeetings` stays honestly empty until a real
//  `PersonRepository.meetings(forPerson:)`-shaped query lands in the Store.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class PersonDetailViewModel {
    public private(set) var person: LoadState<Person> = .loading
    /// Meetings this person participated in. Honestly empty today — see file header TODO(S6).
    public private(set) var participantMeetings: [Meeting] = []

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func load(_ id: PersonID) async {
        do {
            guard let resolved = try await database.persons.find(id) else {
                person = .failed("Person not found.")
                return
            }
            person = .loaded(resolved)
            // participantMeetings intentionally stays [] — see file header TODO(S6).
        } catch {
            person = .failed(String(describing: error))
        }
    }
}

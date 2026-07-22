//
//  FakeNotificationScheduler.swift — an in-memory `NotificationScheduling` for view-model tests.
//  An actor (so it's `Sendable` and thread-safe) recording every post/cancel and modelling the
//  OS's pending set (a `.date`-triggered post becomes pending; a cancel removes it).
//
import Foundation
@testable import AriViewModels

actor FakeNotificationScheduler: NotificationScheduling {
    private var authorization: NotificationAuthorization
    private var pending: Set<String>
    private(set) var posted: [NotificationRequest] = []
    private(set) var cancelledBatches: [Set<String>] = []
    private(set) var requestAuthorizationCallCount = 0

    init(authorization: NotificationAuthorization = .authorized, pending: Set<String> = []) {
        self.authorization = authorization
        self.pending = pending
    }

    func authorizationStatus() -> NotificationAuthorization { authorization }

    func requestAuthorization() -> NotificationAuthorization {
        requestAuthorizationCallCount += 1
        return authorization
    }

    func pendingReminderIdentifiers() -> Set<String> { pending }

    func cancel(identifiers: Set<String>) {
        cancelledBatches.append(identifiers)
        pending.subtract(identifiers)
    }

    func post(_ request: NotificationRequest) {
        posted.append(request)
        if case .date = request.trigger {
            pending.insert(request.id)
        }
    }

    // MARK: - Test controls / assertions

    func setAuthorization(_ status: NotificationAuthorization) { authorization = status }

    var postedReminders: [NotificationRequest] {
        posted.filter { $0.category == .meetingReminder }
    }

    var postedSummaries: [NotificationRequest] {
        posted.filter { $0.category == .summaryReady }
    }

    var allCancelled: Set<String> {
        cancelledBatches.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}

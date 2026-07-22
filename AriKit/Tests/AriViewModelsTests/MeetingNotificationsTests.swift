//
//  MeetingNotificationsTests.swift — the @MainActor coordinator over the notification seam:
//  reminder reconciliation gating + the summary-ready "long generation" threshold.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingNotifications")
@MainActor
struct MeetingNotificationsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeEvent(id: CalendarEventID, startOffset: TimeInterval) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarId: "cal-1",
            title: "Weekly Sync",
            startTime: now.addingTimeInterval(startOffset),
            endTime: now.addingTimeInterval(startOffset + 1800),
            isAllDay: false,
            attendees: []
        )
    }

    private func makeNotifications(
        db: AppDatabase,
        scheduler: FakeNotificationScheduler
    ) -> MeetingNotifications {
        let fixedNow = now
        return MeetingNotifications(scheduler: scheduler, database: db, now: { fixedNow })
    }

    // MARK: - Reminders

    @Test("reconcile schedules reminders for future events when enabled + authorized")
    func reconcileSchedulesWhenAuthorized() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.upsert(makeEvent(id: "ev-1", startOffset: 30 * 60))
        let scheduler = FakeNotificationScheduler(authorization: .authorized)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.reconcileReminders()

        let reminders = await scheduler.postedReminders
        #expect(reminders.count == 1)
        #expect(reminders.first?.userInfo[NotificationUserInfoKey.eventId] == "ev-1")
        #expect(notifications.authorization == .authorized)
    }

    @Test("reconcile cancels leftover reminders when the toggle is off")
    func reconcileCancelsWhenDisabled() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setBool(false, forKey: .notificationsMeetingReminders)
        try await db.calendarEvents.upsert(makeEvent(id: "ev-1", startOffset: 30 * 60))
        let stale = MeetingReminderPlanner.identifier(for: "ev-1")
        let scheduler = FakeNotificationScheduler(authorization: .authorized, pending: [stale])
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.reconcileReminders()

        #expect(await scheduler.postedReminders.isEmpty)
        #expect(await scheduler.allCancelled == [stale])
    }

    @Test("reconcile cancels leftover reminders and posts nothing when authorization is denied")
    func reconcileCancelsWhenDenied() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.upsert(makeEvent(id: "ev-1", startOffset: 30 * 60))
        let stale = MeetingReminderPlanner.identifier(for: "ev-old")
        let scheduler = FakeNotificationScheduler(authorization: .denied, pending: [stale])
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.reconcileReminders()

        #expect(await scheduler.postedReminders.isEmpty)
        #expect(await scheduler.allCancelled == [stale])
        #expect(notifications.authorization == .denied)
    }

    @Test("reconcile honours a stored lead time")
    func reconcileUsesStoredLeadTime() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setString("10", forKey: .notificationsReminderLeadMinutes)
        try await db.calendarEvents.upsert(makeEvent(id: "ev-1", startOffset: 30 * 60))
        let scheduler = FakeNotificationScheduler(authorization: .authorized)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.reconcileReminders()

        let reminder = try #require(await scheduler.postedReminders.first)
        if case let .date(fireDate) = reminder.trigger {
            // 30-min start − 10-min lead = 20 min from now.
            #expect(fireDate == now.addingTimeInterval(20 * 60))
        } else {
            Issue.record("expected a .date trigger")
        }
    }

    // MARK: - Launch preparation

    @Test("prepareForLaunch requests authorization when a feature is on but permission is undetermined")
    func prepareRequestsAuthorizationWhenNeeded() async throws {
        let db = try AppDatabase.makeInMemory()
        let scheduler = FakeNotificationScheduler(authorization: .notDetermined)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.prepareForLaunch()

        #expect(await scheduler.requestAuthorizationCallCount == 1)
    }

    @Test("prepareForLaunch does not prompt when all notification features are off")
    func prepareSkipsWhenAllDisabled() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setBool(false, forKey: .notificationsMeetingReminders)
        try await db.settings.setBool(false, forKey: .notificationsSummaryReady)
        let scheduler = FakeNotificationScheduler(authorization: .notDetermined)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.prepareForLaunch()

        #expect(await scheduler.requestAuthorizationCallCount == 0)
    }

    @Test("prepareForLaunch does not re-prompt once authorization is already decided")
    func prepareSkipsWhenAlreadyDecided() async throws {
        let db = try AppDatabase.makeInMemory()
        let scheduler = FakeNotificationScheduler(authorization: .authorized)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.prepareForLaunch()

        #expect(await scheduler.requestAuthorizationCallCount == 0)
    }

    // MARK: - Summary-ready

    @Test("summaryGenerated posts for a long generation when enabled + authorized")
    func summaryPostsForLongGeneration() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(id: "m-1", title: "Roadmap", createdAt: now, updatedAt: now))
        let scheduler = FakeNotificationScheduler(authorization: .authorized)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.summaryGenerated(meetingId: "m-1", elapsed: .seconds(45))

        let summaries = await scheduler.postedSummaries
        #expect(summaries.count == 1)
        #expect(summaries.first?.userInfo[NotificationUserInfoKey.meetingId] == "m-1")
        #expect(summaries.first?.body.contains("Roadmap") == true)
    }

    @Test("summaryGenerated stays silent for a short generation")
    func summarySilentForShortGeneration() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(id: "m-1", title: "Quick", createdAt: now, updatedAt: now))
        let scheduler = FakeNotificationScheduler(authorization: .authorized)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.summaryGenerated(meetingId: "m-1", elapsed: .seconds(10))

        #expect(await scheduler.postedSummaries.isEmpty)
    }

    @Test("summaryGenerated stays silent when the toggle is off")
    func summarySilentWhenDisabled() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setBool(false, forKey: .notificationsSummaryReady)
        try await db.meetings.upsert(Meeting(id: "m-1", title: "Roadmap", createdAt: now, updatedAt: now))
        let scheduler = FakeNotificationScheduler(authorization: .authorized)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.summaryGenerated(meetingId: "m-1", elapsed: .seconds(45))

        #expect(await scheduler.postedSummaries.isEmpty)
    }

    @Test("summaryGenerated stays silent when authorization is denied")
    func summarySilentWhenDenied() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(id: "m-1", title: "Roadmap", createdAt: now, updatedAt: now))
        let scheduler = FakeNotificationScheduler(authorization: .denied)
        let notifications = makeNotifications(db: db, scheduler: scheduler)

        await notifications.summaryGenerated(meetingId: "m-1", elapsed: .seconds(45))

        #expect(await scheduler.postedSummaries.isEmpty)
    }
}

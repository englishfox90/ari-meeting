# Swift Notifications — Calendar Reminders + Summary-Ready

Ports the frozen Rust `notifications/` subsystem to the Swift-native app, scoped to the two cases
we actually ship. Before this, the Settings "Notifications" group was honestly-disabled
("Notifications haven't been ported to the Swift app yet").

## Scope (what shipped)

1. **Calendar meeting reminders (F5)** — a local notification fires *N* minutes before each synced,
   non-all-day calendar event. Its notification carries a **Start Recording** action; tapping the
   action *or* the notification body starts capturing immediately (product decision 2026-07-22) and
   navigates to the recording page, primed with the event's title + calendar link.
2. **Summary-ready** — when a post-recording summary finishes generating **and** that generation
   took **≥ 30 s** (the "long summary" bar — the user has likely tabbed away), a notification is
   delivered. Tapping it opens that meeting.

Recording start/stop alerts are a *distinct* notification and remain honestly-disabled (they'd hook
the recording lifecycle, not wired yet).

## Layering (why the split)

The framework-touching code is isolated in the app target so `AriViewModels` never imports
`UserNotifications` and stays unit-testable.

- **`AriViewModels/Notifications/`** (no `UserNotifications` import):
  - `NotificationScheduling` — the seam (protocol) + framework-agnostic value types
    (`NotificationRequest`, `NotificationTrigger`, `NotificationAuthorization`,
    `NotificationCategory`) + the copy factories (the one place wording lives).
    `NotificationAuthorizing` is the narrow auth subset `SettingsViewModel` depends on.
  - `MeetingReminderPlanner` — **pure** reconcile core: (events, leadTime, now, currentlyScheduled)
    → {toSchedule, toCancel}. Exhaustively unit-tested.
  - `MeetingNotifications` — `@MainActor @Observable` coordinator: reconciles reminders against the
    calendar + settings, and gates the summary-ready post on the ≥30 s threshold + toggle + OS
    authorization. Injectable clock for deterministic tests.
- **`Ari/App/Notifications/`** (concrete `UserNotifications`):
  - `SystemNotificationScheduler` — `NotificationScheduling` over `UNUserNotificationCenter`.
    Stateless (computed `center`, no stored non-Sendable state) so it's unconditionally `Sendable`.
    Registers the categories/actions; uses a `UNCalendarNotificationTrigger` (wall-clock, survives
    sleep) for scheduled reminders.
  - `NotificationActionHandler` — the `UNUserNotificationCenterDelegate`; routes a tapped
    notification back to `AppEnvironment` via `@MainActor` closures. Presents notifications even when
    foregrounded.
  - `ReminderRefreshScheduler` — the 15-min reconcile loop (parity with `CalendarSyncScheduler`),
    owned by `AppEnvironment`. Toggling a pref reconciles *immediately* via the Settings VM's
    `onNotificationSettingsChanged` closure; this loop catches calendar syncs + the passage of time.

## Seams touched

- **Settings** — 3 new `SettingKey`s (`notificationsMeetingReminders`,
  `notificationsReminderLeadMinutes` (string-encoded int), `notificationsSummaryReady`). New
  `SettingsViewModel` prefs/setters/`Availability`, plus an honest `notificationAuthorization` banner
  (No-Fake-State — the preference is real; we honestly surface the OS permission state): `.denied`
  points to System Settings, `.notDetermined` pairs with an "Allow Notifications" button. Lead-time
  picker options: 1 / 5 / 10 / 15 min (default 5).
- **Authorization** — the toggles default ON, so on first launch `ReminderRefreshScheduler`'s first
  pass calls `MeetingNotifications.prepareForLaunch()`, which requests OS authorization once when a
  feature is enabled but permission is still `.notDetermined` (otherwise a shipped-on toggle would
  read "on" while the feature is silently dead — never prompted, reconcile bails). The periodic
  reconcile loop itself never prompts (status-only), so it can't nag from the background.
- **Post-recording pipeline** — `MeetingProcessingCoordinator` gained an optional
  `notifySummaryGenerated(meetingId, elapsed)` hook, fired only after a summary *actually* generated,
  carrying the real generation `Duration` (`ContinuousClock`). The notifier decides "long enough".
- **App shell** — `AppEnvironment` owns the notifier + delegate + reconcile loop; a
  `pendingNavigation` intent (raised from a notification tap, outside the view tree) is observed by
  `RootSplitView` and applied to `selectedSection` / `path`, then cleared.

## Invariants preserved

- **Consent-before-record** — the reminder's "start immediately" path still goes through the
  session's real consent edges (`requestStart()` → `confirmConsentRequested()`), i.e. the same code
  path the in-app Record button uses; no new silent-capture edge was introduced.
- **No-Fake-State** — every notification is backed by a real event/summary; authorization is the OS's
  real status; a disabled toggle clears any leftover scheduled reminders rather than leaving stale
  ones armed.

## Not done / follow-ons

- Recording start/stop alerts (`generalRecordingAlerts`) stay disabled.
- No per-event snooze / multiple reminder times (single lead time).
- Reminders are scheduled for a 14-day horizon; events beyond it get a reminder once they enter the
  window on a later reconcile.

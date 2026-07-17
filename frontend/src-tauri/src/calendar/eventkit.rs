// Native EventKit access (F4). All real Objective-C calls live behind
// `#[cfg(target_os = "macos")]`; the rest of the crate (and non-macOS builds) only ever
// see the safe, pure-Rust `NativeCalendar` / `NativeEvent` shapes from `calendar::models`.
//
// Permission prompts must run on the macOS main thread — mirror the existing
// `audio::devices::discovery::request_audio_permission_on_main` pattern used by
// `trigger_microphone_permission` in lib.rs.

use crate::calendar::models::{Attendee, NativeCalendar, NativeEvent};

#[cfg(target_os = "macos")]
mod macos_impl {
    use super::*;
    use chrono::{DateTime, TimeZone, Utc};
    use objc2::rc::Retained;
    use objc2_event_kit::{EKAuthorizationStatus, EKCalendar, EKEntityType, EKEvent, EKEventStore};
    use objc2_foundation::{NSArray, NSDate, NSString};

    /// Maps an `EKAuthorizationStatus` to the contract's status strings.
    fn status_to_string(status: EKAuthorizationStatus) -> String {
        match status {
            EKAuthorizationStatus::NotDetermined => "notDetermined",
            EKAuthorizationStatus::Restricted => "restricted",
            EKAuthorizationStatus::Denied => "denied",
            EKAuthorizationStatus::FullAccess => "fullAccess",
            // WriteOnly has no calendar-read use here; treat as not-yet-authorized for reads.
            _ => "denied",
        }
        .to_string()
    }

    pub fn permission_status() -> String {
        // Class method — safe to call without an EKEventStore instance.
        let status =
            unsafe { EKEventStore::authorizationStatusForEntityType(EKEntityType::Event) };
        status_to_string(status)
    }

    /// Runs the EventKit full-access prompt. Must be invoked on the main thread (the
    /// completion handler is dispatched back onto the calling thread by EventKit, so
    /// running the request itself on the main thread keeps the whole round-trip there).
    pub fn request_full_access_on_main(
        result_sender: tokio::sync::oneshot::Sender<Result<String, String>>,
    ) {
        use block2::RcBlock;
        use objc2_foundation::NSError;
        use std::sync::{Arc, Mutex};

        let store = unsafe { EKEventStore::new() };
        let sender = Arc::new(Mutex::new(Some(result_sender)));
        let completion_sender = sender.clone();
        // The EKEventStore MUST stay alive until EventKit invokes the completion
        // handler. If `store` were only a local, it would be released at the end of
        // this function — mid-request — and macOS would tear the request down (the
        // TCC prompt flashes and disappears, and the completion handler never fires).
        // Capturing a retained clone inside the block ties the store's lifetime to the
        // block, which we leak below, so both survive the async round-trip.
        let store_keepalive = store.clone();

        let completion = RcBlock::new(move |granted: objc2::runtime::Bool, _error: *mut NSError| {
            log::info!("📅 EventKit completion handler fired, granted={}", granted.as_bool());
            let _keepalive = &store_keepalive;
            let status = if granted.as_bool() {
                "fullAccess".to_string()
            } else {
                // Re-check the authoritative status rather than assuming "denied" —
                // e.g. restricted vs. denied are both "not granted".
                status_to_string(unsafe {
                    EKEventStore::authorizationStatusForEntityType(EKEntityType::Event)
                })
            };
            if let Some(sender) = completion_sender.lock().ok().and_then(|mut s| s.take()) {
                let _ = sender.send(Ok(status));
            }
        });

        log::info!(
            "📅 requesting EventKit full access (status before = {})",
            permission_status()
        );
        unsafe {
            store.requestFullAccessToEventsWithCompletion(
                RcBlock::as_ptr(&completion) as *mut _,
            );
        }
        // Keep the block alive until EventKit invokes it. EventKit's completion handler
        // is called asynchronously on an arbitrary thread, so we intentionally leak the
        // block's retain here rather than dropping it while the async call is in flight.
        std::mem::forget(completion);
    }

    fn ns_date_to_utc(date: &NSDate) -> DateTime<Utc> {
        let secs = date.timeIntervalSince1970();
        Utc.timestamp_opt(secs.floor() as i64, ((secs.fract()) * 1e9) as u32)
            .single()
            .unwrap_or_else(Utc::now)
    }

    fn utc_to_ns_date(dt: DateTime<Utc>) -> Retained<NSDate> {
        NSDate::dateWithTimeIntervalSince1970(dt.timestamp() as f64)
    }

    fn ns_string_to_string(s: &NSString) -> String {
        s.to_string()
    }

    /// Read an `EKCalendar`'s assigned color as a portable `#RRGGBB` hex string.
    ///
    /// EventKit exposes the color as a (deprecated but still functional) `CGColor`.
    /// We message it directly rather than pulling in AppKit's `NSColor`, then read
    /// the raw components with CoreGraphics. Non-RGB spaces (grayscale) are mapped
    /// to gray; pattern/unsupported colors yield `None` (honest — no fake data).
    fn read_calendar_color(cal: &EKCalendar) -> Option<String> {
        use std::os::raw::c_void;

        #[link(name = "CoreGraphics", kind = "framework")]
        extern "C" {
            fn CGColorGetComponents(color: *const c_void) -> *const f64;
            fn CGColorGetNumberOfComponents(color: *const c_void) -> usize;
        }

        // `CGColor` follows the Core Foundation "get" rule — the returned reference
        // is not owned, and we read it synchronously before any autorelease drain.
        let cg_color: *const c_void = unsafe { objc2::msg_send![cal, CGColor] };
        if cg_color.is_null() {
            return None;
        }

        let count = unsafe { CGColorGetNumberOfComponents(cg_color) };
        let components_ptr = unsafe { CGColorGetComponents(cg_color) };
        if components_ptr.is_null() || count < 2 {
            return None;
        }
        let components = unsafe { std::slice::from_raw_parts(components_ptr, count) };

        let (r, g, b) = match count {
            // Grayscale color space: [white, alpha].
            2 => (components[0], components[0], components[0]),
            // RGB(A) or any space whose first three components are R,G,B.
            _ => (components[0], components[1], components[2]),
        };

        let to_u8 = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        Some(format!("#{:02X}{:02X}{:02X}", to_u8(r), to_u8(g), to_u8(b)))
    }

    pub fn list_calendars() -> Result<Vec<NativeCalendar>, String> {
        let store = unsafe { EKEventStore::new() };
        let calendars: Retained<NSArray<EKCalendar>> =
            unsafe { store.calendarsForEntityType(EKEntityType::Event) };

        let mut out = Vec::new();
        for cal in calendars.to_vec() {
            let id = unsafe { ns_string_to_string(&cal.calendarIdentifier()) };
            let title = unsafe { ns_string_to_string(&cal.title()) };
            let color = read_calendar_color(&cal);
            out.push(NativeCalendar { id, title, color });
        }
        Ok(out)
    }

    fn attendee_from_participant(
        participant: &objc2_event_kit::EKParticipant,
    ) -> Attendee {
        let name = unsafe { participant.name() }.map(|n| ns_string_to_string(&n));
        let url = unsafe { participant.URL() };
        let url_string = url
            .absoluteString()
            .map(|s| ns_string_to_string(&s))
            .unwrap_or_default();
        let email = if url_string.starts_with("mailto:") {
            Some(url_string.trim_start_matches("mailto:").to_string())
        } else {
            None
        };
        Attendee { name, email }
    }

    pub fn fetch_events(
        calendar_ids: &[String],
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<NativeEvent>, String> {
        if calendar_ids.is_empty() {
            return Ok(Vec::new());
        }

        let store = unsafe { EKEventStore::new() };
        let all_calendars: Retained<NSArray<EKCalendar>> =
            unsafe { store.calendarsForEntityType(EKEntityType::Event) };

        let selected: Vec<Retained<EKCalendar>> = all_calendars
            .to_vec()
            .into_iter()
            .filter(|cal| {
                let id = unsafe { ns_string_to_string(&cal.calendarIdentifier()) };
                calendar_ids.iter().any(|wanted| wanted == &id)
            })
            .collect();

        if selected.is_empty() {
            return Ok(Vec::new());
        }

        let calendars_array: Retained<NSArray<EKCalendar>> = NSArray::from_retained_slice(&selected);
        let start_date = utc_to_ns_date(start);
        let end_date = utc_to_ns_date(end);

        let predicate = unsafe {
            store.predicateForEventsWithStartDate_endDate_calendars(
                &start_date,
                &end_date,
                Some(&calendars_array),
            )
        };

        let events: Retained<NSArray<EKEvent>> = unsafe { store.eventsMatchingPredicate(&predicate) };

        let mut out = Vec::new();
        for event in events.to_vec() {
            let id = match unsafe { event.eventIdentifier() } {
                Some(id) => ns_string_to_string(&id),
                // Events without a persisted identifier (e.g. not yet saved) can't be
                // tracked across syncs — skip them.
                None => continue,
            };
            let calendar = unsafe { event.calendar() };
            let (calendar_id, calendar_title) = match &calendar {
                Some(cal) => (
                    unsafe { ns_string_to_string(&cal.calendarIdentifier()) },
                    Some(unsafe { ns_string_to_string(&cal.title()) }),
                ),
                None => (String::new(), None),
            };
            let title_ns = unsafe { event.title() };
            let title = ns_string_to_string(&title_ns);
            let start_date_ns = unsafe { event.startDate() };
            let start_time = ns_date_to_utc(&start_date_ns);
            let end_date_ns = unsafe { event.endDate() };
            let end_time = ns_date_to_utc(&end_date_ns);
            let is_all_day = unsafe { event.isAllDay() };
            let location = unsafe { event.location() }.map(|l| ns_string_to_string(&l));
            let notes = unsafe { event.notes() }.map(|n| ns_string_to_string(&n));
            let organizer = unsafe { event.organizer() }
                .and_then(|p| unsafe { p.name() })
                .map(|n| ns_string_to_string(&n));
            let attendees = unsafe { event.attendees() }
                .map(|arr| arr.to_vec().iter().map(|p| attendee_from_participant(p)).collect())
                .unwrap_or_default();

            // ---- Recurrence signals (F9 Meeting Series) ----
            // `calendarItemExternalIdentifier` (EKCalendarItem) is stable across every
            // occurrence of a recurring event → the series key. The other three describe
            // this specific occurrence. Same NSDate→RFC3339 conversion as start/end above.
            let series_key = unsafe { event.calendarItemExternalIdentifier() }
                .map(|s| ns_string_to_string(&s));
            let has_recurrence = unsafe { event.hasRecurrenceRules() };
            let occurrence_date = unsafe { event.occurrenceDate() }
                .map(|d| ns_date_to_utc(&d).to_rfc3339());
            let is_detached = unsafe { event.isDetached() };

            out.push(NativeEvent {
                id,
                calendar_id,
                calendar_title,
                title,
                start_time,
                end_time,
                is_all_day,
                location,
                notes,
                organizer,
                attendees,
                series_key,
                has_recurrence,
                occurrence_date,
                is_detached,
            });
        }

        Ok(out)
    }
}

#[cfg(target_os = "macos")]
pub use macos_impl::{fetch_events, list_calendars, permission_status, request_full_access_on_main};

#[cfg(not(target_os = "macos"))]
pub mod stub {
    use super::*;
    use chrono::{DateTime, Utc};

    pub fn permission_status() -> String {
        "restricted".to_string()
    }

    pub fn request_full_access_on_main(
        result_sender: tokio::sync::oneshot::Sender<Result<String, String>>,
    ) {
        let _ = result_sender.send(Ok("restricted".to_string()));
    }

    pub fn list_calendars() -> Result<Vec<NativeCalendar>, String> {
        Ok(Vec::new())
    }

    pub fn fetch_events(
        _calendar_ids: &[String],
        _start: DateTime<Utc>,
        _end: DateTime<Utc>,
    ) -> Result<Vec<NativeEvent>, String> {
        Ok(Vec::new())
    }
}

#[cfg(not(target_os = "macos"))]
pub use stub::{fetch_events, list_calendars, permission_status, request_full_access_on_main};

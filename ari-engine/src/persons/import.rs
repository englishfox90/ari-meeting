// Person Profiles (F2) — attendee import. Turns a linked calendar event's attendee list
// into `persons` rows (email-keyed stubs) and links them to the event's meeting as
// participants (`link_source = 'calendar'`). This is the bridge that populates people from
// F4 calendar data, per the F2 identity-source decision (email-seeded, not voice).
//
// Fully idempotent: `upsert_stub_from_attendee` returns an existing person unchanged (never
// clobbering authored identity) and `link_participant` is INSERT OR IGNORE. Safe to call at
// link time AND to re-run as a reconcile pass over already-linked events.

use sqlx::SqlitePool;

use crate::database::repositories::calendar::CalendarRepository;
use crate::database::repositories::person::{PersonRepository, PersonRow};

#[derive(serde::Deserialize)]
struct AttendeeJson {
    name: Option<String>,
    email: Option<String>,
}

/// Import the attendees of `event_id` as persons, linking them to the event's meeting when
/// one is linked. Returns the imported/matched person rows. Errors only on genuine DB
/// failure; a missing event or empty attendee list yields an empty Vec.
pub async fn import_participants_from_event(
    pool: &SqlitePool,
    event_id: &str,
) -> Result<Vec<PersonRow>, sqlx::Error> {
    let Some(event) = CalendarRepository::get_event(pool, event_id).await? else {
        return Ok(Vec::new());
    };

    let attendees: Vec<AttendeeJson> = event
        .attendees
        .as_deref()
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    let mut people = Vec::with_capacity(attendees.len());
    for attendee in attendees {
        // Skip fully-empty attendee entries (no name AND no email) — nothing to key on.
        let has_email = attendee.email.as_deref().map(|e| !e.trim().is_empty()).unwrap_or(false);
        let display_name = attendee.name.clone().unwrap_or_default();
        if !has_email && display_name.trim().is_empty() {
            continue;
        }

        let row = PersonRepository::upsert_stub_from_attendee(
            pool,
            attendee.email.as_deref(),
            &display_name,
        )
        .await?;

        if let Some(meeting_id) = &event.meeting_id {
            PersonRepository::link_participant(pool, meeting_id, &row.id, "calendar").await?;
        }

        people.push(row);
    }

    Ok(people)
}

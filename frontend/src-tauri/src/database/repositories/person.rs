// Person Profiles (F2) repository — additive DB access layer for persons / profile_facts /
// meeting_participants. Follows the sanctioned pattern (mirrors calendar.rs): unit struct,
// `pool: &SqlitePool` first, runtime sqlx query/query_as (no compile-time macros),
// `Result<_, sqlx::Error>`.

use chrono::Utc;
use sqlx::{FromRow, Row, SqlitePool};
use uuid::Uuid;

use crate::persons::models::NewPerson;

#[derive(Debug, Clone, FromRow)]
pub struct PersonRow {
    pub id: String,
    pub email: Option<String>,
    pub display_name: String,
    pub role: Option<String>,
    pub organization: Option<String>,
    pub domain: Option<String>,
    pub notes: Option<String>,
    pub is_owner: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, FromRow)]
pub struct ProfileFactRow {
    pub id: String,
    pub person_id: String,
    pub fact_text: String,
    pub fact_kind: String,
    pub source_meeting_id: Option<String>,
    pub source_meeting_title: Option<String>,
    pub source_segment_ref: Option<String>,
    pub source_kind: String,
    pub confidence: f64,
    pub status: String,
    pub superseded_by: Option<String>,
    pub created_at: String,
    pub last_confirmed_at: Option<String>,
    /// When this (usually pending) fact is a proposed replacement for an existing one, the id
    /// of the fact it will supersede once confirmed. NULL for ordinary facts. Deferred
    /// supersession keeps the old fact ACTIVE until the replacement is confirmed.
    pub supersedes_fact_id: Option<String>,
    /// How many rows this fact has in `profile_fact_sources` (origin + reaffirmations +
    /// carried-forward lineage). A real corroboration signal for the UI. `#[sqlx(default)]`
    /// so SELECTs that don't compute it (they don't need the count) still map cleanly to 0.
    #[sqlx(default)]
    pub source_count: i64,
}

/// One recorded observation backing a `profile_fact` (F2 multi-source facts). A fact
/// accumulates these across meetings instead of collapsing to a single latest source.
#[derive(Debug, Clone, FromRow)]
pub struct ProfileFactSourceRow {
    pub id: String,
    pub fact_id: String,
    pub meeting_id: Option<String>,
    /// Joined from `meetings.title` when `meeting_id` resolves; NULL for manual/unknown.
    pub meeting_title: Option<String>,
    pub segment_ref: Option<String>,
    pub source_kind: String,
    /// 'origin' | 'reaffirmed' | 'carried'
    pub relation: String,
    pub confidence: f64,
    pub observed_at: String,
}

pub struct PersonRepository;

impl PersonRepository {
    /// Upsert authored-identity fields only. Never touches `is_owner`.
    pub async fn upsert_authored(
        pool: &SqlitePool,
        person: &NewPerson,
    ) -> Result<PersonRow, sqlx::Error> {
        let now = Utc::now().to_rfc3339();

        if let Some(id) = &person.id {
            sqlx::query(
                r#"
                UPDATE persons SET
                    email = ?,
                    display_name = ?,
                    role = ?,
                    organization = ?,
                    domain = ?,
                    notes = ?,
                    updated_at = ?
                WHERE id = ?
                "#,
            )
            .bind(&person.email)
            .bind(&person.display_name)
            .bind(&person.role)
            .bind(&person.organization)
            .bind(&person.domain)
            .bind(&person.notes)
            .bind(&now)
            .bind(id)
            .execute(pool)
            .await?;

            return Self::get(pool, id)
                .await?
                .ok_or(sqlx::Error::RowNotFound);
        }

        if let Some(email) = &person.email {
            if let Some(existing) = Self::get_by_email(pool, email).await? {
                sqlx::query(
                    r#"
                    UPDATE persons SET
                        display_name = ?,
                        role = ?,
                        organization = ?,
                        domain = ?,
                        notes = ?,
                        updated_at = ?
                    WHERE id = ?
                    "#,
                )
                .bind(&person.display_name)
                .bind(&person.role)
                .bind(&person.organization)
                .bind(&person.domain)
                .bind(&person.notes)
                .bind(&now)
                .bind(&existing.id)
                .execute(pool)
                .await?;

                return Self::get(pool, &existing.id)
                    .await?
                    .ok_or(sqlx::Error::RowNotFound);
            }
        }

        let id = Uuid::new_v4().to_string();
        sqlx::query(
            r#"
            INSERT INTO persons (
                id, email, display_name, role, organization, domain, notes,
                is_owner, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
            "#,
        )
        .bind(&id)
        .bind(&person.email)
        .bind(&person.display_name)
        .bind(&person.role)
        .bind(&person.organization)
        .bind(&person.domain)
        .bind(&person.notes)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await?;

        Self::get(pool, &id).await?.ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn get(pool: &SqlitePool, id: &str) -> Result<Option<PersonRow>, sqlx::Error> {
        sqlx::query_as::<_, PersonRow>("SELECT * FROM persons WHERE id = ?")
            .bind(id)
            .fetch_optional(pool)
            .await
    }

    pub async fn get_by_email(
        pool: &SqlitePool,
        email: &str,
    ) -> Result<Option<PersonRow>, sqlx::Error> {
        sqlx::query_as::<_, PersonRow>("SELECT * FROM persons WHERE email = ?")
            .bind(email)
            .fetch_optional(pool)
            .await
    }

    pub async fn list(pool: &SqlitePool) -> Result<Vec<PersonRow>, sqlx::Error> {
        sqlx::query_as::<_, PersonRow>("SELECT * FROM persons ORDER BY display_name ASC")
            .fetch_all(pool)
            .await
    }

    pub async fn delete(pool: &SqlitePool, id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM persons WHERE id = ?")
            .bind(id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn get_owner(pool: &SqlitePool) -> Result<Option<PersonRow>, sqlx::Error> {
        sqlx::query_as::<_, PersonRow>("SELECT * FROM persons WHERE is_owner = 1 LIMIT 1")
            .fetch_optional(pool)
            .await
    }

    /// Upsert authored fields AND set is_owner=1. Ensures exactly one owner exists by
    /// clearing `is_owner` on every row first, inside a transaction.
    pub async fn set_owner(
        pool: &SqlitePool,
        person: &NewPerson,
    ) -> Result<PersonRow, sqlx::Error> {
        let mut tx = pool.begin().await?;
        let now = Utc::now().to_rfc3339();

        sqlx::query("UPDATE persons SET is_owner = 0")
            .execute(&mut *tx)
            .await?;

        // Resolve target id: explicit id, else existing row by email, else a fresh insert.
        let target_id = if let Some(id) = &person.id {
            id.clone()
        } else if let Some(email) = &person.email {
            let existing = sqlx::query_as::<_, PersonRow>("SELECT * FROM persons WHERE email = ?")
                .bind(email)
                .fetch_optional(&mut *tx)
                .await?;
            match existing {
                Some(row) => row.id,
                None => {
                    let id = Uuid::new_v4().to_string();
                    sqlx::query(
                        r#"
                        INSERT INTO persons (
                            id, email, display_name, role, organization, domain, notes,
                            is_owner, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                        "#,
                    )
                    .bind(&id)
                    .bind(&person.email)
                    .bind(&person.display_name)
                    .bind(&person.role)
                    .bind(&person.organization)
                    .bind(&person.domain)
                    .bind(&person.notes)
                    .bind(&now)
                    .bind(&now)
                    .execute(&mut *tx)
                    .await?;
                    id
                }
            }
        } else {
            let id = Uuid::new_v4().to_string();
            sqlx::query(
                r#"
                INSERT INTO persons (
                    id, email, display_name, role, organization, domain, notes,
                    is_owner, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                "#,
            )
            .bind(&id)
            .bind(&person.email)
            .bind(&person.display_name)
            .bind(&person.role)
            .bind(&person.organization)
            .bind(&person.domain)
            .bind(&person.notes)
            .bind(&now)
            .bind(&now)
            .execute(&mut *tx)
            .await?;
            id
        };

        sqlx::query(
            r#"
            UPDATE persons SET
                email = ?,
                display_name = ?,
                role = ?,
                organization = ?,
                domain = ?,
                notes = ?,
                is_owner = 1,
                updated_at = ?
            WHERE id = ?
            "#,
        )
        .bind(&person.email)
        .bind(&person.display_name)
        .bind(&person.role)
        .bind(&person.organization)
        .bind(&person.domain)
        .bind(&person.notes)
        .bind(&now)
        .bind(&target_id)
        .execute(&mut *tx)
        .await?;

        let row = sqlx::query_as::<_, PersonRow>("SELECT * FROM persons WHERE id = ?")
            .bind(&target_id)
            .fetch_one(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok(row)
    }

    /// If `email` matches an existing row, returns it unchanged (never overwrites authored
    /// fields). Else inserts a stub person (display_name = provided name, or the email
    /// localpart if no name given).
    pub async fn upsert_stub_from_attendee(
        pool: &SqlitePool,
        email: Option<&str>,
        display_name: &str,
    ) -> Result<PersonRow, sqlx::Error> {
        if let Some(email) = email {
            if let Some(existing) = Self::get_by_email(pool, email).await? {
                return Ok(existing);
            }
        }

        let resolved_name = if !display_name.trim().is_empty() {
            display_name.to_string()
        } else if let Some(email) = email {
            email.split('@').next().unwrap_or(email).to_string()
        } else {
            "Unknown".to_string()
        };

        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO persons (
                id, email, display_name, role, organization, domain, notes,
                is_owner, created_at, updated_at
            ) VALUES (?, ?, ?, NULL, NULL, NULL, NULL, 0, ?, ?)
            "#,
        )
        .bind(&id)
        .bind(email)
        .bind(&resolved_name)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await?;

        Self::get(pool, &id).await?.ok_or(sqlx::Error::RowNotFound)
    }

    pub async fn link_participant(
        pool: &SqlitePool,
        meeting_id: &str,
        person_id: &str,
        link_source: &str,
    ) -> Result<(), sqlx::Error> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT OR IGNORE INTO meeting_participants (meeting_id, person_id, link_source, created_at)
            VALUES (?, ?, ?, ?)
            "#,
        )
        .bind(meeting_id)
        .bind(person_id)
        .bind(link_source)
        .bind(&now)
        .execute(pool)
        .await?;
        Ok(())
    }

    pub async fn list_participants(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<Vec<PersonRow>, sqlx::Error> {
        sqlx::query_as::<_, PersonRow>(
            r#"
            SELECT p.* FROM persons p
            JOIN meeting_participants mp ON mp.person_id = p.id
            WHERE mp.meeting_id = ?
            ORDER BY p.display_name ASC
            "#,
        )
        .bind(meeting_id)
        .fetch_all(pool)
        .await
    }

    /// Count the persons linked to a meeting (calendar attendees imported as people +
    /// any voice-confirmed speakers). Used as a calendar prior for the diarizer's
    /// expected speaker count. Sparse by nature — callers must treat a low/zero count
    /// defensively (fall back to auto speaker detection).
    pub async fn count_participants(
        pool: &SqlitePool,
        meeting_id: &str,
    ) -> Result<i64, sqlx::Error> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM meeting_participants WHERE meeting_id = ?",
        )
        .bind(meeting_id)
        .fetch_one(pool)
        .await?;
        Ok(count)
    }

    pub async fn list_meetings_for_person(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<Vec<(String, String, String)>, sqlx::Error> {
        let rows = sqlx::query(
            r#"
            SELECT m.id, m.title, m.created_at FROM meetings m
            JOIN meeting_participants mp ON mp.meeting_id = m.id
            WHERE mp.person_id = ?
            ORDER BY m.created_at DESC
            "#,
        )
        .bind(person_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| {
                let created_at: crate::database::models::DateTimeUtc = row.get("created_at");
                (
                    row.get::<String, _>("id"),
                    row.get::<String, _>("title"),
                    created_at.0.to_rfc3339(),
                )
            })
            .collect())
    }

    pub async fn meeting_count_for_person(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<i64, sqlx::Error> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM meeting_participants WHERE person_id = ?",
        )
        .bind(person_id)
        .fetch_one(pool)
        .await?;
        Ok(count)
    }

    pub async fn active_fact_count(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<i64, sqlx::Error> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM profile_facts WHERE person_id = ? AND status = 'active'",
        )
        .bind(person_id)
        .fetch_one(pool)
        .await?;
        Ok(count)
    }

    pub async fn pending_fact_count(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<i64, sqlx::Error> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM profile_facts WHERE person_id = ? AND status = 'pending'",
        )
        .bind(person_id)
        .fetch_one(pool)
        .await?;
        Ok(count)
    }
}

pub struct ProfileFactRepository;

impl ProfileFactRepository {
    #[allow(clippy::too_many_arguments)]
    pub async fn insert(
        pool: &SqlitePool,
        person_id: &str,
        fact_text: &str,
        fact_kind: &str,
        source_meeting_id: Option<&str>,
        source_segment_ref: Option<&str>,
        source_kind: &str,
        confidence: f64,
        status: &str,
    ) -> Result<ProfileFactRow, sqlx::Error> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();

        sqlx::query(
            r#"
            INSERT INTO profile_facts (
                id, person_id, fact_text, fact_kind, source_meeting_id, source_segment_ref,
                source_kind, confidence, status, superseded_by, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            "#,
        )
        .bind(&id)
        .bind(person_id)
        .bind(fact_text)
        .bind(fact_kind)
        .bind(source_meeting_id)
        .bind(source_segment_ref)
        .bind(source_kind)
        .bind(confidence)
        .bind(status)
        .bind(&now)
        .execute(pool)
        .await?;

        Self::get(pool, &id).await?.ok_or(sqlx::Error::RowNotFound)
    }

    /// Public single-fact fetch by id (the private `get` is the post-insert reload path).
    pub async fn get_public(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<ProfileFactRow>, sqlx::Error> {
        Self::get(pool, id).await
    }

    async fn get(pool: &SqlitePool, id: &str) -> Result<Option<ProfileFactRow>, sqlx::Error> {
        sqlx::query_as::<_, ProfileFactRow>(
            r#"
            SELECT
                pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
                m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
                pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
                pf.supersedes_fact_id,
                (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
            FROM profile_facts pf
            LEFT JOIN meetings m ON m.id = pf.source_meeting_id
            WHERE pf.id = ?
            "#,
        )
        .bind(id)
        .fetch_optional(pool)
        .await
    }

    pub async fn list_for_person(
        pool: &SqlitePool,
        person_id: &str,
        include_superseded: bool,
    ) -> Result<Vec<ProfileFactRow>, sqlx::Error> {
        let query = if include_superseded {
            r#"
            SELECT
                pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
                m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
                pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
                pf.supersedes_fact_id,
                (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
            FROM profile_facts pf
            LEFT JOIN meetings m ON m.id = pf.source_meeting_id
            WHERE pf.person_id = ?
            ORDER BY pf.created_at DESC
            "#
        } else {
            r#"
            SELECT
                pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
                m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
                pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
                pf.supersedes_fact_id,
                (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
            FROM profile_facts pf
            LEFT JOIN meetings m ON m.id = pf.source_meeting_id
            WHERE pf.person_id = ? AND pf.status != 'superseded'
            ORDER BY pf.created_at DESC
            "#
        };

        sqlx::query_as::<_, ProfileFactRow>(query)
            .bind(person_id)
            .fetch_all(pool)
            .await
    }

    pub async fn list_pending(pool: &SqlitePool) -> Result<Vec<ProfileFactRow>, sqlx::Error> {
        sqlx::query_as::<_, ProfileFactRow>(
            r#"
            SELECT
                pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
                m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
                pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
                pf.supersedes_fact_id,
                (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
            FROM profile_facts pf
            LEFT JOIN meetings m ON m.id = pf.source_meeting_id
            WHERE pf.status = 'pending'
            ORDER BY pf.created_at DESC
            "#,
        )
        .fetch_all(pool)
        .await
    }

    pub async fn set_status(
        pool: &SqlitePool,
        fact_id: &str,
        status: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE profile_facts SET status = ? WHERE id = ?")
            .bind(status)
            .bind(fact_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn supersede(
        pool: &SqlitePool,
        old_fact_id: &str,
        new_fact_id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "UPDATE profile_facts SET status = 'superseded', superseded_by = ? WHERE id = ?",
        )
        .bind(new_fact_id)
        .bind(old_fact_id)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// Record that `new_fact_id` (a pending replacement) is intended to supersede
    /// `old_fact_id` once confirmed — WITHOUT retiring the old fact yet. The old fact stays
    /// ACTIVE and in use until the replacement is confirmed (see `supersedes_target` +
    /// `profile_fact_confirm`). This is the deferred half of `supersede`.
    pub async fn mark_supersedes(
        pool: &SqlitePool,
        new_fact_id: &str,
        old_fact_id: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE profile_facts SET supersedes_fact_id = ? WHERE id = ?")
            .bind(old_fact_id)
            .bind(new_fact_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// The id of the fact that `fact_id` proposes to replace, if any. Read at confirm time
    /// to retire the old fact only once the replacement is enrolled.
    pub async fn supersedes_target(
        pool: &SqlitePool,
        fact_id: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        sqlx::query_scalar("SELECT supersedes_fact_id FROM profile_facts WHERE id = ?")
            .bind(fact_id)
            .fetch_optional(pool)
            .await
            .map(|opt| opt.flatten())
    }

    /// Active + pending facts for a person (excludes superseded/rejected/removed) — the
    /// "current facts" the reconciliation agent is shown so it can decide add/keep/
    /// supersede/remove instead of piling on near-duplicates.
    pub async fn list_active_and_pending_for_person(
        pool: &SqlitePool,
        person_id: &str,
    ) -> Result<Vec<ProfileFactRow>, sqlx::Error> {
        sqlx::query_as::<_, ProfileFactRow>(
            r#"
            SELECT
                pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
                m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
                pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
                pf.supersedes_fact_id,
                (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
            FROM profile_facts pf
            LEFT JOIN meetings m ON m.id = pf.source_meeting_id
            WHERE pf.person_id = ? AND pf.status IN ('active', 'pending')
            ORDER BY pf.created_at ASC
            "#,
        )
        .bind(person_id)
        .fetch_all(pool)
        .await
    }

    /// Mark a fact as removed by automated reconciliation/cap-enforcement — distinct from
    /// `set_status(.., "rejected")`, which is the user-driven rejection path. Provenance:
    /// 'rejected' = a human said no; 'removed' = the reconciliation agent or the active-fact
    /// cap pruned it because the managed set was getting too large or too stale.
    pub async fn mark_removed(pool: &SqlitePool, fact_id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE profile_facts SET status = 'removed' WHERE id = ?")
            .bind(fact_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// Reset the staleness clock — called both when a user explicitly confirms a fact
    /// (`profile_fact_confirm`) and when the reconciliation agent decides to "keep" a fact
    /// unchanged after seeing fresh transcript evidence that reaffirms it.
    pub async fn touch_confirmed(pool: &SqlitePool, fact_id: &str) -> Result<(), sqlx::Error> {
        let now = Utc::now().to_rfc3339();
        sqlx::query("UPDATE profile_facts SET last_confirmed_at = ? WHERE id = ?")
            .bind(&now)
            .bind(fact_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// Active/pending facts for a person that haven't been (re)confirmed in over
    /// `stale_after_days` — candidates for reconfirmation or removal. Falls back to
    /// `created_at` when `last_confirmed_at` is NULL (never reconfirmed since creation).
    pub async fn facts_needing_review(
        pool: &SqlitePool,
        person_id: &str,
        stale_after_days: i64,
    ) -> Result<Vec<ProfileFactRow>, sqlx::Error> {
        sqlx::query_as::<_, ProfileFactRow>(
            r#"
            SELECT
                pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
                m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
                pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
                pf.supersedes_fact_id,
                (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
            FROM profile_facts pf
            LEFT JOIN meetings m ON m.id = pf.source_meeting_id
            WHERE pf.person_id = ?
              AND pf.status IN ('active', 'pending')
              AND (julianday('now') - julianday(COALESCE(pf.last_confirmed_at, pf.created_at))) > ?
            ORDER BY julianday(COALESCE(pf.last_confirmed_at, pf.created_at)) ASC
            "#,
        )
        .bind(person_id)
        .bind(stale_after_days as f64)
        .fetch_all(pool)
        .await
    }

    /// Enforce a per-person cap on ACTIVE facts. When over cap, the lowest-confidence /
    /// oldest active facts are marked 'removed' (automated pruning, not user rejection —
    /// see `mark_removed`) until the count is back at `cap`. Returns how many were pruned.
    /// Pending facts don't count toward the cap (they haven't been confirmed-before-enroll
    /// yet) and are never touched here.
    pub async fn trim_active_to_cap(
        pool: &SqlitePool,
        person_id: &str,
        cap: i64,
    ) -> Result<i64, sqlx::Error> {
        let active: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM profile_facts WHERE person_id = ? AND status = 'active'",
        )
        .bind(person_id)
        .fetch_one(pool)
        .await?;

        let excess = active - cap;
        if excess <= 0 {
            return Ok(0);
        }

        let excess_ids: Vec<String> = sqlx::query_scalar(
            r#"
            SELECT id FROM profile_facts
            WHERE person_id = ? AND status = 'active'
            ORDER BY confidence ASC, created_at ASC
            LIMIT ?
            "#,
        )
        .bind(person_id)
        .bind(excess)
        .fetch_all(pool)
        .await?;

        let removed = excess_ids.len() as i64;
        for id in excess_ids {
            sqlx::query("UPDATE profile_facts SET status = 'removed' WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await?;
        }
        Ok(removed)
    }

    /// Enforce a per-person cap on PENDING facts, mirroring `trim_active_to_cap`. Unbounded
    /// pending facts could otherwise pile up (a person never reviewed on the People page).
    /// When over cap, the lowest-confidence / oldest pending facts are marked 'removed'
    /// (automated pruning, not user rejection). Pruning a pending *supersede* proposal is
    /// safe — the fact it targeted is still ACTIVE and simply stays. Returns how many were
    /// pruned.
    pub async fn trim_pending_to_cap(
        pool: &SqlitePool,
        person_id: &str,
        cap: i64,
    ) -> Result<i64, sqlx::Error> {
        let pending: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM profile_facts WHERE person_id = ? AND status = 'pending'",
        )
        .bind(person_id)
        .fetch_one(pool)
        .await?;

        let excess = pending - cap;
        if excess <= 0 {
            return Ok(0);
        }

        let excess_ids: Vec<String> = sqlx::query_scalar(
            r#"
            SELECT id FROM profile_facts
            WHERE person_id = ? AND status = 'pending'
            ORDER BY confidence ASC, created_at ASC
            LIMIT ?
            "#,
        )
        .bind(person_id)
        .bind(excess)
        .fetch_all(pool)
        .await?;

        let removed = excess_ids.len() as i64;
        for id in excess_ids {
            sqlx::query("UPDATE profile_facts SET status = 'removed' WHERE id = ?")
                .bind(&id)
                .execute(pool)
                .await?;
        }
        Ok(removed)
    }
}

/// Multi-source provenance for profile facts (F2). A fact accumulates one row here per
/// observation instead of collapsing to a single latest source. See migration
/// `20260716120000_add_profile_fact_sources.sql`.
pub struct ProfileFactSourceRepository;

impl ProfileFactSourceRepository {
    /// Insert a source row unconditionally. Used for the 'origin' observation of a freshly
    /// inserted fact (which by definition has no prior sources).
    #[allow(clippy::too_many_arguments)]
    pub async fn add_source(
        pool: &SqlitePool,
        fact_id: &str,
        meeting_id: Option<&str>,
        segment_ref: Option<&str>,
        source_kind: &str,
        relation: &str,
        confidence: f64,
    ) -> Result<(), sqlx::Error> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            r#"
            INSERT INTO profile_fact_sources
                (id, fact_id, meeting_id, segment_ref, source_kind, relation, confidence, observed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(&id)
        .bind(fact_id)
        .bind(meeting_id)
        .bind(segment_ref)
        .bind(source_kind)
        .bind(relation)
        .bind(confidence.clamp(0.0, 1.0))
        .bind(&now)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// True when `fact_id` already has a source row for `meeting_id` (a non-null meeting).
    /// Used to keep reaffirmations / carried lineage from double-counting the same meeting.
    async fn has_source_for_meeting(
        pool: &SqlitePool,
        fact_id: &str,
        meeting_id: &str,
    ) -> Result<bool, sqlx::Error> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM profile_fact_sources WHERE fact_id = ? AND meeting_id = ?",
        )
        .bind(fact_id)
        .bind(meeting_id)
        .fetch_one(pool)
        .await?;
        Ok(count > 0)
    }

    /// Add a source only if `fact_id` has no existing source for the same (non-null) meeting.
    /// Returns whether a row was inserted. Sources with a NULL meeting are always inserted
    /// (there's nothing to dedupe against). Used for 'reaffirmed' (keep) observations.
    #[allow(clippy::too_many_arguments)]
    pub async fn add_source_dedup(
        pool: &SqlitePool,
        fact_id: &str,
        meeting_id: Option<&str>,
        segment_ref: Option<&str>,
        source_kind: &str,
        relation: &str,
        confidence: f64,
    ) -> Result<bool, sqlx::Error> {
        if let Some(mid) = meeting_id {
            if Self::has_source_for_meeting(pool, fact_id, mid).await? {
                return Ok(false);
            }
        }
        Self::add_source(pool, fact_id, meeting_id, segment_ref, source_kind, relation, confidence)
            .await?;
        Ok(true)
    }

    /// Every source backing a fact, newest observation first, with meeting titles joined.
    pub async fn list_for_fact(
        pool: &SqlitePool,
        fact_id: &str,
    ) -> Result<Vec<ProfileFactSourceRow>, sqlx::Error> {
        sqlx::query_as::<_, ProfileFactSourceRow>(
            r#"
            SELECT
                s.id, s.fact_id, s.meeting_id, m.title AS meeting_title, s.segment_ref,
                s.source_kind, s.relation, s.confidence, s.observed_at
            FROM profile_fact_sources s
            LEFT JOIN meetings m ON m.id = s.meeting_id
            WHERE s.fact_id = ?
            ORDER BY s.observed_at DESC
            "#,
        )
        .bind(fact_id)
        .fetch_all(pool)
        .await
    }

    /// Carry every source of `from_fact_id` onto `to_fact_id` as 'carried' lineage, so a
    /// superseding fact inherits ALL of the prior fact's provenance instead of only the
    /// latest single meeting. Preserves each source's meeting/evidence/confidence/observed_at
    /// (only `relation` becomes 'carried'). Skips any meeting the target already has a source
    /// for (e.g. the superseding meeting itself). Returns how many rows were carried.
    pub async fn carry_sources(
        pool: &SqlitePool,
        from_fact_id: &str,
        to_fact_id: &str,
    ) -> Result<i64, sqlx::Error> {
        let sources = Self::list_for_fact(pool, from_fact_id).await?;
        let mut carried = 0i64;
        for src in sources {
            // Dedupe by non-null meeting so the same meeting never appears twice on the
            // surviving fact. NULL-meeting sources are always carried (nothing to match on).
            if let Some(mid) = src.meeting_id.as_deref() {
                if Self::has_source_for_meeting(pool, to_fact_id, mid).await? {
                    continue;
                }
            }
            let id = Uuid::new_v4().to_string();
            sqlx::query(
                r#"
                INSERT INTO profile_fact_sources
                    (id, fact_id, meeting_id, segment_ref, source_kind, relation, confidence, observed_at)
                VALUES (?, ?, ?, ?, ?, 'carried', ?, ?)
                "#,
            )
            .bind(&id)
            .bind(to_fact_id)
            .bind(&src.meeting_id)
            .bind(&src.segment_ref)
            .bind(&src.source_kind)
            .bind(src.confidence)
            .bind(&src.observed_at)
            .execute(pool)
            .await?;
            carried += 1;
        }
        Ok(carried)
    }

    /// Raise a fact's confidence to at least `floor` (never lowers it). Called when a
    /// supersede is confirmed so the surviving fact reflects the best corroboration it
    /// inherited rather than silently dropping to the new observation's value.
    pub async fn raise_confidence(
        pool: &SqlitePool,
        fact_id: &str,
        floor: f64,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE profile_facts SET confidence = max(confidence, ?) WHERE id = ?")
            .bind(floor.clamp(0.0, 1.0))
            .bind(fact_id)
            .execute(pool)
            .await?;
        Ok(())
    }
}

/// Highest-confidence ACTIVE facts for a person, capped at `limit` — used by the F3
/// context assembler to keep the injected block terse.
pub async fn top_active_facts(
    pool: &SqlitePool,
    person_id: &str,
    limit: i64,
) -> Result<Vec<ProfileFactRow>, sqlx::Error> {
    sqlx::query_as::<_, ProfileFactRow>(
        r#"
        SELECT
            pf.id, pf.person_id, pf.fact_text, pf.fact_kind, pf.source_meeting_id,
            m.title AS source_meeting_title, pf.source_segment_ref, pf.source_kind,
            pf.confidence, pf.status, pf.superseded_by, pf.created_at, pf.last_confirmed_at,
            pf.supersedes_fact_id,
            (SELECT COUNT(*) FROM profile_fact_sources pfs WHERE pfs.fact_id = pf.id) AS source_count
        FROM profile_facts pf
        LEFT JOIN meetings m ON m.id = pf.source_meeting_id
        WHERE pf.person_id = ? AND pf.status = 'active'
        ORDER BY pf.confidence DESC, pf.created_at DESC
        LIMIT ?
        "#,
    )
    .bind(person_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}

#[cfg(test)]
mod profile_fact_sources_tests {
    use super::{ProfileFactRepository, ProfileFactSourceRepository};
    use sqlx::sqlite::SqlitePoolOptions;
    use sqlx::SqlitePool;

    /// Fresh in-memory pool with all real migrations applied and FK enforcement on.
    async fn mem_pool() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query("PRAGMA foreign_keys = ON;")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        pool
    }

    async fn insert_person(pool: &SqlitePool, id: &str) {
        sqlx::query(
            "INSERT INTO persons (id, display_name, is_owner, created_at, updated_at) \
             VALUES (?, ?, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .bind(id)
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
    }

    async fn insert_meeting(pool: &SqlitePool, id: &str) {
        sqlx::query(
            "INSERT INTO meetings (id, title, created_at, updated_at) \
             VALUES (?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        )
        .bind(id)
        .bind(format!("Meeting {id}"))
        .execute(pool)
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn migrations_apply_cleanly() {
        // mem_pool() panics if the new 20260716120000 migration fails.
        let _pool = mem_pool().await;
    }

    #[tokio::test]
    async fn add_and_list_sources_sets_count() {
        let pool = mem_pool().await;
        insert_person(&pool, "p1").await;
        insert_meeting(&pool, "mA").await;
        insert_meeting(&pool, "mB").await;

        let fact = ProfileFactRepository::insert(
            &pool, "p1", "likes ci", "interest", Some("mA"), Some("ev-A"),
            "attributed", 0.5, "pending",
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &fact.id, Some("mA"), Some("ev-A"), "attributed", "origin", 0.5,
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &fact.id, Some("mB"), Some("ev-B"), "attributed", "reaffirmed", 0.7,
        )
        .await
        .unwrap();

        let sources = ProfileFactSourceRepository::list_for_fact(&pool, &fact.id)
            .await
            .unwrap();
        assert_eq!(sources.len(), 2, "both sources listed");
        assert!(sources.iter().all(|s| s.meeting_title.is_some()), "titles joined");

        let reloaded = ProfileFactRepository::get_public(&pool, &fact.id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reloaded.source_count, 2, "source_count subquery reflects rows");
    }

    #[tokio::test]
    async fn add_source_dedup_skips_same_meeting() {
        let pool = mem_pool().await;
        insert_person(&pool, "p1").await;
        insert_meeting(&pool, "mA").await;
        let fact = ProfileFactRepository::insert(
            &pool, "p1", "f", "other", Some("mA"), Some("e"), "attributed", 0.5, "active",
        )
        .await
        .unwrap();

        let first = ProfileFactSourceRepository::add_source_dedup(
            &pool, &fact.id, Some("mA"), None, "attributed", "reaffirmed", 0.5,
        )
        .await
        .unwrap();
        let second = ProfileFactSourceRepository::add_source_dedup(
            &pool, &fact.id, Some("mA"), None, "attributed", "reaffirmed", 0.9,
        )
        .await
        .unwrap();

        assert!(first, "first insert happens");
        assert!(!second, "same-meeting reaffirmation is deduped");
        let sources = ProfileFactSourceRepository::list_for_fact(&pool, &fact.id)
            .await
            .unwrap();
        assert_eq!(sources.len(), 1);
    }

    #[tokio::test]
    async fn carry_sources_brings_lineage_together() {
        let pool = mem_pool().await;
        insert_person(&pool, "p1").await;
        for m in ["mA", "mB", "mC"] {
            insert_meeting(&pool, m).await;
        }

        // Old fact corroborated by meetings A (origin) and B (reaffirmed).
        let old = ProfileFactRepository::insert(
            &pool, "p1", "old", "goal", Some("mA"), Some("e-A"), "attributed", 0.6, "active",
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &old.id, Some("mA"), Some("e-A"), "attributed", "origin", 0.6,
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &old.id, Some("mB"), Some("e-B"), "attributed", "reaffirmed", 0.7,
        )
        .await
        .unwrap();

        // Replacement proposed from a new meeting C.
        let new = ProfileFactRepository::insert(
            &pool, "p1", "new", "goal", Some("mC"), Some("e-C"), "attributed", 0.4, "pending",
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &new.id, Some("mC"), Some("e-C"), "attributed", "origin", 0.4,
        )
        .await
        .unwrap();

        let carried = ProfileFactSourceRepository::carry_sources(&pool, &old.id, &new.id)
            .await
            .unwrap();
        assert_eq!(carried, 2, "A and B both carried onto the replacement");

        let sources = ProfileFactSourceRepository::list_for_fact(&pool, &new.id)
            .await
            .unwrap();
        assert_eq!(sources.len(), 3, "C (origin) + A + B (carried) = full lineage");
        let carried_meetings: Vec<_> = sources
            .iter()
            .filter(|s| s.relation == "carried")
            .filter_map(|s| s.meeting_id.clone())
            .collect();
        assert!(carried_meetings.contains(&"mA".to_string()));
        assert!(carried_meetings.contains(&"mB".to_string()));
    }

    #[tokio::test]
    async fn carry_sources_dedups_shared_meeting() {
        let pool = mem_pool().await;
        insert_person(&pool, "p1").await;
        insert_meeting(&pool, "mA").await;
        insert_meeting(&pool, "mC").await;

        let old = ProfileFactRepository::insert(
            &pool, "p1", "old", "goal", Some("mA"), Some("e-A"), "attributed", 0.6, "active",
        )
        .await
        .unwrap();
        // Old already saw meeting C too.
        for (m, e) in [("mA", "e-A"), ("mC", "e-C-old")] {
            ProfileFactSourceRepository::add_source(
                &pool, &old.id, Some(m), Some(e), "attributed", "origin", 0.6,
            )
            .await
            .unwrap();
        }

        let new = ProfileFactRepository::insert(
            &pool, "p1", "new", "goal", Some("mC"), Some("e-C"), "attributed", 0.4, "pending",
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &new.id, Some("mC"), Some("e-C"), "attributed", "origin", 0.4,
        )
        .await
        .unwrap();

        let carried = ProfileFactSourceRepository::carry_sources(&pool, &old.id, &new.id)
            .await
            .unwrap();
        assert_eq!(carried, 1, "only mA carried; mC already present on the replacement");
        let sources = ProfileFactSourceRepository::list_for_fact(&pool, &new.id)
            .await
            .unwrap();
        assert_eq!(sources.len(), 2, "mC (origin) + mA (carried), no duplicate mC");
    }

    #[tokio::test]
    async fn raise_confidence_never_lowers() {
        let pool = mem_pool().await;
        insert_person(&pool, "p1").await;
        let fact = ProfileFactRepository::insert(
            &pool, "p1", "f", "other", None, None, "attributed", 0.4, "active",
        )
        .await
        .unwrap();

        ProfileFactSourceRepository::raise_confidence(&pool, &fact.id, 0.9)
            .await
            .unwrap();
        let up = ProfileFactRepository::get_public(&pool, &fact.id).await.unwrap().unwrap();
        assert!((up.confidence - 0.9).abs() < 1e-9, "raised to the higher floor");

        ProfileFactSourceRepository::raise_confidence(&pool, &fact.id, 0.3)
            .await
            .unwrap();
        let down = ProfileFactRepository::get_public(&pool, &fact.id).await.unwrap().unwrap();
        assert!((down.confidence - 0.9).abs() < 1e-9, "never lowered below the earned value");
    }

    /// End-to-end supersede+confirm at the repository layer: mirrors what
    /// `profile_fact_confirm` does — carry the old fact's sources onto the replacement,
    /// raise confidence, then retire the old fact. Nothing from the old fact is lost.
    #[tokio::test]
    async fn confirm_supersede_merges_sources_and_retires_old() {
        let pool = mem_pool().await;
        insert_person(&pool, "p1").await;
        for m in ["mA", "mB"] {
            insert_meeting(&pool, m).await;
        }

        let old = ProfileFactRepository::insert(
            &pool, "p1", "ships v2 by Q3", "goal", Some("mA"), Some("e-A"), "attributed", 0.8, "active",
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &old.id, Some("mA"), Some("e-A"), "attributed", "origin", 0.8,
        )
        .await
        .unwrap();

        let new = ProfileFactRepository::insert(
            &pool, "p1", "ships v2 by end of Q3", "goal", Some("mB"), Some("e-B"), "attributed", 0.5, "pending",
        )
        .await
        .unwrap();
        ProfileFactSourceRepository::add_source(
            &pool, &new.id, Some("mB"), Some("e-B"), "attributed", "origin", 0.5,
        )
        .await
        .unwrap();
        ProfileFactRepository::mark_supersedes(&pool, &new.id, &old.id)
            .await
            .unwrap();

        // Simulate confirm: carry -> raise confidence -> retire old.
        ProfileFactSourceRepository::carry_sources(&pool, &old.id, &new.id)
            .await
            .unwrap();
        ProfileFactSourceRepository::raise_confidence(&pool, &new.id, old.confidence)
            .await
            .unwrap();
        ProfileFactRepository::set_status(&pool, &new.id, "active")
            .await
            .unwrap();
        ProfileFactRepository::supersede(&pool, &old.id, &new.id)
            .await
            .unwrap();

        let new_reloaded = ProfileFactRepository::get_public(&pool, &new.id).await.unwrap().unwrap();
        assert_eq!(new_reloaded.source_count, 2, "replacement carries mA + mB");
        assert!(
            (new_reloaded.confidence - 0.8).abs() < 1e-9,
            "confidence raised to the superseded fact's higher value, not the new 0.5",
        );

        let old_reloaded = ProfileFactRepository::get_public(&pool, &old.id).await.unwrap().unwrap();
        assert_eq!(old_reloaded.status, "superseded");
        assert_eq!(old_reloaded.superseded_by.as_deref(), Some(new.id.as_str()));
    }
}

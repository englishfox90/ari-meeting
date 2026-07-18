use sqlx::SqlitePool;

use crate::database::models::{AskConversationRow, AskMessageRow};

pub struct AskConversationRepository;

impl AskConversationRepository {
    /// Delete conversations (and their messages) not touched since `cutoff_rfc3339`.
    /// Enforces the 7-day retention window; called before list/append.
    pub async fn prune_older_than(
        pool: &SqlitePool,
        cutoff_rfc3339: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query(
            "DELETE FROM ask_messages WHERE conversation_id IN \
             (SELECT id FROM ask_conversations WHERE updated_at < ?)",
        )
        .bind(cutoff_rfc3339)
        .execute(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM ask_conversations WHERE updated_at < ?")
            .bind(cutoff_rfc3339)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn create(
        pool: &SqlitePool,
        id: &str,
        meeting_id: Option<&str>,
        title: Option<&str>,
        now_rfc3339: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO ask_conversations (id, meeting_id, title, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(meeting_id)
        .bind(title)
        .bind(now_rfc3339)
        .bind(now_rfc3339)
        .execute(pool)
        .await?;
        Ok(())
    }

    /// List conversations for a scope, most-recently-updated first. `meeting_id = None`
    /// returns global (NULL-meeting) conversations; `Some(id)` returns that meeting's.
    pub async fn list(
        pool: &SqlitePool,
        meeting_id: Option<&str>,
    ) -> Result<Vec<AskConversationRow>, sqlx::Error> {
        match meeting_id {
            Some(meeting_id) => {
                sqlx::query_as::<_, AskConversationRow>(
                    "SELECT id, meeting_id, title, created_at, updated_at FROM ask_conversations \
                     WHERE meeting_id = ? ORDER BY updated_at DESC",
                )
                .bind(meeting_id)
                .fetch_all(pool)
                .await
            }
            None => {
                sqlx::query_as::<_, AskConversationRow>(
                    "SELECT id, meeting_id, title, created_at, updated_at FROM ask_conversations \
                     WHERE meeting_id IS NULL ORDER BY updated_at DESC",
                )
                .fetch_all(pool)
                .await
            }
        }
    }

    pub async fn get(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<AskConversationRow>, sqlx::Error> {
        sqlx::query_as::<_, AskConversationRow>(
            "SELECT id, meeting_id, title, created_at, updated_at FROM ask_conversations WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await
    }

    pub async fn messages(
        pool: &SqlitePool,
        conversation_id: &str,
    ) -> Result<Vec<AskMessageRow>, sqlx::Error> {
        sqlx::query_as::<_, AskMessageRow>(
            "SELECT id, conversation_id, role, content, sources_json, created_at \
             FROM ask_messages WHERE conversation_id = ? ORDER BY created_at ASC",
        )
        .bind(conversation_id)
        .fetch_all(pool)
        .await
    }

    /// Append a message and bump the conversation's `updated_at` (one transaction).
    pub async fn append_message(
        pool: &SqlitePool,
        message_id: &str,
        conversation_id: &str,
        role: &str,
        content: &str,
        sources_json: Option<&str>,
        now_rfc3339: &str,
    ) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query(
            "INSERT INTO ask_messages (id, conversation_id, role, content, sources_json, created_at) \
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(message_id)
        .bind(conversation_id)
        .bind(role)
        .bind(content)
        .bind(sources_json)
        .bind(now_rfc3339)
        .execute(&mut *tx)
        .await?;
        sqlx::query("UPDATE ask_conversations SET updated_at = ? WHERE id = ?")
            .bind(now_rfc3339)
            .bind(conversation_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn set_title(
        pool: &SqlitePool,
        id: &str,
        title: &str,
        now_rfc3339: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query("UPDATE ask_conversations SET title = ?, updated_at = ? WHERE id = ?")
            .bind(title)
            .bind(now_rfc3339)
            .bind(id)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn delete(pool: &SqlitePool, id: &str) -> Result<(), sqlx::Error> {
        let mut tx = pool.begin().await?;
        sqlx::query("DELETE FROM ask_messages WHERE conversation_id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM ask_conversations WHERE id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }
}

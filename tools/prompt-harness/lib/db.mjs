// db.mjs — read-only access to the app's SQLite store for fixture extraction.
//
// Mirrors the safety posture of tools/diarization_calibrate.py: the DB is
// opened with `mode=ro&immutable=1` in the connection URI AND
// `PRAGMA query_only = ON` as a second, independent guard, so a bug in this
// tool can never write to (or corrupt) the real app database. Verified by
// hand: an INSERT against a DB opened this way throws
// "attempt to write a readonly database".
//
// Schema referenced here (frontend/src-tauri/database/migrations/*.sql, as
// inspected 2026-07-16 against the live DB):
//   meetings(id, title, created_at, updated_at, folder_path, transcription_provider,
//            transcription_model, summary_provider, summary_model, template_id)
//   transcripts(id, meeting_id, transcript, timestamp, audio_start_time, audio_end_time,
//               duration, speaker, speaker_id)   -- `speaker` is the dead/legacy column,
//               NOT used (see .claude/context/open-questions.md Q4); we read speaker_id.
//   speakers(id, person_id, label, ...)
//   persons(id, display_name, ...)

import { DatabaseSync } from 'node:sqlite';
import os from 'node:os';
import path from 'node:path';

export const DEFAULT_DB_PATH = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'com.meetily.ai',
  'meeting_minutes.sqlite',
);

/**
 * Open the app's SQLite DB strictly read-only. Throws if the file doesn't
 * exist or can't be opened.
 */
export function openReadOnly(dbPath = DEFAULT_DB_PATH) {
  const db = new DatabaseSync(`file:${dbPath}?mode=ro&immutable=1`, { readOnly: true });
  // Second, independent guard: even if the URI mode were ever bypassed,
  // query_only rejects any write statement at the SQLite engine level.
  db.exec('PRAGMA query_only = ON;');
  return db;
}

/**
 * List candidate meetings for the fixture set: every meeting that has at
 * least one transcript row, newest first. Returns
 * { id, title, createdAt, transcriptCount, templateId, summaryProvider, summaryModel }.
 */
export function listCandidateMeetings(db) {
  const rows = db
    .prepare(
      `SELECT m.id AS id,
              m.title AS title,
              m.created_at AS createdAt,
              m.template_id AS templateId,
              m.summary_provider AS summaryProvider,
              m.summary_model AS summaryModel,
              COUNT(t.id) AS transcriptCount
       FROM meetings m
       JOIN transcripts t ON t.meeting_id = m.id
       GROUP BY m.id
       HAVING transcriptCount > 0
       ORDER BY m.created_at DESC`,
    )
    .all();
  return rows;
}

function formatTime(seconds, fallbackTimestamp) {
  if (seconds === undefined || seconds === null) {
    return fallbackTimestamp;
  }
  const totalSecs = Math.floor(seconds);
  const mins = Math.floor(totalSecs / 60);
  const secs = totalSecs % 60;
  return `[${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}]`;
}

/**
 * Load the full ordered transcript for a meeting id.
 *
 * Speaker-name resolution mirrors the frontend's resolveSpeakerLabelMap +
 * buildSummaryTranscriptPayload (frontend/src/lib/summary/summaryCore.ts):
 * transcripts.speaker_id -> speakers.person_id -> persons.display_name,
 * falling back to speakers.label, falling back to no prefix at all (an
 * unresolved speaker_id, or a NULL speaker_id, produces an unlabeled line
 * — never a fabricated name).
 *
 * Returns { lines: [{speaker, start, text}], transcriptText } where
 * transcriptText is the exact "[MM:SS] Name: text" rendering the app sends
 * as Call ③'s <transcript_chunks> body.
 */
export function loadTranscript(db, meetingId) {
  const rows = db
    .prepare(
      `SELECT t.id AS id,
              t.transcript AS text,
              t.timestamp AS timestamp,
              t.audio_start_time AS audioStartTime,
              t.speaker_id AS speakerId,
              s.label AS speakerLabel,
              p.display_name AS personDisplayName
       FROM transcripts t
       LEFT JOIN speakers s ON s.id = t.speaker_id
       LEFT JOIN persons p ON p.id = s.person_id
       WHERE t.meeting_id = ?
       ORDER BY t.audio_start_time ASC, t.id ASC`,
    )
    .all(meetingId);

  const lines = rows.map((r) => {
    const speakerName = r.personDisplayName || r.speakerLabel || null;
    return {
      speaker: speakerName,
      start: r.audioStartTime,
      text: r.text,
      timeMarker: formatTime(r.audioStartTime, r.timestamp),
    };
  });

  const transcriptText = lines
    .map((l) => `${l.timeMarker} ${l.speaker ? l.speaker + ': ' : ''}${l.text}`)
    .join('\n');

  return { lines, transcriptText };
}

/** Fetch one meeting's metadata row by id. */
export function getMeeting(db, meetingId) {
  return db.prepare('SELECT * FROM meetings WHERE id = ?').get(meetingId);
}

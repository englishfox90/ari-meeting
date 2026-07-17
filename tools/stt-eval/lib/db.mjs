// db.mjs — read-only access to the app's SQLite store, for the S2 STT-eval
// harness. Mirrors the safety posture of tools/prompt-harness/lib/db.mjs and
// tools/diarization-sweep/extract_reference.py: mode=ro&immutable=1 in the
// connection URI AND PRAGMA query_only=ON as a second, independent guard.
// This tool does NOT own the DB — treat frontend/src-tauri/database and the
// live app data as read-only from here, always.

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

export function openReadOnly(dbPath = DEFAULT_DB_PATH) {
  const db = new DatabaseSync(`file:${dbPath}?mode=ro&immutable=1`, { readOnly: true });
  db.exec('PRAGMA query_only = ON;');
  return db;
}

/** Concatenate a meeting's transcripts, ordered by audio_start_time — this
 * IS the shipped Parakeet hypothesis (no need to re-run Parakeet). */
export function getParakeetTranscript(db, meetingId) {
  const rows = db
    .prepare(
      `SELECT transcript, audio_start_time, audio_end_time
       FROM transcripts
       WHERE meeting_id = ?
       ORDER BY audio_start_time ASC`,
    )
    .all(meetingId);
  const text = rows.map((r) => r.transcript).join(' ');
  const segments = rows.map((r) => ({
    text: r.transcript,
    start: r.audio_start_time,
    end: r.audio_end_time,
  }));
  return { text, segments };
}

export function getMeeting(db, meetingId) {
  return db
    .prepare(`SELECT id, title, folder_path FROM meetings WHERE id = ?`)
    .get(meetingId);
}

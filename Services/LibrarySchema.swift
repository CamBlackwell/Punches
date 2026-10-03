import Foundation

/// The on-disk schema, its version, and the value types that map onto it.
///
/// ## Why this is not a JSON blob in `UserDefaults`
///
/// The library used to be a single `[AudioFile]` encoded to JSON under one
/// `UserDefaults` key, read back with `decode([AudioFile].self)`. That decode is
/// all-or-nothing across the whole array: one missing or retyped key throws, and
/// the catch leaves `audioFiles == []`. The app then treated "no index" as
/// "library is empty" and deleted the audio files. Worse, `AudioFile` used the
/// *synthesized* `Codable`, so adding any field to the model was enough to
/// trigger it.
///
/// Storing one row per track removes the failure mode structurally rather than
/// by discipline: there is no array to decode, so there is no array-wide
/// failure. `LibraryStore` keeps the transaction semantics that a single write
/// should have had, while the *granularity* of failure moves from "the entire
/// library" to "one row".
enum LibrarySchema {

    /// Bumped whenever `migrate(from:to:)` gains a step.
    static let currentVersion: Int32 = 1

    /// Statements that build version 1. Idempotent, so they double as the
    /// "create if absent" path.
    static let version1: [String] = [
        """
        CREATE TABLE IF NOT EXISTS track (
            id              TEXT    PRIMARY KEY NOT NULL,
            file_name       TEXT    NOT NULL,
            source_name     TEXT,
            display_title   TEXT    NOT NULL,
            ext             TEXT    NOT NULL,
            byte_size       INTEGER NOT NULL DEFAULT 0,
            duration        REAL    NOT NULL DEFAULT 0,
            date_added      REAL    NOT NULL DEFAULT 0,
            artwork_name    TEXT,
            origin_bookmark BLOB,
            state           INTEGER NOT NULL DEFAULT 0,
            reject_reason   TEXT,
            imported_via    TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_track_state ON track(state)",
        """
        CREATE TABLE IF NOT EXISTS playlist (
            id           TEXT    PRIMARY KEY NOT NULL,
            name         TEXT    NOT NULL,
            is_album     INTEGER NOT NULL DEFAULT 0,
            cover_name   TEXT,
            cover_manual INTEGER NOT NULL DEFAULT 0,
            artist       TEXT,
            date_added   REAL    NOT NULL DEFAULT 0,
            is_master    INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS playlist_member (
            playlist_id TEXT    NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
            track_id    TEXT    NOT NULL REFERENCES track(id)    ON DELETE CASCADE,
            position    INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, track_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_member_track ON playlist_member(track_id)",
        """
        CREATE TABLE IF NOT EXISTS import_job (
            id            TEXT    PRIMARY KEY NOT NULL,
            source_name   TEXT    NOT NULL,
            source_ext    TEXT    NOT NULL DEFAULT '',
            source_url    BLOB,
            staged_name   TEXT,
            inbound       INTEGER NOT NULL DEFAULT 0,
            state         INTEGER NOT NULL DEFAULT 0,
            attempts      INTEGER NOT NULL DEFAULT 0,
            last_error    TEXT,
            created_at    REAL    NOT NULL DEFAULT 0,
            updated_at    REAL    NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_job_state ON import_job(state)",
        """
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT
        )
        """,
    ]
}

/// Lifecycle of a library row.
///
/// Only `committed` rows are part of the user's library. The other cases exist
/// so that "something went wrong" has a name, a place to live, and a way to be
/// surfaced — the absence of which is why import failures used to be
/// indistinguishable from files that were never added.
enum TrackState: Int32, CaseIterable {
    /// In the library. The file is expected at `Tracks/<file_name>`.
    case committed = 0
    /// Was committed, but the file is not on disk right now. Recoverable: the
    /// original security-scoped bookmark, if we have one, may still resolve.
    case missing = 1
    /// Import was refused. `reject_reason` says why. Never auto-retried.
    case rejected = 2
    /// Moved to `Trash/` by a user action. Purged only on explicit request.
    case trashed = 3
    /// Found during migration but could not be confidently attributed. Surfaced
    /// for the user to resolve; never deleted.
    case unclaimed = 4
}

/// Lifecycle of an `import_job` row.
///
/// The job row is committed **before** any bytes are touched, so at every
/// instant the app can answer "what was in flight?" — which is what makes an
/// import resumable rather than a partial loss.
enum ImportJobState: Int32, CaseIterable {
    /// Row exists, no work started. Source may or may not still be reachable.
    case queued = 0
    /// Security scope held; bookmark refreshed while access was live.
    case scoped = 1
    /// Bytes are local (downloaded from a provider, if necessary).
    case materialised = 2
    /// Copied into `Staging/` under an atomic rename.
    case staged = 3
    /// Duration/playability read; awaiting the commit transaction.
    case validated = 4
    /// Track row and membership written in a single transaction.
    case committed = 5
    /// Refused. `last_error` holds the reason. Bytes, if any, are in `Trash/`.
    case rejected = 6
    /// Could not be completed and will not be retried. Recoverable by hand.
    case abandoned = 7
}

/// How a source file arrived.
enum ImportOrigin: String {
    case documentPicker
    case shareExtension
    case legacyMigration
    case reconciliation
}

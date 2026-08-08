use std::path::PathBuf;
use rusqlite::Connection;

/// Resolve the storage directory under `~/Library/Application Support/CopyAttach`.
pub(crate) fn get_persist_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Open (or create) the `SQLite` database with mmap and a small page cache.
pub(crate) fn open_db() -> Option<Connection> {
    let db_path = get_persist_dir()?.join("history.db");
    let conn = Connection::open(&db_path).map_err(|e| {
        eprintln!("CopyAttach: failed to open database: {e}");
    }).ok()?;
    // No mmap: the FTS5 trigram index (several× the text size) would be mapped
    // into the process and count as resident memory — confirmed ~1:1 RSS growth
    // with the index when the DB file stays under the old 32MB cap. Serving it
    // from the LRU page cache keeps DB-related resident memory bounded at the
    // cache size while still covering the same on-demand BLOB reads mmap used
    // to serve (thumbnails/full images are loaded one at a time, per click).
    let _ = conn.execute_batch(
        "PRAGMA mmap_size = 0;
         PRAGMA cache_size = -4096;    -- 4 MB LRU page cache"
    );
    Some(conn)
}

/// Create the history table if it does not already exist.
/// Adds the `entry_id` column via migration for schema versioning.
pub(crate) fn ensure_history_table(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_id        INTEGER NOT NULL DEFAULT 0,
            entry_type      INTEGER NOT NULL,
            text            TEXT,
            png_data        BLOB,
            width           INTEGER,
            height          INTEGER,
            thumb_data      BLOB,
            thumb_width     INTEGER,
            thumb_height    INTEGER,
            hash            INTEGER,
            timestamp       INTEGER NOT NULL,
            source_name     TEXT NOT NULL DEFAULT '',
            source_bundle_id TEXT NOT NULL DEFAULT ''
        );"
    )?;
    // Add entry_id column if this is an old DB that lacks it.
    // We try ALTER TABLE and only propagate the error if the column still
    // doesn't exist afterwards (duplicate-column on re-run is harmless).
    if let Err(e) = conn.execute_batch(
        "ALTER TABLE clipboard_history ADD COLUMN entry_id INTEGER NOT NULL DEFAULT 0;"
    ) {
        let has_column: bool = conn
            .prepare("SELECT entry_id FROM clipboard_history LIMIT 0")
            .is_ok();
        if !has_column {
            eprintln!("CopyAttach: failed to add entry_id column: {e}");
            return Err(e);
        }
    }
    // Backfill entry_id for rows that still have the default (0) using the
    // stable SQLite rowid, ensuring every entry has a persistent, unique ID
    // that survives restarts and reordering. Running this multiple times is
    // safe: once a row has a non-zero entry_id, the UPDATE is a no-op.
    // NB: if this fails, load_history_from_db will read entry_id=0 and
    // assign fresh IDs on every restart, breaking favorites — so we
    // propagate the error rather than silently falling back.
    conn.execute_batch(
        "UPDATE clipboard_history SET entry_id = id WHERE entry_id = 0;"
    )?;

    // FTS5 full-text index over the text column (trigram tokenizer = substring
    // matching for ≥3-char queries). Keeping full text out of the in-memory
    // history Vec is what bounds memory; the index makes search fast on disk.
    //
    // Sync is automatic via AFTER INSERT/DELETE triggers (triggers are per-DB,
    // so they persist across restarts; `IF NOT EXISTS` keeps init idempotent).
    // Image rows have text = NULL and are skipped by the WHEN clauses. The FTS
    // rowid is the base-table rowid, so the AFTER DELETE trigger removes the
    // indexed row directly (the `'delete'` special command is for external
    // content tables and is not needed here). The backfill populates the index
    // for rows that predate this virtual table, guarded so it only runs once
    // (an already-populated index is left untouched).
    conn.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
             text,
             tokenize = 'trigram'
         );
         INSERT INTO clipboard_fts(rowid, text)
             SELECT id, text FROM clipboard_history
             WHERE text IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM clipboard_fts LIMIT 1);
         CREATE TRIGGER IF NOT EXISTS clipboard_fts_ai AFTER INSERT ON clipboard_history
         WHEN new.text IS NOT NULL BEGIN
             INSERT INTO clipboard_fts(rowid, text) VALUES (new.id, new.text);
         END;
         CREATE TRIGGER IF NOT EXISTS clipboard_fts_ad AFTER DELETE ON clipboard_history
         WHEN old.text IS NOT NULL BEGIN
             DELETE FROM clipboard_fts WHERE rowid = old.id;
         END;"
    )?;
    Ok(())
}

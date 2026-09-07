use std::path::PathBuf;
use rusqlite::Connection;

/// Resolve the storage directory under `~/Library/Application Support/CopyAttach`.
pub(crate) fn get_persist_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Open (or create) the SQLite database with WAL, a small page cache, and no mmap.
pub(crate) fn open_db() -> Option<Connection> {
    let db_path = get_persist_dir()?.join("history.db");
    let conn = Connection::open(&db_path).map_err(|e| {
        crate::error_log!("CopyAttach: failed to open database: {e}");
    }).ok()?;
    // No mmap keeps the FTS index out of resident memory; a failed WAL switch
    // is logged rather than swallowed so the journal mode remains visible.
    if let Err(e) = conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA mmap_size = 0;
         PRAGMA cache_size = -4096;"
    ) {
        crate::error_log!("CopyAttach: failed to configure DB pragmas (WAL/synchronous/cache): {e}");
    }
    Some(conn)
}

/// Create the history table and migrate legacy columns/indexes.
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
            source_bundle_id TEXT NOT NULL DEFAULT '',
            preview         TEXT NOT NULL DEFAULT '',
            label           TEXT NOT NULL DEFAULT '',
            custom_label    TEXT NOT NULL DEFAULT ''
        );"
    )?;
    // Add entry_id to old DBs; ignore duplicate-column errors if it already exists.
    if let Err(e) = conn.execute_batch(
        "ALTER TABLE clipboard_history ADD COLUMN entry_id INTEGER NOT NULL DEFAULT 0;"
    ) {
        let has_column: bool = conn
            .prepare("SELECT entry_id FROM clipboard_history LIMIT 0")
            .is_ok();
        if !has_column {
            crate::error_log!("CopyAttach: failed to add entry_id column: {e}");
            return Err(e);
        }
    }
    // Backfill persistent entry IDs from rowids; propagate failure so favorites
    // don't silently break on every restart.
    conn.execute_batch(
        "UPDATE clipboard_history SET entry_id = id WHERE entry_id = 0;"
    )?;

    // Add preview/label to old DBs; same guarded ALTER pattern as entry_id.
    if let Err(e) = conn.execute_batch(
        "ALTER TABLE clipboard_history ADD COLUMN preview TEXT NOT NULL DEFAULT '';
         ALTER TABLE clipboard_history ADD COLUMN label TEXT NOT NULL DEFAULT '';"
    ) {
        let has_column: bool = conn
            .prepare("SELECT preview, label FROM clipboard_history LIMIT 0")
            .is_ok();
        if !has_column {
            crate::error_log!("CopyAttach: failed to add preview/label columns: {e}");
            return Err(e);
        }
    }

    // Add custom_label to old DBs; same guarded ALTER pattern as preview/label.
    if let Err(e) = conn.execute_batch(
        "ALTER TABLE clipboard_history ADD COLUMN custom_label TEXT NOT NULL DEFAULT '';"
    ) {
        let has_column: bool = conn
            .prepare("SELECT custom_label FROM clipboard_history LIMIT 0")
            .is_ok();
        if !has_column {
            crate::error_log!("CopyAttach: failed to add custom_label column: {e}");
            return Err(e);
        }
    }
    backfill_text_metadata(conn)?;

    // Dedup lookup index for (entry_type, hash).
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_history_type_hash
         ON clipboard_history(entry_type, hash);"
    )?;

    // FTS5 trigram index with a size cap. Oversized rows are skipped and remain
    // searchable via LIKE fallback; triggers keep the index in sync.
    let fts_sql = format!(
        "CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
             text,
             tokenize = 'trigram'
         );
         INSERT INTO clipboard_fts(rowid, text)
             SELECT id, text FROM clipboard_history
             WHERE text IS NOT NULL
               AND length(text) <= {fts_cap}
               AND NOT EXISTS (SELECT 1 FROM clipboard_fts LIMIT 1);
         DELETE FROM clipboard_fts
             WHERE rowid IN (SELECT id FROM clipboard_history
                             WHERE entry_type = 0 AND text IS NOT NULL
                               AND length(text) > {fts_cap});
         DROP TRIGGER IF EXISTS clipboard_fts_ai;
         CREATE TRIGGER clipboard_fts_ai AFTER INSERT ON clipboard_history
         WHEN new.text IS NOT NULL AND length(new.text) <= {fts_cap} BEGIN
             INSERT INTO clipboard_fts(rowid, text) VALUES (new.id, new.text);
         END;
         DROP TRIGGER IF EXISTS clipboard_fts_ad;
         CREATE TRIGGER clipboard_fts_ad AFTER DELETE ON clipboard_history
         WHEN old.text IS NOT NULL BEGIN
             DELETE FROM clipboard_fts WHERE rowid = old.id;
         END;",
        fts_cap = FTS_MAX_INDEXED_TEXT_LEN,
    );
    conn.execute_batch(&fts_sql)?;
    Ok(())
}

/// Metadata migration version stored in SQLite `user_version`.
pub(crate) const METADATA_VERSION: i32 = 3;

/// Max text length indexed by FTS; oversized rows use a LIKE fallback.
pub(crate) const FTS_MAX_INDEXED_TEXT_LEN: i64 = 512 * 1024;

/// Backfill/recompute text metadata once for legacy rows, one at a time.
fn backfill_text_metadata(conn: &Connection) -> Result<(), rusqlite::Error> {
    let version: i32 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version >= 2 {
        return Ok(());
    }
    let ids: Vec<i64> = {
        let mut stmt = conn.prepare(
            "SELECT id FROM clipboard_history
             WHERE entry_type = 0 AND text IS NOT NULL"
        )?;
        let rows = stmt.query_map([], |row| row.get::<_, i64>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    if !ids.is_empty() {
        let tx = conn.unchecked_transaction()?;
        for id in ids {
            let text: String = tx.query_row(
                "SELECT text FROM clipboard_history WHERE id = ?1",
                rusqlite::params![id],
                |row| row.get(0),
            )?;
            tx.execute(
                "UPDATE clipboard_history SET hash = ?1, preview = ?2, label = ?3 WHERE id = ?4",
                rusqlite::params![
                    crate::types::text_hash(&text) as i64,
                    crate::types::bounded_preview(&text),
                    crate::types::label_from_text(&text),
                    id,
                ],
            )?;
        }
        tx.commit()?;
    }
    // Stamp only after commit so a failure retries next launch.
    conn.pragma_update(None, "user_version", 2)?;
    Ok(())
}

/// Recompute one image row's hash to the stable algorithm; `Err` leaves it untouched.
pub(crate) fn migrate_one_image_row(conn: &Connection, id: i64) -> Result<u64, ()> {
    let png: Vec<u8> = conn.query_row(
        "SELECT png_data FROM clipboard_history WHERE id = ?1 AND entry_type = 1",
        rusqlite::params![id],
        |row| row.get(0),
    ).map_err(|e| {
        crate::debug_log!("CopyAttach: image-hash migration: cannot load png for row {id}: {e}");
    })?;
    if png.is_empty() {
        crate::debug_log!("CopyAttach: image-hash migration: row {id} has empty png_data — hash left as-is");
        return Err(());
    }
    // Claim reusable-marked pages before the decoder reads the blob.
    crate::backend::claim_pages(png.as_ptr(), png.capacity());
    let img = image::load_from_memory(&png).map_err(|e| {
        crate::debug_log!("CopyAttach: image-hash migration: row {id} png undecodable: {e}");
    })?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let hash = crate::image::image_hash(&rgba, w, h);
    conn.execute(
        "UPDATE clipboard_history SET hash = ?1 WHERE id = ?2",
        rusqlite::params![hash as i64, id],
    ).map_err(|e| {
        crate::debug_log!("CopyAttach: image-hash migration: update failed for row {id}: {e}");
    })?;
    Ok(hash)
}

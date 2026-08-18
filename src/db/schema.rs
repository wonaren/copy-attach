use std::path::PathBuf;
use rusqlite::Connection;

/// Resolve the storage directory under `~/Library/Application Support/CopyAttach`.
pub(crate) fn get_persist_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Open (or create) the `SQLite` database with WAL, a small page cache, and no
/// mmap.
///
/// WAL + `synchronous=NORMAL` turns the per-capture write-through (insert +
/// dedup + trim) from 3 fully-synced transactions into 1 WAL append — one
/// fsync instead of three, lower latency, and far less SSD/battery wear. Reads
/// (search, thumbnail loads) no longer block behind writes.
pub(crate) fn open_db() -> Option<Connection> {
    let db_path = get_persist_dir()?.join("history.db");
    let conn = Connection::open(&db_path).map_err(|e| {
        crate::error_log!("CopyAttach: failed to open database: {e}");
    }).ok()?;
    // No mmap: the FTS5 trigram index (several× the text size) would be mapped
    // into the process and count as resident memory — confirmed ~1:1 RSS growth
    // with the index when the DB file stays under the old 32MB cap. Serving it
    // from the LRU page cache keeps DB-related resident memory bounded at the
    // cache size while still covering the same on-demand BLOB reads mmap used
    // to serve (thumbnails/full images are loaded one at a time, per click).
    // `cache_size` is negative here, which SQLite reads as KiB (-4096 = 4 MB).
    // A failed WAL switch (e.g. SQLITE_BUSY because an older app instance is
    // still running against this DB) must be visible, not silently swallowed:
    // the DB then stays in DELETE journal mode until the next clean launch.
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

/// Create the history table if it does not already exist.
/// Adds the `entry_id`, `preview`, and `label` columns via migration for
/// schema versioning.
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
            label           TEXT NOT NULL DEFAULT ''
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
            crate::error_log!("CopyAttach: failed to add entry_id column: {e}");
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

    // Add preview/label columns if this is an old DB that lacks them (text
    // metadata persisted so cold start never reads the full `text` column).
    // Same guarded ALTER pattern as entry_id above.
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
    backfill_text_metadata(conn)?;

    // Dedup lookup index: `delete_matching_entry` narrows by (entry_type,
    // hash) and verifies exact text, so a duplicate scan is an index lookup
    // instead of a full table scan on every capture.
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_history_type_hash
         ON clipboard_history(entry_type, hash);"
    )?;

    // FTS5 full-text index over the text column (trigram tokenizer = substring
    // matching for ≥3-char queries). Keeping full text out of the in-memory
    // history Vec is what bounds memory; the index makes search fast on disk.
    //
    // The index has a SIZE CAP: text rows longer than `FTS_MAX_INDEXED_TEXT_LEN`
    // characters are NOT indexed. A trigram index costs several× the text size
    // on disk (measured ~6.4×: 10.6MB of text → 68MB DB) and the synchronous
    // capture-path insert scales linearly with size (measured: 2MB text →
    // ~170ms, 8MB → ~760ms of monitor-thread stall). The cap keeps the index
    // and the per-capture write cost bounded no matter how large pasted
    // documents get. Excluded rows stay fully searchable: `db::search_history`
    // runs a LIKE fallback over oversized rows for ≥3-char queries (substring
    // semantics preserved, scan bounded to the rare huge rows — see search.rs).
    //
    // Sync is automatic via AFTER INSERT/DELETE triggers. The insert trigger is
    // DROP + CREATE (not IF NOT EXISTS): triggers persist per-DB, so an old
    // installation would otherwise keep its uncapped trigger forever; the
    // per-launch DROP+CREATE of an empty trigger is negligible. Image rows
    // have text = NULL and are skipped by the WHEN clauses. The FTS rowid is
    // the base-table rowid, so the AFTER DELETE trigger removes the indexed
    // row directly (the `'delete'` special command is for external content
    // tables and is not needed here). The backfill populates the index for
    // rows that predate this virtual table, guarded so it only runs once (an
    // already-populated index is left untouched). The cleanup DELETE evicts
    // oversized rows that predate the cap (idempotent; empty when nothing
    // matches), so legacy indexes shrink to the capped set.
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

/// Persisted-metadata generations, stamped into SQLite's `user_version`:
/// 0 = pre-0.99.15 (no persisted text metadata, DefaultHasher image hashes),
/// 1 = 0.99.15-dev (DefaultHasher text_hash persisted),
/// 2 = stable FNV-1a text hashes (text phase done; image hashes may still be
///     DefaultHasher — a background thread migrates them one row at a time and
///     stamps 3 on completion),
/// 3 = stable FNV-1a text AND image hashes.
pub(crate) const METADATA_VERSION: i32 = 3;

/// Upper bound (in Unicode characters — SQLite `length()` on TEXT counts
/// characters) for text rows that get trigram-indexed. Above this the row is
/// stored but NOT indexed: the trigram index amplifies disk usage several×
/// (~6.4× measured) and the synchronous capture-path insert cost scales with
/// text size (~0.17s per 2MB measured) — a cap keeps both bounded for huge
/// pastes. Excluded rows remain searchable through the LIKE fallback in
/// `db::search_history` (bounded to the rare oversized rows).
pub(crate) const FTS_MAX_INDEXED_TEXT_LEN: i64 = 512 * 1024;

/// Backfill / recompute persisted text metadata (`hash`/`preview`/`label`) for
/// text rows whose metadata predates generation 2. Gated on
/// `user_version < 2`, so it runs exactly once per text generation: version 0
/// rows get their first metadata, version 1 rows get their DefaultHasher
/// hashes recomputed with the stable FNV-1a algorithm (`text_hash` is
/// persisted — std's documented-unstable DefaultHasher must not survive in the
/// DB, or a future Rust change would break re-capture dedup against old rows).
/// On success stamps `user_version = 2`. Image hashes (generation 2 → 3) are
/// migrated separately by `migrate_one_image_row` on a background thread —
/// decoding hundreds of MB of stored PNGs must not stall startup.
///
/// Rows are processed one at a time (id list first, then per-row SELECT +
/// UPDATE) so a legacy DB holding many multi-MB texts never has its whole
/// corpus in memory at once. The cold-start load then never touches the
/// `text` column again.
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
    // Stamp the text generation only after the recompute commits; a failure
    // above leaves the old version in place and the next init retries.
    conn.pragma_update(None, "user_version", 2)?;
    Ok(())
}

/// Recompute ONE image row's persisted content hash with the stable algorithm
/// (`image::image_hash`, FNV-1a over decoded RGBA). The hash hashes raw
/// pixels, so the stored PNG must be decoded — PNG is lossless, so decoding
/// reproduces exactly the RGBA the capture hashed.
///
/// Returns the new hash, or `Err` when the row is missing, its PNG is empty,
/// or the PNG cannot be decoded — the old hash is left untouched and the
/// caller logs/counts the failure explicitly. Callers run this one row at a
/// time under a fresh DB lock so captures never wait behind a whole-corpus
/// decode.
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
    // Claim any reusable-marked pages the allocator handed back before the
    // decoder reads the blob (see ffi::mod::vec_to_raw for the rationale).
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

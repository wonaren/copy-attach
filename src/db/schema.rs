use std::path::PathBuf;
use rusqlite::Connection;

/// Why a database operation failed, at the granularity the UI must act on.
///
/// The distinction is load-bearing: the startup path retries transient failures
/// forever, but a permanent environment failure (read-only file, disk full,
/// permission denied) never succeeds on retry. Collapsing them into one
/// "failed" value — as the previous Option-returning open did — produced an
/// infinite 5 s retry loop with no user-visible cause.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DbFailure {
    /// Retrying may succeed: busy/locked (another process holds it) or a
    /// transient IO error.
    Transient,
    /// Retrying cannot help without user action, but the database file itself
    /// is intact. The environment is the problem (read-only, permissions,
    /// disk full, path not openable).
    PermanentEnvironment,
    /// The file is not a usable database. Only replacing it can help.
    Corrupt,
}

/// Classify a rusqlite error into the category the caller must act on.
pub(crate) fn classify_db_error(e: &rusqlite::Error) -> DbFailure {
    let code = match e {
        rusqlite::Error::SqliteFailure(ffi, _) => ffi.code,
        _ => return DbFailure::Transient,
    };
    match code {
        rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase => {
            DbFailure::Corrupt
        }
        rusqlite::ErrorCode::ReadOnly
        | rusqlite::ErrorCode::CannotOpen
        | rusqlite::ErrorCode::PermissionDenied
        | rusqlite::ErrorCode::DiskFull => DbFailure::PermanentEnvironment,
        // DatabaseBusy / DatabaseLocked / SystemIoFailure / OperationInterrupted
        // and anything unrecognized: a retry may succeed.
        _ => DbFailure::Transient,
    }
}

/// Resolve the storage directory under `~/Library/Application Support/CopyAttach`.
///
/// `COPYATTACH_DATA_DIR` overrides the location. It exists so the real startup
/// path (open -> init -> backoff -> recover) can be exercised against a
/// controlled database without touching the user's data or overriding HOME
/// (overriding HOME breaks keychain access — see CLAUDE.md). Unset in normal
/// operation, where it has no effect.
pub(crate) fn get_persist_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("COPYATTACH_DATA_DIR") {
        let dir = PathBuf::from(dir);
        if let Err(e) = std::fs::create_dir_all(&dir) {
            crate::error_log!(
                "CopyAttach: COPYATTACH_DATA_DIR {} is unusable: {e}",
                dir.display()
            );
            return None;
        }
        return Some(dir);
    }
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Open (or create) the SQLite database with WAL, a small page cache, and no mmap.
///
/// The failure is classified rather than flattened: the caller uses it to decide
/// between retrying, surfacing an environment problem, and offering a rebuild.
pub(crate) fn open_db() -> Result<Connection, DbFailure> {
    let dir = get_persist_dir().ok_or_else(|| {
        crate::error_log!("CopyAttach: cannot resolve or create the storage directory");
        DbFailure::PermanentEnvironment
    })?;
    let db_path = dir.join("history.db");
    let conn = Connection::open(&db_path).map_err(|e| {
        let failure = classify_db_error(&e);
        crate::error_log!("CopyAttach: failed to open database ({}): {e}", db_path.display());
        failure
    })?;
    // Configure the connection. A WAL switch can fail on a read-only file even
    // when the open succeeded; that is a permanent environment failure, not a
    // warning, so it is classified and returned rather than swallowed.
    if let Err(e) = conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA mmap_size = 0;
         PRAGMA cache_size = -4096;"
    ) {
        let failure = classify_db_error(&e);
        crate::error_log!("CopyAttach: failed to configure DB pragmas ({failure:?}): {e}");
        return Err(failure);
    }
    Ok(conn)
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

    // Monotonic entry-id high-water mark.
    //
    // entry_id is the identity Swift stores favorites against, so it must
    // never be handed out twice for the lifetime of a database — not merely
    // within one session. Priming the counter from `MAX(entry_id)` of the
    // rows that happen to be loaded is not enough: after the history is
    // cleared the table is empty, the counter restarts at 1, and newly
    // captured entries walk straight through the ids recorded in the
    // Favorites list — old favorites then light up on unrelated new content.
    // The watermark is stored in the DB (surviving clear, trim, and restart)
    // and only ever moves forward.
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_meta (
             key   TEXT PRIMARY KEY,
             value INTEGER NOT NULL
         );"
    )?;

    // Dedup lookup index for (entry_type, hash).
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_history_type_hash
         ON clipboard_history(entry_type, hash);"
    )?;

    // FTS5 trigram index with a size cap. Oversized rows are skipped and remain
    // searchable via LIKE fallback. AFTER INSERT and AFTER DELETE triggers keep
    // the index in sync; there is no UPDATE trigger because `text` is never
    // updated in place.
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

/// Key of the monotonic entry-id high-water mark in `clipboard_meta`.
pub(crate) const ENTRY_ID_WATERMARK_KEY: &str = "entry_id_watermark";

/// Highest entry id ever issued for this database. 0 when never recorded.
///
/// Reads the persisted watermark only; the caller combines it with the
/// loaded rows' maximum (a database written by an older build has no
/// watermark yet).
pub(crate) fn entry_id_watermark(conn: &Connection) -> u64 {
    conn.query_row(
        "SELECT value FROM clipboard_meta WHERE key = ?1",
        rusqlite::params![ENTRY_ID_WATERMARK_KEY],
        |row| row.get::<_, i64>(0),
    )
    .map(|v| v.max(0) as u64)
    .unwrap_or(0)
}

/// Raise the watermark to `value`. Never lowers it, so a stale caller cannot
/// reopen a gap that ids were already issued from.
pub(crate) fn bump_entry_id_watermark(conn: &Connection, value: u64) -> Result<(), ()> {
    conn.execute(
        "INSERT INTO clipboard_meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = MAX(value, excluded.value)",
        rusqlite::params![ENTRY_ID_WATERMARK_KEY, value as i64],
    )
    .map(|_| ())
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to record entry-id watermark {value}: {e}");
    })
}

/// Metadata migration version stored in SQLite `user_version`.
///
/// 0 legacy → 1 first text backfill → 2 DefaultHasher text recompute →
/// 3 stable FNV-1a for text + image hashes → 4 thumbnails re-encoded to the
/// display-box fit.
pub(crate) const METADATA_VERSION: i32 = 4;

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
    // Claim reusable-marked pages before the decoder reads the blob. A rejected
    // claim means the decode could read reclaimed pages, so the row is treated
    // as undecodable (skipped, logged, and retried on the next launch — the
    // migration is idempotent).
    if !crate::backend::claim_pages(png.as_ptr(), png.capacity()) {
        crate::error_log!("CopyAttach: image-hash migration: row {id} png blob could not be claimed — skipped");
        return Err(());
    }
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

/// Re-encode one image row's thumbnail to the current display-box fit.
///
/// `Ok(None)` means the stored thumbnail already matches the target dims and was
/// left alone (no re-encode); `Ok(Some(dims))` reports the new thumbnail size;
/// `Err` leaves the row untouched.
///
/// Unlike the hash migration (a pure recompute), this changes stored bytes: the
/// thumbnail geometry moved from "300px longest edge" to a 920×200 display box,
/// so rows captured by an older build keep an undersized blob that the row then
/// upscales. Re-encoding uses `create_thumbnail_fast` — the exact production
/// path — so a migrated thumbnail is byte-identical to a freshly captured one.
pub(crate) fn migrate_one_thumbnail_row(
    conn: &Connection, id: i64, blob: &mut Vec<u8>, scratch: &mut Vec<u8>,
) -> Result<Option<(u32, u32)>, ()> {
    // Decide from metadata first: the target dims are a pure function of the
    // stored source width/height, so a row whose thumbnail already matches
    // needs no blob read at all. Reading 162 MB of PNGs across a history to
    // then discard most of them is what made this pass memory-hungry.
    let (w, h, old_tw, old_th, old_thumb_len): (i64, i64, i64, i64, i64) = conn.query_row(
        "SELECT width, height, thumb_width, thumb_height, LENGTH(thumb_data)
         FROM clipboard_history WHERE id = ?1 AND entry_type = 1",
        rusqlite::params![id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
    ).map_err(|e| {
        crate::debug_log!("CopyAttach: thumbnail migration: cannot read row {id}: {e}");
    })?;
    if w <= 0 || h <= 0 {
        crate::debug_log!("CopyAttach: thumbnail migration: row {id} has no usable dims — skipped");
        return Err(());
    }
    let (want_w, want_h) =
        crate::image::thumbnail_target_dims(w as u32, h as u32).unwrap_or((w as u32, h as u32));
    // A row already at the target dims needs no work — but only if it really
    // carries a blob. Dims without bytes (e.g. a Phase 2 that never landed)
    // must still be re-encoded, so the length check stays.
    if old_thumb_len > 0 && (want_w as i64, want_h as i64) == (old_tw, old_th) {
        return Ok(None);
    }

    // Only now, for rows that genuinely need re-encoding, load the blob.
    // `blob` is caller-owned and reused across rows: allocating a fresh
    // 4-7 MB Vec per row made malloc churn, and every freed one kept its
    // pages resident after being marked reusable (measured `Malloc Large
    // (Reusable)` = 132 MB at the end of the pass, and a 180 MB peak for
    // 137 mixed-size rows versus 55 MB when every row is one size).
    let loaded = conn.query_row(
        "SELECT png_data FROM clipboard_history WHERE id = ?1 AND entry_type = 1",
        rusqlite::params![id],
        |row| {
            let bytes = match row.get_ref(0)? {
                rusqlite::types::ValueRef::Blob(b) => b,
                _ => &[],
            };
            blob.clear();
            if blob.capacity() < bytes.len() {
                blob.reserve(bytes.len());
            }
            // The pages may have come back from malloc still marked
            // reclaimable, so claim before writing (madvise contract). A
            // rejected claim means the blob we are about to build could lose
            // pages mid-copy, so report the row as unreadable rather than
            // hand the migration a half-valid PNG.
            if !crate::backend::claim_pages(blob.as_ptr(), blob.capacity()) {
                crate::error_log!("CopyAttach: thumbnail migration: blob buffer could not be claimed for row {id}");
                return Err(rusqlite::Error::InvalidQuery);
            }
            blob.extend_from_slice(bytes);
            Ok(!bytes.is_empty())
        },
    ).map_err(|e| {
        crate::debug_log!("CopyAttach: thumbnail migration: cannot load png for row {id}: {e}");
    })?;
    if !loaded {
        crate::debug_log!("CopyAttach: thumbnail migration: row {id} has empty png_data — skipped");
        return Err(());
    }
    let png: &[u8] = blob;

    // Decode into a caller-owned scratch reused across rows. The capture
    // pipeline's single-slot pool is deliberately NOT used: this is a one-shot
    // startup pass, and parking its buffer in that pool would couple two
    // unrelated phases and leave a migration-sized buffer pool-resident for
    // the rest of the session.
    let decoded_dims = crate::image::decode_png_rgba8_into(png, scratch).or_else(|| {
        // Non-RGBA8 PNG: let the image crate decode, copy into the scratch,
        // then hand the temporary's pages back.
        let img = image::load_from_memory(png).ok()?;
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let raw = rgba.into_raw();
        // Both buffers feed the copy below. The temporary is freshly decoded
        // by the image crate (unmarked), but it is claimed anyway so the
        // release-side symmetry holds; the reuse scratch may still carry a
        // previous row's marking, so an unclaimable scratch must abandon the
        // row instead of copying into possibly-reclaimable pages.
        if !crate::backend::claim_pages(raw.as_ptr(), raw.capacity())
            || !crate::backend::claim_pages(scratch.as_ptr(), scratch.capacity())
        {
            crate::error_log!("CopyAttach: thumbnail migration: decode scratch could not be claimed for row {id}");
            crate::backend::mark_pages_reusable(raw.as_ptr(), raw.capacity());
            return None;
        }
        scratch.clear();
        if scratch.capacity() < raw.len() {
            // Grow as one whole allocation: a realloc-spliced mapping rejects
            // madvise (see the pool rule in image.rs) and would break the
            // reuse contract for every later row.
            let fresh: Vec<u8> = Vec::with_capacity(raw.len());
            crate::backend::mark_pages_reusable(scratch.as_ptr(), scratch.capacity());
            if !crate::backend::claim_pages(fresh.as_ptr(), fresh.capacity()) {
                crate::error_log!("CopyAttach: thumbnail migration: fresh scratch could not be claimed for row {id}");
                crate::backend::mark_pages_reusable(raw.as_ptr(), raw.capacity());
                return None;
            }
            *scratch = fresh;
        }
        scratch.extend_from_slice(&raw);
        crate::backend::mark_pages_reusable(raw.as_ptr(), raw.capacity());
        Some((w, h))
    });
    // Size from the *decoded* dimensions: they belong to this buffer, and
    // they are exactly the input the capture path fed to
    // `create_thumbnail_fast`. Using the metadata columns instead would let a
    // disagreement between the two resize against the wrong stride.
    let (decoded_w, decoded_h) = decoded_dims.ok_or_else(|| {
        crate::debug_log!("CopyAttach: thumbnail migration: row {id} png undecodable");
    })?;
    let (thumb_data, tw, th) =
        crate::image::create_thumbnail_fast(decoded_w, decoded_h, scratch).ok_or_else(|| {
        crate::debug_log!("CopyAttach: thumbnail migration: row {id} thumbnail generation failed");
    })?;
    // The encoded blob is a fresh allocation released right after the write;
    // return its pages to the system on release (release-side symmetry with
    // the claimed decode scratch), or a whole-history pass leaves them dirty.
    let thumb_guard = crate::backend::MarkBlobReusableOnDrop(thumb_data);
    conn.execute(
        "UPDATE clipboard_history SET thumb_data = ?1, thumb_width = ?2, thumb_height = ?3
         WHERE id = ?4",
        rusqlite::params![thumb_guard.0, i64::from(tw), i64::from(th), id],
    ).map_err(|e| {
        crate::debug_log!("CopyAttach: thumbnail migration: update failed for row {id}: {e}");
    })?;
    Ok(Some((tw, th)))
}

use std::collections::HashSet;
use std::path::PathBuf;
use rusqlite::Connection;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DbFailure {
    Transient,
    PermanentEnvironment,
    Corrupt,
}

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
        _ => DbFailure::Transient,
    }
}

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
    if let Err(e) = conn.execute_batch(
        "PRAGMA auto_vacuum = INCREMENTAL;
         PRAGMA journal_mode = WAL;
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
    conn.execute_batch(
        "UPDATE clipboard_history SET entry_id = id WHERE entry_id = 0;"
    )?;

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

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_meta (
             key   TEXT PRIMARY KEY,
             value INTEGER NOT NULL
         );"
    )?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_favorites (
             entry_id INTEGER PRIMARY KEY
         );"
    )?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_quick_slots (
             slot     INTEGER PRIMARY KEY CHECK (slot BETWEEN 1 AND 9),
             entry_id INTEGER NOT NULL UNIQUE
         );"
    )?;

    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_history_type_hash
         ON clipboard_history(entry_type, hash);"
    )?;

    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_history_timestamp
         ON clipboard_history(timestamp DESC, id DESC);"
    )?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_deleted (
             row_id      INTEGER PRIMARY KEY,
             entry_id    INTEGER NOT NULL,
             deleted_at  INTEGER NOT NULL,
             was_favorite INTEGER NOT NULL DEFAULT 0,
             was_slot    INTEGER NOT NULL DEFAULT 0
         );
         CREATE INDEX IF NOT EXISTS idx_deleted_stamp
             ON clipboard_deleted(deleted_at DESC);"
    )?;
    if let Err(e) = conn.execute_batch(
        "ALTER TABLE clipboard_deleted ADD COLUMN was_slot INTEGER NOT NULL DEFAULT 0;"
    ) {
        let has_column: bool = conn
            .prepare("SELECT was_slot FROM clipboard_deleted LIMIT 0")
            .is_ok();
        if !has_column {
            crate::error_log!("CopyAttach: failed to add was_slot column: {e}");
            return Err(e);
        }
    }

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

pub(crate) const ENTRY_ID_WATERMARK_KEY: &str = "entry_id_watermark";

pub(crate) const UNDO_LIMIT_KEY: &str = "undo_budget_bytes";

pub(crate) fn load_undo_limit(conn: &Connection) -> Result<i64, ()> {
    match conn.query_row(
        "SELECT value FROM clipboard_meta WHERE key = ?1",
        rusqlite::params![UNDO_LIMIT_KEY],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(v) => Ok(v),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(crate::backend::DEFAULT_UNDO_LIMIT),
        Err(e) => {
            crate::error_log!("CopyAttach: failed to read the undo limit: {e}");
            Err(())
        }
    }
}

pub(crate) fn store_undo_limit(conn: &Connection, limit: i64) -> Result<(), ()> {
    conn.execute(
        "INSERT INTO clipboard_meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![UNDO_LIMIT_KEY, limit],
    )
    .map(|_| ())
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to record the undo limit {limit}: {e}");
    })
}

pub(crate) fn entry_id_watermark(conn: &Connection) -> u64 {
    conn.query_row(
        "SELECT value FROM clipboard_meta WHERE key = ?1",
        rusqlite::params![ENTRY_ID_WATERMARK_KEY],
        |row| row.get::<_, i64>(0),
    )
    .map(|v| v.max(0) as u64)
    .unwrap_or(0)
}

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

pub(crate) fn load_favorites(conn: &Connection) -> Result<HashSet<u64>, ()> {
    let mut stmt = conn.prepare("SELECT entry_id FROM clipboard_favorites").map_err(|e| {
        crate::error_log!("CopyAttach: failed to prepare favorites load: {e}");
    })?;
    let rows = stmt.query_map([], |row| row.get::<_, i64>(0)).map_err(|e| {
        crate::error_log!("CopyAttach: failed to query favorites: {e}");
    })?;
    Ok(rows
        .flatten()
        .filter(|id| *id > 0)
        .map(|id| id as u64)
        .collect())
}

pub(crate) fn prune_orphan_favorites(conn: &Connection) -> Result<usize, ()> {
    conn.execute(
        "DELETE FROM clipboard_favorites
         WHERE entry_id NOT IN (SELECT entry_id FROM clipboard_history
                                WHERE id NOT IN (SELECT row_id FROM clipboard_deleted))",
        [],
    )
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to prune orphan favorites: {e}");
    })
}

pub(crate) fn set_favorite(conn: &Connection, entry_id: u64, favorite: bool) -> Result<(), ()> {
    let exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_history
             WHERE entry_id = ?1
               AND id NOT IN (SELECT row_id FROM clipboard_deleted)",
            rusqlite::params![entry_id as i64],
            |row| row.get(0),
        )
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to look up entry {entry_id} for favorite toggle: {e}");
        })?;
    if exists == 0 {
        crate::error_log!("CopyAttach: favorite toggle for unknown entry {entry_id}");
        return Err(());
    }
    let sql = if favorite {
        "INSERT OR IGNORE INTO clipboard_favorites (entry_id)
         SELECT entry_id FROM clipboard_history
         WHERE entry_id = ?1 AND id NOT IN (SELECT row_id FROM clipboard_deleted)"
    } else {
        "DELETE FROM clipboard_favorites WHERE entry_id = ?1"
    };
    conn.execute(sql, rusqlite::params![entry_id as i64])
        .map(|_| ())
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to persist favorite state for entry {entry_id}: {e}");
        })
}

pub(crate) const QUICK_SLOT_COUNT: usize = 9;

pub(crate) fn load_quick_slots(conn: &Connection) -> Result<[u64; QUICK_SLOT_COUNT], ()> {
    let mut slots = [0u64; QUICK_SLOT_COUNT];
    let mut stmt = conn
        .prepare("SELECT slot, entry_id FROM clipboard_quick_slots")
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to prepare quick-slot load: {e}");
        })?;
    let rows = stmt
        .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)))
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to query quick slots: {e}");
        })?;
    for (slot, entry_id) in rows.flatten() {
        if (1..=QUICK_SLOT_COUNT as i64).contains(&slot) && entry_id > 0 {
            slots[(slot - 1) as usize] = entry_id as u64;
        }
    }
    Ok(slots)
}

pub(crate) fn prune_orphan_quick_slots(conn: &Connection) -> Result<usize, ()> {
    conn.execute(
        "DELETE FROM clipboard_quick_slots
         WHERE entry_id NOT IN (SELECT entry_id FROM clipboard_history
                                WHERE id NOT IN (SELECT row_id FROM clipboard_deleted))",
        [],
    )
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to prune orphan quick slots: {e}");
    })
}

pub(crate) fn toggle_quick_slot(conn: &Connection, entry_id: u64, slot: u8) -> Result<(), ()> {
    if slot == 0 || slot as usize > QUICK_SLOT_COUNT {
        crate::error_log!("CopyAttach: quick-slot toggle rejected: slot {slot} out of range");
        return Err(());
    }
    let exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_history
             WHERE entry_id = ?1
               AND id NOT IN (SELECT row_id FROM clipboard_deleted)",
            rusqlite::params![entry_id as i64],
            |row| row.get(0),
        )
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to look up entry {entry_id} for quick slot: {e}");
        })?;
    if exists == 0 {
        crate::error_log!("CopyAttach: quick-slot toggle for unknown entry {entry_id}");
        return Err(());
    }
    let tx = conn.unchecked_transaction().map_err(|e| {
        crate::error_log!("CopyAttach: failed to begin quick-slot transaction: {e}");
    })?;
    let current = match tx.query_row(
        "SELECT slot FROM clipboard_quick_slots WHERE entry_id = ?1",
        rusqlite::params![entry_id as i64],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(v) => Some(v),
        Err(rusqlite::Error::QueryReturnedNoRows) => None,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to read the current quick slot for {entry_id}: {e}");
            return Err(());
        }
    };
    let result = if current == Some(slot as i64) {
        tx.execute(
            "DELETE FROM clipboard_quick_slots WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
        )
    } else {
        tx.execute(
            "DELETE FROM clipboard_quick_slots WHERE slot = ?1 OR entry_id = ?2",
            rusqlite::params![slot as i64, entry_id as i64],
        )
        .and_then(|_| {
            tx.execute(
                "INSERT INTO clipboard_quick_slots (slot, entry_id) VALUES (?1, ?2)",
                rusqlite::params![slot as i64, entry_id as i64],
            )
        })
    };
    if let Err(e) = result {
        crate::error_log!("CopyAttach: failed to toggle quick slot {slot} for entry {entry_id}: {e}");
        return Err(());
    }
    tx.commit().map_err(|e| {
        crate::error_log!("CopyAttach: failed to commit quick-slot toggle: {e}");
    })
}

pub(crate) fn clear_quick_slots(conn: &Connection) -> Result<(), ()> {
    conn.execute("DELETE FROM clipboard_quick_slots", [])
        .map(|_| ())
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to clear quick slots: {e}");
        })
}

pub(crate) fn import_favorites(conn: &Connection, ids: &[u64]) -> Result<usize, ()> {
    if ids.is_empty() {
        return Ok(0);
    }
    let tx = conn.unchecked_transaction().map_err(|e| {
        crate::error_log!("CopyAttach: failed to begin favorites import transaction: {e}");
    })?;
    let mut imported = 0usize;
    for &id in ids {
        match tx.execute(
            "INSERT OR IGNORE INTO clipboard_favorites (entry_id)
             SELECT entry_id FROM clipboard_history
             WHERE entry_id = ?1 AND id NOT IN (SELECT row_id FROM clipboard_deleted)",
            rusqlite::params![id as i64],
        ) {
            Ok(changed) => imported += changed,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to import favorite {id}: {e}");
                return Err(());
            }
        }
    }
    tx.commit().map_err(|e| {
        crate::error_log!("CopyAttach: failed to commit favorites import: {e}");
    })?;
    Ok(imported)
}

pub(crate) const METADATA_VERSION: i32 = 4;

pub(crate) const FTS_MAX_INDEXED_TEXT_LEN: i64 = 512 * 1024;

pub(crate) fn auto_vacuum_mode(conn: &Connection) -> Option<i64> {
    conn.query_row("PRAGMA auto_vacuum", [], |r| r.get(0)).ok()
}

pub(crate) fn freelist_pages(conn: &Connection) -> Option<i64> {
    conn.query_row("PRAGMA freelist_count", [], |r| r.get(0)).ok()
}

pub(crate) fn reclaim_free_pages(conn: &Connection, pages: i64) -> Result<i64, ()> {
    let before = freelist_pages(conn).ok_or_else(|| {
        crate::error_log!("CopyAttach: incremental vacuum could not read the freelist");
    })?;
    if before <= 0 {
        return Ok(0);
    }
    let pages = pages.clamp(1, 100_000);
    let sql = match std::ffi::CString::new(format!("PRAGMA incremental_vacuum({pages});")) {
        Ok(s) => s,
        Err(e) => {
            crate::error_log!("CopyAttach: incremental vacuum statement is invalid: {e}");
            return Err(());
        }
    };
    let rc = unsafe {
        rusqlite::ffi::sqlite3_exec(
            conn.handle(),
            sql.as_ptr(),
            None,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if rc != rusqlite::ffi::SQLITE_OK {
        crate::error_log!("CopyAttach: incremental vacuum failed with SQLite code {rc}");
        return Err(());
    }
    let after = freelist_pages(conn).ok_or_else(|| {
        crate::error_log!("CopyAttach: incremental vacuum could not re-read the freelist");
    })?;
    Ok((before - after).max(0))
}

pub(crate) fn convert_to_incremental_auto_vacuum(conn: &Connection) -> Result<(), ()> {
    if let Err(e) = conn.execute_batch(
        "PRAGMA auto_vacuum = INCREMENTAL;
         VACUUM;",
    ) {
        crate::error_log!("CopyAttach: conversion to incremental auto-vacuum failed: {e}");
        return Err(());
    }
    if let Err(e) = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);") {
        crate::error_log!("CopyAttach: checkpoint after the auto-vacuum conversion failed: {e}");
    }
    Ok(())
}

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
    conn.pragma_update(None, "user_version", 2)?;
    Ok(())
}

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

pub(crate) fn migrate_one_thumbnail_row(
    conn: &Connection, id: i64, blob: &mut Vec<u8>, scratch: &mut Vec<u8>,
) -> Result<Option<(u32, u32)>, ()> {
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
    if old_thumb_len > 0 && (want_w as i64, want_h as i64) == (old_tw, old_th) {
        return Ok(None);
    }

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

    let decoded_dims = crate::image::decode_png_rgba8_into(png, scratch).or_else(|| {
        let img = image::load_from_memory(png).ok()?;
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let raw = rgba.into_raw();
        if !crate::backend::claim_pages(raw.as_ptr(), raw.capacity())
            || !crate::backend::claim_pages(scratch.as_ptr(), scratch.capacity())
        {
            crate::error_log!("CopyAttach: thumbnail migration: decode scratch could not be claimed for row {id}");
            crate::backend::mark_pages_reusable(raw.as_ptr(), raw.capacity());
            return None;
        }
        scratch.clear();
        if scratch.capacity() < raw.len() {
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
    let (decoded_w, decoded_h) = decoded_dims.ok_or_else(|| {
        crate::debug_log!("CopyAttach: thumbnail migration: row {id} png undecodable");
    })?;
    let (thumb_data, tw, th) =
        crate::image::create_thumbnail_fast(decoded_w, decoded_h, scratch).ok_or_else(|| {
        crate::debug_log!("CopyAttach: thumbnail migration: row {id} thumbnail generation failed");
    })?;
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

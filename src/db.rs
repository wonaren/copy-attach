//! `SQLite` persistence layer — write-through DB for clipboard history.
//!
//! Schema: `clipboard_history` with columns for both text and image entries.
//! All mutations go through write-through: the monitor thread and the
//! select-and-paste path each insert, deduplicate, and trim on every capture.

use std::path::PathBuf;
use rusqlite::Connection;

use crate::types::ClipboardEntry;

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

/// Load up to `threshold` entries from the DB, newest first.
/// Image entries carry only metadata (`png_data` is empty, loaded on demand).
pub(crate) fn load_history_from_db(conn: &Connection, threshold: usize) -> Vec<ClipboardEntry> {
    let mut stmt = match conn.prepare(
        "SELECT id, entry_id, entry_type, text,
                width, height,
                thumb_width, thumb_height, hash,
                timestamp, source_name, source_bundle_id
         FROM clipboard_history
         ORDER BY id DESC
         LIMIT ?"
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("CopyAttach: failed to prepare load query: {e}");
            return Vec::new();
        }
    };

    let rows = match stmt.query_map([threshold as i64], |row| {
        let entry_type: i32 = row.get(2)?;
        let entry_id: i64 = row.get(1)?;
        Ok((entry_type,
            row.get::<_, i64>(0)?,
            entry_id,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<i64>>(5)?,
            row.get::<_, Option<i64>>(6)?,
            row.get::<_, Option<i64>>(7)?,
            row.get::<_, Option<i64>>(8)?,
            row.get::<_, i64>(9)?,
            row.get::<_, String>(10)?,
            row.get::<_, String>(11)?))
    }) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("CopyAttach: failed to query history: {e}");
            return Vec::new();
        }
    };

    let mut result = Vec::new();
    let mut skipped = 0u32;
    for row in rows {
        let (entry_type, db_id, entry_id, text, width, height,
             thumb_width, thumb_height, hash, timestamp, source_name, source_bundle_id) = match row {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: row read error at index {}: {}", result.len() + skipped as usize + 1, e);
                skipped += 1;
                continue;
            }
        };
        // Use the persisted entry_id, or assign a fresh one for legacy rows.
        let id = if entry_id != 0 { entry_id as u64 } else { crate::backend::new_entry_id() };
        match entry_type {
            0 => {
                // Full text is only needed to derive the bounded preview, label,
                // and dedup hash at load time — then it is dropped. The in-memory
                // entry never retains the body; searches and paste read the DB.
                let full_text = text.unwrap_or_default();
                result.push(ClipboardEntry::text_entry(
                    id,
                    &full_text,
                    timestamp as u64,
                    source_name,
                    source_bundle_id,
                    db_id,
                ));
            }
            1 => result.push(ClipboardEntry::Image {
                id,
                png_data: Vec::new(),
                width: width.unwrap_or(0) as u32,
                height: height.unwrap_or(0) as u32,
                thumb_data: Vec::new(),
                thumb_width: thumb_width.unwrap_or(0) as u32,
                thumb_height: thumb_height.unwrap_or(0) as u32,
                hash: hash.unwrap_or(0) as u64,
                timestamp: timestamp as u64,
                source_name,
                source_bundle_id,
                db_id,
            }),
            _ => {
                eprintln!("CopyAttach: unknown entry_type {entry_type} in DB, skipped");
                skipped += 1;
            }
        }
    }
    if skipped > 0 {
        eprintln!("CopyAttach: skipped {skipped} corrupt or unknown row(s) during history load");
    }
    result
}

/// Insert an entry into the DB. Image data (png, thumb) is provided as separate
/// slices and stored inline; the in-memory `ClipboardEntry` keeps only metadata.
/// For text entries the full body travels separately via `text` (the in-memory
/// entry does not hold it) — mirrors the image split.
pub(crate) fn insert_entry_to_db(
    conn: &Connection,
    entry: &ClipboardEntry,
    text: Option<&str>,
    image_png: Option<&[u8]>,
    image_thumb: Option<(&[u8], u32, u32)>,
) -> Result<(), ()> {
    let result = match entry {
        ClipboardEntry::Text { timestamp, source_name, source_bundle_id, id, .. } => {
            let full = match text {
                Some(t) => t,
                None => {
                    eprintln!("CopyAttach: cannot insert text entry: full text not provided");
                    return Err(());
                }
            };
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id, entry_id)
                 VALUES (0, ?1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?2, ?3, ?4, ?5)",
                rusqlite::params![full, *timestamp as i64, source_name, source_bundle_id, *id as i64],
            ).map(|_| ()).map_err(|e| { eprintln!("CopyAttach: failed to insert text entry: {e}"); })
        }
        ClipboardEntry::Image { width, height,
                                thumb_width: _, thumb_height: _, hash,
                                timestamp, source_name, source_bundle_id, id, .. } => {
            let png = if let Some(data) = image_png { data } else {
                eprintln!("CopyAttach: cannot insert image entry: missing png_data");
                return Err(());
            };
            let (thumb_data, tw, th) = if let Some(t) = image_thumb { t } else {
                eprintln!("CopyAttach: cannot insert image entry: missing thumb_data");
                return Err(());
            };
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id, entry_id)
                 VALUES (1, NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                rusqlite::params![
                    png, i64::from(*width), i64::from(*height),
                    thumb_data, i64::from(tw), i64::from(th),
                    *hash as i64, *timestamp as i64,
                    source_name, source_bundle_id,
                    *id as i64,
                ],
            ).map(|_| ()).map_err(|e| { eprintln!("CopyAttach: failed to insert image entry: {e}"); })
        }
    };
    result
}

/// Delete duplicate entries from the DB, keeping only the newest row for the
/// given entry's content. Text entries dedup by exact text (full body passed
/// separately, as the in-memory entry no longer holds it); images by hash.
pub(crate) fn delete_matching_entry(conn: &Connection, entry: &ClipboardEntry, text: Option<&str>) {
    let result = match entry {
        ClipboardEntry::Text { .. } => {
            let full = match text {
                Some(t) => t,
                None => {
                    eprintln!("CopyAttach: cannot dedup text entry: full text not provided");
                    return;
                }
            };
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 0 AND text = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 0 AND text = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![full],
            ).map(|_| ())
        }
        ClipboardEntry::Image { hash, .. } => {
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 1 AND hash = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 1 AND hash = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![*hash as i64],
            ).map(|_| ())
        }
    };
    if let Err(e) = result {
        eprintln!("CopyAttach: failed to delete matching entry: {e}");
    }
}

/// Trim the DB to at most `threshold` entries (keeps the newest rows).
pub(crate) fn trim_db_history(conn: &Connection, threshold: usize) {
    if let Err(e) = conn.execute(
        "DELETE FROM clipboard_history WHERE id NOT IN (
            SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
        rusqlite::params![threshold as i64],
    ) {
        eprintln!("CopyAttach: failed to trim DB history: {e}");
    }
}

// ═══════════════════════════════════════════
// Migration from legacy JSON
// ═══════════════════════════════════════════

#[cfg(feature = "migration")]
fn migrate_from_json_to_db_impl(conn: &mut Connection) {
    let dir = match get_persist_dir() {
        Some(d) => d,
        None => return,
    };

    let json_path = dir.join("history.json");
    if !json_path.exists() {
        return;
    }

    // Skip migration if DB already has data
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0),
    ).unwrap_or(0);
    if count > 0 {
        let _ = std::fs::rename(&json_path, dir.join("history.json.migrated"));
        return;
    }

    let content = match std::fs::read_to_string(&json_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("CopyAttach: cannot read history.json for migration: {e}");
            return;
        }
    };

    #[derive(serde::Deserialize)]
    struct LegacyText {
        text: String,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        source_name: String,
        #[serde(default)]
        source_bundle_id: String,
    }

    #[derive(serde::Deserialize)]
    struct LegacyImage {
        #[serde(default, deserialize_with = "decode_base64")]
        png_data: Vec<u8>,
        #[serde(default)]
        width: u32,
        #[serde(default)]
        height: u32,
        #[serde(default, deserialize_with = "decode_base64")]
        thumb_data: Vec<u8>,
        #[serde(default)]
        thumb_width: u32,
        #[serde(default)]
        thumb_height: u32,
        #[serde(default)]
        hash: u64,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        source_name: String,
        #[serde(default)]
        source_bundle_id: String,
    }

    fn decode_base64<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = <String as serde::Deserialize>::deserialize(d)?;
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.decode(&s)
            .map_err(serde::de::Error::custom)
    }

    #[derive(serde::Deserialize)]
    enum LegacyEntry {
        Text(LegacyText),
        Image(LegacyImage),
    }

    let entries: Vec<LegacyEntry> = match serde_json::from_str(&content) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("CopyAttach: failed to parse history.json: {e}");
            return;
        }
    };

    // Insert oldest-first so autoincrement IDs increase with age
    let tx = match conn.transaction() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("CopyAttach: failed to begin migration transaction: {e}");
            return;
        }
    };
    for entry in entries.iter().rev() {
        let result = match entry {
            LegacyEntry::Text(lt) => {
                tx.execute(
                    "INSERT INTO clipboard_history (entry_type, text, timestamp, source_name, source_bundle_id)
                     VALUES (0, ?1, ?2, ?3, ?4)",
                    rusqlite::params![lt.text, lt.timestamp as i64, lt.source_name, lt.source_bundle_id],
                )
            }
            LegacyEntry::Image(li) => {
                tx.execute(
                    "INSERT INTO clipboard_history (entry_type, png_data, width, height, thumb_data, thumb_width, thumb_height, hash, timestamp, source_name, source_bundle_id)
                     VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    rusqlite::params![
                        li.png_data, i64::from(li.width), i64::from(li.height),
                        li.thumb_data, i64::from(li.thumb_width), i64::from(li.thumb_height),
                        li.hash as i64, li.timestamp as i64,
                        li.source_name, li.source_bundle_id,
                    ],
                )
            }
        };
        if let Err(e) = result {
            eprintln!("CopyAttach: migration insert error: {e}");
            return;
        }
    }
    if let Err(e) = tx.commit() {
        eprintln!("CopyAttach: failed to commit migration: {e}");
        return;
    }

    let _ = std::fs::rename(&json_path, dir.join("history.json.migrated"));
    let _ = std::fs::remove_file(dir.join("history.json.tmp"));
}

#[cfg(not(feature = "migration"))]
fn migrate_from_json_to_db_impl(_conn: &mut Connection) {}

/// Migrate clipboard history from legacy `history.json` to the `SQLite` database.
/// No-op if the `migration` feature is disabled or no JSON file is present.
pub(crate) fn migrate_from_json_to_db(conn: &mut Connection) {
    migrate_from_json_to_db_impl(conn);
}

// ═══════════════════════════════════════════
// Full-text search & on-demand text loading
// ═══════════════════════════════════════════

/// Case-insensitive substring search over the stored full text.
///
/// Queries of ≥3 Unicode scalars go through the FTS5 trigram index (substring
/// semantics, full-Unicode case folding). Shorter queries cannot form a
/// trigram, so they fall back to a LIKE scan — trigram's matching floor, not a
/// failure path. Known limitation of that fallback: SQLite's LIKE folds ASCII
/// case only, so a <3-char query that relies on non-ASCII case folding (e.g.
/// `é` matching `É`, Greek case) misses those variants; ≥3-char queries are
/// unaffected (trigram folds Unicode). Returns matching entry_ids (the stable
/// Rust IDs, not SQLite rowids).
pub(crate) fn search_history(conn: &Connection, query: &str) -> Vec<u64> {
    let mut ids = Vec::new();
    if query.chars().count() >= 3 {
        let phrase = fts_phrase(query);
        let mut stmt = match conn.prepare(
            "SELECT clipboard_history.entry_id
             FROM clipboard_fts
             JOIN clipboard_history ON clipboard_history.id = clipboard_fts.rowid
             WHERE clipboard_fts MATCH ?1",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("CopyAttach: failed to prepare FTS search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![phrase], |row| row.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: FTS search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => eprintln!("CopyAttach: FTS search row read error: {e}"),
            }
        }
    } else {
        let like = format!("%{}%", escape_like(query));
        let mut stmt = match conn.prepare(
            "SELECT entry_id FROM clipboard_history
             WHERE entry_type = 0 AND text LIKE ?1 ESCAPE '\\'",
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("CopyAttach: failed to prepare LIKE search: {e}");
                return ids;
            }
        };
        let rows = match stmt.query_map(rusqlite::params![like], |row| row.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: LIKE search failed: {e}");
                return ids;
            }
        };
        for row in rows {
            match row {
                Ok(id) => ids.push(id as u64),
                Err(e) => eprintln!("CopyAttach: LIKE search row read error: {e}"),
            }
        }
    }
    ids
}

/// Wrap a user query as an FTS5 phrase, doubling embedded quotes so arbitrary
/// input (including `*`, `-`, parens, quotes) is matched literally.
fn fts_phrase(query: &str) -> String {
    format!("\"{}\"", query.replace('"', "\"\""))
}

/// Escape `%`/`_`/`\` so a LIKE pattern matches the query literally, mirroring
/// the substring semantics of the FTS path (and the pre-index `contains`).
fn escape_like(query: &str) -> String {
    query
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// Load the full text body for a row by its SQLite rowid (== `db_id`).
pub(crate) fn load_text_by_db_id(conn: &Connection, db_id: i64) -> Option<String> {
    conn.query_row(
        "SELECT text FROM clipboard_history WHERE id = ?1",
        rusqlite::params![db_id],
        |row| row.get(0),
    )
    .map_err(|e| eprintln!("CopyAttach: failed to load text for db_id={db_id}: {e}"))
    .ok()
}

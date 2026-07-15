//! SQLite persistence layer — write-through DB for clipboard history.
//!
//! Schema: `clipboard_history` with columns for both text and image entries.
//! All mutations go through write-through: the monitor thread and the
//! select-and-paste path each insert, deduplicate, and trim on every capture.

use std::path::PathBuf;
use rusqlite::Connection;

use crate::types::ClipboardEntry;
use crate::backend::DEFAULT_CLEANUP_THRESHOLD;

/// Resolve the storage directory under `~/Library/Application Support/CopyAttach`.
pub(crate) fn get_persist_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Open (or create) the SQLite database with mmap and a small page cache.
pub(crate) fn open_db() -> Option<Connection> {
    let db_path = get_persist_dir()?.join("history.db");
    let conn = Connection::open(&db_path).map_err(|e| {
        eprintln!("CopyAttach: failed to open database: {}", e);
    }).ok()?;
    // Use mmap for BLOB reads + minimal SQLite page cache (512KB)
    let _ = conn.execute_batch(
        "PRAGMA mmap_size = 33554432;    -- 32 MB (ample for clipboard history, was 256 MB)
         PRAGMA cache_size = -512;"
    );
    Some(conn)
}

/// Create the history table if it does not already exist.
pub(crate) fn ensure_history_table(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
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
    )
}

/// Load up to `DEFAULT_CLEANUP_THRESHOLD` entries from the DB, newest first.
/// Image entries carry only metadata (png_data is empty, loaded on demand).
pub(crate) fn load_history_from_db(conn: &Connection) -> Vec<ClipboardEntry> {
    let mut stmt = match conn.prepare(
        "SELECT id, entry_type, text,
                width, height,
                thumb_data, thumb_width, thumb_height, hash,
                timestamp, source_name, source_bundle_id
         FROM clipboard_history
         ORDER BY id DESC
         LIMIT ?"
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("CopyAttach: failed to prepare load query: {}", e);
            return Vec::new();
        }
    };

    let rows = match stmt.query_map([DEFAULT_CLEANUP_THRESHOLD as i64], |row| {
        let entry_type: i32 = row.get(1)?;
        Ok((entry_type,
            row.get::<_, i64>(0)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<i64>>(3)?,
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<Vec<u8>>>(5)?,
            row.get::<_, Option<i64>>(6)?,
            row.get::<_, Option<i64>>(7)?,
            row.get::<_, Option<i64>>(8)?,
            row.get::<_, i64>(9)?,
            row.get::<_, String>(10)?,
            row.get::<_, String>(11)?))
    }) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("CopyAttach: failed to query history: {}", e);
            return Vec::new();
        }
    };

    let mut result = Vec::new();
    let mut skipped = 0u32;
    for row in rows {
        let (entry_type, db_id, text, width, height, _thumb_data,
             thumb_width, thumb_height, hash, timestamp, source_name, source_bundle_id) = match row {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: row read error at index {}: {}", result.len() + skipped as usize + 1, e);
                skipped += 1;
                continue;
            }
        };
        match entry_type {
            0 => result.push(ClipboardEntry::Text {
                id: crate::backend::new_entry_id(),
                text: text.unwrap_or_default(),
                timestamp: timestamp as u64,
                source_name,
                source_bundle_id,
                db_id,
            }),
            1 => result.push(ClipboardEntry::Image {
                id: crate::backend::new_entry_id(),
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
                eprintln!("CopyAttach: unknown entry_type {} in DB, skipped", entry_type);
                skipped += 1;
            }
        }
    }
    if skipped > 0 {
        eprintln!("CopyAttach: skipped {} corrupt or unknown row(s) during history load", skipped);
    }
    result
}

/// Insert an entry into the DB. Image data (png, thumb) is provided as separate
/// slices and stored inline; the in-memory `ClipboardEntry` keeps only metadata.
pub(crate) fn insert_entry_to_db(
    conn: &Connection,
    entry: &ClipboardEntry,
    image_png: Option<&[u8]>,
    image_thumb: Option<(&[u8], u32, u32)>,
) {
    let result = match entry {
        ClipboardEntry::Text { text, timestamp, source_name, source_bundle_id, .. } => {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id)
                 VALUES (0, ?1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?2, ?3, ?4)",
                rusqlite::params![text, *timestamp as i64, source_name, source_bundle_id],
            ).map(|_| ())
        }
        ClipboardEntry::Image { width, height,
                                thumb_width: _, thumb_height: _, hash,
                                timestamp, source_name, source_bundle_id, .. } => {
            let png = match image_png {
                Some(data) => data,
                None => return,
            };
            let (thumb_data, tw, th) = match image_thumb {
                Some(t) => t,
                None => return,
            };
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id)
                 VALUES (1, NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                rusqlite::params![
                    png, *width as i64, *height as i64,
                    thumb_data, tw as i64, th as i64,
                    *hash as i64, *timestamp as i64,
                    source_name, source_bundle_id,
                ],
            ).map(|_| ())
        }
    };
    if let Err(e) = result {
        eprintln!("CopyAttach: failed to insert entry: {}", e);
    }
}

/// Delete duplicate entries from the DB, keeping only the newest row for the
/// given entry's content (text match or hash match).
pub(crate) fn delete_matching_entry(conn: &Connection, entry: &ClipboardEntry) {
    let result = match entry {
        ClipboardEntry::Text { text, .. } => {
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 0 AND text = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 0 AND text = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![text],
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
        eprintln!("CopyAttach: failed to delete matching entry: {}", e);
    }
}

/// Trim the DB to at most `threshold` entries (keeps the newest rows).
pub(crate) fn trim_db_history(conn: &Connection, threshold: usize) {
    if let Err(e) = conn.execute(
        "DELETE FROM clipboard_history WHERE id NOT IN (
            SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
        rusqlite::params![threshold as i64],
    ) {
        eprintln!("CopyAttach: failed to trim DB history: {}", e);
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
            eprintln!("CopyAttach: cannot read history.json for migration: {}", e);
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
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &s)
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
            eprintln!("CopyAttach: failed to parse history.json: {}", e);
            return;
        }
    };

    // Insert oldest-first so autoincrement IDs increase with age
    let tx = match conn.transaction() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("CopyAttach: failed to begin migration transaction: {}", e);
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
                        li.png_data, li.width as i64, li.height as i64,
                        li.thumb_data, li.thumb_width as i64, li.thumb_height as i64,
                        li.hash as i64, li.timestamp as i64,
                        li.source_name, li.source_bundle_id,
                    ],
                )
            }
        };
        if let Err(e) = result {
            eprintln!("CopyAttach: migration insert error: {}", e);
            return;
        }
    }
    if let Err(e) = tx.commit() {
        eprintln!("CopyAttach: failed to commit migration: {}", e);
        return;
    }

    let _ = std::fs::rename(&json_path, dir.join("history.json.migrated"));
    let _ = std::fs::remove_file(dir.join("history.json.tmp"));
}

#[cfg(not(feature = "migration"))]
fn migrate_from_json_to_db_impl(_conn: &mut Connection) {}

/// Migrate clipboard history from legacy `history.json` to the SQLite database.
/// No-op if the `migration` feature is disabled or no JSON file is present.
pub(crate) fn migrate_from_json_to_db(conn: &mut Connection) {
    migrate_from_json_to_db_impl(conn)
}

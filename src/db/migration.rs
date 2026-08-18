// Migration of clipboard history from legacy `history.json` to `SQLite`.
// Feature-gated on `migration` (default on).

#[cfg(feature = "migration")]
use std::path::Path;
use rusqlite::Connection;

/// Core migration body, parameterized by the storage directory so tests can
/// point it at a temp dir. Feature-gated with `migration`.
#[cfg(feature = "migration")]
pub(crate) fn migrate_from_json_to_db_at(conn: &mut Connection, dir: &Path) {
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
            crate::error_log!("CopyAttach: cannot read history.json for migration: {e}");
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
            crate::error_log!("CopyAttach: failed to parse history.json: {e}");
            return;
        }
    };

    // Insert oldest-first so autoincrement IDs increase with age
    let tx = match conn.transaction() {
        Ok(t) => t,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to begin migration transaction: {e}");
            return;
        }
    };
    for entry in entries.iter().rev() {
        let result = match entry {
            LegacyEntry::Text(lt) => {
                // Persist the same derived metadata (hash/preview/label) the
                // modern insert path stores: the metadata backfill in
                // ensure_history_table ran BEFORE migration (the table must
                // exist first), so rows written here would otherwise be
                // skipped by the cold-start load as "never backfilled".
                //
                // entry_id is stamped per-row right after the insert, because
                // the ensure_history_table entry_id backfill has already run
                // by the time migration executes — a migrated row left at the
                // default 0 would get a FRESH id on every load (favorites are
                // keyed by entry_id and would break on each restart).
                tx.execute(
                    "INSERT INTO clipboard_history
                        (entry_type, text, timestamp, source_name, source_bundle_id,
                         hash, preview, label)
                     VALUES (0, ?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    rusqlite::params![
                        lt.text, lt.timestamp as i64, lt.source_name, lt.source_bundle_id,
                        crate::types::text_hash(&lt.text) as i64,
                        crate::types::bounded_preview(&lt.text),
                        crate::types::label_from_text(&lt.text),
                    ],
                )
                .and_then(|_| tx.execute(
                    "UPDATE clipboard_history SET entry_id = id WHERE id = last_insert_rowid()",
                    [],
                ))
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
                .and_then(|_| tx.execute(
                    "UPDATE clipboard_history SET entry_id = id WHERE id = last_insert_rowid()",
                    [],
                ))
            }
        };
        if let Err(e) = result {
            crate::error_log!("CopyAttach: migration insert error: {e}");
            return;
        }
    }
    if let Err(e) = tx.commit() {
        crate::error_log!("CopyAttach: failed to commit migration: {e}");
        return;
    }

    let _ = std::fs::rename(&json_path, dir.join("history.json.migrated"));
    let _ = std::fs::remove_file(dir.join("history.json.tmp"));
}

/// Migrate clipboard history from legacy `history.json` to the `SQLite` database.
/// No-op if the `migration` feature is disabled or no JSON file is present.
pub(crate) fn migrate_from_json_to_db(conn: &mut Connection) {
    #[cfg(feature = "migration")]
    {
        let dir = match super::get_persist_dir() {
            Some(d) => d,
            None => return,
        };
        migrate_from_json_to_db_at(conn, &dir);
    }
    #[cfg(not(feature = "migration"))]
    let _ = conn;
}

// Migration of clipboard history from legacy `history.json` to `SQLite`.
// Feature-gated on `migration` (default on).

use rusqlite::Connection;

#[cfg(feature = "migration")]
fn migrate_from_json_to_db_impl(conn: &mut Connection) {
    let dir = match super::get_persist_dir() {
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

use rusqlite::Connection;

use crate::types::ClipboardEntry;

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

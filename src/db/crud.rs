use rusqlite::Connection;

use crate::types::ClipboardEntry;

/// One-time onboarding rows shown the very first time the app opens with an
/// empty database. Each tip is a normal text entry, so it renders, pastes, and
/// searches exactly like any real capture — but its source is CopyAttach
/// itself, which makes the row show the app's own icon (Swift resolves the
/// source icon by `source_bundle_id` through NSWorkspace).
///
/// Guarded on the table being empty before any real capture: a fresh install
/// has no rows and gets the tips; once anything is captured (or a legacy JSON
/// migration lands) the table is non-empty and seeding is a no-op forever. The
/// first tip is written last so it gets the newest rowid and sits at the top
/// of the newest-first list; timestamps are staggered for realism.
pub(crate) fn seed_first_launch_tips(conn: &Connection) {
    const TIPS: &[&str] = &[
        "欢迎使用 CopyAttach !",
        "1. 打开：按 ⌥X 打开或关闭剪贴板，打字即搜索",
        "2. 粘贴：按回车或点击条目，直接粘贴到应用",
        "3. 预览：按空格预览大图与文本，按 Esc 退出",
        "4. 搜索：直接输入关键词实时过滤，支持全文",
        "5. 标签页：按 ← → 或双指横滑切换不同分类",
        "6. 收藏：按 ⌥P 收藏常用条目，重启不丢失",
        "7. 删除与撤销：按 ⌃⌫ 删除，按 ⌘Z 撤销恢复",
        "8. 右键菜单：右键条目弹出菜单，支持另存与复制",
        "9. 拖拽：直接拖拽条目到其他应用，自动避让",
    ];

    let count: i64 = match conn.query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0)) {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to check history count for first-launch seeding: {e}");
            return;
        }
    };
    if count > 0 {
        return; // Existing user (or migrated history) — never re-seed.
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let tx = match conn.unchecked_transaction() {
        Ok(tx) => tx,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to begin first-launch seeding transaction: {e}");
            return;
        }
    };

    // Insert in reverse display order so the first tip (intended to be read
    // first) gets the newest rowid and tops the newest-first history.
    for (i, tip) in TIPS.iter().enumerate().rev() {
        let full = tip.to_string();
        // db_id = 0 here is fine: these rows are reloaded from the DB on
        // launch (load assigns the real rowid), the in-memory entry is never
        // used for paste-by-id before that.
        let entry = ClipboardEntry::text_entry(
            crate::backend::new_entry_id(),
            &full,
            now - i as u64,
            "CopyAttach".to_string(),
            "com.example.copyattach".to_string(),
            0,
        );
        if insert_entry_to_db(&tx, &entry, Some(&full), None, None).is_err() {
            crate::error_log!("CopyAttach: failed to seed first-launch tip");
            return;
        }
    }

    if let Err(e) = tx.commit() {
        crate::error_log!("CopyAttach: failed to commit first-launch seeding: {e}");
        return;
    }
    crate::debug_log!(
        "CopyAttach: seeded {} first-launch usage tips (source: CopyAttach)",
        TIPS.len()
    );
}

/// Load up to `threshold` entries from the DB, newest first.
///
/// Only metadata is read: the full `text` column is never touched at load.
/// Preview/label/text-hash were persisted at insert time (and backfilled for
/// legacy rows by `ensure_history_table`), so a cold start reads a bounded,
/// per-row payload no matter how large the stored documents are. Image entries
/// carry only metadata (`png_data` is empty, loaded on demand).
pub(crate) fn load_history_from_db(conn: &Connection, threshold: usize) -> Vec<ClipboardEntry> {
    let mut stmt = match conn.prepare(
        "SELECT id, entry_id, entry_type, preview, label, hash,
                width, height,
                thumb_width, thumb_height,
                timestamp, source_name, source_bundle_id,
                custom_label
         FROM clipboard_history
         ORDER BY id DESC
         LIMIT ?"
    ) {
        Ok(s) => s,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to prepare load query: {e}");
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
            row.get::<_, String>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, Option<i64>>(6)?,
            row.get::<_, Option<i64>>(7)?,
            row.get::<_, Option<i64>>(8)?,
            row.get::<_, Option<i64>>(9)?,
            row.get::<_, i64>(10)?,
            row.get::<_, String>(11)?,
            row.get::<_, String>(12)?,
            row.get::<_, String>(13)?))
    }) {
        Ok(r) => r,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to query history: {e}");
            return Vec::new();
        }
    };

    let mut result = Vec::new();
    let mut skipped = 0u32;
    for row in rows {
        let (entry_type, db_id, entry_id, preview, label, hash,
             width, height,
             thumb_width, thumb_height,
             timestamp, source_name, source_bundle_id,
             custom_label) = match row {
            Ok(r) => r,
            Err(e) => {
                crate::error_log!("CopyAttach: row read error at index {}: {}", result.len() + skipped as usize + 1, e);
                skipped += 1;
                continue;
            }
        };
        // Use the persisted entry_id, or assign a fresh one for legacy rows.
        let id = if entry_id != 0 { entry_id as u64 } else { crate::backend::new_entry_id() };
        match entry_type {
            0 => {
                // Text metadata must be persisted (backfill ran at schema
                // ensure). An empty preview means the row was written before
                // the metadata backfill and never got it — reading its full
                // text here would silently reintroduce the cold-start cost we
                // removed, so fail loud instead: the row is skipped and
                // reported, not transparently recovered.
                let preview = preview.unwrap_or_default();
                if preview.is_empty() {
                    crate::debug_log!("CopyAttach: text row {db_id} has no persisted preview — skipped");
                    skipped += 1;
                    continue;
                }
                result.push(ClipboardEntry::Text {
                    id,
                    preview,
                    label,
                    custom_label,
                    text_hash: hash as u64,
                    timestamp: timestamp as u64,
                    source_name,
                    source_bundle_id,
                    db_id,
                });
            }
            1 => result.push(ClipboardEntry::Image {
                id,
                width: width.unwrap_or(0) as u32,
                height: height.unwrap_or(0) as u32,
                thumb_width: thumb_width.unwrap_or(0) as u32,
                thumb_height: thumb_height.unwrap_or(0) as u32,
                hash: hash as u64,
                custom_label,
                timestamp: timestamp as u64,
                source_name,
                source_bundle_id,
                db_id,
            }),
            _ => {
                crate::error_log!("CopyAttach: unknown entry_type {entry_type} in DB, skipped");
                skipped += 1;
            }
        }
    }
    if skipped > 0 {
        crate::debug_log!("CopyAttach: skipped {skipped} corrupt or unknown row(s) during history load");
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
        ClipboardEntry::Text { timestamp, source_name, source_bundle_id, id, preview, label, custom_label, text_hash, .. } => {
            let full = match text {
                Some(t) => t,
                None => {
                    crate::error_log!("CopyAttach: cannot insert text entry: full text not provided");
                    return Err(());
                }
            };
            // Preview/label/custom_label/text-hash are persisted alongside the body so the
            // cold-start load never reads the full `text` column. The hash
            // column doubles as the text dedup hash (image rows store the
            // content hash there).
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id, entry_id,
                     preview, label, custom_label)
                 VALUES (0, ?1, NULL, NULL, NULL, NULL, NULL, NULL, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    full, *text_hash as i64, *timestamp as i64,
                    source_name, source_bundle_id, *id as i64,
                    preview, label, custom_label,
                ],
            ).map(|_| ()).map_err(|e| { crate::error_log!("CopyAttach: failed to insert text entry: {e}"); })
        }
        ClipboardEntry::Image { width, height,
                                thumb_width: _, thumb_height: _, hash,
                                custom_label,
                                timestamp, source_name, source_bundle_id, id, .. } => {
            let png = if let Some(data) = image_png { data } else {
                crate::error_log!("CopyAttach: cannot insert image entry: missing png_data");
                return Err(());
            };
            let (thumb_data, tw, th) = if let Some(t) = image_thumb { t } else {
                crate::error_log!("CopyAttach: cannot insert image entry: missing thumb_data");
                return Err(());
            };
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id, entry_id,
                     custom_label)
                 VALUES (1, NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                rusqlite::params![
                    png, i64::from(*width), i64::from(*height),
                    thumb_data, i64::from(tw), i64::from(th),
                    *hash as i64, *timestamp as i64,
                    source_name, source_bundle_id,
                    *id as i64,
                    custom_label,
                ],
            ).map(|_| ()).map_err(|e| { crate::error_log!("CopyAttach: failed to insert image entry: {e}"); })
        }
    };
    result
}

/// Delete duplicate entries from the DB, keeping only the newest row for the
/// given entry's content. Text entries dedup by exact text (full body passed
/// separately, as the in-memory entry no longer holds it); images by hash.
///
/// Both lookups narrow through the `(entry_type, hash)` index: the hash
/// selects candidate rows, and for text the exact-text predicate still
/// enforces full equality (a 2^-64 hash collision can at worst miss a dedup,
/// never delete a different text's row).
pub(crate) fn delete_matching_entry(conn: &Connection, entry: &ClipboardEntry, text: Option<&str>) {
    let result = match entry {
        ClipboardEntry::Text { text_hash, .. } => {
            let full = match text {
                Some(t) => t,
                None => {
                    crate::error_log!("CopyAttach: cannot dedup text entry: full text not provided");
                    return;
                }
            };
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 0 AND hash = ?1 AND text = ?2
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 0 AND hash = ?1 AND text = ?2
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![*text_hash as i64, full],
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
        crate::error_log!("CopyAttach: failed to delete matching entry: {e}");
    }
}

/// Trim the DB to at most `threshold` entries (keeps the newest rows).
///
/// Range deletion, not a full scan: the subquery walks `threshold + 1` rows in
/// rowid order to find the cutoff id, then the DELETE touches only the rows
/// older than that cutoff. When the table holds ≤ threshold rows the subquery
/// yields NULL and nothing is visited at all — the previous `id NOT IN
/// (SELECT ...)` form scanned every record on every capture.
pub(crate) fn trim_db_history(conn: &Connection, threshold: usize) {
    if let Err(e) = conn.execute(
        "DELETE FROM clipboard_history
         WHERE id <= (SELECT id FROM clipboard_history
                      ORDER BY id DESC LIMIT 1 OFFSET ?)",
        rusqlite::params![threshold as i64],
    ) {
        crate::error_log!("CopyAttach: failed to trim DB history: {e}");
    }
}

/// The capture/paste write-through as ONE transaction: insert + dedup delete +
/// trim commit together. With WAL + `synchronous=NORMAL` this is a single WAL
/// append and one fsync, where the previous three autocommit statements each
/// paid a full journal sync. Returns the new row id on success; on any failure
/// the transaction rolls back and nothing is committed.
pub(crate) fn persist_entry_to_db(
    conn: &mut Connection,
    entry: &ClipboardEntry,
    text: Option<&str>,
    image_png: Option<&[u8]>,
    image_thumb: Option<(&[u8], u32, u32)>,
    threshold: usize,
) -> Result<i64, ()> {
    let perf = crate::perf::PerfSpan::start("rust", "db.write");
    // `unchecked_transaction` skips the BEGIN round-trip: the first write
    // statement opens the implicit transaction and `commit` closes it.
    let tx = conn.unchecked_transaction().map_err(|e| {
        crate::error_log!("CopyAttach: failed to begin write transaction: {e}");
    })?;
    insert_entry_to_db(&tx, entry, text, image_png, image_thumb)?;
    delete_matching_entry(&tx, entry, text);
    trim_db_history(&tx, threshold);
    let row_id = tx.last_insert_rowid();
    tx.commit().map_err(|e| {
        crate::error_log!("CopyAttach: failed to commit write transaction: {e}");
    })?;
    if let Some(mut span) = perf {
        span.data = Some(match entry {
            ClipboardEntry::Text { .. } => "text".to_string(),
            ClipboardEntry::Image { .. } => "image".to_string(),
        });
    }
    Ok(row_id)
}

/// Update the custom label / remark for an entry by its stable `entry_id`.
///
/// A zero-row update is a failure, not a success: the caller's in-memory entry
/// and its DB row are required to agree, so silently "succeeding" against a
/// missing row would leave the remark memory-only and lose it on restart.
pub(crate) fn update_entry_custom_label(
    conn: &Connection,
    entry_id: u64,
    custom_label: &str,
) -> Result<(), ()> {
    let changed = conn
        .execute(
            "UPDATE clipboard_history SET custom_label = ?1 WHERE entry_id = ?2",
            rusqlite::params![custom_label, entry_id as i64],
        )
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to update custom_label for entry {entry_id}: {e}");
        })?;
    if changed == 0 {
        crate::error_log!(
            "CopyAttach: custom_label update matched no row for entry {entry_id} (DB/memory out of sync)"
        );
        return Err(());
    }
    Ok(())
}

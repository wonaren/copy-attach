use rusqlite::Connection;

use crate::db::schema::bump_entry_id_watermark;
use crate::types::ClipboardEntry;

pub(crate) fn seed_first_launch_tips(conn: &Connection) {
    const TIPS: &[&str] = &[
        "欢迎使用 CopyAttach !",
        "1. 打开：按 ⌥Space 打开或关闭剪贴板，打字即搜索",
        "2. 粘贴：按回车或点击条目，直接粘贴到应用",
        "3. 预览：按空格预览大图与文本，按 Esc 退出",
        "4. 搜索：直接输入关键词实时过滤，支持全文",
        "5. 标签页：按 ← → 或双指横滑切换不同分类",
        "6. 收藏：按 ⌥P 收藏常用条目，自动清理时会保留",
        "7. 删除与撤销：按 ⌃⌫ 删除，按 ⌘Z 撤销恢复",
        "8. 右键菜单：右键条目弹出菜单，支持另存与复制",
        "9. 拖拽：直接拖拽条目到其他应用，自动避让",
    ];

    let count: i64 = match conn.query_row(
        "SELECT COUNT(*) FROM clipboard_history h
         WHERE NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id = h.id)",
        [],
        |r| r.get(0),
    ) {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to check history count for first-launch seeding: {e}");
            return;
        }
    };
    if count > 0 {
        return;
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

    for (i, tip) in TIPS.iter().enumerate().rev() {
        let full = tip.to_string();
        let entry = ClipboardEntry::text_entry(
            crate::backend::new_entry_id(),
            &full,
            now - i as u64,
            "CopyAttach".to_string(),
            "cc.wonaren.copyattach".to_string(),
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

const ORDER_NEWEST_FIRST: &str = "ORDER BY timestamp DESC, id DESC";

pub(crate) fn load_history_from_db(conn: &Connection, threshold: usize) -> Vec<ClipboardEntry> {
    let mut stmt = match conn.prepare(
        &format!(
            "SELECT id, entry_id, entry_type, preview, label, hash,
                    width, height,
                    thumb_width, thumb_height,
                    timestamp, source_name, source_bundle_id,
                    custom_label
             FROM clipboard_history
             -- One live-row filter for the whole statement. `clipboard_favorites`
             -- only ever references live rows (a delete drops the favorite, and
             -- `prune_orphan_favorites` sweeps leftovers), so the favorites half
             -- needs no filter of its own: this outer one already excludes a
             -- soft-deleted row that a stale favorite id might name.
             WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
               AND (id IN (SELECT id FROM clipboard_history
                           WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                             AND entry_id NOT IN (SELECT entry_id FROM clipboard_favorites)
                           {ORDER_NEWEST_FIRST} LIMIT ?1)
                   OR entry_id IN (SELECT entry_id FROM clipboard_favorites))
             {ORDER_NEWEST_FIRST}"
        )
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
        let id = if entry_id != 0 { entry_id as u64 } else { crate::backend::new_entry_id() };
        match entry_type {
            0 => {
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
    if result.is_ok() && bump_entry_id_watermark(conn, entry.entry_id()).is_err() {
        crate::error_log!("CopyAttach: entry-id watermark not raised after insert; ids stay unique only while rows survive");
    }
    result
}

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
            collect_live_rows_with_content(conn, TEXT_DEDUP_SQL, rusqlite::params![*text_hash as i64, full])
        }
        ClipboardEntry::Image { hash, .. } => {
            collect_live_rows_with_content(conn, IMAGE_DEDUP_SQL, rusqlite::params![*hash as i64])
        }
    };
    match result {
        Ok(rows) => {
            if let Err(e) = keep_newest_row(conn, &rows) {
                crate::error_log!("CopyAttach: failed to delete matching entry: {e}");
            }
        }
        Err(e) => crate::error_log!("CopyAttach: failed to delete matching entry: {e}"),
    }
}

const TEXT_DEDUP_SQL: &str =
    "SELECT id, entry_id FROM clipboard_history
     WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
       AND entry_type = 0 AND hash = ?1 AND text = ?2
     ORDER BY id DESC";

const IMAGE_DEDUP_SQL: &str =
    "SELECT id, entry_id FROM clipboard_history
     WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
       AND entry_type = 1 AND hash = ?1
     ORDER BY id DESC";

fn collect_live_rows_with_content(
    conn: &Connection,
    sql: &str,
    params: impl rusqlite::Params,
) -> Result<Vec<(i64, i64)>, rusqlite::Error> {
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params, |r| Ok((r.get(0)?, r.get(1)?)))?;
    rows.collect()
}

fn keep_newest_row(conn: &Connection, rows: &[(i64, i64)]) -> Result<(), rusqlite::Error> {
    let Some(&(_, survivor_entry_id)) = rows.first() else {
        return Ok(());
    };
    for &(row_id, entry_id) in &rows[1..] {
        if entry_id != survivor_entry_id
            && conn.query_row(
                "SELECT COUNT(*) FROM clipboard_favorites WHERE entry_id = ?1",
                rusqlite::params![entry_id],
                |r| r.get::<_, i64>(0),
            )?
                > 0
        {
            conn.execute(
                "INSERT OR IGNORE INTO clipboard_favorites (entry_id) VALUES (?1)",
                rusqlite::params![survivor_entry_id],
            )?;
            conn.execute(
                "DELETE FROM clipboard_favorites WHERE entry_id = ?1",
                rusqlite::params![entry_id],
            )?;
        }
        conn.execute(
            "DELETE FROM clipboard_history WHERE id = ?1",
            rusqlite::params![row_id],
        )?;
    }
    Ok(())
}

pub(crate) fn trim_db_history(conn: &Connection, threshold: usize) -> Result<(), ()> {
    let sql = "DELETE FROM clipboard_history
               WHERE id IN (SELECT id FROM clipboard_history
                            WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                              AND entry_id NOT IN (SELECT entry_id FROM clipboard_favorites)
                            ORDER BY timestamp ASC, id ASC
                            LIMIT (SELECT MAX(0,
                                     (SELECT COUNT(*) FROM clipboard_history
                                       WHERE id NOT IN (SELECT row_id FROM clipboard_deleted))
                                     - (SELECT COUNT(*) FROM clipboard_favorites)
                                     - ?1)))";
    if let Err(e) = conn.execute(sql, rusqlite::params![threshold as i64]) {
        crate::error_log!("CopyAttach: failed to trim DB history: {e}");
        return Err(());
    }
    Ok(())
}

pub(crate) fn soft_delete_row(conn: &Connection, db_id: i64) -> Result<u64, ()> {
    let stamp = crate::backend::undo_stamp_now();
    let (entry_id, was_favorite) = match conn.query_row(
        "SELECT h.entry_id,
                (SELECT COUNT(*) FROM clipboard_favorites f WHERE f.entry_id = h.entry_id)
         FROM clipboard_history h
         WHERE h.id = ?1
           AND NOT EXISTS (SELECT 1 FROM clipboard_deleted d WHERE d.row_id = h.id)",
        rusqlite::params![db_id],
        |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
    ) {
        Ok(v) => v,
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            crate::error_log!("CopyAttach: soft-delete matched no live row for db_id={db_id}");
            return Err(());
        }
        Err(e) => {
            crate::error_log!("CopyAttach: soft-delete could not read row {db_id}: {e}");
            return Err(());
        }
    };
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![db_id, entry_id, stamp, was_favorite],
    )
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to record deletion of row {db_id}: {e}");
    })?;
    Ok(entry_id as u64)
}

pub(crate) fn newest_deleted_row(
    conn: &Connection,
) -> Result<Option<(i64, u64, bool)>, ()> {
    loop {
        let candidate = match conn.query_row(
            "SELECT row_id, entry_id, was_favorite
             FROM clipboard_deleted
             ORDER BY deleted_at DESC, row_id DESC
             LIMIT 1",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        ) {
            Ok(v) => Some(v),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => {
                crate::error_log!("CopyAttach: undo could not read the deleted-row head: {e}");
                return Err(());
            }
        };
        let (row_id, entry_id, was_favorite) = match candidate {
            Some(v) => v,
            None => return Ok(None),
        };
        let payload_exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM clipboard_history WHERE id = ?1",
                rusqlite::params![row_id],
                |r| r.get(0),
            )
            .map_err(|e| {
                crate::error_log!("CopyAttach: undo could not check payload for row {row_id}: {e}");
            })?;
        if payload_exists > 0 {
            return Ok(Some((row_id, entry_id as u64, was_favorite != 0)));
        }
        crate::debug_log!("CopyAttach: dropping orphan undo entry for missing row {row_id}");
        conn.execute(
            "DELETE FROM clipboard_deleted WHERE row_id = ?1",
            rusqlite::params![row_id],
        )
        .map_err(|e| {
            crate::error_log!(
                "CopyAttach: could not drop orphan undo entry for row {row_id}: {e} — aborting instead of looping"
            );
        })?;
    }
}

pub(crate) fn undo_depth(conn: &Connection) -> Result<usize, ()> {
    count_deleted_rows(conn, None)
}

fn count_deleted_rows(conn: &Connection, cutoff_micros: Option<i64>) -> Result<usize, ()> {
    let floor = cutoff_micros.unwrap_or(i64::MIN);
    conn.query_row(
        "SELECT COUNT(*) FROM clipboard_deleted d
         JOIN clipboard_history h ON h.id = d.row_id
         WHERE d.deleted_at >= ?1",
        rusqlite::params![floor],
        |row| row.get::<_, i64>(0),
    )
    .map(|n| n.max(0) as usize)
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to count undoable deletions: {e}");
    })
}

fn collect_item_evictions(conn: &Connection, cap: usize) -> Result<Vec<i64>, ()> {
    let depth = count_deleted_rows(conn, None)?;
    if depth <= cap {
        return Ok(Vec::new());
    }
    let mut stmt = conn
        .prepare(
            "SELECT d.row_id FROM clipboard_deleted d
             JOIN clipboard_history h ON h.id = d.row_id
             ORDER BY d.deleted_at ASC, d.row_id ASC
             LIMIT ?1",
        )
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to prepare the undo item sweep: {e}");
        })?;
    let doomed = stmt
        .query_map(rusqlite::params![(depth - cap) as i64], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to read the undo item sweep: {e}");
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to collect the undo item sweep: {e}");
        })?;
    Ok(doomed)
}

const ROW_PAYLOAD_BYTES: &str =
    "COALESCE(LENGTH(CAST(h.text AS BLOB)), 0) + COALESCE(LENGTH(h.png_data), 0) + COALESCE(LENGTH(h.thumb_data), 0)";

fn retained_deleted_payload_bytes(
    conn: &Connection,
    cutoff_micros: Option<i64>,
) -> Result<i64, ()> {
    let sql = format!(
        "SELECT COALESCE(SUM({ROW_PAYLOAD_BYTES}), 0)
         FROM clipboard_deleted d
         JOIN clipboard_history h ON h.id = d.row_id
         WHERE d.deleted_at >= ?1"
    );
    let floor = cutoff_micros.unwrap_or(i64::MIN);
    conn.query_row(&sql, rusqlite::params![floor], |row| row.get::<_, i64>(0))
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to size the retained deleted payload: {e}");
        })
}

fn collect_evictions(
    conn: &Connection,
    excess: i64,
    cutoff_micros: Option<i64>,
) -> Result<Vec<i64>, ()> {
    if excess <= 0 {
        return Ok(Vec::new());
    }
    let sql = format!(
        "SELECT d.row_id, {ROW_PAYLOAD_BYTES}
         FROM clipboard_deleted d
         JOIN clipboard_history h ON h.id = d.row_id
         WHERE d.deleted_at >= ?1
         ORDER BY d.deleted_at ASC, d.row_id ASC"
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| {
        crate::error_log!("CopyAttach: failed to prepare the deleted-payload sweep: {e}");
    })?;
    let floor = cutoff_micros.unwrap_or(i64::MIN);
    let rows = stmt.query_map(rusqlite::params![floor], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
    })
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to read the deleted-payload rows: {e}");
    })?;

    let mut remaining = excess;
    let mut doomed: Vec<i64> = Vec::new();
    for row in rows {
        let (row_id, bytes) = match row {
            Ok(v) => v,
            Err(e) => {
                crate::error_log!("CopyAttach: deleted-payload row read error: {e}");
                continue;
            }
        };
        if remaining <= 0 {
            break;
        }
        doomed.push(row_id);
        remaining = remaining.saturating_sub(bytes.max(0));
    }
    Ok(doomed)
}

pub(crate) fn purge_expired_deleted_rows(
    conn: &Connection,
    limit: i64,
) -> Result<usize, ()> {
    let now_micros = crate::backend::undo_stamp_now();
    let cutoff_micros = now_micros - (crate::backend::UNDO_RETENTION_SECS as i64) * 1_000_000;

    if let Err(e) = conn.execute(
        "DELETE FROM clipboard_deleted
         WHERE NOT EXISTS (SELECT 1 FROM clipboard_history h WHERE h.id = clipboard_deleted.row_id)",
        [],
    ) {
        crate::error_log!("CopyAttach: failed to prune orphan undo entries: {e}");
        return Err(());
    }

    let mut purged = purge_deleted_by(conn, &format!("d.deleted_at < {cutoff_micros}"))?;

    if limit < 0 {
        let cap = limit.unsigned_abs() as usize;
        let doomed = collect_item_evictions(conn, cap)?;
        purged += delete_payload_rows(conn, &doomed)?;
    } else if limit > crate::backend::UNDO_LIMIT_UNLIMITED {
        let retained = retained_deleted_payload_bytes(conn, None)?;
        if retained > limit {
            let doomed = collect_evictions(conn, retained - limit, None)?;
            purged += delete_payload_rows(conn, &doomed)?;
        }
    }

    if purged > 0 {
        crate::debug_log!("CopyAttach: purged {purged} deleted row(s) (age or undo limit)");
    }
    Ok(purged)
}

pub(crate) fn pending_undo_evictions(
    conn: &Connection,
    incoming_payload_bytes: i64,
    limit: i64,
) -> Result<usize, ()> {
    let cutoff_micros = crate::backend::undo_stamp_now()
        - (crate::backend::UNDO_RETENTION_SECS as i64) * 1_000_000;
    if limit < 0 {
        let cap = limit.unsigned_abs() as usize;
        let depth = count_deleted_rows(conn, Some(cutoff_micros))?;
        return Ok((depth + 1).saturating_sub(cap));
    }
    if limit == crate::backend::UNDO_LIMIT_UNLIMITED {
        return Ok(0);
    }
    let retained = retained_deleted_payload_bytes(conn, Some(cutoff_micros))?;
    let after_insert = retained.saturating_add(incoming_payload_bytes);
    let older = collect_evictions(conn, after_insert - limit, Some(cutoff_micros))?.len();
    let self_evicted = usize::from(incoming_payload_bytes > limit);
    Ok(older + self_evicted)
}

pub(crate) fn storage_breakdown(conn: &Connection) -> Result<(i64, i64, i64), ()> {
    let live = "id NOT IN (SELECT row_id FROM clipboard_deleted)";
    let text_sql = format!(
        "SELECT COALESCE(SUM(LENGTH(CAST(text AS BLOB))), 0)
         FROM clipboard_history
         WHERE {live} AND entry_type = 0"
    );
    let image_sql = format!(
        "SELECT COALESCE(SUM(COALESCE(LENGTH(png_data), 0) + COALESCE(LENGTH(thumb_data), 0)), 0)
         FROM clipboard_history
         WHERE {live} AND entry_type = 1"
    );
    let text = conn.query_row(&text_sql, [], |r| r.get::<_, i64>(0)).map_err(|e| {
        crate::error_log!("CopyAttach: failed to size live text payloads: {e}");
    })?;
    let image = conn.query_row(&image_sql, [], |r| r.get::<_, i64>(0)).map_err(|e| {
        crate::error_log!("CopyAttach: failed to size live image payloads: {e}");
    })?;
    Ok((text, image, retained_deleted_payload_bytes(conn, None)?))
}

pub(crate) fn history_row_payload_bytes(conn: &Connection, row_id: i64) -> Result<i64, ()> {
    let sql = format!("SELECT {ROW_PAYLOAD_BYTES} FROM clipboard_history h WHERE h.id = ?1");
    conn.query_row(&sql, rusqlite::params![row_id], |row| row.get::<_, i64>(0))
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to size history row {row_id}: {e}");
        })
}

fn purge_deleted_by(conn: &Connection, predicate: &str) -> Result<usize, ()> {
    let ids: Vec<i64> = {
        let sql = format!("SELECT d.row_id FROM clipboard_deleted d WHERE {predicate}");
        let mut stmt = match conn.prepare(&sql) {
            Ok(s) => s,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to prepare deleted-row sweep: {e}");
                return Err(());
            }
        };
        let rows = match stmt.query_map([], |r| r.get::<_, i64>(0)) {
            Ok(r) => r,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to read rows to sweep: {e}");
                return Err(());
            }
        };
        rows.flatten().collect()
    };
    delete_payload_rows(conn, &ids)
}

pub(crate) fn delete_payload_rows(conn: &Connection, ids: &[i64]) -> Result<usize, ()> {
    if ids.is_empty() {
        return Ok(0);
    }
    let mut removed = 0usize;
    for chunk in ids.chunks(500) {
        let placeholders = vec!["?"; chunk.len()].join(",");
        let del_side = format!(
            "DELETE FROM clipboard_deleted WHERE row_id IN ({placeholders})"
        );
        let del_rows = format!(
            "DELETE FROM clipboard_history WHERE id IN ({placeholders})"
        );
        let tx = match conn.unchecked_transaction() {
            Ok(t) => t,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to begin deleted-payload transaction: {e}");
                return Err(());
            }
        };
        if let Err(e) = tx.execute(&del_rows, rusqlite::params_from_iter(chunk.iter())) {
            crate::error_log!("CopyAttach: failed to remove {} deleted payload rows: {e}", chunk.len());
            return Err(());
        }
        if let Err(e) = tx.execute(&del_side, rusqlite::params_from_iter(chunk.iter())) {
            crate::error_log!("CopyAttach: failed to remove {} undo entries: {e}", chunk.len());
            return Err(());
        }
        match tx.commit() {
            Ok(()) => removed += chunk.len(),
            Err(e) => {
                crate::error_log!("CopyAttach: failed to commit deleted-payload sweep: {e}");
                return Err(());
            }
        }
    }
    Ok(removed)
}

pub(crate) fn persist_entry_to_db(
    conn: &mut Connection,
    entry: &ClipboardEntry,
    text: Option<&str>,
    image_png: Option<&[u8]>,
    image_thumb: Option<(&[u8], u32, u32)>,
    threshold: usize,
) -> Result<i64, ()> {
    let perf = crate::perf::PerfSpan::start("rust", "db.write");
    let tx = conn.unchecked_transaction().map_err(|e| {
        crate::error_log!("CopyAttach: failed to begin write transaction: {e}");
    })?;
    insert_entry_to_db(&tx, entry, text, image_png, image_thumb)?;
    delete_matching_entry(&tx, entry, text);
    trim_db_history(&tx, threshold)?;
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

pub(crate) fn update_entry_custom_label(
    conn: &Connection,
    entry_id: u64,
    custom_label: &str,
) -> Result<(), ()> {
    let changed = conn
        .execute(
            "UPDATE clipboard_history SET custom_label = ?1
             WHERE entry_id = ?2
               AND id NOT IN (SELECT row_id FROM clipboard_deleted)",
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

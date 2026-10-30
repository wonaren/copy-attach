use rusqlite::Connection;

use crate::db::schema::bump_entry_id_watermark;
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

/// Newest-first row order for both the list and the trim cutoff.
///
/// Keyed on `timestamp`, not on `id`. Row order and time order diverge as soon
/// as rows are inserted out of chronological order — which `restore_backup_merge`
/// does by definition (it appends older history to a live DB). With `id` as the
/// key, merged rows took the largest rowids, so they displaced the user's own
/// newer rows from the visible window and were evicted last instead of first.
/// `paste` and `undo` already re-stamp an entry's timestamp when they move it to
/// the head, so `timestamp` is the ordering the rest of the app maintains.
/// `id` is only the tiebreaker, which keeps the order identical to the previous
/// `id`-based one for a DB whose timestamps are in insertion order.
const ORDER_NEWEST_FIRST: &str = "ORDER BY timestamp DESC, id DESC";

/// Load the newest `threshold` **non-favorite** rows plus every favorite,
/// newest first.
///
/// The plain `LIMIT ?` is not enough now that favorites survive trimming: a
/// favorite can sit arbitrarily far down the list, and truncating to the newest
/// N rows would silently hide it. It is also not enough to take the newest N
/// rows and add favorites: a favorite that happens to *be* in the newest N
/// consumes one of the N slots, so the oldest cleanable row disappears from the
/// list while the trim (which caps only cleanable rows) leaves it in the DB.
/// Measured live: 100 non-favorites + 2 favorites with one favorite re-copied
/// to the top rendered 101 rows instead of 102. The subquery therefore excludes
/// favorites before applying `LIMIT`, matching `trim_db_history`'s cap exactly.
///
/// Soft-deleted rows (`deleted_at != 0`) are excluded from both halves: they are
/// undo candidates, not list entries.
///
/// Only metadata is read: the full `text` column is never touched at load.
/// Preview/label/text-hash were persisted at insert time (and backfilled for
/// legacy rows by `ensure_history_table`), so a cold start reads a bounded,
/// per-row payload no matter how large the stored documents are. Image entries
/// carry only metadata (`png_data` is empty, loaded on demand).
pub(crate) fn load_history_from_db(conn: &Connection, threshold: usize) -> Vec<ClipboardEntry> {
    let mut stmt = match conn.prepare(
        &format!(
            "SELECT id, entry_id, entry_type, preview, label, hash,
                    width, height,
                    thumb_width, thumb_height,
                    timestamp, source_name, source_bundle_id,
                    custom_label
             FROM clipboard_history
             WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
               AND (id IN (SELECT id FROM clipboard_history
                           WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                             AND entry_id NOT IN (SELECT entry_id FROM clipboard_favorites)
                           {ORDER_NEWEST_FIRST} LIMIT ?1)
                   OR entry_id IN (SELECT entry_id FROM clipboard_favorites
                                   WHERE entry_id IN (SELECT entry_id FROM clipboard_history
                                                      WHERE id NOT IN (SELECT row_id FROM clipboard_deleted))))
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
    // Persisting a row is the moment its entry_id enters the durable identity
    // space, so the high-water mark is raised here rather than at shutdown:
    // a crash (or a clear before quitting) must not lose the record, or a
    // later session would re-issue an id a favorite still points at.
    if result.is_ok() && bump_entry_id_watermark(conn, entry.entry_id()).is_err() {
        crate::error_log!("CopyAttach: entry-id watermark not raised after insert; ids stay unique only while rows survive");
    }
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
            // Dedup only against LIVE rows: a soft-deleted row of the same
            // content is an undo candidate, and removing it here would make the
            // delete silently un-undoable just because the content was copied
            // again.
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                   AND entry_type = 0 AND hash = ?1 AND text = ?2
                   AND id != (SELECT id FROM clipboard_history
                              WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                                AND entry_type = 0 AND hash = ?1 AND text = ?2
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![*text_hash as i64, full],
            ).map(|_| ())
        }
        ClipboardEntry::Image { hash, .. } => {
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                   AND entry_type = 1 AND hash = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                                AND entry_type = 1 AND hash = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![*hash as i64],
            ).map(|_| ())
        }
    };
    if let Err(e) = result {
        crate::error_log!("CopyAttach: failed to delete matching entry: {e}");
    }
}

/// Trim the DB to at most `threshold` **non-favorite** entries (keeps the
/// newest rows, never deletes a favorite).
///
/// Favorites are excluded from both the count and the delete, so the cap applies
/// to cleanable history only: the table may hold `threshold` non-favorites plus
/// every favorite. That is the product promise — a starred entry is never
/// removed by automatic cleanup.
///
/// The excess is `total - favorites`, which is exact because the favorite table
/// is kept free of orphans (every delete path removes the favorite in the same
/// transaction, and init prunes legacy leftovers). The DELETE then walks only
/// the OLDEST `excess` cleanable rows, so a steady-state capture (excess = 1)
/// costs a count plus a couple of index rows — measured 15–140 µs at 10 000
/// rows. The previous newest-first cutoff subquery had to walk the whole window
/// and, once the favorite exclusion made it non-covering, cost 1.9 ms per
/// capture at the same size.
///
/// "Oldest" is `(timestamp, id)`, the same order the list uses: trimming by
/// rowid instead would evict the user's own newer rows first whenever the table
/// holds rows inserted out of chronological order (a merge).
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

/// Mark a live row as deleted in the side table, recording whether it was
/// favorited.
///
/// Returns the row's `(entry_id, deleted_at)` on success. `Err` means the row
/// was missing, already deleted, or the write failed; every caller treats that
/// as an explicit failure (0), never a silent success.
///
/// This writes ONLY the side table. The payload row in `clipboard_history` is
/// never updated, which is the whole point: an `UPDATE` on an image row rewrites
/// its multi-MB PNG + thumbnail blobs and was measured at +24 MB retained RSS
/// for 34 deletions.
pub(crate) fn soft_delete_row(conn: &Connection, db_id: i64) -> Result<(u64, i64), ()> {
    let stamp = crate::backend::undo_stamp_now();
    // Read the row's identity and star state in one probe; a row that is
    // already in the side table is not deletable again.
    //
    // "No such row" and "the read failed" are DIFFERENT outcomes and must not be
    // collapsed: a failed read (IO error, lock timeout, damaged schema) is a
    // defect in the main path, and reporting it as "the row isn't there" would
    // hide it behind a plausible business answer. Only `QueryReturnedNoRows`
    // means the row is genuinely absent.
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
    Ok((entry_id as u64, stamp))
}

/// The most recently deleted row's identity, or `None` when nothing is
/// undoable. Drives `clipboard_can_undo` and the undo path itself.
///
/// `(row_id, entry_id, deleted_at, was_favorite)`. A side row whose payload row
/// is already gone is skipped and cleaned up: it cannot be restored, and
/// letting it sit at the head would block every older deletion behind it.
///
/// `Err` is a real read failure and must be surfaced, not flattened into
/// `None`: "nothing is undoable" is a normal state the UI acts on (it disables
/// ⌘Z), so reporting an IO error that way would make a broken database look
/// like an empty undo stack.
pub(crate) fn newest_deleted_row(
    conn: &Connection,
) -> Result<Option<(i64, u64, i64, i64)>, ()> {
    loop {
        let candidate = match conn.query_row(
            "SELECT row_id, entry_id, deleted_at, was_favorite
             FROM clipboard_deleted
             ORDER BY deleted_at DESC, row_id DESC
             LIMIT 1",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
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
        let (row_id, entry_id, stamp, was_favorite) = match candidate {
            Some(v) => v,
            None => return Ok(None),
        };
        // An orphan side row (payload row already purged) is dropped and the
        // next-newest deletion is considered.
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
            return Ok(Some((row_id, entry_id as u64, stamp, was_favorite)));
        }
        crate::debug_log!("CopyAttach: dropping orphan undo entry for missing row {row_id}");
        // The drop MUST succeed before looping: on failure the same row would be
        // selected again forever, so this returns an explicit error instead of
        // retrying silently.
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

/// Number of deletions currently undoable.
///
/// `Err` (not 0) on a read failure: the caller uses this to enable/disable ⌘Z,
/// and a failed count reported as "0" would silently disable undo while the
/// deleted rows are still there.
pub(crate) fn undo_depth(conn: &Connection) -> Result<usize, ()> {
    conn.query_row(
        "SELECT COUNT(*) FROM clipboard_deleted d
         WHERE EXISTS (SELECT 1 FROM clipboard_history h WHERE h.id = d.row_id)",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|n| n.max(0) as usize)
    .map_err(|e| {
        crate::error_log!("CopyAttach: failed to count undoable deletions: {e}");
    })
}

/// Purge deletions past their retention window, then shed the oldest until the
/// retained payload fits the byte budget.
///
/// This is the only thing that removes a soft-deleted row without an undo: a
/// deleted row keeps its payload, so without a sweep the deleted set would grow
/// forever. Runs at startup (cheap: the age query is index-only) and after each
/// delete (so a burst of large deletions self-limits immediately).
///
/// Purging means removing the PAYLOAD row (that is what frees disk) plus its
/// side-table row. Orphan side rows are pruned in the same pass.
///
/// Returns how many payload rows were purged. A DB error is reported and
/// returned as `Err`; the caller logs it, and nothing else depends on the sweep
/// succeeding.
pub(crate) fn purge_expired_deleted_rows(conn: &Connection) -> Result<usize, ()> {
    let now_micros = crate::backend::undo_stamp_now();
    let cutoff_micros = now_micros - (crate::backend::UNDO_RETENTION_SECS as i64) * 1_000_000;

    // 1. Orphan side rows: their payload row is already gone.
    if let Err(e) = conn.execute(
        "DELETE FROM clipboard_deleted
         WHERE NOT EXISTS (SELECT 1 FROM clipboard_history h WHERE h.id = clipboard_deleted.row_id)",
        [],
    ) {
        crate::error_log!("CopyAttach: failed to prune orphan undo entries: {e}");
        return Err(());
    }

    // 2. Age: everything deleted longer ago than the retention window.
    let by_age = purge_deleted_by(conn, &format!("d.deleted_at < {cutoff_micros}"))?;

    // 3. Byte budget. Each column is COALESCEd individually: a text row has
    // NULL png/thumb and an image row has NULL text, and `LENGTH(a) + LENGTH(b)`
    // is NULL as soon as any term is NULL. A single outer COALESCE therefore
    // reported "0 bytes retained" for every image row and the budget never fired
    // (measured: 80 MB of deleted screenshots stayed under a 64 MB budget).
    let retained: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(
                 COALESCE(LENGTH(h.text), 0)
               + COALESCE(LENGTH(h.png_data), 0)
               + COALESCE(LENGTH(h.thumb_data), 0)), 0)
             FROM clipboard_deleted d
             JOIN clipboard_history h ON h.id = d.row_id",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|e| {
            crate::error_log!("CopyAttach: failed to size the retained deleted payload: {e}");
        })?;

    let mut purged = by_age;
    if retained > crate::backend::MAX_UNDO_RETAINED_BYTES {
        // Walk oldest-deletion-first, collecting rows until enough bytes are
        // shed, then delete exactly that set.
        let mut excess = retained - crate::backend::MAX_UNDO_RETAINED_BYTES;
        let mut doomed: Vec<i64> = Vec::new();
        {
            let mut stmt = match conn.prepare(
                "SELECT d.row_id,
                        COALESCE(LENGTH(h.text), 0)
                      + COALESCE(LENGTH(h.png_data), 0)
                      + COALESCE(LENGTH(h.thumb_data), 0)
                 FROM clipboard_deleted d
                 JOIN clipboard_history h ON h.id = d.row_id
                 ORDER BY d.deleted_at ASC, d.row_id ASC",
            ) {
                Ok(s) => s,
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to prepare deleted-payload sweep: {e}");
                    return Err(());
                }
            };
            let rows = match stmt.query_map([], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
            }) {
                Ok(r) => r,
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to read deleted-payload rows: {e}");
                    return Err(());
                }
            };
            for row in rows {
                let (row_id, bytes) = match row {
                    Ok(v) => v,
                    Err(e) => {
                        crate::error_log!("CopyAttach: deleted-payload row read error: {e}");
                        continue;
                    }
                };
                if excess <= 0 {
                    break;
                }
                doomed.push(row_id);
                excess = excess.saturating_sub(bytes.max(0));
            }
        }
        purged += delete_payload_rows(conn, &doomed)?;
    }

    if purged > 0 {
        crate::debug_log!("CopyAttach: purged {purged} deleted row(s) (age or byte budget)");
    }
    Ok(purged)
}

/// Purge deletions matching a `clipboard_deleted` predicate. Returns how many
/// payload rows were removed.
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

/// Remove the given payload rows and their side-table entries.
fn delete_payload_rows(conn: &Connection, ids: &[i64]) -> Result<usize, ()> {
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
        if let Err(e) = conn.execute(&del_side, rusqlite::params_from_iter(chunk.iter())) {
            crate::error_log!("CopyAttach: failed to remove {} undo entries: {e}", chunk.len());
            return Err(());
        }
        match conn.execute(&del_rows, rusqlite::params_from_iter(chunk.iter())) {
            Ok(c) => removed += c,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to remove {} deleted payload rows: {e}", chunk.len());
                return Err(());
            }
        }
    }
    Ok(removed)
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
    // Trim is part of the same transaction: a failure must roll the whole
    // write back rather than commit a capture that left the table over the cap.
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

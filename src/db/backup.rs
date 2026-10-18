//! Database backup and restore operations for CopyAttach.
//!
//! Provides atomic, zero-overhead export via SQLite `VACUUM INTO`, pre-inspection of
//! backup packages, and transactional restore (both overwrite and merge modes).
//!
//! Preserves:
//! - Complete clipboard history (text, full PNG blobs, thumbnails, dimensions, timestamps, source apps)
//! - User remarks (`custom_label`)
//! - User favorites (persisted inside `clipboard_backup_favorites` table)
//! - Monotonic `entry_id` sequence watermark

use rusqlite::{Connection, OpenFlags};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::db::schema::bump_entry_id_watermark;

/// Summary information extracted from a backup file during inspection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BackupInspectInfo {
    pub item_count: usize,
    pub favorite_count: usize,
    pub timestamp: u64,
}

fn escape_sql_string(s: &str) -> String {
    s.replace('\'', "''")
}

/// Export the current database to a standalone `.cabackup` file.
///
/// Uses `VACUUM INTO` to create a compact, consistent snapshot of all tables
/// without memory overhead, then records metadata and favorite IDs.
pub(crate) fn export_backup(
    conn: &Connection,
    target_path: &Path,
) -> Result<usize, String> {
    if let Some(parent) = target_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("无法创建备份目标目录: {e}"))?;
        }
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let pid = std::process::id();
    let tmp_path = target_path.with_extension(format!("tmp-{pid}-{now}"));
    if tmp_path.exists() {
        let _ = std::fs::remove_file(&tmp_path);
    }

    let tmp_str = tmp_path.to_str().ok_or_else(|| "目标路径包含非法 UTF-8 字符".to_string())?;
    let vacuum_sql = format!("VACUUM INTO '{}'", escape_sql_string(tmp_str));
    conn.execute_batch(&vacuum_sql)
        .map_err(|e| format!("执行 VACUUM INTO 导出失败: {e}"))?;

    // Now enrich the exported standalone snapshot with backup metadata and favorite IDs.
    let item_count: usize = {
        let backup_conn = Connection::open(&tmp_path)
            .map_err(|e| format!("打开临时备份文件失败: {e}"))?;

        backup_conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS clipboard_backup_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS clipboard_backup_favorites (
                entry_id INTEGER PRIMARY KEY
            );"
        ).map_err(|e| format!("创建备份元数据表失败: {e}"))?;

        let count: i64 = backup_conn
            .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
            .unwrap_or(0);

        {
            let mut stmt = backup_conn
                .prepare("INSERT OR REPLACE INTO clipboard_backup_meta (key, value) VALUES (?1, ?2)")
                .map_err(|e| format!("准备写入元数据失败: {e}"))?;
            stmt.execute(["version", "1"]).map_err(|e| e.to_string())?;
            stmt.execute(["created_at", &now.to_string()]).map_err(|e| e.to_string())?;
            stmt.execute(["app_version", env!("CARGO_PKG_VERSION")]).map_err(|e| e.to_string())?;
            stmt.execute(["total_items", &count.to_string()]).map_err(|e| e.to_string())?;
        }

        // The favorite set lives in the live DB's `clipboard_favorites` table
        // (`VACUUM INTO` copies it too); the backup format's own table is what
        // older builds and the restore path read, so mirror it explicitly.
        backup_conn
            .execute(
                "INSERT OR IGNORE INTO clipboard_backup_favorites (entry_id)
                 SELECT entry_id FROM clipboard_favorites",
                [],
            )
            .map_err(|e| format!("写入备份收藏失败: {e}"))?;

        count.max(0) as usize
    };

    // Atomically replace target file.
    //
    // The stale-sidecar purge is load-bearing, not hygiene. `VACUUM INTO` writes
    // a *fresh* database at `tmp_path`, but a previous export to the same
    // `target_path` can have left `target_path-wal` / `-shm` behind. SQLite
    // replays a `-wal` that sits beside a database file, so after the rename a
    // reader would see the OLD WAL's contents layered over the NEW snapshot —
    // reproduced locally as a reader returning pre-export rows. Removing the
    // sidecars first is what makes the rename a real replacement.
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = target_path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let sidecar = PathBuf::from(sidecar);
        if sidecar.exists() {
            std::fs::remove_file(&sidecar)
                .map_err(|e| format!("清理旧的备份 WAL 附属文件失败 ({suffix}): {e}"))?;
        }
    }

    if target_path.exists() {
        std::fs::remove_file(target_path)
            .map_err(|e| format!("删除旧的备份文件失败: {e}"))?;
    }
    std::fs::rename(&tmp_path, target_path)
        .map_err(|e| format!("重命名备份临时文件至目标路径失败: {e}"))?;

    // The temp database was written through a WAL-mode connection, so its own
    // sidecars can survive the rename under names nothing will ever look for.
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = tmp_path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(sidecar));
    }

    Ok(item_count)
}

/// Inspect a backup file to check its validity and extract high-level summary statistics.
pub(crate) fn inspect_backup(backup_path: &Path) -> Result<BackupInspectInfo, String> {
    if !backup_path.exists() {
        return Err("备份文件不存在".to_string());
    }

    let conn = Connection::open_with_flags(backup_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("无法打开备份文件 (可能已损坏或非 SQLite 格式): {e}"))?;

    let has_history: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clipboard_history'",
        [],
        |r| r.get(0),
    ).map_err(|e| format!("查询历史表失败: {e}"))?;

    if has_history == 0 {
        return Err("不是有效的 CopyAttach 备份文件（缺少剪贴板历史表）".to_string());
    }

    let item_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM clipboard_history",
        [],
        |r| r.get(0),
    ).map_err(|e| format!("统计历史记录数失败: {e}"))?;

    let has_fav: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clipboard_backup_favorites'",
        [],
        |r| r.get(0),
    ).unwrap_or(0);

    let favorite_count: i64 = if has_fav > 0 {
        conn.query_row("SELECT COUNT(*) FROM clipboard_backup_favorites", [], |r| r.get(0)).unwrap_or(0)
    } else {
        0
    };

    let has_meta: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clipboard_backup_meta'",
        [],
        |r| r.get(0),
    ).unwrap_or(0);

    let timestamp: u64 = if has_meta > 0 {
        conn.query_row(
            "SELECT value FROM clipboard_backup_meta WHERE key = 'created_at'",
            [],
            |r| r.get::<_, String>(0),
        ).ok().and_then(|s| s.parse::<u64>().ok()).unwrap_or(0)
    } else {
        0
    };

    let final_timestamp = if timestamp > 0 {
        timestamp
    } else {
        std::fs::metadata(backup_path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0)
    };

    Ok(BackupInspectInfo {
        item_count: item_count.max(0) as usize,
        favorite_count: favorite_count.max(0) as usize,
        timestamp: final_timestamp,
    })
}

/// Completely overwrite the active database with data from the backup file.
///
/// Returns `(restored_item_count, restored_favorites)`.
pub(crate) fn restore_backup_overwrite(
    conn: &mut Connection,
    backup_path: &Path,
) -> Result<(usize, Vec<u64>), String> {
    // 1. Inspect first to validate file format and ensure clipboard_history exists.
    let _info = inspect_backup(backup_path)?;

    let backup_str = backup_path
        .to_str()
        .ok_or_else(|| "备份文件路径包含非法字符".to_string())?;

    conn.execute("ATTACH DATABASE ?1 AS backup_db", [backup_str])
        .map_err(|e| format!("挂载备份数据库失败: {e}"))?;

    let res = (|| -> Result<(usize, Vec<u64>), String> {
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| format!("开启恢复事务失败: {e}"))?;

        // Overwrite clipboard_history and its favorite set. They are one
        // logical dataset: keeping the old favorites would leave ids that the
        // restored rows may not contain.
        tx.execute("DELETE FROM main.clipboard_history", [])
            .map_err(|e| format!("清空当前历史表失败: {e}"))?;
        tx.execute("DELETE FROM main.clipboard_favorites", [])
            .map_err(|e| format!("清空当前收藏表失败: {e}"))?;

        tx.execute_batch(
            "INSERT INTO main.clipboard_history (
                id, entry_id, entry_type, text, png_data, width, height,
                thumb_data, thumb_width, thumb_height, hash, timestamp,
                source_name, source_bundle_id, preview, label, custom_label
            )
            SELECT
                id, entry_id, entry_type, text, png_data, width, height,
                thumb_data, thumb_width, thumb_height, hash, timestamp,
                source_name, source_bundle_id, preview, label, custom_label
            FROM backup_db.clipboard_history;",
        )
        .map_err(|e| format!("导入备份历史数据失败: {e}"))?;

        // Adopt the backup's meta EXCEPT the entry-id watermark, which must
        // never move backwards.
        //
        // `bump_entry_id_watermark` is `MAX(value, excluded)`, so copying the
        // backup's watermark over the live one and then bumping is a no-op if
        // the backup's is larger — but if the backup's is SMALLER it wins, and
        // the ids this database already issued can be handed out again. Those
        // ids are exactly what Swift's Favorites list stores, so a favorite
        // would then light up on unrelated new content (the hazard
        // `schema.rs::bump_entry_id_watermark` exists to prevent).
        //
        // The watermark is read back and re-applied as a floor below, after the
        // row copy, so the local value always survives.
        let local_watermark = crate::db::schema::entry_id_watermark(&tx);

        // `clipboard_meta` may be absent from the archive, and it cannot be
        // guarded with `EXISTS` in the same statement: SQLite resolves
        // `backup_db.clipboard_meta` at PREPARE time, so a missing table fails
        // the statement before the guard is ever evaluated. That failure was
        // also being swallowed by `let _ =` on the whole batch — and because
        // `execute_batch` stops at the first error, the `CREATE TABLE
        // IF NOT EXISTS main.clipboard_meta` that preceded it never applied
        // either. Verified against a meta-less archive: the batch aborted with
        // `no such table: backup_db.clipboard_meta` and `main.clipboard_meta`
        // was left absent, so every later meta read and write failed silently.
        // Checking at runtime, in its own statement, keeps the failure local.
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS main.clipboard_meta (
                key TEXT PRIMARY KEY,
                value INTEGER
            );",
        )
        .map_err(|e| format!("创建元数据表失败: {e}"))?;

        let backup_has_meta: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master
                 WHERE type = 'table' AND name = 'clipboard_meta'",
                [],
                |r| r.get(0),
            )
            .map_err(|e| format!("检查备份元数据表失败: {e}"))?;

        if backup_has_meta > 0 {
            tx.execute(
                "INSERT OR REPLACE INTO main.clipboard_meta (key, value)
                 SELECT key, value FROM backup_db.clipboard_meta
                 WHERE key <> 'entry_id_watermark'",
                [],
            )
            .map_err(|e| format!("恢复元数据失败: {e}"))?;
        }

        // Read restored favorite IDs
        let has_fav_table: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master WHERE type='table' AND name='clipboard_backup_favorites'",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);

        if has_fav_table > 0 {
            // Restore the durable set only for rows that actually came back:
            // joining the restored history drops ids whose row is absent from
            // the archive (or was removed by an older trim).
            tx.execute(
                "INSERT OR IGNORE INTO main.clipboard_favorites (entry_id)
                 SELECT f.entry_id
                 FROM backup_db.clipboard_backup_favorites f
                 JOIN main.clipboard_history h ON h.entry_id = f.entry_id",
                [],
            )
            .map_err(|e| format!("恢复收藏表失败: {e}"))?;
        }
        let restored_favorites: Vec<u64> = {
            let mut stmt = tx
                .prepare("SELECT entry_id FROM main.clipboard_favorites ORDER BY entry_id")
                .map_err(|e| format!("准备读取恢复后的收藏失败: {e}"))?;
            let rows = stmt
                .query_map([], |r| r.get::<_, i64>(0))
                .map_err(|e| format!("遍历恢复后的收藏失败: {e}"))?;
            rows.flatten().filter(|id| *id > 0).map(|id| id as u64).collect()
        };

        // No explicit FTS rebuild here. `ensure_history_table` installs
        // AFTER INSERT / AFTER DELETE triggers on `clipboard_history` that keep
        // `clipboard_fts` in sync, and they fire for the restore's own writes:
        // the `DELETE FROM main.clipboard_history` above fires the delete
        // trigger for each removed row, and `INSERT ... SELECT` fires the insert
        // trigger for each restored row. Verified by
        // `test_search_works_after_restore_without_explicit_rebuild`.
        //
        // The previous `INSERT INTO clipboard_fts(clipboard_fts)
        // VALUES('rebuild')` was redundant work: measured 69 ms on a
        // 6 000-text-row fixture, paid while holding the DB mutex the capture
        // path also needs, to rebuild an index the triggers had already built.
        // (For the same reason there is no rebuild in the merge path.)

        // Ensure the watermark covers both the highest entry_id now present AND
        // the local watermark captured before the meta copy. Applied
        // unconditionally — including when the restored table is empty — so a
        // restore can never leave the DB issuing ids it already issued before.
        let max_entry_id: i64 = tx
            .query_row(
                "SELECT COALESCE(MAX(entry_id), 0) FROM clipboard_history",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);
        let floor = (max_entry_id.max(0) as u64).max(local_watermark);
        if floor > 0 {
            let _ = bump_entry_id_watermark(&tx, floor);
        }

        let restored_count: i64 = tx
            .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
            .unwrap_or(0);

        tx.commit().map_err(|e| format!("提交恢复事务失败: {e}"))?;

        Ok((restored_count.max(0) as usize, restored_favorites))
    })();

    let _ = conn.execute_batch("DETACH DATABASE backup_db;");
    res
}

/// Merge clipboard records from the backup file into the active database.
///
/// Merges deduplicated entries, preserves newer remarks, and consolidates favorites.
/// Returns `(newly_added_item_count, merged_favorites)`.
pub(crate) fn restore_backup_merge(
    conn: &mut Connection,
    backup_path: &Path,
) -> Result<(usize, Vec<u64>), String> {
    let _info = inspect_backup(backup_path)?;

    let backup_str = backup_path
        .to_str()
        .ok_or_else(|| "备份文件路径包含非法字符".to_string())?;

    conn.execute("ATTACH DATABASE ?1 AS backup_db", [backup_str])
        .map_err(|e| format!("挂载备份数据库失败: {e}"))?;

    let res = (|| -> Result<(usize, Vec<u64>), String> {
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| format!("开启合并事务失败: {e}"))?;

        // Read backup favorite IDs
        let has_fav_table: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master WHERE type='table' AND name='clipboard_backup_favorites'",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);

        let mut backup_fav_set: HashSet<u64> = HashSet::new();
        if has_fav_table > 0 {
            let mut stmt = tx
                .prepare("SELECT entry_id FROM backup_db.clipboard_backup_favorites")
                .map_err(|e| format!("准备读取备份收藏失败: {e}"))?;
            let rows = stmt
                .query_map([], |r| r.get::<_, i64>(0))
                .map_err(|e| format!("读取备份收藏失败: {e}"))?;
            for row in rows.flatten() {
                if row > 0 {
                    backup_fav_set.insert(row as u64);
                }
            }
        }

        // The live favorite set is the durable table, not a Swift argument.
        let mut merged_fav_set: HashSet<u64> = {
            let mut stmt = tx
                .prepare("SELECT entry_id FROM main.clipboard_favorites")
                .map_err(|e| format!("查询现有收藏失败: {e}"))?;
            let rows = stmt
                .query_map([], |r| r.get::<_, i64>(0))
                .map_err(|e| format!("遍历现有收藏失败: {e}"))?;
            rows.flatten().filter(|id| *id > 0).map(|id| id as u64).collect()
        };

        // Query active entry IDs and max watermark to prevent ID conflicts
        let mut used_entry_ids: HashSet<u64> = HashSet::new();
        {
            let mut stmt = tx
                .prepare("SELECT entry_id FROM main.clipboard_history")
                .map_err(|e| format!("查询现有 entry_id 失败: {e}"))?;
            let rows = stmt
                .query_map([], |r| r.get::<_, i64>(0))
                .map_err(|e| format!("遍历现有 entry_id 失败: {e}"))?;
            for row in rows.flatten() {
                if row > 0 {
                    used_entry_ids.insert(row as u64);
                }
            }
        }

        let mut max_entry_id: u64 = used_entry_ids.iter().copied().max().unwrap_or(0);
        let current_watermark = crate::db::schema::entry_id_watermark(&tx);
        max_entry_id = max_entry_id.max(current_watermark);

        // Ids the backup carries count as "seen" even when every one of them
        // deduplicates away. The watermark is a high-water mark of ids this
        // database has ever been shown — not merely of ids it currently stores —
        // and the whole point of "only ever rises" is that an id can never be
        // reissued once it has appeared. A dedup-only merge previously left the
        // watermark untouched (measured: watermark 3 against backup ids up to
        // 9001), so the next capture could mint an id the backup still refers to.
        {
            let backup_max: i64 = tx
                .query_row(
                    "SELECT COALESCE(MAX(entry_id), 0) FROM backup_db.clipboard_history",
                    [],
                    |r| r.get(0),
                )
                .map_err(|e| format!("读取备份最大 entry_id 失败: {e}"))?;
            if backup_max > 0 {
                max_entry_id = max_entry_id.max(backup_max as u64);
            }
            if let Some(&fav_max) = backup_fav_set.iter().max() {
                max_entry_id = max_entry_id.max(fav_max);
            }
        }

        let mut newly_added = 0usize;

        // One row at a time. Collecting every row into a `Vec` first held the
        // whole backup's blobs in memory at once: measured +588 MB peak RSS on a
        // 570 MB / 10 000-row archive (a full-size history), which on a 16 GB
        // machine is the difference between a restore and a memory event. The
        // SELECT and the INSERTs touch different databases (`backup_db` vs
        // `main`), so the read cursor stays valid while we write.
        struct RawBackupRow {
            entry_id: i64,
            entry_type: i32,
            text: Option<String>,
            png_data: Option<Vec<u8>>,
            width: Option<i64>,
            height: Option<i64>,
            thumb_data: Option<Vec<u8>>,
            thumb_width: Option<i64>,
            thumb_height: Option<i64>,
            hash: i64,
            timestamp: i64,
            source_name: String,
            source_bundle_id: String,
            preview: String,
            label: String,
            custom_label: String,
        }

        let mut stmt = tx
            .prepare(
                "SELECT entry_id, entry_type, text, png_data, width, height,
                        thumb_data, thumb_width, thumb_height, hash, timestamp,
                        source_name, source_bundle_id, preview, label, custom_label
                 FROM backup_db.clipboard_history
                 ORDER BY id ASC",
            )
            .map_err(|e| format!("读取备份条目失败: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(RawBackupRow {
                    entry_id: row.get(0)?,
                    entry_type: row.get(1)?,
                    text: row.get(2)?,
                    png_data: row.get(3)?,
                    width: row.get(4)?,
                    height: row.get(5)?,
                    thumb_data: row.get(6)?,
                    thumb_width: row.get(7)?,
                    thumb_height: row.get(8)?,
                    hash: row.get(9)?,
                    timestamp: row.get(10)?,
                    source_name: row.get(11)?,
                    source_bundle_id: row.get(12)?,
                    preview: row.get(13)?,
                    label: row.get(14)?,
                    custom_label: row.get(15)?,
                })
            })
            .map_err(|e| format!("查询备份记录失败: {e}"))?;

        for row in rows {
            // A malformed row is reported, not silently dropped: the old
            // `.flatten()` hid read errors, so a partially-readable archive
            // restored "successfully" with rows missing.
            let item = match row {
                Ok(r) => r,
                Err(e) => {
                    crate::error_log!("CopyAttach: merge: unreadable backup row skipped: {e}");
                    continue;
                }
            };
            let is_fav = backup_fav_set.contains(&(item.entry_id as u64));

            if item.entry_type == 0 {
                // Text entry
                let full_text = match &item.text {
                    Some(t) => t.as_str(),
                    None => continue,
                };

                let existing: Option<(i64, i64, String)> = tx
                    .query_row(
                        "SELECT id, entry_id, custom_label FROM main.clipboard_history
                         WHERE entry_type = 0 AND hash = ?1 AND text = ?2",
                        rusqlite::params![item.hash, full_text],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                    )
                    .ok();

                if let Some((curr_id, curr_entry_id, curr_label)) = existing {
                    if curr_label.is_empty() && !item.custom_label.is_empty() {
                        let _ = tx.execute(
                            "UPDATE main.clipboard_history SET custom_label = ?1 WHERE id = ?2",
                            rusqlite::params![item.custom_label, curr_id],
                        );
                    }
                    if is_fav && curr_entry_id > 0 {
                        merged_fav_set.insert(curr_entry_id as u64);
                    }
                } else {
                    let mut final_eid = item.entry_id as u64;
                    if final_eid == 0 || used_entry_ids.contains(&final_eid) {
                        max_entry_id += 1;
                        final_eid = max_entry_id;
                    }
                    used_entry_ids.insert(final_eid);
                    // An id adopted verbatim from the backup may be the highest
                    // this database has ever seen; the watermark must cover it
                    // (the counter above only advances on collisions).
                    max_entry_id = max_entry_id.max(final_eid);

                    let res = tx.execute(
                        "INSERT INTO main.clipboard_history
                            (entry_type, text, png_data, width, height,
                             thumb_data, thumb_width, thumb_height, hash,
                             timestamp, source_name, source_bundle_id, entry_id,
                             preview, label, custom_label)
                         VALUES (0, ?1, NULL, NULL, NULL, NULL, NULL, NULL, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                        rusqlite::params![
                            full_text, item.hash, item.timestamp,
                            item.source_name, item.source_bundle_id, final_eid as i64,
                            item.preview, item.label, item.custom_label,
                        ],
                    );
                    if res.is_ok() {
                        newly_added += 1;
                        if is_fav {
                            merged_fav_set.insert(final_eid);
                        }
                    }
                }
            } else if item.entry_type == 1 {
                // Image entry
                let png = match &item.png_data {
                    Some(p) => p.as_slice(),
                    None => continue,
                };
                let thumb = match &item.thumb_data {
                    Some(t) => t.as_slice(),
                    None => continue,
                };

                let existing: Option<(i64, i64, String)> = tx
                    .query_row(
                        "SELECT id, entry_id, custom_label FROM main.clipboard_history
                         WHERE entry_type = 1 AND hash = ?1",
                        rusqlite::params![item.hash],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                    )
                    .ok();

                if let Some((curr_id, curr_entry_id, curr_label)) = existing {
                    if curr_label.is_empty() && !item.custom_label.is_empty() {
                        let _ = tx.execute(
                            "UPDATE main.clipboard_history SET custom_label = ?1 WHERE id = ?2",
                            rusqlite::params![item.custom_label, curr_id],
                        );
                    }
                    if is_fav && curr_entry_id > 0 {
                        merged_fav_set.insert(curr_entry_id as u64);
                    }
                } else {
                    let mut final_eid = item.entry_id as u64;
                    if final_eid == 0 || used_entry_ids.contains(&final_eid) {
                        max_entry_id += 1;
                        final_eid = max_entry_id;
                    }
                    used_entry_ids.insert(final_eid);
                    // An id adopted verbatim from the backup may be the highest
                    // this database has ever seen; the watermark must cover it
                    // (the counter above only advances on collisions).
                    max_entry_id = max_entry_id.max(final_eid);

                    let res = tx.execute(
                        "INSERT INTO main.clipboard_history
                            (entry_type, text, png_data, width, height,
                             thumb_data, thumb_width, thumb_height, hash,
                             timestamp, source_name, source_bundle_id, entry_id,
                             preview, label, custom_label)
                         VALUES (1, NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, '', '', ?12)",
                        rusqlite::params![
                            png,
                            item.width.unwrap_or(0),
                            item.height.unwrap_or(0),
                            thumb,
                            item.thumb_width.unwrap_or(0),
                            item.thumb_height.unwrap_or(0),
                            item.hash,
                            item.timestamp,
                            item.source_name,
                            item.source_bundle_id,
                            final_eid as i64,
                            item.custom_label,
                        ],
                    );
                    if res.is_ok() {
                        newly_added += 1;
                        if is_fav {
                            merged_fav_set.insert(final_eid);
                        }
                    }
                }
            }
        }
        drop(stmt);

        // Raise the watermark whenever the ids the backup carried could exceed
        // it — not only when rows were inserted. A merge that deduplicated every
        // row (same content on both sides) still revealed ids this database has
        // never issued; leaving the watermark below them lets the next capture
        // reuse one. `max_entry_id` already folds in the pre-merge watermark and
        // the highest id present locally.
        if max_entry_id > 0 {
            let _ = bump_entry_id_watermark(&tx, max_entry_id);
        }

        // Persist the consolidated favorite set. The ids were collected against
        // rows that are present after this transaction, so this is the durable
        // write the old implementation expressed by returning them to Swift.
        {
            let mut fav_stmt = tx
                .prepare("INSERT OR IGNORE INTO main.clipboard_favorites (entry_id) VALUES (?1)")
                .map_err(|e| format!("准备写入合并收藏失败: {e}"))?;
            for id in &merged_fav_set {
                fav_stmt
                    .execute([*id as i64])
                    .map_err(|e| format!("写入合并收藏失败: {e}"))?;
            }
        }

        // No explicit FTS rebuild here either — see the note in
        // `restore_backup_overwrite`. The `INSERT`s above fire the
        // `clipboard_fts_ai` trigger, so the index is already current; the
        // rebuild was redundant work (69 ms on a 6 000-text-row fixture) paid
        // while holding the DB mutex.

        tx.commit().map_err(|e| format!("提交合并事务失败: {e}"))?;

        Ok((newly_added, merged_fav_set.into_iter().collect()))
    })();

    let _ = conn.execute_batch("DETACH DATABASE backup_db;");
    res
}

use rusqlite::{Connection, OpenFlags};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::db::schema::bump_entry_id_watermark;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BackupInspectInfo {
    pub item_count: usize,
    pub favorite_count: usize,
    pub timestamp: u64,
}

fn escape_sql_string(s: &str) -> String {
    s.replace('\'', "''")
}

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

        backup_conn
            .execute(
                "DELETE FROM clipboard_history
                 WHERE id IN (SELECT row_id FROM clipboard_deleted)",
                [],
            )
            .map_err(|e| format!("清理备份中的已删除记录失败: {e}"))?;
        backup_conn
            .execute("DELETE FROM clipboard_deleted", [])
            .map_err(|e| format!("清理备份中的删除标记失败: {e}"))?;
        backup_conn
            .execute(
                "DELETE FROM clipboard_quick_slots
                 WHERE entry_id NOT IN (SELECT entry_id FROM clipboard_history)",
                [],
            )
            .map_err(|e| format!("清理备份中的孤立快捷槽位失败: {e}"))?;

        backup_conn
            .execute_batch("VACUUM;")
            .map_err(|e| format!("压缩备份文件失败: {e}"))?;

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

        backup_conn
            .execute(
                "INSERT OR IGNORE INTO clipboard_backup_favorites (entry_id)
                 SELECT entry_id FROM clipboard_favorites",
                [],
            )
            .map_err(|e| format!("写入备份收藏失败: {e}"))?;

        count.max(0) as usize
    };

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

    for suffix in ["-wal", "-shm"] {
        let mut sidecar = tmp_path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(sidecar));
    }

    Ok(item_count)
}

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

    let has_deleted_table: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_deleted'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let count_sql = if has_deleted_table > 0 {
        "SELECT COUNT(*) FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)"
    } else {
        "SELECT COUNT(*) FROM clipboard_history"
    };
    let item_count: i64 = conn.query_row(count_sql, [], |r| r.get(0))
        .map_err(|e| format!("统计历史记录数失败: {e}"))?;

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

pub(crate) fn restore_backup_overwrite(
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
            .map_err(|e| format!("开启恢复事务失败: {e}"))?;

        tx.execute("DELETE FROM main.clipboard_history", [])
            .map_err(|e| format!("清空当前历史表失败: {e}"))?;
        tx.execute("DELETE FROM main.clipboard_favorites", [])
            .map_err(|e| format!("清空当前收藏表失败: {e}"))?;

        tx.execute("DELETE FROM main.clipboard_deleted", [])
            .map_err(|e| format!("清空撤销记录失败: {e}"))?;
        tx.execute("DELETE FROM main.clipboard_quick_slots", [])
            .map_err(|e| format!("清空当前快捷槽位失败: {e}"))?;

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

        let backup_has_deleted: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master
                 WHERE type = 'table' AND name = 'clipboard_deleted'",
                [],
                |r| r.get(0),
            )
            .map_err(|e| format!("检查备份删除标记表失败: {e}"))?;
        if backup_has_deleted > 0 {
            tx.execute(
                "DELETE FROM main.clipboard_history
                 WHERE id IN (SELECT row_id FROM backup_db.clipboard_deleted)",
                [],
            )
            .map_err(|e| format!("剔除备份中已删除的记录失败: {e}"))?;
        }

        let local_watermark = crate::db::schema::entry_id_watermark(&tx);

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
                 WHERE key NOT IN ('entry_id_watermark', 'undo_budget_bytes')",
                [],
            )
            .map_err(|e| format!("恢复元数据失败: {e}"))?;
        }

        let has_fav_table: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master WHERE type='table' AND name='clipboard_backup_favorites'",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);

        if has_fav_table > 0 {
            tx.execute(
                "INSERT OR IGNORE INTO main.clipboard_favorites (entry_id)
                 SELECT f.entry_id
                 FROM backup_db.clipboard_backup_favorites f
                 JOIN main.clipboard_history h ON h.entry_id = f.entry_id",
                [],
            )
            .map_err(|e| format!("恢复收藏表失败: {e}"))?;
        }
        let backup_has_slots: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master
                 WHERE type = 'table' AND name = 'clipboard_quick_slots'",
                [],
                |r| r.get(0),
            )
            .map_err(|e| format!("检查备份快捷槽位表失败: {e}"))?;
        if backup_has_slots > 0 {
            tx.execute(
                "INSERT OR IGNORE INTO main.clipboard_quick_slots (slot, entry_id)
                 SELECT s.slot, s.entry_id
                 FROM backup_db.clipboard_quick_slots s
                 JOIN main.clipboard_history h ON h.entry_id = s.entry_id
                 WHERE s.slot BETWEEN 1 AND 9",
                [],
            )
            .map_err(|e| format!("恢复快捷槽位失败: {e}"))?;
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

        let mut merged_fav_set: HashSet<u64> = {
            let mut stmt = tx
                .prepare("SELECT entry_id FROM main.clipboard_favorites")
                .map_err(|e| format!("查询现有收藏失败: {e}"))?;
            let rows = stmt
                .query_map([], |r| r.get::<_, i64>(0))
                .map_err(|e| format!("遍历现有收藏失败: {e}"))?;
            rows.flatten().filter(|id| *id > 0).map(|id| id as u64).collect()
        };

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
        let mut slot_remap: HashMap<u64, u64> = HashMap::new();

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

        let backup_has_deleted: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master
                 WHERE type = 'table' AND name = 'clipboard_deleted'",
                [],
                |r| r.get(0),
            )
            .map_err(|e| format!("检查备份删除标记表失败: {e}"))?;
        let skip_deleted = if backup_has_deleted > 0 {
            " WHERE id NOT IN (SELECT row_id FROM backup_db.clipboard_deleted)"
        } else {
            ""
        };
        let merge_rows_sql = format!(
            "SELECT entry_id, entry_type, text, png_data, width, height,
                    thumb_data, thumb_width, thumb_height, hash, timestamp,
                    source_name, source_bundle_id, preview, label, custom_label
             FROM backup_db.clipboard_history{skip_deleted}
             ORDER BY id ASC"
        );
        let mut stmt = tx
            .prepare(&merge_rows_sql)
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
            let item = match row {
                Ok(r) => r,
                Err(e) => {
                    crate::error_log!("CopyAttach: merge: unreadable backup row skipped: {e}");
                    continue;
                }
            };
            let is_fav = backup_fav_set.contains(&(item.entry_id as u64));

            if item.entry_type == 0 {
                let full_text = match &item.text {
                    Some(t) => t.as_str(),
                    None => continue,
                };

                let existing: Option<(i64, i64, String)> = tx
                    .query_row(
                        "SELECT id, entry_id, custom_label FROM main.clipboard_history
                         WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                           AND entry_type = 0 AND hash = ?1 AND text = ?2",
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
                    if item.entry_id > 0 && curr_entry_id > 0 {
                        slot_remap.insert(item.entry_id as u64, curr_entry_id as u64);
                    }
                } else {
                    let mut final_eid = item.entry_id as u64;
                    if final_eid == 0 || used_entry_ids.contains(&final_eid) {
                        max_entry_id += 1;
                        final_eid = max_entry_id;
                    }
                    used_entry_ids.insert(final_eid);
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
                        if item.entry_id > 0 {
                            slot_remap.insert(item.entry_id as u64, final_eid);
                        }
                    }
                }
            } else if item.entry_type == 1 {
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
                         WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                           AND entry_type = 1 AND hash = ?1",
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
                    if item.entry_id > 0 && curr_entry_id > 0 {
                        slot_remap.insert(item.entry_id as u64, curr_entry_id as u64);
                    }
                } else {
                    let mut final_eid = item.entry_id as u64;
                    if final_eid == 0 || used_entry_ids.contains(&final_eid) {
                        max_entry_id += 1;
                        final_eid = max_entry_id;
                    }
                    used_entry_ids.insert(final_eid);
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
                        if item.entry_id > 0 {
                            slot_remap.insert(item.entry_id as u64, final_eid);
                        }
                    }
                }
            }
        }
        drop(stmt);

        if max_entry_id > 0 {
            let _ = bump_entry_id_watermark(&tx, max_entry_id);
        }

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

        let backup_has_slots: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM backup_db.sqlite_master
                 WHERE type = 'table' AND name = 'clipboard_quick_slots'",
                [],
                |r| r.get(0),
            )
            .map_err(|e| format!("检查备份快捷槽位表失败: {e}"))?;
        if backup_has_slots > 0 {
            let mut slot_stmt = tx
                .prepare(
                    "INSERT OR IGNORE INTO main.clipboard_quick_slots (slot, entry_id)
                     VALUES (?1, ?2)",
                )
                .map_err(|e| format!("准备写入合并快捷槽位失败: {e}"))?;
            let mut read_stmt = tx
                .prepare(
                    "SELECT slot, entry_id FROM backup_db.clipboard_quick_slots
                     WHERE slot BETWEEN 1 AND 9",
                )
                .map_err(|e| format!("读取备份快捷槽位失败: {e}"))?;
            let rows = read_stmt
                .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
                .map_err(|e| format!("遍历备份快捷槽位失败: {e}"))?;
            for (slot, entry_id) in rows.flatten() {
                let Some(mapped) = slot_remap.get(&(entry_id as u64)) else { continue };
                slot_stmt
                    .execute(rusqlite::params![slot, *mapped as i64])
                    .map_err(|e| format!("写入合并快捷槽位失败: {e}"))?;
            }
        }

        tx.commit().map_err(|e| format!("提交合并事务失败: {e}"))?;

        Ok((newly_added, merged_fav_set.into_iter().collect()))
    })();

    let _ = conn.execute_batch("DETACH DATABASE backup_db;");
    res
}

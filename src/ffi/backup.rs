use std::ffi::{c_char, c_int, CStr, CString};
use std::path::Path;
use std::sync::atomic::Ordering;

use crate::backend::try_backend;
use crate::db::backup::{export_backup, inspect_backup, restore_backup_merge, restore_backup_overwrite};
use crate::db::{entry_id_watermark, load_history_from_db};
use super::parse_ids_str;

/// Export full database and favorites to a standalone `.cabackup` file.
///
/// Returns non-negative item count on success, or negative error code on failure:
/// -1 = backend unavailable or invalid path
/// -2 = database error or export failure
#[no_mangle]
pub extern "C" fn clipboard_export_backup(
    target_path: *const c_char,
    favorite_ids_str: *const c_char,
) -> c_int {
    if target_path.is_null() {
        return -1;
    }
    let path_str = match unsafe { CStr::from_ptr(target_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    let path = Path::new(path_str);
    let fav_ids = parse_ids_str(favorite_ids_str);

    let b = match try_backend() {
        Some(b) => b,
        None => return -1,
    };

    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned during backup export: {e}");
            return -2;
        }
    };

    match export_backup(&conn, path, &fav_ids) {
        Ok(count) => {
            crate::debug_log!("CopyAttach: exported backup to {} ({} items)", path.display(), count);
            count as c_int
        }
        Err(e) => {
            crate::error_log!("CopyAttach: failed to export backup to {}: {e}", path.display());
            -2
        }
    }
}

/// Pre-inspect a backup file.
///
/// Populates `out_item_count`, `out_fav_count`, and `out_timestamp`.
/// Returns 1 on success, 0 on failure or invalid format.
#[no_mangle]
pub extern "C" fn clipboard_inspect_backup(
    backup_path: *const c_char,
    out_item_count: *mut c_int,
    out_fav_count: *mut c_int,
    out_timestamp: *mut u64,
) -> c_int {
    if backup_path.is_null() || out_item_count.is_null() || out_fav_count.is_null() || out_timestamp.is_null() {
        return 0;
    }
    let path_str = match unsafe { CStr::from_ptr(backup_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let path = Path::new(path_str);

    match inspect_backup(path) {
        Ok(info) => {
            unsafe {
                *out_item_count = info.item_count as c_int;
                *out_fav_count = info.favorite_count as c_int;
                *out_timestamp = info.timestamp;
            }
            1
        }
        Err(e) => {
            crate::error_log!("CopyAttach: inspect backup failed for {}: {e}", path.display());
            0
        }
    }
}

/// Overwrite active database with backup data.
///
/// On success, outputs comma-separated restored favorite IDs in `out_fav_str`
/// (caller must free with `clipboard_free_string`) and returns restored item count (>= 0).
/// On failure, returns negative error code.
#[no_mangle]
pub extern "C" fn clipboard_restore_backup_overwrite(
    backup_path: *const c_char,
    out_fav_str: *mut *mut c_char,
) -> c_int {
    if backup_path.is_null() || out_fav_str.is_null() {
        return -1;
    }
    let path_str = match unsafe { CStr::from_ptr(backup_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    let path = Path::new(path_str);

    let b = match try_backend() {
        Some(b) => b,
        None => return -1,
    };

    let mut conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned during restore overwrite: {e}");
            return -2;
        }
    };

    let mut hist = b.history.lock().unwrap();

    match restore_backup_overwrite(&mut conn, path) {
        Ok((count, fav_ids)) => {
            // Clear undo stack since historical references are invalidated
            b.deleted_stack.lock().unwrap().clear();

            // Reload memory history from newly populated database
            let threshold = b.cleanup_threshold.load(Ordering::Relaxed);
            *hist = load_history_from_db(&conn, threshold);

            // Re-align monotonic entry_id counter
            let max_loaded = hist.iter().map(|e| e.entry_id()).max().unwrap_or(0);
            let watermark = entry_id_watermark(&conn);
            let next = max_loaded.max(watermark) + 1;
            crate::backend::prime_entry_id(next);

            // Publish change so UI refreshes immediately
            crate::backend::mark_history_changed();

            let fav_csv = fav_ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let c_fav = CString::new(fav_csv).unwrap_or_default();
            unsafe {
                *out_fav_str = c_fav.into_raw();
            }

            crate::debug_log!(
                "CopyAttach: restored backup overwrite from {} ({} items, {} favorites)",
                path.display(),
                count,
                fav_ids.len()
            );
            count as c_int
        }
        Err(e) => {
            crate::error_log!("CopyAttach: restore backup overwrite failed: {e}");
            -2
        }
    }
}

/// Merge records from backup into active database.
///
/// On success, outputs comma-separated consolidated favorite IDs in `out_fav_str`
/// (caller must free with `clipboard_free_string`) and returns newly added item count (>= 0).
/// On failure, returns negative error code.
#[no_mangle]
pub extern "C" fn clipboard_restore_backup_merge(
    backup_path: *const c_char,
    current_fav_str: *const c_char,
    out_fav_str: *mut *mut c_char,
) -> c_int {
    if backup_path.is_null() || out_fav_str.is_null() {
        return -1;
    }
    let path_str = match unsafe { CStr::from_ptr(backup_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };
    let path = Path::new(path_str);
    let curr_favs = parse_ids_str(current_fav_str);

    let b = match try_backend() {
        Some(b) => b,
        None => return -1,
    };

    let mut conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned during restore merge: {e}");
            return -2;
        }
    };

    let mut hist = b.history.lock().unwrap();

    match restore_backup_merge(&mut conn, path, &curr_favs) {
        Ok((added_count, merged_fav_ids)) => {
            let threshold = b.cleanup_threshold.load(Ordering::Relaxed);
            *hist = load_history_from_db(&conn, threshold);

            let max_loaded = hist.iter().map(|e| e.entry_id()).max().unwrap_or(0);
            let watermark = entry_id_watermark(&conn);
            let next = max_loaded.max(watermark) + 1;
            crate::backend::prime_entry_id(next);

            crate::backend::mark_history_changed();

            let fav_csv = merged_fav_ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let c_fav = CString::new(fav_csv).unwrap_or_default();
            unsafe {
                *out_fav_str = c_fav.into_raw();
            }

            crate::debug_log!(
                "CopyAttach: restored backup merge from {} ({} new items, {} total favorites)",
                path.display(),
                added_count,
                merged_fav_ids.len()
            );
            added_count as c_int
        }
        Err(e) => {
            crate::error_log!("CopyAttach: restore backup merge failed: {e}");
            -2
        }
    }
}

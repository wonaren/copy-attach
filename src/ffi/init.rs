use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::backend::{set_backend, Backend, DEFAULT_CLEANUP_THRESHOLD, MAX_CLEANUP_THRESHOLD, MIN_CLEANUP_THRESHOLD};
use crate::db::{bump_entry_id_watermark, ensure_history_table, entry_id_watermark, get_persist_dir, load_history_from_db, migrate_from_json_to_db, open_db, seed_first_launch_tips, trim_db_history};
use crate::ignore::IgnoreRules;
use crate::monitor::clipboard_monitor;
use crate::types::ClipboardEntry;

const INIT_OK: c_int = 1;
const INIT_RETRYABLE: c_int = 0;
const INIT_CORRUPT: c_int = -1;
const INIT_PERMANENT_ENV: c_int = -2;

#[no_mangle]
pub extern "C" fn clipboard_recover_corrupt_db() -> c_int {
    let Some(dir) = get_persist_dir() else {
        crate::error_log!("CopyAttach: recover_corrupt_db: persist dir unavailable");
        return 0;
    };
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let main = dir.join("history.db");
    let backup = dir.join(format!("history.db.corrupt-{stamp}"));
    if let Err(e) = std::fs::rename(&main, &backup) {
        crate::error_log!("CopyAttach: recover_corrupt_db: rename {} failed: {e}", main.display());
        return 0;
    }
    for suffix in ["-wal", "-shm"] {
        let side = dir.join(format!("history.db{suffix}"));
        if side.exists() {
            let side_backup = dir.join(format!("history.db.corrupt-{stamp}{suffix}"));
            if let Err(e) = std::fs::rename(&side, &side_backup) {
                crate::error_log!("CopyAttach: recover_corrupt_db: rename {} failed: {e}", side.display());
            }
        }
    }
    crate::error_log!("CopyAttach: corrupt database moved to {}", backup.display());
    1
}

#[no_mangle]
pub extern "C" fn clipboard_init_with_threshold_and_favorites(
    threshold: c_int,
    favorite_ids_csv: *const c_char,
) -> c_int {
    let legacy = super::parse_ids_str(favorite_ids_csv);
    clipboard_init_inner(if threshold > 0 { Some(threshold) } else { None }, &legacy)
}

fn clipboard_init_inner(threshold: Option<c_int>, legacy_favorites: &[u64]) -> c_int {
    let startup_threshold = threshold
        .map(|t| (t.max(0) as usize).clamp(MIN_CLEANUP_THRESHOLD, MAX_CLEANUP_THRESHOLD))
        .unwrap_or(DEFAULT_CLEANUP_THRESHOLD);

    if let Some(b) = crate::backend::try_backend() {
        if !legacy_favorites.is_empty() {
            let imported = match b.db.lock() {
                Ok(conn) => match crate::db::import_favorites(&conn, legacy_favorites) {
                    Ok(_) => match crate::db::load_favorites(&conn) {
                        Ok(set) => set,
                        Err(()) => {
                            crate::error_log!("CopyAttach: favorites unreadable after legacy import; retryable");
                            return INIT_RETRYABLE;
                        }
                    },
                    Err(()) => {
                        crate::error_log!("CopyAttach: legacy favorite import failed on resumed init; retryable");
                        return INIT_RETRYABLE;
                    }
                },
                Err(e) => {
                    crate::error_log!("CopyAttach: DB mutex poisoned importing legacy favorites: {e}");
                    return INIT_RETRYABLE;
                }
            };
            if let Ok(mut favorites) = b.favorites.lock() {
                *favorites = imported;
            }
        }
        if b.running.swap(true, Ordering::SeqCst) {
            return 1;
        }
        let handle = thread::spawn({
            let history = Arc::clone(&b.history);
            let running = Arc::clone(&b.running);
            let source_app = Arc::clone(&b.source_app);
            let db = Arc::clone(&b.db);
            let pasteboard_event_lock = Arc::clone(&b.pasteboard_event_lock);
            let pending_self_write = Arc::clone(&b.pending_self_write);
            let cleanup_threshold = Arc::clone(&b.cleanup_threshold);
            let ignore_rules = Arc::clone(&b.ignore_rules);
            let favorites = Arc::clone(&b.favorites);
            move || clipboard_monitor(history, running, source_app, db,
                pasteboard_event_lock, pending_self_write,
                cleanup_threshold, ignore_rules, favorites)
        });
        *b.monitor_handle.lock().unwrap() = Some(handle);
        return 1;
    }

    let mut conn = match open_db() {
        Ok(c) => c,
        Err(crate::db::DbFailure::Corrupt) => {
            crate::error_log!("CopyAttach: database is not usable, init aborted");
            return INIT_CORRUPT;
        }
        Err(crate::db::DbFailure::PermanentEnvironment) => {
            crate::error_log!("CopyAttach: database cannot be used in this environment, init aborted");
            return INIT_PERMANENT_ENV;
        }
        Err(crate::db::DbFailure::Transient) => {
            crate::error_log!("CopyAttach: database temporarily unavailable, init will retry");
            return INIT_RETRYABLE;
        }
    };

    if let Err(e) = ensure_history_table(&conn) {
        match crate::db::classify_db_error(&e) {
            crate::db::DbFailure::Corrupt => {
                crate::error_log!("CopyAttach: database is corrupt, init aborted: {e}");
                return INIT_CORRUPT;
            }
            crate::db::DbFailure::PermanentEnvironment => {
                crate::error_log!("CopyAttach: database is read-only or unusable: {e}");
                return INIT_PERMANENT_ENV;
            }
            crate::db::DbFailure::Transient => {
                crate::error_log!("CopyAttach: failed to create table (retryable): {e}");
                return INIT_RETRYABLE;
            }
        }
    }

    migrate_from_json_to_db(&mut conn);

    seed_first_launch_tips(&conn);

    if !legacy_favorites.is_empty() {
        match crate::db::import_favorites(&conn, legacy_favorites) {
            Ok(imported) => crate::debug_log!(
                "CopyAttach: imported {imported} legacy favorite(s) before the startup trim"
            ),
            Err(()) => {
                crate::error_log!("CopyAttach: legacy favorite import failed; init retryable so the caller keeps its list");
                return INIT_RETRYABLE;
            }
        }
    }

    if let Err(()) = crate::db::prune_orphan_favorites(&conn) {
        crate::error_log!("CopyAttach: orphan-favorite cleanup failed; stale ids may linger");
    }
    let favorites_set = match crate::db::load_favorites(&conn) {
        Ok(set) => set,
        Err(()) => {
            crate::error_log!("CopyAttach: favorites unreadable; init retryable instead of trimming unprotected");
            return INIT_RETRYABLE;
        }
    };

    let saved = load_history_from_db(&conn, startup_threshold);
    if trim_db_history(&conn, startup_threshold).is_err() {
        crate::error_log!("CopyAttach: startup trim failed; the table stays over the load cap until the next capture's transactional trim");
    }

    {
        let max_loaded = saved.iter().map(|e| match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        }).max().unwrap_or(0);
        let watermark = entry_id_watermark(&conn);
        let next = max_loaded.max(watermark) + 1;
        crate::backend::prime_entry_id(next);
        if watermark < max_loaded && bump_entry_id_watermark(&conn, max_loaded).is_err() {
            crate::error_log!("CopyAttach: entry-id watermark not recorded; ids stay safe only while history is non-empty");
        }
    }

    let undo_limit = match crate::db::load_undo_limit(&conn) {
        Ok(v) => v,
        Err(()) => {
            crate::error_log!("CopyAttach: undo limit unreadable; init retryable instead of guessing");
            return INIT_RETRYABLE;
        }
    };

    if crate::db::purge_expired_deleted_rows(&conn, undo_limit).is_err() {
        crate::error_log!("CopyAttach: startup deleted-row sweep failed; retried after the next delete");
    }

    let history: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(saved));
    let running = Arc::new(AtomicBool::new(true));
    let source_app = Arc::new(Mutex::new(crate::types::SourceApp::default()));
    let pasteboard_event_lock = Arc::new(Mutex::new(()));
    let pending_self_write = Arc::new(Mutex::new(None));
    let db = Arc::new(Mutex::new(conn));
    let undo_limit = Arc::new(AtomicI64::new(undo_limit));
    let cleanup_threshold = Arc::new(AtomicUsize::new(startup_threshold));
    let ignore_rules = Arc::new(Mutex::new(IgnoreRules::default()));
    let last_restored_id = Arc::new(AtomicU64::new(0));
    let favorites = Arc::new(Mutex::new(favorites_set));

    let backend = Backend {
        history: Arc::clone(&history),
        running: Arc::clone(&running),
        monitor_handle: Mutex::new(None),
        source_app: Arc::clone(&source_app),
        pasteboard_event_lock: Arc::clone(&pasteboard_event_lock),
        pending_self_write: Arc::clone(&pending_self_write),
        db: Arc::clone(&db),
        cleanup_threshold: Arc::clone(&cleanup_threshold),
        ignore_rules: Arc::clone(&ignore_rules),
        undo_limit: Arc::clone(&undo_limit),
        last_restored_id: Arc::clone(&last_restored_id),
        favorites: Arc::clone(&favorites),
    };

    if set_backend(backend).is_err() {
        return 0;
    }

    super::paste::purge_stale_paste_images();

    super::paste::purge_stale_drag_images();

    crate::backend::purge_legacy_undo_payload_dir();

    #[cfg(not(feature = "stress-test"))]
    if let Some(b) = crate::backend::try_backend() {
        spawn_compaction_if_fragmented(b);
    }

    #[cfg(not(feature = "stress-test"))]
    if let Some(b) = crate::backend::try_backend() {
        spawn_metadata_migration(b);
    }

    let handle = thread::spawn(|| clipboard_monitor(
        history, running, source_app, db,
        pasteboard_event_lock, pending_self_write,
        cleanup_threshold, ignore_rules, favorites,
    ));

    if let Some(b) = crate::backend::try_backend() {
        if let Ok(mut h) = b.monitor_handle.lock() {
            *h = Some(handle);
        }
    }

    1
}

#[cfg(not(feature = "stress-test"))]
fn spawn_metadata_migration(b: &'static crate::backend::Backend) {
    let version: i32 = match b.db.lock() {
        Ok(c) => match c.query_row("PRAGMA user_version", [], |r| r.get(0)) {
            Ok(v) => v,
            Err(_) => return,
        },
        Err(_) => return,
    };
    if version >= crate::db::METADATA_VERSION {
        return;
    }
    let hash_pending = version < 3;
    let thumb_pending = version < 4;
    let ids: Vec<i64> = match b.db.lock() {
        Ok(c) => {
            let mut stmt = match c.prepare(
                "SELECT id FROM clipboard_history WHERE entry_type = 1
                 ORDER BY width * height DESC, LENGTH(png_data) DESC",
            ) {
                Ok(s) => s,
                Err(e) => {
                    crate::error_log!("CopyAttach: metadata migration: cannot list image rows: {e}");
                    return;
                }
            };
            let rows = match stmt.query_map([], |row| row.get::<_, i64>(0)) {
                Ok(r) => r,
                Err(e) => {
                    crate::error_log!("CopyAttach: metadata migration: cannot read image rows: {e}");
                    return;
                }
            };
            rows.filter_map(|r| r.ok()).collect()
        }
        Err(_) => return,
    };
    if ids.is_empty() {
        if let Ok(c) = b.db.lock() {
            let _ = c.pragma_update(None, "user_version", crate::db::METADATA_VERSION);
        }
        return;
    }
    std::thread::spawn(move || {
        let mut updated = 0usize;
        let mut thumbs = 0usize;
        let mut failed = 0usize;
        let mut thumb_blob: Vec<u8> = Vec::new();
        let mut thumb_scratch: Vec<u8> = Vec::new();
        for id in ids {
            if !b.running.load(Ordering::SeqCst) {
                return;
            }
            let mut new_hash: Option<u64> = None;
            if hash_pending {
                match b.db.lock() {
                    Ok(c) => match crate::db::migrate_one_image_row(&c, id) {
                        Ok(h) => {
                            updated += 1;
                            new_hash = Some(h);
                        }
                        Err(()) => failed += 1,
                    },
                    Err(_) => failed += 1,
                }
            }
            let mut new_dims: Option<(u32, u32)> = None;
            if thumb_pending {
                match b.db.lock() {
                    Ok(c) => match crate::db::migrate_one_thumbnail_row(&c, id, &mut thumb_blob, &mut thumb_scratch) {
                        Ok(dims) => {
                            if dims.is_some() {
                                thumbs += 1;
                            }
                            new_dims = dims;
                        }
                        Err(()) => failed += 1,
                    },
                    Err(_) => failed += 1,
                }
            }
            if new_hash.is_some() || new_dims.is_some() {
                if let Ok(mut hist) = b.history.lock() {
                    for entry in hist.iter_mut() {
                        if let crate::types::ClipboardEntry::Image {
                            db_id, hash: h, thumb_width, thumb_height, ..
                        } = entry {
                            if *db_id == id {
                                if let Some(hash) = new_hash {
                                    *h = hash;
                                }
                                if let Some((tw, th)) = new_dims {
                                    *thumb_width = tw;
                                    *thumb_height = th;
                                }
                                break;
                            }
                        }
                    }
                    crate::backend::mark_history_changed();
                }
            }
        }
        crate::backend::mark_pages_reusable(thumb_blob.as_ptr(), thumb_blob.capacity());
        crate::backend::mark_pages_reusable(thumb_scratch.as_ptr(), thumb_scratch.capacity());
        if let Ok(c) = b.db.lock() {
            if let Err(e) = c.pragma_update(None, "user_version", crate::db::METADATA_VERSION) {
                crate::error_log!("CopyAttach: metadata migration: failed to stamp user_version: {e}");
            }
        }
        crate::debug_log!("CopyAttach: metadata migration complete: {updated} rows hashed, {thumbs} thumbnails re-encoded, {failed} failed");
    });
}

#[no_mangle]
pub extern "C" fn clipboard_cleanup() {
    if let Some(b) = crate::backend::try_backend() {
        b.running.store(false, Ordering::SeqCst);
        if let Ok(mut handle) = b.monitor_handle.lock() {
            if let Some(h) = handle.take() {
                h.thread().unpark();
                let _ = h.join();
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn clipboard_set_debug_logging(enabled: c_int) -> c_int {
    crate::backend::set_debug_logging(enabled != 0);
    1
}

#[no_mangle]
pub extern "C" fn clipboard_is_debug_logging() -> c_int {
    c_int::from(crate::backend::debug_log_enabled())
}

#[no_mangle]
pub extern "C" fn clipboard_set_source_app(name: *const c_char, bundle_id: *const c_char, pid: i32) {
    let name = if name.is_null() { String::new() } else {
        unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned()
    };
    let bundle_id = if bundle_id.is_null() { String::new() } else {
        unsafe { CStr::from_ptr(bundle_id) }.to_string_lossy().into_owned()
    };
    if let Some(b) = crate::backend::try_backend() {
        let mut src = b.source_app.lock().unwrap();
        src.name = name;
        src.bundle_id = bundle_id;
        src.pid = pid;
    }
}

#[no_mangle]
pub extern "C" fn clipboard_set_ignore_rules(
    app_bundle_ids: *const c_char,
    ignore_text: c_int,
    ignore_images: c_int,
    min_text_characters: c_int,
    ignore_sensitive: c_int,
) -> c_int {
    if app_bundle_ids.is_null() || min_text_characters < 0 {
        return 0;
    }
    let encoded = match unsafe { CStr::from_ptr(app_bundle_ids) }.to_str() {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let rules = IgnoreRules::from_encoded(
        encoded,
        ignore_text != 0,
        ignore_images != 0,
        match min_text_characters {
            0 => None,
            value => Some(value as usize),
        },
        ignore_sensitive != 0,
    );
    match crate::backend::try_backend() {
        Some(backend) => {
            *backend.ignore_rules.lock().unwrap() = rules;
            1
        }
        None => 0,
    }
}

#[cfg(not(feature = "stress-test"))]
fn spawn_compaction_if_fragmented(b: &'static crate::backend::Backend) {
    const MIN_FULL_VACUUM_PAGES: i64 = 10_000;
    const MIN_FULL_VACUUM_SHARE_PCT: i64 = 20;
    const MIN_INCREMENTAL_PAGES: i64 = 1_024;
    const INCREMENTAL_BATCH_PAGES: i64 = 1_024;

    let (freelist, total, auto_vacuum) = {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: compaction check could not lock the DB: {e}");
                return;
            }
        };
        let (freelist, total, mode) = match (
            crate::db::freelist_pages(&conn),
            conn.query_row("PRAGMA page_count", [], |r| r.get::<_, i64>(0)).ok(),
            crate::db::auto_vacuum_mode(&conn),
        ) {
            (Some(f), Some(t), Some(m)) => (f, t, m),
            _ => {
                crate::error_log!("CopyAttach: compaction check could not read the DB stats");
                return;
            }
        };
        (freelist, total, mode)
    };
    if total <= 0 {
        return;
    }

    if auto_vacuum == 2 {
        if freelist < MIN_INCREMENTAL_PAGES {
            return;
        }
        crate::debug_log!(
            "CopyAttach: reclaiming {freelist} free pages incrementally (batch {INCREMENTAL_BATCH_PAGES})"
        );
        std::thread::spawn(move || loop {
            if !b.running.load(Ordering::SeqCst) {
                return;
            }
            let freed = {
                let conn = match b.db.lock() {
                    Ok(c) => c,
                    Err(e) => {
                        crate::error_log!("CopyAttach: incremental reclaim could not lock the DB: {e}");
                        return;
                    }
                };
                match crate::db::reclaim_free_pages(&conn, INCREMENTAL_BATCH_PAGES) {
                    Ok(n) => n,
                    Err(()) => return,
                }
            };
            if freed <= 0 {
                crate::debug_log!("CopyAttach: incremental reclaim complete");
                return;
            }
            thread::sleep(std::time::Duration::from_millis(20));
        });
        return;
    }

    if freelist < MIN_FULL_VACUUM_PAGES {
        return;
    }
    if freelist * 100 < total * MIN_FULL_VACUUM_SHARE_PCT {
        crate::debug_log!(
            "CopyAttach: skipping compaction, freelist={freelist}/{total} pages is under {MIN_FULL_VACUUM_SHARE_PCT}%"
        );
        return;
    }

    crate::debug_log!(
        "CopyAttach: converting the database to incremental auto-vacuum (freelist {freelist}/{total} pages)"
    );
    std::thread::spawn(move || {
        let guard = match b.db.lock() {
            Ok(g) => g,
            Err(e) => {
                crate::error_log!("CopyAttach: compaction could not lock the DB: {e}");
                return;
            }
        };
        if !b.running.load(Ordering::SeqCst) {
            return;
        }
        let started = std::time::Instant::now();
        if crate::db::convert_to_incremental_auto_vacuum(&guard).is_ok() {
            crate::debug_log!(
                "CopyAttach: conversion complete in {} ms",
                started.elapsed().as_millis()
            );
        }
    });
}

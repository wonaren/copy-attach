use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::backend::{set_backend, Backend, DEFAULT_CLEANUP_THRESHOLD};
use crate::db::{bump_entry_id_watermark, ensure_history_table, entry_id_watermark, get_persist_dir, load_history_from_db, migrate_from_json_to_db, open_db, seed_first_launch_tips, trim_db_history};
use crate::ignore::IgnoreRules;
use crate::monitor::clipboard_monitor;
use crate::types::ClipboardEntry;

// init return codes, mirrored by Swift's ClipboardBackend.StartResult:
//   1  = started
//   0  = retryable (transient; the UI retries on a cooldown)
//  -1  = corrupt database (replacing the file is the only fix)
//  -2  = environment failure (read-only / permissions / disk full / path not
//        openable). A classification, not a terminal state: the caller keeps
//        retrying with backoff, so the app auto-recovers once the user fixes
//        the environment out of band. Distinct from -1: the database is
//        intact, so offering a "back up and rebuild" would needlessly destroy
//        a good file.
const INIT_OK: c_int = 1;
const INIT_RETRYABLE: c_int = 0;
const INIT_CORRUPT: c_int = -1;
const INIT_PERMANENT_ENV: c_int = -2;

/// Move a corrupt `history.db` (plus WAL/SHM sidecars) aside as
/// `history.db.corrupt-<unix-secs>` so the next `clipboard_init` starts
/// with a fresh database. The user keeps the old file for manual salvage.
/// Returns 1 on success, 0 if the main file could not be renamed. Must only
/// be called while no backend holds a connection (i.e. after init returned -1).
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
    // Sidecars carry pages of the same corrupt image; a stale WAL replayed
    // onto a fresh file would re-corrupt it. Their absence is normal.
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

/// Set only after Swift has cryptographically verified a device-bound lease.
/// Invalid values are rejected instead of being treated as licensed.
#[no_mangle]
pub extern "C" fn clipboard_set_runtime_entitlement(state: c_int) -> c_int {
    if !(0..=2).contains(&state) { return 0; }
    crate::backend::RUNTIME_ENTITLEMENT.store(state as usize, Ordering::SeqCst);
    if state == 0 {
        if let Some(b) = crate::backend::try_backend() {
            b.running.store(false, Ordering::SeqCst);
        }
    }
    1
}

#[no_mangle]
pub extern "C" fn clipboard_init() -> c_int {
    if crate::backend::RUNTIME_ENTITLEMENT.load(Ordering::SeqCst) == 0 {
        crate::error_log!("CopyAttach: clipboard_init rejected: runtime entitlement is denied");
        return 0;
    }
    // OnceLock intentionally retains the backend for process lifetime. A
    // license transition may stop and later re-enable monitoring, so resume
    // the existing backend instead of attempting to replace the singleton.
    if let Some(b) = crate::backend::try_backend() {
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
            move || clipboard_monitor(history, running, source_app, db,
                pasteboard_event_lock, pending_self_write,
                cleanup_threshold, ignore_rules)
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
                // Replacing the file is the only fix; the user decides.
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

    // One-time onboarding: seed usage tips (source icon = CopyAttach) only when
    // the history is empty. Runs before load so the tips are picked up as
    // normal rows; a no-op for any existing user.
    seed_first_launch_tips(&conn);

    // First determine the load limit; then load, THEN trim — otherwise the
    // trim below the load limit discards entries before we can read them.
    #[cfg(feature = "stress-test")]
    const INIT_LOAD: usize = 10000;
    #[cfg(not(feature = "stress-test"))]
    const INIT_LOAD: usize = DEFAULT_CLEANUP_THRESHOLD;

    // `load_history_from_db` already applies `LIMIT ?` with the same bound,
    // so the returned Vec is at most INIT_LOAD entries.
    let saved = load_history_from_db(&conn, INIT_LOAD);
    if trim_db_history(&conn, INIT_LOAD).is_err() {
        crate::error_log!("CopyAttach: startup trim failed; the table stays over the load cap until the next capture's transactional trim");
    }

    // Prime the entry-id counter above every id this database has ever issued.
    //
    // The loaded rows are NOT sufficient on their own: after a clear (or after
    // a trim that removed everything) nothing is loaded, and priming from 0
    // would restart ids at 1 — walking straight through the ids recorded in
    // Swift's Favorites list, so old favorites would light up on unrelated new
    // captures. The persisted watermark is what survives a clear.
    //
    // Loaded ids still contribute (a database written by an older build has no
    // watermark yet), and `prime_entry_id` is monotonic, so neither source can
    // move the counter backwards.
    {
        let max_loaded = saved.iter().map(|e| match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        }).max().unwrap_or(0);
        let watermark = entry_id_watermark(&conn);
        let next = max_loaded.max(watermark) + 1;
        crate::backend::prime_entry_id(next);
        if watermark < max_loaded {
            // Adopt this database's existing ids into the watermark so the next
            // launch needs no loaded rows to stay collision-free.
            if bump_entry_id_watermark(&conn, max_loaded).is_err() {
                crate::error_log!("CopyAttach: entry-id watermark not recorded; ids stay safe only while history is non-empty");
            }
        }
    }

    let history: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(saved));
    let running = Arc::new(AtomicBool::new(true));
    let source_app = Arc::new(Mutex::new(crate::types::SourceApp::default()));
    let pasteboard_event_lock = Arc::new(Mutex::new(()));
    let pending_self_write = Arc::new(Mutex::new(None));
    let db = Arc::new(Mutex::new(conn));
    let cleanup_threshold = Arc::new(AtomicUsize::new(DEFAULT_CLEANUP_THRESHOLD));
    let ignore_rules = Arc::new(Mutex::new(IgnoreRules::default()));
    let deleted_stack: Arc<Mutex<Vec<crate::backend::DeletedStackEntry>>> = Arc::new(Mutex::new(Vec::new()));
    let last_restored_id = Arc::new(AtomicU64::new(0));

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
        deleted_stack: Arc::clone(&deleted_stack),
        last_restored_id: Arc::clone(&last_restored_id),
    };

    if set_backend(backend).is_err() {
        return 0; // Already initialized
    }

    // Purge stale materialized paste PNGs once at launch: the per-paste
    // purge only runs when an image paste happens, so a long stretch without
    // one leaves stale files until the OS cleans $TMPDIR.
    super::paste::purge_stale_paste_images();

    // Same contract for drag PNGs, whose only other sweep happens when a new
    // image drag materializes — i.e. never, for a user who dragged once.
    super::paste::purge_stale_drag_images();

    // Purge stale materialized undo payloads once at launch: the in-memory
    // undo stack does not survive a restart, so every file in the directory
    // is an orphan from a previous process.
    crate::backend::purge_undo_payload_dir();

    // One-time image metadata migration (DefaultHasher → stable FNV-1a hashes
    // and 300px → display-box thumbnails, user_version 3 → 4) on a background
    // thread: decoding ~250 MB of stored PNGs takes seconds, and the DB lock is
    // held one row at a time so captures keep flowing during the window.
    // Idempotent — an interrupted run is redone on the next launch. Skipped in
    // stress-test builds, whose DBs are generated fresh with the new algorithm.
    #[cfg(not(feature = "stress-test"))]
    if let Some(b) = crate::backend::try_backend() {
        spawn_metadata_migration(b);
    }

    // NOTE: no baseline clipboard read here. The monitor seeds
    // `last_change_count` from the pasteboard changeCount at startup, so the
    // first poll never treats the pre-existing clipboard state as a new
    // capture — the baseline is the changeCount seed, not the payload.
    // Decoding the current clipboard image here used to cost ~65MB of
    // retained ImageIO decode buffers at every launch (measured: the
    // buffers are vm_allocate'd outside the malloc zone, so neither
    // `malloc_zone_pressure_relief` nor natural malloc reuse reclaims
    // them promptly).

    let handle = thread::spawn(|| clipboard_monitor(
        history, running, source_app, db,
        pasteboard_event_lock, pending_self_write,
        cleanup_threshold, ignore_rules,
    ));

    if let Some(b) = crate::backend::try_backend() {
        if let Ok(mut h) = b.monitor_handle.lock() {
            *h = Some(handle);
        }
    }

    1
}

/// Background driver for the image metadata migration (user_version 3 → 4):
/// `schema::migrate_one_image_row` rehashes, `schema::migrate_one_thumbnail_row`
/// re-encodes stored thumbnails to the display-box fit.
///
/// Collects the image row ids once, then decodes and rewrites each row on a
/// fresh DB lock — the lock is never held across a decode, so the capture
/// monitor and paste paths only ever wait for a single row (~tens of ms). The
/// in-memory entry's hash and thumbnail dims are mirrored as each row
/// completes, so same-session re-capture dedup and fresh rows see the new values
/// immediately. On completion stamps `user_version = METADATA_VERSION`;
/// failures are logged and counted but do not block the stamp — an undecodable
/// row will never decode, and retrying it forever would waste every later
/// launch. An interrupted run simply re-runs next launch (idempotent).
///
/// Each pass is gated on its own starting version, so a user already at 3 only
/// re-encodes thumbnails instead of also re-decoding every PNG for a hash that
/// is already stable. They share one `user_version` stamp at the end: two
/// independent writers would race, and whichever stamped first would make the
/// other's half appear done.
#[cfg(not(feature = "stress-test"))]
fn spawn_metadata_migration(b: &'static crate::backend::Backend) {
    // Skip entirely once the image generation is stamped (4) — a later launch
    // must not re-decode the whole corpus.
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
            // Order by decreasing source size so the reusable decode buffers
            // reach their high-water mark on the first row and are then reused
            // without further growth. An arbitrary order makes the scratch
            // ratchet through several allocations, each of which keeps its
            // pages resident after MADV_FREE_REUSABLE.
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
        // Nothing to migrate — stamp the generation directly.
        if let Ok(c) = b.db.lock() {
            let _ = c.pragma_update(None, "user_version", crate::db::METADATA_VERSION);
        }
        return;
    }
    std::thread::spawn(move || {
        let mut updated = 0usize;
        let mut thumbs = 0usize;
        let mut failed = 0usize;
        // One blob buffer reused for every row: a fresh 4-7 MB Vec per row
        // churns malloc, and each freed one stayed resident after being marked
        // reusable (measured 132 MB of Malloc Large (Reusable) retained, and a
        // 180 MB peak across 137 mixed-size rows).
        let mut thumb_blob: Vec<u8> = Vec::new();
        let mut thumb_scratch: Vec<u8> = Vec::new();
        for id in ids {
            if !b.running.load(Ordering::SeqCst) {
                return; // shutting down — next launch resumes (idempotent)
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
            // Mirror into the in-memory entry: same-session re-capture dedup
            // needs the stable hash, and the row's stored dims must match the
            // blob now in the DB.
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
                    // Publish under the history lock: the mirrored hash/dims are
                    // now part of the visible row state.
                    crate::backend::mark_history_changed();
                }
            }
        }
        // Hand both reusable buffers' pages back before this thread exits.
        // They are caller-owned and outlive the loop, so without this the
        // idle process keeps a blob-sized and a scratch-sized region resident
        // long after the migration finished.
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

/// Enable or disable Rust-side stderr logging at runtime.
///
/// Default is `cfg!(debug_assertions)`: debug builds log, release builds do
/// not. The Swift settings UI calls this to persist an explicit user choice.
#[no_mangle]
pub extern "C" fn clipboard_set_debug_logging(enabled: c_int) -> c_int {
    crate::backend::set_debug_logging(enabled != 0);
    1
}

/// Returns 1 if Rust-side stderr logging is currently enabled. Mainly used by
/// the settings UI to show the correct switch state before a user override
/// exists.
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

/// Replaces the configured rules atomically with respect to capture. Strings
/// are copied only when the user commits a settings change, never per poll.
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

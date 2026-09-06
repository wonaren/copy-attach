use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::backend::{set_backend, Backend, DEFAULT_CLEANUP_THRESHOLD};
use crate::db::{ensure_history_table, load_history_from_db, migrate_from_json_to_db, open_db, seed_first_launch_tips, trim_db_history};
use crate::ignore::IgnoreRules;
use crate::monitor::clipboard_monitor;
use crate::types::ClipboardEntry;

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

    let mut conn = if let Some(c) = open_db() { c } else {
        crate::error_log!("CopyAttach: failed to open database, init failed");
        return 0;
    };

    if let Err(e) = ensure_history_table(&conn) {
        crate::error_log!("CopyAttach: failed to create table: {e}");
        return 0;
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
    trim_db_history(&conn, INIT_LOAD);

    // Prime the entry-id counter above the highest loaded ID so new entries
    // never collide with restored ones. This is safe even when loaded IDs are
    // a sparse set from the backfill (SQLite rowids can have gaps from
    // deletion): the AtomicU64 is monotonic and always moves forward.
    {
        let max_id = saved.iter().map(|e| match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        }).max().unwrap_or(0);
        crate::backend::prime_entry_id(max_id + 1);
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

    // Purge stale materialized undo payloads once at launch: the in-memory
    // undo stack does not survive a restart, so every file in the directory
    // is an orphan from a previous process.
    crate::backend::purge_undo_payload_dir();

    // One-time image-hash migration (DefaultHasher → stable FNV-1a,
    // user_version 2 → 3) on a background thread: decoding ~250 MB of stored
    // PNGs takes seconds, and the DB lock is held one row at a time so
    // captures keep flowing during the window. Idempotent — an interrupted run
    // is redone on the next launch (the recompute is a pure function of the
    // stored bytes). Skipped in stress-test builds, whose DBs are generated
    // fresh with the new algorithm.
    #[cfg(not(feature = "stress-test"))]
    if let Some(b) = crate::backend::try_backend() {
        spawn_image_hash_migration(b);
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

/// Background driver for the image-hash migration (`schema::migrate_one_image_row`).
///
/// Collects the image row ids once, then decodes and rehashes each row on a
/// fresh DB lock — the lock is never held across a decode, so the capture
/// monitor and paste paths only ever wait for a single row (~tens of ms). The
/// in-memory entry's hash is mirrored as each row completes, so same-session
/// re-capture dedup sees the new value immediately. On completion stamps
/// `user_version = METADATA_VERSION`; failures are logged and counted but do
/// not block the stamp — an undecodable row will never decode, and retrying it
/// forever would waste every later launch. An interrupted run simply re-runs
/// next launch (idempotent recompute).
#[cfg(not(feature = "stress-test"))]
fn spawn_image_hash_migration(b: &'static crate::backend::Backend) {
    // Skip entirely once the image generation is stamped (3) — a later launch
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
    let ids: Vec<i64> = match b.db.lock() {
        Ok(c) => {
            let mut stmt = match c.prepare("SELECT id FROM clipboard_history WHERE entry_type = 1") {
                Ok(s) => s,
                Err(e) => {
                    crate::error_log!("CopyAttach: image-hash migration: cannot list image rows: {e}");
                    return;
                }
            };
            let rows = match stmt.query_map([], |row| row.get::<_, i64>(0)) {
                Ok(r) => r,
                Err(e) => {
                    crate::error_log!("CopyAttach: image-hash migration: cannot read image rows: {e}");
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
        let mut failed = 0usize;
        for id in ids {
            if !b.running.load(Ordering::SeqCst) {
                return; // shutting down — next launch resumes (idempotent)
            }
            let result = match b.db.lock() {
                Ok(c) => crate::db::migrate_one_image_row(&c, id),
                Err(_) => {
                    failed += 1;
                    continue;
                }
            };
            match result {
                Ok(hash) => {
                    updated += 1;
                    // Mirror into the in-memory entry so same-session
                    // re-capture dedup sees the stable hash immediately (a
                    // re-copy before the next restart would otherwise show a
                    // transient duplicate).
                    if let Ok(mut hist) = b.history.lock() {
                        for entry in hist.iter_mut() {
                            if let crate::types::ClipboardEntry::Image { db_id, hash: h, .. } = entry {
                                if *db_id == id {
                                    *h = hash;
                                    break;
                                }
                            }
                        }
                    }
                }
                Err(()) => failed += 1,
            }
        }
        if let Ok(c) = b.db.lock() {
            if let Err(e) = c.pragma_update(None, "user_version", crate::db::METADATA_VERSION) {
                crate::error_log!("CopyAttach: image-hash migration: failed to stamp user_version: {e}");
            }
        }
        crate::debug_log!("CopyAttach: image-hash migration complete: {updated} updated, {failed} failed");
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

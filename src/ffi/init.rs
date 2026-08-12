use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::backend::{set_backend, Backend, DEFAULT_CLEANUP_THRESHOLD};
use crate::db::{ensure_history_table, load_history_from_db, migrate_from_json_to_db, open_db, trim_db_history};
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
        eprintln!("CopyAttach: clipboard_init rejected: runtime entitlement is denied");
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
            let last_seen_text = Arc::clone(&b.last_seen_text);
            let last_seen_image_hash = Arc::clone(&b.last_seen_image_hash);
            let pasteboard_event_lock = Arc::clone(&b.pasteboard_event_lock);
            let pending_self_write = Arc::clone(&b.pending_self_write);
            let cleanup_threshold = Arc::clone(&b.cleanup_threshold);
            let ignore_rules = Arc::clone(&b.ignore_rules);
            move || clipboard_monitor(history, running, source_app, db, last_seen_text,
                last_seen_image_hash, pasteboard_event_lock, pending_self_write,
                cleanup_threshold, ignore_rules)
        });
        *b.monitor_handle.lock().unwrap() = Some(handle);
        return 1;
    }

    let mut conn = if let Some(c) = open_db() { c } else {
        eprintln!("CopyAttach: failed to open database, init failed");
        return 0;
    };

    if let Err(e) = ensure_history_table(&conn) {
        eprintln!("CopyAttach: failed to create table: {e}");
        return 0;
    }

    migrate_from_json_to_db(&mut conn);

    // First determine the load limit; then load, THEN trim — otherwise the
    // trim below the load limit discards entries before we can read them.
    #[cfg(feature = "stress-test")]
    const INIT_LOAD: usize = 10000;
    #[cfg(not(feature = "stress-test"))]
    const INIT_LOAD: usize = DEFAULT_CLEANUP_THRESHOLD;

    let saved = load_history_from_db(&conn, INIT_LOAD);
    let saved: Vec<ClipboardEntry> = saved.into_iter().take(INIT_LOAD).collect();
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
    let last_seen_text: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_seen_image_hash: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
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
        last_seen_text: Arc::clone(&last_seen_text),
        last_seen_image_hash: Arc::clone(&last_seen_image_hash),
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
        last_seen_text, last_seen_image_hash, pasteboard_event_lock, pending_self_write,
        cleanup_threshold, ignore_rules,
    ));

    if let Some(b) = crate::backend::try_backend() {
        if let Ok(mut h) = b.monitor_handle.lock() {
            *h = Some(handle);
        }
    }

    1
}

#[no_mangle]
pub extern "C" fn clipboard_cleanup() {
    if let Some(b) = crate::backend::try_backend() {
        b.running.store(false, Ordering::SeqCst);
        if let Ok(mut handle) = b.monitor_handle.lock() {
            if let Some(h) = handle.take() {
                let _ = h.join();
            }
        }
    }
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
    );
    match crate::backend::try_backend() {
        Some(backend) => {
            *backend.ignore_rules.lock().unwrap() = rules;
            1
        }
        None => 0,
    }
}

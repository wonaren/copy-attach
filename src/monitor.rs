//! Background clipboard monitor thread.
//!
//! Polls the system clipboard every 300ms, detects new content via NSPasteboard
//! `changeCount` (lightweight) + content comparison.
//!
//! ## Image capture pipeline (two-phase)
//!
//! **Phase 1 (sync — monitor thread)**:
//!   hash → fast thumbnail (CatmullRom) → update in-memory history → set last_seen
//!
//! **Phase 2 (async — background thread)**:
//!   full PNG encode (expensive) → write-through SQLite → update db_id in history
//!
//! This split keeps the monitor thread responsive: 4K capture blocks for ~1s
//! instead of ~5s, and changeCount checks continue to work during encoding.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use arboard::Clipboard;

use crate::backend::POLL_INTERVAL_MS;
use crate::types::ClipboardEntry;
use crate::image::{encode_png, create_thumbnail_fast, image_hash};
use crate::history::add_to_history;
use crate::db::{insert_entry_to_db, delete_matching_entry, trim_db_history};
use crate::ignore::IgnoreRules;
use crate::macos;

/// Maximum length of the longest edge for thumbnail generation.
const THUMBNAIL_MAX_DIM: u32 = 300;

/// Shared image processing pipeline: Phase 1 (in-memory) + Phase 2 (async DB).
///
/// Accepts raw RGBA pixel data as a slice (borrowed for Phase 1, cloned only
/// for the async Phase 2 closure). This avoids an extra allocation on the
/// clipboard path where img_data.bytes is already live.
fn ingest_rgba_image(
    rgba: &[u8],
    width: u32,
    height: u32,
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    last_seen_image_hash: &Arc<Mutex<Option<u64>>>,
    last_seen_text: &Arc<Mutex<Option<String>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
    ignore_rules: &Arc<Mutex<IgnoreRules>>,
) {
    if ignore_rules.lock().unwrap().ignores_image() {
        return;
    }
    let hash = image_hash(rgba, width, height);
    let is_new = {
        let last = last_seen_image_hash.lock().unwrap();
        match *last {
            Some(h) => h != hash,
            None => true,
        }
    };

    if is_new && width > 0 && height > 0 {
        // ── Phase 1 (sync): fast thumbnail → in-memory history ──
        let (thumb_data, thumb_w, thumb_h) = match create_thumbnail_fast(width, height, rgba, THUMBNAIL_MAX_DIM) {
            Some(t) => t,
            None => {
                // Thumbnail creation failed (likely corrupt pixel data). Create
                // the entry anyway — Phase 2 full encode will determine if the
                // image data is truly broken and remove the entry if so.
                // Set last_seen to avoid an infinite retry loop.
                eprintln!("CopyAttach: thumbnail creation failed for image {}x{} — capturing without thumbnail", width, height);
                *last_seen_image_hash.lock().unwrap() = Some(hash);
                *last_seen_text.lock().unwrap() = None;
                // Fall through: create entry with empty thumbnail, continue to Phase 2
                (Vec::new(), 0u32, 0u32)
            }
        };

        let item = ClipboardEntry::Image {
            id: crate::backend::new_entry_id(),
            png_data: Vec::new(),
            width,
            height,
            thumb_data: Vec::new(),
            thumb_width: thumb_w,
            thumb_height: thumb_h,
            hash,
            timestamp: now,
            source_name: src.name.clone(),
            source_bundle_id: src.bundle_id.clone(),
            db_id: 0,
        };

        // In-memory update (metadata only — no PNG blobs held)
        {
            let mut hist = history.lock().unwrap();
            *hist = add_to_history(std::mem::take(&mut *hist), item);
            while hist.len() > cleanup_threshold.load(Ordering::Relaxed) {
                hist.pop();
            }
        }

        // Prevent re-capture before async phase completes
        *last_seen_image_hash.lock().unwrap() = Some(hash);
        *last_seen_text.lock().unwrap() = None;

        // ── Phase 2 (async): full PNG encode → DB write ────────
        let db = db.clone();
        let history = history.clone();
        let threshold = cleanup_threshold.load(Ordering::Relaxed);
        let rgba_owned = rgba.to_vec();
        let item_hash = hash;
        let thumb_async = thumb_data;

        thread::spawn(move || {
            let full_png = match encode_png(width, height, &rgba_owned) {
                Some(png) => png,
                None => {
                    eprintln!("CopyAttach: failed to encode full-size PNG for image {}x{} — removing broken entry from history", width, height);
                    // Remove the entry created in Phase 1 — without PNG data it can
                    // never be pasted. The user sees the entry appear and disappear,
                    // which is better than a ghost entry that silently fails on paste.
                    let mut hist = history.lock().unwrap();
                    hist.retain(|e| match e {
                        ClipboardEntry::Image { hash: h, .. } => *h != item_hash,
                        _ => true,
                    });
                    return;
                }
            };

            // Lock history FIRST to find and clone the item (consistent lock order)
            let db_item = {
                let hist = history.lock().unwrap();
                hist.iter().find(|e| match e {
                    ClipboardEntry::Image { hash: h, .. } => *h == item_hash,
                    _ => false,
                }).cloned()
            };

            if let Some(db_item) = db_item {
                let conn = match db.lock() {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("CopyAttach: DB mutex poisoned in Phase 2 image persist: {}", e);
                        return;
                    }
                };
                if insert_entry_to_db(
                    &conn, &db_item,
                    Some(&full_png),
                    Some((&thumb_async, thumb_w, thumb_h)),
                ).is_err() {
                    eprintln!("CopyAttach: Phase 2 DB insert failed for image {}x{} — entry stays with db_id=0", width, height);
                    return;
                }
                delete_matching_entry(&conn, &db_item);
                let row_id = conn.last_insert_rowid();
                trim_db_history(&conn, threshold);

                // Re-acquire history lock to update db_id in memory
                let mut hist = history.lock().unwrap();
                for entry in hist.iter_mut() {
                    if let ClipboardEntry::Image { hash: h, db_id, .. } = entry {
                        if *h == item_hash {
                            *db_id = row_id;
                            break;
                        }
                    }
                }
                // Signal Swift that a thumbnail is now available via DB
                crate::backend::IMAGE_ENCODING_COUNTER.fetch_add(1, Ordering::Relaxed);
            }
        });
    } else if is_new {
        // Zero-size image — just record the hash
        *last_seen_image_hash.lock().unwrap() = Some(hash);
        *last_seen_text.lock().unwrap() = None;
    }
}

/// Try to decode image files from the given file paths and process them
/// through the standard image pipeline. Returns `true` if any file was
/// successfully decoded and ingested.
///
/// Non-image files are silently skipped (the caller's `continue` ensures
/// the file icon from the pasteboard is not recorded).
fn try_ingest_image_files(
    paths: &[String],
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    last_seen_image_hash: &Arc<Mutex<Option<u64>>>,
    last_seen_text: &Arc<Mutex<Option<String>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
    ignore_rules: &Arc<Mutex<IgnoreRules>>,
) -> bool {
    if ignore_rules.lock().unwrap().ignores_image() {
        return false;
    }
    for path in paths {
        // image::open checks magic bytes, not extension — reliable format detection
        let img = match image::open(path) {
            Ok(img) => img,
            Err(_) => continue,
        };

        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let pixels = rgba.into_raw();

        eprintln!("CopyAttach: captured image file: {path} ({}x{})", w, h);

        ingest_rgba_image(
            &pixels, w, h,
            history, last_seen_image_hash, last_seen_text, db, src, now, cleanup_threshold, ignore_rules,
        );
        return true;
    }
    false
}

pub(crate) fn clipboard_monitor(
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    source_app: Arc<Mutex<crate::types::SourceApp>>,
    db: Arc<Mutex<rusqlite::Connection>>,
    last_seen_text: Arc<Mutex<Option<String>>>,
    last_seen_image_hash: Arc<Mutex<Option<u64>>>,
    cleanup_threshold: Arc<AtomicUsize>,
    ignore_rules: Arc<Mutex<IgnoreRules>>,
) {
    let mut cb = loop {
        match Clipboard::new() {
            Ok(c) => break c,
            Err(e) => {
                eprintln!("clipboard-monitor: failed to open clipboard: {e}, retrying in 1s...");
                if !running.load(Ordering::SeqCst) { return; }
                thread::sleep(Duration::from_secs(1));
            }
        }
    };

    let mut last_change_count: Option<i64> = None;

    while running.load(Ordering::SeqCst) {
        // Lightweight check: skip all pasteboard reads if changeCount matches.
        match (macos::pasteboard_change_count(), last_change_count) {
            (Some(cc), Some(last)) if cc == last => {
                for _ in 0..10 {
                    if !running.load(Ordering::SeqCst) { return; }
                    thread::sleep(Duration::from_millis(POLL_INTERVAL_MS / 10));
                }
                continue;
            }
            (Some(cc), _) => last_change_count = Some(cc),
            _ => {}
        }

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let src = source_app.lock().unwrap().clone();
        if ignore_rules.lock().unwrap().ignores_app(&src.bundle_id) {
            continue;
        }

        // ── Handle file copies ───────────────────────────────────────────
        // When files are copied in Finder, macOS provides the file icon as
        // an image on the pasteboard. We skip the clipboard image read and
        // instead try to decode the actual files from disk.
        if macos::pasteboard_has_files() {
            let paths = macos::pasteboard_file_paths();
            try_ingest_image_files(
                &paths,
                &history, &last_seen_image_hash, &last_seen_text,
                &db, &src, now, &cleanup_threshold, &ignore_rules,
            );
            continue;
        }

        // ── Try image from clipboard ─────────────────────────────────────
        let image_allowed = !ignore_rules.lock().unwrap().ignores_image();
        let mut captured = false;

        if image_allowed {
            if let Ok(img_data) = cb.get_image() {
                ingest_rgba_image(
                    &img_data.bytes,
                    img_data.width as u32,
                    img_data.height as u32,
                    &history, &last_seen_image_hash, &last_seen_text,
                    &db, &src, now, &cleanup_threshold, &ignore_rules,
                );
                captured = true;
            }
        }

        // ── Text (always sync — fast: no PNG encoding) ───────────────
        if !captured {
            if let Ok(text) = cb.get_text() {
                let is_new = {
                    let last = last_seen_text.lock().unwrap();
                    match &*last {
                        Some(last) => &text != last,
                        None => !text.is_empty(),
                    }
                };

                if !text.is_empty() && is_new {
                    let trimmed = text.trim();
                    if trimmed.len() >= 2 && !ignore_rules.lock().unwrap().ignores_text(&text) {
                        let item = ClipboardEntry::Text {
                            id: crate::backend::new_entry_id(),
                            text: text.clone(),
                            timestamp: now,
                            source_name: src.name,
                            source_bundle_id: src.bundle_id,
                            db_id: 0,
                        };

                        // Scope 1: in-memory history update (history lock only)
                        let item_for_db = {
                            let mut hist = history.lock().unwrap();
                            *hist = add_to_history(std::mem::take(&mut *hist), item);
                            while hist.len() > cleanup_threshold.load(Ordering::Relaxed) {
                                hist.pop();
                            }
                            hist[0].clone()
                        }; // history lock released

                        // Scope 2: DB write-through (db lock only — no history lock held)
                        match db.lock() {
                            Ok(conn) => {
                                if insert_entry_to_db(&conn, &item_for_db, None, None).is_ok() {
                                    delete_matching_entry(&conn, &item_for_db);
                                    let row_id = conn.last_insert_rowid();
                                    trim_db_history(&conn, cleanup_threshold.load(Ordering::Relaxed));

                                    // Re-acquire history lock to set db_id on the head entry
                                    let mut hist = history.lock().unwrap();
                                    if let Some(ClipboardEntry::Text { db_id, .. }) = hist.get_mut(0) {
                                        *db_id = row_id;
                                    }
                                } else {
                                    eprintln!("CopyAttach: failed to insert text entry to DB — entry stays with db_id=0");
                                }
                            }
                            Err(e) => {
                                eprintln!("CopyAttach: DB mutex poisoned in text capture persist: {}", e);
                                // Entry already in in-memory history. DB persistence
                                // skipped; entry stays with db_id=0 until DB recovers.
                            }
                        }
                    }
                    *last_seen_text.lock().unwrap() = Some(text);
                    *last_seen_image_hash.lock().unwrap() = None;
                }
            }
        }

        for _ in 0..10 {
            if !running.load(Ordering::SeqCst) { return; }
            thread::sleep(Duration::from_millis(POLL_INTERVAL_MS / 10));
        }
    }
}

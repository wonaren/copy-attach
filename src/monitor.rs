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
use crate::macos;

/// Maximum length of the longest edge for thumbnail generation.
const THUMBNAIL_MAX_DIM: u32 = 300;

pub(crate) fn clipboard_monitor(
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    source_app: Arc<Mutex<crate::types::SourceApp>>,
    db: Arc<Mutex<rusqlite::Connection>>,
    last_seen_text: Arc<Mutex<Option<String>>>,
    last_seen_image_hash: Arc<Mutex<Option<u64>>>,
    cleanup_threshold: Arc<AtomicUsize>,
) {
    let mut cb = match Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("clipboard-monitor: failed to open clipboard: {e}");
            return;
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

        // ── Try image first ────────────────────────────────────────────
        if let Ok(img_data) = cb.get_image() {
            let hash = image_hash(&img_data.bytes, img_data.width as u32, img_data.height as u32);
            let is_new = {
                let last = last_seen_image_hash.lock().unwrap();
                match *last {
                    Some(h) => h != hash,
                    None => true,
                }
            };

            if is_new && img_data.width > 0 && img_data.height > 0 {
                let w = img_data.width as u32;
                let h = img_data.height as u32;

                // ── Phase 1 (sync): fast thumbnail → in-memory history ──
                let (thumb_data, thumb_w, thumb_h) = match create_thumbnail_fast(w, h, &img_data.bytes, THUMBNAIL_MAX_DIM) {
                    Some(t) => t,
                    None => {
                        eprintln!("CopyAttach: thumbnail creation failed for image {}x{}, skipping entry", w, h);
                        *last_seen_image_hash.lock().unwrap() = Some(hash);
                        *last_seen_text.lock().unwrap() = None;
                        continue;
                    }
                };

                let item = ClipboardEntry::Image {
                    id: crate::backend::new_entry_id(),
                    png_data: Vec::new(),
                    width: w,
                    height: h,
                    thumb_data: Vec::new(),
                    thumb_width: thumb_w,
                    thumb_height: thumb_h,
                    hash,
                    timestamp: now,
                    source_name: src.name,
                    source_bundle_id: src.bundle_id,
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
                let rgba = img_data.bytes.to_vec();
                let item_hash = hash;

                thread::spawn(move || {
                    let full_png = match encode_png(w, h, &rgba) {
                        Some(png) => png,
                        None => {
                            eprintln!("CopyAttach: failed to encode full-size PNG for image {}x{} (db_id stays 0)", w, h);
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
                        // Lock DB WITHOUT holding history lock
                        if let Ok(conn) = db.lock() {
                            let _ = insert_entry_to_db(
                                &conn, &db_item,
                                Some(&full_png),
                                Some((&thumb_data, thumb_w, thumb_h)),
                            );
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
                        }
                    }
                });
            } else if is_new {
                // Zero-size image — just record the hash
                *last_seen_image_hash.lock().unwrap() = Some(hash);
                *last_seen_text.lock().unwrap() = None;
            }
        } else {
            // ── Text (always sync — fast: no PNG encoding) ────────────
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
                    if trimmed.len() >= 2 {
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
                        if let Ok(conn) = db.lock() {
                            let _ = insert_entry_to_db(&conn, &item_for_db, None, None);
                            delete_matching_entry(&conn, &item_for_db);
                            let row_id = conn.last_insert_rowid();
                            trim_db_history(&conn, cleanup_threshold.load(Ordering::Relaxed));

                            // Re-acquire history lock to set db_id on the head entry
                            let mut hist = history.lock().unwrap();
                            if let Some(ClipboardEntry::Text { db_id, .. }) = hist.get_mut(0) {
                                *db_id = row_id;
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

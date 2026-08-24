//! Background clipboard monitor thread.
//!
//! Polls the pasteboard via `changeCount`; image capture runs in two phases so
//! the monitor thread stays responsive while full PNG encoding happens async.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use arboard::Clipboard;

use crate::backend::{PendingSelfWrite, POLL_INTERVAL_MS};
use crate::types::ClipboardEntry;
use crate::image::{create_thumbnail_fast, image_hash};
use crate::history::add_to_history;
use crate::ignore::IgnoreRules;
use crate::macos;

/// Maximum length of the longest edge for thumbnail generation.
const THUMBNAIL_MAX_DIM: u32 = 300;

/// Shared image pipeline: Phase 1 updates memory, Phase 2 encodes and persists.
/// Uses the pooled decode buffer to avoid per-capture large allocations.
#[allow(clippy::too_many_arguments)]
fn ingest_rgba_image(
    rgba: crate::backend::ImageDecodeBuffer,
    width: u32,
    height: u32,
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
    ignore_rules: &Arc<Mutex<IgnoreRules>>,
) {
    if ignore_rules.lock().unwrap().ignores_image() {
        return;
    }
    let hash = image_hash(&rgba, width, height);

    // A new changeCount means a genuine re-copy, even with equal image content.
    if width > 0 && height > 0 {
        // Phase 1 (sync): fast thumbnail -> in-memory history.
        let (thumb_data, thumb_w, thumb_h) = if let Some(t) = create_thumbnail_fast(width, height, &rgba, THUMBNAIL_MAX_DIM) { t } else {
            // Keep the entry; Phase 2 will remove it if the image is truly broken.
            crate::debug_log!("CopyAttach: thumbnail creation failed for image {width}x{height} — capturing without thumbnail");
            (Vec::new(), 0u32, 0u32)
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

        // In-memory update (metadata only, no PNG blobs).
        {
            let mut hist = history.lock().unwrap();
            *hist = add_to_history(std::mem::take(&mut *hist), item);
            while hist.len() > cleanup_threshold.load(Ordering::Relaxed) {
                hist.pop();
            }
            crate::backend::mark_history_changed();
        }

        // Phase 2 (async): full PNG encode -> DB write.
        let db = db.clone();
        let history = history.clone();
        let threshold = cleanup_threshold.load(Ordering::Relaxed);
        let item_hash = hash;
        let thumb_async = thumb_data;

        thread::spawn(move || {
            // Use the pooled scratch buffer to avoid per-capture large allocations.
            let mut scratch = crate::backend::ImageEncodeScratchGuard::acquire();
            let full_png = match crate::image::encode_png_into(width, height, &rgba, &mut scratch) {
                Some(()) => scratch.as_slice(),
                None => {
                    crate::debug_log!("CopyAttach: failed to encode full-size PNG for image {width}x{height} — removing broken entry from history");
                    // Remove the Phase 1 entry: without PNG data it can never be pasted.
                    let mut hist = history.lock().unwrap();
                    hist.retain(|e| match e {
                        ClipboardEntry::Image { hash: h, .. } => *h != item_hash,
                        _ => true,
                    });
                    return;
                }
            };

            let db_item = {
                let hist = history.lock().unwrap();
                hist.iter().find(|e| match e {
                    ClipboardEntry::Image { hash: h, .. } => *h == item_hash,
                    _ => false,
                }).cloned()
            };

            if let Some(db_item) = db_item {
                let mut conn = match db.lock() {
                    Ok(c) => c,
                    Err(e) => {
                        crate::error_log!("CopyAttach: DB mutex poisoned in Phase 2 image persist: {e}");
                        return;
                    }
                };
                let persisted = crate::db::persist_entry_to_db(
                    &mut conn, &db_item,
                    None,
                    Some(full_png),
                    Some((&thumb_async, thumb_w, thumb_h)),
                    threshold,
                );
                match persisted {
                    Ok(row_id) => {
                        let mut hist = history.lock().unwrap();
                        for entry in hist.iter_mut() {
                            if let ClipboardEntry::Image { hash: h, db_id, .. } = entry {
                                if *h == item_hash {
                                    *db_id = row_id;
                                    break;
                                }
                            }
                        }
                        crate::backend::IMAGE_ENCODING_COUNTER.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(()) => {
                        crate::error_log!("CopyAttach: Phase 2 DB insert failed for image {width}x{height} — entry stays with db_id=0");
                    }
                }
            }
        });
    } else {
        // Zero-size image: observe but do not create an entry.
    }
}

/// Decode image files from Finder copies and run them through the image pipeline.
/// Returns true if any file was ingested; non-image files are skipped.
#[allow(clippy::too_many_arguments)]
fn try_ingest_image_files(
    paths: &[String],
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
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
        // Skip our own temp files so they don't re-enter history as Finder copies.
        if crate::backend::is_copyattach_temp_path(path) {
            continue;
        }
        let img = match image::open(path) {
            Ok(img) => img,
            Err(_) => continue,
        };

        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let pixels = crate::backend::ImageDecodeBuffer::from_vec(rgba.into_raw());

        crate::debug_log!("CopyAttach: captured image file: {path} ({w}x{h})");
        ingest_rgba_image(
            pixels, w, h,
            history, db, src, now, cleanup_threshold, ignore_rules,
        );
        return true;
    }
    false
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn clipboard_monitor(
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    source_app: Arc<Mutex<crate::types::SourceApp>>,
    db: Arc<Mutex<rusqlite::Connection>>,
    pasteboard_event_lock: Arc<Mutex<()>>,
    pending_self_write: Arc<Mutex<Option<PendingSelfWrite>>>,
    cleanup_threshold: Arc<AtomicUsize>,
    ignore_rules: Arc<Mutex<IgnoreRules>>,
) {
    let mut cb = loop {
        match Clipboard::new() {
            Ok(c) => break c,
            Err(e) => {
                crate::error_log!("clipboard-monitor: failed to open clipboard: {e}, retrying in 1s...");
                if !running.load(Ordering::SeqCst) { return; }
                thread::sleep(Duration::from_secs(1));
            }
        }
    };

    // Ignore the pre-existing clipboard state on startup to avoid a duplicate capture.
    let mut last_change_count: Option<i64> = macos::pasteboard_change_count();

    while running.load(Ordering::SeqCst) {
        // A new changeCount is a new clipboard use; serialize with our own writes.
        let event_guard = pasteboard_event_lock.lock().unwrap();
        let observed_change_count = match (macos::pasteboard_change_count(), last_change_count) {
            (Some(cc), Some(last)) if cc == last => None,
            (Some(cc), _) => {
                last_change_count = Some(cc);
                Some(cc)
            }
            _ => None,
        };

        // A token suppresses only its exact pasteboard change.
        let is_self_write = if let Some(cc) = observed_change_count {
            let mut pending = pending_self_write.lock().unwrap();
            match pending.as_ref() {
                Some(PendingSelfWrite { change_count }) if *change_count == cc => {
                    *pending = None;
                    true
                }
                Some(_) => {
                    *pending = None;
                    false
                }
                None => false,
            }
        } else {
            false
        };
        drop(event_guard);

        if observed_change_count.is_none() || is_self_write {
            // No new event or a self-write: park for the full poll interval.
            if !running.load(Ordering::SeqCst) { return; }
            thread::park_timeout(Duration::from_millis(POLL_INTERVAL_MS));
            continue;
        }

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let src = source_app.lock().unwrap().clone();
        if ignore_rules.lock().unwrap().ignores_app(&src.bundle_id) {
            continue;
        }

        // Handle Finder file copies: decode the files instead of the file icon.
        if macos::pasteboard_has_files() {
            let paths = macos::pasteboard_file_paths();
            try_ingest_image_files(
                &paths,
                &history,
                &db, &src, now, &cleanup_threshold, &ignore_rules,
            );
            continue;
        }

        // Try image from clipboard.
        let image_allowed = !ignore_rules.lock().unwrap().ignores_image();
        let mut captured = false;

        if image_allowed {
            if let Some(img_bytes) = macos::pasteboard_image_data() {
                // Fast path for 8-bit RGBA PNGs; generic decoder otherwise.
                let decoded: Result<(crate::backend::ImageDecodeBuffer, u32, u32), image::ImageError> = {
                    let mut pooled = crate::backend::ImageDecodeBuffer::acquire();
                    match crate::image::decode_png_rgba8_into(&img_bytes, pooled.as_mut_vec()) {
                        Some((w, h)) => Ok((pooled, w, h)),
                        None => {
                            drop(pooled);
                            image::load_from_memory(&img_bytes).map(|img| {
                                let rgba = img.to_rgba8();
                                let (w, h) = rgba.dimensions();
                                (
                                    crate::backend::ImageDecodeBuffer::from_vec(rgba.into_raw()),
                                    w, h,
                                )
                            })
                        }
                    }
                };
                match decoded {
                    Ok((pixels, w, h)) => {
                        ingest_rgba_image(
                            pixels, w, h,
                            &history,
                            &db, &src, now, &cleanup_threshold, &ignore_rules,
                        );
                        captured = true;
                    }
                    Err(e) => {
                        // Undecodable image data: fail explicitly, don't fabricate a capture.
                        crate::debug_log!("CopyAttach: pasteboard image data ({} bytes) undecodable: {e}", img_bytes.len());
                    }
                }
            }
        }

        // Text (always sync: no PNG encoding).
        if !captured {
            if let Ok(text) = cb.get_text() {
                if !text.is_empty() {
                    let trimmed = text.trim();
                    if trimmed.len() >= 2 && !ignore_rules.lock().unwrap().ignores_text(&text) {
                        let item = ClipboardEntry::text_entry(
                            crate::backend::new_entry_id(),
                            &text,
                            now,
                            src.name,
                            src.bundle_id,
                            0,
                        );

                        // In-memory update first.
                        let item_for_db = {
                            let mut hist = history.lock().unwrap();
                            *hist = add_to_history(std::mem::take(&mut *hist), item);
                            while hist.len() > cleanup_threshold.load(Ordering::Relaxed) {
                                hist.pop();
                            }
                            crate::backend::mark_history_changed();
                            hist[0].clone()
                        }; // history lock released

                        // DB write-through; use the hash to roll back on failure.
                        let failed_hash = match &item_for_db {
                            ClipboardEntry::Text { text_hash, .. } => *text_hash,
                            _ => unreachable!("text capture produced a non-text entry"),
                        };
                        match db.lock() {
                            Ok(mut conn) => {
                                match crate::db::persist_entry_to_db(
                                    &mut conn,
                                    &item_for_db,
                                    Some(&text),
                                    None,
                                    None,
                                    cleanup_threshold.load(Ordering::Relaxed),
                                ) {
                                    Ok(row_id) => {
                                        // Set db_id by hash, not index, to survive concurrent moves.
                                        let mut hist = history.lock().unwrap();
                                        crate::history::assign_db_id_by_text_hash(
                                            &mut hist,
                                            failed_hash,
                                            row_id,
                                        );
                                    }
                                    Err(()) => {
                                        // Persist failed: roll back by hash so concurrent moves aren't disturbed.
                                        crate::error_log!("CopyAttach: failed to insert text entry to DB — removing it from history");
                                        let mut hist = history.lock().unwrap();
                                        hist.retain(|e| match e {
                                            ClipboardEntry::Text { text_hash: h, .. } => *h != failed_hash,
                                            _ => true,
                                        });
                                    }
                                }
                            }
                            Err(e) => {
                                crate::error_log!("CopyAttach: DB mutex poisoned in text capture persist: {e}");
                                let mut hist = history.lock().unwrap();
                                hist.retain(|e| match e {
                                    ClipboardEntry::Text { text_hash: h, .. } => *h != failed_hash,
                                    _ => true,
                                });
                            }
                        }
                    }
                }
            }
        }

        if !running.load(Ordering::SeqCst) { return; }
        thread::park_timeout(Duration::from_millis(POLL_INTERVAL_MS));
    }
}

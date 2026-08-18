//! Background clipboard monitor thread.
//!
//! Polls the system clipboard every 500ms, detects new content via `NSPasteboard`
//! `changeCount` (lightweight) + content comparison.
//!
//! ## Image capture pipeline (two-phase)
//!
//! **Phase 1 (sync — monitor thread)**:
//!   hash → fast thumbnail (`CatmullRom`) → update in-memory history
//!
//! **Phase 2 (async — background thread)**:
//!   full PNG encode (expensive) → write-through `SQLite` → update `db_id` in history
//!
//! This split keeps the monitor thread responsive: 4K capture blocks for ~1s
//! instead of ~5s, and changeCount checks continue to work during encoding.

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

/// Shared image processing pipeline: Phase 1 (in-memory) + Phase 2 (async DB).
///
/// Accepts raw RGBA pixel data **by ownership**: Phase 1 borrows it, Phase 2
/// moves it into the encoding thread — zero copies. The buffer itself is the
/// pooled decode scratch ([`crate::backend::ImageDecodeBuffer`]): the
/// clipboard path decodes 8-bit RGBA PNGs straight into it and the generic
/// decoder fallback hands its buffer to the pool as well, so repeated large
/// image captures reuse one allocation instead of alloc + lingering-freed-
/// region per capture (macOS does not return large freed regions promptly).
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

    // The caller invokes us only for a new pasteboard changeCount. Equal image
    // content is therefore a genuine re-copy and must refresh its history use.
    if width > 0 && height > 0 {
        // ── Phase 1 (sync): fast thumbnail → in-memory history ──
        let (thumb_data, thumb_w, thumb_h) = if let Some(t) = create_thumbnail_fast(width, height, &rgba, THUMBNAIL_MAX_DIM) { t } else {
            // Thumbnail creation failed (likely corrupt pixel data). Create
            // the entry anyway — Phase 2 full encode will determine if the
            // image data is truly broken and remove the entry if so.
            crate::debug_log!("CopyAttach: thumbnail creation failed for image {width}x{height} — capturing without thumbnail");
            // Fall through: create entry with empty thumbnail, continue to Phase 2
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

        // In-memory update (metadata only — no PNG blobs held)
        {
            let mut hist = history.lock().unwrap();
            *hist = add_to_history(std::mem::take(&mut *hist), item);
            while hist.len() > cleanup_threshold.load(Ordering::Relaxed) {
                hist.pop();
            }
            crate::backend::mark_history_changed();
        }

        // ── Phase 2 (async): full PNG encode → DB write ────────
        let db = db.clone();
        let history = history.clone();
        let threshold = cleanup_threshold.load(Ordering::Relaxed);
        let item_hash = hash;
        let thumb_async = thumb_data;

        thread::spawn(move || {
            // Encode into the shared scratch buffer (reused across captures):
            // a fresh multi-MB output Vec per capture would linger as a
            // retained region after free (large freed blocks are not returned
            // to the OS promptly in this process). The RAII guard trims the
            // pool on drop when one oversized encode grew it past the
            // retention cap (see backend::ImageEncodeScratchGuard).
            let mut scratch = crate::backend::ImageEncodeScratchGuard::acquire();
            let full_png = match crate::image::encode_png_into(width, height, &rgba, &mut scratch) {
                Some(()) => scratch.as_slice(),
                None => {
                    crate::debug_log!("CopyAttach: failed to encode full-size PNG for image {width}x{height} — removing broken entry from history");
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
                    Err(()) => {
                        crate::error_log!("CopyAttach: Phase 2 DB insert failed for image {width}x{height} — entry stays with db_id=0");
                    }
                }
            }
        });
    } else {
        // Zero-size image — observe the event but create no entry.
    }
}

/// Try to decode image files from the given file paths and process them
/// through the standard image pipeline. Returns `true` if any file was
/// successfully decoded and ingested.
///
/// Non-image files are silently skipped (the caller's `continue` ensures
/// the file icon from the pasteboard is not recorded).
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
        // Files under CopyAttach's own temp tree (paste/drag materializations)
        // must never re-enter history: after an image paste the temp file-url
        // can linger on the pasteboard until the next paste, and a later
        // non-self-write changeCount would otherwise re-ingest it as a "Finder
        // file copy" — re-stamping the entry and jumping it to the top.
        if crate::backend::is_copyattach_temp_path(path) {
            continue;
        }
        // image::open checks magic bytes, not extension — reliable format detection
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

    // Seed with the current changeCount so the first poll doesn't treat
    // the existing clipboard state as a new change. Without this, every
    // app restart would capture a duplicate entry with empty source-app
    // metadata (SourceApp::default), which overwrites the DB-loaded
    // entry's correct source info via dedup.
    let mut last_change_count: Option<i64> = macos::pasteboard_change_count();

    while running.load(Ordering::SeqCst) {
        // A new changeCount is a new clipboard-use event, even if its payload
        // equals the previous payload. Serialize this observation with our own
        // pasteboard writes so their suppression token cannot race us.
        let event_guard = pasteboard_event_lock.lock().unwrap();
        let observed_change_count = match (macos::pasteboard_change_count(), last_change_count) {
            (Some(cc), Some(last)) if cc == last => None,
            (Some(cc), _) => {
                last_change_count = Some(cc);
                Some(cc)
            }
            _ => None,
        };

        // A token can only suppress its own exact pasteboard change. Once a
        // different change arrives it is stale and must not affect later copies.
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
            // No new platform event, or precisely the event written by this
            // app. In neither case may we fabricate a history capture.
            // Park once for the full poll interval instead of ten 30ms slices:
            // the 30ms slicing woke the CPU roughly 30x/s in the idle path for
            // no functional benefit. `clipboard_cleanup()` unparks the thread
            // so shutdown still completes immediately.
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

        // ── Handle file copies ───────────────────────────────────────────
        // When files are copied in Finder, macOS provides the file icon as
        // an image on the pasteboard. We skip the clipboard image read and
        // instead try to decode the actual files from disk.
        if macos::pasteboard_has_files() {
            let paths = macos::pasteboard_file_paths();
            try_ingest_image_files(
                &paths,
                &history,
                &db, &src, now, &cleanup_threshold, &ignore_rules,
            );
            continue;
        }

        // ── Try image from clipboard ─────────────────────────────────────
        let image_allowed = !ignore_rules.lock().unwrap().ignores_image();
        let mut captured = false;

        if image_allowed {
            if let Some(img_bytes) = macos::pasteboard_image_data() {
                // Pooled decode first: 8-bit RGBA PNGs (pasteboard screenshots
                // — the largest transient on this path) go straight into the
                // pooled buffer with zero intermediate allocation; anything
                // else falls back to the generic decoder, whose buffer joins
                // the pool anyway via `from_vec`.
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
                        // Image data present but undecodable (exotic format).
                        // Fail explicitly — do not fabricate a capture.
                        crate::debug_log!("CopyAttach: pasteboard image data ({} bytes) undecodable: {e}", img_bytes.len());
                    }
                }
            }
        }

        // ── Text (always sync — fast: no PNG encoding) ───────────────
        if !captured {
            if let Ok(text) = cb.get_text() {
                if !text.is_empty() {
                    let trimmed = text.trim();
                    if trimmed.len() >= 2 && !ignore_rules.lock().unwrap().ignores_text(&text) {
                        // The full text is still live here (`text`); the entry
                        // derives preview/label/hash and hands the body to the
                        // DB write-through below without retaining it.
                        let item = ClipboardEntry::text_entry(
                            crate::backend::new_entry_id(),
                            &text,
                            now,
                            src.name,
                            src.bundle_id,
                            0,
                        );

                        // Scope 1: in-memory history update (history lock only)
                        let item_for_db = {
                            let mut hist = history.lock().unwrap();
                            *hist = add_to_history(std::mem::take(&mut *hist), item);
                            while hist.len() > cleanup_threshold.load(Ordering::Relaxed) {
                                hist.pop();
                            }
                            crate::backend::mark_history_changed();
                            hist[0].clone()
                        }; // history lock released

                        // Scope 2: DB write-through (db lock only — no history lock held).
                        // The captured text's hash identifies the just-added memory entry so
                        // a failed persist can roll it back below (the entry's body exists
                        // only in SQLite, so unpersisted text would be an inert ghost).
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
                                        // Re-acquire history lock to set db_id on the captured
                                        // entry. Match by content hash, never by head position:
                                        // a concurrent select-and-paste (or undo) may have
                                        // moved another entry to position 0 between Scope 1
                                        // and here, and writing our rowid into that entry would
                                        // orphan this one (db_id=0 forever) while pointing the
                                        // other at a row that a later delete would remove from
                                        // under us — an unpasteable, undeletable ghost.
                                        let mut hist = history.lock().unwrap();
                                        crate::history::assign_db_id_by_text_hash(
                                            &mut hist,
                                            failed_hash,
                                            row_id,
                                        );
                                    }
                                    Err(()) => {
                                        // Persist failed (I/O error, SQLITE_BUSY, or the FTS
                                        // trigger failing). The entry can never be pasted or
                                        // deleted — roll it out of memory so it doesn't linger
                                        // as a ghost. Match by content hash, not index, so a
                                        // concurrent select-and-paste moving another entry to the
                                        // head can't be disturbed.
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

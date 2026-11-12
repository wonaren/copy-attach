use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use arboard::Clipboard;

use crate::backend::{PendingSelfWrite, POLL_INTERVAL_MS};
use crate::types::ClipboardEntry;
use crate::image::{create_thumbnail_fast, image_hash};
use crate::history::{is_pending_image, preserve_history_identity, publish_persisted_entry, visible_history};
use crate::ignore::IgnoreRules;
use crate::macos;

enum ImagePhase2Payload {
    ExistingPng(Vec<u8>),
    Rgba {
        buffer: crate::backend::ImageDecodeBuffer,
        width: u32,
        height: u32,
    },
}

struct ImagePhase2Job {
    payload: ImagePhase2Payload,
    entry_id: u64,
    thumb_data: Vec<u8>,
    thumb_w: u32,
    thumb_h: u32,
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    db: Arc<Mutex<rusqlite::Connection>>,
    cleanup_threshold: Arc<AtomicUsize>,
}

static IMAGE_PHASE2_QUEUE: OnceLock<mpsc::SyncSender<ImagePhase2Job>> = OnceLock::new();

fn image_phase2_sender() -> &'static mpsc::SyncSender<ImagePhase2Job> {
    IMAGE_PHASE2_QUEUE.get_or_init(|| {
        let (tx, rx) = mpsc::sync_channel::<ImagePhase2Job>(1);
        thread::Builder::new()
            .name("copyattach-image-phase2".to_string())
            .spawn(move || {
                while let Ok(job) = rx.recv() {
                    persist_image_phase2(job);
                }
            })
            .expect("CopyAttach: failed to start image Phase 2 worker");
        tx
    })
}

fn persist_image_phase2(job: ImagePhase2Job) {
    let ImagePhase2Job { payload, entry_id, thumb_data: thumb_async,
        thumb_w, thumb_h, history, db, cleanup_threshold } = job;
    let thumb_guard = crate::backend::MarkBlobReusableOnDrop(thumb_async);
    let thumb_async = &thumb_guard.0;
    let _existing_guard;
    let mut scratch_guard;
    let full_png = match payload {
        ImagePhase2Payload::ExistingPng(png) => {
            _existing_guard = crate::backend::MarkBlobReusableOnDrop(png);
            _existing_guard.0.as_slice()
        }
        ImagePhase2Payload::Rgba { buffer, width, height } => {
            scratch_guard = crate::backend::ImageEncodeScratchGuard::acquire();
            let perf = crate::perf::PerfSpan::start("rust", "image.encode_png");
            if let Some(mut span) = perf {
                span.val = Some((width as i64) * (height as i64));
            }
            match crate::image::encode_png_into(width, height, &buffer, &mut scratch_guard) {
                Some(()) => scratch_guard.as_slice(),
                None => {
                    crate::debug_log!("CopyAttach: failed to encode full-size PNG for image {width}x{height}");
                    let mut hist = history.lock().unwrap();
                    hist.retain(|entry| entry.entry_id() != entry_id || !is_pending_image(entry));
                    return;
                }
            }
        }
    };
    let mut conn = match db.lock() {
        Ok(conn) => conn,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in Phase 2 image persist: {e}");
            history.lock().unwrap().retain(|entry| entry.entry_id() != entry_id || !is_pending_image(entry));
            return;
        }
    };
    let mut hist = history.lock().unwrap();
    let Some(index) = hist.iter().rposition(|entry| entry.entry_id() == entry_id && is_pending_image(entry)) else {
        return;
    };
    let mut item = hist.remove(index);
    preserve_history_identity(visible_history(&hist), &mut item);
    match crate::db::persist_entry_to_db(
        &mut conn, &item, None, Some(full_png), Some((thumb_async, thumb_w, thumb_h)),
        cleanup_threshold.load(Ordering::Relaxed),
    ) {
        Ok((row_id, removed)) => {
            publish_persisted_entry(&mut hist, item, row_id, &removed);
            crate::backend::mark_history_changed();
            crate::backend::IMAGE_ENCODING_COUNTER.fetch_add(1, Ordering::Relaxed);
        }
        Err(()) => crate::error_log!("CopyAttach: Phase 2 DB insert failed for image {entry_id}"),
    }
}

fn persist_captured_text(
    db: &Mutex<rusqlite::Connection>,
    history: &Mutex<Vec<ClipboardEntry>>,
    cleanup_threshold: &AtomicUsize,
    mut item: ClipboardEntry,
    text: &str,
) {
    let mut conn = match db.lock() {
        Ok(conn) => conn,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in text capture persist: {e}");
            return;
        }
    };
    let mut hist = history.lock().unwrap();
    preserve_history_identity(visible_history(&hist), &mut item);
    match crate::db::persist_entry_to_db(
        &mut conn, &item, Some(text), None, None, cleanup_threshold.load(Ordering::Relaxed),
    ) {
        Ok((row_id, removed)) => {
            publish_persisted_entry(&mut hist, item, row_id, &removed);
            crate::backend::mark_history_changed();
            crate::perf::perf_instant("rust", "capture.text", Some("text"));
        }
        Err(()) => crate::error_log!("CopyAttach: failed to insert text entry to DB"),
    }
}

#[allow(clippy::too_many_arguments)]
fn insert_image_entry(
    hash: u64,
    width: u32,
    height: u32,
    thumb_data: Vec<u8>,
    thumb_w: u32,
    thumb_h: u32,
    payload: ImagePhase2Payload,
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
) {
    let item = ClipboardEntry::Image {
        id: crate::backend::new_entry_id(),
        width,
        height,
        thumb_width: thumb_w,
        thumb_height: thumb_h,
        hash,
        custom_label: String::new(),
        timestamp: now,
        source_name: src.name.clone(),
        source_bundle_id: src.bundle_id.clone(),
        db_id: 0,
    };

    let entry_id = item.entry_id();
    history.lock().unwrap().push(item);
    crate::perf::perf_instant("rust", "capture.image_phase1", Some("image"));

    let job = ImagePhase2Job {
        payload,
        entry_id,
        thumb_data,
        thumb_w,
        thumb_h,
        history: history.clone(),
        db: db.clone(),
        cleanup_threshold: cleanup_threshold.clone(),
    };
    image_phase2_sender().send(job)
        .expect("CopyAttach: image Phase 2 worker stopped");
}

#[allow(clippy::too_many_arguments)]
fn ingest_streamed_png(
    png: Vec<u8>,
    streamed: crate::image::StreamedRgba8,
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
    ignore_rules: &Arc<Mutex<IgnoreRules>>,
) {
    if ignore_rules.lock().unwrap().ignores_image() {
        crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
        crate::backend::mark_pages_reusable(streamed.thumb_png.as_ptr(), streamed.thumb_png.capacity());
        return;
    }
    insert_image_entry(
        streamed.hash,
        streamed.width,
        streamed.height,
        streamed.thumb_png,
        streamed.thumb_w,
        streamed.thumb_h,
        ImagePhase2Payload::ExistingPng(png),
        history,
        db,
        src,
        now,
        cleanup_threshold,
    );
}

#[allow(clippy::too_many_arguments)]
fn ingest_rgba_image(
    rgba: crate::backend::ImageDecodeBuffer,
    width: u32,
    height: u32,
    raw_png: Option<Vec<u8>>,
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
    ignore_rules: &Arc<Mutex<IgnoreRules>>,
) {
    if ignore_rules.lock().unwrap().ignores_image() {
        if let Some(png) = raw_png {
            crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
        }
        return;
    }
    let hash = image_hash(&rgba, width, height);

    if width > 0 && height > 0 {
        let perf_thumb = crate::perf::PerfSpan::start("rust", "image.thumbnail_phase1");
        if let Some(mut span) = perf_thumb {
            span.val = Some((width as i64) * (height as i64));
        }
        let (thumb_data, thumb_w, thumb_h) = if let Some(t) = create_thumbnail_fast(width, height, &rgba) { t } else {
            crate::debug_log!("CopyAttach: thumbnail creation failed for image {width}x{height} — capturing without thumbnail");
            (Vec::new(), 0u32, 0u32)
        };

        let payload = if let Some(png) = raw_png {
            drop(rgba);
            ImagePhase2Payload::ExistingPng(png)
        } else {
            ImagePhase2Payload::Rgba { buffer: rgba, width, height }
        };

        insert_image_entry(
            hash,
            width,
            height,
            thumb_data,
            thumb_w,
            thumb_h,
            payload,
            history,
            db,
            src,
            now,
            cleanup_threshold,
            );
    } else if let Some(png) = raw_png {
        crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
    }
}


#[allow(clippy::too_many_arguments)]
fn ingest_decoded_png(
    img_bytes: Vec<u8>,
    history: &Arc<Mutex<Vec<ClipboardEntry>>>,
    db: &Arc<Mutex<rusqlite::Connection>>,
    src: &crate::types::SourceApp,
    now: u64,
    cleanup_threshold: &Arc<AtomicUsize>,
    ignore_rules: &Arc<Mutex<IgnoreRules>>,
) -> bool {
    let mut is_native_png = false;
    let decoded: Result<(crate::backend::ImageDecodeBuffer, u32, u32), image::ImageError> = {
        let mut pooled = crate::backend::ImageDecodeBuffer::acquire();
        match crate::image::decode_png_rgba8_into(&img_bytes, pooled.as_mut_vec()) {
            Some((w, h)) => {
                is_native_png = true;
                Ok((pooled, w, h))
            }
            None => {
                drop(pooled);
                image::load_from_memory(&img_bytes).map(|img| {
                    let rgba = img.into_rgba8();
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
            let raw_png = if is_native_png {
                Some(img_bytes)
            } else {
                crate::backend::mark_pages_reusable(img_bytes.as_ptr(), img_bytes.capacity());
                None
            };
            ingest_rgba_image(
                pixels, w, h, raw_png,
                history,
                db, src, now, cleanup_threshold, ignore_rules,
            );
            true
        }
        Err(e) => {
            crate::backend::mark_pages_reusable(img_bytes.as_ptr(), img_bytes.capacity());
            crate::debug_log!("CopyAttach: pasteboard image data ({} bytes) undecodable: {e}", img_bytes.len());
            false
        }
    }
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

    let mut last_change_count: Option<i64> = macos::pasteboard_change_count();

    while running.load(Ordering::SeqCst) {
        let event_guard = pasteboard_event_lock.lock().unwrap();
        let observed_change_count = match (macos::pasteboard_change_count(), last_change_count) {
            (Some(cc), Some(last)) if cc == last => None,
            (Some(cc), _) => {
                last_change_count = Some(cc);
                Some(cc)
            }
            _ => None,
        };

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

        if ignore_rules.lock().unwrap().ignores_sensitive() && macos::pasteboard_has_sensitive_content() {
            crate::debug_log!("CopyAttach: skipped sensitive clipboard content (Concealed/Transient type detected)");
            continue;
        }

        let image_allowed = !ignore_rules.lock().unwrap().ignores_image();
        let mut captured = false;

        if image_allowed {
            if let Some(img_bytes) = macos::pasteboard_image_data() {
                if let Some(streamed) = crate::image::hash_and_thumbnail_streaming(&img_bytes) {
                    ingest_streamed_png(
                        img_bytes, streamed,
                        &history, &db, &src, now, &cleanup_threshold, &ignore_rules,
                    );
                    captured = true;
                } else {
                    captured = ingest_decoded_png(
                        img_bytes,
                        &history, &db, &src, now, &cleanup_threshold, &ignore_rules,
                    );
                }
            }
        }

        if !captured {
            if macos::pasteboard_has_files() {
                crate::debug_log!("CopyAttach: ignored file/icon clipboard content");
                continue;
            }
            let text_opt = cb.get_text().ok().or_else(macos::pasteboard_url_string);
            if let Some(raw_text) = text_opt {
                let text_guard = crate::backend::MarkStringReusableOnDrop(raw_text);
                let text = &text_guard.0;
                if !text.is_empty() {
                    let trimmed = text.trim();
                    if !trimmed.is_empty() && !ignore_rules.lock().unwrap().ignores_text(text) {
                        let item = ClipboardEntry::text_entry(
                            crate::backend::new_entry_id(),
                            text,
                            now,
                            src.name,
                            src.bundle_id,
                            0,
                        );

                        persist_captured_text(&db, &history, &cleanup_threshold, item, text);
                    }
                }
            }
        }

        if !running.load(Ordering::SeqCst) { return; }
        thread::park_timeout(Duration::from_millis(POLL_INTERVAL_MS));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_out_of_order_image_commit_keeps_snapshot_and_database_in_sync() {
        let _shared = crate::tests::shared_state_guard();
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::ensure_history_table(&conn).unwrap();
        let db = Arc::new(Mutex::new(conn));
        let history = Arc::new(Mutex::new(Vec::new()));
        let threshold = Arc::new(AtomicUsize::new(100));

        let capture_text = |id, body: &str, timestamp| {
            let entry = ClipboardEntry::text_entry(id, body, timestamp, String::new(), String::new(), 0);
            persist_captured_text(&db, &history, &threshold, entry, body);
        };
        for id in 1..=100 {
            capture_text(id, &format!("initial {id}"), id);
            if id <= 98 {
                crate::db::set_favorite(&db.lock().unwrap(), id, true).unwrap();
            }
        }

        let rgba = [1, 2, 3, 255];
        let png = crate::image::encode_png(1, 1, &rgba).unwrap();
        {
            let mut hist = history.lock().unwrap();
            hist.push(ClipboardEntry::Image {
                id: 101, width: 1, height: 1, thumb_width: 1, thumb_height: 1,
                hash: crate::image::image_hash(&rgba, 1, 1), custom_label: String::new(),
                timestamp: 101, source_name: String::new(), source_bundle_id: String::new(), db_id: 0,
            });
            assert_eq!(visible_history(&hist).len(), 100);
        }
        capture_text(102, "same-second text", 101);
        persist_image_phase2(ImagePhase2Job {
            payload: ImagePhase2Payload::ExistingPng(png.clone()), entry_id: 101, thumb_data: png,
            thumb_w: 1, thumb_h: 1, history: history.clone(), db: db.clone(), cleanup_threshold: threshold.clone(),
        });
        capture_text(103, "next capture", 102);

        let ids = |entry: &ClipboardEntry| (entry.entry_id(), entry.db_id());
        let memory: Vec<_> = visible_history(&history.lock().unwrap()).iter().map(ids).collect();
        let disk: Vec<_> = crate::db::load_history_from_db(&db.lock().unwrap(), 1000)
            .iter().map(ids).collect();
        assert_eq!(memory, disk);
        assert_eq!(memory.len(), 100);
        assert_eq!((memory[0].0, memory[1].0), (103, 101));
    }
}

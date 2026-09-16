// DB injection and the FFI/benchmark helpers exposed to the app and CLI.

use std::time::Instant;

use crate::backend::new_entry_id;
use crate::db::{insert_entry_to_db, trim_db_history};
use crate::image::{encode_png, image_hash, thumbnail_target_dims};
use crate::types::ClipboardEntry;
use super::image::generate_image_rgba;
use super::text::generate_text_content;
use super::{ImageResolution, InjectStats, TextLength};

/// Inject `count` entries into a DB at `db_path`.  Returns stats.
///
/// `text_ratio` should be in [0.0, 1.0].  The remaining fraction is images.
/// Uses the given `seed` for deterministic generation.
pub fn inject_into_db(
    db_path: &str,
    count: usize,
    text_ratio: f64,
    seed: u64,
    threshold: usize,
) -> InjectStats {
    let start = Instant::now();

    let conn = rusqlite::Connection::open(db_path)
        .expect("stress: failed to open DB for injection");
    conn.execute_batch(
        "PRAGMA mmap_size = 33554432;
         PRAGMA cache_size = -512;
         PRAGMA synchronous = OFF;"
    ).ok();

    // Ensure the history table exists
    crate::db::ensure_history_table(&conn).expect("stress: ensure table failed");

    let text_count = (count as f64 * text_ratio) as usize;
    let image_count = count - text_count;

    let mut stats = InjectStats {
        total: count,
        texts: text_count,
        images: image_count,
        ..InjectStats::default()
    };

    let categories_text = [
        (TextLength::Short,  text_count / 5),
        (TextLength::Medium, text_count / 5),
        (TextLength::MedLong,text_count / 5),
        (TextLength::Long,   text_count / 5),
        (TextLength::XLong,  text_count - (text_count / 5) * 4),
    ];

    let categories_image = [
        (ImageResolution::Res540p, image_count / 5),
        (ImageResolution::Res1k,   image_count / 5),
        (ImageResolution::Res2k,   image_count / 5),
        (ImageResolution::Res4k,   image_count / 5),
        (ImageResolution::Res8k,   image_count - (image_count / 5) * 4),
    ];

    let mut idx = 0u64;

    // ── Insert text entries ───────────────────────────────────────
    for (cat, n) in &categories_text {
        for _i in 0..*n {
            let s = seed.wrapping_add(idx).wrapping_mul(6364136223846793005);
            let text = generate_text_content(*cat, s);
            let entry = ClipboardEntry::text_entry(
                new_entry_id(),
                &text,
                idx,
                String::from("StressTest"),
                String::from("com.stresstest"),
                0,
            );
            // Insert: no png, no thumb. Dedup is unnecessary here —
            // every generated entry has unique content (unique seed per entry).
            insert_entry_to_db(&conn, &entry, Some(&text), None, None).ok();
            idx += 1;

            // Track category
            let ci = match cat {
                TextLength::Short => 0,
                TextLength::Medium => 1,
                TextLength::MedLong => 2,
                TextLength::Long => 3,
                TextLength::XLong => 4,
            };
            stats.text_sizes[ci] += 1;
        }
        eprintln!("PROGRESS:{}/{}", idx, count);
    }

    // ── Insert image entries ──────────────────────────────────────
    for (cat, n) in &categories_image {
        let (w, h) = cat.dims();
        for _i in 0..*n {
            let s = seed.wrapping_add(idx).wrapping_mul(6364136223846793005);

            // Determine encode resolution (capped at FHD for speed).
            // The stored PNG is downscaled but entry metadata keeps the
            // original resolution — the app's handling of metadata+thumb
            // is what matters.
            const MAX_ENCODE_DIM: u32 = 1920;
            let (encode_w, encode_h) = if w.max(h) > MAX_ENCODE_DIM {
                let scale = MAX_ENCODE_DIM as f64 / w.max(h) as f64;
                ((w as f64 * scale).round() as u32,
                 (h as f64 * scale).round() as u32)
            } else {
                (w, h)
            };

            // Generate RGBA at encode resolution (much cheaper than native)
            let rgba = generate_image_rgba(encode_w.max(1), encode_h.max(1), s);
            let hash = image_hash(&rgba, encode_w.max(1), encode_h.max(1));

            // Generate thumbnail DIRECTLY at thumb resolution — skip the
            // expensive downscale from native resolution.  Using the same
            // seed-based block generator at thumb scale gives a visually
            // consistent result without touching 33M pixels. The target dims
            // come from the production box fit so injected data matches what
            // the capture pipeline would store.
            let (thumb_w, thumb_h) = thumbnail_target_dims(encode_w.max(1), encode_h.max(1))
                .unwrap_or((encode_w.max(1), encode_h.max(1)));
            let thumb_sky = generate_image_rgba(thumb_w.max(1), thumb_h.max(1), s);
            let thumb_data = encode_png(thumb_w.max(1), thumb_h.max(1), &thumb_sky)
                .unwrap_or_default();

            // Encode full PNG
            let png = encode_png(encode_w.max(1), encode_h.max(1), &rgba)
                .expect("stress: PNG encode failed");

            let entry = ClipboardEntry::Image {
                id: new_entry_id(),
                width: w,
                height: h,
                thumb_width: thumb_w,
                thumb_height: thumb_h,
                hash,
                custom_label: String::new(),
                timestamp: idx,
                source_name: String::from("StressTest"),
                source_bundle_id: String::from("com.stresstest"),
                db_id: 0,
            };
            insert_entry_to_db(&conn, &entry, None, Some(&png), Some((&thumb_data, thumb_w, thumb_h))).ok();
            idx += 1;

            let ci = match cat {
                ImageResolution::Res540p => 0,
                ImageResolution::Res1k => 1,
                ImageResolution::Res2k => 2,
                ImageResolution::Res4k => 3,
                ImageResolution::Res8k => 4,
            };
            stats.image_sizes[ci] += 1;
        }
        eprintln!("PROGRESS:{}/{}", idx, count);
    }

    // Trim
    trim_db_history(&conn, threshold);

    // Get DB file size
    if let Ok(meta) = std::fs::metadata(db_path) {
        stats.db_size_bytes = meta.len() as i64;
    }

    stats.elapsed_ms = start.elapsed().as_millis() as u64;
    stats
}

/// Get the default DB path.
pub fn default_db_path() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    Some(format!("{}/Library/Application Support/CopyAttach/history.db", home))
}

/// In-memory injection into the running backend.
/// Returns the number of entries actually inserted.
pub fn ffi_inject(count: i32, text_ratio: f64, seed: i64) -> i32 {
    let Some(b) = crate::backend::try_backend() else { return 0 };
    let db_path = match default_db_path() {
        Some(p) => p,
        None => return 0,
    };

    // Use the injection count as the DB trim threshold so all injected
    // entries survive in the DB. The in-memory reload below will then
    // apply the backend's configured limit.
    let injected = inject_into_db(&db_path, count as usize, text_ratio, seed as u64, count as usize);
    // Reload from DB into in-memory history via the shared helper.
    crate::backend::reload_history_from_db(b);

    injected.total as i32
}

/// Reset stress-injected data by re-loading from DB.
pub fn ffi_reset() {
    let Some(b) = crate::backend::try_backend() else { return };
    crate::backend::reload_history_from_db(b);
}

/// Benchmark: measure snapshot lock contention by cloning the history N
/// times (mirrors what clipboard_snapshot_acquire does).  Returns average µs.
pub fn bench_snapshot_clone(n: i32) -> f64 {
    let b = crate::backend::try_backend();
    let hist = match b {
        Some(b) => &b.history,
        None => return 0.0,
    };
    let mut total = 0u128;
    for _ in 0..n {
        let t0 = Instant::now();
        let _guard = hist.lock().unwrap();
        total += t0.elapsed().as_nanos();
    }
    total as f64 / (n as f64 * 1000.0)
}

/// Benchmark: measure the overhead of reading the history Vec length through
/// a mutex lock.  Returns average ns.
pub fn bench_count(n: i32) -> f64 {
    let b = crate::backend::try_backend();
    let hist = match b {
        Some(b) => &b.history,
        None => return 0.0,
    };
    let mut total = 0u128;
    for _ in 0..n {
        let t0 = Instant::now();
        let _count = hist.lock().unwrap().len();
        total += t0.elapsed().as_nanos();
    }
    total as f64 / n as f64
}

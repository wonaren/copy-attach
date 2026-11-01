use std::time::Instant;

use crate::backend::new_entry_id;
use crate::db::{insert_entry_to_db, trim_db_history};
use crate::image::{encode_png, image_hash, thumbnail_target_dims};
use crate::types::ClipboardEntry;
use super::image::generate_image_rgba;
use super::text::generate_text_content;
use super::{ImageResolution, InjectStats, TextLength};

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
            insert_entry_to_db(&conn, &entry, Some(&text), None, None).ok();
            idx += 1;

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

    for (cat, n) in &categories_image {
        let (w, h) = cat.dims();
        for _i in 0..*n {
            let s = seed.wrapping_add(idx).wrapping_mul(6364136223846793005);

            const MAX_ENCODE_DIM: u32 = 1920;
            let (encode_w, encode_h) = if w.max(h) > MAX_ENCODE_DIM {
                let scale = MAX_ENCODE_DIM as f64 / w.max(h) as f64;
                ((w as f64 * scale).round() as u32,
                 (h as f64 * scale).round() as u32)
            } else {
                (w, h)
            };

            let rgba = generate_image_rgba(encode_w.max(1), encode_h.max(1), s);
            let hash = image_hash(&rgba, encode_w.max(1), encode_h.max(1));

            let (thumb_w, thumb_h) = thumbnail_target_dims(encode_w.max(1), encode_h.max(1))
                .unwrap_or((encode_w.max(1), encode_h.max(1)));
            let thumb_sky = generate_image_rgba(thumb_w.max(1), thumb_h.max(1), s);
            let thumb_data = encode_png(thumb_w.max(1), thumb_h.max(1), &thumb_sky)
                .unwrap_or_default();

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

    if trim_db_history(&conn, threshold).is_err() {
        crate::error_log!("CopyAttach stress: trim failed after injection; the fixture may exceed the cap");
    }

    if let Ok(meta) = std::fs::metadata(db_path) {
        stats.db_size_bytes = meta.len() as i64;
    }

    stats.elapsed_ms = start.elapsed().as_millis() as u64;
    stats
}

pub fn default_db_path() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    Some(format!("{}/Library/Application Support/CopyAttach/history.db", home))
}

pub fn ffi_inject(count: i32, text_ratio: f64, seed: i64) -> i32 {
    let Some(b) = crate::backend::try_backend() else { return 0 };
    let db_path = match default_db_path() {
        Some(p) => p,
        None => return 0,
    };

    let injected = inject_into_db(&db_path, count as usize, text_ratio, seed as u64, count as usize);
    crate::backend::reload_history_from_db(b);

    injected.total as i32
}

pub fn ffi_reset() {
    let Some(b) = crate::backend::try_backend() else { return };
    crate::backend::reload_history_from_db(b);
}

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

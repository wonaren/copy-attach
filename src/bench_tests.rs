//! Performance benchmarks for clipboard history management and image processing.
//!
//! Run with: cargo test --features stress-test -- --nocapture
//!
//! Individual benchmarks:
//!   cargo test --features stress-test benchmark_thresholds -- --nocapture
//!   cargo test --features stress-test benchmark_images -- --nocapture

use crate::types::ClipboardEntry;
use crate::image::{encode_png, decode_png, create_thumbnail, create_thumbnail_fast, image_hash};
use crate::history::add_to_history;
use crate::backend::new_entry_id;
use rusqlite::Connection;

// ═══════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════

/// Estimate total heap allocation for a history Vec (vec backing + string buffers).
fn estimate_vec_heap(hist: &[ClipboardEntry]) -> usize {
    let vec_backing = hist.len() * std::mem::size_of::<ClipboardEntry>();
    let string_heap: usize = hist
        .iter()
        .map(|entry| match entry {
            ClipboardEntry::Text { text, source_name, source_bundle_id, .. } => {
                text.capacity() + source_name.capacity() + source_bundle_id.capacity()
            }
            ClipboardEntry::Image {
                png_data, thumb_data, source_name, source_bundle_id, ..
            } => {
                png_data.capacity()
                    + thumb_data.capacity()
                    + source_name.capacity()
                    + source_bundle_id.capacity()
            }
        })
        .sum();
    vec_backing + string_heap
}

fn format_bytes(bytes: usize) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.2} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{} B", bytes)
    }
}

/// Create the clipboard_history table schema (mirrors db.rs exactly).
fn create_bench_table(conn: &Connection) {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_type      INTEGER NOT NULL,
            text            TEXT,
            png_data        BLOB,
            width           INTEGER,
            height          INTEGER,
            thumb_data      BLOB,
            thumb_width     INTEGER,
            thumb_height    INTEGER,
            hash            INTEGER,
            timestamp       INTEGER NOT NULL,
            source_name     TEXT NOT NULL DEFAULT '',
            source_bundle_id TEXT NOT NULL DEFAULT ''
        );",
    )
    .expect("bench: failed to create table");
}

/// Generate a text entry with realistic content (~60-80 chars) for benchmarking.
fn bench_text(index: u64) -> ClipboardEntry {
    let text = format!(
        "benchmark-item-{:06}: The quick brown fox jumps over the lazy dog #{}",
        index, index
    );
    ClipboardEntry::Text {
        id: new_entry_id(),
        text,
        timestamp: index,
        source_name: String::from("Benchmark"),
        source_bundle_id: String::from("com.benchmark"),
        db_id: 0,
    }
}

/// Helper trait to access text content from ClipboardEntry for DB queries.
trait TextContent {
    fn text(&self) -> &str;
}
impl TextContent for ClipboardEntry {
    fn text(&self) -> &str {
        match self {
            ClipboardEntry::Text { text, .. } => text,
            _ => panic!("bench: expected Text entry"),
        }
    }
}

/// Generate a RGBA buffer simulating a screenshot with mixed content.
/// The `variation` param shifts colors to produce a unique hash per image.
fn make_screenshot_rgba(width: u32, height: u32, variation: u8) -> Vec<u8> {
    let mut data = vec![0u8; (width * height * 4) as usize];
    for y in 0..height {
        for x in 0..width {
            let i = ((y * width + x) * 4) as usize;
            // Gradient sky (top) to warm (bottom) background
            let grad = y as f64 / height as f64;
            data[i] = (100.0 + grad * 100.0 + (x as f64 / width as f64) * 55.0) as u8;
            data[i + 1] = (80.0 + grad * 80.0) as u8;
            data[i + 2] = (180.0 - grad * 80.0) as u8;
            data[i + 3] = 255;

            // Simulated window blocks (rectangular regions)
            if x % 500 > 20 && x % 500 < 480 && y % 400 > 20 && y % 400 < 380 {
                data[i] = data[i].wrapping_add(40);
                data[i + 1] = data[i + 1].wrapping_add(35);
                data[i + 2] = data[i + 2].wrapping_add(50);
            }

            // Simulated text lines (thin alternating horizontal strips)
            if y % 16 < 2 && x % 300 < 280 {
                data[i] = 20;
                data[i + 1] = 20;
                data[i + 2] = 30;
            }
        }
    }
    // Tweak one pixel for uniqueness (variation guarantees different hash)
    let last = data.len() - 4;
    data[last] = data[last].wrapping_add(variation);
    data
}

// ═══════════════════════════════════════════
// History Threshold Benchmark
// ═══════════════════════════════════════════

#[test]
fn benchmark_thresholds() {
    let thresholds: [usize; 6] = [100, 500, 1000, 2000, 3000, 5000];
    const STEADY_STATE_SAMPLES: usize = 50; // additional entries averaged for per-item cost

    // ── Header ──────────────────────────────────────────────────────────
    println!();
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!("  CopyAttach History Threshold Benchmark");
    println!("  Text entries with unique content (no dedup match during fill)");
    println!("  Steady-state average over {} extra additions per threshold", STEADY_STATE_SAMPLES);
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!();
    println!(
        "{:<10} | {:<16} | {:<16} | {:<16} | {:<16} | {:<16} | {:<16}",
        "Threshold",
        "Mem (heap est.)",
        "DB file size",
        "mgmt::size_of",
        "Add/item (avg)",
        "Clone (snap)",
        "DB write/item"
    );
    println!(
        "{:-<10}-+-{:-<16}-+-{:-<16}-+-{:-<16}-+-{:-<16}-+-{:-<16}-+-{:-<16}",
        "", "", "", "", "", "", ""
    );

    println!("  sizeof(ClipboardEntry) = {}", std::mem::size_of::<ClipboardEntry>());
    println!();

    for &threshold in &thresholds {
        let db_dir = std::env::temp_dir().join(format!("copyattach_bench_{}", threshold));
        let _ = std::fs::create_dir_all(&db_dir);
        let db_path = db_dir.join("history.db");
        let _ = std::fs::remove_file(&db_path);

        // ── Open DB (mirrors db.rs) ─────────────────────────────────────
        let conn = Connection::open(&db_path)
            .expect("bench: failed to open temp DB");
        conn.execute_batch(
            "PRAGMA mmap_size = 268435456;
             PRAGMA cache_size = -512;",
        )
        .expect("bench: pragma failed");
        create_bench_table(&conn);

        // ── Fill to threshold ───────────────────────────────────────────
        let mut hist = Vec::with_capacity(threshold + STEADY_STATE_SAMPLES);
        let mut db_write_total = std::time::Duration::new(0, 0);

        // Track db_id for the last inserted entry so we can set it
        let mut last_db_id: i64 = 0;

        for i in 0..threshold {
            let item = bench_text(i as u64);

            // DB write-through (mirrors monitor.rs / ffi.rs):
            let db_start = std::time::Instant::now();
            conn.execute(
                "INSERT INTO clipboard_history (entry_type, text, timestamp, source_name, source_bundle_id)
                 VALUES (0, ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    &item.text(),
                    item.timestamp() as i64,
                    item.source_name(),
                    item.source_bundle_id(),
                ],
            )
            .expect("bench: DB insert failed");
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 0 AND text = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 0 AND text = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![item.text()],
            )
            .expect("bench: DB dedup failed");
            conn.execute(
                "DELETE FROM clipboard_history WHERE id NOT IN (
                    SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
                rusqlite::params![threshold as i64],
            )
            .expect("bench: DB trim failed");
            db_write_total += db_start.elapsed();

            last_db_id = conn.last_insert_rowid();

            // In-memory add (mirrors monitor.rs / ffi.rs):
            hist = add_to_history(std::mem::take(&mut hist), item);
            while hist.len() > threshold {
                hist.pop();
            }
        }
        assert_eq!(hist.len(), threshold);

        // Assign db_id to the head item so it mirrors real app state
        if let Some(head) = hist.get_mut(0) {
            match head {
                ClipboardEntry::Text { ref mut db_id, .. }
                | ClipboardEntry::Image { ref mut db_id, .. } => {
                    *db_id = last_db_id;
                }
            }
        }

        // ── Steady-state: average per-add cost ──────────────────────────
        let mut add_times = Vec::with_capacity(STEADY_STATE_SAMPLES);
        let mut db_times = Vec::with_capacity(STEADY_STATE_SAMPLES);

        for j in 0..STEADY_STATE_SAMPLES {
            let item = bench_text((threshold + j) as u64);

            let db_start = std::time::Instant::now();
            conn.execute(
                "INSERT INTO clipboard_history (entry_type, text, timestamp, source_name, source_bundle_id)
                 VALUES (0, ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    &item.text(),
                    item.timestamp() as i64,
                    item.source_name(),
                    item.source_bundle_id(),
                ],
            )
            .expect("bench: steady DB insert failed");
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 0 AND text = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 0 AND text = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![item.text()],
            )
            .expect("bench: steady DB dedup failed");
            conn.execute(
                "DELETE FROM clipboard_history WHERE id NOT IN (
                    SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
                rusqlite::params![threshold as i64],
            )
            .expect("bench: steady DB trim failed");
            db_times.push(db_start.elapsed());

            // In-memory
            let add_start = std::time::Instant::now();
            hist = add_to_history(std::mem::take(&mut hist), item);
            while hist.len() > threshold {
                hist.pop();
            }
            add_times.push(add_start.elapsed());

            assert_eq!(hist.len(), threshold);
        }

        // ── Snapshot clone time ─────────────────────────────────────────
        let clone_start = std::time::Instant::now();
        let _snapshot = hist.clone();
        let clone_time = clone_start.elapsed();
        drop(_snapshot);

        // ── Memory estimate ─────────────────────────────────────────────
        let mem_estimate = estimate_vec_heap(&hist);

        // DB file size
        let db_size = std::fs::metadata(&db_path)
            .map(|m| m.len())
            .expect("bench: metadata failed");

        // Compute averages
        let avg_add = add_times.iter().sum::<std::time::Duration>()
            / STEADY_STATE_SAMPLES as u32;
        let avg_db = db_times.iter().sum::<std::time::Duration>()
            / STEADY_STATE_SAMPLES as u32;

        // ── Print row ───────────────────────────────────────────────────
        println!(
            "{:<10} | {:<16} | {:<16} | {:<16} | {:<16?} | {:<16?} | {:<16?}",
            threshold,
            format_bytes(mem_estimate),
            format_bytes(db_size as usize),
            format_bytes(std::mem::size_of::<ClipboardEntry>()),
            avg_add,
            clone_time,
            avg_db,
        );

        // Cleanup
        drop(hist);
        drop(conn);
        let _ = std::fs::remove_file(&db_path);
        let _ = std::fs::remove_dir(&db_dir);
    }

    println!();
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!("  Benchmark complete.");
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!();
}

// ═══════════════════════════════════════════
// Image Performance Benchmarks
// ═══════════════════════════════════════════

#[test]
fn benchmark_images() {
    // ══════════════════════════════════════════════════
    // 1. IMAGE CAPTURE PROCESSING BENCHMARK
    // ══════════════════════════════════════════════════
    let resolutions: [(u32, u32, &str); 3] = [
        (800, 600, "800×600 (small crop)"),
        (1920, 1080, "1920×1080 (FHD)"),
        (3840, 2160, "3840×2160 (4K UHD)"),
    ];

    println!();
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!("  CopyAttach Image Capture Performance");
    println!("══════════════════════════════════════════════════════════════════════════════════════\n");

    println!(
        "{:<28} | {:<14} | {:<14} | {:<14} | {:<14} | {:<12} | {:<12} | {:<12}",
        "Resolution",
        "PNG size",
        "Thumb size",
        "Encode time",
        "Thumb(L3)",
        "Thumb(CR)",
        "Hash time",
        "Total sync"
    );
    println!(
        "{:-<28}-+-{:-<14}-+-{:-<14}-+-{:-<14}-+-{:-<14}-+-{:-<12}-+-{:-<12}-+-{:-<12}",
        "", "", "", "", "", "", "", ""
    );

    // Store encoded images for DB benchmark (one per resolution)
    let mut encoded_samples: Vec<(Vec<u8>, Vec<u8>, u32, u32, u32, u32, u64)> = Vec::new();

    for &(w, h, label) in &resolutions {
        let rgba = make_screenshot_rgba(w, h, 1);

        let hash_start = std::time::Instant::now();
        let hash = image_hash(&rgba, w, h);
        let hash_time = hash_start.elapsed();

        let encode_start = std::time::Instant::now();
        let png = encode_png(w, h, &rgba).expect("bench: PNG encode failed");
        let encode_time = encode_start.elapsed();

        let l3_start = std::time::Instant::now();
        let _thumb_l3 = create_thumbnail(w, h, &rgba, 500)
            .expect("bench: L3 thumbnail failed");
        let l3_time = l3_start.elapsed();

        let cr_start = std::time::Instant::now();
        let thumb_cr = create_thumbnail_fast(w, h, &rgba, 500)
            .expect("bench: CR thumbnail failed");
        let cr_time = cr_start.elapsed();

        let (thumb_data, _thumb_w, _thumb_h) = thumb_cr;
        let total_sync = hash_time + cr_time; // sync path = hash + fast thumb

        println!(
            "{:<28} | {:<14} | {:<14} | {:<14?} | {:<14?} | {:<12?} | {:<12?} | {:<12?}",
            label,
            format_bytes(png.len()),
            format_bytes(thumb_data.len()),
            encode_time,
            l3_time,
            cr_time,
            hash_time,
            total_sync,
        );

        encoded_samples.push((png, thumb_data, _thumb_w, _thumb_h, w, h, hash));
    }

    // ══════════════════════════════════════════════════
    // 2. IN-MEMORY IMAGE HISTORY BENCHMARK
    // ══════════════════════════════════════════════════
    let thresholds: [usize; 6] = [100, 500, 1000, 2000, 3000, 5000];
    const SS_SAMPLES: usize = 50;

    println!();
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!("  In-Memory History with Image Entries (empty blobs — matches real app)");
    println!("══════════════════════════════════════════════════════════════════════════════════════\n");

    println!(
        "{:<10} | {:<16} | {:<16} | {:<16} | {:<16} | {:<16}",
        "Threshold",
        "Mem (heap est.)",
        "mgmt::size_of",
        "Add/item (avg)",
        "Clone (snap)",
        "per-entry mem"
    );
    println!(
        "{:-<10}-+-{:-<16}-+-{:-<16}-+-{:-<16}-+-{:-<16}-+-{:-<16}",
        "", "", "", "", "", ""
    );

    for &threshold in &thresholds {
        let mut hist: Vec<ClipboardEntry> = Vec::with_capacity(threshold + SS_SAMPLES);
        let mut add_times = Vec::with_capacity(SS_SAMPLES);

        // Fill to threshold: unique hash per entry avoids dedup
        for i in 0..threshold {
            let item = ClipboardEntry::Image {
                id: new_entry_id(),
                png_data: Vec::new(),
                width: 1920,
                height: 1080,
                thumb_data: Vec::new(),
                thumb_width: 500,
                thumb_height: 281,
                hash: i as u64 + 1,
                timestamp: i as u64,
                source_name: String::new(),
                source_bundle_id: String::new(),
                db_id: i as i64,
            };
            hist = add_to_history(std::mem::take(&mut hist), item);
            while hist.len() > threshold {
                hist.pop();
            }
        }
        assert_eq!(hist.len(), threshold);

        // Steady-state measurements
        for j in 0..SS_SAMPLES {
            let item = ClipboardEntry::Image {
                id: new_entry_id(),
                png_data: Vec::new(),
                width: 1920,
                height: 1080,
                thumb_data: Vec::new(),
                thumb_width: 500,
                thumb_height: 281,
                hash: (threshold + j) as u64 + 1,
                timestamp: (threshold + j) as u64,
                source_name: String::new(),
                source_bundle_id: String::new(),
                db_id: (threshold + j) as i64,
            };
            let add_start = std::time::Instant::now();
            hist = add_to_history(std::mem::take(&mut hist), item);
            while hist.len() > threshold {
                hist.pop();
            }
            add_times.push(add_start.elapsed());
            assert_eq!(hist.len(), threshold);
        }

        let avg_add = add_times.iter().sum::<std::time::Duration>() / SS_SAMPLES as u32;

        let clone_start = std::time::Instant::now();
        let _snap = hist.clone();
        let clone_time = clone_start.elapsed();
        drop(_snap);

        let mem_estimate = estimate_vec_heap(&hist);
        let per_entry = mem_estimate / threshold;
        drop(hist);

        println!(
            "{:<10} | {:<16} | {:<16} | {:<16?} | {:<16?} | {:<16}",
            threshold,
            format_bytes(mem_estimate),
            format_bytes(std::mem::size_of::<ClipboardEntry>()),
            avg_add,
            clone_time,
            format_bytes(per_entry),
        );
    }

    // ══════════════════════════════════════════════════
    // 3. DB STORAGE WITH IMAGES
    // ══════════════════════════════════════════════════

    // Use the 1920×1080 and 3840×2160 encoded samples
    let fhd_png = &encoded_samples[1].0;    // 1920×1080 PNG
    let fhd_thumb = &encoded_samples[1].1;
    let uhd_png = &encoded_samples[2].0;   // 3840×2160 (4K) PNG
    let uhd_thumb = &encoded_samples[2].1;

    println!();
    println!("══════════════════════════════════════════════════════════════════════════════════════");
    println!("  DB Storage with Image Entries");
    println!("══════════════════════════════════════════════════════════════════════════════════════\n");

    println!(
        "{:<10} | {:<16} | {:<16} | {:<16} | {:<18} | {:<16} | {:<16}",
        "Threshold",
        "DB (FHD)",
        "DB (4K)",
        "FHD write/item",
        "4K write/item",
        "FHD per-entry",
        "4K per-entry"
    );
    println!(
        "{:-<10}-+-{:-<16}-+-{:-<16}-+-{:-<16}-+-{:-<18}-+-{:-<16}-+-{:-<16}",
        "", "", "", "", "", "", ""
    );

    for &threshold in &thresholds {
        // ── FHD DB benchmark ─────────────────────────────────
        let db_dir_fhd = std::env::temp_dir().join(format!("copyattach_img_fhd_{}", threshold));
        let _ = std::fs::create_dir_all(&db_dir_fhd);
        let db_path_fhd = db_dir_fhd.join("history.db");
        let _ = std::fs::remove_file(&db_path_fhd);

        let conn_fhd = Connection::open(&db_path_fhd)
            .expect("bench: failed to open temp DB for FHD");
        conn_fhd
            .execute_batch(
                "PRAGMA mmap_size = 268435456;
                 PRAGMA cache_size = -512;",
            )
            .expect("bench: pragma failed");
        create_bench_table(&conn_fhd);

        let mut fhd_write_times = Vec::with_capacity(threshold);
        let mut fhd_last_id: i64 = 0;
        let mut fhd_hash: u64 = 12345;

        for i in 0..threshold {
            fhd_hash = fhd_hash.wrapping_mul(6364136223846793005).wrapping_add(1);
            let row_id;

            let write_start = std::time::Instant::now();
            conn_fhd
                .execute(
                    "INSERT INTO clipboard_history
                     (entry_type, text, png_data, width, height,
                      thumb_data, thumb_width, thumb_height, hash,
                      timestamp, source_name, source_bundle_id)
                     VALUES (1, NULL, ?1, 1920, 1080, ?2, 500, 281, ?3, ?4, '', '')",
                    rusqlite::params![fhd_png, fhd_thumb, fhd_hash as i64, i as i64],
                )
                .expect("bench: FHD DB insert failed");
            conn_fhd
                .execute(
                    "DELETE FROM clipboard_history WHERE id NOT IN (
                        SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
                    rusqlite::params![threshold as i64],
                )
                .expect("bench: FHD DB trim failed");
            fhd_write_times.push(write_start.elapsed());

            row_id = conn_fhd.last_insert_rowid();
            fhd_last_id = row_id;
        }
        let _ = fhd_last_id;

        let fhd_avg_write =
            fhd_write_times.iter().sum::<std::time::Duration>() / threshold as u32;
        let fhd_db_size = std::fs::metadata(&db_path_fhd)
            .map(|m| m.len())
            .expect("bench: FHD metadata failed");
        let fhd_per_entry = fhd_db_size / threshold as u64;

        drop(conn_fhd);
        let _ = std::fs::remove_file(&db_path_fhd);
        let _ = std::fs::remove_dir(&db_dir_fhd);

        // ── 4K DB benchmark ──────────────────────────────────
        let db_dir_4k = std::env::temp_dir().join(format!("copyattach_img_4k_{}", threshold));
        let _ = std::fs::create_dir_all(&db_dir_4k);
        let db_path_4k = db_dir_4k.join("history.db");
        let _ = std::fs::remove_file(&db_path_4k);

        let conn_4k = Connection::open(&db_path_4k)
            .expect("bench: failed to open temp DB for 4K");
        conn_4k
            .execute_batch(
                "PRAGMA mmap_size = 268435456;
                 PRAGMA cache_size = -512;",
            )
            .expect("bench: pragma failed");
        create_bench_table(&conn_4k);

        let mut uhd_write_times = Vec::with_capacity(threshold);
        let mut uhd_hash: u64 = 99999;

        for i in 0..threshold {
            uhd_hash = uhd_hash.wrapping_mul(6364136223846793005).wrapping_add(1);

            let write_start = std::time::Instant::now();
            conn_4k
                .execute(
                    "INSERT INTO clipboard_history
                     (entry_type, text, png_data, width, height,
                      thumb_data, thumb_width, thumb_height, hash,
                      timestamp, source_name, source_bundle_id)
                     VALUES (1, NULL, ?1, 3840, 2160, ?2, 500, 281, ?3, ?4, '', '')",
                    rusqlite::params![uhd_png, uhd_thumb, uhd_hash as i64, i as i64],
                )
                .expect("bench: 4K DB insert failed");
            conn_4k
                .execute(
                    "DELETE FROM clipboard_history WHERE id NOT IN (
                        SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
                    rusqlite::params![threshold as i64],
                )
                .expect("bench: 4K DB trim failed");
            uhd_write_times.push(write_start.elapsed());
        }

        let uhd_avg_write =
            uhd_write_times.iter().sum::<std::time::Duration>() / threshold as u32;
        let uhd_db_size = std::fs::metadata(&db_path_4k)
            .map(|m| m.len())
            .expect("bench: 4K metadata failed");
        let uhd_per_entry = uhd_db_size / threshold as u64;

        drop(conn_4k);
        let _ = std::fs::remove_file(&db_path_4k);
        let _ = std::fs::remove_dir(&db_dir_4k);

        println!(
            "{:<10} | {:<16} | {:<16} | {:<16?} | {:<18?} | {:<16} | {:<16}",
            threshold,
            format_bytes(fhd_db_size as usize),
            format_bytes(uhd_db_size as usize),
            fhd_avg_write,
            uhd_avg_write,
            format_bytes(fhd_per_entry as usize),
            format_bytes(uhd_per_entry as usize),
        );
    }

    println!();
    println!("══════════════════════════════════════════════════════════════════════════════════════");
}

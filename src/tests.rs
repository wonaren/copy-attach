//! Unit tests for clipboard history management and image processing.
//!
//! ⚠️  Benchmark: run with `cargo test benchmark_thresholds -- --nocapture`

use crate::types::ClipboardEntry;
use crate::image::{encode_png, decode_png, create_thumbnail, create_thumbnail_fast, image_hash};
use crate::history::add_to_history;
use crate::backend::new_entry_id;
use crate::ffi::clipboard_free_string;
use rusqlite::Connection;

fn make_text(text: &str, ts: u64) -> ClipboardEntry {
    ClipboardEntry::Text {
        id: new_entry_id(),
        text: text.to_string(),
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    }
}

fn make_image(data: &[u8], w: u32, h: u32, ts: u64) -> ClipboardEntry {
    let hash = image_hash(data, w, h);
    let png = encode_png(w, h, data).unwrap();
    let thumb = create_thumbnail(w, h, data, 100).unwrap();
    ClipboardEntry::Image {
        id: new_entry_id(),
        png_data: png,
        width: w,
        height: h,
        thumb_data: thumb.0,
        thumb_width: thumb.1,
        thumb_height: thumb.2,
        hash,
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    }
}

fn make_test_image_rgba(w: u32, h: u32, fill_byte: u8) -> Vec<u8> {
    vec![fill_byte; (w * h * 4) as usize]
}

// ═══════════════════════════════════════════
// Basic History Tests
// ═══════════════════════════════════════════

#[test]
fn test_add_text_item() {
    let history = vec![];
    let item = make_text("hello world", 100);
    let result = add_to_history(history, item);
    assert_eq!(result.len(), 1);
    if let ClipboardEntry::Text { text, .. } = &result[0] {
        assert_eq!(text, "hello world");
    } else { panic!("Expected Text entry"); }
}

#[test]
fn test_text_deduplication() {
    let history = vec![make_text("duplicate", 100)];
    let item = make_text("duplicate", 200);
    let result = add_to_history(history, item);
    assert_eq!(result.len(), 1);
    if let ClipboardEntry::Text { timestamp, .. } = &result[0] {
        assert_eq!(*timestamp, 200);
    }
}

#[test]
fn test_text_and_image_mixed() {
    let history = vec![];
    let t1 = make_text("text1", 100);
    let img_data = make_test_image_rgba(10, 10, 128);
    let i1 = make_image(&img_data, 10, 10, 200);
    let history = add_to_history(history, t1);
    let history = add_to_history(history, i1);
    assert_eq!(history.len(), 2);
    assert!(matches!(history[0], ClipboardEntry::Image { .. }));
    assert!(matches!(history[1], ClipboardEntry::Text { .. }));
}

#[test]
fn test_image_deduplication() {
    let img_data = make_test_image_rgba(8, 8, 200);
    let img1 = make_image(&img_data, 8, 8, 100);
    let img2 = make_image(&img_data, 8, 8, 200);
    let history = vec![img1];
    let result = add_to_history(history, img2);
    assert_eq!(result.len(), 1);
    if let ClipboardEntry::Image { timestamp, .. } = &result[0] {
        assert_eq!(*timestamp, 200);
    }
}

#[test]
fn test_add_multiple_items_order() {
    let history = vec![];
    let items = vec!["c", "b", "a"];
    let mut history = history;
    for (i, &s) in items.iter().enumerate() {
        history = add_to_history(history, make_text(s, i as u64));
    }
    assert_eq!(history.len(), 3);
    if let ClipboardEntry::Text { text, .. } = &history[0] {
        assert_eq!(text, "a");
    }
}

// ═══════════════════════════════════════════
// Image Processing Tests
// ═══════════════════════════════════════════

#[test]
fn test_encode_decode_png() {
    let rgba = make_test_image_rgba(16, 16, 100);
    let png = encode_png(16, 16, &rgba).expect("encode should succeed");
    assert!(!png.is_empty());
    let (decoded, w, h) = decode_png(&png).expect("decode should succeed");
    assert_eq!(w, 16);
    assert_eq!(h, 16);
    assert_eq!(decoded.len(), 16 * 16 * 4);
}

#[test]
fn test_create_thumbnail() {
    let rgba = make_test_image_rgba(200, 100, 150);
    let thumb = create_thumbnail(200, 100, &rgba, 50);
    assert!(thumb.is_some());
    let (_, tw, th) = thumb.unwrap();
    assert!(tw <= 50 && th <= 50);
}

#[test]
fn test_image_hash_consistency() {
    let data1 = make_test_image_rgba(10, 10, 200);
    let data2 = make_test_image_rgba(10, 10, 200);
    assert_eq!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
}

#[test]
fn test_image_hash_different() {
    let data1 = make_test_image_rgba(10, 10, 200);
    let data2 = make_test_image_rgba(10, 10, 100);
    assert_ne!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
}

// ═══════════════════════════════════════════
// Metadata Tests
// ═══════════════════════════════════════════

#[test]
fn test_source_app_fields() {
    let mut t = make_text("hello", 1);
    let img_data = make_test_image_rgba(5, 5, 50);
    let mut i = make_image(&img_data, 5, 5, 2);
    if let ClipboardEntry::Text { ref mut source_name, ref mut source_bundle_id, .. } = t {
        *source_name = "Safari".into();
        *source_bundle_id = "com.apple.Safari".into();
    }
    if let ClipboardEntry::Image { ref mut source_name, ref mut source_bundle_id, .. } = i {
        *source_name = "Photos".into();
        *source_bundle_id = "com.apple.Photos".into();
    }
    assert_eq!(t.source_name(), "Safari");
    assert_eq!(t.source_bundle_id(), "com.apple.Safari");
    assert_eq!(i.source_name(), "Photos");
    assert_eq!(i.source_bundle_id(), "com.apple.Photos");
}

#[test]
fn test_item_types() {
    let t = make_text("test", 1);
    let img_data = make_test_image_rgba(5, 5, 50);
    let i = make_image(&img_data, 5, 5, 2);
    assert_eq!(t.content_type(), 0);
    assert_eq!(i.content_type(), 1);
}

#[test]
fn test_item_timestamps() {
    let t = make_text("a", 1000);
    let img_data = make_test_image_rgba(5, 5, 50);
    let i = make_image(&img_data, 5, 5, 2000);
    assert_eq!(t.timestamp(), 1000);
    assert_eq!(i.timestamp(), 2000);
}

// ═══════════════════════════════════════════
// Label Tests
// ═══════════════════════════════════════════

#[test]
fn test_label_text() {
    let t = make_text("Hello World", 100);
    assert_eq!(t.label(), "Hello World");
}

#[test]
fn test_label_image() {
    let img_data = make_test_image_rgba(1920, 1080, 128);
    let i = make_image(&img_data, 1920, 1080, 100);
    assert_eq!(i.label(), "Image (1920×1080)");
}

#[test]
fn test_label_multibyte() {
    let cn = "这是一个测试中文文本用于验证标签截断功能是否正常工作";
    let t = make_text(cn, 100);
    let label = t.label();
    assert!(label.chars().count() <= 61);
    assert!(label.contains("这是一个"));
}

#[test]
fn test_free_string_null_safe() {
    clipboard_free_string(std::ptr::null_mut());
}

// ═══════════════════════════════════════════
// Auto-Cleanup Threshold Tests
// ═══════════════════════════════════════════

fn fill_and_trim_to(threshold: usize, count: usize) -> Vec<ClipboardEntry> {
    let mut hist = Vec::with_capacity(count);
    for i in 0..count {
        let item = make_text(&format!("item-{:04}", i), i as u64);
        hist = add_to_history(std::mem::take(&mut hist), item);
        while hist.len() > threshold {
            hist.pop();
        }
    }
    hist
}

#[test]
fn test_auto_cleanup_at_threshold_100() {
    let hist = fill_and_trim_to(100, 150);
    assert_eq!(hist.len(), 100);
}

#[test]
fn test_auto_cleanup_at_threshold_500() {
    let hist = fill_and_trim_to(500, 750);
    assert_eq!(hist.len(), 500);
}

#[test]
fn test_auto_cleanup_at_threshold_1000() {
    let hist = fill_and_trim_to(1000, 1500);
    assert_eq!(hist.len(), 1000);
}

#[test]
fn test_auto_cleanup_at_threshold_2000() {
    let hist = fill_and_trim_to(2000, 3000);
    assert_eq!(hist.len(), 2000);
}

#[test]
fn test_auto_cleanup_at_threshold_3000() {
    let hist = fill_and_trim_to(3000, 4500);
    assert_eq!(hist.len(), 3000);
}

#[test]
fn test_auto_cleanup_at_threshold_5000() {
    let hist = fill_and_trim_to(5000, 7500);
    assert_eq!(hist.len(), 5000);
}

#[test]
fn test_auto_cleanup_keeps_newest() {
    let hist = fill_and_trim_to(10, 50);
    assert_eq!(hist.len(), 10);
    if let ClipboardEntry::Text { text, .. } = &hist[0] {
        assert_eq!(text, "item-0049");
    } else {
        panic!("Expected Text entry at head");
    }
}

#[test]
fn test_auto_cleanup_removes_oldest() {
    let hist = fill_and_trim_to(10, 50);
    if let ClipboardEntry::Text { text, .. } = &hist[9] {
        assert_eq!(text, "item-0040");
    } else {
        panic!("Expected Text entry at tail");
    }
}

#[test]
fn test_auto_cleanup_no_trim_below_threshold() {
    let hist = fill_and_trim_to(100, 50);
    assert_eq!(hist.len(), 50);
}

#[test]
fn test_auto_cleanup_empty_history() {
    let hist = fill_and_trim_to(100, 0);
    assert!(hist.is_empty());
}

#[test]
fn test_auto_cleanup_exactly_at_threshold() {
    let hist = fill_and_trim_to(100, 100);
    assert_eq!(hist.len(), 100);
}

// ═══════════════════════════════════════════
// Trim-Oldest-Percent Tests
// ═══════════════════════════════════════════

fn simulate_trim_oldest_percent(
    mut hist: Vec<ClipboardEntry>, percent: usize,
) -> (Vec<ClipboardEntry>, Vec<ClipboardEntry>) {
    let total = hist.len();
    if total == 0 {
        return (hist, vec![]);
    }
    let count = ((total as f64 * percent as f64 / 100.0).ceil()) as usize;
    let count = count.min(total);
    let split_at = total - count;
    let removed = hist.split_off(split_at);
    (hist, removed)
}

#[test]
fn test_trim_percent_0() {
    let hist: Vec<_> = (0..100).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 0);
    assert_eq!(kept.len(), 100);
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_100() {
    let hist: Vec<_> = (0..100).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 100);
    assert!(kept.is_empty());
    assert_eq!(removed.len(), 100);
}

#[test]
fn test_trim_percent_40() {
    let mut hist = Vec::new();
    for i in 0..100 {
        hist = add_to_history(hist, make_text(&format!("t-{:03}", i), i as u64));
    }
    assert_eq!(hist.len(), 100);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 60);
    assert_eq!(removed.len(), 40);
    if let ClipboardEntry::Text { text, .. } = &kept[0] {
        assert_eq!(text, "t-099");
    }
    if let ClipboardEntry::Text { text, .. } = &removed[0] {
        assert_eq!(text, "t-039");
    }
}

#[test]
fn test_trim_percent_50_even() {
    let hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 50);
    assert_eq!(kept.len(), 25);
    assert_eq!(removed.len(), 25);
}

#[test]
fn test_trim_percent_ceil_small_count() {
    let hist: Vec<_> = (0..3).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 1);
    assert_eq!(removed.len(), 2);
}

#[test]
fn test_trim_percent_empty() {
    let (kept, removed) = simulate_trim_oldest_percent(vec![], 40);
    assert!(kept.is_empty());
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_ceil_single_entry() {
    let hist = vec![make_text("only", 0)];
    let (kept, removed) = simulate_trim_oldest_percent(hist, 1);
    assert!(kept.is_empty());
    assert_eq!(removed.len(), 1);
}

#[test]
fn test_trim_percent_all_thresholds_consistency() {
    for &threshold in &[100, 500, 1000, 2000, 3000, 5000] {
        let over = (threshold as f64 * 1.1) as usize;
        let mut hist = fill_and_trim_to(threshold, over);
        assert_eq!(hist.len(), threshold, "failed fill at threshold {}", threshold);
        let kept_count = threshold - ((threshold as f64 * 0.4).ceil()) as usize;
        let (kept, _) = simulate_trim_oldest_percent(hist, 40);
        assert_eq!(kept.len(), kept_count, "failed trim at threshold {}", threshold);
        hist = kept;
    }
}

// ═══════════════════════════════════════════
// Dynamic Threshold Change Tests
// ═══════════════════════════════════════════

#[test]
fn test_threshold_reduction_trims_history() {
    let mut hist: Vec<_> = (0..200).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    assert_eq!(hist.len(), 200);

    let new_threshold = 100usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert_eq!(hist.len(), 100);

    if let ClipboardEntry::Text { text, .. } = &hist[0] {
        assert_eq!(text, "t-199");
    }
    if let ClipboardEntry::Text { text, .. } = &hist[99] {
        assert_eq!(text, "t-100");
    }
}

#[test]
fn test_threshold_increase_preserves_all() {
    let mut hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    let new_threshold = 100usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert_eq!(hist.len(), 50);
}

#[test]
fn test_threshold_reduction_to_minimum() {
    let mut hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    let new_threshold = 0usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert!(hist.is_empty());
}

// ═══════════════════════════════════════════
// In-Memory History Layout Tests
// ═══════════════════════════════════════════

#[test]
fn test_in_memory_order_newest_first() {
    let mut hist = Vec::new();
    for i in 0..5 {
        hist = add_to_history(hist, make_text(&format!("item-{}", i), i as u64));
    }
    assert_eq!(hist.len(), 5);
    if let ClipboardEntry::Text { text, .. } = &hist[0] {
        assert_eq!(text, "item-4");
    }
    if let ClipboardEntry::Text { text, .. } = &hist[4] {
        assert_eq!(text, "item-0");
    }
}

// ═══════════════════════════════════════════
// Threshold Performance Benchmarks
// ═══════════════════════════════════════════
//
// Run with: cargo test benchmark_thresholds -- --nocapture
//
// Measures at each threshold (100, 500, 1000, 2000, 3000, 5000):
//   - 内存占用: Vec 自身容量 + String heap 分配 → heap 总估计
//   - 存储占用: SQLite DB 文件大小
//   - 运行性能: 稳态下每添加一条的平均耗时（含去重扫描+头部插入+尾部pop）
//               以及完整快照克隆耗时、DB 写入耗时

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
//
// Run with: cargo test benchmark_images -- --nocapture
//
// Measures image capture performance and DB storage at each threshold.
// In-memory image entries carry empty blobs (matches real app behavior).
// DB stores full PNG + thumbnail for each image.

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
        let thumb_l3 = create_thumbnail(w, h, &rgba, 500)
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

// ═══════════════════════════════════════════
// Entry ID Persistence Tests
// ═══════════════════════════════════════════

use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db, trim_db_history};
use crate::backend::prime_entry_id;

/// Helper: open an in-memory SQLite DB for testing.
fn test_db() -> Connection {
    let conn = Connection::open_in_memory().expect("failed to create in-memory DB");
    ensure_history_table(&conn).expect("failed to create table");
    conn
}

/// Helper: insert a text entry with known content and return its db_id.
fn insert_text(conn: &Connection, text: &str, ts: u64) -> i64 {
    let entry = ClipboardEntry::Text {
        id: new_entry_id(),
        text: text.to_string(),
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    };
    insert_entry_to_db(conn, &entry, None, None).expect("insert failed");
    conn.last_insert_rowid()
}

#[test]
fn test_entry_id_persistence_and_restore() {
    // Use a file-backed DB to test cross-session ID stability.
    let db_path = std::env::temp_dir().join(format!(
        "copyattach_test_eid_{}.db", std::process::id()
    ));
    let _ = std::fs::remove_file(&db_path);

    // Simulate first launch: open DB, insert entries, reload and verify IDs.
    let conn = Connection::open(&db_path).expect("failed to open temp DB");
    ensure_history_table(&conn).expect("failed to create table");
    let _a = insert_text(&conn, "alpha", 100);
    let _b = insert_text(&conn, "beta", 200);
    let _c = insert_text(&conn, "gamma", 300);

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 3, "should load all 3 entries");

    assert_eq!(loaded[0].text(), "gamma", "newest first");
    assert_eq!(loaded[1].text(), "beta");
    assert_eq!(loaded[2].text(), "alpha");

    let ids: Vec<u64> = loaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();
    assert!(ids[0] != 0, "entry_id must not be zero");
    assert_ne!(ids[0], ids[1], "entry IDs must be unique");
    assert_ne!(ids[1], ids[2], "entry IDs must be unique");

    // Simulate restart: close conn, open fresh, reload → IDs must match.
    drop(conn);

    // Reopen same DB file (simulates app restart).
    let conn = Connection::open(&db_path).expect("failed to reopen temp DB");
    ensure_history_table(&conn).expect("migration idempotent");
    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 3, "same count after reload");

    let reloaded_ids: Vec<u64> = reloaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();
    assert_eq!(reloaded_ids, ids,
        "entry_ids must survive restart (reload must read from DB, not assign fresh)");

    let _ = std::fs::remove_file(&db_path);
}

#[test]
fn test_entry_id_stable_after_delete() {
    let conn = test_db();
    let _id_a = insert_text(&conn, "a", 100);
    let _id_b = insert_text(&conn, "b", 200);
    let _id_c = insert_text(&conn, "c", 300);

    let before = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    let ids_before: Vec<u64> = before.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    // Delete the middle entry ("b") via its db_id.
    // (Find db_id by matching text "b".)
    let db_id_b: i64 = {
        let mut stmt = conn.prepare(
            "SELECT id FROM clipboard_history WHERE entry_type = 0 AND text = 'b'"
        ).unwrap();
        stmt.query_row([], |row| row.get(0)).unwrap()
    };
    conn.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![db_id_b])
        .unwrap();

    let after = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(after.len(), 2, "one entry deleted");

    let ids_after: Vec<u64> = after.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    // "c" (index 0) and "a" (index 1) must retain their original IDs.
    assert_eq!(ids_after[0], ids_before[0], "newest entry ID stable after delete");
    assert_eq!(ids_after[1], ids_before[2], "oldest entry ID stable after delete");
    assert_eq!(after[0].text(), "c", "newest preserved");
    assert_eq!(after[1].text(), "a", "oldest preserved");
}

#[test]
fn test_entry_id_monotonic_after_reload() {
    // Simulate full lifecycle: first session inserts, reloads, then inserts
    // more. New IDs must not collide with restored IDs.
    let conn = test_db();

    // First batch: 3 entries.
    let _a = insert_text(&conn, "first-batch-a", 100);
    let _b = insert_text(&conn, "first-batch-b", 200);
    let _c = insert_text(&conn, "first-batch-c", 300);

    // Simulate restart: reload, then prime the counter.
    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    let max_loaded = loaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).max().unwrap();
    prime_entry_id(max_loaded + 1);

    // Insert a new entry after restart — must get a fresh ID above all loaded.
    let new_id = new_entry_id();
    assert!(new_id > max_loaded,
        "new entry_id {} must be > max loaded ID {}", new_id, max_loaded);

    let entry_new = ClipboardEntry::Text {
        id: new_id,
        text: "post-restart".to_string(),
        timestamp: 999,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    };
    insert_entry_to_db(&conn, &entry_new, None, None).unwrap();

    // Reload again — all 4 entries must have stable IDs.
    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 4, "4 entries total after post-restart insert");

    let all_ids: Vec<u64> = reloaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    // The three original entries must retain their original IDs.
    for orig in &loaded {
        let orig_id = match orig {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert!(all_ids.contains(&orig_id),
            "original entry_id {} must survive restart", orig_id);
    }
    // The new entry must have its assigned ID.
    assert!(all_ids.contains(&new_id),
        "post-restart entry_id {} must be present", new_id);
}

#[test]
fn test_entry_id_backfill_old_rows() {
    // Simulate an old DB that was created before the entry_id column existed.
    // After ALTER TABLE + backfill, entry_id is set to the SQLite rowid.
    let conn = Connection::open_in_memory().expect("in-memory DB");
    conn.execute_batch(
        "CREATE TABLE clipboard_history (
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
            timestamp       INTEGER NOT NULL DEFAULT 0,
            source_name     TEXT NOT NULL DEFAULT '',
            source_bundle_id TEXT NOT NULL DEFAULT ''
        );"
    ).unwrap();
    // Insert rows WITHOUT entry_id column (old schema).
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, timestamp)
         VALUES (0, 'legacy-a', 100)",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, timestamp)
         VALUES (0, 'legacy-b', 200)",
        [],
    ).unwrap();

    // Now run the migration (add entry_id column + backfill).
    ensure_history_table(&conn).unwrap();

    // Load — both rows must have non-zero entry_ids.
    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 2);
    for e in &loaded {
        let eid = match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert!(eid > 0, "backfilled entry_id must be non-zero, got {}", eid);
    }

    // Reload (simulate second restart) — IDs must be identical.
    let loaded2 = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    for (orig, reload) in loaded.iter().zip(loaded2.iter()) {
        let oid = match orig {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        let rid = match reload {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert_eq!(oid, rid, "legacy entry_id stable across restarts");
    }
}

#[test]
fn test_clipboard_delete_by_id_returns_zero_on_failure() {
    // Verify that clipboard_delete_by_id returns 0 (failure) when the entry
    // doesn't exist — proving the failure path that Finding 1 relies on.
    //
    // This path triggers in the Swift deleteItem(at:) flow when:
    //   1. deleteKeyNotification handler -> deleteItem(at: itemIndex)
    //   2. backend.deleteEntry(at:) calls clipboard_delete_by_id in Rust
    //   3. If this returns 0, deleteEntry returns false
    //   4. But searchResults.removeAll { $0.id == item.id } has already run

    use std::sync::{Arc, Mutex, atomic::{AtomicBool, AtomicU64, AtomicUsize}};
    use crate::backend::{Backend, set_backend};
    use crate::ffi::clipboard_delete_by_id;
    use crate::ignore::IgnoreRules;
    use crate::types::SourceApp;

    // Initialize the Backend singleton exactly once for all tests that need it.
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let conn = Connection::open_in_memory()
            .expect("in-memory DB for test");
        crate::db::ensure_history_table(&conn)
            .expect("schema creation");
        let backend = Backend {
            history: Arc::new(Mutex::new(Vec::new())),       // empty history
            running: Arc::new(AtomicBool::new(true)),
            monitor_handle: Mutex::new(None),
            source_app: Arc::new(Mutex::new(SourceApp::default())),
            last_seen_text: Arc::new(Mutex::new(None)),
            last_seen_image_hash: Arc::new(Mutex::new(None)),
            pasteboard_event_lock: Arc::new(Mutex::new(())),
            pending_self_write: Arc::new(Mutex::new(None)),
            db: Arc::new(Mutex::new(conn)),
            cleanup_threshold: Arc::new(AtomicUsize::new(3000)),
            ignore_rules: Arc::new(Mutex::new(IgnoreRules::default())),
            deleted_stack: Arc::new(Mutex::new(Vec::new())),
            last_restored_id: Arc::new(AtomicU64::new(0)),
            image_paste_use_ctrl_v: Arc::new(AtomicBool::new(false)),
        };
        set_backend(backend)
            .expect("Backend singleton must not be set before this test");
    });

    // Test 1: non-existent entry ID → returns 0
    assert_eq!(
        clipboard_delete_by_id(99999),
        0,
        "deleting a non-existent entry ID must return 0 (failure)"
    );

    // Test 2: entry ID 0 (never valid) → returns 0
    assert_eq!(
        clipboard_delete_by_id(0),
        0,
        "deleting entry ID 0 must return 0 (failure)"
    );

    // Test 3: empty history → any ID returns 0
    assert_eq!(
        clipboard_delete_by_id(1),
        0,
        "deleting from empty history must return 0 (failure)"
    );
}

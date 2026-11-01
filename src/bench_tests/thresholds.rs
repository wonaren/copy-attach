use crate::backend::new_entry_id;
use crate::history::add_to_history;
use crate::types::ClipboardEntry;
use rusqlite::Connection;
use super::{create_bench_table, estimate_vec_heap, format_bytes};

fn bench_text(index: u64) -> (ClipboardEntry, String) {
    let text = format!(
        "benchmark-item-{:06}: The quick brown fox jumps over the lazy dog #{}",
        index, index
    );
    let entry = ClipboardEntry::text_entry(
        new_entry_id(),
        &text,
        index,
        String::from("Benchmark"),
        String::from("com.benchmark"),
        0,
    );
    (entry, text)
}

#[test]
fn benchmark_thresholds() {
    let thresholds: [usize; 6] = [100, 500, 1000, 2000, 3000, 5000];
    const STEADY_STATE_SAMPLES: usize = 50;

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

        let conn = Connection::open(&db_path)
            .expect("bench: failed to open temp DB");
        conn.execute_batch(
            "PRAGMA mmap_size = 268435456;
             PRAGMA cache_size = -512;",
        )
        .expect("bench: pragma failed");
        create_bench_table(&conn);

        let mut hist = Vec::with_capacity(threshold + STEADY_STATE_SAMPLES);
        let mut db_write_total = std::time::Duration::new(0, 0);

        let mut last_db_id: i64 = 0;

        for i in 0..threshold {
            let (item, text) = bench_text(i as u64);

            let db_start = std::time::Instant::now();
            conn.execute(
                "INSERT INTO clipboard_history (entry_type, text, timestamp, source_name, source_bundle_id)
                 VALUES (0, ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    &text,
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
                rusqlite::params![text],
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

            hist = add_to_history(std::mem::take(&mut hist), item);
            while hist.len() > threshold {
                hist.pop();
            }
        }
        assert_eq!(hist.len(), threshold);

        if let Some(head) = hist.get_mut(0) {
            match head {
                ClipboardEntry::Text { ref mut db_id, .. }
                | ClipboardEntry::Image { ref mut db_id, .. } => {
                    *db_id = last_db_id;
                }
            }
        }

        let mut add_times = Vec::with_capacity(STEADY_STATE_SAMPLES);
        let mut db_times = Vec::with_capacity(STEADY_STATE_SAMPLES);

        for j in 0..STEADY_STATE_SAMPLES {
            let (item, text) = bench_text((threshold + j) as u64);

            let db_start = std::time::Instant::now();
            conn.execute(
                "INSERT INTO clipboard_history (entry_type, text, timestamp, source_name, source_bundle_id)
                 VALUES (0, ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    &text,
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
                rusqlite::params![text],
            )
            .expect("bench: steady DB dedup failed");
            conn.execute(
                "DELETE FROM clipboard_history WHERE id NOT IN (
                    SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
                rusqlite::params![threshold as i64],
            )
            .expect("bench: steady DB trim failed");
            db_times.push(db_start.elapsed());

            let add_start = std::time::Instant::now();
            hist = add_to_history(std::mem::take(&mut hist), item);
            while hist.len() > threshold {
                hist.pop();
            }
            add_times.push(add_start.elapsed());

            assert_eq!(hist.len(), threshold);
        }

        let clone_start = std::time::Instant::now();
        let _snapshot = hist.clone();
        let clone_time = clone_start.elapsed();
        drop(_snapshot);

        let mem_estimate = estimate_vec_heap(&hist);

        let db_size = std::fs::metadata(&db_path)
            .map(|m| m.len())
            .expect("bench: metadata failed");

        let avg_add = add_times.iter().sum::<std::time::Duration>()
            / STEADY_STATE_SAMPLES as u32;
        let avg_db = db_times.iter().sum::<std::time::Duration>()
            / STEADY_STATE_SAMPLES as u32;

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

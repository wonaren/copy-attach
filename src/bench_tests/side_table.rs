use rusqlite::Connection;
use std::time::Instant;

use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db};
use crate::types::ClipboardEntry;

fn big_blob() -> Vec<u8> {
    vec![0xABu8; 4 * 1024 * 1024]
}

fn bench_db() -> Connection {
    let conn = Connection::open_in_memory().expect("open bench db");
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = OFF;
         PRAGMA mmap_size = 0;
         PRAGMA cache_size = -4096;",
    )
    .expect("pragma");
    ensure_history_table(&conn).expect("schema");
    conn
}

fn fill_history(conn: &Connection, live_rows: usize, image_every: usize) -> Vec<i64> {
    let blob = big_blob();
    let thumb = vec![0xCDu8; 8 * 1024];
    let mut ids = Vec::with_capacity(live_rows);
    for i in 0..live_rows {
        let id = crate::backend::new_entry_id();
        let ts = i as u64;
        if i % image_every == 0 {
            let entry = ClipboardEntry::Image {
                id,
                width: 2560,
                height: 1600,
                thumb_width: 356,
                thumb_height: 200,
                hash: id,
                custom_label: String::new(),
                timestamp: ts,
                source_name: "Bench".to_string(),
                source_bundle_id: "com.bench".to_string(),
                db_id: 0,
            };
            insert_entry_to_db(conn, &entry, None, Some(&blob), Some((&thumb, 356, 200)))
                .expect("insert image");
        } else {
            let body = format!("bench text row {i}");
            let entry = ClipboardEntry::text_entry(
                id, &body, ts, "Bench".to_string(), "com.bench".to_string(), 0,
            );
            insert_entry_to_db(conn, &entry, Some(&body), None, None).expect("insert text");
        }
        ids.push(conn.last_insert_rowid());
    }
    ids
}

fn mark_deleted(conn: &Connection, ids: &[i64], n: usize) {
    let base = crate::backend::undo_stamp_now();
    for (i, row_id) in ids.iter().enumerate().take(n) {
        conn.execute(
            "INSERT OR IGNORE INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
             VALUES (?1, (SELECT entry_id FROM clipboard_history WHERE id = ?1), ?2, 0)",
            rusqlite::params![row_id, base + i as i64],
        )
        .expect("mark deleted");
    }
}

fn time_query<F: FnMut()>(mut f: F, iters: usize) -> f64 {
    f();
    let start = Instant::now();
    for _ in 0..iters {
        f();
    }
    start.elapsed().as_secs_f64() * 1000.0 / iters as f64
}

#[test]
#[ignore = "measurement, run explicitly with --ignored --nocapture"]
fn bench_side_table_growth() {
    let conn = bench_db();
    let live_rows = 3000;
    let image_every = 20;
    let ids = fill_history(&conn, live_rows, image_every);
    println!(
        "history: {live_rows} rows ({} images x 4 MB)",
        live_rows.div_ceil(image_every)
    );

    println!(
        "\n{:>10}  {:>14}  {:>16}  {:>14}  {:>12}  {:>12}",
        "deleted", "load_history", "trim_db_history", "undo_depth", "undoable_MB", "evict_preview"
    );

    let mut marked = 0usize;
    for target in [0usize, 10, 50, 100, 150, 300, 600, 1200, 2400] {
        if target > marked {
            mark_deleted(&conn, &ids[marked..], target - marked);
            marked = target;
        }
        let deleted: i64 = conn
            .query_row("SELECT COUNT(*) FROM clipboard_deleted", [], |r| r.get(0))
            .unwrap();
        let bytes: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(
                     COALESCE(LENGTH(h.text), 0)
                   + COALESCE(LENGTH(h.png_data), 0)
                   + COALESCE(LENGTH(h.thumb_data), 0)), 0)
                 FROM clipboard_deleted d JOIN clipboard_history h ON h.id = d.row_id",
                [],
                |r| r.get(0),
            )
            .unwrap();

        let load_ms = time_query(|| {
            let v = load_history_from_db(&conn, 3000);
            std::hint::black_box(v);
        }, 5);
        let trim_ms = time_query(|| {
            let mut stmt = conn
                .prepare(
                    "DELETE FROM clipboard_history
                     WHERE id IN (SELECT id FROM clipboard_history
                                  WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                                    AND entry_id NOT IN (SELECT entry_id FROM clipboard_favorites)
                                  ORDER BY timestamp ASC, id ASC
                                  LIMIT (SELECT MAX(0,
                                           (SELECT COUNT(*) FROM clipboard_history
                                             WHERE id NOT IN (SELECT row_id FROM clipboard_deleted))
                                           - (SELECT COUNT(*) FROM clipboard_favorites)
                                           - 3000)))",
                )
                .expect("prepare trim");
            let plan: Vec<String> = stmt
                .query_map([], |r| r.get::<_, String>(3))
                .expect("plan")
                .flatten()
                .collect();
            std::hint::black_box(plan);
        }, 5);
        let depth_ms = time_query(|| {
            let v = crate::db::undo_depth(&conn).expect("depth");
            std::hint::black_box(v);
        }, 50);
        let newest_row = ids[marked.min(ids.len() - 1)];
        let (preview_ms, row_bytes) = {
            let mut row_bytes = 0i64;
            let ms = time_query(|| {
                let incoming = crate::db::history_row_payload_bytes(&conn, newest_row)
                    .expect("row payload bytes");
                row_bytes = incoming;
                let n = crate::db::pending_undo_evictions(&conn, incoming, 16 * 1024 * 1024)
                    .expect("preview");
                std::hint::black_box(n);
            }, 20);
            (ms, row_bytes)
        };

        println!(
            "{:>10}  {:>11.2} ms  {:>13.2} ms  {:>11.3} ms  {:>9.1} MB  {:>9.3} ms (row {} bytes)",
            deleted,
            load_ms,
            trim_ms,
            depth_ms,
            bytes as f64 / (1024.0 * 1024.0),
            preview_ms,
            row_bytes
        );
    }
}

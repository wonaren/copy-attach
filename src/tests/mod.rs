//! Unit tests for clipboard history management and image processing.
//!
//! ⚠️  Benchmarks are in bench_tests.rs, run with `cargo test --features stress-test`.
//!
//! Submodules group the tests by subject (history, image, search, cleanup,
//! entry-id persistence, FFI/undo). Shared test helpers live here.

use crate::backend::new_entry_id;
use crate::db::{ensure_history_table, insert_entry_to_db};
use crate::history::add_to_history;
use crate::image::{create_thumbnail, image_hash};
use crate::types::ClipboardEntry;
use rusqlite::Connection;

mod history;
mod image;
mod search;
mod cleanup;
mod db;
mod migration;
mod backend;

fn make_text(text: &str, ts: u64) -> ClipboardEntry {
    ClipboardEntry::text_entry(
        new_entry_id(),
        text,
        ts,
        String::new(),
        String::new(),
        0,
    )
}

/// Stamp db_ids in rowid order: the newest entry (head) keeps the largest id,
/// the oldest (tail) the smallest — exactly the ordering SQLite's
/// autoincrement rowids produce. Tests that exercise identity-based removal
/// need real ids, since a 0 stands for "not persisted" and is never a row.
fn assign_row_ids(hist: &mut [ClipboardEntry]) {
    let n = hist.len();
    for (i, entry) in hist.iter_mut().enumerate() {
        let db_id = (n - i) as i64;
        match entry {
            ClipboardEntry::Text { db_id: d, .. } | ClipboardEntry::Image { db_id: d, .. } => {
                *d = db_id;
            }
        }
    }
}

fn make_image(data: &[u8], w: u32, h: u32, ts: u64) -> ClipboardEntry {
    let hash = image_hash(data, w, h);
    let thumb = create_thumbnail(w, h, data).unwrap();
    ClipboardEntry::Image {
        id: new_entry_id(),
        width: w,
        height: h,
        thumb_width: thumb.1,
        thumb_height: thumb.2,
        hash,
        custom_label: String::new(),
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    }
}

fn make_test_image_rgba(w: u32, h: u32, fill_byte: u8) -> Vec<u8> {
    vec![fill_byte; (w * h * 4) as usize]
}

/// Open an in-memory SQLite DB for testing.
fn test_db() -> Connection {
    let conn = Connection::open_in_memory().expect("failed to create in-memory DB");
    ensure_history_table(&conn).expect("failed to create table");
    conn
}

/// Insert a text entry with known content and return its db_id.
fn insert_text(conn: &Connection, text: &str, ts: u64) -> i64 {
    let entry = ClipboardEntry::text_entry(
        new_entry_id(),
        text,
        ts,
        String::new(),
        String::new(),
        0,
    );
    insert_entry_to_db(conn, &entry, Some(text), None, None).expect("insert failed");
    conn.last_insert_rowid()
}

/// Fill history to `count` entries while trimming to `threshold` after every
/// insert — mirrors the monitor thread's add + trim loop.
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

/// Mirror of `clipboard_trim_oldest_percent` for unit testing the
/// percent/ceil arithmetic without a live backend.
///
/// Models the production contract faithfully on two points that the previous
/// tail-split mirror did not: the count is "how many DB rows the DELETE
/// actually removed", and memory removal is by identity (db_id) rather than by
/// position. Tests can therefore assert the DB/memory consistency invariant.
fn simulate_trim_oldest_percent(
    mut hist: Vec<ClipboardEntry>, percent: usize,
) -> (Vec<ClipboardEntry>, Vec<ClipboardEntry>) {
    let total = hist.len();
    if total == 0 {
        return (hist, vec![]);
    }
    let count = ((total as f64 * percent as f64 / 100.0).ceil()) as usize;
    let count = count.min(total);
    // Which rows the DELETE would have removed: oldest by row order.
    let mut by_row: Vec<(i64, usize)> = hist
        .iter()
        .enumerate()
        .filter(|(_, e)| e.db_id() != 0)
        .map(|(i, e)| (e.db_id(), i))
        .collect();
    by_row.sort_by_key(|(db_id, _)| *db_id);
    let doomed: std::collections::HashSet<i64> =
        by_row.iter().take(count).map(|(db_id, _)| *db_id).collect();
    let mut kept = Vec::with_capacity(hist.len());
    let mut removed = Vec::new();
    for entry in hist.drain(..) {
        if doomed.contains(&entry.db_id()) {
            removed.push(entry);
        } else {
            kept.push(entry);
        }
    }
    (kept, removed)
}

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

/// Mirror of `clipboard_trim_oldest_percent`'s in-memory split for unit testing
/// the percent/ceil arithmetic without a live backend.
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

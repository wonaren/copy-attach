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
mod backup;
mod soft_delete;
mod soft_delete_real;
mod quick_slots;

static SHARED_STATE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub(crate) fn shared_state_guard() -> std::sync::MutexGuard<'static, ()> {
    SHARED_STATE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

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

fn test_db() -> Connection {
    let conn = Connection::open_in_memory().expect("failed to create in-memory DB");
    ensure_history_table(&conn).expect("failed to create table");
    conn
}

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

fn simulate_trim_oldest_percent(
    hist: Vec<ClipboardEntry>,
    percent: usize,
) -> (Vec<ClipboardEntry>, Vec<ClipboardEntry>) {
    simulate_trim_oldest_percent_with_favorites(hist, percent, &std::collections::HashSet::new())
}

fn simulate_trim_oldest_percent_with_favorites(
    mut hist: Vec<ClipboardEntry>,
    percent: usize,
    favorites: &std::collections::HashSet<u64>,
) -> (Vec<ClipboardEntry>, Vec<ClipboardEntry>) {
    let cleanable_total = hist
        .iter()
        .filter(|e| !favorites.contains(&e.entry_id()))
        .count();
    if cleanable_total == 0 {
        return (hist, vec![]);
    }
    let count = ((cleanable_total as f64 * percent as f64 / 100.0).ceil()) as usize;
    let count = count.min(cleanable_total);
    let mut by_row: Vec<(i64, usize)> = hist
        .iter()
        .enumerate()
        .filter(|(_, e)| e.db_id() != 0 && !favorites.contains(&e.entry_id()))
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

use crate::types::ClipboardEntry;
use rusqlite::Connection;

mod thresholds;
mod images;
mod memory_probe;
mod side_table;

fn estimate_vec_heap(hist: &[ClipboardEntry]) -> usize {
    let vec_backing = std::mem::size_of_val(hist);
    let string_heap: usize = hist
        .iter()
        .map(|entry| match entry {
            ClipboardEntry::Text { preview, label, source_name, source_bundle_id, .. } => {
                preview.capacity() + label.capacity() + source_name.capacity() + source_bundle_id.capacity()
            }
            ClipboardEntry::Image {
                source_name, source_bundle_id, ..
            } => {
                source_name.capacity() + source_bundle_id.capacity()
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

fn create_bench_table(conn: &Connection) {
    crate::db::ensure_history_table(conn).expect("bench: failed to create table");
}

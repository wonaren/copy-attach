//! Performance benchmarks for clipboard history management and image processing.
//!
//! Run with: cargo test --features stress-test -- --nocapture
//!
//! Individual benchmarks:
//!   cargo test --features stress-test benchmark_thresholds -- --nocapture
//!   cargo test --features stress-test benchmark_images -- --nocapture
//!
//! Submodules: `thresholds` (history-size scaling), `images` (capture/DB
//! throughput), `memory_probe` (FTS index resident-memory isolation). Shared
//! measurement helpers live here.

use crate::types::ClipboardEntry;
use rusqlite::Connection;

mod thresholds;
mod images;
mod memory_probe;

/// Estimate total heap allocation for a history Vec (vec backing + string buffers).
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

/// Create the full app schema — including the FTS5 index and its sync triggers —
/// so the benchmark's DB write measurements include index maintenance, exactly
/// as they happen in the real backend.
fn create_bench_table(conn: &Connection) {
    crate::db::ensure_history_table(conn).expect("bench: failed to create table");
}

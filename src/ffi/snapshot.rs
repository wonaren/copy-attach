use std::ffi::{c_char, c_int, c_longlong};

use super::to_ffi_cstring;
use crate::backend::try_backend;
use crate::types::ClipboardEntry;

/// Lightweight snapshot row: exactly the fields the frontend list consumes.
/// The full text is deliberately NOT carried — a refresh snapshot must stay
/// small even when history holds many multi-KB pasted documents.
pub(crate) struct SnapshotRow {
    pub(crate) entry_type: i32,
    pub(crate) id: i64,
    pub(crate) timestamp: i64,
    pub(crate) label: String,
    pub(crate) custom_label: String,
    pub(crate) source_name: String,
    pub(crate) source_bundle_id: String,
    pub(crate) preview: String, // text entries only; empty for images
    pub(crate) db_id: i64,      // image entries only; 0 otherwise
    pub(crate) width: i32,
    pub(crate) height: i32,
}

impl SnapshotRow {
    pub(crate) fn from_entry(entry: &ClipboardEntry) -> SnapshotRow {
        let (preview, db_id, width, height) = match entry {
            ClipboardEntry::Text { .. } => (entry.preview(), 0, 0, 0),
            ClipboardEntry::Image {
                db_id,
                width,
                height,
                ..
            } => (String::new(), *db_id, *width as i32, *height as i32),
        };
        SnapshotRow {
            entry_type: entry.content_type(),
            id: entry.entry_id() as i64,
            timestamp: entry.timestamp() as i64,
            label: entry.label(),
            custom_label: entry.custom_label().to_string(),
            source_name: entry.source_name().to_string(),
            source_bundle_id: entry.source_bundle_id().to_string(),
            preview,
            db_id,
            width,
            height,
        }
    }
}

/// Opaque handle to a lightweight snapshot of clipboard history, taken under a
/// single history lock. Holds compact metadata + bounded previews — never full
/// text — so acquiring it does not deep-clone potentially many MB of pasted
/// content. All reads from this snapshot are race-free: the background monitor
/// thread cannot modify it.
pub struct Snapshot(Vec<SnapshotRow>);

/// Acquire a consistent snapshot of all history entries under one lock.
/// Returns an opaque handle (or null if the backend is uninitialized).
/// Caller must release with `clipboard_snapshot_release()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_acquire() -> *mut Snapshot {
    let hist = match try_backend() {
        Some(b) => b.history.lock().unwrap(),
        None => return std::ptr::null_mut(),
    };
    let rows: Vec<SnapshotRow> = hist.iter().map(SnapshotRow::from_entry).collect();
    // Swift reads the rows across the FFI for the popup's lifetime; claim any
    // reusable-marked pages the allocator handed back (see vec_to_raw).
    crate::backend::claim_pages(
        rows.as_ptr().cast::<u8>(),
        rows.capacity() * std::mem::size_of::<SnapshotRow>(),
    );
    Box::into_raw(Box::new(Snapshot(rows)))
}
// Packed snapshot wire format (one allocation, no per-field CString churn)
//
// The per-row snapshot API above allocates and frees one CString per string
// field on every full-history reload. For 3000 rows that is ~9k-12k tiny
// allocations per refresh, all of them in the malloc small zone and exactly
// the transient churn that keeps dirty pages at a high water mark. This API
// serializes the whole snapshot into a single caller-owned byte buffer:
//
//   header  : 4 bytes "CSNP", u32 version, u32 row_count, u32 flags
//   per row : 56-byte fixed header (all integers little-endian)
//             i32 entry_type, i64 id, i64 timestamp, i64 db_id,
//             i32 width, i32 height,
//             u32 custom_label_len,
//             u32 label_len, u32 source_name_len, u32 source_bundle_id_len,
//             u32 preview_len
//             followed by the five UTF-8 byte spans: custom_label, label, source_name, source_bundle_id, preview
//
// Text rows carry custom_label + label + source metadata + bounded preview. Image rows carry
// custom_label + the synthesized "Image (WxH)" label + source metadata and an empty preview.
// The caller owns the returned buffer and releases it with
// `clipboard_free_bytes` (which marks its pages reusable before freeing).

pub(crate) const PACKED_SNAPSHOT_MAGIC: &[u8; 4] = b"CSNP";
pub(crate) const PACKED_SNAPSHOT_VERSION: u32 = 2;
pub(crate) const PACKED_ROW_HEADER_LEN: usize = 56;

fn push_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn push_i32(out: &mut Vec<u8>, value: i32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn push_i64(out: &mut Vec<u8>, value: i64) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn decimal_len_u32(mut value: u32) -> usize {
    let mut len = 1;
    while value >= 10 {
        value /= 10;
        len += 1;
    }
    len
}

fn push_decimal_u32(out: &mut Vec<u8>, mut value: u32) {
    let mut buf = [0u8; 10];
    let mut pos = buf.len();
    loop {
        pos -= 1;
        buf[pos] = b'0' + (value % 10) as u8;
        value /= 10;
        if value == 0 {
            break;
        }
    }
    out.extend_from_slice(&buf[pos..]);
}

fn image_label_len(width: u32, height: u32) -> usize {
    // "Image (" + width + "x" + height + ")" - multiplication sign U+00D7, two UTF-8 bytes.
    10 + decimal_len_u32(width) + decimal_len_u32(height)
}

fn push_image_label(out: &mut Vec<u8>, width: u32, height: u32) {
    out.extend_from_slice(b"Image (");
    push_decimal_u32(out, width);
    out.extend_from_slice("\u{00D7}".as_bytes());
    push_decimal_u32(out, height);
    out.extend_from_slice(b")");
}

/// Serialize history into the packed format without cloning any per-row
/// `String`. The image label is written digit-by-digit into the output buffer,
/// so even that `format!("Image ({w}x{h})")` allocation disappears.
pub(crate) fn encode_snapshot_packed(hist: &[ClipboardEntry]) -> Vec<u8> {
    let mut total = 16usize; // magic + version + row_count + flags
    for entry in hist {
        total += PACKED_ROW_HEADER_LEN;
        match entry {
            ClipboardEntry::Text {
                label,
                custom_label,
                source_name,
                source_bundle_id,
                preview,
                ..
            } => {
                total += custom_label.len() + label.len() + source_name.len() + source_bundle_id.len() + preview.len();
            }
            ClipboardEntry::Image {
                width,
                height,
                custom_label,
                source_name,
                source_bundle_id,
                ..
            } => {
                total +=
                    custom_label.len() + image_label_len(*width, *height) + source_name.len() + source_bundle_id.len();
            }
        }
    }

    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(PACKED_SNAPSHOT_MAGIC);
    push_u32(&mut out, PACKED_SNAPSHOT_VERSION);
    push_u32(&mut out, hist.len() as u32);
    push_u32(&mut out, 0); // flags reserved

    for entry in hist {
        match entry {
            ClipboardEntry::Text {
                id,
                timestamp,
                label,
                custom_label,
                source_name,
                source_bundle_id,
                preview,
                ..
            } => {
                push_i32(&mut out, 0);
                push_i64(&mut out, *id as i64);
                push_i64(&mut out, *timestamp as i64);
                push_i64(&mut out, 0);
                push_i32(&mut out, 0);
                push_i32(&mut out, 0);
                push_u32(&mut out, custom_label.len() as u32);
                push_u32(&mut out, label.len() as u32);
                push_u32(&mut out, source_name.len() as u32);
                push_u32(&mut out, source_bundle_id.len() as u32);
                push_u32(&mut out, preview.len() as u32);
                out.extend_from_slice(custom_label.as_bytes());
                out.extend_from_slice(label.as_bytes());
                out.extend_from_slice(source_name.as_bytes());
                out.extend_from_slice(source_bundle_id.as_bytes());
                out.extend_from_slice(preview.as_bytes());
            }
            ClipboardEntry::Image {
                id,
                width,
                height,
                custom_label,
                timestamp,
                source_name,
                source_bundle_id,
                db_id,
                ..
            } => {
                let label_len = image_label_len(*width, *height);
                push_i32(&mut out, 1);
                push_i64(&mut out, *id as i64);
                push_i64(&mut out, *timestamp as i64);
                push_i64(&mut out, *db_id);
                push_i32(&mut out, *width as i32);
                push_i32(&mut out, *height as i32);
                push_u32(&mut out, custom_label.len() as u32);
                push_u32(&mut out, label_len as u32);
                push_u32(&mut out, source_name.len() as u32);
                push_u32(&mut out, source_bundle_id.len() as u32);
                push_u32(&mut out, 0);
                out.extend_from_slice(custom_label.as_bytes());
                push_image_label(&mut out, *width, *height);
                out.extend_from_slice(source_name.as_bytes());
                out.extend_from_slice(source_bundle_id.as_bytes());
            }
        }
    }

    debug_assert_eq!(out.len(), total);
    out
}

/// Acquire the whole snapshot as one packed byte buffer. The caller owns the
/// buffer and must release it with `clipboard_free_bytes`. Returns null when
/// the backend is unavailable; on success `*out_len` receives the byte length.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_packed_acquire(out_len: *mut c_int) -> *mut u8 {
    let hist = match try_backend() {
        Some(b) => b.history.lock().unwrap(),
        None => return std::ptr::null_mut(),
    };
    let perf = crate::perf::PerfSpan::start("rust", "snapshot.pack");
    let packed = encode_snapshot_packed(&hist);
    let rows = hist.len();
    if let Some(mut span) = perf {
        span.val = Some(rows as i64);
        span.data = Some(format!("bytes{}", packed.len()));
    }
    if !out_len.is_null() {
        unsafe {
            *out_len = packed.len() as c_int;
        }
    }
    super::vec_to_raw(packed)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_count(snap: *const Snapshot) -> c_int {
    if snap.is_null() {
        return 0;
    }
    let snap = unsafe { &*snap };
    snap.0.len() as c_int
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_type(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() {
        return -1;
    }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(-1, |row| row.entry_type)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_id(snap: *const Snapshot, index: c_int) -> i64 {
    if snap.is_null() {
        return 0;
    }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.id)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_timestamp(
    snap: *const Snapshot,
    index: c_int,
) -> c_longlong {
    if snap.is_null() {
        return 0;
    }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.timestamp)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_label(
    snap: *const Snapshot,
    index: c_int,
) -> *mut c_char {
    if snap.is_null() {
        return std::ptr::null_mut();
    }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => to_ffi_cstring(&row.label),
        None => std::ptr::null_mut(),
    }
}

/// Custom label (user-defined remark) for a snapshot item.
/// Caller must free with `clipboard_free_string()`.
/// Returns null when no custom label is set.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_custom_label(
    snap: *const Snapshot,
    index: c_int,
) -> *mut c_char {
    if snap.is_null() {
        return std::ptr::null_mut();
    }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => {
            if row.custom_label.is_empty() {
                std::ptr::null_mut()
            } else {
                to_ffi_cstring(&row.custom_label)
            }
        }
        None => std::ptr::null_mut(),
    }
}

/// Bounded preview text for a text item (≤ 256 Unicode scalars; long entries
/// elided to head……tail so the row shows the real ending). The list row only
/// renders ~50 visual chars, so the snapshot carries this bounded preview
/// instead of cloning the full text into the frontend. Caller must free
/// with `clipboard_free_string()`. Image items return null.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_preview(
    snap: *const Snapshot,
    index: c_int,
) -> *mut c_char {
    if snap.is_null() {
        return std::ptr::null_mut();
    }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => {
            if row.preview.is_empty() {
                std::ptr::null_mut()
            } else {
                to_ffi_cstring(&row.preview)
            }
        }
        None => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_name(
    snap: *const Snapshot,
    index: c_int,
) -> *mut c_char {
    if snap.is_null() {
        return std::ptr::null_mut();
    }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => to_ffi_cstring(&row.source_name),
        None => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_bundle_id(
    snap: *const Snapshot,
    index: c_int,
) -> *mut c_char {
    if snap.is_null() {
        return std::ptr::null_mut();
    }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => to_ffi_cstring(&row.source_bundle_id),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_db_id(snap: *const Snapshot, index: c_int) -> i64 {
    if snap.is_null() {
        return 0;
    }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.db_id)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_width(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() {
        return 0;
    }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.width)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_height(
    snap: *const Snapshot,
    index: c_int,
) -> c_int {
    if snap.is_null() {
        return 0;
    }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.height)
}

/// Safe to call with null pointer (no-op).
#[no_mangle]
pub extern "C" fn clipboard_snapshot_release(snap: *mut Snapshot) {
    if snap.is_null() {
        return;
    }
    unsafe {
        let boxed = Box::from_raw(snap);
        // Release-path symmetry with the claim in `clipboard_snapshot_acquire`:
        // the rows array was claimed before Swift read it, so its pages must be
        // marked reusable before the Vec drops.
        crate::backend::mark_pages_reusable(
            boxed.0.as_ptr().cast::<u8>(),
            boxed.0.capacity() * std::mem::size_of::<SnapshotRow>(),
        );
        drop(boxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_u32(buf: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(buf[at..at + 4].try_into().unwrap())
    }

    fn read_i32(buf: &[u8], at: usize) -> i32 {
        i32::from_le_bytes(buf[at..at + 4].try_into().unwrap())
    }

    fn read_i64(buf: &[u8], at: usize) -> i64 {
        i64::from_le_bytes(buf[at..at + 8].try_into().unwrap())
    }

    #[test]
    fn packed_snapshot_round_trips_text_and_image_rows() {
        let hist = vec![
            ClipboardEntry::Text {
                id: 7,
                preview: "head……tail\u{0}with nul".to_string(),
                label: "汉字 label".to_string(),
                custom_label: "备注 text".to_string(),
                text_hash: 1,
                timestamp: 111,
                source_name: "Xcode".to_string(),
                source_bundle_id: "com.apple.dt.Xcode".to_string(),
                db_id: 0,
            },
            ClipboardEntry::Image {
                id: 9,
                width: 3840,
                height: 2160,
                thumb_width: 300,
                thumb_height: 169,
                hash: 2,
                custom_label: String::new(),
                timestamp: 222,
                source_name: "Finder".to_string(),
                source_bundle_id: "com.apple.finder".to_string(),
                db_id: 42,
            },
        ];
        let packed = encode_snapshot_packed(&hist);

        assert_eq!(&packed[0..4], b"CSNP");
        assert_eq!(read_u32(&packed, 4), PACKED_SNAPSHOT_VERSION);
        assert_eq!(read_u32(&packed, 8), 2);

        let mut at = 16;
        assert_eq!(read_i32(&packed, at), 0);
        assert_eq!(read_i64(&packed, at + 4), 7);
        assert_eq!(read_i64(&packed, at + 12), 111);
        assert_eq!(read_i64(&packed, at + 20), 0);
        let custom_label_len = read_u32(&packed, at + 36) as usize;
        let label_len = read_u32(&packed, at + 40) as usize;
        let source_len = read_u32(&packed, at + 44) as usize;
        let bundle_len = read_u32(&packed, at + 48) as usize;
        let preview_len = read_u32(&packed, at + 52) as usize;
        let mut span = at + PACKED_ROW_HEADER_LEN;
        assert_eq!(&packed[span..span + custom_label_len], "备注 text".as_bytes());
        span += custom_label_len;
        assert_eq!(&packed[span..span + label_len], "汉字 label".as_bytes());
        span += label_len;
        assert_eq!(&packed[span..span + source_len], b"Xcode");
        span += source_len;
        assert_eq!(&packed[span..span + bundle_len], b"com.apple.dt.Xcode");
        span += bundle_len;
        assert_eq!(
            &packed[span..span + preview_len],
            "head……tail\u{0}with nul".as_bytes()
        );
        at = span + preview_len;

        assert_eq!(read_i32(&packed, at), 1);
        assert_eq!(read_i64(&packed, at + 4), 9);
        assert_eq!(read_i64(&packed, at + 12), 222);
        assert_eq!(read_i64(&packed, at + 20), 42);
        assert_eq!(read_i32(&packed, at + 28), 3840);
        assert_eq!(read_i32(&packed, at + 32), 2160);
        let custom_label_len = read_u32(&packed, at + 36) as usize;
        assert_eq!(custom_label_len, 0);
        let label_len = read_u32(&packed, at + 40) as usize;
        span = at + PACKED_ROW_HEADER_LEN;
        assert_eq!(
            &packed[span..span + label_len],
            "Image (3840×2160)".as_bytes()
        );
        span += label_len;
        assert_eq!(read_u32(&packed, at + 44) as usize, "Finder".len());
        assert_eq!(&packed[span..span + "Finder".len()], b"Finder");
    }

    #[test]
    fn packed_snapshot_empty_history_has_only_header() {
        let packed = encode_snapshot_packed(&[]);
        assert_eq!(packed.len(), 16);
        assert_eq!(&packed[0..4], b"CSNP");
        assert_eq!(read_u32(&packed, 8), 0);
    }

    #[test]
    #[ignore = "benchmark: run with cargo test --release -- --ignored --nocapture"]
    fn benchmark_packed_vs_per_row_snapshot() {
        let hist: Vec<ClipboardEntry> = (0..3000)
            .map(|i| ClipboardEntry::Text {
                id: i,
                preview: "head……tail 一段用于测量打包快照的中文预览文本".to_string(),
                label: "label text entry".to_string(),
                custom_label: String::new(),
                text_hash: i,
                timestamp: 1_000_000 + i,
                source_name: "Xcode".to_string(),
                source_bundle_id: "com.apple.dt.Xcode".to_string(),
                db_id: i as i64,
            })
            .collect();

        let iterations = 100;
        let start = std::time::Instant::now();
        for _ in 0..iterations {
            let rows: Vec<SnapshotRow> = hist.iter().map(SnapshotRow::from_entry).collect();
            std::hint::black_box(rows);
        }
        let old_avg_us = start.elapsed().as_nanos() as f64 / iterations as f64 / 1000.0;

        let start = std::time::Instant::now();
        for _ in 0..iterations {
            std::hint::black_box(encode_snapshot_packed(&hist));
        }
        let packed_avg_us = start.elapsed().as_nanos() as f64 / iterations as f64 / 1000.0;

        println!(
            "snapshot build: old per-row {old_avg_us:.1} us vs packed {packed_avg_us:.1} us, packed bytes {}",
            encode_snapshot_packed(&hist).len()
        );
    }
}

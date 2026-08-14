//! Core type definitions for clipboard history entries.

/// Source app info for attribution metadata.
#[derive(Clone, Debug, Default)]
pub(crate) struct SourceApp {
    pub(crate) name: String,
    pub(crate) bundle_id: String,
    pub(crate) pid: i32,
}

/// A clipboard history entry.
///
/// Each entry carries a stable monotonic `id` (survives reordering) and a
/// `SQLite` `db_id` for on-demand image/thumb loading from the database.
#[derive(Clone, Debug)]
pub(crate) enum ClipboardEntry {
    Text {
        /// Stable, unique entry identifier (monotonic, survives reordering).
        id: u64,
        /// Bounded single-line preview for the list row (≤256 Unicode scalars;
        /// long entries elided to `head……tail`). The full text lives only in
        /// SQLite (FTS5-indexed) and is loaded on demand by `db_id` — the
        /// in-memory entry never holds it, so memory stays flat regardless of
        /// how large pasted documents are.
        preview: String,
        /// First non-empty line of the original text, ≤60 scalars (list title).
        label: String,
        /// Content hash for in-memory dedup (DB dedup stays exact-text).
        text_hash: u64,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        /// `SQLite` row id for DB-level operations (0 = unset).
        db_id: i64,
    },
    Image {
        /// Stable, unique entry identifier (monotonic, survives reordering).
        id: u64,
        png_data: Vec<u8>,
        width: u32,
        height: u32,
        thumb_data: Vec<u8>,
        thumb_width: u32,
        thumb_height: u32,
        hash: u64,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        /// `SQLite` row id for loading full image on demand (0 = unset).
        db_id: i64,
    },
}

impl ClipboardEntry {
    pub(crate) fn entry_id(&self) -> u64 {
        match self {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        }
    }

    pub(crate) fn timestamp(&self) -> u64 {
        match self {
            ClipboardEntry::Text { timestamp, .. } | ClipboardEntry::Image { timestamp, .. } => *timestamp,
        }
    }

    pub(crate) fn content_type(&self) -> i32 {
        match self {
            ClipboardEntry::Text { .. } => 0,
            ClipboardEntry::Image { .. } => 1,
        }
    }

    pub(crate) fn source_name(&self) -> &str {
        match self {
            ClipboardEntry::Text { source_name, .. } | ClipboardEntry::Image { source_name, .. } => source_name,
        }
    }

    pub(crate) fn source_bundle_id(&self) -> &str {
        match self {
            ClipboardEntry::Text { source_bundle_id, .. } | ClipboardEntry::Image { source_bundle_id, .. } => source_bundle_id,
        }
    }

    pub(crate) fn label(&self) -> String {
        match self {
            ClipboardEntry::Text { label, .. } => label.clone(),
            ClipboardEntry::Image { width, height, .. } => {
                format!("Image ({width}×{height})")
            }
        }
    }

    /// Bounded preview for the list row (≤ 256 Unicode scalars), precomputed at
    /// capture/load time from the full text. The snapshot carries this instead
    /// of the full multi-KB text.
    pub(crate) fn preview(&self) -> String {
        match self {
            ClipboardEntry::Text { preview, .. } => preview.clone(),
            ClipboardEntry::Image { .. } => String::new(),
        }
    }
}

/// FNV-1a 64-bit, the shared stable content hash for BOTH text and image
/// identity. A fixed published algorithm — deliberately NOT `DefaultHasher`:
/// std documents it as unstable across Rust releases, and the hash values are
/// now persisted in SQLite (the `hash` column). A silent std change would make
/// re-captured content stop matching pre-existing rows' hashes (ghost entries
/// for text, duplicate entries for images). A stable algorithm can never
/// drift under us.
pub(crate) fn fnv1a(iter: impl IntoIterator<Item = u8>) -> u64 {
    const FNV_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = FNV_OFFSET_BASIS;
    for b in iter {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

/// Content hash for in-memory text dedup. DB-side dedup stays exact-text
/// (`delete_matching_entry`), so a 64-bit hash only ever gates the in-memory
/// duplicate removal — collision is ~2⁻⁶⁴ and self-heals on next DB pass.
pub(crate) fn text_hash(text: &str) -> u64 {
    fnv1a(text.as_bytes().iter().copied())
}

/// True if `line` is all whitespace, short-circuiting at the first non-
/// whitespace char — O(1) for any non-blank line, however long.
fn is_blank_line(line: &str) -> bool {
    line.chars().all(|c| c.is_whitespace())
}

/// First non-empty line of `text`, ≤60 Unicode scalars (else truncated with
/// `…`). O(60) for a non-blank line regardless of length: the blank check
/// short-circuits at the first non-whitespace char and the truncation only
/// reads 61 scalars — a multi-MB single-line paste is not scanned in full.
pub(crate) fn label_from_text(text: &str) -> String {
    let first = text.lines().find(|l| !is_blank_line(l)).unwrap_or(text);
    let char_count: usize = first.chars().take(61).count();
    if char_count > 60 {
        let truncated: String = first.chars().take(59).collect();
        format!("{truncated}…")
    } else {
        first.to_string()
    }
}

impl ClipboardEntry {
    /// Build a Text entry from the full captured text, deriving the bounded
    /// preview, row label, and dedup hash. The full text is written through to
    /// SQLite by the caller (which still holds it) but is not retained here.
    pub(crate) fn text_entry(
        id: u64,
        full_text: &str,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        db_id: i64,
    ) -> ClipboardEntry {
        ClipboardEntry::Text {
            id,
            preview: bounded_preview(full_text),
            label: label_from_text(full_text),
            text_hash: text_hash(full_text),
            timestamp,
            source_name,
            source_bundle_id,
            db_id,
        }
    }
}

/// Preview budget in Unicode scalars carried by the snapshot for one row.
/// Small enough that a refresh of a large history stays light.
const PREVIEW_SCALARS: usize = 256;
/// Head window of an elided preview; the tail gets the budget that remains
/// after the elision marker.
const PREVIEW_HEAD: usize = 180;
const PREVIEW_ELISION: &str = "……";

/// Single-line bounded preview for a text entry: the whole text when it fits
/// the budget, else `head……tail`. O(budget) regardless of text length — head is
/// taken from the front, tail from the back, and the "longer than budget" probe
/// only reads one scalar past the limit.
pub(crate) fn bounded_preview(text: &str) -> String {
    let over_budget = text.chars().take(PREVIEW_SCALARS + 1).count() > PREVIEW_SCALARS;
    if !over_budget {
        return text.to_string();
    }
    let tail_budget = PREVIEW_SCALARS - PREVIEW_HEAD - PREVIEW_ELISION.chars().count();
    let head: String = text.chars().take(PREVIEW_HEAD).collect();
    let tail: String = text
        .chars()
        .rev()
        .take(tail_budget)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    format!("{head}{PREVIEW_ELISION}{tail}")
}

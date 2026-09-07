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
/// `id` is stable across reordering; `db_id` points to SQLite for on-demand
/// image/thumb loading.
#[derive(Clone, Debug)]
pub(crate) enum ClipboardEntry {
    Text {
        /// Stable, unique entry identifier (monotonic, survives reordering).
        id: u64,
        /// Bounded preview; full text is loaded from SQLite by `db_id`.
        preview: String,
        /// First non-empty line of the original text (≤60 scalars).
        label: String,
        /// User-defined remark/memo. Empty when no remark is set.
        custom_label: String,
        /// Content hash for in-memory dedup.
        text_hash: u64,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        /// SQLite row id (0 = unset).
        db_id: i64,
    },
    Image {
        /// Stable, unique entry identifier (monotonic, survives reordering).
        id: u64,
        width: u32,
        height: u32,
        thumb_width: u32,
        thumb_height: u32,
        hash: u64,
        /// User-defined remark/memo. Empty when no remark is set.
        custom_label: String,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        /// SQLite row id (0 = unset).
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

    pub(crate) fn custom_label(&self) -> &str {
        match self {
            ClipboardEntry::Text { custom_label, .. }
            | ClipboardEntry::Image { custom_label, .. } => custom_label,
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

    /// Bounded preview for the list row.
    pub(crate) fn preview(&self) -> String {
        match self {
            ClipboardEntry::Text { preview, .. } => preview.clone(),
            ClipboardEntry::Image { .. } => String::new(),
        }
    }
}

/// Stable FNV-1a hash for persisted content identity (never `DefaultHasher`).
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

/// Content hash for in-memory text dedup.
pub(crate) fn text_hash(text: &str) -> u64 {
    fnv1a(text.as_bytes().iter().copied())
}

fn is_blank_line(line: &str) -> bool {
    line.chars().all(|c| c.is_whitespace())
}

/// First non-empty line of `text`, truncated to 60 Unicode scalars.
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
    /// Build a Text entry with bounded preview, label, and dedup hash.
    /// The full text is not retained in memory.
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
            custom_label: String::new(),
            text_hash: text_hash(full_text),
            timestamp,
            source_name,
            source_bundle_id,
            db_id,
        }
    }
}

/// Preview budget in Unicode scalars.
const PREVIEW_SCALARS: usize = 256;
/// Head window of an elided preview.
const PREVIEW_HEAD: usize = 180;
const PREVIEW_ELISION: &str = "……";

/// Single-line preview: whole text when it fits, else `head……tail`.
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

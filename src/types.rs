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
        text: String,
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
            ClipboardEntry::Text { text, .. } => {
                let first = text
                    .lines()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or(text);
                let char_count: usize = first.chars().count();
                if char_count > 60 {
                    let truncated: String = first.chars().take(59).collect();
                    format!("{truncated}…")
                } else {
                    first.to_string()
                }
            }
            ClipboardEntry::Image { width, height, .. } => {
                format!("Image ({width}×{height})")
            }
        }
    }

    /// Accessor for Text variant content. Panics for Image entries.
    pub(crate) fn text(&self) -> &str {
        match self {
            ClipboardEntry::Text { text, .. } => text,
            _ => panic!("text() called on a non-Text ClipboardEntry"),
        }
    }

    /// Bounded preview for the list row (≤ 256 Unicode scalars). Short text is
    /// carried whole; longer text is elided to `head……tail` so the row can show
    /// the real ending instead of a middle chunk of a truncated prefix. The
    /// snapshot still never carries full multi-KB text into the frontend.
    pub(crate) fn preview(&self) -> String {
        match self {
            ClipboardEntry::Text { text, .. } => bounded_preview(text),
            ClipboardEntry::Image { .. } => String::new(),
        }
    }

    /// Case-insensitive substring match over the searchable fields: source
    /// name, label, and full text. Mirrors the popup's previous Swift-side
    /// `localizedCaseInsensitiveContains` semantics.
    pub(crate) fn matches_search(&self, query: &str) -> bool {
        let q = query.to_lowercase();
        if self.source_name().to_lowercase().contains(&q) {
            return true;
        }
        if self.label().to_lowercase().contains(&q) {
            return true;
        }
        if let ClipboardEntry::Text { text, .. } = self {
            if text.to_lowercase().contains(&q) {
                return true;
            }
        }
        false
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
fn bounded_preview(text: &str) -> String {
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

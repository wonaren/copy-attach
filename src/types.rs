//! Core type definitions for clipboard history entries.

/// Source app info for attribution metadata.
#[derive(Clone, Debug, Default)]
pub(crate) struct SourceApp {
    pub(crate) name: String,
    pub(crate) bundle_id: String,
}

/// A clipboard history entry.
///
/// Each entry carries a stable monotonic `id` (survives reordering) and a
/// SQLite `db_id` for on-demand image/thumb loading from the database.
#[derive(Clone, Debug)]
pub(crate) enum ClipboardEntry {
    Text {
        /// Stable, unique entry identifier (monotonic, survives reordering).
        id: u64,
        text: String,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        /// SQLite row id for DB-level operations (0 = unset).
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
        /// SQLite row id for loading full image on demand (0 = unset).
        db_id: i64,
    },
}

impl ClipboardEntry {
    pub(crate) fn timestamp(&self) -> u64 {
        match self {
            ClipboardEntry::Text { timestamp, .. } => *timestamp,
            ClipboardEntry::Image { timestamp, .. } => *timestamp,
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
            ClipboardEntry::Text { source_name, .. } => source_name,
            ClipboardEntry::Image { source_name, .. } => source_name,
        }
    }

    pub(crate) fn source_bundle_id(&self) -> &str {
        match self {
            ClipboardEntry::Text { source_bundle_id, .. } => source_bundle_id,
            ClipboardEntry::Image { source_bundle_id, .. } => source_bundle_id,
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
                    format!("{}…", truncated)
                } else {
                    first.to_string()
                }
            }
            ClipboardEntry::Image { width, height, .. } => {
                format!("📷 图片 ({}×{})", width, height)
            }
        }
    }
}

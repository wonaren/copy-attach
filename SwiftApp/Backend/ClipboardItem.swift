import Foundation

enum ClipboardItem: Identifiable {
    case text(entryId: Int, timestamp: UInt64, customLabel: String, label: String, sourceName: String, sourceBundleId: String, preview: String, displayPreview: String)
    case image(entryId: Int, dbId: Int, width: Int, height: Int, timestamp: UInt64, customLabel: String, label: String, sourceName: String, sourceBundleId: String)

    var id: Int {
        switch self {
        case .text(let entryId, _, _, _, _, _, _, _): return entryId
        case .image(let entryId, _, _, _, _, _, _, _, _): return entryId
        }
    }

    var customLabel: String {
        switch self {
        case .text(_, _, let customLabel, _, _, _, _, _): return customLabel
        case .image(_, _, _, _, _, let customLabel, _, _, _): return customLabel
        }
    }

    var hasCustomLabel: Bool {
        !customLabel.isEmpty
    }

    var label: String {
        switch self {
        case .text(_, _, _, let label, _, _, _, _): return label
        case .image(_, _, _, _, _, _, let label, _, _): return label
        }
    }

    var timestamp: UInt64 {
        switch self {
        case .text(_, let ts, _, _, _, _, _, _): return ts
        case .image(_, _, _, _, let ts, _, _, _, _): return ts
        }
    }

    var sourceName: String {
        switch self {
        case .text(_, _, _, _, let sn, _, _, _): return sn
        case .image(_, _, _, _, _, _, _, let sn, _): return sn
        }
    }

    var sourceBundleId: String {
        switch self {
        case .text(_, _, _, _, _, let sbid, _, _): return sbid
        case .image(_, _, _, _, _, _, _, _, let sbid): return sbid
        }
    }

    /// Bounded single-line preview for the list row (≤ 256 scalars; long entries
    /// arrive elided to head……tail). The full text is fetched on demand via
    /// `clipboard_get_text_by_id` for preview/drag.
    var preview: String {
        switch self {
        case .text(_, _, _, _, _, _, let preview, _): return preview
        case .image: return ""
        }
    }

    /// Pre-computed single-line preview with newlines collapsed and width-bounded.
    /// Calculated once during snapshot decode to avoid per-render string churn in ItemRowView.
    var displayPreview: String {
        switch self {
        case .text(_, _, _, _, _, _, _, let display): return display
        case .image: return ""
        }
    }

    /// Pure formatting helper to turn raw preview text into bounded single-line display text.
    static func formatDisplayPreview(_ preview: String) -> String {
        guard !preview.isEmpty else { return "" }
        // Single-pass newline collapse without intermediate array allocations.
        // Breaks early at 60 characters since visual width is capped at 50.
        var collapsed = ""
        collapsed.reserveCapacity(min(preview.utf8.count, 64))
        var wasWhitespaceOrNewline = false
        for ch in preview {
            if ch.isNewline {
                if !wasWhitespaceOrNewline && !collapsed.isEmpty {
                    collapsed.append("⏎")
                    wasWhitespaceOrNewline = true
                }
            } else if ch.isWhitespace {
                if !wasWhitespaceOrNewline && !collapsed.isEmpty {
                    collapsed.append(" ")
                    wasWhitespaceOrNewline = true
                }
            } else {
                collapsed.append(ch)
                wasWhitespaceOrNewline = false
            }
            if collapsed.count >= 60 { break }
        }
        if visualWidth(collapsed) > 50 {
            let prefix = String(collapsed.prefix(whileVisualWidth: 25))
            let suffix = String(collapsed.suffix(whileVisualWidth: 25))
            return "\(prefix)……\(suffix)"
        }
        return collapsed
    }

    /// Load the entry's full text on demand. The snapshot only carries a
    /// bounded preview, so paste/drag/copy/preview all fetch the real content
    /// through this single path. nil when the load fails.
    var fullText: String? {
        guard case .text(let entryId, _, _, _, _, _, _, _) = self else { return nil }
        return ClipboardBackend.getTextByEntryId(entryId)
    }

    /// Load the entry's full PNG data on demand. nil while the image is still
    /// encoding (no persisted db_id yet) or when the load fails.
    var imageData: Data? {
        guard case .image(_, let dbId, _, _, _, _, _, _, _) = self, dbId != 0 else { return nil }
        return ClipboardBackend.getImageFullByDbId(dbId)
    }

    /// Return a copy of this item with an updated custom label.
    func withUpdatedCustomLabel(_ newCustomLabel: String) -> ClipboardItem {
        switch self {
        case .text(let entryId, let timestamp, _, let label, let sourceName, let sourceBundleId, let preview, let displayPreview):
            return .text(
                entryId: entryId, timestamp: timestamp,
                customLabel: newCustomLabel, label: label,
                sourceName: sourceName, sourceBundleId: sourceBundleId,
                preview: preview, displayPreview: displayPreview
            )
        case .image(let entryId, let dbId, let width, let height, let timestamp, _, let label, let sourceName, let sourceBundleId):
            return .image(
                entryId: entryId, dbId: dbId, width: width, height: height,
                timestamp: timestamp, customLabel: newCustomLabel,
                label: label, sourceName: sourceName, sourceBundleId: sourceBundleId
            )
        }
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

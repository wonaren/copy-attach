import Foundation

enum ClipboardItem: Identifiable {
    case text(entryId: Int, text: String, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String, preview: String)
    case image(entryId: Int, dbId: Int, width: Int, height: Int, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)

    var id: Int {
        switch self {
        case .text(let entryId, _, _, _, _, _, _): return entryId
        case .image(let entryId, _, _, _, _, _, _, _): return entryId
        }
    }

    var label: String {
        switch self {
        case .text(_, _, _, let label, _, _, _): return label
        case .image(_, _, _, _, _, let label, _, _): return label
        }
    }

    var timestamp: UInt64 {
        switch self {
        case .text(_, _, let ts, _, _, _, _): return ts
        case .image(_, _, _, _, let ts, _, _, _): return ts
        }
    }

    var sourceName: String {
        switch self {
        case .text(_, _, _, _, let sn, _, _): return sn
        case .image(_, _, _, _, _, _, let sn, _): return sn
        }
    }

    var sourceBundleId: String {
        switch self {
        case .text(_, _, _, _, _, let sbid, _): return sbid
        case .image(_, _, _, _, _, _, _, let sbid): return sbid
        }
    }

    /// Bounded preview (first ~200 chars) for the list row. The full text is
    /// fetched on demand via `clipboard_get_text_by_id` for preview/drag.
    var preview: String {
        switch self {
        case .text(_, _, _, _, _, _, let preview): return preview
        case .image: return ""
        }
    }

    /// Load the entry's full text on demand. The snapshot only carries a
    /// bounded preview, so paste/drag/copy/preview all fetch the real content
    /// through this single path. nil when the load fails.
    var fullText: String? {
        guard case .text(let entryId, _, _, _, _, _, _) = self else { return nil }
        return ClipboardBackend.getTextByEntryId(entryId)
    }

    /// Load the entry's full PNG data on demand. nil while the image is still
    /// encoding (no persisted db_id yet) or when the load fails.
    var imageData: Data? {
        guard case .image(_, let dbId, _, _, _, _, _, _) = self, dbId != 0 else { return nil }
        return ClipboardBackend.getImageFullByDbId(dbId)
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

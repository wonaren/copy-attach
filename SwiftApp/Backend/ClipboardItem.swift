import Foundation

enum ClipboardItem: Identifiable, Equatable {
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

    var slotDisplayName: String {
        if hasCustomLabel { return customLabel }
        if isImage { return label }
        return displayPreview
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

    var preview: String {
        switch self {
        case .text(_, _, _, _, _, _, let preview, _): return preview
        case .image: return ""
        }
    }

    var displayPreview: String {
        switch self {
        case .text(_, _, _, _, _, _, _, let display): return display
        case .image: return ""
        }
    }

    static func formatDisplayPreview(_ preview: String) -> String {
        guard !preview.isEmpty else { return "" }
        var collapsed = ""
        collapsed.reserveCapacity(min(preview.utf8.count, 256))
        var pendingSeparator: Character?
        for ch in preview {
            if ch.isNewline {
                if !collapsed.isEmpty { pendingSeparator = "⏎" }
            } else if ch.isWhitespace {
                if !collapsed.isEmpty, pendingSeparator == nil { pendingSeparator = " " }
            } else {
                if let separator = pendingSeparator {
                    collapsed.append(separator)
                    pendingSeparator = nil
                }
                collapsed.append(ch)
            }
        }
        if visualWidth(collapsed) > 50 {
            let prefix = String(collapsed.prefix(whileVisualWidth: 25))
            let suffix = String(collapsed.suffix(whileVisualWidth: 25))
            return "\(prefix)……\(suffix)"
        }
        return collapsed
    }

    var fullText: String? {
        guard case .text(let entryId, _, _, _, _, _, _, _) = self else { return nil }
        return ClipboardBackend.getTextByEntryId(entryId)
    }

    var imageData: Data? {
        guard case .image(_, let dbId, _, _, _, _, _, _, _) = self, dbId != 0 else { return nil }
        return ClipboardBackend.getImageFullByDbId(dbId)
    }

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

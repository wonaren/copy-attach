import Foundation

enum ClipboardItem: Identifiable {
    case text(entryId: Int, text: String, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String, fullText: String)
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

    var fullText: String {
        switch self {
        case .text(_, _, _, _, _, _, let ft): return ft
        case .image: return ""
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

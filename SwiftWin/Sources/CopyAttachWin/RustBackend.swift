// RustBackend.swift — Swift wrapper over the Rust copy_attach C ABI.
//
// All calls stay on the main thread (the Rust monitor runs on its own thread
// behind the history lock). Strings and buffers returned by Rust are freed
// with the matching clipboard_free_* functions — no copies are retained.

import CCopyAttach
import Foundation

/// One flattened history row for the UI list.
struct HistoryRow {
    let entryId: UInt64
    let isImage: Bool
    let label: String
    let preview: String
    let sourceName: String
    let timestamp: UInt64
}

enum RustBackend {
    /// Entitlement state passed to `clipboard_set_runtime_entitlement`.
    /// The Windows MVP has no licensing integration yet; it runs with the
    /// full entitlement so the backend accepts `clipboard_init`. Real
    /// license verification is a later iteration (see docs/windows.md).
    private static let mvpEntitlement: Int32 = 2

    static func start(debugLogging: Bool) -> Bool {
        _ = clipboard_set_debug_logging(debugLogging ? 1 : 0)
        guard clipboard_set_runtime_entitlement(mvpEntitlement) == 1 else {
            fputs("CopyAttach: failed to set runtime entitlement\n", stderr)
            return false
        }
        guard clipboard_init() == 1 else {
            fputs("CopyAttach: clipboard_init failed\n", stderr)
            return false
        }
        return true
    }

    static func shutdown() {
        clipboard_cleanup()
    }

    /// Acquire a consistent snapshot and flatten it into `HistoryRow`s.
    static func snapshotRows() -> [HistoryRow] {
        guard let snap = clipboard_snapshot_acquire() else { return [] }
        defer { clipboard_snapshot_release(snap) }
        let count = Int(clipboard_snapshot_count(snap))
        var rows: [HistoryRow] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            let type = clipboard_snapshot_item_type(snap, Int32(i))
            let id = UInt64(bitPattern: clipboard_snapshot_item_id(snap, Int32(i)))
            let timestamp = UInt64(bitPattern: clipboard_snapshot_item_timestamp(snap, Int32(i)))
            let label = takeString(clipboard_snapshot_item_label(snap, Int32(i))) ?? ""
            let preview = takeString(clipboard_snapshot_item_preview(snap, Int32(i))) ?? ""
            let source = takeString(clipboard_snapshot_item_source_name(snap, Int32(i))) ?? ""
            rows.append(HistoryRow(
                entryId: id,
                isImage: type == 1,
                label: label,
                preview: preview,
                sourceName: source,
                timestamp: timestamp
            ))
        }
        return rows
    }

    /// Full-text search: returns matching entry_ids (empty on no match).
    static func searchIds(_ query: String) -> Set<UInt64> {
        var count: Int32 = 0
        let ids = clipboard_search_ids(query, &count)
        guard let ids = ids, count > 0 else { return [] }
        defer { clipboard_free_u64_array(ids, count) }
        let buffer = UnsafeBufferPointer(start: ids, count: Int(count))
        return Set(buffer)
    }

    @discardableResult
    static func paste(entryId: UInt64) -> Bool {
        clipboard_select_and_paste_by_id(entryId) == 1
    }

    @discardableResult
    static func delete(entryId: UInt64) -> Bool {
        clipboard_delete_by_id(entryId) == 1
    }

    @discardableResult
    static func undoDelete() -> Bool {
        clipboard_undo_delete() == 1
    }

    static func canUndo() -> Bool {
        clipboard_can_undo() == 1
    }

    static func historyRevision() -> UInt64 {
        clipboard_get_history_revision()
    }

    static func imageEncodingCounter() -> UInt64 {
        clipboard_get_image_encoding_counter()
    }

    static func setCleanupThreshold(_ threshold: Int32) {
        clipboard_set_cleanup_threshold(threshold)
    }

    static func clearHistory() {
        _ = clipboard_clear_history()
        _ = clipboard_shrink_db_memory()
    }

    // MARK: - Helpers

    /// Adopt a Rust-allocated C string and free it immediately after copying.
    private static func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = ptr else { return nil }
        defer { clipboard_free_string(ptr) }
        return String(cString: ptr)
    }
}

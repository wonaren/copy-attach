import Foundation

/// Decoder for the Rust `clipboard_snapshot_packed_acquire` wire format.
///
/// The old snapshot path performed one CString allocation per string field
/// (label, source name, bundle id, preview) for every row on every reload.
/// For a 3000-row history that is roughly 9k-12k transient small-zone
/// allocations per refresh. This decoder reads the same data from one packed
/// buffer, builds Swift `String` copies while the buffer is alive, and then
/// lets the caller release the buffer through `clipboard_free_bytes`.
enum PackedSnapshot {
    fileprivate static let magic: [UInt8] = Array("CSNP".utf8)
    fileprivate static let version: UInt32 = 3
    fileprivate static let headerLength = 16
    fileprivate static let rowHeaderLength = 60
    /// Row flag bit 0: the entry is in the DB's `clipboard_favorites` table.
    fileprivate static let rowFlagFavorite: UInt32 = 1

    /// Decode one packed snapshot into its rows plus the durable favorite set.
    ///
    /// Favorites travel per row (a flag) so the list and the set cannot drift:
    /// both are decoded from the same snapshot. This replaces the old
    /// UserDefaults id set, which had to be reconciled against the list after
    /// every publish.
    static func decodeItems(from ptr: UnsafeRawPointer, length: Int) -> ([ClipboardItem], Set<Int>)? {
        guard length >= headerLength else { return nil }
        for (index, byte) in magic.enumerated() {
            guard ptr.load(fromByteOffset: index, as: UInt8.self) == byte else { return nil }
        }
        guard readUInt32(ptr, at: 4) == version else { return nil }
        let count = Int(readUInt32(ptr, at: 8))
        guard count >= 0, length >= headerLength + count &* rowHeaderLength else { return nil }

        var items: [ClipboardItem] = []
        items.reserveCapacity(count)
        var favoriteIds: Set<Int> = []
        var offset = headerLength

        // Sub-phase accumulation. Measuring per row would flood the log; the
        // totals answer "where did the 16 ms go" without perturbing the loop.
        let profiling = Perf.isEnabled
        var stringNs: UInt64 = 0
        var formatNs: UInt64 = 0

        for _ in 0..<count {
            guard offset <= length - rowHeaderLength else { return nil }
            let entryType = readInt32(ptr, at: offset)
            let id = Int(readInt64(ptr, at: offset + 4))
            let timestampRaw = readInt64(ptr, at: offset + 12)
            let timestamp = UInt64(bitPattern: timestampRaw)
            let dbId = Int(readInt64(ptr, at: offset + 20))
            let width = Int(readInt32(ptr, at: offset + 28))
            let height = Int(readInt32(ptr, at: offset + 32))
            let customLabelLength = Int(readUInt32(ptr, at: offset + 36))
            let labelLength = Int(readUInt32(ptr, at: offset + 40))
            let sourceNameLength = Int(readUInt32(ptr, at: offset + 44))
            let sourceBundleIdLength = Int(readUInt32(ptr, at: offset + 48))
            let previewLength = Int(readUInt32(ptr, at: offset + 52))
            let flags = readUInt32(ptr, at: offset + 56)
            if flags & rowFlagFavorite != 0 {
                favoriteIds.insert(id)
            }

            let stringBytes = customLabelLength + labelLength + sourceNameLength + sourceBundleIdLength + previewLength
            guard stringBytes >= 0, offset <= length - rowHeaderLength - stringBytes else { return nil }

            var span = offset + rowHeaderLength
            let strT0 = profiling ? Perf.nowNs() : 0
            let customLabel = readString(ptr, at: span, byteCount: customLabelLength)
            span += customLabelLength
            let label = readString(ptr, at: span, byteCount: labelLength)
            span += labelLength
            let sourceName = readString(ptr, at: span, byteCount: sourceNameLength)
            span += sourceNameLength
            let sourceBundleId = readString(ptr, at: span, byteCount: sourceBundleIdLength)
            span += sourceBundleIdLength
            let preview = readString(ptr, at: span, byteCount: previewLength)
            span += previewLength
            if profiling { stringNs &+= Perf.nowNs() &- strT0 }

            switch entryType {
            case 0:
                let fmtT0 = profiling ? Perf.nowNs() : 0
                let display = ClipboardItem.formatDisplayPreview(preview)
                if profiling { formatNs &+= Perf.nowNs() &- fmtT0 }
                items.append(.text(
                    entryId: id,
                    timestamp: timestamp,
                    customLabel: customLabel,
                    label: label,
                    sourceName: sourceName,
                    sourceBundleId: sourceBundleId,
                    preview: preview,
                    displayPreview: display
                ))
            case 1:
                items.append(.image(
                    entryId: id,
                    dbId: dbId,
                    width: width,
                    height: height,
                    timestamp: timestamp,
                    customLabel: customLabel,
                    label: label,
                    sourceName: sourceName,
                    sourceBundleId: sourceBundleId
                ))
            default:
                return nil
            }
            offset = span
        }
        if profiling, count > 0 {
            Perf.emitSpan("swift", "snapshot.decode.strings", durNs: stringNs, val: Int64(count))
            Perf.emitSpan("swift", "snapshot.decode.format_preview", durNs: formatNs, val: Int64(count))
        }
        return (items, favoriteIds)
    }

    fileprivate static func readUInt32(_ ptr: UnsafeRawPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    fileprivate static func readInt32(_ ptr: UnsafeRawPointer, at offset: Int) -> Int32 {
        Int32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: Int32.self))
    }

    fileprivate static func readInt64(_ ptr: UnsafeRawPointer, at offset: Int) -> Int64 {
        Int64(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: Int64.self))
    }

    fileprivate static func readString(_ ptr: UnsafeRawPointer, at offset: Int, byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        let base = ptr.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: base, count: byteCount), as: UTF8.self)
    }
}

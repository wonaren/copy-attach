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
    fileprivate static let version: UInt32 = 1
    fileprivate static let headerLength = 16
    fileprivate static let rowHeaderLength = 52

    static func decodeItems(from ptr: UnsafeRawPointer, length: Int) -> [ClipboardItem]? {
        guard length >= headerLength else { return nil }
        for (index, byte) in magic.enumerated() {
            guard ptr.load(fromByteOffset: index, as: UInt8.self) == byte else { return nil }
        }
        guard readUInt32(ptr, at: 4) == version else { return nil }
        let count = Int(readUInt32(ptr, at: 8))
        guard count >= 0, length >= headerLength + count &* rowHeaderLength else { return nil }

        var items: [ClipboardItem] = []
        items.reserveCapacity(count)
        var offset = headerLength

        for _ in 0..<count {
            guard offset <= length - rowHeaderLength else { return nil }
            let entryType = readInt32(ptr, at: offset)
            let id = Int(readInt64(ptr, at: offset + 4))
            let timestampRaw = readInt64(ptr, at: offset + 12)
            let timestamp = UInt64(bitPattern: timestampRaw)
            let dbId = Int(readInt64(ptr, at: offset + 20))
            let width = Int(readInt32(ptr, at: offset + 28))
            let height = Int(readInt32(ptr, at: offset + 32))
            let labelLength = Int(readUInt32(ptr, at: offset + 36))
            let sourceNameLength = Int(readUInt32(ptr, at: offset + 40))
            let sourceBundleIdLength = Int(readUInt32(ptr, at: offset + 44))
            let previewLength = Int(readUInt32(ptr, at: offset + 48))

            let stringBytes = labelLength + sourceNameLength + sourceBundleIdLength + previewLength
            guard stringBytes >= 0, offset <= length - rowHeaderLength - stringBytes else { return nil }

            var span = offset + rowHeaderLength
            let label = readString(ptr, at: span, byteCount: labelLength)
            span += labelLength
            let sourceName = readString(ptr, at: span, byteCount: sourceNameLength)
            span += sourceNameLength
            let sourceBundleId = readString(ptr, at: span, byteCount: sourceBundleIdLength)
            span += sourceBundleIdLength
            let preview = readString(ptr, at: span, byteCount: previewLength)
            span += previewLength

            switch entryType {
            case 0:
                let display = ClipboardItem.formatDisplayPreview(preview)
                items.append(.text(
                    entryId: id,
                    timestamp: timestamp,
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
                    label: label,
                    sourceName: sourceName,
                    sourceBundleId: sourceBundleId
                ))
            default:
                return nil
            }
            offset = span
        }
        return items
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

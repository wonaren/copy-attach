import AppKit
import Foundation
import UniformTypeIdentifiers

enum ClipboardDragProvider {
    struct Payload {
        let data: [String: Data]
        let suggestedName: String?
    }

    static func payload(for item: ClipboardItem, richText: Bool = false) -> Payload? {
        switch item {
        case .text:
            guard let full = item.fullText else {
                debugLog("Drag: failed to load full text for entry \(item.id)")
                return nil
            }
            let plain = Data(full.utf8)
            let rich = richText ? Self.richRepresentations(for: full) : [:]
            let types = richText ? Self.richTextRepresentationTypes : Self.plainTextRepresentationTypes
            var data: [String: Data] = [:]
            for type in types {
                data[type.identifier] = rich[type.identifier] ?? plain
            }
            return Payload(data: data, suggestedName: nil)
        case .image:
            guard let data = item.imageData else {
                debugLog("Drag: failed to load PNG data for image entry \(item.id); offering empty drag")
                return nil
            }
            do {
                let url = try temporaryImageURL(entryId: item.id)
                try data.write(to: url, options: .atomic)
                return Payload(data: [UTType.fileURL.identifier: Data(url.absoluteString.utf8)],
                               suggestedName: url.lastPathComponent)
            } catch {
                errorLog("Drag: failed to materialize image entry \(item.id): \(error)")
                return nil
            }
        }
    }

    static func placeholderPayload() -> Payload {
        var data: [String: Data] = [:]
        for type in plainTextRepresentationTypes {
            data[type.identifier] = Data()
        }
        return Payload(data: data, suggestedName: nil)
    }

    private static let plainTextRepresentationTypes: [UTType] = [
        .utf8PlainText,
        .plainText,
        .text,
    ]

    private static let richTextRepresentationTypes: [UTType] = [
        .utf8PlainText,
        .plainText,
        .text,
        .html,
        .rtf,
    ]

    private static func richRepresentations(for full: String) -> [String: Data] {
        let attributed = NSAttributedString(
            string: full,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        var result: [String: Data] = [:]

        let range = NSRange(location: 0, length: attributed.length)
        if let rtf = try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            result[UTType.rtf.identifier] = rtf
        }
        if let html = try? attributed.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        ) {
            result[UTType.html.identifier] = html
        }
        return result
    }

    private static func temporaryImageURL(entryId: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyAttach", isDirectory: true)
            .appendingPathComponent("Drag", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("clipboard-\(entryId)-\(UUID().uuidString).png")
        clipboard_purge_stale_drag_images()
        return url
    }
}

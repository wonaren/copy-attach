import AppKit
import Foundation
import UniformTypeIdentifiers

enum ClipboardDragProvider {
    static func provider(for item: ClipboardItem, richText: Bool = false) -> NSItemProvider {
        let perfDrag = PerfSpan.start("swift", "drag.materialize")
        if let span = perfDrag {
            span.data = item.isImage ? "image" : "text"
        }
        let provider = NSItemProvider()
        defer { perfDrag?.end() }
        switch item {
        case .text:
            guard let full = item.fullText else {
                debugLog("Drag: failed to load full text for entry \(item.id)")
                return NSItemProvider(object: "" as NSString)
            }
            let plain = Data(full.utf8)
            let rich = richText ? Self.richRepresentations(for: full) : [:]
            let types = richText ? Self.richTextRepresentationTypes : Self.plainTextRepresentationTypes
            for type in types {
                let data = rich[type.identifier] ?? plain
                provider.registerDataRepresentation(
                    forTypeIdentifier: type.identifier,
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }

        case .image:
            guard let data = item.imageData else {
                debugLog("Drag: failed to load PNG data for image entry \(item.id); offering empty drag")
                return NSItemProvider()
            }

            do {
                let url = try temporaryImageURL(entryId: item.id)
                try data.write(to: url, options: .atomic)

                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    visibility: .all
                ) { completion in
                    completion(url.absoluteString.data(using: .utf8), nil)
                    return nil
                }
                provider.suggestedName = url.lastPathComponent
            } catch {
                errorLog("Drag: failed to materialize image entry \(item.id): \(error)")
                return NSItemProvider()
            }
        }
        return provider
    }

    private static let plainTextRepresentationTypes: [UTType] = [
        .utf8PlainText,
        .plainText,
        .text,
    ]

    static func placeholderProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        for type in plainTextRepresentationTypes {
            provider.registerDataRepresentation(
                forTypeIdentifier: type.identifier,
                visibility: .all
            ) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        return provider
    }

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

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Builds native drag representations for popup history rows.
///
/// Images are eagerly materialized as PNG files when the drag begins and are
/// offered as `public.file-url`. This is the representation expected by Finder,
/// Dropover-style shelves, and applications that consume a dropped image as a
/// file rather than as an in-memory pasteboard image.
///
/// Text is offered under every representation a drop target may key on:
/// UTF-8 plain text, generic plain text, abstract text, HTML and RTF. A bare
/// `NSItemProvider(object: NSString)` advertises only
/// `public.utf8-plain-text`, so receivers filtering on any of the other UTIs
/// decline the drop.
enum ClipboardDragProvider {
    /// The `NSItemProvider` SwiftUI's `.onDrag` hands to the drag session for
    /// `item`.
    ///
    /// Every representation is registered with eagerly built `Data`, so a
    /// receiver reading the pasteboard during `draggingEntered:` gets the
    /// payload without waiting on SwiftUI's asynchronous provider round trip.
    static func provider(for item: ClipboardItem) -> NSItemProvider {
        let provider = NSItemProvider()
        switch item {
        case .text:
            // Full text is no longer held in the snapshot; load it on demand
            // only for the item actually being dragged. A failed load yields an
            // empty drop (logged), never a silently truncated label.
            guard let full = item.fullText else {
                debugLog("Drag: failed to load full text for entry \(item.id)")
                return NSItemProvider(object: "" as NSString)
            }
            let plain = Data(full.utf8)
            let rich = Self.richRepresentations(for: full)
            for type in Self.textRepresentationTypes {
                // Rich types carry their own serialization; everything else is
                // the same UTF-8 bytes under a different UTI.
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
            // nil here means no persisted db_id yet (still encoding) or a load
            // failure — either way the item must not be dragged.
            guard let data = item.imageData else {
                fatalError("Failed to load PNG data for draggable image entry \(item.id)")
            }

            do {
                let url = try temporaryImageURL(entryId: item.id)
                try data.write(to: url, options: .atomic)

                // Do not advertise a generic image payload: consumers such as
                // Dropover choose their handling from this file URL and copy the
                // PNG into their own destination during the native drag session.
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    visibility: .all
                ) { completion in
                    completion(url.absoluteString.data(using: .utf8), nil)
                    return nil
                }
                provider.suggestedName = url.lastPathComponent
            } catch {
                fatalError("Failed to materialize draggable image entry \(item.id): \(error)")
            }
        }
        return provider
    }

    /// Every text representation a drag result advertises.
    ///
    /// `public.utf8-plain-text` alone is not enough: receivers differ in which
    /// UTI they match on. Electron and web drop zones (思源笔记 and other
    /// editors) filter on `public.plain-text` or `text/plain`, while
    /// rich-text destinations (Notes, Typora, Word) prefer `public.rtf` /
    /// `public.html`. Advertising the whole set is what makes an
    /// `NSDraggingItem` from a stock AppKit text control work everywhere.
    private static let textRepresentationTypes: [UTType] = [
        .utf8PlainText,
        .plainText,
        .text,
        .html,
        .rtf,
    ]

    /// Serialized RTF and HTML for `full`.
    ///
    /// RTF and HTML are structured formats: handing a receiver the raw UTF-8
    /// bytes under those UTIs produces a document it cannot parse. Both are
    /// derived from the same attributed string so the dropped content matches
    /// the plain-text representation exactly.
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

        // Drag output is durable until a later image drag begins. This lets the
        // drop destination consume the URL after the originating drag gesture
        // ends without retaining decoded image data in the popup.
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: url)
        }
        return directory.appendingPathComponent("clipboard-\(entryId)-\(UUID().uuidString).png")
    }
}

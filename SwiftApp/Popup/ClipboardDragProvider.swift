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
/// Text is offered as UTF-8 plain text, generic plain text and abstract text.
/// A bare `NSItemProvider(object: NSString)` advertises only
/// `public.utf8-plain-text`, so receivers filtering on any of the other UTIs
/// decline the drop.
///
/// Rich text (HTML *and* RTF) is off by default. Chromium populates its drag
/// `drop_data.html` — i.e. web `text/html` — when the pasteboard carries either
/// `public.html` or `public.rtf` (it converts RTF to HTML; see
/// `web_drag_dest_mac.mm`, "Get HTML. If there's no HTML, try RTF."). VS Code's
/// Copilot chat input classifies *any* drag carrying `text/html` as a URL
/// attachment ("Attach URL as Context"): it swallows the drop and never inserts
/// the text. A few editors need the opposite — they only accept a drop that
/// carries `text/html` (思源笔记, Typora) — so the caller opts into rich text
/// per drag, keyed on the frontmost app active when the popup was opened.
enum ClipboardDragProvider {
    /// The `NSItemProvider` SwiftUI's `.onDrag` hands to the drag session for
    /// `item`.
    ///
    /// Every representation is registered with eagerly built `Data`, so a
    /// receiver reading the pasteboard during `draggingEntered:` gets the
    /// payload without waiting on SwiftUI's asynchronous provider round trip.
    static func provider(for item: ClipboardItem, richText: Bool = false) -> NSItemProvider {
        let perfDrag = PerfSpan.start("swift", "drag.materialize")
        if let span = perfDrag {
            span.data = item.isImage ? "image" : "text"
        }
        let provider = NSItemProvider()
        defer { perfDrag?.end() }
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
            let rich = richText ? Self.richRepresentations(for: full) : [:]
            let types = richText ? Self.richTextRepresentationTypes : Self.plainTextRepresentationTypes
            for type in types {
                // Plain UTIs share the same UTF-8 bytes; a rich UTI carries its
                // own serialization (see `richRepresentations`).
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
            // failure (row trimmed between snapshot and drag, DB lock/IO fault).
            // Degrade exactly like the text branch: log and offer an empty drag
            // instead of aborting the process — a declined drop is recoverable,
            // a fatalError in a user drag handler is not.
            guard let data = item.imageData else {
                debugLog("Drag: failed to load PNG data for image entry \(item.id); offering empty drag")
                return NSItemProvider()
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
                // Disk full / permission / sandbox: the drop cannot be
                // materialized. Log and decline rather than crash the app.
                errorLog("Drag: failed to materialize image entry \(item.id): \(error)")
                return NSItemProvider()
            }
        }
        return provider
    }

    /// The default text representations: plain UTIs only.
    ///
    /// `public.utf8-plain-text` alone is not enough — receivers differ in which
    /// UTI they match on, and Electron/web drop zones filter on
    /// `public.plain-text`. Plain is also the only safe default: any rich UTI
    /// makes Chromium synthesize `text/html` and breaks VS Code chat drops
    /// (see above).
    private static let plainTextRepresentationTypes: [UTType] = [
        .utf8PlainText,
        .plainText,
        .text,
    ]

    /// The representations used for apps that only accept rich text.
    ///
    /// Adds HTML and RTF to the plain set. Only used when the source app opted
    /// in (see `ClipboardBackend.richTextDragAppBundleIDs`).
    private static let richTextRepresentationTypes: [UTType] = [
        .utf8PlainText,
        .plainText,
        .text,
        .html,
        .rtf,
    ]

    /// Serialized RTF and HTML for `full`, keyed by UTI.
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

        // Sweep aged-out drag files AFTER the new one is written. The old rule
        // deleted every file at the start of each drag, which left the last
        // drag's PNG on disk forever for anyone who dragged an image only once
        // (measured: a 207 KB file surviving across several restarts). The TTL
        // is the same one the paste path uses, so a drop destination that reads
        // its file slightly after the gesture ends still finds it.
        let url = directory.appendingPathComponent("clipboard-\(entryId)-\(UUID().uuidString).png")
        clipboard_purge_stale_drag_images()
        return url
    }
}

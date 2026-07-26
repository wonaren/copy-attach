import AppKit
import Foundation
import UniformTypeIdentifiers

/// Builds native drag representations for popup history rows.
///
/// Images are eagerly materialized as PNG files when the drag begins and are
/// offered as `public.file-url`. This is the representation expected by Finder,
/// Dropover-style shelves, and applications that consume a dropped image as a
/// file rather than as an in-memory pasteboard image.
enum ClipboardDragProvider {
    static func provider(for item: ClipboardItem) -> NSItemProvider {
        switch item {
        case .text(_, _, _, _, _, _, let fullText):
            return NSItemProvider(object: fullText as NSString)

        case .image(_, let dbId, _, _, _, _, _, _):
            precondition(dbId > 0, "An image without a persisted database ID must not be draggable")
            guard let data = ClipboardBackend.shared.getImageFullByDbId(dbId) else {
                fatalError("Failed to load PNG data for draggable image entry \(item.id)")
            }

            do {
                let url = try temporaryImageURL(entryId: item.id)
                try data.write(to: url, options: .atomic)

                // Do not advertise a generic image payload: consumers such as
                // Dropover choose their handling from this file URL and copy the
                // PNG into their own destination during the native drag session.
                return NSItemProvider(
                    item: url as NSURL,
                    typeIdentifier: UTType.fileURL.identifier
                )
            } catch {
                fatalError("Failed to materialize draggable image entry \(item.id): \(error)")
            }
        }
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

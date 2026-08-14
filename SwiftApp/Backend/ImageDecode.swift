import AppKit
import ImageIO

/// Immutable box carrying a fully-decoded image across an isolation boundary
/// (Task.detached → main actor). NSImage is documented thread-safe for
/// creation/drawing since macOS 10.12, and the box never mutates after
/// construction, so `@unchecked Sendable` is sound.
struct DecodedImage: @unchecked Sendable {
    let image: NSImage
}

/// Off-main image decoding with hard bounds on the decoded pixel buffer.
///
/// The preview window displays images at most ~720pt tall / 85% of the
/// visible frame, but decoding the stored full-resolution PNG (up to many
/// tens of MB of RGBA for a large photo) wastes memory and stalls the main
/// thread. `previewImage` decodes through ImageIO's thumbnail API so the
/// decoded buffer is capped at display resolution (plus zoom headroom) —
/// typically a 5-20× memory reduction with no visible quality loss at 1×.
enum ImageDecode {
    /// Longest decoded edge (pixels) floor for previews: keeps enough real
    /// pixels for the pinch-zoom view to inspect detail (a 720pt-tall window
    /// at 2× shows ~1440px; 2048px ≈ 2.8× zoom headroom) while still bounding
    /// the decoded buffer hard (~2048²×4 ≈ 16MB worst case, vs tens of MB for
    /// a full-res 4K decode and hundreds of MB for very large photos).
    private static let zoomHeadroomPx: Int = 2048

    /// The largest point dimension a preview window will ever display an
    /// image at — mirrors `PreviewWindow.contentSize`'s image rules.
    private static let maxPreviewHeightPt: CGFloat = 720
    private static let maxPreviewFraction: CGFloat = 0.85

    /// Decode `data` for on-screen preview, bounded to display resolution.
    ///
    /// `screenSize` is the visible frame size in points; `scale` the backing
    /// scale factor. Animated GIFs are returned as-is (NSImage preserves the
    /// animation; they are small by nature). Returns nil when undecodable.
    static func previewImage(from data: Data, screenSize: CGSize, scale: CGFloat) -> DecodedImage? {
        // GIF: preserve animation exactly as the old NSImage(data:) path did.
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            guard let image = NSImage(data: data) else { return nil }
            return DecodedImage(image: image)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }

        // Display size in points, same rules as PreviewWindow.contentSize:
        // height caps at 720pt, width at 85% of the screen, aspect preserved.
        let displayH = min(CGFloat(h), maxPreviewHeightPt)
        let displayW = min(displayH * CGFloat(w) / CGFloat(h),
                           screenSize.width * maxPreviewFraction)
        let displayLongest = max(displayW, displayH)

        // Decode budget: display resolution at minimum, zoom headroom floor,
        // never larger than the source itself.
        let maxPixel = min(max(w, h),
                           max(Int(displayLongest * scale), zoomHeadroomPx))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // Decode inside this task — without it the CGImage may decompress
            // lazily on first draw, i.e. back on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return DecodedImage(image: NSImage(cgImage: cg,
                                           size: NSSize(width: cg.width, height: cg.height)))
    }
}

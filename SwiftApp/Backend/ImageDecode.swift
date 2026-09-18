import AppKit
import CoreGraphics

/// Immutable box carrying a fully-decoded image across an isolation boundary
/// (Task.detached → main actor). NSImage is documented thread-safe for
/// creation/drawing since macOS 10.12, and the box never mutates after
/// construction, so `@unchecked Sendable` is sound.
struct DecodedImage: @unchecked Sendable {
    let image: NSImage
}

/// Owns a Rust-decoded preview buffer for the lifetime of the CGImage built
/// from it. The CGDataProvider's release callback holds exactly one
/// `Unmanaged` retain; when the provider dies (preview closed, or the
/// provider was never adopted by a CGImage), `deinit` returns the buffer's
/// pages to the system and frees it. The Rust buffer is therefore released
/// exactly once, on whatever thread the last owner dies.
private final class PreviewBufferBox: @unchecked Sendable {
    let ptr: UnsafeMutableRawPointer
    let len: Int32

    init(ptr: UnsafeMutableRawPointer, len: Int32) {
        self.ptr = ptr
        self.len = len
    }

    deinit {
        clipboard_preview_buffer_release(ptr, len)
    }
}

/// Off-main image decoding with hard bounds on the decoded pixel buffer.
///
/// The preview window displays images at most ~720 pt tall / 85% of the
/// visible frame, but decoding the stored full-resolution PNG (up to many
/// tens of MB of RGBA for a large photo) wastes memory and stalls the main
/// thread. `previewImage(dbId:maxPixel:)` decodes in the Rust backend with a
/// hard cap on the longest decoded edge, so the delivered buffer is at most
/// `maxPixel²×4` bytes (~16 MB at the 2048 px budget).
///
/// Why the Rust path instead of ImageIO: ImageIO's thumbnail decode keeps its
/// full-resolution decode plus the resized buffer in malloc'd regions that
/// macOS never returns to the process footprint (measured: 8 freed preview
/// decode buffers lingered as `MALLOC_LARGE (empty)` ~47 MB after closing
/// previews). The Rust path marks every intermediate reusable
/// (MADV_FREE_REUSABLE) and hands the caller an exactly-sized buffer whose
/// pages are marked reusable when the preview closes
/// (`clipboard_preview_buffer_release`), so a closed preview stops counting
/// against the footprint — matching the capture-pipeline pool behavior.
enum ImageDecode {
    /// Longest decoded edge (pixels) floor for previews: keeps enough real
    /// pixels for the pinch-zoom view to inspect detail (a 720 pt-tall window
    /// at 2× shows ~1440 px; 2048 px ≈ 2.8× zoom headroom) while still
    /// bounding the decoded buffer hard (~2048²×4 ≈ 16 MB worst case, vs tens
    /// of MB for a full-res 4K decode and hundreds of MB for very large
    /// photos).
    private static let zoomHeadroomPx: Int = 2048

    /// The largest point dimension a preview window will ever display an
    /// image at — mirrors `PreviewWindow.contentSize`'s image rules.
    private static let maxPreviewHeightPt: CGFloat = 720
    private static let maxPreviewFraction: CGFloat = 0.85

    /// Decode budget for a stored image of `width`×`height` pixels: display
    /// resolution at minimum, zoom headroom floor, never larger than the
    /// source itself. Mirrors the old ImageIO path's budget so the on-screen
    /// result is pixel-identical to before.
    static func previewBudget(width: Int, height: Int, screenSize: CGSize, scale: CGFloat) -> Int {
        guard width > 0, height > 0 else { return zoomHeadroomPx }
        // Display size in points, same rules as PreviewWindow.contentSize:
        // height caps at 720 pt, width at 85% of the screen, aspect preserved.
        let displayH = min(CGFloat(height), maxPreviewHeightPt)
        let displayW = min(displayH * CGFloat(width) / CGFloat(height),
                           screenSize.width * maxPreviewFraction)
        let displayLongest = max(displayW, displayH)
        return min(max(width, height),
                   max(Int(displayLongest * scale), zoomHeadroomPx))
    }

    /// Concurrency bound for preview decodes.
    ///
    /// The list rows already bound their decodes (`thumbnailDecodeSlots`); the
    /// preview path had none, and it is the heavier one: each delivered buffer
    /// is up to maxPixel²×4 bytes (measured 13.2 MB for a 2293×1440 source), and
    /// it is held until the preview closes. Rapid arrow-key navigation cancels
    /// the Swift task, but cancellation cannot interrupt a decode already inside
    /// Rust — so without a slot limit a burst of selection changes stacks whole
    /// decode buffers at once.
    /// Sized for previews (one is on screen at a time) while still allowing the
    /// next selection to start decoding before the previous one is torn down.
    private static let decodeGate = PreviewDecodeGate(limit: 2)

    /// Async entry point: waits for a decode slot, then decodes. Returns nil if
    /// the task was cancelled while waiting, so a superseded selection never
    /// occupies a slot.
    static func previewImageAsync(dbId: Int, maxPixel: Int) async -> DecodedImage? {
        guard let ticket = await decodeGate.acquire() else { return nil }
        defer { ticket.release() }
        guard !Task.isCancelled else { return nil }
        // Decode off the cooperative pool: this is blocking work and would
        // otherwise occupy a thread the runtime wants for awaiting tasks.
        return await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            previewImage(dbId: dbId, maxPixel: maxPixel)
        }.value
    }

    /// Decode the stored image for `dbId` as a bounded preview. The Rust path
    /// avoids ImageIO's full-resolution thumbnail decode and returns an image
    /// whose pixel buffer has a hard longest-edge limit.
    ///
    /// Blocking; callers must go through `previewImageAsync` so the decode is
    /// concurrency-bounded.
    private static func previewImage(dbId: Int, maxPixel: Int) -> DecodedImage? {
        guard dbId != 0 else { return nil }
        var len: Int32 = 0, w: Int32 = 0, h: Int32 = 0, isGif: Int32 = 0
        let ptr = clipboard_decode_preview_by_db_id(Int64(dbId), Int32(maxPixel),
                                                    &len, &w, &h, &isGif)

        // Animated GIFs are preserved through NSImage because the Rust path
        // intentionally does not flatten animated content.
        if isGif != 0 {
            guard let data = ClipboardBackend.getImageFullByDbId(dbId),
                  let image = NSImage(data: data) else { return nil }
            return DecodedImage(image: image)
        }

        guard let ptr, len > 0, w > 0, h > 0 else { return nil }
        return makeImage(ptr: ptr, len: len, width: Int(w), height: Int(h))
    }

    /// Wrap a Rust RGBA8 buffer in a CGImage whose data provider releases the
    /// buffer exactly when the preview image goes away. Straight (non-
    /// premultiplied) alpha — `.last` matches the Rust buffer's byte layout.
    private static func makeImage(ptr: UnsafeMutableRawPointer, len: Int32,
                                  width: Int, height: Int) -> DecodedImage? {
        let box = PreviewBufferBox(ptr: ptr, len: len)
        let retained = Unmanaged.passRetained(box).toOpaque()
        guard let provider = CGDataProvider(dataInfo: retained, data: ptr, size: Int(len),
                                            releaseData: { info, _, _ in
            guard let info else { return }
            Unmanaged<PreviewBufferBox>.fromOpaque(info).release()
        }) else {
            Unmanaged<PreviewBufferBox>.fromOpaque(retained).release()
            return nil
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil  // provider released at scope exit → box released → buffer freed
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: bitmapInfo, provider: provider,
                               decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else {
            return nil  // CGImageCreate failed → provider not retained → freed at scope exit
        }
        return DecodedImage(image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)))
    }
}

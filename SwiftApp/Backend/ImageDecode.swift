import AppKit
import CoreGraphics

final class DecodedImage: @unchecked Sendable {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
    }
}

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

enum ImageDecode {
    private static let zoomHeadroomPx: Int = 2048

    private static let maxPreviewHeightPt: CGFloat = 720
    private static let maxPreviewFraction: CGFloat = 0.85

    static func previewBudget(width: Int, height: Int, screenSize: CGSize, scale: CGFloat) -> Int {
        guard width > 0, height > 0 else { return zoomHeadroomPx }
        let displayH = min(CGFloat(height), maxPreviewHeightPt)
        let displayW = min(displayH * CGFloat(width) / CGFloat(height),
                           screenSize.width * maxPreviewFraction)
        let displayLongest = max(displayW, displayH)
        return min(max(width, height),
                   max(Int(displayLongest * scale), zoomHeadroomPx))
    }

    private static let decodeGate = PreviewDecodeGate(limit: 2)

    @MainActor private static var previewSession: UUID?

    @MainActor private static let previewCache: NSCache<NSString, DecodedImage> = {
        let cache = NSCache<NSString, DecodedImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func beginPreviewSession() {
        previewSession = UUID()
    }

    @MainActor
    static func endPreviewSession() {
        previewSession = nil
        previewCache.removeAllObjects()
    }

    @MainActor
    static func previewImageAsync(dbId: Int, maxPixel: Int) async -> DecodedImage? {
        guard let session = previewSession, !Task.isCancelled else { return nil }
        let key = "\(dbId):\(maxPixel)" as NSString
        if let cached = previewCache.object(forKey: key) { return cached }
        guard let ticket = await decodeGate.acquire() else { return nil }
        defer { ticket.release() }
        guard !Task.isCancelled, previewSession == session else { return nil }
        if let cached = previewCache.object(forKey: key) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            previewImage(dbId: dbId, maxPixel: maxPixel)
        }.value
        guard !Task.isCancelled, previewSession == session else { return nil }
        if let decoded {
            let cost = Int(decoded.image.size.width * decoded.image.size.height * 4)
            previewCache.setObject(decoded, forKey: key, cost: cost)
        }
        return decoded
    }

    private static func previewImage(dbId: Int, maxPixel: Int) -> DecodedImage? {
        guard dbId != 0 else { return nil }
        var len: Int32 = 0, w: Int32 = 0, h: Int32 = 0, isGif: Int32 = 0
        let ptr = clipboard_decode_preview_by_db_id(Int64(dbId), Int32(maxPixel),
                                                    &len, &w, &h, &isGif)

        if isGif != 0 {
            guard let data = ClipboardBackend.getImageFullByDbId(dbId),
                  let image = NSImage(data: data) else { return nil }
            return DecodedImage(image: image)
        }

        guard let ptr, len > 0, w > 0, h > 0 else { return nil }
        return makeImage(ptr: ptr, len: len, width: Int(w), height: Int(h))
    }

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
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: bitmapInfo, provider: provider,
                               decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else {
            return nil
        }
        return DecodedImage(image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)))
    }
}

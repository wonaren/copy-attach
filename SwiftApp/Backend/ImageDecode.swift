import AppKit
import CoreGraphics
import IOSurface

final class PreviewSurface: @unchecked Sendable {
    let surface: IOSurface
    let pixelWidth: Int
    let pixelHeight: Int

    init(surface: IOSurface, pixelWidth: Int, pixelHeight: Int) {
        self.surface = surface
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var pixelCost: Int { pixelWidth * pixelHeight * 4 }
}

final class DecodedImage: @unchecked Sendable {
    let surface: PreviewSurface?
    let image: NSImage?

    init(surface: PreviewSurface) {
        self.surface = surface
        self.image = nil
    }

    init(image: NSImage) {
        self.surface = nil
        self.image = image
    }

    var pixelCost: Int {
        if let surface { return surface.pixelCost }
        if let image { return Int(image.size.width * image.size.height * 4) }
        return 0
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
    @MainActor private static var previewSessionOwners: Set<UUID> = []

    @MainActor private static let previewCache: NSCache<NSString, DecodedImage> = {
        let cache = NSCache<NSString, DecodedImage>()
        cache.countLimit = 2
        return cache
    }()

    @MainActor
    @discardableResult
    static func beginPreviewSession() -> UUID {
        let token = UUID()
        previewSessionOwners.insert(token)
        if previewSession == nil {
            previewSession = UUID()
        }
        return token
    }

    @MainActor
    static func endPreviewSession(_ token: UUID) {
        previewSessionOwners.remove(token)
        guard previewSessionOwners.isEmpty else { return }
        previewSession = nil
        previewCache.removeAllObjects()
    }

    @MainActor
    static func previewImageAsync(dbId: Int,
                                  sourceWidth: Int,
                                  sourceHeight: Int,
                                  maxPixel: Int) async -> DecodedImage? {
        guard let session = previewSession, !Task.isCancelled else { return nil }
        let key = "\(dbId):\(maxPixel)" as NSString
        if let cached = previewCache.object(forKey: key) { return cached }
        guard let ticket = await decodeGate.acquire() else { return nil }
        defer { ticket.release() }
        guard !Task.isCancelled, previewSession == session else { return nil }
        if let cached = previewCache.object(forKey: key) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            previewImage(dbId: dbId,
                         sourceWidth: sourceWidth,
                         sourceHeight: sourceHeight,
                         maxPixel: maxPixel)
        }.value
        guard !Task.isCancelled, previewSession == session else { return nil }
        if let decoded {
            previewCache.setObject(decoded, forKey: key, cost: decoded.pixelCost)
        }
        return decoded
    }

    private static func previewImage(dbId: Int,
                                     sourceWidth: Int,
                                     sourceHeight: Int,
                                     maxPixel: Int) -> DecodedImage? {
        guard dbId != 0, sourceWidth > 0, sourceHeight > 0 else { return nil }
        var dw: Int32 = 0
        var dh: Int32 = 0
        guard clipboard_preview_dims(Int32(sourceWidth), Int32(sourceHeight), Int32(maxPixel), &dw, &dh) != 0,
              dw > 0, dh > 0 else { return nil }

        let properties = [
            IOSurfacePropertyKey.width: Int(dw),
            IOSurfacePropertyKey.height: Int(dh),
            IOSurfacePropertyKey.bytesPerElement: 4,
            IOSurfacePropertyKey.pixelFormat: 0x42475241,
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }

        let stride = surface.bytesPerRow
        var outW: Int32 = 0
        var outH: Int32 = 0
        var isGif: Int32 = 0
        let filled = clipboard_decode_preview_into(Int64(dbId), Int32(maxPixel),
                                                   surface.baseAddress.assumingMemoryBound(to: UInt8.self),
                                                   Int32(stride * Int(dh)), Int32(stride),
                                                   &outW, &outH, &isGif)

        if isGif != 0 {
            guard let data = ClipboardBackend.getImageFullByDbId(dbId),
                  let image = NSImage(data: data) else { return nil }
            return DecodedImage(image: image)
        }
        guard filled != 0, outW == dw, outH == dh else { return nil }
        return DecodedImage(surface: PreviewSurface(surface: surface,
                                                    pixelWidth: Int(dw),
                                                    pixelHeight: Int(dh)))
    }
}

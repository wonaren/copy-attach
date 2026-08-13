import AppKit

extension NSImage {
    static var appIcon: NSImage {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }
        return NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil) ?? NSImage()
    }

    /// Load the application icon SVG from the bundle as an NSImage.
    /// Uses icon_inner.svg which includes a white background for in-app display.
    static var appIconSVG: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon_inner", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

/// Cache app icons by bundle ID to avoid repeated lookups. Icons are stored
/// as a single 36 pt representation (2× the 18 pt row size) — NSWorkspace
/// icons carry every size up to 512 pt, and caching the full multi-rep image
/// would pin hundreds of KB per app for an 18 pt row.
///
/// Bounded by `countLimit`: a plain dictionary would keep one ~20 KB bitmap
/// per distinct source app for the whole process lifetime (unbounded growth
/// over months of use). NSCache evicts the least-recently-used entries past
/// the cap and under system memory pressure; a re-decoded icon costs one
/// NSWorkspace lookup on the next scroll.
@MainActor private let appIconCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 128
    return cache
}()

@MainActor
func getAppIcon(for bundleId: String) -> NSImage? {
    if bundleId.isEmpty { return nil }
    let key = bundleId as NSString
    if let cached = appIconCache.object(forKey: key) { return cached }

    // Try to get icon from the running application
    let icon: NSImage? = {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
           let icon = app.icon {
            return icon
        }
        // Fallback: try to get icon from the app bundle path
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: path.path)
        }
        return nil
    }()
    guard let icon else { return nil }

    // Downscale to the row display size (36 pt = 18 pt @2x Retina), so the
    // cache holds one small bitmap per app instead of the full multi-size
    // icon. 18 pt rows cannot use anything larger, so this is lossless for
    // rendering.
    let scaled = NSImage(size: NSSize(width: 36, height: 36))
    scaled.lockFocus()
    icon.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
    scaled.unlockFocus()
    appIconCache.setObject(scaled, forKey: key)
    return scaled
}

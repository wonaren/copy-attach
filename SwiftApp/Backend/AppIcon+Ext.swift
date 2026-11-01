import AppKit

extension NSImage {
    static var appIcon: NSImage {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }
        return NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil) ?? NSImage()
    }

    static var appIconSVG: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon_inner", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

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

    let icon: NSImage? = {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
           let icon = app.icon {
            return icon
        }
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: path.path)
        }
        return nil
    }()
    guard let icon else { return nil }

    let scaled = NSImage(size: NSSize(width: 36, height: 36))
    scaled.lockFocus()
    icon.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
    scaled.unlockFocus()
    appIconCache.setObject(scaled, forKey: key)
    return scaled
}

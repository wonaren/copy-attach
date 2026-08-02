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

/// Cache app icons by bundle ID to avoid repeated lookups
@MainActor private var appIconCache: [String: NSImage] = [:]

@MainActor
func getAppIcon(for bundleId: String) -> NSImage? {
    if bundleId.isEmpty { return nil }
    if let cached = appIconCache[bundleId] { return cached }

    // Try to get icon from the running application
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
       let icon = app.icon {
        appIconCache[bundleId] = icon
        return icon
    }

    // Fallback: try to get icon from the app bundle path
    if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
        let icon = NSWorkspace.shared.icon(forFile: path.path)
        appIconCache[bundleId] = icon
        return icon
    }

    return nil
}

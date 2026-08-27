import AppKit
import SwiftUI

// MARK: - Preview Content

struct PreviewContent: View {
    let item: ClipboardItem

    @State private var image: NSImage?
    @State private var isLoadingImage = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme


    private var currentDbId: Int {
        guard case .image(_, let dbId, _, _, _, _, _, _) = item else { return 0 }
        return dbId
    }

    /// Stored pixel dimensions of the image item (capture-time decode size).
    private var imagePixelSize: (w: Int, h: Int) {
        guard case .image(_, _, let w, let h, _, _, _, _) = item else { return (0, 0) }
        return (w, h)
    }

    /// Derive NSColor from theme.previewPrimaryText so there's a single source
    /// of truth for the preview text color.
    private var previewTextNSColor: NSColor {
        if let cgColor = theme.previewPrimaryText.cgColor,
           let color = NSColor(cgColor: cgColor) {
            return color
        }
        // Fallback: should not be reached since AppTheme uses numeric Color values,
        // but guarded in case a semantic Color is introduced in the future.
        return colorScheme == .dark
            ? NSColor(white: 0.83, alpha: 1.0)
            : NSColor(white: 0.22, alpha: 1.0)
    }

    var body: some View {
        ZStack {
            theme.previewBackground
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            switch item {
            case .text(_, let text, _, _, _, _, _):
                LargeTextView(text: text, textColor: previewTextNSColor)
            case .image(_, let dbId, _, _, _, _, _, _):
                imageContent(dbId: dbId)
            }
        }
    }

    @ViewBuilder
    private func imageContent(dbId: Int) -> some View {
        Group {
            if let img = image {
                ZoomableImageView(image: img)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else if isLoadingImage {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundColor(theme.previewSecondaryText)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 24))
                    .foregroundColor(theme.previewSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Auto-cancels previous task and restarts when dbId changes
        .task(id: dbId, priority: .userInitiated) {
            await loadImage(dbId: dbId)
        }
        .onDisappear {
            // Break the NSImage -> CGImage -> PreviewBufferBox ownership chain
            // as soon as this preview content leaves the hosting view.
            image = nil
            isLoadingImage = false
        }
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }
        isLoadingImage = true

        // The decode budget depends on the display constraints and the item's
        // stored pixel size; capture them on the main actor, then decode fully
        // off-main. The Rust backend downscales and delivers an exactly-sized
        // RGBA buffer whose pages stop counting against the footprint when the
        // preview closes (ImageIO's decodes lingered as `MALLOC_LARGE
        // (empty)` residue — see ImageDecode).
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = imagePixelSize
        let maxPixel = ImageDecode.previewBudget(width: size.w, height: size.h,
                                                 screenSize: screenSize, scale: scale)
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            ImageDecode.previewImage(dbId: dbId, maxPixel: maxPixel)
        }.value
        // Only apply if we're still showing the same item
        if currentDbId == dbId {
            if let decoded { image = decoded.image }
            isLoadingImage = false
        }
    }
}

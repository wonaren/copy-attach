import AppKit
import SwiftUI

// MARK: - Preview Content

struct PreviewContent: View {
    let item: ClipboardItem

    @State private var image: NSImage?
    @State private var hasFailed = false
    @State private var showSpinner = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(item: ClipboardItem) {
        self.item = item
        let initialImage: NSImage?
        if case .image(_, let dbId, _, _, _, _, _, _, _) = item {
            initialImage = ClipboardBackend.shared.cachedThumbnail(dbId: dbId)
        } else {
            initialImage = nil
        }
        self._image = State(initialValue: initialImage)
    }

    private var currentDbId: Int {
        guard case .image(_, let dbId, _, _, _, _, _, _, _) = item else { return 0 }
        return dbId
    }

    /// Stored pixel dimensions of the image item (capture-time decode size).
    private var imagePixelSize: (w: Int, h: Int) {
        guard case .image(_, _, let w, let h, _, _, _, _, _) = item else { return (0, 0) }
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
            case .text:
                textContent
            case .image:
                imageContent(dbId: currentDbId)
            }
        }
    }

    private var textContent: some View {
        let prepared = PreviewTextLayout.prepare(item.preview)
        let isDark = colorScheme == .dark
        return VStack(spacing: 0) {
            LargeTextView(
                preparedText: prepared,
                textColor: previewTextNSColor,
                isDark: isDark
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .opacity(isDark ? 0.12 : 0.08)

            PreviewFooterBar(
                item: item,
                prepared: prepared
            )
        }
    }

    @ViewBuilder
    private func imageContent(dbId: Int) -> some View {
        Group {
            if let img = image {
                ZoomableImageView(image: img, dbId: dbId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else if hasFailed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 24))
                    .foregroundColor(theme.previewSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showSpinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundColor(theme.previewSecondaryText)
            } else {
                Color.clear
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
            hasFailed = false
            showSpinner = false
        }
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }

        // Fast check if thumbnail became available right after init
        if image == nil, let cached = ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
            image = cached
        }

        // Delay showing the spinner to avoid 1-frame flickering on fast decodes (<150ms).
        // If an image (e.g. cached thumbnail) is already displayed, no spinner is needed.
        let spinnerTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled, currentDbId == dbId, image == nil, !hasFailed {
                showSpinner = true
            }
        }

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
        // Concurrency-bounded inside `previewImageAsync`: an unbounded burst of
        // selections (fast arrow-key navigation) would otherwise stack whole
        // decode buffers, since cancelling this task cannot interrupt a decode
        // already running in Rust.
        let decoded = await ImageDecode.previewImageAsync(dbId: dbId, maxPixel: maxPixel)
        spinnerTask.cancel()

        guard currentDbId == dbId, !Task.isCancelled else { return }

        // Only apply if we're still showing the same item
        if let decoded {
            image = decoded.image
            hasFailed = false
        } else if image == nil {
            hasFailed = true
        }
        showSpinner = false
    }
}

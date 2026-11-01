import AppKit
import SwiftUI

struct PreviewContent: View {
    let item: ClipboardItem

    @State private var image: NSImage?
    @State private var hasFailed = false
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

    private var imagePixelSize: (w: Int, h: Int) {
        guard case .image(_, _, let w, let h, _, _, _, _, _) = item else { return (0, 0) }
        return (w, h)
    }

    private var previewTextNSColor: NSColor {
        if let cgColor = theme.previewPrimaryText.cgColor,
           let color = NSColor(cgColor: cgColor) {
            return color
        }
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
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.previewBackground)
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundColor(theme.previewSecondaryText)
                            .symbolEffect(.pulse)
                        Text("载入预览中…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.previewSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .linearShimmer(isActive: true, duration: 1.3)
            }
        }
        .task(id: dbId, priority: .userInitiated) {
            await loadImage(dbId: dbId)
        }
        .onDisappear {
            image = nil
            hasFailed = false
        }
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }

        if image == nil, let cached = ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
            image = cached
        }

        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = imagePixelSize
        let maxPixel = ImageDecode.previewBudget(width: size.w, height: size.h,
                                                 screenSize: screenSize, scale: scale)
        let decoded = await ImageDecode.previewImageAsync(dbId: dbId, maxPixel: maxPixel)

        guard currentDbId == dbId, !Task.isCancelled else { return }

        if let decoded {
            image = decoded.image
            hasFailed = false
        } else if image == nil {
            hasFailed = true
        }
    }
}

import AppKit
import Observation
import SwiftUI

@Observable
final class PreviewDismissState {
    var isDismissing = false
}

struct PreviewContent: View {
    let item: ClipboardItem
    private let maxPixelOverride: Int?
    private let onTapWhenUnzoomed: (() -> Void)?
    private let onPaste: ((Int) -> Void)?
    private let onClose: (() -> Void)?
    private let onImageLoaded: ((NSImage) -> Void)?
    private let showsZoomHint: Bool
    private let hoverState: PreviewHoverState?
    private let dismissState: PreviewDismissState?

    @State private var image: NSImage?
    @State private var hasFailed = false
    @State private var hasAppeared = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(item: ClipboardItem,
         initialImage: NSImage? = nil,
         maxPixelOverride: Int? = nil,
         onTapWhenUnzoomed: (() -> Void)? = nil,
         onPaste: ((Int) -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         onImageLoaded: ((NSImage) -> Void)? = nil,
         showsZoomHint: Bool = false,
         hoverState: PreviewHoverState? = nil,
         dismissState: PreviewDismissState? = nil) {
        self.item = item
        self.maxPixelOverride = maxPixelOverride
        self.onTapWhenUnzoomed = onTapWhenUnzoomed
        self.onPaste = onPaste
        self.onClose = onClose
        self.onImageLoaded = onImageLoaded
        self.showsZoomHint = showsZoomHint
        self.hoverState = hoverState
        self.dismissState = dismissState
        let seeded: NSImage?
        if let initialImage {
            seeded = initialImage
        } else if case .image(_, let dbId, _, _, _, _, _, _, _) = item {
            seeded = ClipboardBackend.shared.cachedThumbnail(dbId: dbId)
        } else {
            seeded = nil
        }
        self._image = State(initialValue: seeded)
    }

    private struct ImageLoadKey: Hashable {
        let dbId: Int
        let maxPixel: Int?
    }

    private var imageLoadKey: ImageLoadKey {
        ImageLoadKey(dbId: currentDbId, maxPixel: maxPixelOverride)
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
            theme.popupBackground
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            switch item {
            case .text:
                textContent
            case .image:
                imageContent(dbId: currentDbId)
            }
        }
        .overlay {
            if showsZoomHint {
                miniHoverHint
            }
        }
        .scaleEffect(showsZoomHint && !hasAppeared ? 0.97 : 1.0)
        .scaleEffect(dismissState?.isDismissing == true ? 1.04 : 1.0, anchor: .center)
        .blur(radius: dismissState?.isDismissing == true ? 16.0 : 0.0)
        .opacity(dismissState?.isDismissing == true ? 0.0 : 1.0)
        .animation(.easeOut(duration: 0.15), value: dismissState?.isDismissing)
        .onAppear {
            guard showsZoomHint else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.86)) {
                hasAppeared = true
            }
        }
    }

    private var isHoveringBubble: Bool {
        hoverState?.isHovering ?? false
    }

    @ViewBuilder
    private var textContent: some View {
        let prepared = PreviewTextLayout.prepare(item.preview)
        let isDark = colorScheme == .dark
        if showsZoomHint {
            miniTextContent(prepared)
        } else {
            VStack(spacing: 0) {
                LargeTextView(
                    preparedText: prepared,
                    textColor: previewTextNSColor,
                    isDark: isDark,
                    onTap: onTapWhenUnzoomed
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(theme.previewBackground)
                )
                .padding(.horizontal, 3)
                .padding(.top, 3)

                Divider()
                    .opacity(isDark ? 0.12 : 0.08)

                PreviewFooterBar(
                    item: item,
                    details: .text(prepared),
                    onPaste: onPaste,
                    onClose: onClose
                )
            }
        }
    }

    private func miniTextContent(_ prepared: PreparedPreviewText) -> some View {
        Text(prepared.displayText)
            .font(miniTextFont(prepared.kind))
            .foregroundColor(theme.previewPrimaryText)
            .lineLimit(6)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(theme.previewBackground)
            )
            .padding(3)
            .contentShape(Rectangle())
            .onTapGesture { onTapWhenUnzoomed?() }
    }

    private func miniTextFont(_ kind: TextContentKind) -> Font {
        kind == .prose ? .system(size: 12) : .system(size: 12, design: .monospaced)
    }

    @ViewBuilder
    private func imageContent(dbId: Int) -> some View {
        Group {
            if showsZoomHint {
                miniImageContent
            } else {
                VStack(spacing: 0) {
                    largeImageBody(dbId: dbId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .padding(.horizontal, 3)
                        .padding(.top, 3)

                    Divider()
                        .opacity(colorScheme == .dark ? 0.12 : 0.08)

                    PreviewFooterBar(
                        item: item,
                        details: .image(width: imagePixelSize.w, height: imagePixelSize.h),
                        onPaste: onPaste,
                        onClose: onClose
                    )
                }
            }
        }
        .task(id: imageLoadKey, priority: .userInitiated) {
            await loadImage(dbId: dbId)
        }
        .onDisappear {
            image = nil
            hasFailed = false
        }
    }

    @ViewBuilder
    private var miniImageContent: some View {
        if let img = image {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(3)
                .contentShape(Rectangle())
                .onTapGesture { onTapWhenUnzoomed?() }
        } else if hasFailed {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 24))
                .foregroundColor(theme.previewSecondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            imageLoadingPlaceholder
        }
    }

    @ViewBuilder
    private func largeImageBody(dbId: Int) -> some View {
        if let img = image {
            ZoomableImageView(image: img, dbId: dbId, onTapWhenUnzoomed: onTapWhenUnzoomed)
        } else if hasFailed {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 24))
                .foregroundColor(theme.previewSecondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            imageLoadingPlaceholder
        }
    }

    private var imageLoadingPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
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
        .contentShape(Rectangle())
        .onTapGesture { onTapWhenUnzoomed?() }
    }

    private var miniHoverHint: some View {
        ZStack {
            cornerMark
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            cornerMark
                .rotationEffect(.degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
        }
        .opacity(isHoveringBubble ? 1 : 0)
        .scaleEffect(isHoveringBubble ? 1 : 0.94)
        .animation(.easeOut(duration: 0.12), value: isHoveringBubble)
        .allowsHitTesting(false)
    }

    private var cornerMark: some View {
        ZStack {
            CornerMarkShape()
                .stroke(Color.black.opacity(0.55),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            CornerMarkShape()
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 20, height: 20)
    }

    private func applyImage(_ newImage: NSImage) {
        image = newImage
        onImageLoaded?(newImage)
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }
        let perfLoad = PerfSpan.start("swift", "preview.image_load")
        perfLoad?.val = Int64(dbId)
        perfLoad?.data = "cancelled"
        defer { perfLoad?.end() }

        if let image {
            onImageLoaded?(image)
        }

        if image == nil, let cached = ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
            applyImage(cached)
        }

        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = imagePixelSize
        let maxPixel = maxPixelOverride
            ?? ImageDecode.previewBudget(width: size.w, height: size.h,
                                         screenSize: screenSize, scale: scale)
        let decoded = await ImageDecode.previewImageAsync(dbId: dbId, maxPixel: maxPixel)

        guard currentDbId == dbId, !Task.isCancelled else { return }

        if let decoded {
            applyImage(decoded.image)
            hasFailed = false
            perfLoad?.data = showsZoomHint ? "mini" : "large"
        } else if image == nil {
            hasFailed = true
            perfLoad?.data = "unavailable"
        }
    }
}

private struct CornerMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 1
        let minX = rect.minX + inset
        let minY = rect.minY + inset
        let maxX = rect.maxX - inset
        let maxY = rect.maxY - inset
        let radius = min(6, (maxX - minX) / 2, (maxY - minY) / 2)

        var path = Path()
        path.move(to: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: minX + radius, y: minY))
        path.addQuadCurve(to: CGPoint(x: minX, y: minY + radius),
                          control: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX, y: maxY))
        return path
    }
}

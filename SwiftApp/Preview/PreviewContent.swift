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

                Divider()
                    .opacity(isDark ? 0.12 : 0.08)

                PreviewFooterBar(
                    item: item,
                    prepared: prepared,
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
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture { onTapWhenUnzoomed?() }
    }

    private func miniTextFont(_ kind: TextContentKind) -> Font {
        kind == .prose ? .system(size: 12) : .system(size: 12, design: .monospaced)
    }

    @ViewBuilder
    private func imageContent(dbId: Int) -> some View {
        Group {
            if let img = image {
                if showsZoomHint {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(6)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapWhenUnzoomed?() }
                } else {
                    ZoomableImageView(image: img, dbId: dbId, onTapWhenUnzoomed: onTapWhenUnzoomed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(6)
                }
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
                .contentShape(Rectangle())
                .onTapGesture { onTapWhenUnzoomed?() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !showsZoomHint, onPaste != nil || onClose != nil {
                largeActionButtons
                    .padding(12)
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

    private var miniHoverHint: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cornerMark
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                cornerMark
                    .rotationEffect(.degrees(180))
            }
        }
        .padding(8)
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

    @ViewBuilder
    private var largeActionButtons: some View {
        HStack(spacing: 6) {
            if let onPaste {
                PreviewActionButton(title: "粘贴",
                                    icon: "arrow.down.to.line",
                                    style: .overlay,
                                    action: { onPaste(item.id) })
            }
            if let onClose {
                PreviewActionButton(title: "关闭",
                                    icon: "xmark",
                                    style: .overlay,
                                    action: onClose)
            }
        }
    }

    private func applyImage(_ newImage: NSImage) {
        image = newImage
        onImageLoaded?(newImage)
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }

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
        } else if image == nil {
            hasFailed = true
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

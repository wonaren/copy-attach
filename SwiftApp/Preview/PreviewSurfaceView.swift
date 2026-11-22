import AppKit
import IOSurface
import SwiftUI

struct SurfaceImageView: NSViewRepresentable {
    let surface: PreviewSurface
    var cornerRadius: CGFloat = 0
    var onTap: (() -> Void)?

    func makeNSView(context: Context) -> SurfaceNSView {
        let view = SurfaceNSView()
        view.apply(surface: surface, cornerRadius: cornerRadius, onTap: onTap)
        return view
    }

    func updateNSView(_ nsView: SurfaceNSView, context: Context) {
        nsView.apply(surface: surface, cornerRadius: cornerRadius, onTap: onTap)
    }
}

final class SurfaceNSView: NSView {
    private var onTap: (() -> Void)?
    private var currentSurface: IOSurface?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func apply(surface: PreviewSurface, cornerRadius: CGFloat, onTap: (() -> Void)?) {
        self.onTap = onTap
        if currentSurface !== surface.surface {
            currentSurface = surface.surface
            layer?.contents = surface.surface
        }
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        onTap?()
    }
}

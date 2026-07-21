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
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }
        isLoadingImage = true
        let data = await Task.detached(priority: .userInitiated) {
            ClipboardBackend.shared.getImageFullByDbId(dbId)
        }.value
        // Only apply if we're still showing the same item
        if currentDbId == dbId {
            if let data, let img = NSImage(data: data) { image = img }
            isLoadingImage = false
        }
    }
}

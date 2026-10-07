import AppKit
import SwiftUI

// MARK: - Preview Footer Bar (Native HUD pill showing source app and metadata)

struct PreviewFooterBar: View {
    let item: ClipboardItem
    let prepared: PreparedPreviewText
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var appIcon: NSImage? {
        if !item.sourceBundleId.isEmpty {
            return getAppIcon(for: item.sourceBundleId)
        }
        return nil
    }

    private var formattedStats: String {
        let linesStr = prepared.isTruncatedLines
            ? "\(PreviewFooterBar.formatNumber(prepared.lineCount))+ 行"
            : "\(PreviewFooterBar.formatNumber(prepared.lineCount)) 行"
        let charsStr = "\(PreviewFooterBar.formatNumber(prepared.charCount)) 字符"

        if prepared.byteCount >= 10 * 1024 {
            let sizeStr = PreviewFooterBar.formatByteSize(prepared.byteCount)
            return "\(linesStr) · \(charsStr) (\(sizeStr))"
        } else {
            return "\(linesStr) · \(charsStr)"
        }
    }

    private var badgeTitle: String {
        switch prepared.kind {
        case .json: return "JSON"
        case .code: return "代码"
        case .prose: return "文本"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Source app info
            HStack(spacing: 5) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
                if !item.sourceName.isEmpty && item.sourceName != "-" {
                    Text(item.sourceName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.previewSecondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Metadata: kind badge + stats
            HStack(spacing: 6) {
                Text(badgeTitle)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.previewSecondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )

                Text(formattedStats)
                    .font(.system(size: 11))
                    .foregroundColor(theme.previewSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(
            colorScheme == .dark
                ? Color.black.opacity(0.18)
                : Color.black.opacity(0.03)
        )
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func formatNumber(_ num: Int) -> String {
        numberFormatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }

    static func formatByteSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
        } else {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB", mb)
        }
    }
}

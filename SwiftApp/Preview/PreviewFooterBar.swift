import AppKit
import SwiftUI

struct PreviewFooterBar: View {
    enum Details {
        case text(PreparedPreviewText)
        case image(width: Int, height: Int)
    }

    static let height: CGFloat = 28

    let item: ClipboardItem
    let details: Details
    let onPaste: ((Int) -> Void)?
    let onClose: (() -> Void)?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(item: ClipboardItem,
         details: Details,
         onPaste: ((Int) -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        self.item = item
        self.details = details
        self.onPaste = onPaste
        self.onClose = onClose
    }

    private var appIcon: NSImage? {
        if !item.sourceBundleId.isEmpty {
            return getAppIcon(for: item.sourceBundleId)
        }
        return nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showName: true, showStats: true)
            row(showName: true, showStats: false)
            row(showName: false, showStats: false)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(
            colorScheme == .dark
                ? Color.black.opacity(0.18)
                : Color.black.opacity(0.03)
        )
    }

    private func row(showName: Bool, showStats: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
                if showName && !item.sourceName.isEmpty && item.sourceName != "-" {
                    Text(item.sourceName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.previewSecondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }
            }

            Spacer(minLength: 8)

            if showStats {
                statsView
            }

            Text("最近使用 \(Self.formatTimestamp(item.timestamp))")
                .font(.system(size: 10))
                .foregroundColor(theme.previewSecondaryText)
                .lineLimit(1)
                .fixedSize()

            if onPaste != nil || onClose != nil {
                HStack(spacing: 6) {
                    if let onPaste {
                        PreviewActionButton(title: "粘贴",
                                            icon: "arrow.down.to.line",
                                            action: { onPaste(item.id) })
                    }
                    if let onClose {
                        PreviewActionButton(title: "关闭",
                                            icon: "xmark",
                                            action: onClose)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statsView: some View {
        switch details {
        case .text(let prepared):
            HStack(spacing: 6) {
                Text(Self.badgeTitle(prepared))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.previewSecondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )

                Text(Self.formattedStats(prepared))
                    .font(.system(size: 11))
                    .foregroundColor(theme.previewSecondaryText)
                    .lineLimit(1)
            }
        case .image(let width, let height):
            Text("\(width) × \(height)")
                .font(.system(size: 11))
                .foregroundColor(theme.previewSecondaryText)
                .lineLimit(1)
        }
    }

    private static func formattedStats(_ prepared: PreparedPreviewText) -> String {
        let linesStr = prepared.isTruncatedLines
            ? "\(formatNumber(prepared.lineCount))+ 行"
            : "\(formatNumber(prepared.lineCount)) 行"
        let charsStr = "\(formatNumber(prepared.charCount)) 字符"

        if prepared.byteCount >= 10 * 1024 {
            let sizeStr = formatByteSize(prepared.byteCount)
            return "\(linesStr) · \(charsStr) (\(sizeStr))"
        } else {
            return "\(linesStr) · \(charsStr)"
        }
    }

    private static func badgeTitle(_ prepared: PreparedPreviewText) -> String {
        switch prepared.kind {
        case .json: return "JSON"
        case .code: return "代码"
        case .prose: return "文本"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    private static func formatTimestamp(_ seconds: UInt64) -> String {
        guard seconds > 0 else { return "—" }
        return timestampFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(seconds))
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

struct PreviewActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(theme.popupPrimaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.popupTagBackground))
            .overlay(Capsule().strokeBorder(theme.popupRowBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(AppleTactileButtonStyle(scale: 0.92))
        .fixedSize()
    }
}

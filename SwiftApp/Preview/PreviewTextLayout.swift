import AppKit

enum TextContentKind: Equatable, Sendable {
    case prose
    case code
    case json
}

struct PreparedPreviewText: Equatable, Sendable {
    let rawText: String
    let displayText: String
    let kind: TextContentKind
    let lineCount: Int
    let isTruncatedLines: Bool
    let charCount: Int
    let byteCount: Int
}

enum PreviewTextClassifier {
    static func prepare(_ rawText: String) -> PreparedPreviewText {
        let (displayText, kind) = classify(rawText)
        let (lines, truncated) = estimateLines(displayText)
        let charCount = displayText.count
        let byteCount = displayText.utf8.count
        return PreparedPreviewText(
            rawText: rawText,
            displayText: displayText,
            kind: kind,
            lineCount: lines,
            isTruncatedLines: truncated,
            charCount: charCount,
            byteCount: byteCount
        )
    }

    private static func estimateLines(_ text: String) -> (count: Int, truncated: Bool) {
        var count = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") {
                count += 1
                if count >= 9999 { return (9999, true) }
            }
        }
        return (count + 1, false)
    }

    private static func classify(_ text: String) -> (displayText: String, kind: TextContentKind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (text, .prose)
        }

        if trimmed.count <= 120_000,
           (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
           (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            if trimmed.contains("\n") {
                return (text, .json)
            } else {
                let formatted = prettyPrintSingleLineJSON(trimmed)
                return (formatted, .json)
            }
        }

        let sample = String(trimmed.prefix(800))

        if !sample.contains("\n") {
            if sample.hasPrefix("http://") || sample.hasPrefix("https://") || sample.hasPrefix("file://") || sample.hasPrefix("/") {
                return (text, .code)
            }
            if !sample.contains(" ") && sample.count > 16 {
                return (text, .code)
            }
        }

        let codeIndicators = [
            "func ", "function ", "def ", "class ", "struct ", "interface ", "enum ",
            "import ", "export ", "return ", "const ", "let ", "var ", "val ",
            "public ", "private ", "fn ", "impl ", "async ", "await ",
            "SELECT ", "FROM ", "WHERE ", "INSERT ", "UPDATE ", "DELETE ",
            "<html>", "<div", "/>", "{\n", "};\n", "{\r\n", "=>", "->",
            "//", "/*", "NSLog(", "print(", "println("
        ]
        var codeScore = 0
        for indicator in codeIndicators {
            if sample.contains(indicator) {
                codeScore += 2
            }
        }

        let lines = sample.components(separatedBy: .newlines)
        var indentedLines = 0
        for line in lines {
            if line.hasPrefix("    ") || line.hasPrefix("\t") || line.hasPrefix("  ") {
                indentedLines += 1
            }
        }
        if indentedLines >= 2 {
            codeScore += 3
        }

        var symbolCount = 0
        var cjkCount = 0
        for scalar in sample.unicodeScalars {
            if "{}[];=<>#$".contains(Character(scalar)) {
                symbolCount += 1
            } else if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                cjkCount += 1
            }
        }

        if symbolCount >= 4 {
            codeScore += 2
        }

        if cjkCount > 10 && codeScore < 4 {
            return (text, .prose)
        }

        if codeScore >= 4 {
            return (text, .code)
        }

        return (text, .prose)
    }

    private static func prettyPrintSingleLineJSON(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.utf8.count + 512)
        var indentLevel = 0
        var inString = false
        var escape = false

        func appendIndent() {
            result.append("\n")
            for _ in 0..<indentLevel {
                result.append("  ")
            }
        }

        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if escape {
                result.append(ch)
                escape = false
                i = input.index(after: i)
                continue
            }
            if ch == "\\" && inString {
                result.append(ch)
                escape = true
                i = input.index(after: i)
                continue
            }
            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                i = input.index(after: i)
                continue
            }
            if inString {
                result.append(ch)
                i = input.index(after: i)
                continue
            }

            let nextIndex = input.index(after: i)
            if ch == "{" && nextIndex < input.endIndex && input[nextIndex] == "}" {
                result.append("{}")
                i = input.index(after: nextIndex)
                continue
            }
            if ch == "[" && nextIndex < input.endIndex && input[nextIndex] == "]" {
                result.append("[]")
                i = input.index(after: nextIndex)
                continue
            }

            switch ch {
            case "{", "[":
                result.append(ch)
                indentLevel += 1
                appendIndent()
            case "}", "]":
                indentLevel = max(0, indentLevel - 1)
                appendIndent()
                result.append(ch)
            case ",":
                result.append(ch)
                appendIndent()
            case ":":
                result.append(": ")
            case " ", "\t", "\n", "\r":
                break
            default:
                result.append(ch)
            }
            i = nextIndex
        }
        return result
    }
}

@MainActor
enum PreviewHighlighter {
    private static let jsonStringRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
    }()
    private static let jsonKeyRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"(?=\\s*:)")
    }()
    private static let jsonLiteralRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b(-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?|true|false|null)\\b")
    }()

    private static let codeCommentRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "(//.*$|/\\*[\\s\\S]*?\\*/|#.*$)", options: [.anchorsMatchLines])
    }()
    private static let codeStringRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"|'((?:[^'\\\\]|\\\\.)*)'")
    }()
    private static let codeKeywordRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "\\b(func|def|class|struct|interface|enum|import|export|return|const|let|var|val|public|private|static|fn|impl|type|async|await|try|catch|throw|if|else|for|while|switch|case|break|continue|guard|select|from|where|insert|into|update|delete|table)\\b",
            options: [.caseInsensitive]
        )
    }()
    private static let codeNumberRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    }()

    static func highlight(
        storage: NSTextStorage,
        kind: TextContentKind,
        baseTextColor: NSColor,
        isDark: Bool
    ) {
        guard kind != .prose else { return }
        let length = storage.length
        guard length > 0, length <= 60_000 else { return }

        let str = storage.string
        let fullRange = NSRange(location: 0, length: length)

        let keyColor: NSColor = isDark
            ? NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.95, alpha: 1.0)
            : NSColor(calibratedRed: 0.10, green: 0.40, blue: 0.80, alpha: 1.0)
        let stringColor: NSColor = isDark
            ? NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.60, alpha: 1.0)
            : NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.25, alpha: 1.0)
        let numberColor: NSColor = isDark
            ? NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.42, alpha: 1.0)
            : NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.05, alpha: 1.0)
        let keywordColor: NSColor = isDark
            ? NSColor(calibratedRed: 0.95, green: 0.52, blue: 0.72, alpha: 1.0)
            : NSColor(calibratedRed: 0.65, green: 0.15, blue: 0.45, alpha: 1.0)
        let commentColor: NSColor = isDark
            ? NSColor(white: 0.55, alpha: 1.0)
            : NSColor(white: 0.45, alpha: 1.0)

        storage.beginEditing()
        switch kind {
        case .json:
            jsonStringRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: stringColor, range: r) }
            }
            jsonKeyRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: keyColor, range: r) }
            }
            jsonLiteralRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: numberColor, range: r) }
            }

        case .code:
            codeNumberRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: numberColor, range: r) }
            }
            codeKeywordRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: keywordColor, range: r) }
            }
            codeStringRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: stringColor, range: r) }
            }
            codeCommentRegex?.enumerateMatches(in: str, range: fullRange) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: commentColor, range: r) }
            }

        case .prose:
            break
        }
        storage.endEditing()
    }
}

@MainActor
enum PreviewTextLayout {
    static let proseFont: NSFont = .systemFont(ofSize: 14.5, weight: .regular)
    static let codeFont: NSFont = .monospacedSystemFont(ofSize: 13.5, weight: .regular)

    static var font: NSFont { codeFont }

    static func font(for kind: TextContentKind) -> NSFont {
        switch kind {
        case .prose: return proseFont
        case .code, .json: return codeFont
        }
    }

    private static let _proseParagraphStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 5.0
        ps.paragraphSpacing = 8.0
        ps.lineHeightMultiple = 1.15
        return ps
    }()

    private static let _codeParagraphStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 4.0
        ps.paragraphSpacing = 0
        ps.lineHeightMultiple = 1.10
        return ps
    }()

    static func paragraphStyle(for kind: TextContentKind) -> NSParagraphStyle {
        switch kind {
        case .prose: return _proseParagraphStyle
        case .code, .json: return _codeParagraphStyle
        }
    }

    static func prepare(_ text: String) -> PreparedPreviewText {
        PreviewTextClassifier.prepare(text)
    }

    static func attributes(for kind: TextContentKind, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: kind),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle(for: kind)
        ]
    }

    static func attributes(textColor: NSColor) -> [NSAttributedString.Key: Any] {
        attributes(for: .code, textColor: textColor)
    }

    static func measureHeight(_ text: String, kind: TextContentKind, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let approxLineHeight: CGFloat = (kind == .prose) ? 22.0 : 19.0
        let maxLinesNeeded = Int(ceil(maxHeight / approxLineHeight)) + 2

        var lineCount = 0
        text.enumerateLines { _, stop in
            lineCount += 1
            if lineCount >= maxLinesNeeded {
                stop = true
            }
        }

        if lineCount >= maxLinesNeeded {
            return maxHeight
        }

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes(for: kind, textColor: .white)))
        _ = layoutManager.glyphRange(for: textContainer)
        return min(layoutManager.usedRect(for: textContainer).height, maxHeight)
    }

    static func measureHeight(_ text: String, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        measureHeight(text, kind: .code, width: width, maxHeight: maxHeight)
    }
}

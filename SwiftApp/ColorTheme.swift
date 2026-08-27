import SwiftUI

// MARK: - App Theme Colors

struct AppTheme {
    // MARK: Settings
    let background: Color
    let secondaryBackground: Color
    let cardBackground: Color
    let cardBorder: Color
    let divider: Color
    let tabBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let buttonBackground: Color
    let buttonBorder: Color
    let buttonText: Color
    let cardRowBackground: Color

    // MARK: Popup
    let popupBackground: Color
    let popupPrimaryText: Color
    let popupSecondaryText: Color
    let popupMutedText: Color
    let popupDimText: Color
    let popupRowHover: Color
    let popupRowDefault: Color
    let popupRowBorder: Color
    let popupSearchBackground: Color
    let popupTagBackground: Color
    let popupFilterTabInactive: Color
    let popupFilterTabBackground: Color
    let popupFilterTabBackgroundSelected: Color

    // MARK: Preview
    let previewBackground: Color
    let previewPrimaryText: Color
    let previewSecondaryText: Color

    // MARK: - Dark Theme (existing — must not change)

    static let dark = AppTheme(
        // Settings
        background: Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)),
        secondaryBackground: Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)),
        cardBackground: Color(nsColor: NSColor(calibratedRed: 0.175, green: 0.175, blue: 0.19, alpha: 1.0)),
        cardBorder: Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.26, alpha: 1.0)),
        divider: Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.26, alpha: 1.0)),
        tabBackground: Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)),
        primaryText: Color(white: 0.9),
        secondaryText: Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)),
        tertiaryText: Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)),
        buttonBackground: Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)),
        buttonBorder: Color(nsColor: NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.48, alpha: 1.0)),
        buttonText: Color(white: 0.85),
        cardRowBackground: Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)),

        // Popup
        popupBackground: Color.black.opacity(0.8),
        popupPrimaryText: Color.white.opacity(0.9),
        popupSecondaryText: Color.white.opacity(0.7),
        popupMutedText: Color.white.opacity(0.6),
        popupDimText: Color.white.opacity(0.45),
        popupRowHover: Color.white.opacity(0.08),
        popupRowDefault: .clear,
        popupRowBorder: Color(nsColor: NSColor.separatorColor).opacity(0.1),
        popupSearchBackground: Color.white.opacity(0.07),
        popupTagBackground: Color.black.opacity(0.2),
        popupFilterTabInactive: Color.white.opacity(0.45),
        popupFilterTabBackground: Color.white.opacity(0.05),
        popupFilterTabBackgroundSelected: Color(nsColor: .controlAccentColor).opacity(0.15),

        // Preview
        previewBackground: Color(nsColor: NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 0.92)),
        previewPrimaryText: Color(white: 0.83),
        previewSecondaryText: Color(white: 0.5)
    )

    // MARK: - Light Theme

    static let light = AppTheme(
        // Settings — Apple-native light window background
        background: Color(nsColor: NSColor.windowBackgroundColor),
        secondaryBackground: Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.9, alpha: 1.0)),
        cardBackground: Color(nsColor: NSColor(calibratedRed: 0.975, green: 0.975, blue: 0.98, alpha: 1.0)),
        cardBorder: Color(nsColor: NSColor(calibratedRed: 0.78, green: 0.78, blue: 0.8, alpha: 1.0)),
        divider: Color(nsColor: NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.84, alpha: 1.0)),
        tabBackground: Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.9, alpha: 1.0)),
        primaryText: Color(white: 0.15),
        secondaryText: Color(nsColor: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.53, alpha: 1.0)),
        tertiaryText: Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)),
        buttonBackground: Color(nsColor: NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)),
        buttonBorder: Color(nsColor: NSColor(calibratedRed: 0.65, green: 0.65, blue: 0.68, alpha: 1.0)),
        buttonText: Color(white: 0.15),
        cardRowBackground: Color(nsColor: NSColor.windowBackgroundColor),

        // Popup — Spotlight-like light translucent
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.94, alpha: 0.85)),
        popupPrimaryText: Color(white: 0.12),
        popupSecondaryText: Color(white: 0.4),
        popupMutedText: Color(white: 0.45),
        popupDimText: Color(white: 0.55),
        popupRowHover: Color.black.opacity(0.06),
        popupRowDefault: .clear,
        popupRowBorder: Color(nsColor: NSColor.separatorColor).opacity(0.25),
        popupSearchBackground: Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.9, alpha: 0.6)),
        popupTagBackground: Color(nsColor: NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)),
        popupFilterTabInactive: Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.6, alpha: 1.0)),
        popupFilterTabBackground: Color.black.opacity(0.04),
        popupFilterTabBackgroundSelected: Color(nsColor: .controlAccentColor).opacity(0.12),

        // Preview — light panel closer to VS Code Light+
        previewBackground: Color(nsColor: NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.88)),
        previewPrimaryText: Color(white: 0.22),
        previewSecondaryText: Color(white: 0.5)
    )
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .dark
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - View Modifier

struct ThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.appTheme, colorScheme == .dark ? .dark : .light)
    }
}

extension View {
    func withAppTheme() -> some View {
        modifier(ThemeModifier())
    }
}

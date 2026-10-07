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

    // MARK: - Dark Theme (Standard: WCAG AA Compliant, >= 4.5:1 text, >= 3:1 non-text)

    static let dark = AppTheme(
        // Settings
        background: Color.clear,
        secondaryBackground: Color.white.opacity(0.05),
        cardBackground: Color.white.opacity(0.07),
        cardBorder: Color.white.opacity(0.14),
        divider: Color.white.opacity(0.15),
        tabBackground: Color.clear,
        primaryText: Color(white: 0.94),
        secondaryText: Color(nsColor: NSColor(calibratedRed: 0.68, green: 0.68, blue: 0.70, alpha: 1.0)),
        tertiaryText: Color(nsColor: NSColor(calibratedRed: 0.60, green: 0.60, blue: 0.63, alpha: 1.0)),
        buttonBackground: Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)),
        buttonBorder: Color(nsColor: NSColor(calibratedRed: 0.48, green: 0.48, blue: 0.52, alpha: 1.0)),
        buttonText: Color(white: 0.92),
        cardRowBackground: Color.black.opacity(0.24),

        // Popup
        popupBackground: Color.black.opacity(0.82),
        popupPrimaryText: Color.white.opacity(0.94),
        popupSecondaryText: Color.white.opacity(0.76),
        popupMutedText: Color.white.opacity(0.68),
        popupDimText: Color.white.opacity(0.60),
        popupRowHover: Color.white.opacity(0.09),
        popupRowDefault: .clear,
        popupRowBorder: Color.white.opacity(0.14),
        popupSearchBackground: Color.white.opacity(0.08),
        popupTagBackground: Color.black.opacity(0.25),
        popupFilterTabInactive: Color.white.opacity(0.60),
        popupFilterTabBackground: Color.white.opacity(0.06),
        popupFilterTabBackgroundSelected: Color(nsColor: .controlAccentColor).opacity(0.20),

        // Preview
        previewBackground: Color(nsColor: NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1.0)),
        previewPrimaryText: Color(white: 0.90),
        previewSecondaryText: Color(white: 0.65)
    )

    // MARK: - Light Theme (Standard: WCAG AA Compliant, >= 4.5:1 text, >= 3:1 non-text)

    static let light = AppTheme(
        // Settings — Apple-native light window background
        background: Color.clear,
        secondaryBackground: Color.black.opacity(0.04),
        cardBackground: Color.white.opacity(0.75),
        cardBorder: Color.black.opacity(0.12),
        divider: Color.black.opacity(0.12),
        tabBackground: Color.clear,
        primaryText: Color(white: 0.10),
        secondaryText: Color(nsColor: NSColor(calibratedRed: 0.34, green: 0.34, blue: 0.36, alpha: 1.0)),
        tertiaryText: Color(nsColor: NSColor(calibratedRed: 0.38, green: 0.38, blue: 0.40, alpha: 1.0)),
        buttonBackground: Color(nsColor: NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)),
        buttonBorder: Color(nsColor: NSColor(calibratedRed: 0.65, green: 0.65, blue: 0.68, alpha: 1.0)),
        buttonText: Color(white: 0.10),
        cardRowBackground: Color.white.opacity(0.65),

        // Popup — Spotlight-like light translucent
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.94, alpha: 0.88)),
        popupPrimaryText: Color(white: 0.10),
        popupSecondaryText: Color(white: 0.33),
        popupMutedText: Color(white: 0.36),
        popupDimText: Color(white: 0.38),
        popupRowHover: Color.black.opacity(0.07),
        popupRowDefault: .clear,
        popupRowBorder: Color.black.opacity(0.14),
        popupSearchBackground: Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.9, alpha: 0.70)),
        popupTagBackground: Color(nsColor: NSColor(calibratedRed: 0.83, green: 0.83, blue: 0.85, alpha: 1.0)),
        popupFilterTabInactive: Color(nsColor: NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.38, alpha: 1.0)),
        popupFilterTabBackground: Color.black.opacity(0.05),
        popupFilterTabBackgroundSelected: Color(nsColor: .controlAccentColor).opacity(0.16),

        // Preview — clean light reading panel
        previewBackground: Color(nsColor: NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)),
        previewPrimaryText: Color(white: 0.15),
        previewSecondaryText: Color(white: 0.35)
    )

    // MARK: - Dark High Contrast Theme (WCAG AAA Compliant, >= 7:1 text, >= 3:1 non-text)

    static let darkHighContrast = AppTheme(
        // Settings
        background: Color.clear,
        secondaryBackground: Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)),
        cardBackground: Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)),
        cardBorder: Color.white.opacity(0.40),
        divider: Color.white.opacity(0.40),
        tabBackground: Color.clear,
        primaryText: Color.white,
        secondaryText: Color.white.opacity(0.90),
        tertiaryText: Color.white.opacity(0.80),
        buttonBackground: Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)),
        buttonBorder: Color.white.opacity(0.60),
        buttonText: Color.white,
        cardRowBackground: Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)),

        // Popup
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.98)),
        popupPrimaryText: Color.white,
        popupSecondaryText: Color.white.opacity(0.92),
        popupMutedText: Color.white.opacity(0.85),
        popupDimText: Color.white.opacity(0.78),
        popupRowHover: Color.white.opacity(0.16),
        popupRowDefault: .clear,
        popupRowBorder: Color.white.opacity(0.40),
        popupSearchBackground: Color.white.opacity(0.14),
        popupTagBackground: Color(nsColor: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1.0)),
        popupFilterTabInactive: Color.white.opacity(0.80),
        popupFilterTabBackground: Color.white.opacity(0.12),
        popupFilterTabBackgroundSelected: Color(nsColor: .controlAccentColor).opacity(0.35),

        // Preview
        previewBackground: Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)),
        previewPrimaryText: Color.white,
        previewSecondaryText: Color.white.opacity(0.85)
    )

    // MARK: - Light High Contrast Theme (WCAG AAA Compliant, >= 7:1 text, >= 3:1 non-text)

    static let lightHighContrast = AppTheme(
        // Settings
        background: Color.clear,
        secondaryBackground: Color(nsColor: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.95, alpha: 1.0)),
        cardBackground: Color.white,
        cardBorder: Color.black.opacity(0.40),
        divider: Color.black.opacity(0.40),
        tabBackground: Color.clear,
        primaryText: Color.black,
        secondaryText: Color(white: 0.15),
        tertiaryText: Color(white: 0.22),
        buttonBackground: Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0)),
        buttonBorder: Color.black.opacity(0.50),
        buttonText: Color.black,
        cardRowBackground: Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)),

        // Popup
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)),
        popupPrimaryText: Color.black,
        popupSecondaryText: Color(white: 0.16),
        popupMutedText: Color(white: 0.20),
        popupDimText: Color(white: 0.24),
        popupRowHover: Color.black.opacity(0.12),
        popupRowDefault: .clear,
        popupRowBorder: Color.black.opacity(0.40),
        popupSearchBackground: Color(nsColor: NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1.0)),
        popupTagBackground: Color(nsColor: NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.82, alpha: 1.0)),
        popupFilterTabInactive: Color(white: 0.20),
        popupFilterTabBackground: Color.black.opacity(0.08),
        popupFilterTabBackgroundSelected: Color(nsColor: .controlAccentColor).opacity(0.25),

        // Preview
        previewBackground: Color.white,
        previewPrimaryText: Color.black,
        previewSecondaryText: Color(white: 0.20)
    )

    // MARK: - Reduce Transparency Variant

    func withOpaqueBackgrounds(isDark: Bool) -> AppTheme {
        AppTheme(
            background: self.background,
            secondaryBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0))
                : Color(nsColor: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.95, alpha: 1.0)),
            cardBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1.0))
                : Color.white,
            cardBorder: self.cardBorder,
            divider: self.divider,
            tabBackground: self.tabBackground,
            primaryText: self.primaryText,
            secondaryText: self.secondaryText,
            tertiaryText: self.tertiaryText,
            buttonBackground: self.buttonBackground,
            buttonBorder: self.buttonBorder,
            buttonText: self.buttonText,
            cardRowBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0))
                : Color(nsColor: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)),
            popupBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0))
                : Color(nsColor: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)),
            popupPrimaryText: self.popupPrimaryText,
            popupSecondaryText: self.popupSecondaryText,
            popupMutedText: self.popupMutedText,
            popupDimText: self.popupDimText,
            popupRowHover: self.popupRowHover,
            popupRowDefault: self.popupRowDefault,
            popupRowBorder: self.popupRowBorder,
            popupSearchBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1.0))
                : Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0)),
            popupTagBackground: self.popupTagBackground,
            popupFilterTabInactive: self.popupFilterTabInactive,
            popupFilterTabBackground: self.popupFilterTabBackground,
            popupFilterTabBackgroundSelected: self.popupFilterTabBackgroundSelected,
            previewBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))
                : Color.white,
            previewPrimaryText: self.previewPrimaryText,
            previewSecondaryText: self.previewSecondaryText
        )
    }

    // MARK: - Dynamic Resolver

    static func resolve(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard,
        reduceTransparency: Bool = false
    ) -> AppTheme {
        let isDark = colorScheme == .dark
        let isIncreased = contrast == .increased
        var theme: AppTheme
        switch (isDark, isIncreased) {
        case (true, false): theme = .dark
        case (true, true):  theme = .darkHighContrast
        case (false, false): theme = .light
        case (false, true):  theme = .lightHighContrast
        }
        if reduceTransparency && !isIncreased {
            theme = theme.withOpaqueBackgrounds(isDark: isDark)
        }
        return theme
    }
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.environment(
            \.appTheme,
            AppTheme.resolve(
                colorScheme: colorScheme,
                contrast: colorSchemeContrast,
                reduceTransparency: reduceTransparency
            )
        )
    }
}

extension View {
    func withAppTheme() -> some View {
        modifier(ThemeModifier())
    }
}

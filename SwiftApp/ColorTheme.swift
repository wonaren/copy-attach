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

    // MARK: Update CTA (About tab)
    /// Fill and label for the "下载更新" call to action.
    ///
    /// Deliberately not `Color.green` (#31D158): white on the system green is
    /// 2.0:1, below even the 3:1 large-text floor, and the saturated block was
    /// the loudest thing on an otherwise quiet window. Each pair below keeps
    /// the label in the AA→AAA band while the fill itself stays ≥3:1 against
    /// that theme's window backdrop, so the button edge clears the non-text
    /// floor without needing an extra border.
    let updateActionBackground: Color
    let updateActionText: Color

    // MARK: Popup
    let popupBackground: Color
    let popupPrimaryText: Color
    let popupSecondaryText: Color
    let popupMutedText: Color
    let popupDimText: Color
    /// Accent for user-authored remarks (备注). One semantic color in every
    /// theme so "has a remark" reads the same everywhere; each value is picked
    /// for WCAG AA text contrast against that theme's popup background.
    /// Teal, deliberately: the favorite star already owns yellow, and the old
    /// warm amber read as "another star" at row scale.
    let popupRemarkAccent: Color
    let popupRowHover: Color
    let popupRowDefault: Color
    let popupRowBorder: Color
    let popupSearchBackground: Color
    let popupSearchHighlightBackground: Color
    let popupSearchHighlightText: Color
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
        // #1F7D48 sRGB: white label 5.14:1, and 3.20:1 against the measured
        // #1F1F21 window backdrop. The two ratios trade off exactly — a
        // lighter green raises the label ratio but pushes the edge under 3:1.
        updateActionBackground: Color(nsColor: NSColor(srgbRed: 0.122, green: 0.490, blue: 0.282, alpha: 1.0)),
        updateActionText: Color.white,

        // Popup
        popupBackground: Color.black.opacity(0.82),
        popupPrimaryText: Color.white.opacity(0.94),
        popupSecondaryText: Color.white.opacity(0.76),
        popupMutedText: Color.white.opacity(0.68),
        popupDimText: Color.white.opacity(0.60),
        // #0FA79A sRGB: measured 6.7:1 on the popup's actual dark backdrop and
        // 4.5:1 even in the worst case (82% black over a white desktop) — the
        // AA–AAA band for 13 pt text, not the glare of a near-white mint.
        // sRGB (not calibrated) so the rendered color is the hex used here.
        popupRemarkAccent: Color(nsColor: NSColor(srgbRed: 0.059, green: 0.655, blue: 0.604, alpha: 1.0)),
        popupRowHover: Color.white.opacity(0.09),
        popupRowDefault: .clear,
        popupRowBorder: Color.white.opacity(0.14),
        popupSearchBackground: Color.white.opacity(0.08),
        popupSearchHighlightBackground: Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.74, blue: 0.18, alpha: 0.38)),
        popupSearchHighlightText: Color.white.opacity(0.94),
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
        // #0F5C33 sRGB: white label 8.08:1 (AAA) and 7.10:1 against the light
        // window, so the light theme gets the full AAA band.
        updateActionBackground: Color(nsColor: NSColor(srgbRed: 0.059, green: 0.361, blue: 0.200, alpha: 1.0)),
        updateActionText: Color.white,

        // Popup — Spotlight-like light translucent
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.94, alpha: 0.88)),
        popupPrimaryText: Color(white: 0.10),
        popupSecondaryText: Color(white: 0.33),
        popupMutedText: Color(white: 0.36),
        popupDimText: Color(white: 0.38),
        // #005B52 sRGB on the worst-case translucent backdrop (#CFCFD3 = 88%
        // white over a black desktop) is 5.2:1, so remarks stay AA-readable
        // even over a dark window; on the usual light backdrop it is ~6.9:1.
        popupRemarkAccent: Color(nsColor: NSColor(srgbRed: 0.0, green: 0.357, blue: 0.322, alpha: 1.0)),
        popupRowHover: Color.black.opacity(0.07),
        popupRowDefault: .clear,
        popupRowBorder: Color.black.opacity(0.14),
        popupSearchBackground: Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.9, alpha: 0.70)),
        popupSearchHighlightBackground: Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.15, alpha: 0.48)),
        popupSearchHighlightText: Color(white: 0.30),
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
        // #5FD98A with black label: 11.78:1. A filled dark green cannot reach
        // AAA text on this backdrop, so the increased-contrast theme inverts
        // to a light fill instead of settling for AA.
        updateActionBackground: Color(nsColor: NSColor(srgbRed: 0.373, green: 0.851, blue: 0.541, alpha: 1.0)),
        updateActionText: Color.black,

        // Popup
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.98)),
        popupPrimaryText: Color.white,
        popupSecondaryText: Color.white.opacity(0.92),
        popupMutedText: Color.white.opacity(0.85),
        popupDimText: Color.white.opacity(0.78),
        // #7FE7DC on the near-opaque #141416 popup is 12.6:1 (AAA).
        popupRemarkAccent: Color(nsColor: NSColor(srgbRed: 0.498, green: 0.906, blue: 0.863, alpha: 1.0)),
        popupRowHover: Color.white.opacity(0.16),
        popupRowDefault: .clear,
        popupRowBorder: Color.white.opacity(0.40),
        popupSearchBackground: Color.white.opacity(0.14),
        popupSearchHighlightBackground: Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.74, blue: 0.18, alpha: 0.42)),
        popupSearchHighlightText: Color.white.opacity(0.95),
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
        // #0B4A2A with a white label: 10.36:1 (AAA) on the light backdrop.
        updateActionBackground: Color(nsColor: NSColor(srgbRed: 0.043, green: 0.290, blue: 0.165, alpha: 1.0)),
        updateActionText: Color.white,

        // Popup
        popupBackground: Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)),
        popupPrimaryText: Color.black,
        popupSecondaryText: Color(white: 0.16),
        popupMutedText: Color(white: 0.20),
        popupDimText: Color(white: 0.24),
        // #00534B on the near-opaque #F5F5F7 popup is 7.8:1 (AAA), so the
        // increased-contrast theme stays legible with the same hue family.
        popupRemarkAccent: Color(nsColor: NSColor(srgbRed: 0.0, green: 0.325, blue: 0.294, alpha: 1.0)),
        popupRowHover: Color.black.opacity(0.12),
        popupRowDefault: .clear,
        popupRowBorder: Color.black.opacity(0.40),
        popupSearchBackground: Color(nsColor: NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1.0)),
        popupSearchHighlightBackground: Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.10, alpha: 0.48)),
        popupSearchHighlightText: Color(white: 0.30),
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
            updateActionBackground: self.updateActionBackground,
            updateActionText: self.updateActionText,
            popupBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0))
                : Color(nsColor: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)),
            popupPrimaryText: self.popupPrimaryText,
            popupSecondaryText: self.popupSecondaryText,
            popupMutedText: self.popupMutedText,
            popupDimText: self.popupDimText,
            popupRemarkAccent: self.popupRemarkAccent,
            popupRowHover: self.popupRowHover,
            popupRowDefault: self.popupRowDefault,
            popupRowBorder: self.popupRowBorder,
            popupSearchBackground: isDark
                ? Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1.0))
                : Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1.0)),
            popupSearchHighlightBackground: self.popupSearchHighlightBackground,
            popupSearchHighlightText: self.popupSearchHighlightText,
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

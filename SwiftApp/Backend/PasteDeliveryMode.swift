import Foundation

/// What happens after an entry is placed on the system pasteboard.
///
/// The mode is read from UserDefaults at the moment of the paste (never cached
/// in a view), so a settings change takes effect on the very next activation.
/// Keys are zero-based and mirror the `COPYATTACH_DELIVERY_*` constants in
/// `CopyAttach-Bridging-Header.h`; `keystroke` is the default.
enum PasteDeliveryMode: Int {
    /// Write the pasteboard, dismiss the popup, then post ⌘V to the target app.
    case keystroke = 0
    /// Write the pasteboard only — the user pastes by hand. No Accessibility
    /// permission is required, and no keystroke is synthesized.
    case clipboardOnly = 1

    static let defaultsKey = "PasteDeliveryMode"

    static var current: PasteDeliveryMode {
        PasteDeliveryMode(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .keystroke
    }

    static func persist(_ mode: PasteDeliveryMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}

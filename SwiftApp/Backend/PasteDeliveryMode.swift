import Foundation

enum PasteDeliveryMode: Int {
    case keystroke = 0
    case clipboardOnly = 1

    static let defaultsKey = "PasteDeliveryMode"

    static var current: PasteDeliveryMode {
        PasteDeliveryMode(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .keystroke
    }

    static func persist(_ mode: PasteDeliveryMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}

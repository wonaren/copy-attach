import AppKit
import Carbon

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    var flags: UInt

    static var `default`: HotkeyConfig {
        // ⌥Space (Option+Space)
        HotkeyConfig(keyCode: UInt16(kVK_Space),
                     flags: NSEvent.ModifierFlags.option.rawValue)
    }

    var displayString: String {
        var parts: [String] = []
        if flags & NSEvent.ModifierFlags.control.rawValue != 0 { parts.append("⌃") }
        if flags & NSEvent.ModifierFlags.option.rawValue != 0 { parts.append("⌥") }
        if flags & NSEvent.ModifierFlags.shift.rawValue != 0 { parts.append("⇧") }
        if flags & NSEvent.ModifierFlags.command.rawValue != 0 { parts.append("⌘") }

        if let char = keyCodeToCharacter(keyCode) {
            // Named keys stay readable ("Space", "Return"); only single chars
            // get uppercased.
            parts.append(char.count == 1 ? char.uppercased() : char)
        } else {
            parts.append("?")
        }
        return parts.joined()
    }

    /// Convert NSEvent modifier flags to Carbon modifier flags
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if flags & NSEvent.ModifierFlags.command.rawValue != 0 { mods |= UInt32(cmdKey) }
        if flags & NSEvent.ModifierFlags.option.rawValue != 0 { mods |= UInt32(optionKey) }
        if flags & NSEvent.ModifierFlags.control.rawValue != 0 { mods |= UInt32(controlKey) }
        if flags & NSEvent.ModifierFlags.shift.rawValue != 0 { mods |= UInt32(shiftKey) }
        return mods
    }

    private func keyCodeToCharacter(_ code: UInt16) -> String? {
        let map: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_F): "f",
            UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_X): "x",
            UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_Q): "q",
            UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_R): "r",
            UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_6): "6",
            UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_7): "7",
            UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_0): "0",
            UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_O): "o", UInt16(kVK_ANSI_U): "u",
            UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_P): "p",
            UInt16(kVK_Return): "Return",
            UInt16(kVK_ANSI_L): "l", UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_K): "k",
            UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Comma): ",",
            UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_Period): ".",
            UInt16(kVK_Tab): "Tab", UInt16(kVK_Space): "Space",
            UInt16(kVK_ANSI_Grave): "`", UInt16(kVK_Delete): "⌫", UInt16(kVK_Escape): "Esc",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_DownArrow): "↓", UInt16(kVK_UpArrow): "↑",
        ]
        return map[code]
    }
}

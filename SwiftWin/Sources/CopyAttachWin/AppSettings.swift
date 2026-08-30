// AppSettings.swift — JSON settings persisted under %APPDATA%\CopyAttach.
//
// The Windows MVP keeps settings minimal: hotkey, history threshold, and
// debug logging. The settings UI is a later iteration; edit the JSON file or
// use the tray menu.

import Foundation

struct AppSettings: Codable {
    /// Virtual-key code of the popup hotkey (default: 'X' paired with Alt).
    var hotkeyVK: UInt32 = 0x58
    /// Hotkey modifiers (MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4).
    var hotkeyMods: UInt32 = 1
    /// History cleanup threshold (rows).
    var cleanupThreshold: Int32 = 3000
    /// Verbose Rust logging.
    var debugLogging: Bool = false

    static func url() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CopyAttach", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        let url = url()
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            fputs("CopyAttach: settings file is corrupt, using defaults: \(url.path)\n", stderr)
            return AppSettings()
        }
        return settings
    }

    func save() {
        let url = Self.url()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

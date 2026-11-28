import AudioToolbox
import QuartzCore

private func soundFeedbackCaptureTrampoline() {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            SoundFeedback.playCopyFromMonitor()
        }
    }
}

@MainActor
enum SoundFeedback {
    struct SoundChoice: Hashable, Identifiable, RawRepresentable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        var id: String { rawValue }

        var displayName: String {
            let localized: String
            switch rawValue {
            case "Basso": localized = "低音"
            case "Blow": localized = "吹风"
            case "Bottle": localized = "空鼓"
            case "Frog": localized = "蛙鸣"
            case "Funk": localized = "放克"
            case "Glass": localized = "清脆"
            case "Hero": localized = "凯旋"
            case "Morse": localized = "滴答"
            case "Ping": localized = "叮咚"
            case "Pop": localized = "气泡"
            case "Purr": localized = "低鸣"
            case "Sosumi": localized = "经典"
            case "Submarine": localized = "潜艇"
            case "Tink": localized = "轻敲"
            default: localized = rawValue
            }
            return localized == rawValue ? rawValue : "\(localized) (\(rawValue))"
        }

        static let tink = SoundChoice(rawValue: "Tink")
        static let pop = SoundChoice(rawValue: "Pop")
        static let purr = SoundChoice(rawValue: "Purr")

        static let allCases: [SoundChoice] = {
            let dir = "/System/Library/Sounds"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return names
                .filter { $0.hasSuffix(".aiff") }
                .map { $0.replacingOccurrences(of: ".aiff", with: "") }
                .sorted()
                .map { SoundChoice(rawValue: $0) }
        }()
    }

    static let copyEnabledKey = "CopySoundEnabled"
    static let pasteEnabledKey = "PasteSoundEnabled"
    static let copySoundNameKey = "CopySoundName"
    static let pasteSoundNameKey = "PasteSoundName"

    static let defaultCopySound: SoundChoice = .purr
    static let defaultPasteSound: SoundChoice = .pop

    private static var cache: [String: SystemSoundID] = [:]
    private static var suppressMonitorCopyUntil: CFTimeInterval = 0

    static var copyEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: copyEnabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: copyEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: copyEnabledKey)
            syncCaptureCallback()
        }
    }

    static var pasteEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: pasteEnabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: pasteEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: pasteEnabledKey)
            if !newValue && !copyEnabled {
                disposeCache()
            }
        }
    }

    static var copySound: SoundChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: copySoundNameKey) else {
                return defaultCopySound
            }
            let choice = SoundChoice(rawValue: raw)
            return SoundChoice.allCases.contains(choice) ? choice : defaultCopySound
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: copySoundNameKey)
        }
    }

    static var pasteSound: SoundChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: pasteSoundNameKey) else {
                return defaultPasteSound
            }
            let choice = SoundChoice(rawValue: raw)
            return SoundChoice.allCases.contains(choice) ? choice : defaultPasteSound
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: pasteSoundNameKey)
        }
    }

    static func syncCaptureCallback() {
        if copyEnabled {
            clipboard_set_capture_callback(soundFeedbackCaptureTrampoline)
        } else {
            clipboard_set_capture_callback(nil)
            if !pasteEnabled {
                disposeCache()
            }
        }
    }

    static func playCopy(fromMenuCopy: Bool = false) {
        guard copyEnabled else { return }
        if fromMenuCopy {
            suppressMonitorCopyUntil = CACurrentMediaTime() + 1.0
        }
        play(copySound, label: "copy")
    }

    static func playCopyFromMonitor() {
        guard copyEnabled else { return }
        if CACurrentMediaTime() < suppressMonitorCopyUntil {
            suppressMonitorCopyUntil = 0
            return
        }
        play(copySound, label: "copy.monitor")
    }

    static func playPaste() {
        guard pasteEnabled else { return }
        play(pasteSound, label: "paste")
    }

    static func preview(_ choice: SoundChoice) {
        play(choice, label: "preview")
    }

    private static func play(_ choice: SoundChoice, label: String) {
        let start = CFAbsoluteTimeGetCurrent()
        let soundID: SystemSoundID
        if let cached = cache[choice.rawValue] {
            soundID = cached
        } else {
            var created: SystemSoundID = 0
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(choice.rawValue).aiff")
            let status = AudioServicesCreateSystemSoundID(url as CFURL, &created)
            guard status == kAudioServicesNoError else {
                debugLog("SoundFeedback: system sound '\(choice.rawValue)' unavailable status=\(status)")
                return
            }
            cache[choice.rawValue] = created
            soundID = created
        }
        AudioServicesPlaySystemSound(soundID)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        debugLog("SoundFeedback: \(label) sound=\(choice.rawValue) elapsedMs=\(String(format: "%.2f", elapsedMs))")
    }

    private static func disposeCache() {
        for (_, soundID) in cache {
            AudioServicesDisposeSystemSoundID(soundID)
        }
        cache.removeAll()
    }
}

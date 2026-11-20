import Foundation
import CoreGraphics

/// Keyboard key codes for the configurable hotkeys.
enum KeyCode: UInt32, CaseIterable, Codable {
    case upArrow = 0x7E
    case downArrow = 0x7D
    case leftArrow = 0x7B
    case rightArrow = 0x7C
    case f1 = 0x7A
    case f2 = 0x78
    case f3 = 0x63
    case f4 = 0x76
    case f5 = 0x60
    case f6 = 0x61
    case f7 = 0x62
    case f8 = 0x64
    case f9 = 0x65
    case f10 = 0x6D
    case f11 = 0x67
    case f12 = 0x6F
    case equal = 0x18
    case minus = 0x1B

    var displayName: String {
        switch self {
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        case .equal: return "="
        case .minus: return "-"
        }
    }
}

/// Carbon modifier flags, stored as the raw `RegisterEventHotKey` mask.
struct ModifierMask: OptionSet, Codable, Hashable {
    let rawValue: UInt32

    static let control = ModifierMask(rawValue: 1 << 12)  // controlKey
    static let option = ModifierMask(rawValue: 1 << 11)   // optionKey
    static let shift = ModifierMask(rawValue: 1 << 9)     // shiftKey
    static let command = ModifierMask(rawValue: 1 << 8)   // cmdKey

    /// ⇧ — verified to register cleanly for every F1–F12 key, and macOS assigns
    /// no system shortcut to ⇧F*, so it never competes with VoiceOver (⌘F5) or zoom (⌥⌘F8).
    static let defaultSet: ModifierMask = [.shift]

    var displayName: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

/// A single configurable hotkey binding.
struct HotkeyBinding: Codable, Equatable {
    var key: KeyCode
    var modifiers: ModifierMask

    var displayName: String {
        "\(modifiers.displayName)\(key.displayName)"
    }
}

enum HotkeyAction: String, CaseIterable, Codable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case monitorVolumeUp
    case monitorVolumeDown
    case toggleMute
    case openPanel

    var title: String {
        switch self {
        case .brightnessUp: return "亮度 +"
        case .brightnessDown: return "亮度 −"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        case .monitorVolumeUp: return "显示器音量 +"
        case .monitorVolumeDown: return "显示器音量 −"
        case .toggleMute: return "静音开关"
        case .openPanel: return "打开控制面板"
        }
    }
}

/// User-editable configuration, persisted as JSON in Application Support.
struct Configuration: Codable {
    var bindings: [String: HotkeyBinding]
    /// Which volume channel the plain volume hotkeys drive.
    var volumeTarget: VolumeTarget
    var brightnessStep: Double
    var volumeStep: Double

    enum VolumeTarget: String, Codable, CaseIterable {
        case system
        case monitor

        var title: String {
            switch self {
            case .system: return "系统音量"
            case .monitor: return "显示器音量"
            }
        }
    }

    static var `default`: Configuration {
        Configuration(
            bindings: [
                HotkeyAction.brightnessUp.rawValue: HotkeyBinding(key: .f1, modifiers: .defaultSet),
                HotkeyAction.brightnessDown.rawValue: HotkeyBinding(key: .f2, modifiers: .defaultSet),
                HotkeyAction.volumeDown.rawValue: HotkeyBinding(key: .f5, modifiers: .defaultSet),
                HotkeyAction.volumeUp.rawValue: HotkeyBinding(key: .f6, modifiers: .defaultSet),
                HotkeyAction.toggleMute.rawValue: HotkeyBinding(key: .f4, modifiers: .defaultSet),
                HotkeyAction.openPanel.rawValue: HotkeyBinding(key: .f11, modifiers: .defaultSet)
            ],
            volumeTarget: .system,
            brightnessStep: 1.0 / 16.0,
            volumeStep: 1.0 / 16.0
        )
    }

    // MARK: - Persistence

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Lumen", isDirectory: true)
    }

    static var fileURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static func load() -> Configuration {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Configuration.self, from: data)
        else { return .default }
        return decoded
    }

    func save() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Configuration.supportDirectory,
                                     withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Configuration.fileURL, options: .atomic)
    }

    func binding(for action: HotkeyAction) -> HotkeyBinding? {
        bindings[action.rawValue]
    }
}

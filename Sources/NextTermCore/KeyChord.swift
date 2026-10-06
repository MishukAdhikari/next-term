import Foundation

/// A keyboard shortcut: a key and its modifiers, in the form a menu item takes (the key unshifted, Shift
/// as a flag), so it reads the same in the menu, in Settings and in the saved preferences.
public struct KeyChord: Codable, Hashable, Sendable {
    /// The key as a menu key equivalent: a lowercase letter, a digit, a symbol on its unshifted key
    /// ("]" not "}"), or a function-key character (arrows, F1…).
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.count == 1 && key.lowercased() != key ? key.lowercased() : key
        // An uppercase letter in a menu key equivalent means Shift.
        self.shift = shift || (key.count == 1 && key.lowercased() != key && key.uppercased() == key)
        self.command = command
        self.option = option
        self.control = control
    }

    /// Function keys and other named keys, by the character AppKit uses for them.
    static let named: [Character: String] = [
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
        "\u{F704}": "F1", "\u{F705}": "F2", "\u{F706}": "F3", "\u{F707}": "F4", "\u{F708}": "F5", "\u{F709}": "F6",
        "\u{F70A}": "F7", "\u{F70B}": "F8", "\u{F70C}": "F9", "\u{F70D}": "F10", "\u{F70E}": "F11", "\u{F70F}": "F12",
        "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
        "\u{8}": "⌫", "\u{7F}": "⌫", "\u{F728}": "⌦", "\r": "↩", "\t": "⇥", " ": "Space", "\u{1B}": "⎋",
    ]

    var isFunctionKey: Bool {
        guard let scalar = key.unicodeScalars.first else { return false }
        return (0xF704...0xF70F).contains(scalar.value)
    }

    /// As menus show it: "⌃⌥⇧⌘T".
    public var display: String {
        let name = key.count == 1 ? (Self.named[Character(key)] ?? key.uppercased()) : key
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + name
    }

    /// A shortcut must not swallow typing: it needs ⌘ or ⌃ (⌥ alone types characters), unless it is a
    /// function key.
    public var isUsable: Bool {
        guard !key.isEmpty, key != "\u{1B}" else { return false }
        return command || control || isFunctionKey
    }
}

/// The user's changes to the default shortcuts. `nil` for an id means "no shortcut" (removed).
public struct KeyBindings: Equatable, Sendable {
    public private(set) var overrides: [String: KeyChord?]

    public init(overrides: [String: KeyChord?] = [:]) {
        self.overrides = overrides
    }

    /// The shortcut a command has: the user's choice, else its default.
    public func chord(for id: String, default fallback: KeyChord?) -> KeyChord? {
        if let override = overrides[id] { return override }
        return fallback
    }

    /// Sets a command's shortcut. Setting it back to the default forgets the override.
    public mutating func set(_ chord: KeyChord?, for id: String, default fallback: KeyChord?) {
        overrides[id] = chord == fallback ? .none : .some(chord)
        if chord == fallback { overrides.removeValue(forKey: id) }
    }

    public mutating func reset(_ id: String) { overrides.removeValue(forKey: id) }
    public mutating func resetAll() { overrides.removeAll() }

    /// Which other command already uses `chord`, given every command's default.
    public func owner(of chord: KeyChord, defaults: [String: KeyChord?], except id: String) -> String? {
        defaults.keys.sorted().first { other in other != id && self.chord(for: other, default: defaults[other] ?? nil) == chord }
    }

    // Saved as JSON: { id: chord } with an empty object for "none".
    public func encoded() -> Data {
        let plain = overrides.mapValues { $0.map { ChordBox(chord: $0) } ?? ChordBox(chord: nil) }
        return (try? JSONEncoder().encode(plain)) ?? Data()
    }

    public static func decode(_ data: Data?) -> KeyBindings {
        guard let data, let plain = try? JSONDecoder().decode([String: ChordBox].self, from: data) else { return KeyBindings() }
        return KeyBindings(overrides: plain.mapValues { $0.chord })
    }

    struct ChordBox: Codable { var chord: KeyChord? }
}

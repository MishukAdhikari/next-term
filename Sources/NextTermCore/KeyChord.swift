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

    /// Commands that act only while the editor has the keyboard (Edit › Line), and commands that act on the
    /// terminal wherever the keyboard is (File › Split Right). The editor's command and the terminal's can have the
    /// same key: the editor's answers it while the editor has the keyboard, the other everywhere else, so ⌘D
    /// duplicates a line in the editor and splits the terminal elsewhere (`canShareKey`).
    public static let editorCommands: Set<String> = ["duplicateLine:", "deleteLine:", "moveLineUp:", "moveLineDown:", "copyPathWithLine:"]
    public static let terminalCommands: Set<String> = [
        "newRemoteTab:", "splitRight:", "splitDown:", "renameTab:", "clearBuffer:", "selectPaneLeft:", "selectPaneRight:",
        "selectPaneAbove:", "selectPaneBelow:", "selectNextPane:", "selectPreviousPane:", "toggleZoomPane:", "equalizePanes:",
    ]

    /// The parts of the window a command can be kept to: its key works only there.
    public enum Part: Int, CaseIterable, Sendable {
        case editor, sidebar, gitLists, diff, branchPopup

        /// Where Settings says it belongs, for the commands outside the menus.
        public var name: String {
            switch self {
            case .editor: return "Editor"
            case .sidebar: return "Project Sidebar"
            case .gitLists: return "Git Log and Compare lists"
            case .diff: return "Proposed Edit"
            case .branchPopup: return "Branch Popup"
            }
        }

        /// When its commands have their keys.
        public var whileActive: String {
            switch self {
            case .editor: return "while the editor has the keyboard"
            case .sidebar: return "while the project sidebar has the keyboard"
            case .gitLists: return "while a Git Log or Compare list has the keyboard"
            case .diff: return "while an agent’s proposed edit is shown"
            case .branchPopup: return "while the branch popup is open"
            }
        }

        /// No text is typed there, so ↩, ⌫ or ⌦ alone can be a key (the sidebar's Rename is ↩, as in Finder).
        public var takesPlainKeys: Bool { self == .sidebar || self == .gitLists }
    }

    /// A command outside the menus, kept to one part of the window, with its default key.
    public struct PartCommand: Equatable, Sendable {
        public let id: String
        public let title: String
        public let part: Part
        public let chord: KeyChord
    }

    /// The keys outside the menus, which Settings lists with the part they belong to.
    public static let partCommands: [PartCommand] = [
        PartCommand(id: "sidebar.open", title: "Open", part: .sidebar, chord: KeyChord(key: "\u{F701}", command: true)),
        PartCommand(id: "sidebar.rename", title: "Rename", part: .sidebar, chord: KeyChord(key: "\r")),
        PartCommand(id: "sidebar.trash", title: "Move to Trash", part: .sidebar, chord: KeyChord(key: "\u{8}", command: true)),
        PartCommand(id: "gitLists.open", title: "Open Commit or File", part: .gitLists, chord: KeyChord(key: "\r")),
        PartCommand(id: "diff.accept", title: "Accept", part: .diff, chord: KeyChord(key: "\r", command: true)),
        PartCommand(id: "branchPopup.fetch", title: "Fetch", part: .branchPopup, chord: KeyChord(key: "r", command: true)),
        PartCommand(id: "branchPopup.newBranch", title: "New Branch from Selected", part: .branchPopup,
                    chord: KeyChord(key: "\r", command: true)),
        PartCommand(id: "branchPopup.delete", title: "Delete Branch", part: .branchPopup, chord: KeyChord(key: "\u{8}", command: true)),
        PartCommand(id: "branchPopup.copyName", title: "Copy Name", part: .branchPopup, chord: KeyChord(key: "c", command: true)),
    ]

    /// Where a command acts.
    public enum Scope: Equatable, Sendable {
        /// Anywhere: its key is its own (most menu commands).
        case everywhere
        /// On the terminal, from wherever the keyboard is; a part's own command on the key wins in that part.
        case terminal
        /// Only in that part of the window.
        case part(Part)
    }

    public static func scope(of id: String) -> Scope {
        if editorCommands.contains(id) { return .part(.editor) }
        if terminalCommands.contains(id) { return .terminal }
        if let command = partCommands.first(where: { $0.id == id }) { return .part(command.part) }
        return .everywhere
    }

    /// Whether two commands can have the same key: a key can belong to one command per part of the window. Two
    /// parts' commands can share one, and so can a part's and a terminal command (⌘D: Duplicate Line in the editor,
    /// Split Right elsewhere). The branch popup's can share any key, since it has the keyboard while it is open (its
    /// ⌘C copies a branch's name, Edit › Copy is ⌘C everywhere else). A key of a command for everywhere is its own,
    /// and so is Accept's from the sidebar's.
    public static func canShareKey(_ first: String, _ second: String) -> Bool {
        let one = scope(of: first), other = scope(of: second)
        if case .part(let a) = one, case .part(let b) = other {
            // Accept answers wherever the keyboard is in the window, and the sidebar can be beside the proposed edit.
            if Set([a, b]) == [.diff, .sidebar] { return false }
            return a != b
        }
        if case .part(let a) = one { return other == .terminal || a == .branchPopup }
        if case .part(let b) = other { return one == .terminal || b == .branchPopup }
        return false
    }

    /// Whether `chord` can be `id`'s key: with ⌘ or ⌃ (or a function key), so typing is never swallowed; in a part
    /// with no text to type in (`Part.takesPlainKeys`), also ↩, ⌫ or ⌦ without them.
    public static func isUsable(_ chord: KeyChord, for id: String) -> Bool {
        if chord.isUsable { return true }
        guard case .part(let part) = scope(of: id), part.takesPlainKeys else { return false }
        return ["\r", "\u{8}", "\u{F728}"].contains(chord.key)
    }

    /// "⌘D is Duplicate Line while the editor has the keyboard, Split Right everywhere else": which of the commands
    /// `ids` on one key has it where, the parts' first.
    public static func sharingNote(_ chord: KeyChord, _ ids: [String], title: (String) -> String) -> String {
        func part(_ id: String) -> Part? {
            if case .part(let part) = scope(of: id) { return part }
            return nil
        }
        let inParts = ids.filter { part($0) != nil }.sorted { (part($0)?.rawValue ?? 0) < (part($1)?.rawValue ?? 0) }
        let phrases = inParts.map { "\(title($0)) \(part($0)?.whileActive ?? "")" }
            + ids.filter { part($0) == nil }.map { "\(title($0)) everywhere else" }
        return "\(chord.display) is " + phrases.joined(separator: ", ")
    }

    /// The other commands that already use `chord` and can't share it with `id`, given every command's default.
    public func owners(of chord: KeyChord, defaults: [String: KeyChord?], except id: String) -> [String] {
        defaults.keys.sorted().filter { other in
            other != id && !Self.canShareKey(id, other) && self.chord(for: other, default: defaults[other] ?? nil) == chord
        }
    }

    /// The first of `owners(of:)`.
    public func owner(of chord: KeyChord, defaults: [String: KeyChord?], except id: String) -> String? {
        owners(of: chord, defaults: defaults, except: id).first
    }

    /// The command that has `chord` too, in the other part (`canShareKey`).
    public func sharer(of chord: KeyChord, defaults: [String: KeyChord?], except id: String) -> String? {
        sharers(of: chord, defaults: defaults, except: id).first
    }

    /// Every other command that has `chord` too, each in another part (`canShareKey`).
    public func sharers(of chord: KeyChord, defaults: [String: KeyChord?], except id: String) -> [String] {
        defaults.keys.sorted().filter { other in
            other != id && Self.canShareKey(id, other) && self.chord(for: other, default: defaults[other] ?? nil) == chord
        }
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

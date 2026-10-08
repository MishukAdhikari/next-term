import Foundation

// "Coming from another app?": shortcut presets, and the plan an import makes before anything changes.
// Design: claudedocs/research_next-term-migration (keymap tables in §2.2, settings in §3, safety in §6).
// Importers only read other apps' files; nothing here writes anywhere but returns a plan for a preview.

/// Shortcuts laid between Next Term's defaults and the user's own changes. A preset never takes a Control
/// key without ⌘ (those belong to the shell and the agents) or a key macOS keeps for itself.
public enum KeymapPreset: String, CaseIterable, Codable, Sendable {
    case nextTerm, vsCode, jetBrains

    public var name: String {
        switch self {
        case .nextTerm: return "Next Term"
        case .vsCode: return "VS Code"
        case .jetBrains: return "JetBrains (macOS)"
        }
    }

    /// The commands whose shortcut differs from Next Term's (nil: no shortcut). Ids as menus give them.
    public var overrides: [String: KeyChord?] {
        let cmd = { (key: String) in KeyChord(key: key, command: true) }
        switch self {
        case .nextTerm:
            return [:]
        case .vsCode:
            let none: KeyChord? = nil
            return [
                "newWindow:": KeyChord(key: "n", command: true, shift: true),
                "splitRight:": cmd("\\"),          // ⌘D is Add Selection to Next Find Match there
                "duplicateLine:": none,            // so ⌘D does nothing unexpected; ⇧⌥↓ can't be a menu shortcut here (needs ⌘ or ⌃)
                "replaceInFiles:": KeyChord(key: "h", command: true, shift: true),
            ]
        case .jetBrains:
            let none: KeyChord? = nil
            return [
                "goToFile:": KeyChord(key: "o", command: true, shift: true),
                "saveDocument:": KeyChord(key: "s", command: true, option: true),
                "saveAllDocuments:": cmd("s"),      // ⌘S saves everything in JetBrains IDEs
                "replaceInFile:": cmd("r"),
                "splitRight:": cmd("\\"),          // ⌘D is Duplicate Line there, as it is in Next Term's editor
                "deleteLine:": cmd("\u{8}"),       // ⌘⌫, in the editor only (the sidebar's ⌘⌫ still trashes)
                "indentSelection:": none,          // ⌘] and ⌘[ are Forward and Back there; ⇥ and ⇧⇥ indent
                "outdentSelection:": none,
            ]
        }
    }

    /// ⌘K clears only while a terminal has the keyboard (in the editor both IDEs use ⌘K for other things).
    public var clearsOnlyInTerminal: Bool { self != .nextTerm }

    /// The shortcut a command has under this preset, before the user's own changes.
    public func chord(for id: String, default fallback: KeyChord?) -> KeyChord? {
        if let preset = overrides[id] { return preset }
        return fallback
    }
}

/// The apps an import can read.
public enum ImportSourceKind: String, CaseIterable, Codable, Sendable {
    case vsCode, vsCodeInsiders, vsCodium, cursor, devinDesktop, jetBrains, zed, iTerm2, ghostty, warp, terminalApp

    /// The preset that fits people coming from it.
    public var preset: KeymapPreset {
        switch self {
        case .vsCode, .vsCodeInsiders, .vsCodium, .cursor, .devinDesktop: return .vsCode
        case .jetBrains: return .jetBrains
        case .zed, .iTerm2, .ghostty, .warp, .terminalApp: return .nextTerm
        }
    }
}

/// An app found on this Mac (found by folders and dates only: nothing is parsed until the user picks it).
public struct DetectedApp: Equatable, Sendable {
    public let kind: ImportSourceKind
    /// "VS Code", "PhpStorm 2026.1", "Cursor".
    public let name: String
    /// The app's settings folder (VS Code's `…/Code/User`, a JetBrains `…/JetBrains/PhpStorm2026.1`).
    public let configPath: String
    public let lastUsed: Date?
    /// The keymap the app itself uses (a JetBrains keymap or Zed's base_keymap can point elsewhere).
    public var preset: KeymapPreset

    public init(kind: ImportSourceKind, name: String, configPath: String, lastUsed: Date?, preset: KeymapPreset? = nil) {
        self.kind = kind
        self.name = name
        self.configPath = configPath
        self.lastUsed = lastUsed
        self.preset = preset ?? kind.preset
    }
}

/// A Next Term setting an import can set, already clamped to Next Term's range.
public enum ImportedSetting: Equatable, Sendable {
    case fontSize(Double)          // 8–32 points, shared by editor and terminal
    case editorLineHeight(Double)  // 1.0–2.0, multiple of the font's own line height, steps of 0.05
    case softWrap(Bool)
    case optionAsMeta(Bool)
    case terminalPosition(String)  // bottom, right, left, top
    case sidebarSide(String)       // left, right
    case editorFontFamily(String)  // an installed monospaced family, by its own name
    case terminalFontFamily(String)
    case terminalPalette(TerminalPalette)

    /// The UserDefaults key the app keeps it under.
    public var key: String {
        switch self {
        case .fontSize: return "fontSize"
        case .editorLineHeight: return "editorLineHeight"
        case .softWrap: return "softWrap"
        case .optionAsMeta: return "optionAsMeta"
        case .terminalPosition: return "terminalPosition"
        case .sidebarSide: return "sidebarSide"
        case .editorFontFamily: return "editorFontFamily"
        case .terminalFontFamily: return "terminalFontFamily"
        case .terminalPalette: return "terminalPalette"
        }
    }

    /// Every key applying it writes, for the snapshot Undo restores: custom colours are also kept for
    /// Settings to offer again.
    public var keys: [String] {
        if case .terminalPalette = self { return [key, "customTerminalPalette"] }
        return [key]
    }

    public static func fontSize(clamping value: Double) -> ImportedSetting { .fontSize(min(32, max(8, value.rounded()))) }

    public static func lineHeight(clamping factor: Double) -> ImportedSetting {
        .editorLineHeight(min(2.0, max(1.0, (factor * 20).rounded() / 20)))
    }
}

/// One row of the preview's settings section.
public struct PlannedSetting: Equatable, Sendable {
    public let setting: ImportedSetting
    /// Where it came from: "editor.fontSize 13", "options/editor-font.xml FONT_SIZE".
    public let source: String
    /// Ticked in the preview unless there is a reason not to (said in `note`).
    public let ticked: Bool
    public let note: String?

    public init(_ setting: ImportedSetting, source: String, ticked: Bool = true, note: String? = nil) {
        self.setting = setting
        self.source = source
        self.ticked = ticked
        self.note = note
    }
}

/// One of the user's own shortcuts from the other app, as a row of the preview's "Your shortcuts" (§2.4).
/// Applied as the user's own change, on top of the preset.
public struct PlannedShortcut: Equatable, Sendable {
    /// The Next Term command, as `KeyboardShortcuts` names menu items ("goToFile:", "selectTabByNumber:#3").
    public let command: String
    public let title: String
    /// The shortcut it gets; nil takes its shortcut away (the user removed it in the other app).
    public let chord: KeyChord?
    /// Where it came from: "keybindings.json: cmd+t → workbench.action.quickOpen".
    public let source: String
    /// For a row that takes a shortcut away: the keys the other app removed (empty: every key it had). It
    /// changes Next Term only when Next Term uses one of them for the command.
    public let removed: [KeyChord]
    /// Ticked in the preview unless there is a reason not to (said in `note`).
    public var ticked: Bool
    /// False for a key no import takes (a Control key without ⌘): shown, but it can't be ticked.
    public var allowed: Bool
    public var note: String?

    public init(command: String, title: String, chord: KeyChord?, source: String, removed: [KeyChord] = [],
                ticked: Bool = true, allowed: Bool = true, note: String? = nil) {
        self.command = command
        self.title = title
        self.chord = chord
        self.source = source
        self.removed = removed
        self.ticked = ticked && allowed
        self.allowed = allowed
        self.note = note
    }
}

/// Something the import saw and did not bring over, with the reason (shown, and copyable for an agent).
public struct SkippedItem: Equatable, Sendable, Codable {
    public let item: String
    public let reason: String
    public init(_ item: String, _ reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// What one source would bring over. Nothing is applied until the user does.
public struct ImportPlan: Equatable, Sendable {
    public var preset: KeymapPreset
    public var settings: [PlannedSetting]
    /// The user's own shortcuts, in the order the other app lists them. Settled against Next Term's own
    /// shortcuts (`settlingShortcuts`) before the preview shows them.
    public var shortcuts: [PlannedShortcut]
    /// Folders, newest first, already checked to exist.
    public var recentProjects: [String]
    public var skipped: [SkippedItem]

    public init(preset: KeymapPreset, settings: [PlannedSetting] = [], shortcuts: [PlannedShortcut] = [],
                recentProjects: [String] = [], skipped: [SkippedItem] = []) {
        self.preset = preset
        self.settings = settings
        self.shortcuts = shortcuts
        self.recentProjects = recentProjects
        self.skipped = skipped
    }
}

/// Values that look like credentials never enter a plan (settings files sit next to tokens).
public enum SecretGuard {
    static let patterns = [
        #"sk-[A-Za-z0-9_\-]{12,}"#, #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"xox[abpr]-[A-Za-z0-9\-]{10,}"#, #"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_\-]{30,}"#, #"-----BEGIN"#,
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\."#, #"[A-Za-z0-9+/=_\-]{40,}"#,
        #"lsv2_(pt|sk)_[A-Za-z0-9_]{16,}"#, #"hf_[A-Za-z0-9]{30,}"#, #"gsk_[A-Za-z0-9]{20,}"#, #"tvly-[A-Za-z0-9_\-]{16,}"#,
        #"r8_[A-Za-z0-9]{20,}"#, #"xai-[A-Za-z0-9]{20,}"#, #"pcsk_[A-Za-z0-9_]{20,}"#,
    ]

    public static func looksSecret(_ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Keys whose values are never read into a plan, whatever they hold.
    public static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["env", "profiles", "shellargs", "proxy", "token", "secret", "password", "apikey", "api_key", "auth", "command"]
            .contains { lower.contains($0) }
    }
}

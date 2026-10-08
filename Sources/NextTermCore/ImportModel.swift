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

    /// The commands whose shortcut differs from Next Term's (nil: no shortcut). Ids as menus give them, or as
    /// `KeyBindings.partCommands` does for the keys outside the menus.
    public var overrides: [String: KeyChord?] {
        let cmd = { (key: String) in KeyChord(key: key, command: true) }
        switch self {
        case .nextTerm:
            return [:]
        case .vsCode:
            let none: KeyChord? = nil
            return [
                "newWindow:": KeyChord(key: "n", command: true, shift: true),
                "sidebar.newFolder": none,         // ⇧⌘N is New Window there, and VS Code's explorer has no key for it
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
    case terminalScrollback(Int)          // lines, Scrollback.range
    case terminalStartFolder(String)      // StartFolder as stored: project, current, home or an existing folder
    case terminalCursorShape(String)      // a CursorShape: block, bar, underline
    case terminalCursorBlink(Bool)
    case trimTrailingWhitespace(Bool)     // on save
    case insertFinalNewline(Bool)         // on save
    case hiddenFiles([String])            // FileHiding patterns, added to the user's own

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
        case .terminalScrollback: return "terminalScrollback"
        case .terminalStartFolder: return "terminalStartFolder"
        case .terminalCursorShape: return "terminalCursorShape"
        case .terminalCursorBlink: return "terminalCursorBlink"
        case .trimTrailingWhitespace: return "trimTrailingWhitespace"
        case .insertFinalNewline: return "insertFinalNewline"
        case .hiddenFiles: return "hiddenFilePatterns"
        }
    }

    /// The keys that hold a Bool (UserDefaults hands a number back for those too).
    public static let boolKeys: Set<String> = ["softWrap", "optionAsMeta", "terminalCursorBlink", "trimTrailingWhitespace", "insertFinalNewline"]

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

    public static func scrollback(clamping lines: Int) -> ImportedSetting { .terminalScrollback(Scrollback.clamped(lines)) }
}

/// Rows for the settings several importers read the same way.
enum ImportRows {
    /// Scrollback in lines, with a note when Next Term's range changes it. `unlimited`: the other app keeps it all.
    static func scrollback(_ lines: Int, unlimited: Bool = false, source: String, app: String) -> PlannedSetting {
        let setting = ImportedSetting.scrollback(clamping: unlimited ? Scrollback.range.upperBound : lines)
        let most = formatted(Scrollback.range.upperBound), least = formatted(Scrollback.range.lowerBound)
        var note: String?
        if unlimited {
            note = "\(app) keeps all of it; Next Term keeps at most \(most) lines"
        } else if lines > Scrollback.range.upperBound {
            note = "Next Term keeps at most \(most) lines"
        } else if lines < Scrollback.range.lowerBound {
            note = "Next Term keeps at least \(least) lines"
        }
        return PlannedSetting(setting, source: source, note: note)
    }

    /// Where new tabs start. The other apps have no projects, so anything but the project's folder (the folder of
    /// the tab in front, the home folder, a folder of your own) is offered unticked: ticked, it applies in a
    /// project window as well.
    static func startFolder(_ folder: StartFolder, source: String) -> PlannedSetting {
        switch folder {
        case .project:
            return PlannedSetting(.terminalStartFolder(folder.stored), source: source)
        case .current, .home, .folder:
            return PlannedSetting(.terminalStartFolder(folder.stored), source: source, ticked: false,
                                  note: "in project windows too, where new tabs otherwise open in the project's folder")
        }
    }

    /// The start folder for a path the other app names: used when it is a folder on this Mac (`~/` is the home
    /// folder), else reported by its key alone. Only a folder that is used is shown, and never one whose name
    /// looks like a credential.
    static func startFolder(_ raw: String, key: String, home: String) -> (setting: PlannedSetting?, skipped: [SkippedItem]) {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard !SecretGuard.pathLooksSecret(path) else { return (nil, [SkippedItem(key, "looked like a credential")]) }
        guard path.hasPrefix("/") else { return (nil, [SkippedItem(key, "only a full path to a folder is read")]) }
        let folder = canonicalPath(path)
        guard ImportVSCode.isDirectory(folder) else { return (nil, [SkippedItem(key, "the folder isn't on this Mac")]) }
        let homeFolder = canonicalPath(home)
        let chosen = folder == homeFolder ? StartFolder.home : .folder(folder)
        return (startFolder(chosen, source: "\(key) \(RecentProjects.abbreviate(folder, home: homeFolder))"), [])
    }

    /// The patterns from globs relative to the project's folder (VS Code's and Zed's), and the ones that need
    /// nothing because the sidebar hides them anyway.
    static func hiddenFiles(_ globs: [String], source: String) -> PlannedSetting? {
        var patterns: [String] = []
        for glob in globs where !SecretGuard.looksSecret(glob) {
            if let pattern = FileHiding.pattern(fromProjectGlob: glob), !patterns.contains(pattern) { patterns.append(pattern) }
        }
        guard !patterns.isEmpty else { return nil }
        return PlannedSetting(.hiddenFiles(patterns), source: source)
    }

    /// The editor's caret is macOS's text caret; only the terminal's cursor has a style here.
    static let editorCaret = "the editor keeps macOS's text caret; the cursor style here is the terminal's"

    /// "10,000".
    static func formatted(_ lines: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: lines)) ?? String(lines)
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

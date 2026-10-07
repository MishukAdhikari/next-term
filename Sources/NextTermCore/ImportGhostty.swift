import Foundation

// "Coming from Ghostty?": its config files (§3.4), read as text and never run. Design:
// claudedocs/research_next-term-migration (§3.4 terminals, §6 safety). Only allowlisted keys have their
// values looked at; keys that run programs or can hold secrets are named, never read. `config-file`
// includes are followed only inside Ghostty's own folders, and a `theme` only by name, from Ghostty's
// themes folders. Nothing is written.

public enum ImportGhostty {
    /// Where Ghostty reads its config, in order (later values win): the XDG folder, then Application Support.
    static func configFolders(home: String) -> [String] {
        [(home as NSString).appendingPathComponent(".config/ghostty"),
         (home as NSString).appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
    }

    /// In each folder, `config` and then `config.ghostty` (the name Ghostty 1.2 writes).
    static let fileNames = ["config", "config.ghostty"]

    static func configFiles(home: String) -> [String] {
        configFolders(home: home).flatMap { folder in fileNames.map { (folder as NSString).appendingPathComponent($0) } }
            .filter(isRegularFile)
    }

    /// Ghostty, when it has a config file. Last use is the newest file's date (detection opens nothing).
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        let files = configFiles(home: home)
        guard let last = files.last else { return [] }
        let used = files.compactMap(ImportFile.modificationDate).max()
        return [DetectedApp(kind: .ghostty, name: "Ghostty", configPath: last, lastUsed: used)]
    }

    // MARK: plan

    /// The font, its size, Option as Alt, the colours (a theme's, then the config's own) and the keybinds
    /// that have a Next Term command. `applications`: where Ghostty.app is looked for, for its bundled
    /// themes; `fonts`: the fonts this Mac has (tests pass their own of both).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system, applications: [String]? = nil) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .ghostty else { return plan }
        var skipped: [SkippedItem] = []
        let config = Config(entries(home: home, skipped: &skipped))
        let apps = applications ?? ["/Applications", (home as NSString).appendingPathComponent("Applications")]
        addFont(config, fonts: fonts, to: &plan)
        addOptionAsAlt(config, usKeyboard: usKeyboard, to: &plan)
        addColours(config, home: home, applications: apps, to: &plan)
        addKeybinds(config, usKeyboard: usKeyboard, to: &plan)
        plan.skipped += skipped + report(config)
        return plan
    }

    // MARK: reading

    struct Entry: Equatable {
        let key: String
        let value: String
    }

    /// `key = value` lines (Ghostty has no trailing comments: a `#` in a value is part of it, as in a colour).
    /// A value in double quotes loses them.
    static func parse(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return key.isEmpty ? nil : Entry(key: key, value: value)
        }
    }

    /// At most this many files, includes and all (a loop of includes stops here too).
    static let fileLimit = 16

    /// Every entry of the config files in the order Ghostty reads them: all of its own files first, then the
    /// files they include, then the files those include, each in the order listed (Ghostty loads includes
    /// once its own files are read, so a value in an include wins over one in a later file). Keys that run
    /// programs or can hold secrets are dropped here, so no value of theirs is kept.
    static func entries(home: String, skipped: inout [SkippedItem]) -> [Entry] {
        let folders = configFolders(home: home).map { canonicalPath($0) }
        // Paths as listed, not resolved: an include is relative to the folder its file was opened from, which
        // for a symlinked config (stow, chezmoi) isn't the folder the file is really in.
        var queue = configFiles(home: home)
        var seen = Set<String>()
        var result: [Entry] = []
        var redacted: [String] = []
        while !queue.isEmpty, seen.count < fileLimit {
            let listed = queue.removeFirst()
            let path = canonicalPath(listed)
            guard seen.insert(path).inserted else { continue }
            guard let text = ImportFile.text(path) else {
                skipped.append(SkippedItem((path as NSString).lastPathComponent, "couldn't be read"))
                continue
            }
            for entry in parse(text) {
                if isNeverRead(entry.key) {
                    if !redacted.contains(entry.key) { redacted.append(entry.key) }
                } else if entry.key == "config-file" {
                    if let include = include(entry.value, from: listed, home: home, folders: folders, skipped: &skipped) { queue.append(include) }
                } else {
                    result.append(entry)
                }
            }
        }
        for key in redacted where !SecretGuard.looksSecret(key) {
            skipped.append(SkippedItem(key, "never imported: runs commands or can hold secrets"))
        }
        return result
    }

    /// An included file, as Ghostty finds it: `~/` is the home folder, and any other relative path is relative
    /// to the including file's folder. It is read only when it is inside one of Ghostty's folders; `?` marks
    /// one that may be missing. The path comes back as listed, for the includes inside it.
    static func include(_ value: String, from file: String, home: String, folders: [String], skipped: inout [SkippedItem]) -> String? {
        var given = value
        let optional = given.hasPrefix("?")
        if optional { given.removeFirst() }
        guard !given.isEmpty else { return nil }
        if given.hasPrefix("~/") { given = home + String(given.dropFirst()) }
        let base = URL(fileURLWithPath: (file as NSString).deletingLastPathComponent, isDirectory: true)
        let listed = URL(fileURLWithPath: given, relativeTo: base).standardizedFileURL.path
        let path = resolvedPath(listed)
        guard folders.contains(where: { path.hasPrefix($0 + "/") }) else {
            skipped.append(SkippedItem("config-file", "only files in Ghostty's own folders are read"))
            return nil
        }
        guard isRegularFile(path) else {
            let name = (path as NSString).lastPathComponent
            if !optional { skipped.append(SkippedItem(SecretGuard.looksSecret(name) ? "config-file" : "config-file \(name)", "file not found")) }
            return nil
        }
        return listed
    }

    /// The kernel's spelling of a path whose last part may not exist: its folder resolved, then the name.
    static func resolvedPath(_ path: String) -> String {
        if FileManager.default.fileExists(atPath: path) { return canonicalPath(path) }
        let folder = canonicalPath((path as NSString).deletingLastPathComponent)
        return (folder as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// Keys that start programs, set their environment or can hold secrets.
    static let neverRead: Set<String> = ["command", "initial-command", "env"]

    static func isNeverRead(_ key: String) -> Bool { neverRead.contains(key) || SecretGuard.isSecretKey(key) }

    /// The values the import uses, with Ghostty's rules: the last value wins, `font-family` and `keybind`
    /// add to a list (an empty value, or `keybind = clear`, starts it again) and `palette` sets one colour.
    struct Config {
        var fontFamilies: [String] = []
        var fontSize: String?
        var optionAsAlt: String?
        var theme: String?
        var palette: [Int: String] = [:]
        var colours: [String: String] = [:]
        var keybinds: [String] = []
        /// Other keys, in the order first seen.
        var others: [String] = []

        static let colourKeys = ["foreground", "background", "cursor-color", "selection-background"]

        init(_ entries: [Entry]) {
            for entry in entries { add(entry) }
        }

        mutating func add(_ entry: Entry) {
            let value = entry.value
            switch entry.key {
            case "font-family": if value.isEmpty { fontFamilies = [] } else { fontFamilies.append(value) }
            case "font-size": fontSize = value
            case "macos-option-as-alt": optionAsAlt = value
            case "theme": theme = value
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0...255).contains(index) { palette[index] = parts[1] }
            case "keybind": if value == "clear" { keybinds = [] } else { keybinds.append(value) }
            default:
                if Self.colourKeys.contains(entry.key) {
                    colours[entry.key] = value
                } else if !others.contains(entry.key) {
                    others.append(entry.key)
                }
            }
        }
    }

    // MARK: settings

    static func addFont(_ config: Config, fonts: FontCatalog, to plan: inout ImportPlan) {
        if !config.fontFamilies.isEmpty {
            // A family never has a comma, so the list reads back as one.
            let list = config.fontFamilies.joined(separator: ", ")
            let row = ImportFonts.row(.terminal, list: list, source: "font-family", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
        guard let text = config.fontSize else { return }
        guard let size = Double(text), size.isFinite, size > 0 else {
            plan.skipped.append(SkippedItem("font-size", "not a font size Next Term can use"))
            return
        }
        var notes = ["sets the editor too: Next Term has one size for both"]
        if size.rounded() < 8 || size.rounded() > 32 { notes.insert("Next Term's sizes go from 8 to 32", at: 0) }
        plan.settings.append(PlannedSetting(.fontSize(clamping: size), source: "font-size \(ImportITerm2.formatted(size))",
                                            note: notes.joined(separator: "; ")))
    }

    /// `macos-option-as-alt`: true or false for both keys, or one side only (offered unticked: Next Term can't
    /// set one side yet). Unset is left alone, since Ghostty's own default depends on the keyboard layout.
    static func addOptionAsAlt(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        guard let value = config.optionAsAlt?.lowercased() else { return }
        let source = "macos-option-as-alt \(value)"
        switch value {
        case "false":
            plan.settings.append(PlannedSetting(.optionAsMeta(false), source: source))
        case "true", "left", "right":
            var notes: [String] = []
            if value != "true" { notes.append("on in Ghostty for \(value.capitalized) Option only; Next Term can't set one side yet") }
            if !usKeyboard { notes.append("your keyboard layout may need Option to type @ [ ] { }") }
            plan.settings.append(PlannedSetting(.optionAsMeta(true), source: source, ticked: notes.isEmpty,
                                                note: notes.isEmpty ? nil : notes.joined(separator: "; ")))
        default:
            plan.skipped.append(SkippedItem("macos-option-as-alt", "value not recognised"))
        }
    }

    // MARK: colours

    /// A theme's colours, then the config's own on top (Ghostty's order). The theme is read by name from the
    /// themes folders beside the config and inside Ghostty.app; a theme given as a path isn't read.
    static func addColours(_ config: Config, home: String, applications: [String], to plan: inout ImportPlan) {
        var palette: [Int: String] = [:]
        var colours: [String: String] = [:]
        var source: [String] = []
        if let value = config.theme {
            if let name = themeName(value), let file = themeFile(name, home: home, applications: applications) {
                let theme = Config(parse(ImportFile.text(file) ?? ""))
                palette = theme.palette
                colours = theme.colours
                source.append("theme \(name)")
            } else if let name = themeName(value) {
                plan.skipped.append(SkippedItem("theme \(name)", "not found in Ghostty's themes folders"))
            } else {
                plan.skipped.append(SkippedItem("theme", "only a theme given by name is read"))
            }
        }
        if !config.palette.isEmpty || !config.colours.isEmpty { source.append("your colour settings") }
        palette.merge(config.palette) { $1 }
        colours.merge(config.colours) { $1 }

        var result = TerminalPalette(name: "Ghostty colours")
        var unreadable: [String] = []
        func colour(_ key: String, _ text: String?) -> (rgb: UInt32, alpha: Double)? {
            guard let text else { return nil }
            guard let colour = TerminalPalette.hex(text) else {
                unreadable.append(key)
                return nil
            }
            return colour
        }
        for slot in 0..<16 { result.ansi[slot] = colour("palette \(slot)", palette[slot])?.rgb }
        result.foreground = colour("foreground", colours["foreground"])?.rgb
        result.background = colour("background", colours["background"])?.rgb
        result.cursor = colour("cursor-color", colours["cursor-color"])?.rgb
        if let selection = colour("selection-background", colours["selection-background"]) {
            result.selection = ImportColours.opaqueSelection(selection.rgb, alpha: selection.alpha, background: result.background)
        }
        if let row = ImportColours.row(result, source: source.joined(separator: " and ")) { plan.settings.append(row) }
        for key in unreadable {
            plan.skipped.append(SkippedItem(key, "only #rrggbb colours are read, not colour names"))
        }
        if palette.keys.contains(where: { $0 > 15 }) {
            plan.skipped.append(SkippedItem("palette colours 16–255", "Next Term sets the first 16 colours only"))
        }
    }

    /// "Catppuccin Mocha", or the dark one of "light:Rose Pine Dawn,dark:Rose Pine" (Next Term is dark). Nil
    /// for a path, or a name that can't be a theme file's.
    static func themeName(_ value: String) -> String? {
        var name = value
        if value.contains("dark:") || value.contains("light:") {
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let dark = parts.first(where: { $0.hasPrefix("dark:") }) else { return nil }
            name = String(dark.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty, name.count <= 100, !name.contains("/"), !name.hasPrefix("."), !name.contains("\0"),
              !SecretGuard.looksSecret(name) else { return nil }
        return name
    }

    /// The theme's file: the user's own themes first, then the ones Ghostty comes with.
    static func themeFile(_ name: String, home: String, applications: [String]) -> String? {
        let own = configFolders(home: home).map { ($0 as NSString).appendingPathComponent("themes") }
        let bundled = applications.map { ($0 as NSString).appendingPathComponent("Ghostty.app/Contents/Resources/ghostty/themes") }
        return (own + bundled).map { ($0 as NSString).appendingPathComponent(name) }.first(where: isRegularFile)
    }

    // MARK: keybinds

    /// Ghostty actions with a Next Term command of the same meaning.
    static let actions: [String: String] = {
        var actions = [
            "new_tab": "newTab:", "new_window": "newWindow:", "close_surface": "closeTab:", "close_tab": "closeTab:",
            "close_window": "performClose:", "new_split:right": "splitRight:", "new_split:down": "splitDown:",
            "goto_split:left": "selectPaneLeft:", "goto_split:right": "selectPaneRight:", "goto_split:up": "selectPaneAbove:",
            "goto_split:down": "selectPaneBelow:", "goto_split:next": "selectNextPane:", "goto_split:previous": "selectPreviousPane:",
            "next_tab": "showNextTab:", "previous_tab": "showPreviousTab:", "last_tab": "selectTabByNumber:#9",
            "clear_screen": "clearBuffer:", "copy_to_clipboard": "copy:", "paste_from_clipboard": "paste:", "select_all": "selectAll:",
            "increase_font_size:1": "increaseFontSize:", "decrease_font_size:1": "decreaseFontSize:", "reset_font_size": "resetFontSize:",
            "toggle_fullscreen": "toggleFullScreen:", "open_config": "showSettings:",
        ]
        for n in 1...8 { actions["goto_tab:\(n)"] = "selectTabByNumber:#\(n)" }
        return actions
    }()

    /// Ghostty's key names, as the VS Code key reader spells them.
    static let keyNames: [String: String] = [
        "arrow_up": "up", "arrow_down": "down", "arrow_left": "left", "arrow_right": "right", "page_up": "pageup",
        "page_down": "pagedown", "bracket_left": "[", "left_bracket": "[", "bracket_right": "]", "right_bracket": "]",
        "equal": "=", "minus": "-", "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";",
        "quote": "'", "apostrophe": "'", "backquote": "`", "grave_accent": "`", "return": "enter",
    ]

    /// Each keybind with a matching command becomes one of the user's shortcuts; the rest are counted. Only
    /// the action's name is ever shown: what follows it (text to send the terminal) is never looked at.
    static func addKeybinds(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        var unmatched = 0
        for bind in config.keybinds {
            // The first "=" ends the trigger: what an action sends can hold one too.
            guard let equals = bind.firstIndex(of: "="), equals != bind.startIndex else {
                unmatched += 1
                continue
            }
            let trigger = String(bind[..<equals]).trimmingCharacters(in: .whitespaces)
            let action = String(bind[bind.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard let command = actions[action] else {
                unmatched += 1
                continue
            }
            let source = "keybind \(trigger) → \(action)"
            switch key(trigger, usKeyboard: usKeyboard) {
            case .chord(let chord):
                plan.shortcuts.append(ImportShortcuts.row(command, chord, source: source))
            case .notSupported(let reason):
                plan.skipped.append(SkippedItem(SecretGuard.looksSecret(trigger) ? "a keybind" : source, reason))
            }
        }
        if unmatched > 0 {
            plan.skipped.append(SkippedItem("\(unmatched) keybind\(unmatched == 1 ? "" : "s")",
                                            "no matching Next Term command, or they send text to the terminal"))
        }
    }

    /// A Ghostty trigger ("super+shift+d", "cmd+bracket_left") read the way VS Code's keys are. Key
    /// sequences and system-wide keys aren't supported.
    static func key(_ trigger: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        var text = trigger.lowercased()
        for prefix in ["unconsumed:", "performable:", "all:"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("global:") { return .notSupported("system-wide keys aren't supported") }
        if text.contains(">") { return .notSupported(ImportShortcuts.twoStep) }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard var key = parts.popLast(), !key.isEmpty else { return .notSupported(ImportShortcuts.notRecognised) }
        let modifiers: [String: String] = ["super": "cmd", "cmd": "cmd", "command": "cmd", "ctrl": "ctrl", "control": "ctrl",
                                           "alt": "alt", "opt": "alt", "option": "alt", "shift": "shift"]
        var names: [String] = []
        for part in parts {
            guard let name = modifiers[part] else { return .notSupported(ImportShortcuts.notRecognised) }
            names.append(name)
        }
        if let named = keyNames[key] { key = named }
        if key.hasPrefix("key_"), key.count == 5 { key = "[key\(key.suffix(1))]" }
        if key.hasPrefix("digit_"), key.count == 7 { key = "[digit\(key.suffix(1))]" }
        return ImportVSCode.parseKey((names + [key]).joined(separator: "+"), usKeyboard: usKeyboard)
    }

    // MARK: the rest

    static let reasons: [String: String] = [
        "scrollback-limit": "a scrollback setting comes later",
        "cursor-style": "cursor style comes later", "cursor-style-blink": "cursor style comes later",
        "font-feature": "font features aren't supported", "font-thicken": "font rendering follows macOS",
        "background-opacity": "the terminal is opaque here", "background-blur": "the terminal is opaque here",
        "window-theme": "Next Term is dark", "working-directory": "a start folder setting comes later",
        "shell-integration": "Next Term sets up its own shell integration", "custom-shader": "shaders aren't supported",
    ]

    /// Every other key, by name: the ones with a reason of their own, then the rest in one row.
    static func report(_ config: Config) -> [SkippedItem] {
        var items: [SkippedItem] = []
        var rest: [String] = []
        for key in config.others where !SecretGuard.looksSecret(key) {
            if let reason = reasons[key] { items.append(SkippedItem(key, reason)) } else { rest.append(key) }
        }
        if !rest.isEmpty {
            let shown = rest.prefix(12).joined(separator: ", ") + (rest.count > 12 ? " and \(rest.count - 12) more" : "")
            items.append(SkippedItem("other settings: " + shown, "no matching Next Term setting yet"))
        }
        return items
    }
}

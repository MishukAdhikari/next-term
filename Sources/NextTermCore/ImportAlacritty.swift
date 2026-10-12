import Foundation

// "Coming from Alacritty?": its TOML config (read with TOMLReader, never run), and the files it imports from its
// own folder. Both spellings are read: 0.14's `[general]` table (`general.import`, `general.working_directory`)
// and the top-level keys before it. The shell, `env`, hints and every binding's `command` run programs or can
// hold secrets, so they are dropped as soon as a file is parsed and only named. Nothing is written.

public enum ImportAlacritty {
    /// The folder imports are read from: `~/.config/alacritty`.
    static func folder(home: String) -> String { (home as NSString).appendingPathComponent(".config/alacritty") }

    /// Where Alacritty looks for its config, in order (the first that exists is used).
    static func configFiles(home: String) -> [String] {
        [(home as NSString).appendingPathComponent(".config/alacritty/alacritty.toml"),
         (home as NSString).appendingPathComponent(".config/alacritty.toml"),
         (home as NSString).appendingPathComponent(".alacritty.toml")]
    }

    /// The YAML configs before 0.13, which aren't read: Alacritty's own `alacritty migrate` turns one into TOML.
    static func yamlFiles(home: String) -> [String] {
        [(home as NSString).appendingPathComponent(".config/alacritty/alacritty.yml"),
         (home as NSString).appendingPathComponent(".config/alacritty.yml"),
         (home as NSString).appendingPathComponent(".alacritty.yml")]
    }

    static let bundles = ["Alacritty.app"]

    /// Alacritty, when it has a config file (or only an old YAML one). Last use is that file's date.
    public static func detect(home: String = NSHomeDirectory(), applications: [String]? = nil) -> [DetectedApp] {
        guard let file = configFiles(home: home).first(where: isRegularFile) ?? yamlFiles(home: home).first(where: isRegularFile) else {
            return []
        }
        let apps = applications ?? ImportVSCode.applicationFolders(home: home)
        let bundle = ImportAppBundles.find(bundles, applications: apps)
        return [DetectedApp(kind: .alacritty, name: "Alacritty", configPath: file, lastUsed: ImportFile.modificationDate(file),
                            appPath: bundle?.path, version: bundle?.version)]
    }

    // MARK: plan

    /// The font, its size, the cursor, the scrollback, Option as Alt, the start folder, the colours and the key
    /// bindings that have a Next Term command. `fonts`: the fonts this Mac has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .alacritty else { return plan }
        let path = app.configPath.isEmpty ? (configFiles(home: home).first(where: isRegularFile) ?? "") : app.configPath
        if path.hasSuffix(".yml") {
            plan.skipped.append(SkippedItem((path as NSString).lastPathComponent,
                                            "Alacritty reads TOML since 0.13; run alacritty migrate to convert this file, then import again"))
            return plan
        }
        guard let real = ImportFile.ownFile(path, folders: [folder(home: home)]) else {
            let reason = isRegularFile(path) ? ImportFile.linkedOut : "couldn't be read"
            plan.skipped.append(SkippedItem((path as NSString).lastPathComponent, reason + "; no settings came over"))
            return plan
        }
        var loader = Loader(home: home)
        guard let config = loader.load(real, depth: 0) else {
            let reason = loader.mainError.map { "not valid TOML (line \($0.line)), so Alacritty doesn't read it either" } ?? "couldn't be read"
            plan.skipped.append(SkippedItem((path as NSString).lastPathComponent, reason + "; no settings came over"))
            return plan
        }
        let root = TOMLValue.table(config)
        addFont(root, fonts: fonts, to: &plan)
        addCursor(root, to: &plan)
        addScrolling(root, to: &plan)
        addOptionAsAlt(root, usKeyboard: usKeyboard, to: &plan)
        addStartFolder(root, home: home, to: &plan)
        addColours(root, to: &plan)
        addBindings(root, usKeyboard: usKeyboard, to: &plan)
        plan.skipped += loader.skipped
        plan.skipped += report(root, neverRead: loader.neverRead)
        return plan
    }

    // MARK: reading

    /// The config and its imports, merged as Alacritty merges them: each import before the file that imports it,
    /// tables merged key by key, arrays (key bindings) added together, any other value replaced.
    struct Loader {
        let home: String
        let folder: String
        var seen = Set<String>()
        var skipped: [SkippedItem] = []
        /// What was dropped unread, by fixed name.
        var neverRead: [String] = []
        var mainError: TOMLError?

        /// Alacritty's own limit on imports inside imports, and a limit on files.
        static let depthLimit = 5
        static let fileLimit = 16

        init(home: String) {
            self.home = home
            folder = canonicalPath(ImportAlacritty.folder(home: home))
        }

        mutating func load(_ path: String, depth: Int) -> [String: TOMLValue]? {
            let real = canonicalPath(path)
            guard seen.insert(real).inserted, seen.count <= Self.fileLimit else { return [:] }
            guard let text = ImportFile.text(real) else { return nil }
            switch TOMLReader.parse(text) {
            case .failure(let error):
                if depth == 0 { mainError = error }
                return nil
            case .success(var config):
                config = sanitized(config)
                let imports = importPaths(config, from: path, depth: depth)
                var merged: [String: TOMLValue] = [:]
                for file in imports {
                    if let imported = load(file, depth: depth + 1) {
                        merged = ImportAlacritty.merge(merged, imported)
                    } else {
                        let name = (file as NSString).lastPathComponent
                        skipped.append(SkippedItem(SecretGuard.looksSecret(name) ? "an import" : "import \(name)",
                                                   "not valid TOML, so Alacritty skips it too"))
                    }
                }
                return ImportAlacritty.merge(merged, config)
            }
        }

        /// The files `general.import` (or the older top-level `import`) names that are in Alacritty's folder:
        /// `~/` is the home folder and a relative path is beside the importing file. Others are named, not read.
        mutating func importPaths(_ config: [String: TOMLValue], from file: String, depth: Int) -> [String] {
            let list = config["general"]?.table?["import"] ?? config["import"]
            guard let list else { return [] }
            guard let items = list.array else {
                skipped.append(SkippedItem("import", "value not recognised"))
                return []
            }
            guard depth < Self.depthLimit else {
                skipped.append(SkippedItem("import", "imports go deeper than Alacritty follows"))
                return []
            }
            var paths: [String] = []
            for item in items {
                guard var given = item.string, !given.isEmpty, !given.contains("\0") else { continue }
                if given.hasPrefix("~/") { given = home + String(given.dropFirst()) }
                let base = URL(fileURLWithPath: (file as NSString).deletingLastPathComponent, isDirectory: true)
                let listed = URL(fileURLWithPath: given, relativeTo: base).standardizedFileURL.path
                let path = ImportGhostty.resolvedPath(listed)
                let name = (listed as NSString).lastPathComponent
                let shown = SecretGuard.looksSecret(name) ? "an import" : "import \(name)"
                guard path.hasPrefix(folder + "/") else {
                    skipped.append(SkippedItem(shown, "only files in Alacritty's own folder are read"))
                    continue
                }
                // A missing import is skipped by Alacritty itself, so it is passed over quietly.
                guard isRegularFile(path) else { continue }
                paths.append(path)
            }
            return paths
        }

        /// The config without what runs programs or can hold secrets: `env`, the shell, hints (they run
        /// commands), the bell's command, mouse bindings, and each key binding's `command` and `chars` (kept only
        /// as a mark that the binding had one).
        mutating func sanitized(_ config: [String: TOMLValue]) -> [String: TOMLValue] {
            var config = config
            for key in ["env", "shell", "hints", "mouse", "mouse_bindings"] where config.removeValue(forKey: key) != nil {
                note(key == "mouse_bindings" ? "mouse" : key)
            }
            if var terminal = config["terminal"]?.table, terminal.removeValue(forKey: "shell") != nil {
                config["terminal"] = .table(terminal)
                note("shell")
            }
            if var bell = config["bell"]?.table, bell.removeValue(forKey: "command") != nil {
                config["bell"] = .table(bell)
                note("bell.command")
            }
            if var keyboard = config["keyboard"]?.table, let bindings = keyboard["bindings"]?.array {
                keyboard["bindings"] = .array(bindings.map(sanitizedBinding))
                config["keyboard"] = .table(keyboard)
            }
            if let bindings = config["key_bindings"]?.array { config["key_bindings"] = .array(bindings.map(sanitizedBinding)) }
            return config
        }

        func sanitizedBinding(_ binding: TOMLValue) -> TOMLValue {
            guard var table = binding.table else { return binding }
            for key in ["command", "chars"] where table[key] != nil { table[key] = .bool(true) }
            return .table(table)
        }

        mutating func note(_ key: String) {
            if !neverRead.contains(key) { neverRead.append(key) }
        }
    }

    static func merge(_ base: [String: TOMLValue], _ replacement: [String: TOMLValue]) -> [String: TOMLValue] {
        var result = base
        for (key, value) in replacement {
            switch (result[key], value) {
            case (.table(let old)?, .table(let new)): result[key] = .table(merge(old, new))
            case (.array(let old)?, .array(let new)): result[key] = .array(old + new)
            default: result[key] = value
            }
        }
        return result
    }

    // MARK: settings

    static func addFont(_ root: TOMLValue, fonts: FontCatalog, to plan: inout ImportPlan) {
        if let family = root["font", "normal", "family"]?.string {
            let row = ImportFonts.row(.terminal, list: family, source: "font.normal.family", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
        guard let raw = root["font", "size"] else { return }
        guard let size = raw.number, size > 0 else {
            return plan.skipped.append(SkippedItem("font.size", "not a font size Next Term can use"))
        }
        plan.settings.append(ImportRows.terminalFontSize(size, source: "font.size \(ImportRows.number(size))"))
    }

    /// `cursor.style`: a table with `shape` and `blinking`, or (older) a shape alone.
    static func addCursor(_ root: TOMLValue, to plan: inout ImportPlan) {
        guard let style = root["cursor", "style"] else { return }
        let shapes: [String: CursorShape] = ["block": .block, "underline": .underline, "beam": .bar]
        let shape = style.string ?? style.table?["shape"]?.string
        if let shape {
            if let chosen = shapes[shape.lowercased()] {
                plan.settings.append(PlannedSetting(.terminalCursorShape(chosen.rawValue), source: "cursor.style.shape \(shape)"))
            } else {
                plan.skipped.append(SkippedItem("cursor.style.shape", "value not recognised"))
            }
        }
        if let blinking = style.table?["blinking"]?.string {
            switch blinking.lowercased() {
            case "never", "off": plan.settings.append(PlannedSetting(.terminalCursorBlink(false), source: "cursor.style.blinking \(blinking)"))
            case "on", "always": plan.settings.append(PlannedSetting(.terminalCursorBlink(true), source: "cursor.style.blinking \(blinking)"))
            default: plan.skipped.append(SkippedItem("cursor.style.blinking", "value not recognised"))
            }
        }
    }

    static func addScrolling(_ root: TOMLValue, to plan: inout ImportPlan) {
        guard let raw = root["scrolling", "history"] else { return }
        guard case .integer(let lines) = raw, lines >= 0, lines <= Int64(Int32.max) else {
            return plan.skipped.append(SkippedItem("scrolling.history", "value not recognised"))
        }
        plan.settings.append(ImportRows.scrollback(Int(lines), source: "scrolling.history \(lines)", app: "Alacritty"))
    }

    /// `window.option_as_alt`: None, OnlyLeft, OnlyRight or Both.
    static func addOptionAsAlt(_ root: TOMLValue, usKeyboard: Bool, to plan: inout ImportPlan) {
        guard let raw = root["window", "option_as_alt"] else { return }
        let sides: [String: (Bool, Bool)] = ["none": (false, false), "onlyleft": (true, false), "onlyright": (false, true), "both": (true, true)]
        guard let value = raw.string, let (left, right) = sides[value.lowercased()] else {
            return plan.skipped.append(SkippedItem("window.option_as_alt", "value not recognised"))
        }
        plan.settings.append(ImportRows.optionAsMeta(left: left, right: right, app: "Alacritty", source: "window.option_as_alt \(value)",
                                                     usKeyboard: usKeyboard))
    }

    /// `general.working_directory` (or the older top-level key): a folder on this Mac. "None" is the default.
    static func addStartFolder(_ root: TOMLValue, home: String, to plan: inout ImportPlan) {
        guard let raw = root["general", "working_directory"] ?? root["working_directory"] else { return }
        guard let path = raw.string else { return plan.skipped.append(SkippedItem("working_directory", "value not recognised")) }
        guard path.lowercased() != "none" else { return }
        let row = ImportRows.startFolder(path, key: "working_directory", home: home)
        plan.settings += [row.setting].compactMap { $0 }
        plan.skipped += row.skipped
    }

    /// `[colors.primary]`, `[colors.normal]`, `[colors.bright]`, the cursor's colour and the selection's. A
    /// colour that follows the cell under it (`CellForeground`) leaves Next Term's.
    static func addColours(_ root: TOMLValue, to plan: inout ImportPlan) {
        guard let colours = root["colors"]?.table else { return }
        var palette = TerminalPalette(name: "Alacritty colours")
        var unreadable: [String] = []
        func colour(_ path: [String]) -> UInt32? {
            guard let raw = TOMLValue.table(colours).value(at: path) else { return nil }
            guard let text = raw.string else {
                unreadable.append(path.joined(separator: "."))
                return nil
            }
            if text.hasPrefix("Cell") { return nil }
            guard let rgb = ImportColours.hex(text) else {
                unreadable.append(path.joined(separator: "."))
                return nil
            }
            return rgb
        }
        for (index, name) in TerminalPalette.ansiNames.enumerated() {
            palette.ansi[index] = colour(["normal", name])
            palette.ansi[index + 8] = colour(["bright", name])
        }
        palette.foreground = colour(["primary", "foreground"])
        palette.background = colour(["primary", "background"])
        palette.cursor = colour(["cursor", "cursor"])
        palette.selection = colour(["selection", "background"])
        if let row = ImportColours.row(palette, source: "[colors]") { plan.settings.append(row) }
        for path in unreadable { plan.skipped.append(SkippedItem("colors.\(path)", "only #rrggbb colours are read")) }
    }

    // MARK: key bindings

    /// Alacritty's actions with a Next Term command of the same meaning (lowercased).
    static let actions: [String: String] = {
        var actions = [
            "copy": "copy:", "paste": "paste:", "createnewwindow": "newWindow:", "createnewtab": "newTab:",
            "selectnexttab": "showNextTab:", "selectprevioustab": "showPreviousTab:", "selectlasttab": "selectTabByNumber:#9",
            "clearhistory": "clearBuffer:", "increasefontsize": "increaseFontSize:", "decreasefontsize": "decreaseFontSize:",
            "resetfontsize": "resetFontSize:", "togglefullscreen": "toggleFullScreen:", "minimize": "performMiniaturize:",
            "searchforward": "performFindPanelAction:#1",
        ]
        for n in 1...8 { actions["selecttab\(n)"] = "selectTabByNumber:#\(n)" }
        return actions
    }()

    /// Keys Alacritty spelled differently before 0.13 (`Key1`, `Equals`, `LBracket`…).
    static func key(_ raw: String) -> String {
        if raw.count == 4, raw.hasPrefix("Key"), let digit = raw.last, digit.isNumber { return String(digit) }
        return raw
    }

    /// `[[keyboard.bindings]]` (or the older `key_bindings`): the ones whose action has a Next Term command.
    /// Text a binding sends and a program it runs are never looked at; such bindings are counted or named.
    static func addBindings(_ root: TOMLValue, usKeyboard: Bool, to plan: inout ImportPlan) {
        let bindings = (root["keyboard", "bindings"]?.array ?? []) + (root["key_bindings"]?.array ?? [])
        var unmatched = 0
        var commands = 0
        for binding in bindings {
            guard let table = binding.table else {
                unmatched += 1
                continue
            }
            if table["command"] != nil {
                commands += 1
                continue
            }
            guard let action = table["action"]?.string, let command = actions[action.lowercased()] else {
                unmatched += 1
                continue
            }
            let mods = table["mods"]?.string ?? ""
            let keyText: String
            switch table["key"] {
            case .string(let text)?: keyText = text
            case .integer?: keyText = "a scan code"
            default: keyText = ""
            }
            let trigger = (mods.isEmpty ? "" : mods + "+") + keyText
            let source = ImportKeys.label("keyboard.bindings \(trigger) → \(action)")
            if let mode = table["mode"]?.string, requiresMode(mode) {
                plan.skipped.append(SkippedItem(source, "only in one of Alacritty's modes (\(ImportShortcuts.shown(mode)))"))
                continue
            }
            guard case .string(let text)? = table["key"] else {
                plan.skipped.append(SkippedItem(source, ImportShortcuts.notRecognised))
                continue
            }
            let parts = mods.split(separator: "|").map(String.init)
            switch ImportKeys.parse(modifiers: parts, key: key(text), usKeyboard: usKeyboard) {
            case .chord(let chord): plan.shortcuts.append(ImportShortcuts.row(command, chord, source: source))
            case .notSupported(let reason): plan.skipped.append(SkippedItem(source, reason))
            }
        }
        if commands > 0 {
            plan.skipped.append(SkippedItem("\(commands) key binding\(commands == 1 ? "" : "s") with a command", "never imported: runs commands"))
        }
        if unmatched > 0 {
            plan.skipped.append(SkippedItem("\(unmatched) key binding\(unmatched == 1 ? "" : "s")",
                                            "no matching Next Term command, or they send text to the terminal"))
        }
    }

    /// A mode the binding needs on (`Vi`, `Search`…), not one it needs off (`~Vi`).
    static func requiresMode(_ mode: String) -> Bool {
        mode.split(separator: "|").contains { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("~") }
    }

    // MARK: the rest

    static let reasons: [String: String] = [
        "window.opacity": "the terminal is opaque here", "window.blur": "the terminal is opaque here",
        "window.decorations": "windows keep macOS's title bar", "font.offset": "terminal line height isn't adjustable yet",
        "selection.save_to_clipboard": "copy on select isn't a setting yet",
    ]

    /// The keys read above: everything else is named in one row (or with a reason of its own).
    static let read: Set<String> = [
        "font.normal", "font.size", "cursor.style", "scrolling.history", "window.option_as_alt", "general.working_directory",
        "working_directory", "colors", "keyboard.bindings", "key_bindings", "general.import", "import",
    ]

    /// What else the config sets, by key, and what was never read.
    static func report(_ root: TOMLValue, neverRead: [String]) -> [SkippedItem] {
        var items: [SkippedItem] = []
        for key in neverRead {
            items.append(SkippedItem(key, "never imported: runs commands or can hold secrets"))
        }
        var rest: [String] = []
        for (table, value) in (root.table ?? [:]).sorted(by: { $0.key < $1.key }) {
            let inner = value.table.map { $0.keys.sorted().map { table + "." + $0 } } ?? [table]
            for key in inner where !read.contains(key) && !read.contains(table) && !SecretGuard.looksSecret(key) && !SecretGuard.isSecretKey(key) {
                if let reason = reasons[key] { items.append(SkippedItem(key, reason)) } else { rest.append(key) }
            }
        }
        if !rest.isEmpty {
            let shown = rest.prefix(12).joined(separator: ", ") + (rest.count > 12 ? " and \(rest.count - 12) more" : "")
            items.append(SkippedItem("other settings: " + shown, "no matching Next Term setting yet"))
        }
        return items
    }
}

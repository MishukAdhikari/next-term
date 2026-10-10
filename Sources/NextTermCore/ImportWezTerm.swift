import Foundation

// "Coming from WezTerm?" (and Kaku, a WezTerm fork with its own folder): wezterm.lua is a Lua program, and it is
// never run. LuaConfigScan reads the values written out in it as literals; anything worked out by Lua (a variable,
// a function, an `if`) becomes one "set by Lua code" row. Values left unset keep WezTerm's own defaults, which matter
// for one setting: on a Mac WezTerm treats the left Option key as Alt unless told otherwise. Colour schemes are read
// from the config's own `color_schemes` and from TOML files in the colors folder beside it. Nothing is written.

public enum ImportWezTerm {
    /// WezTerm's config files, in the order it looks (the first that exists is used), and Kaku's.
    static func configFiles(for kind: ImportSourceKind, home: String) -> [String] {
        switch kind {
        case .kaku:
            return [(home as NSString).appendingPathComponent(".config/kaku/kaku.lua")]
        default:
            return [(home as NSString).appendingPathComponent(".config/wezterm/wezterm.lua"),
                    (home as NSString).appendingPathComponent(".wezterm.lua")]
        }
    }

    /// The app's own folder: its colour schemes live in `colors` there.
    static func folder(for kind: ImportSourceKind, home: String) -> String {
        (home as NSString).appendingPathComponent(kind == .kaku ? ".config/kaku" : ".config/wezterm")
    }

    static func appName(_ kind: ImportSourceKind) -> String { kind == .kaku ? "Kaku" : "WezTerm" }

    /// WezTerm and Kaku, each when it has a config file. Last use is that file's date.
    public static func detect(home: String = NSHomeDirectory(), applications: [String]? = nil) -> [DetectedApp] {
        let apps = applications ?? ImportVSCode.applicationFolders(home: home)
        var found: [DetectedApp] = []
        for (kind, bundle) in [(ImportSourceKind.wezTerm, "WezTerm.app"), (.kaku, "Kaku.app")] {
            guard let file = configFiles(for: kind, home: home).first(where: isRegularFile) else { continue }
            let installed = ImportAppBundles.find([bundle], applications: apps)
            found.append(DetectedApp(kind: kind, name: appName(kind), configPath: file, lastUsed: ImportFile.modificationDate(file),
                                     appPath: installed?.path, version: installed?.version))
        }
        return found
    }

    // MARK: plan

    /// The font, its size, the cursor, the scrollback, the Option keys, the colours and the keys that have a Next
    /// Term command, as written out in the config. `fonts`: the fonts this Mac has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .wezTerm || app.kind == .kaku else { return plan }
        let name = appName(app.kind)
        let path = app.configPath.isEmpty ? (configFiles(for: app.kind, home: home).first(where: isRegularFile) ?? "") : app.configPath
        let file = (path as NSString).lastPathComponent
        guard let real = ImportFile.ownFile(path, folders: [folder(for: app.kind, home: home)]) else {
            let reason = isRegularFile(path) ? ImportFile.linkedOut : "couldn't be read"
            plan.skipped.append(SkippedItem(file, reason + "; no settings came over"))
            return plan
        }
        guard let text = ImportFile.text(real) else {
            plan.skipped.append(SkippedItem(file, "couldn't be read; no settings came over"))
            return plan
        }
        var scan = LuaConfigScan(text)
        guard !scan.unreadable else {
            plan.skipped.append(SkippedItem(file, "couldn't be read as Lua (it is never run); no settings came over"))
            return plan
        }
        let neverRead = scan.fields.keys.filter(isNeverRead).sorted()
        for key in neverRead { scan.fields[key] = nil }
        let config = Config(scan: scan, app: name)
        addFont(config, fonts: fonts, to: &plan)
        addTerminal(config, usKeyboard: usKeyboard, to: &plan)
        addColours(config, folder: folder(for: app.kind, home: home), to: &plan)
        addKeys(config, usKeyboard: usKeyboard, to: &plan)
        plan.skipped += report(config, neverRead: neverRead, computedNames: config.computedNames.filter { !isNeverRead($0) })
        return plan
    }

    /// Fields that start programs, set their environment, connect elsewhere or can hold secrets: named, never read.
    static let neverRead: Set<String> = [
        "default_prog", "set_environment_variables", "launch_menu", "ssh_domains", "unix_domains", "tls_clients", "tls_servers",
        "wsl_domains", "exec_domains", "default_domain", "default_gui_startup_args", "serial_ports", "ssh_backend",
    ]

    static func isNeverRead(_ key: String) -> Bool {
        let field = String(key.prefix { $0 != "." })
        return neverRead.contains(field) || SecretGuard.isSecretKey(field)
    }

    /// The fields the import reads, as the file gives them.
    struct Config {
        let fields: [String: LuaValue]
        let addedKeys: [LuaValue]
        let computed: Set<String>
        let app: String

        /// Fields set by code, by name: a table with code in it counts too, but for the key list, read key by key.
        let computedNames: [String]

        init(scan: LuaConfigScan, app: String) {
            var fields = scan.fields
            var names = scan.computed
            for field in scan.partlyComputed where field != "keys" {
                fields[field] = nil
                names.append(field)
            }
            self.fields = fields
            addedKeys = scan.addedKeys
            computedNames = names
            computed = Set(names.map { String($0.prefix { $0 != "." }) })
            self.app = app
        }

        subscript(_ key: String) -> LuaValue? { fields[key] }
    }

    // MARK: settings

    /// `font = wezterm.font('Name', …)`, `wezterm.font { family = … }` or `wezterm.font_with_fallback { … }`.
    static func addFont(_ config: Config, fonts: FontCatalog, to plan: inout ImportPlan) {
        if let value = config["font"] {
            if let families = families(value), !families.isEmpty {
                let list = families.joined(separator: ", ")
                let row = ImportFonts.row(.terminal, list: list, source: "font", fonts: fonts)
                plan.settings += [row.setting].compactMap { $0 }
                plan.skipped += row.skipped
            } else {
                plan.skipped.append(SkippedItem("font", "value not recognised"))
            }
        }
        guard let value = config["font_size"] else { return }
        guard let size = value.number, size > 0 else {
            return plan.skipped.append(SkippedItem("font_size", "not a font size Next Term can use"))
        }
        plan.settings.append(ImportRows.terminalFontSize(size, source: "font_size \(ImportRows.number(size))"))
    }

    /// The families a font value names, in order.
    static func families(_ value: LuaValue) -> [String]? {
        func family(_ item: LuaValue) -> String? { item.string ?? item["family"]?.string }
        switch value {
        case .call("wezterm.font", let args):
            return args.first.flatMap(family).map { [$0] }
        case .call("wezterm.font_with_fallback", let args):
            return args.first?.items?.compactMap(family)
        default:
            return nil
        }
    }

    /// The cursor, the scrollback, where tabs start and the Option keys.
    static func addTerminal(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        if let value = config["default_cursor_style"] {
            let styles: [String: (CursorShape, Bool)] = [
                "SteadyBlock": (.block, false), "BlinkingBlock": (.block, true), "SteadyUnderline": (.underline, false),
                "BlinkingUnderline": (.underline, true), "SteadyBar": (.bar, false), "BlinkingBar": (.bar, true),
            ]
            if let style = value.string, let (shape, blinks) = styles[style] {
                plan.settings.append(PlannedSetting(.terminalCursorShape(shape.rawValue), source: "default_cursor_style \(style)"))
                plan.settings.append(PlannedSetting(.terminalCursorBlink(blinks), source: "default_cursor_style \(style)"))
            } else {
                plan.skipped.append(SkippedItem("default_cursor_style", "value not recognised"))
            }
        }
        if let value = config["scrollback_lines"] {
            if let lines = value.number, lines >= 0, lines <= Double(Int32.max) {
                plan.settings.append(ImportRows.scrollback(Int(lines), source: "scrollback_lines \(Int(lines))", app: config.app))
            } else {
                plan.skipped.append(SkippedItem("scrollback_lines", "value not recognised"))
            }
        }
        if config["default_cwd"] != nil {
            plan.skipped.append(SkippedItem("default_cwd", "\(config.app) starts only its first window there; new tabs open in the folder of the pane in front"))
        }
        addOptionKeys(config, usKeyboard: usKeyboard, to: &plan)
    }

    static let leftKey = "send_composed_key_when_left_alt_is_pressed"
    static let rightKey = "send_composed_key_when_right_alt_is_pressed"

    /// On a Mac, WezTerm's left Option is Alt (composes nothing) and its right Option composes characters, unless
    /// the config says otherwise. So with neither set, left Option counts as Meta: offered for that side only.
    static func addOptionKeys(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        guard !config.computed.contains(leftKey), !config.computed.contains(rightKey) else { return }
        let leftValue = config[leftKey], rightValue = config[rightKey]
        if leftValue != nil && leftValue?.bool == nil || rightValue != nil && rightValue?.bool == nil {
            return plan.skipped.append(SkippedItem("send_composed_key_when_…_alt_is_pressed", "value not recognised"))
        }
        let left = !(leftValue?.bool ?? false)
        let right = !(rightValue?.bool ?? true)
        var parts: [String] = []
        parts.append(leftValue.map { _ in "\(leftKey) \(!left)" } ?? "left Option as Alt (\(config.app)'s default)")
        if let rightValue { parts.append("\(rightKey) \(rightValue.bool ?? true)") }
        plan.settings.append(ImportRows.optionAsMeta(left: left, right: right, app: config.app, source: parts.joined(separator: ", "),
                                                     usKeyboard: usKeyboard))
    }

    // MARK: colours

    /// The colour scheme (from the config's own `color_schemes`, then a TOML file in the colors folder), then
    /// `colors` over it, as WezTerm lays them. Built-in schemes are inside the app, so they can't be read yet.
    static func addColours(_ config: Config, folder: String, to plan: inout ImportPlan) {
        var scheme: [String: LuaValue] = [:]
        var sources: [String] = []
        if let value = config["color_scheme"] {
            guard let name = value.string, name.count <= 100, !SecretGuard.looksSecret(name) else {
                plan.skipped.append(SkippedItem("color_scheme", "value not recognised"))
                return addColourTable(config["colors"]?.fields ?? [:], scheme: [:], sources: ["colors"], to: &plan)
            }
            if let own = config["color_schemes"]?[name]?.fields {
                scheme = own
                sources.append("color_scheme \(name)")
            } else if let file = schemeFile(name, folder: folder) {
                scheme = file
                sources.append("color_scheme \(name)")
            } else {
                plan.skipped.append(SkippedItem("color_scheme \(name)", "\(config.app)'s built-in schemes are inside \(config.app), so they can't be read yet"))
            }
        }
        if config["colors"] != nil { sources.append("colors") }
        addColourTable(config["colors"]?.fields ?? [:], scheme: scheme, sources: sources, to: &plan)
    }

    static func addColourTable(_ colours: [String: LuaValue], scheme: [String: LuaValue], sources: [String], to plan: inout ImportPlan) {
        var merged = scheme
        merged.merge(colours) { $1 }
        var palette = TerminalPalette(name: "WezTerm colours")
        var unreadable: [String] = []
        func colour(_ key: String, _ value: LuaValue?) -> UInt32? {
            guard let value else { return nil }
            guard let text = value.string, let rgb = ImportColours.hex(text) else {
                unreadable.append(key)
                return nil
            }
            return rgb
        }
        // `ansi` and `brights` are whole lists: the config's replace the scheme's.
        let ansi = merged["ansi"]?.items ?? [], brights = merged["brights"]?.items ?? []
        for slot in 0..<8 {
            palette.ansi[slot] = colour("ansi", slot < ansi.count ? ansi[slot] : nil)
            palette.ansi[slot + 8] = colour("brights", slot < brights.count ? brights[slot] : nil)
        }
        palette.foreground = colour("foreground", merged["foreground"])
        palette.background = colour("background", merged["background"])
        palette.cursor = colour("cursor_bg", merged["cursor_bg"])
        palette.selection = colour("selection_bg", merged["selection_bg"])
        if let row = ImportColours.row(palette, source: sources.joined(separator: " and ")) { plan.settings.append(row) }
        var named: [String] = []
        for key in unreadable where !named.contains(key) { named.append(key) }
        for key in named { plan.skipped.append(SkippedItem("colors \(key)", "only #rrggbb colours are read")) }
    }

    /// A scheme from a TOML file in the colors folder: the one whose `[metadata] name` is `name`, else the file
    /// named after it. Only files in that folder are read, never through a link out of it.
    static func schemeFile(_ name: String, folder: String) -> [String: LuaValue]? {
        let colours = (folder as NSString).appendingPathComponent("colors")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: colours)) ?? []).filter { $0.hasSuffix(".toml") }.sorted()
        var byFile: [String: LuaValue]?
        for file in names.prefix(64) {
            guard let path = ImportVSCode.file(file, inside: colours), let text = ImportFile.text(path),
                  case .success(let root) = TOMLReader.parse(text), let table = root["colors"]?.table else { continue }
            let scheme = table.mapValues(luaValue)
            if root["metadata"]?.table?["name"]?.string == name { return scheme }
            if (file as NSString).deletingPathExtension == name { byFile = scheme }
        }
        return byFile
    }

    static func luaValue(_ value: TOMLValue) -> LuaValue {
        switch value {
        case .string(let text): return .string(text)
        case .array(let items): return .table(items: items.map(luaValue), fields: [:])
        case .table(let fields): return .table(items: [], fields: fields.mapValues(luaValue))
        default: return .computed
        }
    }

    // MARK: keys

    /// WezTerm's key assignments with a Next Term command, by name and the argument that picks one.
    static func command(_ action: String, _ args: [LuaValue]) -> String? {
        let argument = args.first
        switch action {
        case "SpawnTab": return "newTab:"
        case "SpawnWindow": return "newWindow:"
        // WezTerm's names are the other way round from most: SplitHorizontal puts the panes side by side.
        case "SplitHorizontal": return "splitRight:"
        case "SplitVertical": return "splitDown:"
        case "SplitPane":
            switch argument?["direction"]?.string {
            case "Right"?: return "splitRight:"
            case "Down"?: return "splitDown:"
            default: return nil
            }
        case "CloseCurrentTab", "CloseCurrentPane": return "closeTab:"
        case "ActivateTabRelative":
            switch argument?.number {
            case .some(1): return "showNextTab:"
            case .some(-1): return "showPreviousTab:"
            default: return nil
            }
        case "ActivateTab":
            guard let index = argument?.number else { return nil }
            if index == -1 { return "selectTabByNumber:#9" }
            return (0...7).contains(index) && index == index.rounded() ? "selectTabByNumber:#\(Int(index) + 1)" : nil
        case "ActivatePaneDirection":
            let directions = ["Left": "selectPaneLeft:", "Right": "selectPaneRight:", "Up": "selectPaneAbove:",
                              "Down": "selectPaneBelow:", "Next": "selectNextPane:", "Prev": "selectPreviousPane:"]
            return argument?.string.flatMap { directions[$0] }
        case "CopyTo": return argument?.string?.hasPrefix("Clipboard") == true ? "copy:" : nil
        case "PasteFrom": return argument?.string == "Clipboard" ? "paste:" : nil
        case "ClearScrollback": return "clearBuffer:"
        case "Search": return "performFindPanelAction:#1"
        case "IncreaseFontSize": return "increaseFontSize:"
        case "DecreaseFontSize": return "decreaseFontSize:"
        case "ResetFontSize": return "resetFontSize:"
        case "ToggleFullScreen": return "toggleFullScreen:"
        case "TogglePaneZoomState": return "toggleZoomPane:"
        default: return nil
        }
    }

    /// An action's name and arguments: `act.Copy`, `act.SpawnTab 'CurrentPaneDomain'`, or the older
    /// `wezterm.action{ SpawnTab = 'CurrentPaneDomain' }`. Nil for one set by code.
    static func action(_ value: LuaValue?) -> (name: String, args: [LuaValue])? {
        let prefix = "wezterm.action."
        switch value {
        case .name(let name)? where name.hasPrefix(prefix):
            return (String(name.dropFirst(prefix.count)), [])
        case .call(let name, let args)? where name.hasPrefix(prefix):
            return (String(name.dropFirst(prefix.count)), args)
        case .call("wezterm.action", let args)?:
            guard let fields = args.first?.fields, fields.count == 1, let (name, argument) = fields.first else { return nil }
            return (name, [argument])
        default:
            return nil
        }
    }

    /// `keys = { { key = …, mods = …, action = … }, … }`, and keys added with `table.insert`. Text a key would send
    /// is never looked at, and only an action's name is shown.
    static func addKeys(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        let entries = (config["keys"]?.items ?? []) + config.addedKeys
        var unmatched = 0
        var byCode = 0
        for entry in entries {
            guard let fields = entry.fields else {
                unmatched += 1
                continue
            }
            guard let (name, args) = action(fields["action"]) else {
                if fields["action"]?.isWrittenOut == false { byCode += 1 } else { unmatched += 1 }
                continue
            }
            guard let command = command(name, args) else {
                unmatched += 1
                continue
            }
            let key = fields["key"]?.string ?? ""
            let mods = fields["mods"]?.string ?? ""
            let source = ImportKeys.label("keys \(mods.isEmpty ? "" : mods + "+")\(key) → \(name)")
            switch parseKey(key, mods: mods, usKeyboard: usKeyboard) {
            case .chord(let chord): plan.shortcuts.append(ImportShortcuts.row(command, chord, source: source))
            case .notSupported(let reason): plan.skipped.append(SkippedItem(source, reason))
            }
        }
        if byCode > 0 {
            plan.skipped.append(SkippedItem("\(byCode) key\(byCode == 1 ? "" : "s") whose action is Lua code", "Lua code is never run"))
        }
        if unmatched > 0 {
            plan.skipped.append(SkippedItem("\(unmatched) key\(unmatched == 1 ? "" : "s")", "no matching Next Term command, or they send text to the terminal"))
        }
    }

    /// A WezTerm key: `mods` joined by `|` (`LEADER` starts a two-step key), and the key as a character (an
    /// uppercase letter means Shift), a name (`LeftArrow`), `mapped:` or `phys:` (by its place, as on a U.S. layout).
    static func parseKey(_ key: String, mods: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        var modifiers: [String] = []
        for part in mods.split(whereSeparator: { $0 == "|" || $0 == " " || $0 == "+" }) {
            let name = part.lowercased()
            if name == "leader" { return .notSupported(ImportShortcuts.twoStep) }
            modifiers.append(["meta": "alt", "win": "cmd"][name] ?? name)
        }
        var text = key
        if text.hasPrefix("mapped:") { text = String(text.dropFirst(7)) }
        if text.hasPrefix("phys:") {
            guard usKeyboard else { return .notSupported("given by its place on the keyboard, which types something else on your layout") }
            text = String(text.dropFirst(5))
        } else if text.count == 1, let letter = text.first, letter.isUppercase {
            modifiers.append("shift")
        }
        return ImportKeys.parse(modifiers: modifiers, key: text, usKeyboard: usKeyboard)
    }

    // MARK: the rest

    static let reasons: [String: String] = [
        "window_background_opacity": "the terminal is opaque here", "macos_window_background_blur": "the terminal is opaque here",
        "harfbuzz_features": "font features aren't supported", "line_height": "terminal line height isn't adjustable yet",
        "key_tables": "modal keys aren't supported", "leader": "two-step keys aren't supported yet",
    ]

    static let read: Set<String> = [
        "font", "font_size", "default_cursor_style", "scrollback_lines", "default_cwd", leftKey, rightKey, "color_scheme",
        "color_schemes", "colors", "keys",
    ]

    /// What else the config sets, by name; what was never read; and what Lua code sets, in one row.
    static func report(_ config: Config, neverRead: [String], computedNames: [String]) -> [SkippedItem] {
        var items: [SkippedItem] = []
        var rest: [String] = []
        for key in config.fields.keys.sorted() where !read.contains(key) && !SecretGuard.looksSecret(key) && key.count <= 60 {
            if let reason = reasons[key] { items.append(SkippedItem(key, reason)) } else { rest.append(key) }
        }
        if !rest.isEmpty {
            let shown = rest.prefix(12).joined(separator: ", ") + (rest.count > 12 ? " and \(rest.count - 12) more" : "")
            items.append(SkippedItem("other settings: " + shown, "no matching Next Term setting yet"))
        }
        for key in neverRead where !SecretGuard.looksSecret(key) {
            items.append(SkippedItem(key, "never imported: runs commands or can hold secrets"))
        }
        let names = computedNames.filter { !SecretGuard.looksSecret($0) && $0.count <= 60 }
        if !names.isEmpty {
            let shown = names.prefix(12).joined(separator: ", ") + (names.count > 12 ? " and \(names.count - 12) more" : "")
            items.append(SkippedItem("set by Lua code: " + shown, "only values written out in the file are read; it is never run"))
        }
        return items
    }
}

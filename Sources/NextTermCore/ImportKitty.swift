import Foundation

// "Coming from kitty?": kitty.conf and the files it includes, read as `key value` lines and never run. `include`
// and `globinclude` are followed only inside kitty's own folder; `geninclude` (runs a program) and `envinclude`
// (reads the environment) never are. When kitty's dark theme file (`dark-theme.auto.conf`, from its themes
// kitten) exists, its colours win, as they do in kitty on a dark Mac. kitty's "window" is a pane here, and its
// "OS window" a window. Nothing is written.

public enum ImportKitty {
    /// Where kitty looks for kitty.conf on a Mac, in order (the first that exists is used).
    static func configFolders(home: String) -> [String] {
        [(home as NSString).appendingPathComponent(".config/kitty"),
         (home as NSString).appendingPathComponent("Library/Preferences/kitty")]
    }

    static func configFile(home: String) -> String? {
        configFolders(home: home).map { ($0 as NSString).appendingPathComponent("kitty.conf") }.first(where: isRegularFile)
    }

    static let bundles = ["kitty.app"]

    /// kitty, when it has a kitty.conf. Last use is that file's date.
    public static func detect(home: String = NSHomeDirectory(), applications: [String]? = nil) -> [DetectedApp] {
        guard let file = configFile(home: home) else { return [] }
        let apps = applications ?? ImportVSCode.applicationFolders(home: home)
        let bundle = ImportAppBundles.find(bundles, applications: apps)
        return [DetectedApp(kind: .kitty, name: "kitty", configPath: file, lastUsed: ImportFile.modificationDate(file),
                            appPath: bundle?.path, version: bundle?.version)]
    }

    // MARK: plan

    /// The font, its size, the cursor, the scrollback, Option as Alt, the colours and the `map` lines that have a
    /// Next Term command. `fonts`: the fonts this Mac has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .kitty else { return plan }
        guard let path = app.configPath.isEmpty ? configFile(home: home) : app.configPath, isRegularFile(path) else {
            plan.skipped.append(SkippedItem("kitty.conf", "couldn't be read, so no settings came over"))
            return plan
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard let real = ImportFile.ownFile(path, folders: [folder]) else {
            plan.skipped.append(SkippedItem("kitty.conf", ImportFile.linkedOut))
            return plan
        }
        var reader = Reader(folder: folder, home: home)
        reader.read(real)
        var config = Config(reader.entries)
        // The dark theme file's colours win over every other (kitty reads it on a dark Mac; Next Term is dark).
        var themeSource: String?
        if let file = ImportVSCode.file("dark-theme.auto.conf", inside: reader.folder) {
            var theme = Reader(folder: reader.folder, home: home)
            theme.read(file)
            let colours = Config(theme.entries)
            if !colours.palette.isEmpty || !colours.colours.isEmpty {
                config.palette.merge(colours.palette) { $1 }
                config.colours.merge(colours.colours) { $1 }
                themeSource = "your colour settings, dark-theme.auto.conf over them"
            }
            reader.skipped += theme.skipped
        }
        addFont(config, fonts: fonts, to: &plan)
        addTerminal(config, usKeyboard: usKeyboard, to: &plan)
        addColours(config, source: themeSource, to: &plan)
        addMaps(config, usKeyboard: usKeyboard, to: &plan)
        plan.skipped += reader.skipped + report(config, neverRead: reader.neverRead)
        return plan
    }

    // MARK: reading

    struct Entry: Equatable {
        let key: String
        let value: String
    }

    /// `key value` lines: a line whose first non-blank character is `#` is a comment, and a line starting with
    /// `\` continues the one before it.
    static func parse(_ text: String) -> [Entry] {
        var lines: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\\"), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }
        return lines.compactMap { line in
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = parts.first else { return nil }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return Entry(key: String(key), value: value)
        }
    }

    /// The files of one config, includes and all, in kitty's order: an include is read where it stands.
    struct Reader {
        /// kitty's config folder, as its real path: includes are read only inside it.
        let folder: String
        let home: String
        var entries: [Entry] = []
        var skipped: [SkippedItem] = []
        var neverRead: [String] = []
        var seen = Set<String>()

        static let fileLimit = 32
        /// No config file is near this; a bigger one isn't read.
        static let maxBytes = 4 << 20

        init(folder: String, home: String) {
            self.folder = canonicalPath(folder)
            self.home = home
        }

        /// A file inside kitty's folder (its real path), then the files it includes where they stand.
        mutating func read(_ path: String) {
            let real = canonicalPath(path)
            guard real.hasPrefix(folder + "/") else { return note(name(real), ImportFile.linkedOut) }
            guard seen.count < Self.fileLimit, seen.insert(real).inserted else { return }
            guard let text = ImportFile.text(real), text.utf8.count <= Self.maxBytes else {
                return skipped.append(SkippedItem(name(real), "couldn't be read"))
            }
            for entry in ImportKitty.parse(text) {
                switch entry.key {
                case "include":
                    include(entry.value, from: real)
                case "globinclude":
                    globInclude(entry.value, from: real)
                case "geninclude":
                    note("geninclude", "never run: it runs a program")
                case "envinclude":
                    note("envinclude", "never read: it comes from environment variables")
                default:
                    if ImportKitty.isNeverRead(entry.key) {
                        if !neverRead.contains(entry.key) { neverRead.append(entry.key) }
                    } else {
                        entries.append(entry)
                    }
                }
            }
        }

        mutating func note(_ item: String, _ reason: String) {
            if !skipped.contains(SkippedItem(item, reason)) { skipped.append(SkippedItem(item, reason)) }
        }

        func name(_ path: String) -> String {
            let name = (path as NSString).lastPathComponent
            return SecretGuard.looksSecret(name) ? "an included file" : name
        }

        /// A path as kitty takes it: `~/` is the home folder, anything else relative is beside the including file.
        /// One with an environment variable in it isn't expanded, so it isn't read.
        func resolve(_ value: String, from file: String) -> String? {
            var given = value.trimmingCharacters(in: .whitespaces)
            guard !given.isEmpty, !given.contains("$"), !given.contains("\0") else { return nil }
            if given.hasPrefix("~/") { given = home + String(given.dropFirst()) }
            let base = URL(fileURLWithPath: (file as NSString).deletingLastPathComponent, isDirectory: true)
            return URL(fileURLWithPath: given, relativeTo: base).standardizedFileURL.path
        }

        mutating func include(_ value: String, from file: String) {
            guard let listed = resolve(value, from: file) else {
                return note("include", "a path with an environment variable isn't expanded, so it isn't read")
            }
            let path = ImportGhostty.resolvedPath(listed)
            guard path.hasPrefix(folder + "/") else { return note("include", "only files in kitty's own folder are read") }
            guard isRegularFile(path) else { return note("include \(name(path))", "file not found") }
            read(path)
        }

        /// The files a glob names inside kitty's folder (`*`, `?` and `**` for any folders), in name order. The
        /// folders before the first wildcard are resolved; what follows is matched against kitty's files.
        mutating func globInclude(_ value: String, from file: String) {
            guard let listed = resolve(value, from: file) else {
                return note("globinclude", "a path with an environment variable isn't expanded, so it isn't read")
            }
            var fixed: [String] = []
            var rest: [String] = []
            for part in listed.split(separator: "/").map(String.init) {
                if rest.isEmpty, !part.contains(where: { "*?[".contains($0) }) { fixed.append(part) } else { rest.append(part) }
            }
            guard !rest.isEmpty else { return include(value, from: file) }
            let base = canonicalPath("/" + fixed.joined(separator: "/"))
            guard base == folder || base.hasPrefix(folder + "/") else {
                return note("globinclude", "only files in kitty's own folder are read")
            }
            let inside = base == folder ? "" : String(base.dropFirst(folder.count + 1)) + "/"
            guard let pattern = ImportKitty.globPattern(inside + rest.joined(separator: "/")) else {
                return note("globinclude", "pattern not recognised")
            }
            for candidate in ImportKitty.files(in: folder) where candidate.range(of: pattern, options: .regularExpression) != nil {
                read((folder as NSString).appendingPathComponent(candidate))
            }
        }
    }

    /// A glob as a regular expression over paths relative to kitty's folder.
    static func globPattern(_ glob: String) -> String? {
        guard !glob.isEmpty, glob.count <= 200 else { return nil }
        var pattern = "^"
        var characters = Array(glob)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                let slash = index + 2 < characters.count && characters[index + 2] == "/"
                pattern += slash ? "(?:[^/]+/)*" : ".*"
                index += slash ? 3 : 2
                continue
            }
            switch character {
            case "*": pattern += "[^/]*"
            case "?": pattern += "[^/]"
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        characters.removeAll()
        return pattern + "$"
    }

    /// Plain files under kitty's folder (relative paths, sorted), four folders deep at most and 256 at most;
    /// links are never followed out of it.
    static func files(in folder: String) -> [String] {
        var found: [String] = []
        var queue: [(path: String, depth: Int)] = [("", 0)]
        while !queue.isEmpty, found.count < 256 {
            let (relative, depth) = queue.removeFirst()
            let directory = relative.isEmpty ? folder : (folder as NSString).appendingPathComponent(relative)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
            for name in names.prefix(256) where !name.hasPrefix(".") {
                let child = relative.isEmpty ? name : (relative as NSString).appendingPathComponent(name)
                let full = (folder as NSString).appendingPathComponent(child)
                guard canonicalPath(full).hasPrefix(folder + "/") else { continue }
                if isRegularFile(full) {
                    found.append(child)
                } else if depth < 4, ImportVSCode.isDirectory(full) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return found.sorted()
    }

    /// Keys that start programs, set their environment, can hold secrets or name a file that runs commands.
    static let neverRead: Set<String> = [
        "shell", "env", "startup_session", "remote_control_password", "file_transfer_confirmation_bypass", "editor",
        "exe_search_path", "watcher", "action_alias", "kitten_alias", "open_url_with", "command_on_bell", "notify_on_cmd_finish",
        "launch", "listen_on",
    ]

    static func isNeverRead(_ key: String) -> Bool { neverRead.contains(key) || SecretGuard.isSecretKey(key) }

    /// The values the import uses: the last line for a key wins; `map` lines add up.
    struct Config {
        var values: [String: String] = [:]
        var palette: [Int: String] = [:]
        var colours: [String: String] = [:]
        var maps: [String] = []
        var others: [String] = []

        static let read: Set<String> = ["font_family", "font_size", "cursor_shape", "cursor_blink_interval", "scrollback_lines",
                                        "macos_option_as_alt", "kitty_mod"]
        static let colourKeys = ["foreground", "background", "cursor", "selection_background"]

        init(_ entries: [Entry]) {
            for entry in entries {
                let key = entry.key
                if Self.read.contains(key) {
                    values[key] = entry.value
                } else if key == "map" {
                    maps.append(entry.value)
                } else if key == "clear_all_shortcuts", entry.value == "yes" {
                    maps = []
                } else if Self.colourKeys.contains(key) {
                    colours[key] = entry.value
                } else if key.hasPrefix("color"), let index = Int(key.dropFirst(5)), (0...255).contains(index) {
                    palette[index] = entry.value
                } else if !others.contains(key) {
                    others.append(key)
                }
            }
        }
    }

    // MARK: settings

    /// `font_family`: a family name, or kitty's newer `family="…" style=…` form. `monospace` and `auto` are
    /// kitty's own default.
    static func addFont(_ config: Config, fonts: FontCatalog, to plan: inout ImportPlan) {
        if let value = config.values["font_family"], let family = family(value) {
            let row = ImportFonts.row(.terminal, list: family, source: "font_family", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
        guard let text = config.values["font_size"] else { return }
        guard let size = Double(text), size.isFinite, size > 0 else {
            return plan.skipped.append(SkippedItem("font_size", "not a font size Next Term can use"))
        }
        plan.settings.append(ImportRows.terminalFontSize(size, source: "font_size \(ImportRows.number(size))"))
    }

    static func family(_ value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespaces)
        if let range = name.range(of: "family=") {
            var rest = name[range.upperBound...]
            if let quote = rest.first, quote == "\"" || quote == "'" {
                rest = rest.dropFirst()
                name = String(rest.prefix { $0 != quote })
            } else {
                name = String(rest.prefix { $0 != " " && $0 != "\t" })
            }
        } else if name.contains("=") {
            return nil
        }
        guard !name.isEmpty, !["monospace", "auto"].contains(name.lowercased()) else { return nil }
        return name
    }

    static func addTerminal(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        if let shape = config.values["cursor_shape"] {
            let shapes: [String: CursorShape] = ["block": .block, "beam": .bar, "underline": .underline]
            if let chosen = shapes[shape.lowercased()] {
                plan.settings.append(PlannedSetting(.terminalCursorShape(chosen.rawValue), source: "cursor_shape \(shape)"))
            } else {
                plan.skipped.append(SkippedItem("cursor_shape", "value not recognised"))
            }
        }
        if let interval = config.values["cursor_blink_interval"] {
            // The interval, then easing functions kitty animates the blink with.
            let first = interval.split(separator: " ").first.map(String.init) ?? ""
            if let seconds = Double(first), seconds.isFinite {
                let note = seconds < 0 ? "kitty blinks at the system's rate; Next Term blinks at its own" : nil
                plan.settings.append(PlannedSetting(.terminalCursorBlink(seconds != 0), source: "cursor_blink_interval \(first)", note: note))
            } else {
                plan.skipped.append(SkippedItem("cursor_blink_interval", "value not recognised"))
            }
        }
        if let text = config.values["scrollback_lines"] {
            if let lines = Int(text) {
                let row = lines < 0 ? ImportRows.scrollback(0, unlimited: true, source: "scrollback_lines \(lines)", app: "kitty")
                    : ImportRows.scrollback(lines, source: "scrollback_lines \(lines)", app: "kitty")
                plan.settings.append(row)
            } else {
                plan.skipped.append(SkippedItem("scrollback_lines", "value not recognised"))
            }
        }
        if let value = config.values["macos_option_as_alt"] {
            let sides: [String: (Bool, Bool)] = [
                "both": (true, true), "left": (true, false), "right": (false, true),
                "yes": (true, true), "y": (true, true), "true": (true, true),
                "no": (false, false), "n": (false, false), "false": (false, false),
            ]
            if let (left, right) = sides[value.lowercased()] {
                plan.settings.append(ImportRows.optionAsMeta(left: left, right: right, app: "kitty", source: "macos_option_as_alt \(value)",
                                                             usKeyboard: usKeyboard))
            } else {
                plan.skipped.append(SkippedItem("macos_option_as_alt", "value not recognised"))
            }
        }
    }

    /// `color0`–`color15`, `foreground`, `background`, `cursor` and `selection_background` (`none` leaves Next
    /// Term's). Colours by X11 name aren't read.
    static func addColours(_ config: Config, source: String?, to plan: inout ImportPlan) {
        var palette = TerminalPalette(name: "kitty colours")
        var unreadable: [String] = []
        func colour(_ key: String, _ text: String?) -> UInt32? {
            guard let text, text.lowercased() != "none" else { return nil }
            guard let rgb = ImportColours.hex(text) else {
                unreadable.append(key)
                return nil
            }
            return rgb
        }
        for slot in 0..<16 { palette.ansi[slot] = colour("color\(slot)", config.palette[slot]) }
        palette.foreground = colour("foreground", config.colours["foreground"])
        palette.background = colour("background", config.colours["background"])
        palette.cursor = colour("cursor", config.colours["cursor"])
        palette.selection = colour("selection_background", config.colours["selection_background"])
        if let row = ImportColours.row(palette, source: source ?? "your colour settings") { plan.settings.append(row) }
        for key in unreadable { plan.skipped.append(SkippedItem(key, "only #rrggbb colours are read, not colour names")) }
        if config.palette.keys.contains(where: { $0 > 15 }) {
            plan.skipped.append(SkippedItem("color16–color255", "Next Term sets the first 16 colours only"))
        }
    }

    // MARK: keys

    /// kitty actions that take no arguments, with the Next Term command of the same meaning. With arguments they are
    /// something else: `new_tab ssh host` and `new_os_window htop` run that program (kitty's boss.py hands them to
    /// the new window), so only the bare action maps.
    static let plainActions: [String: String] = [
        "new_tab": "newTab:", "new_tab_with_cwd": "newTab:", "new_os_window": "newWindow:", "new_os_window_with_cwd": "newWindow:",
        "close_tab": "closeTab:", "close_window": "closeTab:", // kitty's window is a pane; Close Tab closes the pane in front
        "close_os_window": "performClose:", "next_tab": "showNextTab:", "previous_tab": "showPreviousTab:",
        "next_window": "selectNextPane:", "previous_window": "selectPreviousPane:", "copy_to_clipboard": "copy:",
        "copy_or_noop": "copy:", "paste_from_clipboard": "paste:", "toggle_fullscreen": "toggleFullScreen:",
        "edit_config_file": "showSettings:", "set_tab_title": "renameTab:", "search_scrollback": "performFindPanelAction:#1",
    ]

    /// The actions whose arguments pick the command (`goto_tab 2`, `neighboring_window left`): only these show them.
    static let pickedByArguments: Set<String> = ["goto_tab", "neighboring_window", "clear_terminal", "change_font_size", "toggle_layout"]

    /// kitty actions with a Next Term command of the same meaning, by the action and the arguments that matter.
    static func command(_ action: [String]) -> String? {
        guard let name = action.first else { return nil }
        let args = Array(action.dropFirst())
        if let plain = plainActions[name] { return args.isEmpty ? plain : nil }
        switch name {
        case "goto_tab":
            guard let n = args.first.flatMap({ Int($0) }), (1...8).contains(n) else { return nil }
            return "selectTabByNumber:#\(n)"
        case "neighboring_window":
            let sides = ["left": "selectPaneLeft:", "right": "selectPaneRight:", "up": "selectPaneAbove:", "top": "selectPaneAbove:",
                         "down": "selectPaneBelow:", "bottom": "selectPaneBelow:"]
            return args.first.flatMap { sides[$0] }
        case "clear_terminal":
            return ["reset", "clear", "to_cursor", "to_cursor_scroll", "scrollback"].contains(args.first ?? "") ? "clearBuffer:" : nil
        case "change_font_size":
            guard args.count == 2, ["all", "current"].contains(args[0]) else { return nil }
            if args[1] == "0" { return "resetFontSize:" }
            if args[1].hasPrefix("+") { return "increaseFontSize:" }
            if args[1].hasPrefix("-") { return "decreaseFontSize:" }
            return nil
        case "toggle_layout":
            return args == ["stack"] ? "toggleZoomPane:" : nil
        case "launch":
            // A split of the pane in front, side by side (vsplit) or one above the other (hsplit), running the
            // shell: one that runs a program of its own isn't the same command.
            guard let options = launchOptions(args), options["--type"].map({ $0 == "window" }) ?? true else { return nil }
            switch options["--location"] {
            case "vsplit"?: return "splitRight:"
            case "hsplit"?: return "splitDown:"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `launch`'s options, when it runs nothing of its own (nil when a program follows them).
    static func launchOptions(_ args: [String]) -> [String: String]? {
        let flags: Set<String> = ["--keep-focus", "--copy-colors", "--copy-cmdline", "--copy-env", "--hold", "--allow-remote-control",
                                  "--stdin-add-formatting", "--stdin-add-line-wrap-markers"]
        var options: [String: String] = [:]
        var index = 0
        while index < args.count {
            let word = args[index]
            guard word.hasPrefix("--") else { return nil }
            let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                options[parts[0]] = parts[1]
            } else if flags.contains(word) {
                options[word] = "yes"
            } else if index + 1 < args.count {
                options[word] = args[index + 1]
                index += 1
            }
            index += 1
        }
        return options
    }

    /// The `map` options kitty takes before the keys, with whether each one takes a value after a space.
    static let mapOptions: [String: Bool] = ["--when-focus-on": true, "--new-mode": true, "--mode": true, "--on-unknown": true,
                                             "--on-action": true, "--allow-fallback": true]

    /// `map [options] keys action [arguments]`: the last line for a key wins (an empty action, `no_op` or
    /// `discard_event` leaves the key without one). Only the action's name and the arguments that pick a
    /// command are ever shown; text an action would send is never looked at.
    static func addMaps(_ config: Config, usKeyboard: Bool, to plan: inout ImportPlan) {
        let kittyMod = (config.values["kitty_mod"] ?? "ctrl+shift").lowercased()
        var order: [String] = []
        var maps: [String: (trigger: String, action: [String], options: [String: String])] = [:]
        for line in config.maps {
            var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var options: [String: String] = [:]
            while let first = words.first, first.hasPrefix("--") {
                words.removeFirst()
                let parts = first.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    options[parts[0]] = parts[1]
                } else if mapOptions[first] == true, !words.isEmpty {
                    options[first] = words.removeFirst()
                }
            }
            guard let trigger = words.first else { continue }
            let id = trigger.lowercased()
            if maps[id] == nil { order.append(id) }
            maps[id] = (trigger, Array(words.dropFirst()), options)
        }
        var unmatched = 0
        for id in order {
            guard let (trigger, action, options) = maps[id], !action.isEmpty, !["no_op", "discard_event"].contains(action[0]) else { continue }
            guard let command = command(action) else {
                unmatched += 1
                continue
            }
            let shown = shownAction(action)
            let source = ImportKeys.label("map \(trigger) → \(shown.joined(separator: " "))")
            if options["--when-focus-on"] != nil {
                plan.skipped.append(SkippedItem(source, "only while some windows have the keyboard"))
                continue
            }
            if options["--mode"] != nil || options["--new-mode"] != nil {
                plan.skipped.append(SkippedItem(source, "only in one of kitty's keyboard modes"))
                continue
            }
            switch key(trigger, kittyMod: kittyMod, usKeyboard: usKeyboard) {
            case .chord(let chord): plan.shortcuts.append(ImportShortcuts.row(command, chord, source: source))
            case .notSupported(let reason): plan.skipped.append(SkippedItem(source, reason))
            }
        }
        if unmatched > 0 {
            plan.skipped.append(SkippedItem("\(unmatched) map line\(unmatched == 1 ? "" : "s")",
                                            "no matching Next Term command, or they send text or run programs"))
        }
    }

    /// What a mapped action is shown as: its name, and only the arguments that picked the command (a split's
    /// `--location`, `goto_tab`'s number). A program, its arguments or text the action would send is never shown.
    static func shownAction(_ action: [String]) -> [String] {
        guard let name = action.first else { return [] }
        if name == "launch" { return ["launch", "--location=" + (launchOptions(Array(action.dropFirst()))?["--location"] ?? "")] }
        guard pickedByArguments.contains(name) else { return [name] }
        let picking = name == "change_font_size" ? 2 : 1
        return [name] + Array(action.dropFirst().prefix(picking))
    }

    /// A kitty shortcut ("cmd+shift+t", "kitty_mod+enter", "ctrl+x>ctrl+y"): `kitty_mod` stands for its modifiers,
    /// and a + at the end is the + key.
    static func key(_ trigger: String, kittyMod: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        var text = trigger.lowercased()
        if text.contains(">") { return .notSupported(ImportShortcuts.twoStep) }
        if text.count > 1, text.hasSuffix("+") { text = String(text.dropLast()) + "plus" }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast(), !key.isEmpty else { return .notSupported(ImportShortcuts.notRecognised) }
        var modifiers: [String] = []
        for part in parts {
            if part == "kitty_mod" {
                modifiers += kittyMod.split(separator: "+").map(String.init)
            } else {
                modifiers.append(part)
            }
        }
        return ImportKeys.parse(modifiers: modifiers, key: key, usKeyboard: usKeyboard)
    }

    // MARK: the rest

    static let reasons: [String: String] = [
        "background_opacity": "the terminal is opaque here", "background_blur": "the terminal is opaque here",
        "font_features": "font features aren't supported", "disable_ligatures": "ligatures follow the font",
        "modify_font": "terminal line height isn't adjustable yet", "copy_on_select": "copy on select isn't a setting yet",
    ]

    /// Every other key, by name: the ones with a reason of their own, then the rest in one row; then what was
    /// never read.
    static func report(_ config: Config, neverRead: [String]) -> [SkippedItem] {
        var items: [SkippedItem] = []
        var rest: [String] = []
        for key in config.others where !SecretGuard.looksSecret(key) && key.count <= 60 {
            if let reason = reasons[key] { items.append(SkippedItem(key, reason)) } else { rest.append(key) }
        }
        if !rest.isEmpty {
            let shown = rest.prefix(12).joined(separator: ", ") + (rest.count > 12 ? " and \(rest.count - 12) more" : "")
            items.append(SkippedItem("other settings: " + shown, "no matching Next Term setting yet"))
        }
        for key in neverRead where !SecretGuard.looksSecret(key) {
            items.append(SkippedItem(key, "never imported: runs commands or can hold secrets"))
        }
        return items
    }
}

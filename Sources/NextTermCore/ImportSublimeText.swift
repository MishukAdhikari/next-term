import Foundation

// "Coming from Sublime Text?": the settings, the user's own key bindings and recent folders of Sublime Text 4 (or 3).
// Its data folder is ~/Library/Application Support/Sublime Text (Sublime Text 3's: "Sublime Text 3"), as its docs name
// them (sublimetext.com/docs/revert.html); the settings and key binding formats are those of its docs (settings.html,
// key_bindings.html) and its Default package. Only these are read:
// - Packages/User/Preferences.sublime-settings (JSON with comments and trailing commas): a value is converted only
//   for an allowlisted key, so a token under any other key is never kept;
// - Packages/User/Default.sublime-keymap and Default (OSX).sublime-keymap: each binding's keys, command and whether
//   it has a context, and for a command Next Term has, only the arguments that tell which command it is;
// - Local/Session.sublime_session: `folder_history` and `workspaces.recent_workspaces` only (the session also keeps
//   unsaved text and search history, which are never converted), and the `folders` of a recent project's
//   .sublime-project (never its .sublime-workspace, which keeps unsaved text too);
// - the names in Packages, Installed Packages and Packages/User (counted, never listed), and the app's version.
// Files that link out of the data folder are not read. Nothing is written, and no package code is run.

public enum ImportSublimeText {
    // MARK: detection

    /// The data folders in ~/Library/Application Support, newest version first, with the name each is listed under.
    static let dataFolders = [(folder: "Sublime Text", name: "Sublime Text"), (folder: "Sublime Text 3", name: "Sublime Text 3")]

    static let bundles = ["Sublime Text.app"]

    static func dataFolder(_ name: String, home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/" + name)
    }

    static func userFolder(_ data: String) -> String { (data as NSString).appendingPathComponent("Packages/User") }

    static func sessionFile(_ data: String) -> String { (data as NSString).appendingPathComponent("Local/Session.sublime_session") }

    /// Sublime Text, when one of its data folders has a Packages/User folder: the one used last if both do. Last use
    /// is the newest of the user's settings file, that folder and the session file, which it writes as it runs
    /// (dates only: nothing is opened). `applications`: where the app is looked for, /Applications and
    /// ~/Applications unless given.
    public static func detect(home: String = NSHomeDirectory(), applications: [String]? = nil) -> [DetectedApp] {
        var best: (data: String, name: String, used: Date?, isThree: Bool)?
        for (index, entry) in dataFolders.enumerated() {
            let data = dataFolder(entry.folder, home: home)
            let user = userFolder(data)
            guard ImportVSCode.isDirectory(user) else { continue }
            let files = [(user as NSString).appendingPathComponent("Preferences.sublime-settings"), user, sessionFile(data)]
            let used = files.compactMap(ImportVSCode.modified).max()
            if let current = best, (current.used ?? .distantPast) >= (used ?? .distantPast) { continue }
            best = (data, entry.name, used, index == 1)
        }
        guard let best else { return [] }
        let apps = applications ?? ImportVSCode.applicationFolders(home: home)
        let bundle = app(applications: apps, forThree: best.isThree)
        return [DetectedApp(kind: .sublimeText, name: best.name, configPath: best.data, lastUsed: best.used,
                            appPath: bundle?.path, version: bundle?.version)]
    }

    /// The app, when it is the version that keeps its data in that folder: builds before 4000 are Sublime Text 3's.
    static func app(applications: [String], forThree: Bool) -> (path: String, version: String?)? {
        guard let found = ImportAppBundles.find(bundles, applications: applications) else { return nil }
        let given = version(bundle: found.path)
        if let build = given.flatMap(buildNumber), (build < 4000) != forThree { return nil }
        return (found.path, given)
    }

    /// The version its Info.plist gives: "Build 4200" as Sublime Text writes it, or a plain version.
    static func version(bundle: String) -> String? {
        guard let file = ImportVSCode.file("Contents/Info.plist", inside: bundle), let data = ImportFile.data(file),
              data.count <= 1 << 20,
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let raw = plist["CFBundleShortVersionString"] as? String else { return nil }
        if raw.hasPrefix("Build "), buildNumber(raw) != nil { return raw }
        return ImportVSCode.version(raw)
    }

    /// 4200 for "Build 4200".
    static func buildNumber(_ version: String) -> Int? {
        guard version.hasPrefix("Build ") else { return nil }
        let digits = String(version.dropFirst(6))
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII) else { return nil }
        return Int(digits)
    }

    // MARK: plan

    /// The settings Next Term has too, the user's own key bindings, recent folders and projects, and what wasn't
    /// brought over. `fonts`: the fonts this Mac has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .sublimeText else { return plan }
        let data = app.configPath
        plan.skipped.append(SkippedItem("Sublime Text's own shortcuts", "there is no Sublime Text shortcut set, so Next Term's shortcuts stay"))
        // Sublime Text 3 trims every line; 4 only the lines you changed, unless told otherwise.
        let three = (data as NSString).lastPathComponent == "Sublime Text 3"
        let clickKnown = addSettings(data: data, fonts: fonts, trimsChangedOnly: !three, to: &plan)
        // preview_on_click not set (or no Preferences file): Sublime Text's own default.
        if clickKnown { plan.addSingleClickDefault(for: app.kind, source: "preview_on_click (not set: true)", note: "\(app.name)'s default") }
        // Its sidebar opens a folder with a single click, whatever preview_on_click says.
        plan.noteFolderClick(true, source: "\(app.name)'s sidebar folders")
        addKeys(data: data, usKeyboard: usKeyboard, to: &plan)
        let recents = recentProjects(data: data, home: home)
        plan.recentProjects = recents.paths
        plan.skipped += recents.skipped
        plan.skipped += packages(data: data)
        var seen = Set<String>()
        plan.skipped = plan.skipped.filter { seen.insert($0.item).inserted }
        return plan
    }

    /// A file of the data folder, as its real path, or why it can't be read (nil and no reason: it isn't there).
    static func own(_ path: String, data: String, name: String) -> (path: String?, skipped: SkippedItem?) {
        guard isRegularFile(path) else { return (nil, nil) }
        guard let real = ImportFile.ownFile(path, folders: [data]) else { return (nil, SkippedItem(name, ImportFile.linkedOut)) }
        return (real, nil)
    }

    /// A file's text as JSON with comments (nil: unreadable, too big, or nested deeper than any real one; a nil
    /// document: nothing but comments and space, as Sublime Text first writes its files).
    static func document(_ path: String, limit: Int) -> (text: String, document: JSONC?)? {
        guard let data = ImportFile.data(path), data.count <= limit, let text = String(data: data, encoding: .utf8) else { return nil }
        let unmarked = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        if JSONC.plain(unmarked)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return (unmarked, nil) }
        guard JSONC.isShallow(unmarked), let document = JSONC(unmarked) else { return nil }
        return (unmarked, document)
    }

    // MARK: settings

    static let notRecognised = "value not recognised"
    static let tabsLater = "tab width and spaces come later"

    /// Keys this import turns into a setting: only their values are ever converted. `ignored_packages` is read only to
    /// see whether Vintage, its Vim mode, is on.
    static let mappedKeys: Set<String> = [
        "font_face", "font_size", "word_wrap", "wrap_width", "trim_trailing_white_space_on_save", "trim_only_modified_white_space",
        "ensure_newline_at_eof_on_save", "file_exclude_patterns", "folder_exclude_patterns", "line_padding_top",
        "line_padding_bottom", "preview_on_click", "ignored_packages",
    ]

    /// Keys with a reason of their own when the user set them (the rest are listed together).
    static let reasons: [String: String] = [
        "tab_size": tabsLater, "translate_tabs_to_spaces": tabsLater, "detect_indentation": tabsLater, "use_tab_stops": tabsLater,
        "rulers": "a ruler column comes later",
        "color_scheme": ImportZed.colours, "theme": ImportZed.colours,
        "caret_style": ImportRows.editorCaret, "caret_extra_width": ImportRows.editorCaret, "block_caret": ImportRows.editorCaret,
        "font_options": "font features and ligatures aren't supported",
        "binary_file_patterns": "Find in Files skips what git ignores; a file mask such as !dist/** leaves out more",
        "index_exclude_patterns": "Find in Files skips what git ignores; a file mask such as !dist/** leaves out more",
    ]

    /// The patterns Sublime Text 4 (and 3) hides by default: only what the user added comes over.
    static let defaultExcludes: Set<String> = [
        ".svn", ".git", ".hg", "CVS", ".Trash", ".Trash-*", "*.pyc", "*.pyo", "*.exe", "*.dll", "*.obj", "*.o", "*.a", "*.lib",
        "*.so", "*.dylib", "*.ncb", "*.sdf", "*.suo", "*.pdb", "*.idb", ".DS_Store", ".directory", "desktop.ini", "*.class",
        "*.psd", "*.db", "*.sublime-workspace",
    ]

    /// Sublime Text's font size on macOS (its Default package), for line padding when the user kept it.
    static let defaultFontSize = 12.0

    /// Packages/User/Preferences.sublime-settings as preview rows. The last value of a key wins, as in Sublime Text.
    /// `trimsChangedOnly`: the version trims only changed lines unless `trim_only_modified_white_space` is false.
    /// Returns whether the click Sublime Text uses is known: false when the file is there but couldn't be read, or
    /// preview_on_click holds a value not recognised.
    @discardableResult
    static func addSettings(data: String, fonts: FontCatalog, trimsChangedOnly: Bool, to plan: inout ImportPlan) -> Bool {
        let name = "Preferences.sublime-settings"
        let file = own((userFolder(data) as NSString).appendingPathComponent(name), data: data, name: name)
        if let reason = file.skipped {
            plan.skipped.append(reason)
            return false
        }
        guard let path = file.path else { return true } // no file: Sublime Text's defaults
        guard let read = document(path, limit: 4 << 20) else {
            plan.skipped.append(SkippedItem(name, "couldn't be read as JSON, so no settings came over"))
            return false
        }
        guard let document = read.document else { return true } // only comments: nothing set
        guard case .object(let object)? = document.root else {
            plan.skipped.append(SkippedItem(name, "couldn't be read as JSON, so no settings came over"))
            return false
        }
        let settings = Settings(members: object.members, text: read.text)
        addFont(settings, fonts: fonts, to: &plan)
        addEditing(settings, to: &plan)
        addCleanUp(settings, trimsChangedOnly: trimsChangedOnly, to: &plan)
        addHidden(settings, to: &plan)
        plan.skipped += report(settings)
        return settings.value("preview_on_click") == nil || plan.singleClick != nil
    }

    /// The settings file's members, unconverted until an allowlisted key is asked for.
    struct Settings {
        let members: [JSONC.Member]
        let text: String

        /// nil: not set; .some(nil): set to something JSON can't give back.
        func value(_ key: String) -> Any?? {
            guard ImportSublimeText.mappedKeys.contains(key), let member = members.last(where: { $0.key == key }) else { return nil }
            return .some(member.value.object(in: text))
        }
    }

    static func addFont(_ settings: Settings, fonts: FontCatalog, to plan: inout ImportPlan) {
        if let raw = settings.value("font_face") {
            if let face = raw as? String {
                if !face.trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = ImportFonts.row(.editor, list: face, source: "font_face", fonts: fonts)
                    plan.settings += [row.setting].compactMap { $0 }
                    plan.skipped += row.skipped
                }
            } else {
                plan.skipped.append(SkippedItem("font_face", notRecognised))
            }
        }
        let size = settings.value("font_size").map(ImportVSCode.number)
        if case .some(.none) = size { plan.skipped.append(SkippedItem("font_size", notRecognised)) }
        if let size = size ?? nil, size > 0 {
            plan.settings.append(ImportZed.fontSizeRow(size, source: "font_size", note: nil))
        }
        // Pixels added above and below each line: as a multiple of the line's own height at the font's size.
        let top = settings.value("line_padding_top").map(ImportVSCode.number)
        let bottom = settings.value("line_padding_bottom").map(ImportVSCode.number)
        guard top != nil || bottom != nil else { return }
        guard let topValue = top ?? 0, let bottomValue = bottom ?? 0, topValue >= 0, bottomValue >= 0 else {
            return plan.skipped.append(SkippedItem("line_padding_top and line_padding_bottom", notRecognised))
        }
        let padding = topValue + bottomValue
        guard padding > 0 else { return }
        let setSize: Double? = size ?? nil
        var fontSize: Double = defaultFontSize
        if let setSize, setSize > 0 { fontSize = setSize }
        let natural = fontSize * ImportVSCode.naturalLineHeightRatio
        let source = "line_padding_top \(ImportVSCode.format(topValue)), line_padding_bottom \(ImportVSCode.format(bottomValue))"
        plan.settings.append(PlannedSetting(.lineHeight(clamping: (natural + padding) / natural), source: source,
                                            note: "the nearest line height to Sublime Text's padding"))
    }

    /// Wrapping long lines, and opening a file (and a folder) with a single click in the sidebar.
    static func addEditing(_ settings: Settings, to plan: inout ImportPlan) {
        if let raw = settings.value("word_wrap") {
            if let on = ImportVSCode.bool(raw) {
                plan.settings.append(PlannedSetting(.softWrap(on), source: "word_wrap \(on)"))
            } else if (raw as? String) == "auto" {
                plan.skipped.append(SkippedItem("word_wrap auto", "Next Term wraps every file or none, not by its kind"))
            } else {
                plan.skipped.append(SkippedItem("word_wrap", notRecognised))
            }
        }
        if let raw = settings.value("wrap_width"), let width = ImportVSCode.number(raw), width > 0 {
            plan.skipped.append(SkippedItem("wrap_width \(ImportVSCode.format(width))", "Next Term wraps at the window edge; a wrap column isn't supported"))
        }
        if let raw = settings.value("preview_on_click") {
            if let on = ImportVSCode.bool(raw) {
                plan.settings.append(PlannedSetting(.sidebarSingleClick(on), source: "preview_on_click \(on)"))
            } else if (raw as? String) == "only_left" {
                plan.settings.append(PlannedSetting(.sidebarSingleClick(true), source: "preview_on_click only_left"))
            } else {
                plan.skipped.append(SkippedItem("preview_on_click", notRecognised))
            }
        }
    }

    /// Trimming trailing white space (true or "all", or "not_on_caret") and a final newline, on save.
    static func addCleanUp(_ settings: Settings, trimsChangedOnly: Bool, to plan: inout ImportPlan) {
        if let raw = settings.value("trim_trailing_white_space_on_save") {
            let mode = ImportVSCode.bool(raw).map { $0 ? "all" : "none" } ?? (raw as? String)
            switch mode {
            case "none"?:
                plan.settings.append(PlannedSetting(.trimTrailingWhitespace(false), source: "trim_trailing_white_space_on_save \(shown(raw))"))
            case "all"?, "not_on_caret"?:
                let source = "trim_trailing_white_space_on_save \(shown(raw))"
                let setOnly = settings.value("trim_only_modified_white_space").flatMap { ImportVSCode.bool($0) }
                let changedOnly = setOnly ?? trimsChangedOnly
                var notes: [String] = []
                if changedOnly { notes.append("Sublime Text trims only the lines you changed; Next Term trims every line of the file") }
                if mode == "not_on_caret" { notes.append("the caret's line is trimmed too") }
                plan.settings.append(PlannedSetting(.trimTrailingWhitespace(true), source: source, ticked: !changedOnly,
                                                    note: notes.isEmpty ? nil : notes.joined(separator: "; ")))
            default:
                plan.skipped.append(SkippedItem("trim_trailing_white_space_on_save", notRecognised))
            }
        }
        if let raw = settings.value("ensure_newline_at_eof_on_save") {
            if let on = ImportVSCode.bool(raw) {
                plan.settings.append(PlannedSetting(.insertFinalNewline(on), source: "ensure_newline_at_eof_on_save \(on)"))
            } else {
                plan.skipped.append(SkippedItem("ensure_newline_at_eof_on_save", notRecognised))
            }
        }
    }

    /// "true", "\"all\"".
    static func shown(_ raw: Any?) -> String {
        if let on = ImportVSCode.bool(raw) { return on ? "true" : "false" }
        return (raw as? String).map { "\"\($0)\"" } ?? "…"
    }

    /// The sidebar's `file_exclude_patterns` and `folder_exclude_patterns` (names, `*` and `?` allowed), less Sublime
    /// Text's own defaults, hidden in the project sidebar too. A folder pattern hides only folders.
    static func addHidden(_ settings: Settings, to plan: inout ImportPlan) {
        var patterns: [String] = []
        var sources: [String] = []
        var secret = 0, unusable = 0
        for (key, folders) in [("file_exclude_patterns", false), ("folder_exclude_patterns", true)] {
            guard let raw = settings.value(key) else { continue }
            guard let list = raw as? [Any] else {
                plan.skipped.append(SkippedItem(key, notRecognised))
                continue
            }
            var added = false
            for case let entry as String in list {
                let name = entry.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !defaultExcludes.contains(name), !FileNode.hiddenNames.contains(name) else { continue }
                if SecretGuard.looksSecret(name) {
                    secret += 1
                } else if name.contains("/") || name.hasPrefix("!") || name.count > 200 {
                    unusable += 1
                } else {
                    let pattern = folders ? name + "/" : name
                    if !patterns.contains(pattern) { patterns.append(pattern) }
                    added = true
                }
            }
            if added { sources.append(key) }
        }
        if !patterns.isEmpty {
            plan.settings.append(PlannedSetting(.hiddenFiles(patterns), source: sources.joined(separator: " and ")))
        }
        if secret > 0 {
            plan.skipped.append(SkippedItem(ImportJetBrains.plural(secret, "excluded name", "excluded names"), "looked like a credential"))
        }
        if unusable > 0 {
            plan.skipped.append(SkippedItem(ImportJetBrains.plural(unusable, "excluded pattern", "excluded patterns"), "not a name the sidebar can hide"))
        }
    }

    /// Vintage, the Vim mode Sublime Text ships, is on when `ignored_packages` leaves it out.
    static func vintageOn(_ settings: Settings) -> Bool {
        guard let list = settings.value("ignored_packages") as? [Any] else { return false }
        return !list.contains { ($0 as? String) == "Vintage" }
    }

    /// One row per setting the import saw and doesn't bring over, the unmapped ones gathered into one row. Only key
    /// names leave this function.
    static func report(_ settings: Settings) -> [SkippedItem] {
        var items: [SkippedItem] = []
        var others: [String] = []
        var seen = Set<String>()
        for member in settings.members where !mappedKeys.contains(member.key) && seen.insert(member.key).inserted {
            let key = member.key
            if key.hasPrefix("vintage_") {
                continue // the Vim mode's own settings: one Vim row says it all
            } else if SecretGuard.isSecretKey(key) {
                items.append(SkippedItem(key, ImportZed.secrets))
            } else if let reason = reasons[key] {
                items.append(SkippedItem(key, reason))
            } else if SecretGuard.looksSecret(key) || key.count > 80 {
                continue
            } else {
                others.append(key)
            }
        }
        if vintageOn(settings) { items.insert(SkippedItem("Vim keys (Vintage)", ImportVSCode.noVimMode), at: 0) }
        if !others.isEmpty {
            let shown = others.prefix(12).joined(separator: ", ") + (others.count > 12 ? " and \(others.count - 12) more" : "")
            items.append(SkippedItem("other settings: " + shown, "no matching Next Term setting yet"))
        }
        return items
    }

    // MARK: key bindings

    /// The user's key binding files, in the order Sublime Text reads them: the one for every platform, then macOS's.
    static let keymapFiles = ["Default.sublime-keymap", "Default (OSX).sublime-keymap"]

    /// Commands that are a Next Term command whatever arguments they are given.
    static let commands: [String: String] = [
        "new_window": "newWindow:", "close_window": "performClose:", "prompt_open": "openProjectPanel:",
        "prompt_open_folder": "openProjectPanel:", "prompt_open_project_or_workspace": "openProjectPanel:",
        "close_workspace": "closeProject:", "save_all": "saveAllDocuments:", "close": "closeTab:", "undo": "undo:",
        "redo": "redo:", "redo_or_repeat": "redo:", "cut": "cut:", "copy": "copy:", "paste": "paste:", "select_all": "selectAll:",
        "find_next": "performFindPanelAction:#2", "find_prev": "performFindPanelAction:#3",
        "slurp_find_string": "performFindPanelAction:#7", "indent": "indentSelection:", "unindent": "outdentSelection:",
        "duplicate_line": "duplicateLine:", "swap_line_up": "moveLineUp:", "swap_line_down": "moveLineDown:",
        "toggle_side_bar": "toggleProjectSidebar:", "reveal_in_side_bar": "revealInSidebar:",
        "increase_font_size": "increaseFontSize:", "decrease_font_size": "decreaseFontSize:", "reset_font_size": "resetFontSize:",
        "toggle_full_screen": "toggleFullScreen:", "select_last_tab": "selectTabByNumber:#9", "copy_path": "copyFilePath:",
    ]

    /// A binding's `args`, read one named key at a time.
    struct Arguments {
        let object: JSONC.Object?
        let text: String

        var names: [String] { object?.members.map(\.key) ?? [] }

        /// Only these names (or none at all) are given.
        func only(_ allowed: Set<String>) -> Bool { names.allSatisfy(allowed.contains) }

        func value(_ name: String) -> Any? { object?.members.last { $0.key == name }?.value.object(in: text) }
        func string(_ name: String) -> String? { value(name) as? String }
        func bool(_ name: String) -> Bool? { ImportVSCode.bool(value(name)) }
        func number(_ name: String) -> Double? { ImportVSCode.number(value(name)) }
    }

    /// The Next Term command a Sublime Text command is with these arguments (a command's identity is its name and
    /// its arguments there: `show_overlay` with `show_files` is Go to File). Nil: none.
    static func target(_ command: String, _ args: Arguments) -> String? {
        switch command {
        case "save": return args.only(["async"]) ? "saveDocument:" : nil
        case "reopen_last_file": return args.only(["source"]) ? "reopenClosedTab:" : nil
        case "next_view", "prev_view":
            guard args.only(["extend"]), args.bool("extend") != true else { return nil }
            return command == "next_view" ? "showNextTab:" : "showPreviousTab:"
        case "toggle_comment": return args.only(["block"]) && args.bool("block") != true ? "toggleComment:" : nil
        case "show_panel": return panel(args)
        case "show_overlay": return overlay(args)
        case "run_macro_file":
            let file = args.string("file")
            return args.only(["file"]) && file == "res://Packages/Default/Delete Line.sublime-macro" ? "deleteLine:" : nil
        case "toggle_setting": return args.only(["setting"]) && args.string("setting") == "word_wrap" ? "toggleSoftWrap:" : nil
        case "select_by_index":
            guard args.only(["index"]), let index = args.number("index"), index == index.rounded(), (0...7).contains(index) else { return nil }
            return "selectTabByNumber:#\(Int(index) + 1)"
        case "close_others_by_index", "close_to_right_by_index":
            // The tab context menu's commands; -1 (or nothing) is the tab in front.
            let group = args.number("group"), index = args.number("index")
            guard args.only(["group", "index"]), group == nil || group == -1, index == nil || index == -1 else { return nil }
            return command == "close_others_by_index" ? "closeOtherTabs:" : "closeTabsToTheRight:"
        case "open_dir":
            let file = args.string("file")
            guard args.only(["dir", "file"]), args.string("dir") == "$file_path", file == nil || file == "$file_name" else { return nil }
            return "revealInFinder:"
        case "edit_settings":
            guard args.only(["base_file", "default", "user_file"]),
                  args.string("base_file")?.hasSuffix("/Default/Preferences.sublime-settings") == true else { return nil }
            return "showSettings:"
        case "focus_neighboring_group":
            guard args.only(["forward"]) else { return nil }
            return args.bool("forward") == false ? "selectPreviousPane:" : "selectNextPane:"
        default:
            return args.names.isEmpty ? commands[command] : nil
        }
    }

    /// `show_panel`: Find, Replace and Find in Files, searching forward.
    static func panel(_ args: Arguments) -> String? {
        guard args.only(["panel", "reverse"]), args.bool("reverse") != true else { return nil }
        switch args.string("panel") {
        case "find"?: return "performFindPanelAction:#1"
        case "replace"?: return "replaceInFile:"
        case "find_in_files"?: return "findInFiles:"
        default: return nil
        }
    }

    /// `show_overlay` "goto": with `show_files`, Go to File; with the text ":", Go to Line.
    static func overlay(_ args: Arguments) -> String? {
        guard args.only(["overlay", "show_files", "text"]), args.string("overlay") == "goto" else { return nil }
        let files = args.bool("show_files") == true, text = args.string("text")
        if files && (text ?? "").isEmpty { return "goToFile:" }
        if !files && text == ":" { return "goToLine:" }
        return nil
    }

    /// One binding, in file order.
    struct Binding {
        let file: String
        let keys: [String]
        let command: String?
        /// The Next Term command it is (nil: none, or arguments that make it something else).
        let target: String?
        /// It works only where its `context` holds.
        let hasContext: Bool

        var label: String {
            let keys = self.keys.map(ImportShortcuts.shown).joined(separator: ", ")
            return ImportKeys.label("\(keys) → \(ImportShortcuts.shown(command ?? "nothing"))")
        }
    }

    /// The bindings of the user's key binding files, and what couldn't be read.
    static func bindings(data: String) -> (bindings: [Binding], skipped: [SkippedItem]) {
        var result: [Binding] = []
        var skipped: [SkippedItem] = []
        for name in keymapFiles {
            let file = own((userFolder(data) as NSString).appendingPathComponent(name), data: data, name: name)
            if let reason = file.skipped { skipped.append(reason) }
            guard let path = file.path else { continue }
            guard let read = document(path, limit: 4 << 20) else {
                skipped.append(SkippedItem(name, "couldn't be read as JSON; your shortcuts there were skipped"))
                continue
            }
            guard let document = read.document else { continue } // only comments
            guard let root = document.root, let elements = document.elements(of: root) else {
                skipped.append(SkippedItem(name, "couldn't be read as JSON; your shortcuts there were skipped"))
                continue
            }
            for case .object(let object) in elements {
                result.append(binding(object, text: read.text, file: name))
            }
        }
        return (result, skipped)
    }

    static func binding(_ object: JSONC.Object, text: String, file: String) -> Binding {
        let keys = (object.members.last { $0.key == "keys" }?.value.object(in: text) as? [Any])?.compactMap { $0 as? String } ?? []
        let command = object.members.last { $0.key == "command" }?.value.object(in: text) as? String
        var context = false
        if let member = object.members.last(where: { $0.key == "context" }) {
            if case .array(let range) = member.value { context = !text[range].dropFirst().dropLast().allSatisfy(\.isWhitespace) } else { context = true }
        }
        var argsObject: JSONC.Object?
        var argsReadable = true
        if let member = object.members.last(where: { $0.key == "args" }) {
            if case .object(let args) = member.value { argsObject = args } else { argsReadable = false }
        }
        let target = command.flatMap { argsReadable ? Self.target($0, Arguments(object: argsObject, text: text)) : nil }
        return Binding(file: file, keys: keys, command: command, target: target, hasContext: context)
    }

    /// A Sublime Text key ("super+shift+p", "primary+k"), read as an import's key: `super`, `command` and `primary` are ⌘.
    static func key(_ raw: String, usKeyboard: Bool) -> ImportShortcuts.ParsedKey {
        guard !raw.hasSuffix("++"), raw != "+" else { return .notSupported(ImportShortcuts.notRecognised) }
        var parts = raw.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.popLast(), !last.isEmpty else { return .notSupported(ImportShortcuts.notRecognised) }
        let lowered = last.lowercased()
        if lowered.hasPrefix("keypad") { return .notSupported(ImportShortcuts.numpad) }
        let names = ["forward_slash": "/", "plus": "=", "equals": "=", "backquote": "`"]
        let modifiers = parts.map { $0.lowercased() == "primary" ? "cmd" : $0 }
        return ImportKeys.parse(modifiers: modifiers, key: names[lowered] ?? last, usKeyboard: usKeyboard)
    }

    /// The bindings as rows. As in Sublime Text, a later binding of a key replaces an earlier one; of one command's
    /// keys, the last one comes over (one key per command here).
    static func addKeys(data: String, usKeyboard: Bool, to plan: inout ImportPlan) {
        let read = bindings(data: data)
        plan.skipped += read.skipped
        let list = read.bindings
        let chords = list.map { binding -> KeyChord? in
            guard binding.keys.count == 1, !binding.hasContext, case .chord(let chord) = key(binding.keys[0], usKeyboard: usKeyboard) else { return nil }
            return chord
        }
        var picked: [String: (index: Int, chord: KeyChord)] = [:]
        var order: [String] = []
        for (index, binding) in list.enumerated() {
            if let reason = unusable(binding, index: index, chords: chords, list: list, usKeyboard: usKeyboard) {
                plan.skipped.append(SkippedItem(binding.label, reason))
                continue
            }
            guard let target = binding.target, let chord = chords[index] else { continue }
            if let earlier = picked[target] {
                plan.skipped.append(SkippedItem(list[earlier.index].label, "one shortcut per command here; \(chord.display) comes over"))
            } else {
                order.append(target)
            }
            picked[target] = (index, chord)
        }
        for target in order {
            guard let pick = picked[target] else { continue }
            let binding = list[pick.index]
            plan.shortcuts.append(ImportShortcuts.row(target, pick.chord, source: "\(binding.file): \(binding.label)"))
        }
    }

    /// Why a binding doesn't come over (nil: it does).
    static func unusable(_ binding: Binding, index: Int, chords: [KeyChord?], list: [Binding], usKeyboard: Bool) -> String? {
        guard let command = binding.command, !binding.keys.isEmpty else { return notRecognised }
        if command == "noop" { return "turning a key off isn't brought over" }
        guard binding.target != nil else {
            return ImportSublimeText.commands[command] != nil || knownWithArguments.contains(command)
                ? "passes arguments in Sublime Text that make it another command" : ImportShortcuts.noCommand
        }
        if binding.keys.count > 1 { return ImportShortcuts.twoStep }
        if binding.hasContext { return "works only in some places in Sublime Text; keys for one context come later" }
        let parsed = key(binding.keys[0], usKeyboard: usKeyboard)
        guard case .chord(let chord) = parsed else {
            if case .notSupported(let reason) = parsed { return reason }
            return notRecognised
        }
        if let reason = ImportShortcuts.unusable(chord) { return reason }
        // A later binding of the same key, everywhere, replaces this one.
        if let later = list.indices.last(where: { $0 > index && chords[$0] == chord }), list[later].target != binding.target {
            let other = list[later].command.map(ImportShortcuts.shown) ?? "nothing"
            return list[later].command == "noop" ? "turned off further down" : "replaced further down by \(other)"
        }
        return nil
    }

    /// Commands that are a Next Term command only with some arguments.
    static let knownWithArguments: Set<String> = [
        "save", "reopen_last_file", "next_view", "prev_view", "toggle_comment", "show_panel", "show_overlay", "run_macro_file",
        "toggle_setting", "select_by_index", "close_others_by_index", "close_to_right_by_index", "open_dir", "edit_settings",
        "focus_neighboring_group",
    ]

    // MARK: recent projects

    static let recentLimit = 20

    /// The folders the session lists (`folder_history`, newest first), then the first folder of each recent project
    /// (`workspaces.recent_workspaces`, through the .sublime-project beside each workspace file). Local folders that
    /// exist only, each once, at most 20. Nothing else in the session is converted: it also keeps unsaved text.
    static func recentProjects(data: String, home: String) -> (paths: [String], skipped: [SkippedItem]) {
        let name = "Session.sublime_session"
        let file = own(sessionFile(data), data: data, name: name)
        if let reason = file.skipped { return ([], [reason]) }
        guard let path = file.path else { return ([], []) }
        guard let read = document(path, limit: 32 << 20), case .object(let root)? = read.document?.root else {
            return ([], [SkippedItem("recent projects", "the session file couldn't be read as JSON")])
        }
        let folders = root.members.last { $0.key == "folder_history" }?.value.object(in: read.text) as? [Any] ?? []
        var workspaces: [Any] = []
        if case .object(let object)? = root.members.last(where: { $0.key == "workspaces" })?.value {
            workspaces = object.members.last { $0.key == "recent_workspaces" }?.value.object(in: read.text) as? [Any] ?? []
        }
        var paths: [String] = []
        var skipped: [SkippedItem] = []
        var secret = 0
        func add(_ raw: String) -> Bool {
            guard paths.count < recentLimit, raw.hasPrefix("/") else { return false }
            let folder = canonicalPath(raw)
            guard ImportVSCode.isDirectory(folder), !paths.contains(folder) else { return false }
            guard !SecretGuard.pathLooksSecret(folder) else {
                secret += 1
                return false
            }
            paths.append(folder)
            return true
        }
        for case let folder as String in folders { _ = add(folder) }
        for case let workspace as String in workspaces where paths.count < recentLimit {
            guard let project = projectFile(ofWorkspace: workspace),
                  let listed = ImportVSCode.firstFolder(ofWorkspace: project), let folder = listed.folder else { continue }
            if add(folder), listed.others > 0 {
                let shown = ImportVSCode.workspaceName(project)
                skipped.append(SkippedItem(shown, "only a project's first folder comes over (\(ImportVSCode.counted(listed.others, "more folder")) left out)"))
            }
        }
        if secret > 0 { skipped.append(SkippedItem(ImportVSCode.counted(secret, "recent project"), ImportVSCode.credential)) }
        return (paths, skipped)
    }

    /// The .sublime-project a recent workspace file belongs to: the one beside it with the same name, as Sublime Text
    /// saves them. The workspace file itself is never opened (it keeps unsaved text).
    static func projectFile(ofWorkspace path: String) -> String? {
        let suffix = ".sublime-workspace"
        guard path.hasPrefix("/"), path.hasSuffix(suffix), !SecretGuard.pathLooksSecret(path) else { return nil }
        let project = String(path.dropLast(suffix.count)) + ".sublime-project"
        return isRegularFile(project) ? project : nil
    }

    // MARK: packages

    /// Packages (Packages and Installed Packages, the user's own aside) as a count, a Vim package named as one, and
    /// the files in Packages/User besides those read. Names only: no package is opened, and none is named.
    static func packages(data: String) -> [SkippedItem] {
        let fm = FileManager.default
        var names = Set<String>()
        let installed = (data as NSString).appendingPathComponent("Installed Packages")
        for entry in (try? fm.contentsOfDirectory(atPath: installed)) ?? [] where entry.hasSuffix(".sublime-package") {
            names.insert(String(entry.dropLast(".sublime-package".count)))
        }
        let unpacked = (data as NSString).appendingPathComponent("Packages")
        for entry in (try? fm.contentsOfDirectory(atPath: unpacked)) ?? [] where !entry.hasPrefix(".") && entry != "User" {
            if ImportVSCode.isDirectory((unpacked as NSString).appendingPathComponent(entry)) { names.insert(entry) }
        }
        var items: [SkippedItem] = []
        let vim = names.intersection(vimPackages)
        if let first = vim.sorted().first { items.append(SkippedItem("Vim keys (\(first) package)", ImportVSCode.noVimMode)) }
        let others = names.subtracting(vim).count
        if others > 0 { items.append(SkippedItem(ImportVSCode.counted(others, vim.isEmpty ? "package" : "other package"), "packages aren't imported")) }
        let user = (try? fm.contentsOfDirectory(atPath: userFolder(data))) ?? []
        let settings = user.filter { $0.hasSuffix(".sublime-settings") && $0 != "Preferences.sublime-settings" }.count
        if settings > 0 {
            items.append(SkippedItem(ImportVSCode.counted(settings, "other settings file"), "settings for one language or package aren't imported"))
        }
        if user.contains(where: { $0.hasSuffix(".sublime-snippet") }) { items.append(SkippedItem("snippets", "snippets aren't supported")) }
        if user.contains(where: { $0.hasSuffix(".sublime-build") }) { items.append(SkippedItem("build systems", ImportVSCode.runsCommands)) }
        return items
    }

    /// Packages that give Sublime Text Vim keys.
    static let vimPackages: Set<String> = ["NeoVintageous", "Vintageous", "ActualVim"]
}

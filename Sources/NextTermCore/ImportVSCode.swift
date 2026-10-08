import Foundation
import SQLite3

// "Coming from VS Code?": what VS Code, VS Code Insiders, VSCodium, Cursor and Devin Desktop (once Windsurf)
// would bring over. Design: claudedocs/research_next-term-migration (§3.1 settings, §4 recents, §5 detection,
// §6 safety). Everything here only reads, and only these: settings.json (a value is converted only for an
// allowlisted key), keybindings.json (each rule's key, command and when: ImportVSCodeKeys.swift),
// globalStorage/storage.json (the number of profiles), the app's product.json (one key),
// one key of a state.vscdb opened in place read-only, and the folders list of a workspace file a recent entry
// names. Nothing is written, copied or sent anywhere.

/// The VS Code family: detection by folder, and the plan for one detected app.
public enum ImportVSCode {
    struct Source {
        let kind: ImportSourceKind
        let name: String
        /// The data folder in ~/Library/Application Support (its `User` folder holds settings.json).
        let folder: String
        /// The app bundle's possible names in /Applications or ~/Applications, for its product.json.
        let bundles: [String]
    }

    /// Devin Desktop's bundle name isn't documented, so both likely names are tried. Windsurf is its old name
    /// and folder, used only when the Devin folder isn't there.
    static let sources: [Source] = [
        Source(kind: .vsCode, name: "VS Code", folder: "Code", bundles: ["Visual Studio Code.app"]),
        Source(kind: .vsCodeInsiders, name: "VS Code Insiders", folder: "Code - Insiders", bundles: ["Visual Studio Code - Insiders.app"]),
        Source(kind: .vsCodium, name: "VSCodium", folder: "VSCodium", bundles: ["VSCodium.app"]),
        Source(kind: .cursor, name: "Cursor", folder: "Cursor", bundles: ["Cursor.app"]),
        Source(kind: .devinDesktop, name: "Devin Desktop", folder: "Devin", bundles: ["Devin.app", "Devin Desktop.app"]),
        Source(kind: .devinDesktop, name: "Windsurf", folder: "Windsurf", bundles: ["Windsurf.app"]),
    ]

    static let family: Set<ImportSourceKind> = [.vsCode, .vsCodeInsiders, .vsCodium, .cursor, .devinDesktop]

    // MARK: detection

    /// The apps whose `User` folder exists, most recently used first. Only existence and modification dates
    /// are looked at: nothing is opened until the user picks one.
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        var found: [DetectedApp] = []
        for source in sources {
            if source.folder == "Windsurf", found.contains(where: { $0.kind == .devinDesktop }) { continue }
            let user = (home as NSString).appendingPathComponent("Library/Application Support/\(source.folder)/User")
            guard isDirectory(user) else { continue }
            found.append(DetectedApp(kind: source.kind, name: source.name, configPath: user, lastUsed: lastUsed(user)))
        }
        return found.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    /// The later of settings.json's and the User folder's modification dates (a settings change, or a file
    /// added to the folder).
    static func lastUsed(_ user: String) -> Date? {
        [modified((user as NSString).appendingPathComponent("settings.json")), modified(user)].compactMap { $0 }.max()
    }

    // MARK: plan

    /// What `app` would bring over: its settings (§3.1), the user's own shortcuts (§2.4), recent folders (§4)
    /// and what was left out, with why.
    /// `usKeyboard`: the current input source is U.S.-style, so Option isn't needed to type symbols.
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true) -> ImportPlan {
        plan(for: app, home: home, usKeyboard: usKeyboard,
             applications: ["/Applications", (home as NSString).appendingPathComponent("Applications")])
    }

    /// `applications`: the folders searched for the app bundle; `fonts`: the fonts this Mac has (tests pass
    /// their own of both).
    static func plan(for app: DetectedApp, home: String, usKeyboard: Bool, applications: [String],
                     fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard family.contains(app.kind) else { return plan }
        let settings = settingsPlan(user: app.configPath, appName: app.name, usKeyboard: usKeyboard, fonts: fonts, home: home)
        plan.settings = settings.settings
        let keys = keybindingsPlan(user: app.configPath, usKeyboard: usKeyboard)
        plan.shortcuts = keys.shortcuts
        plan.skipped = settings.skipped + keys.skipped + neverImportedFiles(user: app.configPath)
        let profiles = otherProfiles(user: app.configPath)
        if profiles > 0 {
            plan.skipped.append(SkippedItem(counted(profiles, "other profile"), "only the default profile is read; other profiles: choose in a later version"))
        }
        let recents = recentProjects(app: app, home: home, applications: applications)
        plan.recentProjects = recents.paths
        plan.skipped += recents.skipped
        var seen = Set<String>()
        plan.skipped = plan.skipped.filter { seen.insert($0.item).inserted }
        return plan
    }

    // MARK: settings.json

    static let themesLater = "colour themes come later"
    static let canHoldSecrets = "never imported: can hold secrets"
    static let runsCommands = "never imported: runs commands"
    static let notRecognised = "value not recognised"
    static let credential = "looked like a credential"

    /// Keys this import turns into a setting (§3.1). Only these values are ever converted. The colour theme's
    /// name is read only to pick the colour customizations made for it.
    static let mappedKeys: Set<String> = [
        "editor.fontSize", "window.zoomLevel", "terminal.integrated.fontSize", "editor.lineHeight", "editor.wordWrap",
        "terminal.integrated.macOptionIsMeta", "workbench.sideBar.location", "workbench.panel.defaultLocation",
        "editor.fontFamily", "terminal.integrated.fontFamily", "workbench.colorCustomizations", "workbench.colorTheme",
        "files.trimTrailingWhitespace", "files.insertFinalNewline", "files.exclude", "terminal.integrated.cursorStyle",
        "terminal.integrated.cursorBlinking", "terminal.integrated.scrollback", "terminal.integrated.cwd",
    ]

    /// Keys Next Term has no setting for (§3.5), reported by name when the user set them.
    static let laterKeys: [String: String] = [
        "editor.tabSize": "tab width and spaces come later",
        "editor.insertSpaces": "tab width and spaces come later",
        "editor.detectIndentation": "tab width and spaces come later",
        "search.exclude": "Find in Files skips what git ignores; a file mask such as !dist/** leaves out more",
        "editor.cursorStyle": ImportRows.editorCaret,
        "editor.cursorBlinking": ImportRows.editorCaret,
    ]

    /// Terminal profiles, shells and their arguments: they start programs, so they are never read.
    static let commandPrefixes = [
        "terminal.integrated.profiles.", "terminal.integrated.defaultprofile.", "terminal.integrated.automationprofile.",
        "terminal.integrated.shell.", "terminal.integrated.shellargs.", "terminal.integrated.automationshell.",
    ]

    enum Disposition: Equatable {
        case mapped
        case skipped(String)
        case other
    }

    /// What happens to a key, decided from its name alone (secret and command keys first, so their values
    /// are never converted whatever else they match).
    static func disposition(of key: String) -> Disposition {
        let lower = key.lowercased()
        if commandPrefixes.contains(where: lower.hasPrefix) { return .skipped(runsCommands) }
        if SecretGuard.isSecretKey(key) { return .skipped(canHoldSecrets) }
        if mappedKeys.contains(key) { return .mapped }
        if let reason = laterKeys[key] { return .skipped(reason) }
        if key.hasPrefix("[") { return .skipped("per-language settings come later") }
        return .other
    }

    /// settings.json's top-level members, unconverted: a value becomes a Foundation object only when an
    /// allowlisted key asks for it, so a token under `terminal.integrated.env.osx` is never kept.
    struct SettingsFile {
        let document: JSONC
        let members: [JSONC.Member]

        init?(_ text: String) {
            guard let document = JSONC(text), case .object(let root)? = document.root else { return nil }
            self.document = document
            members = root.members
        }

        /// The value of an allowlisted key (the last one wins, as in VS Code).
        func value(_ key: String) -> Any? {
            guard ImportVSCode.disposition(of: key) == .mapped, let member = members.last(where: { $0.key == key }) else { return nil }
            return member.value.object(in: document.text)
        }

        func has(_ key: String) -> Bool { members.contains { $0.key == key } }
    }

    struct SettingsResult {
        var settings: [PlannedSetting] = []
        var skipped: [SkippedItem] = []
    }

    /// The default profile's settings.json (`<User>/settings.json`) as preview rows.
    static func settingsPlan(user: String, appName: String, usKeyboard: Bool, fonts: FontCatalog = .system,
                             home: String = NSHomeDirectory()) -> SettingsResult {
        let path = (user as NSString).appendingPathComponent("settings.json")
        guard isRegularFile(path) else { return SettingsResult() }
        guard let text = readText(path, limit: 4 << 20) else {
            return SettingsResult(skipped: [SkippedItem("settings.json", "couldn't be read")])
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty {
            return SettingsResult()
        }
        guard let file = SettingsFile(text) else {
            return SettingsResult(skipped: [SkippedItem("settings.json", "couldn't be read as JSON; settings were skipped")])
        }
        return settingsPlan(file, appName: appName, usKeyboard: usKeyboard, fonts: fonts, home: home)
    }

    static func settingsPlan(_ file: SettingsFile, appName: String, usKeyboard: Bool, fonts: FontCatalog = .system,
                             home: String = NSHomeDirectory()) -> SettingsResult {
        var result = SettingsResult()
        let font = fontSize(file)
        result.settings += [font.setting].compactMap { $0 }
        result.skipped += font.skipped
        let line = lineHeight(file)
        result.settings += [line.setting].compactMap { $0 }
        result.skipped += line.skipped
        let wrap = softWrap(file)
        result.settings += [wrap.setting].compactMap { $0 }
        result.skipped += wrap.skipped
        let rest = optionAndPanels(file, appName: appName, usKeyboard: usKeyboard)
        result.settings += rest.settings
        result.skipped += rest.skipped
        let families = fontFamilies(file, appName: appName, fonts: fonts)
        result.settings += families.settings
        result.skipped += families.skipped
        let colours = terminalColours(file, appName: appName)
        result.settings += colours.settings
        result.skipped += colours.skipped
        let saving = cleanUpAndHiding(file)
        result.settings += saving.settings
        result.skipped += saving.skipped
        let terminal = terminalBehaviour(file, appName: appName, home: home)
        result.settings += terminal.settings
        result.skipped += terminal.skipped
        result.skipped += unmappedKeys(file)
        return result
    }

    // MARK: saving, hiding files and the terminal

    /// files.trimTrailingWhitespace and files.insertFinalNewline, and the patterns files.exclude turns on (VS Code
    /// adds them to its own, which hide what the sidebar here hides anyway).
    static func cleanUpAndHiding(_ file: SettingsFile) -> SettingsResult {
        var result = SettingsResult()
        for key in ["files.trimTrailingWhitespace", "files.insertFinalNewline"] where file.has(key) {
            guard let on = bool(file.value(key)) else {
                result.skipped.append(SkippedItem(key, notRecognised))
                continue
            }
            let setting = key == "files.trimTrailingWhitespace" ? ImportedSetting.trimTrailingWhitespace(on) : .insertFinalNewline(on)
            result.settings.append(PlannedSetting(setting, source: "\(key) \(on)"))
        }
        let key = "files.exclude"
        guard file.has(key) else { return result }
        guard let globs = file.value(key) as? [String: Any] else {
            result.skipped.append(SkippedItem(key, notRecognised))
            return result
        }
        var hidden: [String] = []
        for glob in globs.keys.sorted() where !SecretGuard.looksSecret(glob) {
            let on = bool(globs[glob])
            if on == true {
                hidden.append(glob)
            } else if on == false {
                // Showing what VS Code hides by default: the sidebar here hides only these, and always.
                if FileHiding.pattern(fromProjectGlob: glob) == nil {
                    result.skipped.append(SkippedItem("\(key) \(glob) false", "the project sidebar always hides .git, .svn, .hg and .DS_Store"))
                }
            } else {
                result.skipped.append(SkippedItem("\(key) \(glob)", "hiding a file only when another is beside it isn't supported"))
            }
        }
        if let row = ImportRows.hiddenFiles(hidden, source: key) { result.settings.append(row) }
        return result
    }

    /// The terminal's cursor (VS Code's `line` is a bar), its scrollback and the folder it starts in.
    static func terminalBehaviour(_ file: SettingsFile, appName: String, home: String) -> SettingsResult {
        var result = SettingsResult()
        let styleKey = "terminal.integrated.cursorStyle"
        if file.has(styleKey) {
            let shapes = ["block": CursorShape.block, "line": .bar, "underline": .underline]
            if let style = string(file.value(styleKey)), let shape = shapes[style] {
                result.settings.append(PlannedSetting(.terminalCursorShape(shape.rawValue), source: "\(styleKey) \(style)"))
            } else {
                result.skipped.append(SkippedItem(styleKey, notRecognised))
            }
        }
        let blinkKey = "terminal.integrated.cursorBlinking"
        if file.has(blinkKey) {
            if let blinks = bool(file.value(blinkKey)) {
                result.settings.append(PlannedSetting(.terminalCursorBlink(blinks), source: "\(blinkKey) \(blinks)"))
            } else {
                result.skipped.append(SkippedItem(blinkKey, notRecognised))
            }
        }
        let scrollKey = "terminal.integrated.scrollback"
        if file.has(scrollKey) {
            if let lines = number(file.value(scrollKey)), lines >= 0, lines < 1e9 {
                result.settings.append(ImportRows.scrollback(Int(lines), source: "\(scrollKey) \(format(lines))", app: appName))
            } else {
                result.skipped.append(SkippedItem(scrollKey, notRecognised))
            }
        }
        let folderKey = "terminal.integrated.cwd"
        if file.has(folderKey) {
            if let path = file.value(folderKey) as? String {
                if path.contains("${") {
                    result.skipped.append(SkippedItem(folderKey, "uses a variable; only a full path to a folder is read"))
                } else if !path.trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = ImportRows.startFolder(path, key: folderKey, home: home)
                    result.settings += [row.setting].compactMap { $0 }
                    result.skipped += row.skipped
                }
            } else {
                result.skipped.append(SkippedItem(folderKey, notRecognised))
            }
        }
        return result
    }

    // MARK: fonts and colours

    /// editor.fontFamily and terminal.integrated.fontFamily (CSS lists: the first font this Mac has that is
    /// monospaced). VS Code's terminal uses the editor's list while its own is unset or empty, and so does
    /// the import.
    static func fontFamilies(_ file: SettingsFile, appName: String, fonts: FontCatalog) -> SettingsResult {
        var result = SettingsResult()
        func list(_ key: String) -> String? {
            guard file.has(key) else { return nil }
            // Each name in it is checked for credentials as it is looked up.
            guard let text = file.value(key) as? String else {
                result.skipped.append(SkippedItem(key, notRecognised))
                return nil
            }
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        }
        let editorKey = "editor.fontFamily", terminalKey = "terminal.integrated.fontFamily"
        let editorList = list(editorKey)
        if let editorList {
            let editor = ImportFonts.row(.editor, list: editorList, source: editorKey, fonts: fonts)
            result.settings += [editor.setting].compactMap { $0 }
            result.skipped += editor.skipped
        }
        if let terminalList = list(terminalKey) {
            let terminal = ImportFonts.row(.terminal, list: terminalList, source: terminalKey, fonts: fonts)
            result.settings += [terminal.setting].compactMap { $0 }
            result.skipped += terminal.skipped
        } else if let editorList {
            // The fonts passed over were reported for the editor already.
            let note = "\(appName)'s terminal uses the editor font while \(terminalKey) is unset"
            let terminal = ImportFonts.row(.terminal, list: editorList, source: editorKey, fonts: fonts, note: note)
            result.settings += [terminal.setting].compactMap { $0 }
        }
        return result
    }

    /// workbench.colorCustomizations keys for the terminal, by slot: the 16 ANSI colours, then text,
    /// background, cursor and selection.
    static let terminalColourKeys: [String] = {
        let names: [String] = TerminalPalette.ansiNames.map { name in String(name.prefix(1)).uppercased() + String(name.dropFirst()) }
        let normal = names.map { "terminal.ansi" + $0 }
        let bright = names.map { "terminal.ansiBright" + $0 }
        let others = ["terminal.foreground", "terminal.background", "terminalCursor.foreground", "terminal.selectionBackground"]
        return normal + bright + others
    }()

    /// The terminal colours set in workbench.colorCustomizations: the top-level ones, then the block for
    /// the colour theme in use (`"[Theme Name]": {…}`), which wins. Other colours in it, and the theme
    /// itself, are reported.
    static func terminalColours(_ file: SettingsFile, appName: String) -> SettingsResult {
        var result = SettingsResult()
        let themeKey = "workbench.colorTheme", key = "workbench.colorCustomizations"
        let theme = file.has(themeKey) ? string(file.value(themeKey)) : nil
        if file.has(themeKey) { result.skipped.append(SkippedItem(themeKey, themesLater)) }
        guard file.has(key) else { return result }
        guard let customizations = file.value(key) as? [String: Any] else {
            result.skipped.append(SkippedItem(key, notRecognised))
            return result
        }
        var values: [String: Any] = customizations.filter { !$0.key.hasPrefix("[") }
        var scope = ""
        if let theme, let scoped = customizations["[\(theme)]"] as? [String: Any] {
            values.merge(scoped) { _, scoped in scoped }
            scope = " and its [\(theme)] block"
        }
        var palette = TerminalPalette(name: "\(appName) terminal colours")
        var selection: (rgb: UInt32, alpha: Double)?
        for (slot, name) in terminalColourKeys.enumerated() {
            guard let value = values[name] else { continue }
            guard let text = value as? String, let colour = TerminalPalette.hex(text) else {
                result.skipped.append(SkippedItem("\(key) \(name)", notRecognised))
                continue
            }
            switch slot {
            case 0..<16: palette.ansi[slot] = colour.rgb
            case 16: palette.foreground = colour.rgb
            case 17: palette.background = colour.rgb
            case 18: palette.cursor = colour.rgb
            default: selection = colour
            }
        }
        if let selection {
            palette.selection = ImportColours.opaqueSelection(selection.rgb, alpha: selection.alpha, background: palette.background)
        }
        if let row = ImportColours.row(palette, source: "terminal colours in \(key)\(scope)") { result.settings.append(row) }
        let others = Set(values.keys).subtracting(terminalColourKeys).count
        if others > 0 { result.skipped.append(SkippedItem("\(key): \(counted(others, "other colour"))", themesLater)) }
        return result
    }

    typealias Row = (setting: PlannedSetting?, skipped: [SkippedItem])

    /// A number VS Code would use for a size: a JSON number above 0, clamped to VS Code's own 6–100. A key
    /// whose value isn't a number is reported; 0 or below is VS Code's default, so treated as unset.
    static func size(_ file: SettingsFile, _ key: String, skipped: inout [SkippedItem]) -> Double? {
        guard file.has(key) else { return nil }
        guard let value = number(file.value(key)) else {
            skipped.append(SkippedItem(key, notRecognised))
            return nil
        }
        return value > 0 ? min(100, max(6, value)) : nil
    }

    /// editor.fontSize and window.zoomLevel: round(size × 1.2^zoom), VS Code's defaults (12, zoom 0) for the
    /// unset one, imported only if one of them is set. terminal.integrated.fontSize stands in for an unset
    /// editor size (zoomed the same way, since the zoom scales the whole window); when both are set and
    /// differ, the editor's wins and the difference is reported (one size is shared today).
    static func fontSize(_ file: SettingsFile) -> Row {
        var skipped: [SkippedItem] = []
        let editor = size(file, "editor.fontSize", skipped: &skipped)
        let terminal = size(file, "terminal.integrated.fontSize", skipped: &skipped)
        var zoom: Double?
        if file.has("window.zoomLevel") {
            zoom = number(file.value("window.zoomLevel"))
            if zoom == nil { skipped.append(SkippedItem("window.zoomLevel", notRecognised)) }
        }
        if let editor, let terminal, editor != terminal {
            skipped.append(SkippedItem("terminal.integrated.fontSize", "one font size for editor and terminal today; the editor's size is used"))
        }
        let factor = pow(1.2, zoom ?? 0)
        let zoomed = zoom.map { " at window.zoomLevel \(format($0))" } ?? ""
        let row: PlannedSetting
        if let editor {
            row = PlannedSetting(.fontSize(clamping: editor * factor), source: "editor.fontSize \(format(editor))" + zoomed)
        } else if let terminal {
            row = PlannedSetting(.fontSize(clamping: terminal * factor), source: "terminal.integrated.fontSize \(format(terminal))" + zoomed)
        } else if let zoom {
            row = PlannedSetting(.fontSize(clamping: defaultFontSize * factor),
                                 source: "window.zoomLevel \(format(zoom)) with the default editor.fontSize \(format(defaultFontSize))")
        } else {
            return (nil, skipped)
        }
        return (row, skipped)
    }

    /// VS Code's editor font size on macOS when editor.fontSize is unset.
    static let defaultFontSize = 12.0

    /// Next Term's editor font's own line height as a multiple of its size. The real value depends on the font
    /// (JetBrains Mono, then SF Mono, `Theme.swift`) and needs AppKit to measure, which Core doesn't have; 1.2
    /// is close for both, and the result is rounded to 0.05 anyway.
    static let naturalLineHeightRatio = 1.2

    /// editor.lineHeight: 0 is VS Code's default (skipped), under 8 a multiple of the font size, 8 or more
    /// pixels. VS Code rounds the result and keeps it at least 8 px (`fontInfo.ts`). The factor is that
    /// height over the natural height of the font it was set against (the editor's size: window zoom scales
    /// both, so it cancels), so the lines keep their look whatever size Next Term ends up with.
    static func lineHeight(_ file: SettingsFile) -> Row {
        guard file.has("editor.lineHeight") else { return (nil, []) }
        guard let value = number(file.value("editor.lineHeight")) else {
            return (nil, [SkippedItem("editor.lineHeight", notRecognised)])
        }
        guard value > 0 else { return (nil, []) }
        var ignored: [SkippedItem] = []
        let font = size(file, "editor.fontSize", skipped: &ignored) ?? defaultFontSize
        let pixels = max(8, (value < 8 ? value * font : min(150, value)).rounded())
        let factor = pixels / (naturalLineHeightRatio * font)
        return (PlannedSetting(.lineHeight(clamping: factor), source: "editor.lineHeight \(format(value))"), [])
    }

    /// editor.wordWrap: `off` → no wrap; `on`, `wordWrapColumn` and `bounded` → wrap (Next Term wraps at
    /// the window edge, so the column is reported). Old settings files may hold true or false.
    static func softWrap(_ file: SettingsFile) -> Row {
        let key = "editor.wordWrap"
        guard file.has(key) else { return (nil, []) }
        let value = file.value(key)
        let mode = string(value) ?? bool(value).map { $0 ? "on" : "off" }
        switch mode {
        case "off":
            return (PlannedSetting(.softWrap(false), source: "\(key) off"), [])
        case "on":
            return (PlannedSetting(.softWrap(true), source: "\(key) on"), [])
        case "wordWrapColumn", "bounded":
            let mode = mode ?? ""
            return (PlannedSetting(.softWrap(true), source: "\(key) \(mode)"),
                    [SkippedItem("\(key) \(mode)", "Next Term wraps at the window edge; a wrap column isn't supported")])
        default:
            return (nil, [SkippedItem(key, notRecognised)])
        }
    }

    static let optionNote = "left for you to choose: keyboard layouts other than U.S. often need Option to type @ [ ] { }"

    /// Option as Meta (both sides in VS Code), the sidebar side and the panel's default position.
    static func optionAndPanels(_ file: SettingsFile, appName: String, usKeyboard: Bool) -> SettingsResult {
        var result = SettingsResult()
        let metaKey = "terminal.integrated.macOptionIsMeta"
        if file.has(metaKey) {
            if let meta = bool(file.value(metaKey)) {
                // Principle 4: unticked off a U.S.-style layout, where Option often types symbols.
                result.settings.append(PlannedSetting(.optionAsMeta(meta), source: "\(metaKey) \(meta)",
                                                      ticked: usKeyboard, note: usKeyboard ? nil : optionNote))
            } else {
                result.skipped.append(SkippedItem(metaKey, notRecognised))
            }
        }
        let sideKey = "workbench.sideBar.location"
        if file.has(sideKey) {
            if let side = string(file.value(sideKey)), ["left", "right"].contains(side) {
                result.settings.append(PlannedSetting(.sidebarSide(side), source: "\(sideKey) \(side)"))
            } else {
                result.skipped.append(SkippedItem(sideKey, notRecognised))
            }
        }
        let panelKey = "workbench.panel.defaultLocation"
        if file.has(panelKey) {
            if let position = string(file.value(panelKey)), ["bottom", "right", "left", "top"].contains(position) {
                // VS Code applies it only to a new workspace; a panel dragged elsewhere leaves no setting.
                result.settings.append(PlannedSetting(.terminalPosition(position), source: "\(panelKey) \(position)",
                                                      note: "\(appName)'s default for new workspaces"))
            } else {
                result.skipped.append(SkippedItem(panelKey, notRecognised))
            }
        }
        return result
    }

    /// Every key the import doesn't map, by name only: the ones §3.1 names get their reason, and the rest
    /// are counted in one row (most settings files hold dozens).
    static func unmappedKeys(_ file: SettingsFile) -> [SkippedItem] {
        var skipped: [SkippedItem] = []
        var others = Set<String>()
        for member in file.members {
            switch disposition(of: member.key) {
            case .mapped: continue
            case .skipped(let reason):
                skipped.append(SecretGuard.looksSecret(member.key) ? SkippedItem("a setting", credential) : SkippedItem(member.key, reason))
            case .other:
                others.insert(member.key)
            }
        }
        if !others.isEmpty { skipped.append(SkippedItem(counted(others.count, "other setting"), "Next Term has no matching setting")) }
        return skipped
    }

    /// Files beside settings.json that are never opened (§3.1, §6.3), reported when they exist.
    static func neverImportedFiles(user: String) -> [SkippedItem] {
        var skipped: [SkippedItem] = []
        let files = [("mcp.json", "never imported: runs commands and can hold secrets"),
                     ("tasks.json", runsCommands), ("launch.json", runsCommands)]
        for (name, reason) in files where FileManager.default.fileExists(atPath: (user as NSString).appendingPathComponent(name)) {
            skipped.append(SkippedItem(name, reason))
        }
        let snippets = (user as NSString).appendingPathComponent("snippets")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: snippets), !entries.isEmpty {
            skipped.append(SkippedItem("snippets", "snippets aren't supported"))
        }
        return skipped
    }

    // MARK: profiles

    /// How many profiles besides the default one `globalStorage/storage.json` lists (`userDataProfiles`
    /// never includes the default). Only the count is kept.
    static func otherProfiles(user: String) -> Int {
        let path = (user as NSString).appendingPathComponent("globalStorage/storage.json")
        guard let text = readText(path, limit: 32 << 20), let document = JSONC(text), case .object(let root)? = document.root,
              let member = root.members.last(where: { $0.key == "userDataProfiles" }), case .array = member.value,
              let profiles = member.value.object(in: text) as? [Any] else { return 0 }
        return profiles.count
    }

    // MARK: recent projects

    static let recentsKey = "history.recentlyOpenedPathsList"
    /// The one statement run on another app's database: a single keyed row, never `SELECT *` (Cursor keeps its
    /// sign-in tokens in the same table).
    static let itemQuery = "SELECT value FROM ItemTable WHERE key = ?1"
    static let recentLimit = 20

    struct Recents {
        var paths: [String] = []
        var skipped: [SkippedItem] = []
    }

    /// Recent folders, newest first. VS Code 1.118 and later keep them in the application-shared storage
    /// (`~/<sharedDataFolderName>/sharedStorage/state.vscdb`, the name from the app's product.json); before
    /// that, and in apps without the name (Cursor), in `User/globalStorage/state.vscdb`, which is also VS
    /// Code's own fallback while the shared one lacks the key.
    static func recentProjects(app: DetectedApp, home: String, applications: [String]) -> Recents {
        var databases: [String] = []
        var notes: [SkippedItem] = []
        let folder = ((app.configPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let bundles = sources.first { $0.folder == folder }?.bundles ?? []
        if let shared = sharedDataFolderName(bundles: bundles, applications: applications) {
            let path = (home as NSString).appendingPathComponent("\(shared)/sharedStorage/state.vscdb")
            if isRegularFile(path) {
                databases.append(path)
            } else {
                // A portable install or --shared-data-dir moves it, and Next Term can't see either.
                notes.append(SkippedItem("recent projects in ~/\(shared)/sharedStorage",
                                         "not found where \(app.name) keeps them; choose the file to bring them over"))
            }
        }
        databases.append((app.configPath as NSString).appendingPathComponent("globalStorage/state.vscdb"))
        for database in databases where isRegularFile(database) {
            switch readItem(database, key: recentsKey) {
            case .missing:
                continue
            case .failed:
                return Recents(skipped: notes + [SkippedItem("recent projects", "couldn't be read; close \(app.name) and try again")])
            case .value(let data):
                var recents = recentProjects(data)
                recents.skipped = notes + recents.skipped
                return recents
            }
        }
        return Recents(skipped: notes)
    }

    /// `sharedDataFolderName` from the first installed app's product.json (only that key is converted), or nil
    /// when the app isn't found or has none. A name that isn't a plain folder name is ignored.
    static func sharedDataFolderName(bundles: [String], applications: [String]) -> String? {
        for folder in applications {
            for bundle in bundles {
                let path = (folder as NSString).appendingPathComponent("\(bundle)/Contents/Resources/app/product.json")
                guard let text = readText(path, limit: 4 << 20), let document = JSONC(text),
                      case .object(let root)? = document.root else { continue }
                guard let member = root.members.last(where: { $0.key == "sharedDataFolderName" }),
                      let name = member.value.object(in: text) as? String,
                      !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != "..",
                      !SecretGuard.looksSecret(name) else { return nil }
                return name
            }
        }
        return nil
    }

    enum ItemRead: Equatable {
        case value(Data)
        case missing
        case failed
    }

    /// One key of an `ItemTable`, read in place: opened read-only by URI (`mode=ro`), one keyed SELECT, closed.
    /// Never copied (a copy would put the other app's tokens on disk) and never `SELECT *`. Read-only and not
    /// immutable, so what is still in the write-ahead log is seen.
    static func readItem(_ path: String, key: String) -> ItemRead {
        guard isRegularFile(path) else { return .failed }
        let attempt = select(path, key: key, immutable: false)
        // A WAL database whose -wal and -shm are gone can't be opened read-only (SQLite would have to create
        // the -shm). With no -wal, every committed row is in the file itself, so an immutable read sees them all.
        guard attempt.read == .failed, attempt.code & 0xFF == SQLITE_CANTOPEN,
              !FileManager.default.fileExists(atPath: path + "-wal") else { return attempt.read }
        return select(path, key: key, immutable: true).read
    }

    /// The SELECT on one read-only connection, and the SQLite result code when it failed.
    private static func select(_ path: String, key: String, immutable: Bool) -> (read: ItemRead, code: Int32) {
        guard let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return (.failed, SQLITE_MISUSE) }
        var db: OpaquePointer?
        let uri = "file:\(escaped)?mode=ro" + (immutable ? "&immutable=1" : "")
        let opened = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let db else {
            sqlite3_close(db)
            return (.failed, opened)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, itemQuery, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { return (.failed, prepared) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let step = sqlite3_step(statement)
        switch step {
        case SQLITE_ROW:
            // VS Code stores text; another build may store a blob. The blob accessor reads both.
            let bytes = sqlite3_column_blob(statement, 0)
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes, count > 0 else { return (.missing, SQLITE_OK) }
            guard count <= 32 << 20 else { return (.failed, SQLITE_TOOBIG) }
            return (.value(Data(bytes: bytes, count: count)), SQLITE_OK)
        case SQLITE_DONE:
            return (.missing, SQLITE_OK)
        default:
            return (.failed, step)
        }
    }

    /// The stored list (`{"entries": [...]}`, VS Code 1.55 and later): `folderUri` entries, and a
    /// workspace's first folder. Files, remote and virtual entries, missing folders and duplicates are dropped.
    static func recentProjects(_ data: Data) -> Recents {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["entries"] as? [Any] else {
            return Recents(skipped: [SkippedItem("recent projects", "couldn't be read")])
        }
        var recents = Recents()
        var seen = Set<String>()
        var remote = 0, secret = 0
        func add(_ path: String) -> Bool {
            let canonical = canonicalPath(path)
            guard isDirectory(canonical), !seen.contains(canonical) else { return false }
            guard !SecretGuard.pathLooksSecret(canonical) else {
                secret += 1
                return false
            }
            seen.insert(canonical)
            recents.paths.append(canonical)
            return true
        }
        for case let entry as [String: Any] in entries where recents.paths.count < recentLimit {
            if let authority = entry["remoteAuthority"] as? String, !authority.isEmpty {
                remote += 1
            } else if let uri = entry["folderUri"] as? String {
                if let path = localPath(uri) { _ = add(path) } else { remote += 1 }
            } else if let workspace = entry["workspace"] as? [String: Any], let uri = workspace["configPath"] as? String {
                guard let file = localPath(uri) else {
                    remote += 1
                    continue
                }
                guard let workspaceFolders = firstFolder(ofWorkspace: file), let folder = workspaceFolders.folder else { continue }
                let others = workspaceFolders.others
                if add(folder), others > 0 {
                    recents.skipped.append(SkippedItem(workspaceName(file), "only a workspace's first folder comes over (\(counted(others, "more folder")) left out)"))
                }
            }
            // fileUri: a file, not a project.
        }
        if remote > 0 { recents.skipped.append(SkippedItem(counted(remote, "remote project"), "remote and virtual folders aren't imported")) }
        if secret > 0 { recents.skipped.append(SkippedItem(counted(secret, "recent project"), credential)) }
        return recents
    }

    /// A `file:` URI's path (percent escapes decoded), or nil for any other scheme or a file URI with a host.
    static func localPath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme?.lowercased() == "file" else { return nil }
        let host = url.host ?? ""
        guard host.isEmpty || host == "localhost" else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? path : nil
    }

    /// The first folder a workspace file lists (a `path`, resolved against the file's folder, or a `file:`
    /// `uri`), and how many others it lists. Only `folders` is converted: its `settings` can hold anything.
    static func firstFolder(ofWorkspace path: String) -> (folder: String?, others: Int)? {
        guard let text = readText(path, limit: 4 << 20), let document = JSONC(text), case .object(let root)? = document.root,
              let member = root.members.last(where: { $0.key == "folders" }),
              let folders = member.value.object(in: text) as? [Any], let first = folders.first as? [String: Any] else { return nil }
        var folder: String?
        if let relative = first["path"] as? String, !relative.isEmpty {
            let base = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
            folder = URL(fileURLWithPath: relative, relativeTo: base).standardizedFileURL.path
        } else if let uri = first["uri"] as? String {
            folder = localPath(uri)
        }
        return (folder, folders.count - 1)
    }

    /// How a workspace file is named in the report: its file name, or "an untitled workspace" for the
    /// workspace.json VS Code keeps for one.
    static func workspaceName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if name == "workspace.json" { return "an untitled workspace" }
        return SecretGuard.looksSecret(name) ? "a workspace" : name
    }

    // MARK: reading

    /// A plain file's text, if it is UTF-8 and at most `limit` bytes. Never a pipe or a device, which could
    /// block the read forever.
    static func readText(_ path: String, limit: Int) -> String? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// A JSON number (not a boolean, which Foundation also hands over as NSNumber).
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A string value, unless it looks like a credential (then it is treated as not recognised and never shown).
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !SecretGuard.looksSecret(text) else { return nil }
        return text
    }

    /// "12", "1.5".
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)
    }

    /// "1 other profile", "3 other profiles".
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

extension SecretGuard {
    /// A path is checked a component at a time: a whole path is one long run of the characters the
    /// high-entropy pattern looks for, so checking it whole would drop most deep project folders.
    static func pathLooksSecret(_ path: String) -> Bool {
        path.split(separator: "/").contains { looksSecret(String($0)) }
    }
}

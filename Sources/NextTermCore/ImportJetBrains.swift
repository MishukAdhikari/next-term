import Foundation

/// Reads a JetBrains IDE's settings (PhpStorm, IntelliJ IDEA, PyCharm… and Android Studio) into an import
/// plan. Design: claudedocs/research_next-term-migration (§2.4 keymaps, §3.2 settings, §4 recents, §5
/// detection, §6 safety). The settings folder also holds licence keys, GitHub tokens and SSH configs, so
/// only the files on `mayOpen`'s allowlist are ever opened, only allowlisted options are kept from them,
/// and nothing is written anywhere.
public enum ImportJetBrains {
    // MARK: Detection

    /// The settings folders of the IDEs on this Mac, newest version of each product, most recently used first.
    /// Found by folder names and modification times; the only file read is the keymap choice, for the preset.
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        detect(home: home, now: Date())
    }

    static func detect(home: String, now: Date) -> [DetectedApp] {
        products(home: home, now: now)
            .map { DetectedApp(kind: .jetBrains, name: $0.displayName, configPath: $0.path, lastUsed: $0.lastUsed,
                               preset: keymap(config: $0.path).preset) }
    }

    /// One `<Product><Version>` settings folder.
    struct Folder {
        let product: String
        let version: [Int]
        let versionText: String
        let path: String
        let lastUsed: Date?

        /// "PhpStorm 2026.1", "Android Studio 2025.3.4".
        var displayName: String { (ImportJetBrains.productNames[product] ?? product) + " " + versionText }
    }

    /// Folder prefixes whose display name is not the prefix itself.
    static let productNames = [
        "IntelliJIdea": "IntelliJ IDEA", "IdeaIC": "IntelliJ IDEA CE", "PyCharmCE": "PyCharm CE",
        "AndroidStudio": "Android Studio", "AndroidStudioPreview": "Android Studio Preview",
    ]

    /// Folders beside the IDEs' that hold no IDE's settings (seen on a real Mac).
    static let notProducts: Set<String> = ["Daemon", "consentOptions", "acp-agents"]
    /// Gateway and its thin client only reach remote machines; their settings are not an editor's.
    static let remoteOnlyProducts: Set<String> = ["JetBrainsGateway", "JetBrainsClient"]

    /// JetBrains' own ConfigImportHelper ignores settings unused this long.
    static let staleAfter: TimeInterval = 180 * 24 * 60 * 60

    /// The folders `detect` offers: unused ones hidden unless nothing else is left, then the newest version
    /// of each product (hiding first, so a recently used older version wins over an abandoned newer one).
    static func products(home: String, now: Date) -> [Folder] {
        let all = settingsFolders(home: home)
        let fresh = all.filter { folder in folder.lastUsed.map { now.timeIntervalSince($0) < staleAfter } ?? false }
        var newest: [String: Folder] = [:]
        for folder in fresh.isEmpty ? all : fresh {
            if let kept = newest[folder.product], !isNewer(folder, than: kept) { continue }
            newest[folder.product] = folder
        }
        return newest.values.sorted { a, b in
            let x = a.lastUsed ?? .distantPast, y = b.lastUsed ?? .distantPast
            return x != y ? x > y : a.displayName < b.displayName
        }
    }

    static func isNewer(_ a: Folder, than b: Folder) -> Bool {
        if a.version != b.version { return b.version.lexicographicallyPrecedes(a.version) }
        return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
    }

    /// Every `JetBrains/<Product><Version>` and `Google/AndroidStudio<Version>` folder that has `options/`.
    static func settingsFolders(home: String) -> [Folder] {
        let support = (home as NSString).appendingPathComponent("Library/Application Support")
        var found: [Folder] = []
        for (vendor, prefix) in [("JetBrains", ""), ("Google", "AndroidStudio")] {
            let base = (support as NSString).appendingPathComponent(vendor)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for name in names.sorted() where !notProducts.contains(name) {
                guard let parsed = splitVersion(name), parsed.product.hasPrefix(prefix),
                      !parsed.product.hasSuffix("Light"), // LightEdit mode's own folder (`phpstorm -e`)
                      !remoteOnlyProducts.contains(parsed.product) else { continue }
                let path = (base as NSString).appendingPathComponent(name)
                let options = (path as NSString).appendingPathComponent("options")
                guard isDirectory(options) else { continue }
                found.append(Folder(product: parsed.product, version: parsed.version, versionText: parsed.text,
                                    path: path, lastUsed: newestXML(in: options)))
            }
        }
        return found
    }

    /// "PhpStorm2026.1" → ("PhpStorm", [2026, 1], "2026.1"); nil for a folder with no version ("Phpstorm").
    static func splitVersion(_ name: String) -> (product: String, version: [Int], text: String)? {
        guard let range = name.range(of: #"[0-9]+(\.[0-9]+)+$"#, options: .regularExpression) else { return nil }
        let product = String(name[..<range.lowerBound])
        guard let first = product.first, first.isLetter, product.last?.isNumber == false else { return nil }
        let text = String(name[range])
        return (product, text.split(separator: ".").compactMap { Int($0) }, text)
    }

    /// When the IDE last saved a setting: the newest `options/*.xml` (only dates are read here).
    static func newestXML(in options: String) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: options) else { return nil }
        return names.filter { $0.hasSuffix(".xml") }.compactMap { name -> Date? in
            let path = (options as NSString).appendingPathComponent(name)
            guard isRegularFile(path) else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: Plan

    /// What importing from `app` would change. Recent projects come from every detected JetBrains IDE,
    /// because each keeps its own list and people move between them. `usKeyboard`: the current layout is
    /// U.S.-style, so Option is not needed to type symbols (§3 principle 4).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true) -> ImportPlan {
        plan(for: app, home: home, usKeyboard: usKeyboard, now: Date())
    }

    /// `fonts`: the fonts this Mac has (tests pass their own).
    static func plan(for app: DetectedApp, home: String, usKeyboard: Bool, now: Date, fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        addKeymap(config: app.configPath, to: &plan)
        addSettings(config: app.configPath, usKeyboard: usKeyboard, fonts: fonts, to: &plan)
        var configs = products(home: home, now: now).map(\.path)
        if !configs.contains(app.configPath) { configs.insert(app.configPath, at: 0) }
        let recents = recentProjects(configs: configs, home: home)
        plan.recentProjects = recents.paths
        plan.skipped += recents.skipped
        return plan
    }

    // MARK: Keymap

    /// JetBrains' macOS keymap, which is what an IDE on a Mac uses until the user picks another.
    static let macOSDefaultKeymap = "Mac OS X 10.5+"

    /// The built-in keymaps of other editors, which the JetBrains preset does not follow.
    static let otherEditorKeymaps = ["eclipse", "sublime", "emacs", "netbeans", "xcode", "visual studio", "resharper",
                                     "gnome", "kde", "xwin"]

    enum KeymapBase: Equatable {
        case macOS, classic, vsCode, other
    }

    struct Keymap {
        /// The keymap chosen in the IDE (nil: never changed, so the macOS default).
        var active: String?
        /// The built-in keymap the active one rests on, after following custom keymaps' parents.
        var baseName: String
        var base: KeymapBase
        /// The user's own keymaps, the active one first and then each one's parent, by name and file
        /// (built-in keymaps have no file here).
        var customs: [(name: String, file: String)] = []

        var preset: KeymapPreset { base == .vsCode ? .vsCode : .jetBrains }
    }

    /// The active keymap from `options/mac/keymap.xml` (then `options/keymap.xml`), followed through
    /// `keymaps/*.xml` parent links to a built-in. Custom keymap files are found by the `name` in each
    /// file, never by building a path from a name, which could hold "../".
    static func keymap(config: String) -> Keymap {
        let active = ["options/mac/keymap.xml", "options/keymap.xml"].lazy.compactMap { file -> String? in
            component(read(config, file), "KeymapManager")?.children.first { $0.name == "active_keymap" }?["name"]
        }.first
        let customs = customKeymaps(config: config)
        var name = active ?? macOSDefaultKeymap
        var chain: [(name: String, file: String)] = []
        while let custom = customs[name], !chain.contains(where: { $0.name == name }), chain.count < 16 {
            chain.append((name, custom.file))
            guard let parent = custom.parent else { break }
            name = parent
        }
        return Keymap(active: active, baseName: name, base: base(of: name), customs: chain)
    }

    /// Custom keymaps by name: the file and its parent keymap. Only each file's root element is read.
    static func customKeymaps(config: String) -> [String: (file: String, parent: String?)] {
        let folder = (config as NSString).appendingPathComponent("keymaps")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [:] }
        var keymaps: [String: (file: String, parent: String?)] = [:]
        for file in names.sorted() where file.hasSuffix(".xml") {
            let relative = "keymaps/" + file
            guard let root = read(config, relative, rootOnly: true), root.name == "keymap", let name = root["name"],
                  keymaps[name] == nil else { continue }
            keymaps[name] = (relative, root["parent"])
        }
        return keymaps
    }

    static func base(of keymap: String) -> KeymapBase {
        let lower = keymap.lowercased()
        if lower.contains("vscode") { return .vsCode }
        if otherEditorKeymaps.contains(where: { lower.contains($0) }) { return .other }
        if keymap == "Mac OS X" { return .classic } // shown as "IntelliJ IDEA Classic"
        if keymap == macOSDefaultKeymap || lower.contains("macos") { return .macOS }
        return .other
    }

    /// The keymap's notes, then the user's own shortcuts from it (ImportJetBrainsKeys.swift).
    static func addKeymap(config: String, to plan: inout ImportPlan) {
        let keymap = keymap(config: config)
        switch keymap.base {
        case .classic:
            plan.skipped.append(SkippedItem("IntelliJ IDEA Classic keys",
                "the JetBrains preset follows JetBrains' macOS keymap: Go to File is ⇧⌘O (⇧⌘N in Classic), ⌘G stays "
                + "Find Next with Go to Line on ⌘L, ⌘W closes the tab, and ⌘Y (Delete Line), F3 and Control keys "
                + "such as ⌃L don't come over"))
        case .other:
            plan.skipped.append(named("Keymap", keymap.baseName,
                reason: "the JetBrains preset follows JetBrains' macOS keymap, so some keys differ from this one"))
        case .macOS, .vsCode:
            break
        }
        addKeymapShortcuts(keymap, config: config, to: &plan)
    }

    // MARK: Settings

    /// Where the editor's font comes from: the colour scheme when it sets its own font, else the IDE's.
    struct EditorFont {
        var file = "options/editor-font.xml"
        var sizeKey = "FONT_SIZE"
        var size: String?
        var spacing: String?
        var family: String?
        var ligatures = false
    }

    static func addSettings(config: String, usKeyboard: Bool, fonts: FontCatalog = .system, to plan: inout ImportPlan) {
        let font = editorFont(config: config)
        var editorSize: Double?
        if let text = font.size {
            if let size = number(text) {
                editorSize = size
                plan.settings.append(fontSizeRow(size, source: "\(font.file) \(font.sizeKey) \(clean(text))"))
            } else {
                plan.skipped.append(SkippedItem("\(font.file) \(font.sizeKey)", "not a font size Next Term can use"))
            }
        }
        if let text = font.spacing {
            if let factor = number(text) {
                let inRange = (1.0...2.0).contains(factor)
                plan.settings.append(PlannedSetting(.lineHeight(clamping: factor), source: "\(font.file) LINE_SPACING \(clean(text))",
                                                    note: inRange ? nil : "Next Term's line height goes from 1.0 to 2.0"))
            } else {
                plan.skipped.append(SkippedItem("\(font.file) LINE_SPACING", "not a line height Next Term can use"))
            }
        }
        if let family = font.family, !family.isEmpty {
            let key = font.file == "options/editor-font.xml" ? "FONT_FAMILY" : "EDITOR_FONT_NAME"
            let row = ImportFonts.row(.editor, list: family, source: "\(font.file) \(key)", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
        if font.ligatures { plan.skipped.append(SkippedItem("Font ligatures", "Next Term has no ligature setting")) }

        let editorKeys: Set<String> = ["USE_SOFT_WRAPS", "SOFT_WRAP_FILE_MASKS", "STRIP_TRAILING_SPACES", "IS_ENSURE_NEWLINE_AT_EOF"]
        let editor = options(component(read(config, "options/editor.xml", keep: editorKeys), "EditorSettings"), keep: editorKeys)
        addSoftWrap(editor, to: &plan)
        addCleanUp(editor, to: &plan)
        addTerminal(config: config, usKeyboard: usKeyboard, editorSize: editorSize, fonts: fonts, to: &plan)
        addRedacted(editor, file: "options/editor.xml", to: &plan)

        if let scheme = activeScheme(config: config) {
            addConsoleColours(config: config, scheme: scheme, to: &plan)
            plan.skipped.append(named("Colour scheme", displaySchemeName(scheme), reason: "colour themes come later"))
        }
        if hasCodeStyle(config: config) {
            plan.skipped.append(SkippedItem("Code style", "indentation settings come later"))
        }
    }

    static func editorFont(config: String) -> EditorFont {
        if let scheme = schemeFont(config: config) { return scheme }
        let keys: Set<String> = ["FONT_SIZE", "FONT_SIZE_2D", "LINE_SPACING", "FONT_FAMILY", "USE_LIGATURES"]
        let defaults = options(component(read(config, "options/editor-font.xml", keep: keys), "DefaultFont"), keep: keys)
        var font = EditorFont()
        if let size = defaults.values["FONT_SIZE"] {
            font.size = size
        } else if let size = defaults.values["FONT_SIZE_2D"] {
            font.size = size
            font.sizeKey = "FONT_SIZE_2D"
        }
        font.spacing = defaults.values["LINE_SPACING"]
        font.family = defaults.values["FONT_FAMILY"]
        font.ligatures = defaults.values["USE_LIGATURES"] == "true"
        return font
    }

    /// The active colour scheme's font, when the scheme sets one ("Use color scheme font instead of the
    /// default"): its `EDITOR_FONT_NAME`, in a `<font>` element or at the top. A scheme with colours only uses
    /// the IDE's font.
    static func schemeFont(config: String) -> EditorFont? {
        let keys: Set<String> = ["EDITOR_FONT_NAME", "EDITOR_FONT_SIZE", "LINE_SPACING", "EDITOR_LIGATURES"]
        guard let name = activeScheme(config: config), let file = schemeFile(config: config, name: name),
              let root = read(config, file, keep: keys), root.name == "scheme" else { return nil }
        let top = options(root, keep: keys).values
        let first = options(root.children.first { $0.name == "font" }, keep: keys).values
        guard let family = first["EDITOR_FONT_NAME"] ?? top["EDITOR_FONT_NAME"] else { return nil }
        return EditorFont(file: file, sizeKey: "EDITOR_FONT_SIZE", size: first["EDITOR_FONT_SIZE"] ?? top["EDITOR_FONT_SIZE"],
                          spacing: top["LINE_SPACING"], family: family, ligatures: top["EDITOR_LIGATURES"] == "true")
    }

    static func activeScheme(config: String) -> String? {
        let manager = component(read(config, "options/colors.scheme.xml"), "EditorColorsManagerImpl")
        guard let name = manager?.children.first(where: { $0.name == "global_color_scheme" })?["name"], !name.isEmpty else { return nil }
        return name
    }

    /// A scheme the user edited is saved as `_@user_<name>`, in a file whose name may be changed to be safe
    /// on disk, so files are matched by the name inside them.
    static func schemeFile(config: String, name: String) -> String? {
        let folder = (config as NSString).appendingPathComponent("colors")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        let wanted: Set<String> = [name, "_@user_" + name]
        return files.sorted().filter { $0.hasSuffix(".icls") }.map { "colors/" + $0 }.first { file in
            guard let root = read(config, file, rootOnly: true), root.name == "scheme", let inside = root["name"] else { return false }
            return wanted.contains(inside)
        }
    }

    static func displaySchemeName(_ name: String) -> String {
        name.hasPrefix("_@user_") ? String(name.dropFirst(7)) : name
    }

    /// Only whether the folder holds a code style: its contents are not read.
    static func hasCodeStyle(config: String) -> Bool {
        let folder = (config as NSString).appendingPathComponent("codestyles")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.hasSuffix(".xml") }
    }

    /// JetBrains' default soft wrap: on in the main editor, for these files only.
    static let defaultSoftWrapMasks = "*.md; *.txt; *.rst; *.adoc"

    /// `USE_SOFT_WRAPS` lists where soft wraps are on (`MAIN_EDITOR`, `CONSOLE`…); missing means the default
    /// (the main editor, for `SOFT_WRAP_FILE_MASKS` only), empty means off everywhere. Next Term wraps every
    /// file or none, so a mask of `*` is the only way to "on" without the places list.
    static func addSoftWrap(_ editor: Options, to plan: inout ImportPlan) {
        let masks = editor.values["SOFT_WRAP_FILE_MASKS"]
        let everyFile = (masks ?? defaultSoftWrapMasks).split(separator: ";")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "*" }
        let file = "options/editor.xml"
        var wraps = false
        if let raw = editor.values["USE_SOFT_WRAPS"] {
            let places = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            wraps = places.contains("MAIN_EDITOR")
            let shown = raw.isEmpty ? "\"\"" : raw.range(of: #"^[A-Z_,]+$"#, options: .regularExpression) != nil ? raw : "…"
            plan.settings.append(PlannedSetting(.softWrap(wraps), source: "\(file) USE_SOFT_WRAPS \(shown)"))
        } else if everyFile {
            wraps = true
            plan.settings.append(PlannedSetting(.softWrap(true), source: "\(file) SOFT_WRAP_FILE_MASKS *"))
        } else if masks == nil {
            return // the IDE's default, which says nothing about the user
        }
        guard !everyFile, wraps || editor.values["USE_SOFT_WRAPS"] == nil else { return }
        plan.skipped.append(named("Soft wrap only for", masks ?? defaultSoftWrapMasks, reason: "Next Term wraps every file or none"))
    }

    /// "Strip trailing spaces on Save" (`STRIP_TRAILING_SPACES`: None, Changed or Whole; missing is Changed, the
    /// IDE's default) and "Ensure every saved file ends with a line break". Next Term trims whole files only, so
    /// Changed is offered unticked.
    static func addCleanUp(_ editor: Options, to plan: inout ImportPlan) {
        let file = "options/editor.xml"
        switch editor.values["STRIP_TRAILING_SPACES"] {
        case "Whole"?:
            plan.settings.append(PlannedSetting(.trimTrailingWhitespace(true), source: "\(file) STRIP_TRAILING_SPACES Whole"))
        case "None"?:
            plan.settings.append(PlannedSetting(.trimTrailingWhitespace(false), source: "\(file) STRIP_TRAILING_SPACES None"))
        case "Changed"?:
            plan.settings.append(PlannedSetting(.trimTrailingWhitespace(true), source: "\(file) STRIP_TRAILING_SPACES Changed", ticked: false,
                                                note: "the IDE trims only the lines you changed; Next Term trims every line of the file"))
        case nil:
            break
        default:
            plan.skipped.append(SkippedItem("\(file) STRIP_TRAILING_SPACES", "not a value Next Term can use"))
        }
        switch editor.values["IS_ENSURE_NEWLINE_AT_EOF"] {
        case "true"?: plan.settings.append(PlannedSetting(.insertFinalNewline(true), source: "\(file) IS_ENSURE_NEWLINE_AT_EOF true"))
        case "false"?: plan.settings.append(PlannedSetting(.insertFinalNewline(false), source: "\(file) IS_ENSURE_NEWLINE_AT_EOF false"))
        default: break
        }
    }

    static func addTerminal(config: String, usKeyboard: Bool, editorSize: Double?, fonts: FontCatalog = .system, to plan: inout ImportPlan) {
        let terminalKeys: Set<String> = ["useOptionAsMetaKey"]
        let terminal = options(component(read(config, "options/terminal.xml", keep: terminalKeys), "TerminalOptionsProvider"),
                               keep: terminalKeys)
        if let value = terminal.values["useOptionAsMetaKey"]?.lowercased() {
            if value == "true" || value == "false" {
                let on = value == "true"
                // JetBrains turns both Option keys into Meta, so only the layout can make this risky.
                let ticked = !on || usKeyboard
                plan.settings.append(PlannedSetting(.optionAsMeta(on), source: "options/terminal.xml useOptionAsMetaKey \(value)",
                    ticked: ticked, note: ticked ? nil : "Many keyboard layouts need Option to type @ [ ] { }; tick this if yours doesn't"))
            } else {
                plan.skipped.append(SkippedItem("options/terminal.xml useOptionAsMetaKey", "not a value Next Term can use"))
            }
        }
        for key in terminal.others where key.lowercased().contains("shellpath") {
            plan.skipped.append(SkippedItem("options/terminal.xml \(key)", "never imported: it runs a program"))
        }
        addRedacted(terminal, file: "options/terminal.xml", to: &plan)

        let fontKeys: Set<String> = ["FONT_SIZE", "FONT_SIZE_2D", "FONT_FAMILY"]
        let font = options(component(read(config, "options/terminal-font.xml", keep: fontKeys), "TerminalFontOptions"), keep: fontKeys)
        let sizeKey = font.values["FONT_SIZE"] != nil ? "FONT_SIZE" : "FONT_SIZE_2D"
        if let text = font.values[sizeKey] {
            if let size = number(text) {
                if editorSize == nil {
                    plan.settings.append(fontSizeRow(size, source: "options/terminal-font.xml \(sizeKey) \(clean(text))"))
                } else if let editorSize, editorSize.rounded() != size.rounded() {
                    plan.skipped.append(SkippedItem("Terminal font size \(clean(text))",
                        "Next Term uses one size for the editor and the terminal, so the editor's \(clean(String(editorSize))) is used"))
                }
            } else {
                plan.skipped.append(SkippedItem("options/terminal-font.xml \(sizeKey)", "not a font size Next Term can use"))
            }
        }
        if let family = font.values["FONT_FAMILY"], !family.isEmpty {
            let row = ImportFonts.row(.terminal, list: family, source: "options/terminal-font.xml FONT_FAMILY", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
    }

    // MARK: Console colours

    /// The scheme's console colours for ANSI 0–15, in order. JetBrains calls white "gray", bright black
    /// "dark gray" and bright white "white".
    static let consoleColourKeys = [
        "CONSOLE_BLACK_OUTPUT", "CONSOLE_RED_OUTPUT", "CONSOLE_GREEN_OUTPUT", "CONSOLE_YELLOW_OUTPUT",
        "CONSOLE_BLUE_OUTPUT", "CONSOLE_MAGENTA_OUTPUT", "CONSOLE_CYAN_OUTPUT", "CONSOLE_GRAY_OUTPUT",
        "CONSOLE_DARKGRAY_OUTPUT", "CONSOLE_RED_BRIGHT_OUTPUT", "CONSOLE_GREEN_BRIGHT_OUTPUT", "CONSOLE_YELLOW_BRIGHT_OUTPUT",
        "CONSOLE_BLUE_BRIGHT_OUTPUT", "CONSOLE_MAGENTA_BRIGHT_OUTPUT", "CONSOLE_CYAN_BRIGHT_OUTPUT", "CONSOLE_WHITE_OUTPUT",
    ]

    /// Colours of the whole scheme the terminal uses too: its background, the caret and the selection.
    static let schemeColourKeys = ["CONSOLE_BACKGROUND_KEY", "CARET_COLOR", "SELECTION_BACKGROUND"]

    /// The terminal colours the active scheme sets, when the scheme is a file in `colors/` (one the user
    /// made or edited). A built-in scheme isn't on disk; what a scheme doesn't set stays Next Term's.
    static func addConsoleColours(config: String, scheme: String, to plan: inout ImportPlan) {
        var keep = Set(consoleColourKeys + schemeColourKeys)
        keep.formUnion(["CONSOLE_NORMAL_OUTPUT", "FOREGROUND"])
        guard let file = schemeFile(config: config, name: scheme), let root = read(config, file, keep: keep), root.name == "scheme" else { return }
        let colours = options(root.children.first { $0.name == "colors" }, keep: Set(schemeColourKeys)).values
        var foregrounds: [String: String] = [:]
        for option in root.children.first(where: { $0.name == "attributes" })?.children ?? [] where option.name == "option" {
            guard let name = option["name"], keep.contains(name) else { continue }
            let value = option.children.first { $0.name == "value" }
            if let text = options(value, keep: ["FOREGROUND"]).values["FOREGROUND"] { foregrounds[name] = text }
        }
        var palette = TerminalPalette(name: "\(displaySchemeName(scheme)) console colours")
        var unreadable: [String] = []
        func colour(_ key: String, _ text: String?) -> UInt32? {
            guard let text else { return nil }
            guard let rgb = schemeColour(text) else {
                unreadable.append(key)
                return nil
            }
            return rgb
        }
        for (slot, key) in consoleColourKeys.enumerated() { palette.ansi[slot] = colour(key, foregrounds[key]) }
        palette.foreground = colour("CONSOLE_NORMAL_OUTPUT", foregrounds["CONSOLE_NORMAL_OUTPUT"])
        palette.background = colour("CONSOLE_BACKGROUND_KEY", colours["CONSOLE_BACKGROUND_KEY"])
        palette.cursor = colour("CARET_COLOR", colours["CARET_COLOR"])
        palette.selection = colour("SELECTION_BACKGROUND", colours["SELECTION_BACKGROUND"])
        let note = "colours the scheme doesn't set come from its parent in the IDE, which can't be read here"
        if let row = ImportColours.row(palette, source: "\(file) console colours", note: palette.count < 20 ? note : nil) {
            plan.settings.append(row)
        }
        for key in unreadable { plan.skipped.append(SkippedItem("\(file) \(key)", "not a colour Next Term can read")) }
    }

    /// A scheme colour: hex without "#", and JetBrains drops leading zeros ("ff" is 0x0000FF).
    static func schemeColour(_ text: String) -> UInt32? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard (1...6).contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }

    /// Options whose names say they can hold a secret: named in the preview, their values never read.
    static func addRedacted(_ options: Options, file: String, to plan: inout ImportPlan) {
        for key in options.redacted {
            plan.skipped.append(SkippedItem("\(file) \(key)", "never imported: can hold secrets"))
        }
    }

    static func fontSizeRow(_ size: Double, source: String) -> PlannedSetting {
        let inRange = (8...32).contains(size.rounded())
        return PlannedSetting(.fontSize(clamping: size), source: source, note: inRange ? nil : "Next Term's sizes go from 8 to 32")
    }

    /// A positive, finite number ("14", "13.5", "1.2"); nil for anything else ("nan", "-1", "big").
    static func number(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// "14.0" → "14", for a source label (the text is already known to be a number).
    static func clean(_ text: String) -> String {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), abs(value) < 1e9 else { return text }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Recent projects

    /// Each IDE keeps at most this many; more would only bury Next Term's own.
    static let recentLimit = 20

    struct Recent {
        let path: String
        /// When it was last brought to the front (ms since 1970), else when it was opened, else 0.
        let stamp: Int64
    }

    /// Recent folders from every `configs` IDE, newest first: `$USER_HOME$` expanded, hidden ones and remote
    /// ones left out, canonical, existing, and each folder once (at its newest time in any IDE).
    static func recentProjects(configs: [String], home: String) -> (paths: [String], skipped: [SkippedItem]) {
        var newest: [String: Int64] = [:]
        var missing = Set<String>(), remote = Set<String>(), secret = Set<String>()
        for config in configs {
            let found = recentEntries(config: config, home: home)
            remote.formUnion(found.remote)
            for entry in found.entries {
                let path = canonicalPath(entry.path)
                if pathLooksSecret(path) {
                    secret.insert(path)
                } else if !isDirectory(path) {
                    missing.insert(path)
                } else {
                    newest[path] = max(newest[path] ?? .min, entry.stamp)
                }
            }
        }
        let sorted = newest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var skipped: [SkippedItem] = []
        if !missing.isEmpty {
            skipped.append(SkippedItem(plural(missing.count, "recent project", "recent projects"), "the folder no longer exists"))
        }
        if !remote.isEmpty {
            skipped.append(SkippedItem(plural(remote.count, "remote project", "remote projects"), "remote projects aren't supported yet"))
        }
        if !secret.isEmpty {
            skipped.append(SkippedItem(plural(secret.count, "recent project", "recent projects"), "looked like a credential"))
        }
        if sorted.count > recentLimit {
            skipped.append(SkippedItem(plural(sorted.count - recentLimit, "older recent project", "older recent projects"),
                                       "only the \(recentLimit) most recent come over"))
        }
        return (Array(sorted.prefix(recentLimit)), skipped)
    }

    /// `options/recentProjects.xml` → `RecentProjectsManager` → `additionalInfo` map: one entry per project,
    /// keyed by its folder. `remote`: entries that are not a folder on this Mac.
    static func recentEntries(config: String, home: String) -> (entries: [Recent], remote: Set<String>) {
        let times: Set<String> = ["activationTimestamp", "projectOpenTimestamp"]
        let manager = component(read(config, "options/recentProjects.xml", keep: times.union(["additionalInfo"])), "RecentProjectsManager")
        let info = manager?.children.first { $0.name == "option" && $0["name"] == "additionalInfo" }
        guard let map = info?.children.first(where: { $0.name == "map" }) else { return ([], []) }
        var entries: [Recent] = [], remote = Set<String>()
        for entry in map.children where entry.name == "entry" {
            guard let key = entry["key"] else { continue }
            let meta = entry.children.first { $0.name == "value" }?.children.first { $0.name == "RecentProjectMetaInfo" }
            if meta?["hidden"] == "true" { continue }
            guard let path = expand(key, home: home) else {
                remote.insert(key)
                continue
            }
            let values = options(meta, keep: times).values
            let stamps: [Int64] = ["activationTimestamp", "projectOpenTimestamp"].compactMap { key in
                values[key].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            }
            entries.append(Recent(path: path, stamp: stamps.first(where: { $0 > 0 }) ?? 0))
        }
        return (entries, remote)
    }

    /// "$USER_HOME$/Code/app" → "<home>/Code/app". Nil for anything that is not a local absolute path: other
    /// macros, URLs (`ssh://`, `file://`), and `//host/share` paths.
    static func expand(_ key: String, home: String) -> String? {
        var path = key
        if path == "$USER_HOME$" || path.hasPrefix("$USER_HOME$/") { path = home + path.dropFirst("$USER_HOME$".count) }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("$"), !path.contains("://") else { return nil }
        return path
    }

    /// The secret guard, one folder name at a time: its long-token pattern also matches "/", so a whole
    /// path deep enough would look like a credential.
    static func pathLooksSecret(_ path: String) -> Bool {
        path.split(separator: "/").contains { SecretGuard.looksSecret(String($0)) }
    }

    // MARK: Reading files safely

    /// Settings files a plan may read, relative to the IDE's settings folder.
    static let settingsFiles: Set<String> = [
        "options/editor-font.xml", "options/editor.xml", "options/terminal.xml", "options/terminal-font.xml",
        "options/keymap.xml", "options/mac/keymap.xml", "options/recentProjects.xml", "options/colors.scheme.xml",
    ]

    /// Files beside them that hold credentials, hosts or connection details (§6.3).
    static let neverOpen: Set<String> = [
        "security.xml", "c.kdbx", "github.xml", "gitlab.xml", "sshConfigs.xml", "remote-servers.xml", "webServers.xml",
        "app-internal-state.db",
    ]
    static let neverOpenFolders: Set<String> = ["workspace", "settingsSync"]

    /// Whether a path inside the settings folder may be opened: one of `settingsFiles`, a `keymaps/*.xml` or
    /// a `colors/*.icls`, and never a file on the deny list, whatever it is called.
    static func mayOpen(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let file = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        if neverOpen.contains(file) || file.hasSuffix(".key") || file.hasSuffix(".license")
            || file.lowercased().hasPrefix("datasource") || parts.contains(where: { neverOpenFolders.contains($0) }) {
            return false
        }
        if settingsFiles.contains(relative) { return true }
        return parts.count == 2 && ((parts[0] == "keymaps" && file.hasSuffix(".xml")) || (parts[0] == "colors" && file.hasSuffix(".icls")))
    }

    /// Settings files are a few KiB; anything far bigger is not one.
    static let maxFileSize = 4 << 20

    /// An allowlisted file as an element tree (nil when it is missing, too big or not well-formed XML).
    /// Only the `<option>`s named in `keep` keep their values and children; every other option is reduced
    /// to its name while parsing. `rootOnly`: stop at the first element (to learn a keymap's or scheme's name).
    static func read(_ config: String, _ relative: String, keep: Set<String> = [], rootOnly: Bool = false) -> Node? {
        guard mayOpen(relative) else { return nil }
        let path = (config as NSString).appendingPathComponent(relative)
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: rootOnly ? 16384 : maxFileSize + 1),
              rootOnly || data.count <= maxFileSize else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let builder = TreeBuilder(keep: keep, rootOnly: rootOnly)
        parser.delegate = builder
        let complete = parser.parse()
        return complete || rootOnly ? builder.root : nil
    }

    /// An XML element with its attributes and child elements (text is never kept).
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        /// An option whose name says it can hold a secret: its value and children were dropped unread.
        let redacted: Bool

        init(name: String, attributes: [String: String], redacted: Bool) {
            self.name = name
            self.attributes = attributes
            self.redacted = redacted
        }

        subscript(attribute: String) -> String? { attributes[attribute] }
    }

    /// Builds `Node`s, reducing each `<option>` or `<property>` that is not in `keep` to its name as soon as
    /// the parser reaches it, so values outside the allowlist (environment variables, tokens, shell commands)
    /// never enter a tree. Secret-named ones are marked, for the preview to name.
    final class TreeBuilder: NSObject, XMLParserDelegate {
        let keep: Set<String>
        let rootOnly: Bool
        var root: Node?
        private var stack: [Node] = []
        private var skipping = 0

        init(keep: Set<String>, rootOnly: Bool) {
            self.keep = keep
            self.rootOnly = rootOnly
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if skipping > 0 {
                skipping += 1
                return
            }
            let isOption = elementName == "option" || elementName == "property"
            let name = attributes["name"] ?? ""
            let secret = isOption && SecretGuard.isSecretKey(name)
            let reduced = isOption && (secret || !keep.contains(name))
            let node = Node(name: elementName, attributes: reduced ? ["name": name] : attributes, redacted: secret)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
            if rootOnly {
                parser.abortParsing()
            } else if reduced {
                skipping = 1
            } else {
                stack.append(node)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if skipping > 0 {
                skipping -= 1
            } else {
                _ = stack.popLast()
            }
        }
    }

    /// `<component name="…">` directly under a settings file's root.
    static func component(_ root: Node?, _ name: String) -> Node? {
        root?.children.first { $0.name == "component" && $0["name"] == name }
    }

    struct Options {
        /// Values of the allowlisted options that are set.
        var values: [String: String] = [:]
        /// Names of the other options (their values are not kept).
        var others: [String] = []
        /// Names of options dropped unread because they can hold secrets.
        var redacted: [String] = []
    }

    /// The `<option name= value=>` children of `node`, keeping values only for `keep`.
    static func options(_ node: Node?, keep: Set<String>) -> Options {
        var result = Options()
        for option in node?.children ?? [] where option.name == "option" {
            guard let name = option["name"] else { continue }
            if option.redacted {
                result.redacted.append(name)
            } else if keep.contains(name) {
                if result.values[name] == nil, let value = option["value"] { result.values[name] = value }
            } else {
                result.others.append(name)
            }
        }
        return result
    }

    // MARK: Text

    /// A skipped item that shows a value from the file, unless the value looks like a credential.
    static func named(_ label: String, _ value: String, reason: String) -> SkippedItem {
        SecretGuard.looksSecret(value) ? SkippedItem(label, "looked like a credential") : SkippedItem("\(label) “\(value)”", reason)
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) " + (count == 1 ? one : many)
    }
}

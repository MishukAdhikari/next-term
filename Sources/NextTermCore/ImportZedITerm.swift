import Foundation

// Importers for Zed (its base keymap and fonts) and iTerm2 (font, size, the Option keys and colours).
// Design: claudedocs/research_next-term-migration (Zed §2.4 and §3.3, iTerm2 §3.4, detection §5, safety §6).
// Each reads one allowlisted file through a read handle, takes only the values it maps, and names what
// else it saw in `skipped`. Values of keys that can hold secrets are never looked at: the plan names the
// key only. Nothing is written and nothing is run.

/// Zed keeps its settings in `~/.config/zed/settings.json` on macOS (JSONC; `paths.rs`). The import reads
/// `base_keymap` and the fonts, plus `vim_mode`/`helix_mode` so they can be reported. The other settings
/// come in Phase 2b.
public enum ImportZed {
    /// Zed's settings folder (the same for every release channel).
    public static func settingsFolder(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".config/zed")
    }

    /// Zed, when its settings file exists. Last use is the newest of that file and Zed's own database, which
    /// Zed writes whenever it runs (dates only: neither file is opened).
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        let folder = settingsFolder(home: home)
        let settings = (folder as NSString).appendingPathComponent("settings.json")
        guard isRegularFile(settings) else { return [] }
        let dates = ([settings] + databaseFiles(home: home)).compactMap(ImportFile.modificationDate)
        return [DetectedApp(kind: .zed, name: "Zed", configPath: folder, lastUsed: dates.max())]
    }

    /// The preset from `base_keymap`, the editor's and terminal's fonts, and what Zed has that isn't brought
    /// over. Recent projects stay empty. `fonts`: the fonts this Mac has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .zed else { return plan }
        let folder = app.configPath.isEmpty ? settingsFolder(home: home) : app.configPath
        switch settings((folder as NSString).appendingPathComponent("settings.json")) {
        case .unreadable:
            plan.skipped.append(SkippedItem("settings.json", "couldn't be read, so no settings came over"))
        case .invalid:
            plan.skipped.append(SkippedItem("settings.json", "isn't valid JSON, so no settings came over"))
        case .members(let members, text: let text):
            let raw = members.first { $0.key == "base_keymap" }.flatMap { $0.value.object(in: text) }
            let (preset, note) = preset(baseKeymap: raw)
            plan.preset = preset
            if let note { plan.skipped.append(note) }
            let families = fontFamilies(members, in: text, fonts: fonts)
            plan.settings += families.settings
            plan.skipped += families.skipped
            plan.skipped += report(members, in: text)
        }
        if let count = keyBindingCount((folder as NSString).appendingPathComponent("keymap.json")), count > 0 {
            plan.skipped.append(SkippedItem("keymap.json (\(count) shortcut\(count == 1 ? "" : "s"))",
                                            "your own Zed shortcuts come in a later version"))
        }
        if !databaseFiles(home: home).isEmpty {
            plan.skipped.append(SkippedItem("recent projects", "Zed's recent projects come in a later version"))
        }
        return plan
    }

    // MARK: base_keymap

    /// The preset for a `base_keymap` value (nil: not set), with a note unless the match is exact. Notes
    /// never name the value: only VS Code and JetBrains have presets here, and naming the others would
    /// read as a promise.
    static func preset(baseKeymap value: Any?) -> (KeymapPreset, SkippedItem?) {
        guard let value else {
            // Not set: Zed's own default keymap ("Zed").
            return (.nextTerm, SkippedItem("Zed's own shortcuts", "there is no Zed preset, so Next Term's shortcuts stay"))
        }
        switch value as? String {
        case "VSCode": return (.vsCode, nil)
        case "JetBrains": return (.jetBrains, nil)
        case "Cursor":
            // Zed's Cursor keymap is VS Code's plus the AI keys, which have nothing to land on here.
            return (.vsCode, SkippedItem("Cursor's AI shortcuts", "AI commands have no match here; the rest use VS Code keys"))
        case "Zed":
            return (.nextTerm, SkippedItem("Zed's own shortcuts", "there is no Zed preset, so Next Term's shortcuts stay"))
        case "None":
            return (.nextTerm, SkippedItem("base_keymap", "Zed is set to use only your own shortcuts, so Next Term's shortcuts stay"))
        default:
            // SublimeText, Atom, TextMate, Emacs, or a value a newer Zed added.
            return (.nextTerm, SkippedItem("base_keymap", "this keymap has no preset here, so Next Term's shortcuts stay"))
        }
    }

    // MARK: fonts

    /// `buffer_font_family` for the editor, and `terminal.font_family` for the terminal, which Zed's
    /// terminal falls back to the buffer font without. Zed's own fonts (".ZedMono") come with Zed only.
    static func fontFamilies(_ members: [JSONC.Member], in text: String, fonts: FontCatalog) -> (settings: [PlannedSetting], skipped: [SkippedItem]) {
        var settings: [PlannedSetting] = []
        var skipped: [SkippedItem] = []
        func family(_ member: JSONC.Member?, _ key: String) -> String? {
            guard let member else { return nil }
            guard let name = member.value.object(in: text) as? String else {
                skipped.append(SkippedItem(key, "value not recognised"))
                return nil
            }
            guard !name.hasPrefix(".") else {
                if !SecretGuard.looksSecret(name) { skipped.append(SkippedItem("\(key) “\(name)”", "Zed's own font, which only Zed has")) }
                return nil
            }
            return name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        }
        let editor = family(members.last { $0.key == "buffer_font_family" }, "buffer_font_family")
        var terminalMember: JSONC.Member?
        if let terminal = members.last(where: { $0.key == "terminal" }), case .object(let object) = terminal.value {
            terminalMember = object.members.last { $0.key == "font_family" }
        }
        let terminal = family(terminalMember, "terminal.font_family")
        if let editor {
            let row = ImportFonts.row(.editor, list: editor, source: "buffer_font_family", fonts: fonts)
            settings += [row.setting].compactMap { $0 }
            skipped += row.skipped
        }
        if let terminal {
            let row = ImportFonts.row(.terminal, list: terminal, source: "terminal.font_family", fonts: fonts)
            settings += [row.setting].compactMap { $0 }
            skipped += row.skipped
        } else if let editor, terminalMember == nil {
            let note = "Zed's terminal uses the buffer font while terminal.font_family is unset"
            let row = ImportFonts.row(.terminal, list: editor, source: "buffer_font_family", fonts: fonts, note: note)
            settings += [row.setting].compactMap { $0 }
        }
        return (settings, skipped)
    }

    // MARK: reporting the rest

    static let later = "comes in a later version"
    static let fallbacks = "font fallbacks aren't supported"
    static let colours = "colour themes come later"
    static let secrets = "never imported: can hold secrets"

    /// Keys whose values are never looked at, whatever they hold: they run commands, hold credentials or
    /// configure agents (§3.3). Matched as well as anything `SecretGuard.isSecretKey` matches.
    static let neverRead: Set<String> = ["context_servers", "language_models", "agent", "agent_servers", "shell", "env"]

    /// Top-level settings with a reason of their own (the rest are listed together).
    static let reasons: [String: String] = [
        "buffer_font_size": later, "buffer_line_height": later, "soft_wrap": later,
        "buffer_font_fallbacks": fallbacks,
        "theme": colours, "theme_overrides": colours, "experimental.theme_overrides": colours,
        "ui_font_size": "Next Term's window text follows macOS", "ui_font_family": "Next Term's window text follows macOS",
    ]

    /// Inside `terminal` and `project_panel`, only these are named (§3.3's Phase 2b rows).
    static let nestedReasons: [String: [String: String]] = [
        "terminal": ["option_as_meta": later, "dock": later, "font_size": later, "line_height": later,
                     "working_directory": later, "font_fallbacks": fallbacks],
        "project_panel": ["dock": later],
    ]

    /// One skipped row per setting v1 saw and doesn't bring over, in the file's order, with the
    /// unmapped ones gathered into a single row. Only key names leave this function.
    static func report(_ members: [JSONC.Member], in text: String) -> [SkippedItem] {
        var items: [SkippedItem] = []
        var others: [String] = []
        for member in members where member.key != "base_keymap" && member.key != "buffer_font_family" {
            let key = member.key
            if isNeverRead(key) {
                items.append(SkippedItem(key, secrets))
            } else if key == "vim_mode" || key == "helix_mode" {
                // A plain `true` only (Zed rejects anything else); `false` is nothing to report.
                if text[member.value.range] == "true" {
                    items.append(SkippedItem(key, key == "vim_mode" ? "Next Term has no Vim mode" : "Next Term has no Helix mode"))
                }
            } else if let reason = reasons[key] {
                items.append(SkippedItem(key, reason))
            } else if let nested = nestedReasons[key], case .object(let object) = member.value {
                for inner in object.members {
                    let name = key + "." + inner.key
                    if isNeverRead(inner.key) {
                        items.append(SkippedItem(name, secrets))
                    } else if let reason = nested[inner.key] {
                        items.append(SkippedItem(name, reason))
                    }
                }
            } else if !SecretGuard.looksSecret(key) {
                others.append(key)
            }
        }
        if !others.isEmpty {
            let shown = others.prefix(12).joined(separator: ", ") + (others.count > 12 ? " and \(others.count - 12) more" : "")
            items.append(SkippedItem("other settings: " + shown, "no matching Next Term setting yet"))
        }
        return items
    }

    static func isNeverRead(_ key: String) -> Bool { neverRead.contains(key) || SecretGuard.isSecretKey(key) }

    // MARK: files

    enum Settings {
        case unreadable, invalid
        /// The top-level members (positions only: no value is converted until asked for).
        case members([JSONC.Member], text: String)
    }

    static func settings(_ path: String) -> Settings {
        guard let text = ImportFile.text(path) else { return .unreadable }
        // A file of comments only (as Zed first writes it) is an empty settings object.
        if JSONC.plain(text)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return .members([], text: text) }
        guard let document = JSONC(text), case .object(let root)? = document.root else { return .invalid }
        return .members(root.members, text: text)
    }

    /// How many shortcuts `keymap.json` binds (nil: no such file, or not valid). Only the keys of each
    /// `bindings` object are counted; what they are bound to (text a terminal would receive, say) is never looked at.
    static func keyBindingCount(_ path: String) -> Int? {
        guard let text = ImportFile.text(path), let plain = JSONC.plain(text),
              let sections = (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) as? [Any] else { return nil }
        return sections.reduce(0) { count, section in
            count + (((section as? [String: Any])?["bindings"] as? [String: Any])?.count ?? 0)
        }
    }

    /// Zed's databases (`~/Library/Application Support/Zed/db/0-<channel>/db.sqlite`, `db.rs`) that exist.
    /// Listed for their dates and to say recents exist; v1 never opens them.
    static func databaseFiles(home: String) -> [String] {
        let base = (home as NSString).appendingPathComponent("Library/Application Support/Zed/db")
        guard let channels = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return channels.filter { $0.hasPrefix("0-") }.sorted().flatMap { channel -> [String] in
            let folder = (base as NSString).appendingPathComponent(channel)
            return ["db.sqlite", "db.sqlite-wal"].map { (folder as NSString).appendingPathComponent($0) }.filter(isRegularFile)
        }
    }
}

/// iTerm2 keeps everything in one preferences plist (binary or XML). The default profile's font, its size,
/// the Option keys and the colours come over; the start folder and scrollback wait for their settings (§3.5).
public enum ImportITerm2 {
    public static func preferencesPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
    }

    /// iTerm2, when its preferences file exists; last use is that file's date (it isn't opened).
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        let path = preferencesPath(home: home)
        guard isRegularFile(path) else { return [] }
        return [DetectedApp(kind: .iTerm2, name: "iTerm2", configPath: path, lastUsed: ImportFile.modificationDate(path))]
    }

    /// The font, its size, Option as Meta and the colours from the default profile, and what else it saw. The
    /// preset is Next Term's own, whose keys already match iTerm2's ⌘D, ⇧⌘D, ⌘K, ⌥⌘ arrows and ⇧⌘↩.
    /// `fonts`: the fonts this Mac has (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .iTerm2 else { return plan }
        let path = app.configPath.isEmpty ? preferencesPath(home: home) : app.configPath
        guard let data = ImportFile.data(path), let preferences = Preferences(data) else {
            plan.skipped.append(SkippedItem((path as NSString).lastPathComponent, "couldn't be read, so no settings came over"))
            plan.skipped.append(paneKeys)
            return plan
        }
        if let profile = preferences.profile {
            var fontItems: [SkippedItem] = []
            let font = fontSize(profile, skipped: &fontItems)
            let family = fontFamily(profile, fonts: fonts)
            let colours = profile.palette.flatMap { coloursRow($0, profile: profile) }
            plan.settings = [font, family.setting, optionAsMeta(profile, usKeyboard: usKeyboard), colours].compactMap { $0 }
            plan.skipped += fontItems + family.skipped + later(profile)
        } else {
            plan.skipped.append(SkippedItem("profiles", "iTerm2 has no saved profile yet, so no settings came over"))
        }
        if preferences.globalKeyMappings > 0 {
            let count = preferences.globalKeyMappings
            plan.skipped.append(SkippedItem("iTerm2 key mappings (\(count))", "terminal key mappings aren't brought over"))
        }
        plan.skipped.append(paneKeys)
        return plan
    }

    /// iTerm2's Next/Previous Pane keys are Indent/Outdent here (§2.2).
    static let paneKeys = SkippedItem("⌘] and ⌘[ (Next and Previous Pane in iTerm2)",
                                      "they indent and outdent here; ⌥⌘] and ⌥⌘[ move between panes")

    // MARK: reading

    /// The only profile values the import looks at. Everything else in the plist (commands, triggers, key
    /// maps, bound hosts, AI keys) is dropped as soon as the file is parsed, never converted or kept.
    struct Profile: Equatable {
        var normalFont: String?
        /// "Option Key Sends" and "Right Option Key Sends": 0 Normal, 1 Meta, 2 Esc+ (`ITAddressBookMgr.h`).
        var leftOption = 0
        var rightOption = 0
        /// The colours it sets (nil: none), the Dark variants when it keeps separate light and dark ones.
        var palette: TerminalPalette?
        var darkVariants = false
        /// Some colours were given in Display P3 or a calibrated space, and are read as sRGB.
        var otherColourSpace = false
        /// "Custom Directory": No, Yes, Recycle or Advanced (the folder itself isn't read in v1).
        var customDirectory: String?
        var scrollbackLines: Int?
        var unlimitedScrollback = false
    }

    struct Preferences: Equatable {
        var profile: Profile?
        /// How many entries `GlobalKeyMap` has (counted, never read).
        var globalKeyMappings = 0

        init?(_ data: Data) {
            guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
                return nil
            }
            globalKeyMappings = (root["GlobalKeyMap"] as? [String: Any])?.count ?? 0
            profile = ImportITerm2.defaultProfile(root).map(ImportITerm2.profile)
        }
    }

    /// The profile keys the import reads (checked by a test against `SecretGuard` and the never-read list).
    static let profileKeys = ["Guid", "Normal Font", "Option Key Sends", "Right Option Key Sends", "Custom Directory",
                              "Scrollback Lines", "Unlimited Scrollback", "Use Separate Colors for Light and Dark Mode"]
    /// The colours read, by palette slot: the 16 ANSI colours, then text, background, cursor and selection.
    static let colourKeys = (0...15).map { "Ansi \($0) Color" } + ["Foreground Color", "Background Color", "Cursor Color", "Selection Color"]

    /// The profile `Default Bookmark Guid` names in `New Bookmarks`, else the first one.
    static func defaultProfile(_ root: [String: Any]) -> [String: Any]? {
        let profiles = (root["New Bookmarks"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let guid = root["Default Bookmark Guid"] as? String
        return profiles.first { guid != nil && $0["Guid"] as? String == guid } ?? profiles.first
    }

    static func profile(_ values: [String: Any]) -> Profile {
        func option(_ key: String) -> Int {
            guard let value = values[key] as? Int, (0...2).contains(value) else { return 0 }
            return value
        }
        var profile = Profile()
        profile.normalFont = values["Normal Font"] as? String
        profile.leftOption = option("Option Key Sends")
        profile.rightOption = option("Right Option Key Sends")
        readColours(values, into: &profile)
        let directory = values["Custom Directory"] as? String
        profile.customDirectory = ["No", "Yes", "Recycle", "Advanced"].contains(directory ?? "") ? directory : nil
        profile.scrollbackLines = values["Scrollback Lines"] as? Int
        profile.unlimitedScrollback = values["Unlimited Scrollback"] as? Bool ?? false
        return profile
    }

    /// The profile's colours: each a dictionary of "Red/Green/Blue/Alpha Component" (0–1) and a
    /// "Color Space". A profile with separate light and dark colours keeps them under " (Dark)" keys, which
    /// are the ones read: Next Term is dark.
    static func readColours(_ values: [String: Any], into profile: inout Profile) {
        let dark = values["Use Separate Colors for Light and Dark Mode"] as? Bool == true
        var palette = TerminalPalette(name: "iTerm2 colours")
        var read: [(rgb: UInt32, alpha: Double)?] = []
        for key in colourKeys {
            let colour = (dark ? values[key + " (Dark)"] : nil) ?? values[key]
            guard let components = colour as? [String: Any] else {
                read.append(nil)
                continue
            }
            func component(_ name: String) -> Double? { (components[name + " Component"] as? NSNumber)?.doubleValue }
            let rgb = TerminalPalette.rgb(component("Red"), component("Green"), component("Blue"))
            read.append(rgb.map { ($0, component("Alpha") ?? 1) })
            let space = components["Color Space"] as? String
            if rgb != nil, let space, space != "sRGB" { profile.otherColourSpace = true }
        }
        for slot in 0..<16 { palette.ansi[slot] = read[slot]?.rgb }
        palette.foreground = read[16]?.rgb
        palette.background = read[17]?.rgb
        palette.cursor = read[18]?.rgb
        if let selection = read[19] {
            palette.selection = ImportColours.opaqueSelection(selection.rgb, alpha: selection.alpha, background: palette.background)
        }
        profile.palette = palette.isEmpty ? nil : palette
        profile.darkVariants = dark
    }

    // MARK: settings

    /// "Monaco 12" → 12 (the last word is the size; the rest is the font, `fontFamily`).
    static func fontSize(_ profile: Profile, skipped: inout [SkippedItem]) -> PlannedSetting? {
        guard let font = profile.normalFont?.trimmingCharacters(in: .whitespaces), !font.isEmpty else { return nil }
        guard !SecretGuard.looksSecret(font) else {
            skipped.append(SkippedItem("Normal Font", "looked like a credential"))
            return nil
        }
        var words = font.split(separator: " ")
        guard let last = words.popLast(), let size = Double(last), size.isFinite, size > 0 else {
            skipped.append(SkippedItem("Normal Font", "the size couldn't be read"))
            return nil
        }
        let setting = ImportedSetting.fontSize(clamping: size)
        var notes = ["sets the editor too: Next Term has one size for both"]
        if case .fontSize(let clamped) = setting, size < 8 || size > 32 {
            notes.insert("iTerm2 has \(formatted(size)); Next Term's sizes go from 8 to 32, so \(formatted(clamped))", at: 0)
        }
        return PlannedSetting(setting, source: "Normal Font " + font, note: notes.joined(separator: "; "))
    }

    /// Option as Meta when either Option key sends Meta or Esc+: ticked only when both do and the keyboard
    /// is U.S.-style (§3 principle 4), since Next Term can't set one side yet.
    static func optionAsMeta(_ profile: Profile, usKeyboard: Bool) -> PlannedSetting? {
        let left = profile.leftOption != 0, right = profile.rightOption != 0
        guard left || right else { return nil }
        var notes: [String] = []
        if left != right {
            notes.append("on in iTerm2 for \(left ? "Left" : "Right") Option only; Next Term can't set one side yet")
        }
        if !usKeyboard { notes.append("your keyboard layout may need Option to type @ [ ] { }") }
        let source = "Option Key Sends \(optionName(profile.leftOption)), Right Option Key Sends \(optionName(profile.rightOption))"
        return PlannedSetting(.optionAsMeta(true), source: source, ticked: notes.isEmpty,
                              note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    static func optionName(_ value: Int) -> String { ["Normal", "Meta", "Esc+"][value] }

    /// The terminal font from "Normal Font" (its PostScript name, before the size): used when this Mac has
    /// it and it is monospaced. A value that looked like a credential was reported by `fontSize`.
    static func fontFamily(_ profile: Profile, fonts: FontCatalog) -> (setting: PlannedSetting?, skipped: [SkippedItem]) {
        guard let font = profile.normalFont?.trimmingCharacters(in: .whitespaces), !SecretGuard.looksSecret(font) else { return (nil, []) }
        var words = font.split(separator: " ")
        guard words.count > 1, let last = words.popLast(), Double(last) != nil else { return (nil, []) }
        return ImportFonts.row(.terminal, list: words.joined(separator: " "), source: "Normal Font", fonts: fonts)
    }

    /// The profile's colours as a preview row.
    static func coloursRow(_ palette: TerminalPalette, profile: Profile) -> PlannedSetting? {
        var notes: [String] = []
        if profile.otherColourSpace { notes.append("colours in Display P3 or a calibrated space are read as sRGB, so a few may look slightly different") }
        let source = "the default profile's colours" + (profile.darkVariants ? " (its Dark Mode ones)" : "")
        return ImportColours.row(palette, source: source, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// What the profile sets that has no Next Term setting yet. iTerm2 writes its defaults into every
    /// profile, so the start folder and scrollback are named only when they differ from them.
    static func later(_ profile: Profile) -> [SkippedItem] {
        var items: [SkippedItem] = []
        if let directory = profile.customDirectory, directory != "No" {
            items.append(SkippedItem("Custom Directory (\(directory))", "a start folder setting comes later"))
        }
        if profile.unlimitedScrollback {
            items.append(SkippedItem("Unlimited Scrollback", "a scrollback setting comes later"))
        } else if let lines = profile.scrollbackLines, lines != 1000 {
            items.append(SkippedItem("Scrollback Lines \(lines)", "a scrollback setting comes later"))
        }
        return items
    }

    static func formatted(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}

/// Reads for the importers in this file: regular files only (never a pipe or a device), through a read
/// handle, up to a size no settings file reaches.
private enum ImportFile {
    static let limit = 64 << 20

    static func data(_ path: String) -> Data? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data() // nil: an empty file
        } catch {
            return nil
        }
        return data.count <= limit ? data : nil
    }

    static func text(_ path: String) -> String? {
        data(path).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

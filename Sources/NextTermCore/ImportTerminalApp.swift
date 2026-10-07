import Foundation

// "Coming from Terminal?": the default profile in `com.apple.Terminal.plist` (§3.4). Design:
// claudedocs/research_next-term-migration (§3.4 terminals, §6 safety). Terminal saves a profile's font and
// colours as NSKeyedArchiver data. They are read here as plain property lists, picking numbers and strings
// out of the archive's objects: no class is ever instantiated (stricter than secure coding, and no AppKit
// in Core). Only the keys below are looked at; nothing is written and nothing is run.

public enum ImportTerminalApp {
    public static func preferencesPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/Preferences/com.apple.Terminal.plist")
    }

    /// Terminal, when its default profile is one the user chose or changed: every Mac has Terminal, and an
    /// untouched Basic profile has nothing to bring. (Detection reads the default profile's keys below.)
    public static func detect(home: String = NSHomeDirectory()) -> [DetectedApp] {
        let path = preferencesPath(home: home)
        guard isRegularFile(path), let data = ImportFile.data(path), let preferences = Preferences(data),
              let profile = preferences.profile, profile.name != "Basic" || !profile.isBasicDefault else { return [] }
        return [DetectedApp(kind: .terminalApp, name: "Terminal", configPath: path, lastUsed: ImportFile.modificationDate(path))]
    }

    // MARK: reading

    /// The ANSI colour keys in order: normal, then bright.
    static let ansiKeys: [String] = {
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        return names.map { "ANSI\($0)Color" } + names.map { "ANSIBright\($0)Color" }
    }()

    /// Every profile key read (checked by a test against `SecretGuard`).
    static let profileKeys = ansiKeys + ["Font", "useOptionAsMetaKey", "TextColor", "BackgroundColor", "CursorColor", "SelectionColor"]

    struct Profile: Equatable {
        var name = "Basic"
        /// The PostScript name and size.
        var font: (name: String, size: Double)?
        var optionAsMeta = false
        var palette: TerminalPalette?
        /// It has a CommandString (a command it runs at start), which is named, never read.
        var runsCommand = false

        /// Basic as a new Mac has it: SF Mono 11 (or no font saved), no colours, Option types characters.
        var isBasicDefault: Bool {
            let defaultFont = font.map { $0.name == "SFMono-Regular" && $0.size == 11 } ?? true
            return defaultFont && palette == nil && !optionAsMeta
        }

        static func == (a: Profile, b: Profile) -> Bool {
            a.name == b.name && a.font?.name == b.font?.name && a.font?.size == b.font?.size && a.optionAsMeta == b.optionAsMeta
                && a.palette == b.palette && a.runsCommand == b.runsCommand
        }
    }

    struct Preferences {
        /// The default profile (macOS saves its built-in profiles too, so the others say nothing about the user).
        var profile: Profile?

        init?(_ data: Data) {
            guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
                return nil
            }
            let profiles = root["Window Settings"] as? [String: Any] ?? [:]
            let name = root["Default Window Settings"] as? String ?? "Basic"
            guard let values = profiles[name] as? [String: Any] else { return }
            profile = ImportTerminalApp.profile(values, name: name)
        }
    }

    static func profile(_ values: [String: Any], name: String) -> Profile {
        var profile = Profile()
        profile.name = name.count <= 80 && !SecretGuard.looksSecret(name) ? name : "Default"
        profile.font = (values["Font"] as? Data).flatMap(font)
        profile.optionAsMeta = values["useOptionAsMetaKey"] as? Bool == true
        profile.runsCommand = values["CommandString"] != nil
        var palette = TerminalPalette(name: "Terminal, profile \(profile.name)")
        for (slot, key) in ansiKeys.enumerated() { palette.ansi[slot] = (values[key] as? Data).flatMap(colour)?.rgb }
        palette.foreground = (values["TextColor"] as? Data).flatMap(colour)?.rgb
        palette.background = (values["BackgroundColor"] as? Data).flatMap(colour)?.rgb // a see-through one is shown opaque
        palette.cursor = (values["CursorColor"] as? Data).flatMap(colour)?.rgb
        if let selection = (values["SelectionColor"] as? Data).flatMap(colour) {
            palette.selection = ImportColours.opaqueSelection(selection.rgb, alpha: selection.alpha, background: palette.background)
        }
        profile.palette = palette.isEmpty ? nil : palette
        return profile
    }

    /// The objects of an NSKeyedArchiver archive, read as a plain property list.
    static func objects(_ data: Data) -> [Any]? {
        guard data.count <= 64 << 10,
              let archive = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver" else { return nil }
        return archive["$objects"] as? [Any]
    }

    /// An archived NSFont: its size from the font's own object, and its PostScript name, the archive's only
    /// string besides "$null".
    static func font(_ data: Data) -> (name: String, size: Double)? {
        guard let objects = objects(data),
              let font = objects.compactMap({ $0 as? [String: Any] }).first(where: { $0["NSSize"] != nil }),
              let size = (font["NSSize"] as? NSNumber)?.doubleValue, size.isFinite, size > 0,
              let name = objects.compactMap({ $0 as? String }).first(where: { $0 != "$null" }),
              !name.isEmpty, name.count <= 200 else { return nil }
        return (name, size)
    }

    /// An archived NSColor: an sRGB colour's own components ("NSComponents", when its colour space is sRGB),
    /// else "NSRGB" ("r g b [a]") in an RGB colour space or "NSWhite" ("w [a]") in a grey one. Calibrated and
    /// device colours are read as sRGB, which is close for a terminal palette.
    static func colour(_ data: Data) -> (rgb: UInt32, alpha: Double)? {
        guard let dictionaries = objects(data)?.compactMap({ $0 as? [String: Any] }),
              let colour = dictionaries.first(where: { $0["NSColorSpace"] != nil }) else { return nil }
        func numbers(_ key: String) -> [Double]? {
            guard let bytes = colour[key] as? Data, bytes.count <= 256,
                  let text = String(data: bytes, encoding: .ascii)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) else { return nil }
            let values = text.split(separator: " ").compactMap { Double($0) }
            return values.isEmpty ? nil : values
        }
        // The archived colour space's id: 7 is sRGB.
        let sRGB = dictionaries.contains { ($0["NSID"] as? NSNumber)?.intValue == 7 }
        if sRGB, let components = numbers("NSComponents"), components.count >= 3,
           let value = TerminalPalette.rgb(components[0], components[1], components[2]) {
            return (value, components.count > 3 ? components[3] : 1)
        }
        if let rgb = numbers("NSRGB"), rgb.count >= 3, let value = TerminalPalette.rgb(rgb[0], rgb[1], rgb[2]) {
            return (value, rgb.count > 3 ? rgb[3] : 1)
        }
        if let white = numbers("NSWhite"), let value = TerminalPalette.rgb(white[0], white[0], white[0]) {
            return (value, white.count > 1 ? white[1] : 1)
        }
        return nil
    }

    // MARK: plan

    /// The default profile's font, its size, Option as Meta and colours. `fonts`: the fonts this Mac has
    /// (tests pass their own).
    public static func plan(for app: DetectedApp, home: String = NSHomeDirectory(), usKeyboard: Bool = true,
                            fonts: FontCatalog = .system) -> ImportPlan {
        var plan = ImportPlan(preset: app.preset)
        guard app.kind == .terminalApp else { return plan }
        let path = app.configPath.isEmpty ? preferencesPath(home: home) : app.configPath
        guard let data = ImportFile.data(path), let preferences = Preferences(data) else {
            plan.skipped.append(SkippedItem((path as NSString).lastPathComponent, "couldn't be read, so no settings came over"))
            return plan
        }
        guard let profile = preferences.profile else {
            plan.skipped.append(SkippedItem("profiles", "the default profile couldn't be found, so no settings came over"))
            return plan
        }
        if let font = profile.font {
            var notes = ["sets the editor too: Next Term has one size for both"]
            if font.size.rounded() < 8 || font.size.rounded() > 32 { notes.insert("Next Term's sizes go from 8 to 32", at: 0) }
            let shown = SecretGuard.looksSecret(font.name) ? "" : " " + font.name
            plan.settings.append(PlannedSetting(.fontSize(clamping: font.size), source: "Font\(shown) \(ImportITerm2.formatted(font.size))",
                                                note: notes.joined(separator: "; ")))
            let row = ImportFonts.row(.terminal, list: font.name, source: "Font", fonts: fonts)
            plan.settings += [row.setting].compactMap { $0 }
            plan.skipped += row.skipped
        }
        if profile.optionAsMeta {
            plan.settings.append(PlannedSetting(.optionAsMeta(true), source: "Use Option as Meta key", ticked: usKeyboard,
                                                note: usKeyboard ? nil : "your keyboard layout may need Option to type @ [ ] { }"))
        }
        if let palette = profile.palette, let row = ImportColours.row(palette, source: "profile \(profile.name) colours") {
            plan.settings.append(row)
        }
        if profile.runsCommand { plan.skipped.append(SkippedItem("Run command", "never imported: runs commands")) }
        return plan
    }
}

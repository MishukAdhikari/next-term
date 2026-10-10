import Foundation
import Testing
@testable import NextTermCore

/// Alacritty, from the hand-written fixture home in Fixtures/Import/Alacritty (never a real Mac's), plus small
/// configs written into a temp home.
@Suite struct ImportAlacrittyTests {
    var fm: FileManager { .default }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func plan(_ home: String, usKeyboard: Bool = true) throws -> ImportPlan {
        let app = try #require(ImportAlacritty.detect(home: home, applications: []).first)
        return ImportAlacritty.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts)
    }

    /// A temp home with only `config` as ~/.config/alacritty/alacritty.toml.
    func plan(config: String) throws -> ImportPlan {
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-alacritty-" + String(UUID().uuidString.prefix(8))
        let home = root + "/home"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: home + "/.config/alacritty", withIntermediateDirectories: true)
        try config.write(toFile: home + "/.config/alacritty/alacritty.toml", atomically: true, encoding: .utf8)
        return try plan(home)
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func detection() throws {
        let home = try ImportFixtures.copy("Alacritty")
        defer { remove(home) }
        let apps = home + "/Applications"
        try fm.createDirectory(atPath: apps + "/Alacritty.app/Contents", withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.17.0"], format: .xml, options: 0)
        try info.write(to: URL(fileURLWithPath: apps + "/Alacritty.app/Contents/Info.plist"))
        let app = try #require(ImportAlacritty.detect(home: home, applications: [apps]).first)
        #expect(app.kind == .alacritty && app.name == "Alacritty" && app.preset == .nextTerm)
        #expect(app.configPath == home + "/.config/alacritty/alacritty.toml")
        #expect(app.appPath == apps + "/Alacritty.app" && app.version == "0.17.0")
        #expect(ImportAlacritty.detect(home: home, applications: [])[0].appPath == nil)
        #expect(ImportAlacritty.detect(home: home + "/Projects", applications: []).isEmpty)
    }

    @Test func settingsFromTheConfigAndItsImports() throws {
        let home = try ImportFixtures.copy("Alacritty")
        defer { remove(home) }
        let plan = try plan(home)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontFamily("JetBrains Mono")))
        #expect(settings.contains(.terminalFontSize(15)), "font.size 14.5, never outside.toml's 31")
        #expect(settings.contains(.terminalCursorShape("bar")))
        #expect(settings.contains(.terminalCursorBlink(true)))
        #expect(settings.contains(.terminalScrollback(50_000)))
        #expect(settings.contains(.terminalStartFolder(home + "/Projects")))
        let option = try #require(plan.settings.first { $0.setting == .optionAsMeta(true) })
        #expect(!option.ticked && option.note == "on in Alacritty for Left Option only; Next Term can't set one side yet")

        // The theme's colours, the config's own on top (its red and foreground), the cursor left to the cell.
        let row = try #require(plan.settings.first { if case .terminalPalette = $0.setting { return true } else { return false } })
        guard case .terminalPalette(let palette) = row.setting else { return }
        #expect(palette.ansi[0] == 0x15161E && palette.ansi[1] == 0xFF0000 && palette.ansi[9] == 0xF7768E)
        #expect(palette.ansi[15] == nil, "lightgray is a colour name")
        #expect(palette.foreground == 0xC0CAF5 && palette.background == 0x1A1B26)
        #expect(palette.cursor == nil && palette.selection == 0x33467C)
        #expect(reasons(plan)["colors.bright.white"] == "only #rrggbb colours are read")
    }

    @Test func importsStayInAlacrittysFolder() throws {
        let home = try ImportFixtures.copy("Alacritty")
        defer { remove(home) }
        let plan = try plan(home)
        let reasons = reasons(plan)
        #expect(reasons["import outside.toml"] == "only files in Alacritty's own folder are read")
        #expect(reasons["import escape.toml"] == "only files in Alacritty's own folder are read")
        #expect(reasons["import broken.toml"] == "not valid TOML, so Alacritty skips it too")
        #expect(!plan.skipped.contains { $0.item.contains("missing") }, "a missing import is skipped quietly, as Alacritty does")
        #expect(!plan.settings.contains { $0.setting == .terminalFontSize(31) })
    }

    @Test func keyBindings() throws {
        let home = try ImportFixtures.copy("Alacritty")
        defer { remove(home) }
        let plan = try plan(home)
        let rows = plan.shortcuts.map { "\($0.command) \($0.chord?.display ?? "none") \($0.allowed)" }
        #expect(rows == ["newWindow: ⌘D true", "newTab: ⇧⌘T true", "selectTabByNumber:#1 ⌥⌘1 true",
                         "showNextTab: ⇧⌘→ true", "copy: ⌃C false"])
        #expect(plan.shortcuts.first?.source == "keyboard.bindings Command+D → CreateNewWindow")
        let reasons = reasons(plan)
        #expect(reasons["keyboard.bindings Command+F → SearchForward"] == "only in one of Alacritty's modes (Search)")
        #expect(reasons["keyboard.bindings Command+a scan code → Paste"] == "key not recognised")
        #expect(reasons["1 key binding with a command"] == "never imported: runs commands")
        #expect(reasons["2 key bindings"] == "no matching Next Term command, or they send text to the terminal")
    }

    @Test func neverReadAndReported() throws {
        let home = try ImportFixtures.copy("Alacritty")
        defer { remove(home) }
        let plan = try plan(home)
        let reasons = reasons(plan)
        for key in ["env", "shell", "hints", "bell.command"] {
            #expect(reasons[key] == "never imported: runs commands or can hold secrets", "\(key)")
        }
        #expect(reasons["window.opacity"] == "the terminal is opaque here")
        let other = try #require(plan.skipped.first { $0.item.hasPrefix("other settings: ") })
        #expect(other.item.contains("general.live_config_reload") && other.item.contains("window.padding"))
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
        #expect(ImportFixtures.secrets(in: ImportAlacritty.detect(home: home, applications: [])).isEmpty)
    }

    @Test func olderSpellingsAndValues() throws {
        let plan = try plan(config: """
            import = ["themes/missing.toml"]
            working_directory = "None"
            [cursor]
            style = "Underline"
            [window]
            option_as_alt = "Both"
            [scrolling]
            history = 0
            [[key_bindings]]
            key = "Equals"
            mods = "Command"
            action = "IncreaseFontSize"
            """)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalCursorShape("underline")))
        #expect(plan.settings.contains { $0.setting == .optionAsMeta(true) && $0.ticked })
        #expect(settings.contains(.terminalScrollback(1_000)))
        #expect(!settings.contains { if case .terminalStartFolder = $0 { return true } else { return false } })
        #expect(plan.shortcuts.map(\.command) == ["increaseFontSize:"])
    }

    @Test func anInvalidConfigBringsNothing() throws {
        let plan = try plan(config: "[font]\nsize = 12\n[font]\nsize = 13\n")
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped == [SkippedItem("alacritty.toml", "not valid TOML (line 3), so Alacritty doesn't read it either; no settings came over")])
    }

    @Test func anOldYAMLConfigIsNamed() throws {
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-alacritty-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/.config/alacritty", withIntermediateDirectories: true)
        try "font:\n  size: 12\n".write(toFile: root + "/.config/alacritty/alacritty.yml", atomically: true, encoding: .utf8)
        let app = try #require(ImportAlacritty.detect(home: root, applications: []).first)
        let plan = ImportAlacritty.plan(for: app, home: root, fonts: testFonts)
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped.first?.reason.contains("alacritty migrate") == true)
    }

    /// A config that is itself a link out of Alacritty's folder isn't read.
    @Test func aLinkedConfigOutsideIsNotRead() throws {
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-alacritty-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/home/.config", withIntermediateDirectories: true)
        try "[font]\nsize = 20\n".write(toFile: root + "/elsewhere.toml", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root + "/home/.alacritty.toml", withDestinationPath: root + "/elsewhere.toml")
        let app = try #require(ImportAlacritty.detect(home: root + "/home", applications: []).first)
        let plan = ImportAlacritty.plan(for: app, home: root + "/home", fonts: testFonts)
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped.first?.reason.hasPrefix(ImportFile.linkedOut) == true)
    }
}

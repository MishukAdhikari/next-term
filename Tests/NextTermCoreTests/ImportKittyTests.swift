import Foundation
import Testing
@testable import NextTermCore

/// kitty, from the hand-written fixture home in Fixtures/Import/kitty (never a real Mac's), plus small configs
/// written into a temp home.
@Suite struct ImportKittyTests {
    var fm: FileManager { .default }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func plan(_ home: String, usKeyboard: Bool = true) throws -> ImportPlan {
        let app = try #require(ImportKitty.detect(home: home, applications: []).first)
        return ImportKitty.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts)
    }

    func plan(config: String, folder: String = ".config/kitty") throws -> ImportPlan {
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-kitty-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        try config.write(toFile: root + "/" + folder + "/kitty.conf", atomically: true, encoding: .utf8)
        return try plan(root)
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func detection() throws {
        let home = try ImportFixtures.copy("kitty")
        defer { remove(home) }
        let app = try #require(ImportKitty.detect(home: home, applications: []).first)
        #expect(app.kind == .kitty && app.name == "kitty" && app.preset == .nextTerm && app.appPath == nil)
        #expect(app.configPath == home + "/.config/kitty/kitty.conf")
        // kitty also looks in ~/Library/Preferences/kitty on a Mac, after ~/.config/kitty.
        let other = try plan(config: "font_size 17", folder: "Library/Preferences/kitty")
        #expect(other.settings.map(\.setting) == [.terminalFontSize(17)])
    }

    @Test func settingsFromTheConfigAndItsIncludes() throws {
        let home = try ImportFixtures.copy("kitty")
        defer { remove(home) }
        let plan = try plan(home)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontFamily("JetBrains Mono")))
        #expect(settings.contains(.terminalFontSize(15)), "the globinclude'd size comes after kitty.conf's 13")
        #expect(!settings.contains(.terminalFontSize(31)), "outside.conf is never read")
        #expect(settings.contains(.terminalCursorShape("bar")))
        #expect(settings.contains(.terminalCursorBlink(false)))
        #expect(settings.contains(.terminalScrollback(100_000)))
        let option = try #require(plan.settings.first { $0.setting == .optionAsMeta(true) })
        #expect(!option.ticked)

        let row = try #require(plan.settings.first { if case .terminalPalette = $0.setting { return true } else { return false } })
        #expect(row.source == "your colour settings, dark-theme.auto.conf over them")
        guard case .terminalPalette(let palette) = row.setting else { return }
        #expect(palette.ansi[0] == 0x000000 && palette.ansi[1] == 0xF7768E && palette.ansi[2] == 0x9ECE6A && palette.ansi[8] == 0x414868)
        #expect(palette.ansi[4] == nil && palette.foreground == 0xC0CAF5 && palette.background == 0x1A1B26)
        #expect(palette.cursor == 0xC0CAF5 && palette.selection == nil)
        let reasons = reasons(plan)
        #expect(reasons["color4"] == "only #rrggbb colours are read, not colour names")
        #expect(reasons["color16–color255"] == "Next Term sets the first 16 colours only")
    }

    @Test func includesStayInKittysFolderAndNothingRuns() throws {
        let home = try ImportFixtures.copy("kitty")
        defer { remove(home) }
        let plan = try plan(home)
        let reasons = reasons(plan)
        #expect(plan.skipped.contains(SkippedItem("include", "only files in kitty's own folder are read")))
        #expect(plan.skipped.contains(SkippedItem("include", "a path with an environment variable isn't expanded, so it isn't read")))
        #expect(reasons["include missing.conf"] == "file not found")
        #expect(reasons["geninclude"] == "never run: it runs a program")
        #expect(reasons["envinclude"] == "never read: it comes from environment variables")
        for key in ["shell", "env", "remote_control_password", "startup_session"] {
            #expect(reasons[key] == "never imported: runs commands or can hold secrets", "\(key)")
        }
        #expect(reasons["background_opacity"] == "the terminal is opaque here")
        #expect(reasons["copy_on_select"] == "copy on select isn't a setting yet")
        #expect(reasons["other settings: tab_bar_style"] == "no matching Next Term setting yet")
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    @Test func maps() throws {
        let home = try ImportFixtures.copy("kitty")
        defer { remove(home) }
        let plan = try plan(home)
        let rows = plan.shortcuts.map { "\($0.command) \($0.chord?.display ?? "none")" }
        #expect(rows == ["newTab: ⇧⌘T", "splitRight: ⌘D", "splitDown: ⇧⌘D", "clearBuffer: ⌘K", "selectTabByNumber:#1 ⌘1",
                         "toggleZoomPane: ⌘↩", "performClose: ⇧⌘W", "selectPaneLeft: ⇧⌘←", "copy: ⌃⇧C", "increaseFontSize: ⌥⌘="])
        #expect(plan.shortcuts.first?.source == "map kitty_mod+t → new_tab_with_cwd")
        #expect(plan.shortcuts[1].source == "map cmd+d → launch --location=vsplit")
        #expect(plan.shortcuts.first { $0.command == "copy:" }?.allowed == false)
        let reasons = reasons(plan)
        #expect(reasons["map ctrl+a>c → new_tab"] == ImportShortcuts.twoStep)
        #expect(reasons["map cmd+s → next_tab"] == "only while some windows have the keyboard")
        #expect(reasons["map cmd+plus → change_font_size all +2.0"] == ImportShortcuts.notRecognised)
        #expect(reasons["2 map lines"] == "no matching Next Term command, or they send text or run programs")
        #expect(!plan.shortcuts.contains { $0.command == "closeTab:" }, "a later map with no action unmaps cmd+w")
    }

    @Test func valuesAndForms() throws {
        let plan = try plan(config: """
            font_family Menlo
            cursor_blink_interval -1
            scrollback_lines 5000
            macos_option_as_alt yes
            cursor_shape triangle
            font_size big
            map cmd+t
            \\ new_tab
            clear_all_shortcuts yes
            map super+n new_os_window
            """)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontFamily("Menlo")))
        #expect(plan.settings.contains { $0.setting == .terminalCursorBlink(true) && $0.note != nil })
        #expect(settings.contains(.terminalScrollback(5_000)))
        #expect(plan.settings.contains { $0.setting == .optionAsMeta(true) && $0.ticked })
        let reasons = reasons(plan)
        #expect(reasons["cursor_shape"] == "value not recognised")
        #expect(reasons["font_size"] == "not a font size Next Term can use")
        #expect(plan.shortcuts.map(\.command) == ["newWindow:"], "clear_all_shortcuts drops the maps before it")
        #expect(ImportKitty.family("monospace") == nil && ImportKitty.family("family='Fira Code' features=+zero") == "Fira Code")
    }

    @Test func globPatterns() throws {
        let pattern = try #require(ImportKitty.globPattern("kitty.d/**/*.conf"))
        for (path, matches) in [("kitty.d/a.conf", true), ("kitty.d/x/y/b.conf", true), ("kitty.d/a.txt", false), ("other/a.conf", false)] {
            #expect((path.range(of: pattern, options: .regularExpression) != nil) == matches, "\(path)")
        }
        #expect(ImportKitty.globPattern("") == nil)
        #expect(ImportKitty.globPattern(String(repeating: "*", count: 300)) == nil)
    }

    /// A config far bigger than any real one isn't read.
    @Test func aHugeConfigIsNotRead() throws {
        let huge = String(repeating: "font_size 12\n", count: ImportKitty.Reader.maxBytes / 13 + 10)
        let plan = try plan(config: huge)
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped.contains(SkippedItem("kitty.conf", "couldn't be read")))
    }

    /// An include loop, or a file including itself, stops: each file is read once.
    @Test func includeLoops() throws {
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-kitty-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/.config/kitty", withIntermediateDirectories: true)
        try "include a.conf\nfont_size 12\ninclude kitty.conf".write(toFile: root + "/.config/kitty/kitty.conf", atomically: true, encoding: .utf8)
        try "include kitty.conf\ninclude a.conf\ncursor_shape block".write(toFile: root + "/.config/kitty/a.conf", atomically: true, encoding: .utf8)
        let plan = try plan(root)
        let expected: [ImportedSetting] = [.terminalFontSize(12), .terminalCursorShape("block")]
        #expect(plan.settings.map(\.setting) == expected)
    }
}

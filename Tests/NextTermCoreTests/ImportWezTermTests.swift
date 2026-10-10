import Foundation
import Testing
@testable import NextTermCore

/// WezTerm and Kaku, from the hand-written fixture home in Fixtures/Import/WezTerm (never a real Mac's), plus small
/// configs written into a temp home. The Lua is never run.
@Suite struct ImportWezTermTests {
    var fm: FileManager { .default }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func plan(_ home: String, kind: ImportSourceKind = .wezTerm, usKeyboard: Bool = true) throws -> ImportPlan {
        let app = try #require(ImportWezTerm.detect(home: home, applications: []).first { $0.kind == kind })
        return ImportWezTerm.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts)
    }

    func plan(lua: String) throws -> ImportPlan {
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-wezterm-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try lua.write(toFile: root + "/.wezterm.lua", atomically: true, encoding: .utf8)
        return try plan(root)
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func detection() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let apps = ImportWezTerm.detect(home: home, applications: [])
        #expect(apps.map(\.name) == ["WezTerm", "Kaku"])
        #expect(apps.map(\.kind) == [.wezTerm, .kaku])
        #expect(apps[0].configPath == home + "/.config/wezterm/wezterm.lua")
        #expect(apps[1].configPath == home + "/.config/kaku/kaku.lua")
        #expect(apps.allSatisfy { $0.preset == .nextTerm })
    }

    @Test func literalSettingsComeOver() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let plan = try plan(home)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontFamily("JetBrains Mono")))
        #expect(settings.contains(.terminalFontSize(14)))
        #expect(settings.contains(.terminalCursorShape("bar")) && settings.contains(.terminalCursorBlink(true)))
        #expect(settings.contains(.terminalScrollback(20_000)))
        // Left Option is Alt by WezTerm's default and right is set so: both, ticked.
        let option = try #require(plan.settings.first { $0.setting == .optionAsMeta(true) })
        #expect(option.ticked)
        #expect(option.source == "left Option as Alt (WezTerm's default), send_composed_key_when_right_alt_is_pressed false")
        let reasons = reasons(plan)
        #expect(reasons["Terminal font “Operator Mono”"] == "not installed on this Mac")
        #expect(reasons["default_cwd"] == "WezTerm starts only its first window there; new tabs open in the folder of the pane in front")
    }

    @Test func colourSchemeFileWithColorsOverIt() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let plan = try plan(home)
        let row = try #require(plan.settings.first { if case .terminalPalette = $0.setting { return true } else { return false } })
        #expect(row.source == "color_scheme Night Owl and colors")
        guard case .terminalPalette(let palette) = row.setting else { return }
        #expect(palette.ansi[0] == 0x011627, "the config's ansi list replaces the scheme's")
        #expect(palette.ansi[8] == 0x575656 && palette.ansi[11] == 0xFFEB95, "brights from the scheme")
        #expect(palette.foreground == 0xD6DEEB && palette.background == 0x011627)
        #expect(palette.cursor == nil && palette.selection == 0x1D3B53)
        #expect(reasons(plan)["colors cursor_bg"] == "only #rrggbb colours are read")
    }

    @Test func keys() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let plan = try plan(home)
        let rows = plan.shortcuts.map { "\($0.command) \($0.chord?.display ?? "none")" }
        let expected = ["newTab: ⌘T", "splitRight: ⌘D", "splitDown: ⇧⌘D", "showPreviousTab: ⇧⌘[", "selectPaneRight: ⌥⌘→",
                        "selectTabByNumber:#1 ⌘1", "clearBuffer: ⌘K", "toggleZoomPane: ⇧⌘↩", "copy: ⌃⇧C"]
        #expect(rows == expected)
        #expect(plan.shortcuts[1].source == "keys CMD+d → SplitHorizontal")
        let reasons = reasons(plan)
        #expect(reasons["keys LEADER+a → SpawnWindow"] == ImportShortcuts.twoStep)
        #expect(reasons["1 key whose action is Lua code"] == "Lua code is never run")
        #expect(reasons["1 key"] == "no matching Next Term command, or they send text to the terminal")
    }

    @Test func codeAndSecretsAreOnlyNamed() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let plan = try plan(home)
        let reasons = reasons(plan)
        for key in ["default_prog", "set_environment_variables", "ssh_domains"] {
            #expect(reasons[key] == "never imported: runs commands or can hold secrets", "\(key)")
        }
        #expect(reasons["set by Lua code: line_height, term, enable_tab_bar"] == "only values written out in the file are read; it is never run")
        #expect(reasons["window_background_opacity"] == "the terminal is opaque here")
        #expect(reasons["other settings: hide_tab_bar_if_only_one_tab"] == "no matching Next Term setting yet")
        #expect(!plan.settings.contains { $0.setting == .terminalFontSize(99) }, "a commented-out line")
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    @Test func kaku() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let plan = try plan(home, kind: .kaku)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontSize(16)))
        #expect(plan.settings.contains { $0.setting == .optionAsMeta(false) })
        #expect(plan.shortcuts.map(\.command) == ["selectPaneRight:"])
        #expect(plan.shortcuts.first?.chord?.display == "⇧⌘→")
        let reasons = reasons(plan)
        #expect(reasons["color_scheme Kaku Dark"] == "Kaku's built-in schemes are inside Kaku, so they can't be read yet")
        #expect(!plan.skipped.contains { $0.item.hasPrefix("set by Lua code") }, "loading Kaku's defaults sets no field")
    }

    @Test func optionKeysAndDefaults() throws {
        // Nothing set: left Option as Alt (the default), for that side only.
        let unset = try plan(lua: "return {}")
        let left = try #require(unset.settings.first)
        #expect(left.setting == .optionAsMeta(true) && !left.ticked)
        #expect(left.note == "on in WezTerm for Left Option only; Next Term can't set one side yet")
        // Both composing: off.
        let off = try plan(lua: "return { send_composed_key_when_left_alt_is_pressed = true }")
        #expect(off.settings.map(\.setting) == [.optionAsMeta(false)])
        // Set by code: nothing assumed.
        let code = try plan(lua: "local c = {}\nc.send_composed_key_when_left_alt_is_pressed = os.getenv('X') == '1'\nreturn c")
        #expect(code.settings.isEmpty)
    }

    @Test func oldActionFormAndOddKeys() throws {
        let plan = try plan(lua: """
            local wezterm = require('wezterm')
            return {
              keys = {
                { key = 'w', mods = 'SUPER', action = wezterm.action{ CloseCurrentPane = { confirm = true } } },
                { key = 'phys:Space', mods = 'CMD', action = wezterm.action.ToggleFullScreen },
                { key = '9', mods = 'CMD', action = wezterm.action.ActivateTab(-1) },
                { key = 'UpArrow', mods = 'META|CMD', action = wezterm.action.ActivatePaneDirection('Up') },
                { key = 'F', mods = 'CMD', action = wezterm.action.Search { CaseSensitiveString = '' } },
              },
            }
            """)
        let rows = plan.shortcuts.map { "\($0.command) \($0.chord?.display ?? "none")" }
        #expect(rows == ["closeTab: ⌘W", "toggleFullScreen: ⌘Space", "selectTabByNumber:#9 ⌘9", "selectPaneAbove: ⌥⌘↑",
                         "performFindPanelAction:#1 ⇧⌘F"])
    }

    @Test func unreadableLuaBringsNothing() throws {
        let plan = try plan(lua: "config.font_size = 'open")
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped == [SkippedItem(".wezterm.lua", "couldn't be read as Lua (it is never run); no settings came over")])
    }
}

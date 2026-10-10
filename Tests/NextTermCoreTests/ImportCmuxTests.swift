import Foundation
import Testing
@testable import NextTermCore

/// cmux as its own source, and Ghostty themes that other apps ship, from the hand-written fixture home in
/// Fixtures/Import/cmux (never a real Mac's). Apps are looked for only in the fixture's Applications folder.
@Suite struct ImportCmuxTests {
    var fm: FileManager { .default }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func plan(_ home: String) throws -> ImportPlan {
        let apps = [home + "/Applications"]
        let app = try #require(ImportCmux.detect(home: home, applications: apps).first)
        return ImportCmux.plan(for: app, home: home, fonts: testFonts, applications: apps)
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    func palette(_ plan: ImportPlan) -> TerminalPalette? {
        for row in plan.settings { if case .terminalPalette(let palette) = row.setting { return palette } }
        return nil
    }

    @Test func detection() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        let used = Date(timeIntervalSince1970: 1_790_000_000), newer = Date(timeIntervalSince1970: 1_791_000_000)
        try fm.setAttributes([.modificationDate: used], ofItemAtPath: home + "/.config/cmux/cmux.json")
        let own = home + "/Library/Application Support/com.cmuxterm.app/config.ghostty"
        try fm.setAttributes([.modificationDate: newer], ofItemAtPath: own)
        let app = try #require(ImportCmux.detect(home: home, applications: [home + "/Applications"]).first)
        #expect(app.kind == .cmux && app.name == "cmux" && app.preset == .nextTerm)
        #expect(app.configPath == home + "/.config/cmux/cmux.json" && app.lastUsed == newer)
        #expect(app.appPath == home + "/Applications/cmux.app" && app.version == "0.65.0")
        #expect(ImportCmux.detect(home: home + "/.config/ghostty", applications: []).isEmpty)
    }

    @Test func ghosttySettingsThroughCmux() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        let plan = try plan(home)
        let settings = plan.settings.map(\.setting)
        #expect(settings.contains(.terminalFontFamily("JetBrains Mono")))
        #expect(settings.contains(.terminalFontSize(14)), "cmux's own config is read after Ghostty's, and its older file not at all")
        let option = try #require(plan.settings.first { $0.setting == .optionAsMeta(true) })
        #expect(option.note == "on in cmux for Left Option only; Next Term can't set one side yet")
        let colours = try #require(palette(plan))
        #expect(colours.background == 0x011627 && colours.ansi[1] == 0xEF5350, "Night Owl from cmux.app's bundled themes")
        #expect(reasons(plan)["command"] == "never imported: runs commands or can hold secrets")
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    /// cmux's own Ghostty config is never read through a link out of its folder.
    @Test func itsOwnConfigLinkedOutIsNotRead() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        let outside = home + "/outside.ghostty"
        let secret = ImportFixtures.plantedSecrets[1]
        try "font-family = Leaked Mono\nfont-size = 29\ncommand = vault \(secret)\n".write(toFile: outside, atomically: true, encoding: .utf8)
        let own = home + "/Library/Application Support/com.cmuxterm.app/config.ghostty"
        try fm.removeItem(atPath: own)
        try fm.createSymbolicLink(atPath: own, withDestinationPath: outside)
        let plan = try plan(home)
        #expect(!plan.settings.contains { $0.setting == .terminalFontFamily("Leaked Mono") || $0.setting == .terminalFontSize(29) })
        #expect(reasons(plan)["config.ghostty"] == ImportFile.linkedOut)
        #expect(!String(describing: plan).contains("Leaked") && ImportFixtures.secrets(in: plan).isEmpty)
    }

    @Test func cmuxShortcutsThenGhosttyKeybinds() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        let plan = try plan(home)
        var expected = ["newTab: ⇧⌘T", "splitRight: ⌘\\", "toggleZoomPane: ⇧⌘↩", "selectPaneLeft: ⌃⌘←"]
        expected += (1...9).map { "selectTabByNumber:#\($0) ⌥⌘\($0)" }
        expected += ["renameTab: none", "toggleProjectSidebar: ⌥⌘B", "splitDown: ⌘D"]
        let rows = plan.shortcuts.map { "\($0.command) \($0.chord?.display ?? "none")" }
        #expect(rows == expected)
        #expect(plan.shortcuts.first?.source == "shortcuts.bindings.newSurface: cmd+shift+t")
        let removed = try #require(plan.shortcuts.first { $0.command == "renameTab:" })
        #expect(!removed.ticked)
        let reasons = reasons(plan)
        #expect(reasons["shortcuts.bindings.closeTab: [ctrl+b, x]"] == ImportShortcuts.twoStep)
        #expect(reasons["2 cmux shortcuts"] == "no matching Next Term command (workspaces, notifications, the browser and other cmux features)")
        #expect(reasons["other cmux.json settings: agentChat, terminal, actions"]
            == "no matching Next Term setting yet; actions, commands and hooks there are never read")
        // Settled against Next Term's keys, a shortcut it already has goes.
        var current: [String: KeyChord?] = [:]
        for id in ImportShortcuts.titles.keys { current[id] = .some(nil) }
        current["toggleZoomPane:"] = .some(KeyChord(key: "\r", command: true, shift: true))
        #expect(!plan.settlingShortcuts(current: current).shortcuts.contains { $0.command == "toggleZoomPane:" })
    }

    @Test func cmuxKeys() {
        func display(_ stroke: String) -> String {
            if case .chord(let chord) = ImportCmux.key(stroke, usKeyboard: true) { return chord.display }
            return "-"
        }
        #expect(display("cmd+shift+p") == "⇧⌘P")
        #expect(display("⌘+⇧+[") == "⇧⌘[")
        #expect(display("command+plus") == "⌘=")
        #expect(display("ctl+opt+left") == "⌃⌥←")
        #expect(display("cmd+f5") == "⌘F5")
        #expect(display("cmd+volumeup") == "-")
        #expect(display("cmd+") == "-")
        #expect(display("hyper+k") == "-")
    }

    /// Ghostty itself now finds a named theme in any app that ships Ghostty's themes, never through a link out of
    /// that app's themes folder.
    @Test func ghosttyThemesInOtherApps() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        let apps = [home + "/Applications"]
        func plan(_ theme: String) throws -> ImportPlan {
            try "theme = \(theme)\n".write(toFile: home + "/.config/ghostty/config", atomically: true, encoding: .utf8)
            let app = try #require(ImportGhostty.detect(home: home, applications: []).first)
            return ImportGhostty.plan(for: app, home: home, fonts: testFonts, applications: apps)
        }
        #expect(try palette(plan("Night Owl"))?.background == 0x011627)
        #expect(try palette(plan("Dracula"))?.background == 0x282A36)
        let escape = try plan("Escape")
        #expect(palette(escape) == nil)
        #expect(reasons(escape)["theme Escape"] == "not found in Ghostty's themes folders, or in an app that comes with them")
        #expect(ImportGhostty.themeBundles(apps).map { ($0 as NSString).lastPathComponent } == ["Other Term.app", "cmux.app"])
    }

    @Test func aBrokenCmuxJSONStillBringsTheGhosttySettings() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        try "{ \"shortcuts\": ".write(toFile: home + "/.config/cmux/cmux.json", atomically: true, encoding: .utf8)
        let plan = try plan(home)
        let commands: [String] = plan.shortcuts.map(\.command)
        #expect(commands == ["splitDown:"])
        #expect(reasons(plan)["cmux.json"] == "couldn't be read, so cmux's own shortcuts didn't come over")
        #expect(plan.settings.contains { $0.setting == .terminalFontSize(14) })
    }
}

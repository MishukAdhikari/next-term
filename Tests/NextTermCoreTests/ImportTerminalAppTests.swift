import AppKit
import Foundation
import Testing
@testable import NextTermCore

/// Fixtures are written into a fresh temporary home per test; the real home is never read. The colours and
/// fonts are archived by AppKit itself, as Terminal saves them.
@Suite struct ImportTerminalAppTests {
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-import-ta-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func archive(_ object: Any) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
    }

    func font(_ name: String, _ size: CGFloat) throws -> Data {
        try archive(try #require(NSFont(name: name, size: size)))
    }

    func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) throws -> Data {
        try archive(NSColor(calibratedRed: r, green: g, blue: b, alpha: a))
    }

    func write(_ profiles: [String: [String: Any]], default name: String?, home: String) throws -> String {
        var root: [String: Any] = ["Window Settings": profiles]
        if let name { root["Default Window Settings"] = name }
        let path = home + "/Library/Preferences/com.apple.Terminal.plist"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
        return path
    }

    func plan(_ profiles: [String: [String: Any]], default name: String?, usKeyboard: Bool = true) throws -> ImportPlan? {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try write(profiles, default: name, home: home)
        guard let app = ImportTerminalApp.detect(home: home).first else { return nil }
        return ImportTerminalApp.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts)
    }

    @Test func offeredOnlyForAProfileTheUserChoseOrChanged() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ImportTerminalApp.detect(home: home).isEmpty)
        // Every Mac: Basic, as it comes.
        let path = try write(["Basic": ["Font": try font("Menlo-Regular", 11), "name": "Basic"], "Pro": [:]], default: "Basic", home: home)
        _ = try write(["Basic": ["name": "Basic"], "Pro": ["BackgroundColor": try colour(0, 0, 0)]], default: "Basic", home: home)
        #expect(ImportTerminalApp.detect(home: home).isEmpty)
        // Pro chosen, or Basic changed.
        _ = try write(["Basic": [:], "Pro": [:]], default: "Pro", home: home)
        let app = try #require(ImportTerminalApp.detect(home: home).first)
        #expect(app.kind == .terminalApp && app.name == "Terminal" && app.configPath == path && app.preset == .nextTerm)
        _ = try write(["Basic": ["useOptionAsMetaKey": true]], default: nil, home: home)
        #expect(ImportTerminalApp.detect(home: home).count == 1)
    }

    @Test func fontOptionAndColours() throws {
        let profile: [String: Any] = [
            "Font": try font("Menlo-Regular", 14),
            "useOptionAsMetaKey": true,
            "ANSIRedColor": try colour(1, 0, 0),
            "ANSIBrightWhiteColor": try archive(NSColor(calibratedWhite: 1, alpha: 1)),
            "TextColor": try archive(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
            "BackgroundColor": try archive(NSColor(calibratedWhite: 0, alpha: 0.9)),
            "SelectionColor": try colour(1, 1, 1, 0.5),
            "CommandString": "ssh prod-db.internal.example",
        ]
        let plan = try #require(try self.plan(["Basic": [:], "Homebrew": profile], default: "Homebrew"))
        var ansi: [UInt32?] = Array(repeating: nil, count: 16)
        ansi[1] = 0xFF0000
        ansi[15] = 0xFFFFFF
        let palette = TerminalPalette(name: "Terminal, profile Homebrew", ansi: ansi, foreground: 0x808080, background: 0x000000,
                                      selection: 0x808080)
        #expect(plan.settings == [
            PlannedSetting(.fontSize(14), source: "Font Menlo-Regular 14", note: "sets the editor too: Next Term has one size for both"),
            PlannedSetting(.terminalFontFamily("Menlo"), source: "Font Menlo-Regular"),
            PlannedSetting(.optionAsMeta(true), source: "Use Option as Meta key"),
            PlannedSetting(.terminalPalette(palette), source: "profile Homebrew colours", note: "5 of 20 colours; the others stay Next Term's"),
        ])
        #expect(plan.skipped == [SkippedItem("Run command", "never imported: runs commands")])
        #expect(!"\(plan)".contains("prod-db"))

        // Off a U.S. layout, Option as Meta is offered unticked.
        let layout = try #require(try self.plan(["Pro": ["useOptionAsMetaKey": true]], default: "Pro", usKeyboard: false))
        #expect(layout.settings.first?.ticked == false)
    }

    @Test func archivesAreReadWithoutDecodingObjects() throws {
        #expect(ImportTerminalApp.font(try font("Menlo-Bold", 12.5))! == ("Menlo-Bold", 12.5))
        #expect(ImportTerminalApp.colour(try colour(0, 0.5, 1))?.rgb == 0x0080FF)
        #expect(ImportTerminalApp.colour(try archive(NSColor(calibratedWhite: 0.5, alpha: 0.25)))! == (0x808080, 0.25))
        // Anything else: not a colour, not an archive, too big.
        #expect(ImportTerminalApp.colour(try archive("text")) == nil)
        #expect(ImportTerminalApp.colour(Data("junk".utf8)) == nil)
        #expect(ImportTerminalApp.font(Data(count: 70_000)) == nil)
        for key in ImportTerminalApp.profileKeys { #expect(!SecretGuard.isSecretKey(key), "\(key)") }
    }

    @Test func oddFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = try write(["Pro": [:]], default: "Pro", home: home)
        let app = try #require(ImportTerminalApp.detect(home: home).first)
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: path))
        #expect(ImportTerminalApp.plan(for: app, home: home).skipped == [SkippedItem("com.apple.Terminal.plist", "couldn't be read, so no settings came over")])
        _ = try write(["Basic": [:]], default: "Gone", home: home)
        #expect(ImportTerminalApp.plan(for: app, home: home).skipped.first?.item == "profiles")
        let zed = DetectedApp(kind: .zed, name: "Zed", configPath: path, lastUsed: nil)
        #expect(ImportTerminalApp.plan(for: zed, home: home) == ImportPlan(preset: .nextTerm))
    }
}

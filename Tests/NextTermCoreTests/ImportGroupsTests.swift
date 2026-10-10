import Foundation
import Testing
@testable import NextTermCore

/// What the import window lists for each app: its group, what it can bring, and whether its app was removed, with
/// the app and its version looked for only in the folders a test gives (never the real /Applications).
@Suite struct ImportGroupsTests {
    var fm: FileManager { .default }

    @Test func everySourceHasAGroupAndWhatItBrings() {
        for kind in ImportSourceKind.allCases {
            #expect(kind.canBring.contains(.settings) && kind.canBring.contains(.fonts), "\(kind)")
        }
        let editors = ImportSourceKind.allCases.filter { $0.family == .editors }
        let expected: [ImportSourceKind] = [.vsCode, .vsCodeInsiders, .vsCodium, .cursor, .devinDesktop, .vsCodeFork, .jetBrains, .zed, .sublimeText]
        #expect(editors == expected)
        #expect(ImportSourceKind.terminalApp.family == .terminals && !ImportSourceKind.terminalApp.canBring.contains(.shortcuts))
        #expect(ImportSourceKind.kitty.canBring.contains(.colours) && !ImportSourceKind.kitty.canBring.contains(.projects))
        #expect(ImportFamily.allCases.map(\.title) == ["Editors", "Terminals"])
        #expect(ImportContent.list([.shortcuts, .settings, .fonts]) == "shortcuts, settings and fonts")
        #expect(ImportContent.list([.settings]) == "settings" && ImportContent.list([]).isEmpty)
    }

    @Test func appRemoved() {
        let removed = DetectedApp(kind: .zed, name: "Zed", configPath: "/x", lastUsed: nil)
        #expect(removed.appRemoved)
        let installed = DetectedApp(kind: .zed, name: "Zed", configPath: "/x", lastUsed: nil, appPath: "/Applications/Zed.app")
        #expect(!installed.appRemoved)
        let terminal = DetectedApp(kind: .terminalApp, name: "Terminal", configPath: "/x", lastUsed: nil)
        #expect(!terminal.appRemoved, "Terminal comes with macOS")
    }

    func write(_ text: String, to path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func plist(_ version: String) -> String {
        "<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>"
    }

    /// Zed, iTerm2 and Ghostty are found with their apps and versions; an app not there is an app removed.
    @Test func appsAndVersions() throws {
        let home = canonicalPath(fm.temporaryDirectory.path) + "/nt-groups-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: home) }
        try write("{}", to: home + "/.config/zed/settings.json")
        try write("", to: home + "/Library/Preferences/com.googlecode.iterm2.plist")
        try write("font-size = 13", to: home + "/.config/ghostty/config")
        let apps = home + "/Applications"
        try write(plist("0.205.1"), to: apps + "/Zed Preview.app/Contents/Info.plist")
        try write(plist("3.6.4"), to: apps + "/iTerm.app/Contents/Info.plist")

        let zed = try #require(ImportZed.detect(home: home, applications: [apps]).first)
        #expect(zed.appPath == apps + "/Zed Preview.app" && zed.version == "0.205.1" && !zed.appRemoved)
        let iTerm = try #require(ImportITerm2.detect(home: home, applications: [apps]).first)
        #expect(iTerm.appPath == apps + "/iTerm.app" && iTerm.version == "3.6.4")
        let ghostty = try #require(ImportGhostty.detect(home: home, applications: [apps]).first)
        #expect(ghostty.appPath == nil && ghostty.version == nil && ghostty.appRemoved)
    }
}

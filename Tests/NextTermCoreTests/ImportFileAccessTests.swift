import Foundation
import SQLite3
import Testing
@testable import NextTermCore

/// File access is recorded (the plan's test strategy): for each hand-written fixture home, detection and every app's
/// plan open exactly the files on its list, all inside the home: never a file a link leads out to, and never one on
/// this Mac. The preview an agent gets for each app matches the fixture's golden file (preview.golden.json), with no
/// planted secret in it and nothing left for MCPRedaction to mask. The Cursor fixture's are in MCPImportTests, and
/// one more editor's in its importer's own tests.
@Suite struct ImportFileAccessTests {
    var fm: FileManager { .default }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    /// The files opened equal `expected`, and the previews the fixture's golden file.
    func check(_ name: String, home: String, _ watched: (opened: [String], plans: [(app: DetectedApp, plan: ImportPlan)]),
               expected: [String]) throws {
        #expect(watched.opened == expected, "\(name)")
        #expect(!watched.plans.isEmpty, "\(name)")
        let text = ImportFixtures.previews(watched.plans, home: home)
        let secrets: [String] = ImportFixtures.secrets(in: text)
        #expect(secrets.isEmpty && !text.contains("•••"), "\(name)")
        let golden = try ImportFixtures.golden(name, text)
        #expect(text == golden, "\(name)")
    }

    @Test func editorsBuiltOnVSCode() throws {
        let home = try ImportFixtures.copy("VSCodeFamily")
        defer { remove(home) }
        let apps = [home + "/Applications"]
        let watched = ImportFixtures.watched(home: home, detect: { ImportVSCode.detect(home: home, applications: apps) },
                                             plan: { ImportVSCode.plan(for: $0, home: home, usKeyboard: true, applications: apps, fonts: testFonts) })
        let expected: [String] = [
            ".kiro/extensions/extensions.json",
            ".trae/extensions/extensions.json",
            "Applications/Chat.app/Contents/Resources/app/product.json",
            "Applications/Escape.app/Contents/Resources/app/product.json",
            "Applications/Forky.app/Contents/Resources/app/product.json",
            "Applications/Hidden Token.app/Contents/Resources/app/product.json",
            "Applications/Trae.app/Contents/Resources/app/product.json",
            "Library/Application Support/Forky/User/settings.json",
            "Library/Application Support/Kiro/User/settings.json",
            "Library/Application Support/Positron/User/settings.json",
            "Library/Application Support/Trae/User/settings.json",
        ]
        try check("VSCodeFamily", home: home, watched, expected: expected)
    }

    @Test func jetBrainsIDEs() throws {
        let home = try ImportFixtures.copy("JetBrains")
        defer { remove(home) }
        let apps = [home + "/Applications"]
        let watched = ImportFixtures.watched(home: home, detect: { ImportJetBrains.detect(home: home, applications: apps) }, plan: {
            ImportJetBrains.plan(for: $0, home: home, usKeyboard: true, now: Date(), fonts: testFonts, applications: apps)
        })
        let expected: [String] = [
            ".android-studio/config/options/terminal-font.xml",
            "Applications/Acme.app/Contents/Resources/product-info.json",
            "Applications/Android Studio.app/Contents/Resources/product-info.json",
            "Applications/Android Studio.app/Contents/bin/idea.properties",
            "Applications/Hidden Token.app/Contents/Resources/product-info.json",
            "Applications/PhpStorm.app/Contents/Resources/product-info.json",
            "GoLandSettings/config/options/editor-font.xml",
            "Library/Application Support/JetBrains/GoLand2025.2/idea.properties",
            "Library/Application Support/JetBrains/PhpStorm2026.1/idea.properties",
            "Library/Application Support/JetBrains/PhpStorm2026.1/options/editor.xml",
            "Library/Application Support/JetBrains/PhpStorm2026.1/options/filetypes.xml",
            "Library/Application Support/JetBrains/PhpStorm2026.1/options/ide.general.xml",
            "Library/Application Support/JetBrains/PhpStorm2026.1/options/mac/keymap.xml",
            "Library/Application Support/JetBrains/RubyMine2025.1/idea.properties",
            "Library/Application Support/JetBrains/RubyMine2025.1/options/editor.xml",
            "Library/Application Support/JetBrains/WebStorm2024.2/options/editor.xml",
        ]
        try check("JetBrains", home: home, watched, expected: expected)
    }

    @Test func zed() throws {
        let home = try ImportFixtures.copy("Zed")
        defer { remove(home) }
        for name in ["app", "both-a", "both-b"] { try fm.createDirectory(atPath: home + "/Code/" + name, withIntermediateDirectories: true) }
        let sql = try String(contentsOfFile: home + "/workspaces.sql", encoding: .utf8).replacingOccurrences(of: "HOME/", with: home + "/")
        let database = home + "/Library/Application Support/Zed/db/0-stable/db.sqlite"
        try fm.createDirectory(atPath: (database as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(database, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        let made = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        #expect(made == SQLITE_OK)
        let watched = ImportFixtures.watched(home: home, detect: { ImportZed.detect(home: home, applications: []) },
                                             plan: { ImportZed.plan(for: $0, home: home, fonts: testFonts) })
        let expected: [String] = [
            ".config/zed/keymap.json",
            ".config/zed/settings.json",
            "Library/Application Support/Zed/db/0-stable/db.sqlite",
        ]
        try check("Zed", home: home, watched, expected: expected)
    }

    @Test func iTerm2() throws {
        let home = try ImportFixtures.copy("iTerm2")
        defer { remove(home) }
        let watched = ImportFixtures.watched(home: home, detect: { ImportITerm2.detect(home: home, applications: []) },
                                             plan: { ImportITerm2.plan(for: $0, home: home, fonts: testFonts) })
        let expected: [String] = [
            "Library/Application Support/iTerm2/DynamicProfiles/10-base.json",
            "Library/Application Support/iTerm2/DynamicProfiles/20-work.plist",
            "Library/Application Support/iTerm2/DynamicProfiles/30-orphan.json",
            "Library/Application Support/iTerm2/DynamicProfiles/40-collide.json",
            "Library/Application Support/iTerm2/DynamicProfiles/50-broken.json",
            "Library/Preferences/com.googlecode.iterm2.plist",
        ]
        try check("iTerm2", home: home, watched, expected: expected)
    }

    @Test func cmux() throws {
        let home = try ImportFixtures.copy("cmux")
        defer { remove(home) }
        let apps = [home + "/Applications"]
        let watched = ImportFixtures.watched(home: home, detect: { ImportCmux.detect(home: home, applications: apps) },
                                             plan: { ImportCmux.plan(for: $0, home: home, fonts: testFonts, applications: apps) })
        let expected: [String] = [
            ".config/cmux/cmux.json",
            ".config/ghostty/config",
            "Applications/cmux.app/Contents/Info.plist",
            "Applications/cmux.app/Contents/Resources/ghostty/themes/Night Owl",
            "Library/Application Support/com.cmuxterm.app/config.ghostty",
        ]
        try check("cmux", home: home, watched, expected: expected)
    }

    @Test func kitty() throws {
        let home = try ImportFixtures.copy("kitty")
        defer { remove(home) }
        let watched = ImportFixtures.watched(home: home, detect: { ImportKitty.detect(home: home, applications: []) },
                                             plan: { ImportKitty.plan(for: $0, home: home, fonts: testFonts) })
        let expected: [String] = [
            ".config/kitty/current-theme.conf",
            ".config/kitty/dark-theme.auto.conf",
            ".config/kitty/kitty.conf",
            ".config/kitty/kitty.d/extra/size.conf",
        ]
        try check("kitty", home: home, watched, expected: expected)
    }

    @Test func alacritty() throws {
        let home = try ImportFixtures.copy("Alacritty")
        defer { remove(home) }
        let watched = ImportFixtures.watched(home: home, detect: { ImportAlacritty.detect(home: home, applications: []) },
                                             plan: { ImportAlacritty.plan(for: $0, home: home, fonts: testFonts) })
        let expected: [String] = [
            ".config/alacritty/alacritty.toml",
            ".config/alacritty/broken.toml",
            ".config/alacritty/keys.toml",
            ".config/alacritty/themes/night.toml",
        ]
        try check("Alacritty", home: home, watched, expected: expected)
    }

    @Test func wezTermAndKaku() throws {
        let home = try ImportFixtures.copy("WezTerm")
        defer { remove(home) }
        let watched = ImportFixtures.watched(home: home, detect: { ImportWezTerm.detect(home: home, applications: []) },
                                             plan: { ImportWezTerm.plan(for: $0, home: home, fonts: testFonts) })
        let expected: [String] = [
            ".config/kaku/kaku.lua",
            ".config/wezterm/colors/night-owl.toml",
            ".config/wezterm/wezterm.lua",
        ]
        try check("WezTerm", home: home, watched, expected: expected)
    }
}

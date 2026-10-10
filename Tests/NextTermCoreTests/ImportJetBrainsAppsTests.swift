import Foundation
import Testing
@testable import NextTermCore

/// JetBrains IDEs named by their product-info.json, settings moved by idea.properties, IDEs not used lately and
/// the ignored files, from the hand-written fixture home in Fixtures/Import/JetBrains (never a real Mac's).
@Suite struct ImportJetBrainsAppsTests {
    var fm: FileManager { .default }

    /// The fixture, copied, with each settings folder's files dated `days` back.
    func fixture(_ days: [String: Double] = [:]) throws -> String {
        let home = try ImportFixtures.copy("JetBrains")
        let dated: [String: Double] = [
            "Library/Application Support/JetBrains/PhpStorm2026.1/options": 1,
            "GoLandSettings/config/options": 2,
            ".android-studio/config/options": 3,
            "Library/Application Support/JetBrains/RubyMine2025.1/options": 10,
            "Library/Application Support/JetBrains/WebStorm2024.2/options": 300,
        ].merging(days) { $1 }
        for (folder, daysAgo) in dated {
            let path = home + "/" + folder
            for name in try fm.contentsOfDirectory(atPath: path) {
                try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86400)], ofItemAtPath: path + "/" + name)
            }
        }
        return home
    }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func detect(_ home: String) -> [DetectedApp] {
        ImportJetBrains.detect(home: home, applications: [home + "/Applications"], now: Date())
    }

    func plan(_ app: DetectedApp, _ home: String) -> ImportPlan {
        ImportJetBrains.plan(for: app, home: home, usKeyboard: true, now: Date(), fonts: testFonts,
                             applications: [home + "/Applications"])
    }

    @Test func idesAreNamedByTheirAppAndMovedSettingsAreFollowed() throws {
        let home = try fixture()
        defer { remove(home) }
        let found = detect(home)
        let names = found.map(\.name)
        #expect(names == ["PhpStorm 2026.1", "GoLand 2025.2", "Android Studio 2025.3.4", "RubyMine 2025.1", "WebStorm 2024.2"])
        let support = home + "/Library/Application Support/JetBrains"
        let paths = found.map(\.configPath)
        #expect(paths == [support + "/PhpStorm2026.1", home + "/GoLandSettings/config", home + "/.android-studio/config",
                          support + "/RubyMine2025.1", support + "/WebStorm2024.2"])
        let apps = found.map { $0.appPath.map { ($0 as NSString).lastPathComponent } }
        #expect(apps == ["PhpStorm.app", nil, "Android Studio.app", nil, nil])
        #expect(found.map(\.version) == ["2026.1.1", nil, "2025.3.4", nil, nil])
        #expect(found.map(\.notUsedLately) == [false, false, false, false, true])
        #expect(ImportFixtures.secrets(in: found).isEmpty)
    }

    @Test func productInfoGivesFourKeysOnly() throws {
        let home = try fixture()
        defer { remove(home) }
        let phpStorm = ImportJetBrains.installedIDE(bundle: home + "/Applications/PhpStorm.app")
        #expect(phpStorm == ImportJetBrains.Installed(bundle: home + "/Applications/PhpStorm.app", name: "PhpStorm", version: "2026.1.1",
                                                      vendor: "JetBrains", dataDirectoryName: "PhpStorm2026.1"))
        #expect(ImportJetBrains.installedIDE(bundle: home + "/Applications/Acme.app") == nil)
        #expect(ImportJetBrains.installedIDE(bundle: home + "/Applications/Hidden Token.app") == nil)
        let installed = ImportJetBrains.installedIDEs(applications: [home + "/Applications"], home: home)
        #expect(installed.map(\.name) == ["Android Studio", "PhpStorm"])
        #expect(ImportFixtures.secrets(in: installed).isEmpty)
    }

    @Test func theFixturePlantsItsSecrets() throws {
        let home = try fixture()
        defer { remove(home) }
        for file in ["Applications/PhpStorm.app/Contents/Resources/product-info.json", "outside/keymap.xml",
                     "Library/Application Support/JetBrains/PhpStorm2026.1/options/filetypes.xml"] {
            let text = try String(contentsOfFile: home + "/" + file, encoding: .utf8)
            #expect(!ImportFixtures.secrets(in: text).isEmpty, "\(file)")
        }
    }

    @Test func olderToolboxInstallsAreFound() throws {
        let home = try fixture()
        defer { remove(home) }
        let bundle = home + "/Library/Application Support/JetBrains/Toolbox/apps/PhpStorm/ch-0/261.22158.282/PhpStorm.app"
        try fm.createDirectory(atPath: bundle + "/Contents/Resources", withIntermediateDirectories: true)
        try fm.copyItem(atPath: home + "/Applications/PhpStorm.app/Contents/Resources/product-info.json",
                        toPath: bundle + "/Contents/Resources/product-info.json")
        let installed = ImportJetBrains.installedIDEs(applications: [], home: home)
        #expect(installed.map(\.bundle) == [bundle])
        #expect(detect(home).first?.appPath != nil)
    }

    @Test func aFreshIDEHidesNoStaleOne() throws {
        let home = try fixture(["Library/Application Support/JetBrains/PhpStorm2026.1/options": 400])
        defer { remove(home) }
        let found = detect(home)
        #expect(found.count == 5)
        #expect(found.suffix(2).map(\.name) == ["WebStorm 2024.2", "PhpStorm 2026.1"])
        #expect(found.suffix(2).map(\.notUsedLately) == [true, true])
    }

    @Test func planReadsIgnoredFilesAndNeverFollowsASymlinkOut() throws {
        let home = try fixture()
        defer { remove(home) }
        let found = detect(home)
        let phpStorm = try #require(found.first { $0.name == "PhpStorm 2026.1" })
        let plan = plan(phpStorm, home)
        let hidden = PlannedSetting(.hiddenFiles(["node_modules", "*.log", "vendor"]), source: "options/filetypes.xml ignored files")
        #expect(plan.settings.contains(hidden))
        #expect(plan.skipped.contains(SkippedItem("1 ignored file name", "looked like a credential")))
        #expect(plan.skipped.contains(SkippedItem("1 ignored file name", "not a name the sidebar can hide")))
        // The active keymap's file leads out of the settings folder, so it is never read: no shortcut comes over.
        #expect(plan.shortcuts.isEmpty)
        #expect(plan.skipped.contains(SkippedItem("Keymap “Escaped”", "the JetBrains preset follows JetBrains' macOS keymap, so some keys differ from this one")))
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
        #expect(!String(describing: plan).contains("Browser.app"))
    }

    @Test func planReadsTheMovedFolders() throws {
        let home = try fixture()
        defer { remove(home) }
        let found = detect(home)
        let studio = try #require(found.first { $0.name.hasPrefix("Android Studio") })
        #expect(plan(studio, home).settings.map(\.setting) == [.terminalFontSize(12)])
        let goLand = try #require(found.first { $0.name.hasPrefix("GoLand") })
        #expect(plan(goLand, home).settings.map(\.setting) == [.fontSize(15)])
        let rubyMine = try #require(found.first { $0.name.hasPrefix("RubyMine") })
        let rubyPlan = plan(rubyMine, home)
        #expect(rubyPlan.settings.map(\.setting) == [.softWrap(true)])
        let note = SkippedItem("idea.config.path in idea.properties",
                               "uses a variable; only a full path or ${user.home} is read, so the settings here were read")
        #expect(rubyPlan.skipped.contains(note))
    }

    @Test func configPathLines() {
        let home = "/Users/me"
        func setting(_ text: String) -> ImportJetBrains.ConfigPathSetting { ImportJetBrains.configPathSetting(text, home: home) }
        #expect(setting("idea.config.path=${user.home}/cfg") == .path(canonicalPath("/Users/me/cfg")))
        #expect(setting("  idea.config.path : /opt/ide/config  ") == .path(canonicalPath("/opt/ide/config")))
        #expect(setting("idea.config.path /opt/a\nidea.config.path=/opt/b") == .path(canonicalPath("/opt/b")))
        #expect(setting("# idea.config.path=/opt/a") == .unset)
        #expect(setting("idea.config.path.extra=/opt/a") == .unset)
        #expect(setting("idea.config.path=") == .unset)
        #expect(setting("idea.config.path=config") == .unusable("only a full path is read"))
        let variable = ImportJetBrains.ConfigPathSetting.unusable("uses a variable; only a full path or ${user.home} is read")
        #expect(setting("idea.config.path=${idea.home.path}/config") == variable)
        #expect(setting("idea.config.path=/opt/a\\\n  /b") == variable)
        #expect(setting("idea.config.path=/opt/\(ImportFixtures.plantedSecrets[1])") == .unusable("looked like a credential"))
    }
}

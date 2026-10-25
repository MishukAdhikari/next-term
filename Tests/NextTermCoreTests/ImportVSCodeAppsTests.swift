import Foundation
import SQLite3
import Testing
@testable import NextTermCore

/// Editors built on VS Code found by their product.json or the folder a removed one left, and the keymap
/// extensions that choose the shortcut set. Every test runs on a copy of Fixtures/Import/VSCodeFamily.
@Suite struct ImportVSCodeAppsTests {
    func fixture() throws -> String { try ImportFixtures.copy("VSCodeFamily") }

    func remove(_ home: String) { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func applications(_ home: String) -> [String] { [home + "/Applications"] }

    func support(_ home: String, _ folder: String) -> String { home + "/Library/Application Support/\(folder)/User" }

    func detect(_ home: String) -> [DetectedApp] { ImportVSCode.detect(home: home, applications: applications(home)) }

    func plan(_ app: DetectedApp, _ home: String) -> ImportPlan {
        ImportVSCode.plan(for: app, home: home, usKeyboard: true, applications: applications(home), fonts: testFonts)
    }

    func app(_ home: String, _ name: String) throws -> DetectedApp {
        try #require(detect(home).first { $0.name == name })
    }

    // MARK: detection

    @Test func findsEditorsByProductJSONAndTheFoldersRemovedOnesLeft() throws {
        let home = try fixture()
        defer { remove(home) }
        let found = detect(home)
        #expect(Set(found.map(\.name)) == ["Trae", "Forky", "Kiro", "Positron"])
        #expect(found.allSatisfy { $0.kind == .vsCodeFork && $0.preset == .vsCode })
        let trae = try app(home, "Trae")
        #expect(trae.appPath == home + "/Applications/Trae.app" && trae.version == "1.104.3")
        #expect(trae.configPath == support(home, "Trae"))
        // Unknown to Next Term, named by its own product.json.
        let forky = try app(home, "Forky")
        #expect(forky.appPath == home + "/Applications/Forky.app" && forky.version == "0.3.1")
        // Removed: the folder stayed, the app is gone.
        let kiro = try app(home, "Kiro")
        #expect(kiro.appPath == nil && kiro.version == nil && kiro.configPath == support(home, "Kiro"))
        #expect(ImportFixtures.secrets(in: found).isEmpty)
    }

    @Test func mostRecentlyUsedFirst() throws {
        let home = try fixture()
        defer { remove(home) }
        let now = Date()
        for (folder, days) in [("Trae", 3.0), ("Forky", 1.0), ("Kiro", 9.0), ("Positron", 30.0)] {
            let date = now.addingTimeInterval(-days * 86400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: support(home, folder) + "/settings.json")
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: support(home, folder))
        }
        #expect(detect(home).map(\.name) == ["Forky", "Trae", "Kiro", "Positron"])
    }

    @Test func productJSONKeysAreCheckedOneByOne() throws {
        let home = try fixture()
        defer { remove(home) }
        let apps = home + "/Applications"
        #expect(ImportVSCode.product(bundle: apps + "/Trae.app")
                == ImportVSCode.Product(bundle: apps + "/Trae.app", nameShort: "Trae", dataFolderName: ".trae", sharedDataFolderName: nil, version: "1.104.3"))
        // A folder name that leaves Application Support, or a token where a name should be, is no name.
        let escape = try #require(ImportVSCode.product(bundle: apps + "/Escape.app"))
        #expect(escape.nameShort == nil && escape.dataFolderName == nil)
        let token = try #require(ImportVSCode.product(bundle: apps + "/Hidden Token.app"))
        #expect(token.nameShort == nil && token.version == nil && token.dataFolderName == ".hidden-token")
        // Only apps whose product.json names both folders count.
        let names: [String?] = ImportVSCode.installedProducts(applications: [apps]).map(\.nameShort)
        #expect(names == ["Forky", "Trae"])
        #expect(ImportVSCode.product(bundle: apps + "/Notes.app") == nil)
        #expect(ImportVSCode.installedProducts(applications: [home + "/nowhere"]).isEmpty)
        for bad in ["", ".", "..", "a/b", "x\0y", String(repeating: "a", count: 101)] { #expect(ImportVSCode.plainName(bad) == nil) }
        for bad in ["1.0 beta", "1.0;rm", "", String(repeating: "1", count: 41)] { #expect(ImportVSCode.version(bad) == nil) }
        #expect(ImportVSCode.version("1.95.0-insider+2") == "1.95.0-insider+2")
    }

    @Test func aProductJSONSymlinkedOutOfItsBundleIsNotRead() throws {
        let home = try fixture()
        defer { remove(home) }
        let bundle = home + "/Applications/Linked.app/Contents/Resources/app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bundle + "/product.json",
                                                   withDestinationPath: home + "/Applications/Trae.app/Contents/Resources/app/product.json")
        #expect(ImportVSCode.product(bundle: home + "/Applications/Linked.app") == nil)
        // A whole bundle linked from elsewhere is that bundle: its own files are inside it.
        try FileManager.default.createSymbolicLink(atPath: home + "/Applications/Alias.app", withDestinationPath: home + "/Applications/Trae.app")
        #expect(ImportVSCode.product(bundle: home + "/Applications/Alias.app")?.nameShort == "Trae")
    }

    @Test func anInstalledKnownAppIsMarkedAndItsFolderFoundOnce() throws {
        let home = try fixture()
        defer { remove(home) }
        // Kiro reinstalled: found by its product.json, once, with its app.
        try FileManager.default.createDirectory(atPath: home + "/Applications/Kiro.app/Contents/Resources/app", withIntermediateDirectories: true)
        try #"{"nameShort": "Kiro", "dataFolderName": ".kiro", "version": "0.5.0"}"#
            .write(toFile: home + "/Applications/Kiro.app/Contents/Resources/app/product.json", atomically: true, encoding: .utf8)
        let kiro = detect(home).filter { $0.name == "Kiro" }
        #expect(kiro.count == 1 && kiro.first?.appPath == home + "/Applications/Kiro.app" && kiro.first?.version == "0.5.0")
        // A known bundle without a product.json still counts as installed.
        try FileManager.default.createDirectory(atPath: home + "/Applications/Positron.app/Contents", withIntermediateDirectories: true)
        #expect(try app(home, "Positron").appPath == home + "/Applications/Positron.app")
    }

    @Test func devinDesktopsFolderReplacesWindsurfsEvenWhenWindsurfIsInstalled() throws {
        let home = try fixture()
        defer { remove(home) }
        for folder in ["Devin", "Windsurf"] {
            try FileManager.default.createDirectory(atPath: support(home, folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: home + "/Applications/Windsurf.app/Contents/Resources/app", withIntermediateDirectories: true)
        try #"{"nameShort": "Windsurf", "dataFolderName": ".windsurf"}"#
            .write(toFile: home + "/Applications/Windsurf.app/Contents/Resources/app/product.json", atomically: true, encoding: .utf8)
        let found = detect(home).filter { $0.kind == .devinDesktop }
        #expect(found.map(\.name) == ["Devin Desktop"])
    }

    // MARK: keymap extensions

    @Test func intelliJKeybindingsChooseTheJetBrainsSet() throws {
        let home = try fixture()
        defer { remove(home) }
        let kiro = try app(home, "Kiro")
        let plan = plan(kiro, home)
        #expect(plan.preset == .jetBrains)
        #expect(plan.skipped.contains(SkippedItem("IntelliJ IDEA Keybindings extension",
                                                  "its own keys aren't read; JetBrains (macOS) shortcuts are offered instead of VS Code’s")))
        #expect(plan.skipped.contains(SkippedItem("Emacs keys (Awesome Emacs Keymap extension)", "Next Term has no Emacs shortcut set")))
        // The rest is a count: the same id twice is one extension, entries without an id aren't any.
        #expect(plan.skipped.contains(SkippedItem("1 other extension", "extensions aren't imported")))
        #expect(!String(describing: plan).contains("redhat"))
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
        #expect(plan.skipped.contains(SkippedItem("kiroAgent.apiToken", "never imported: can hold secrets")))
    }

    @Test func aTurnedOffKeymapExtensionChoosesNothing() throws {
        let home = try fixture()
        defer { remove(home) }
        let kiro = try app(home, "Kiro")
        let database = kiro.configPath + "/globalStorage/state.vscdb"
        try FileManager.default.createDirectory(atPath: kiro.configPath + "/globalStorage", withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(database, &db) == SQLITE_OK)
        let disabled = #"[{"id":"k--kato.intellij-idea-keybindings","uuid":"f09f3f8b"}]"#
        let sql = "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
            + "INSERT INTO ItemTable VALUES ('extensionsIdentifiers/disabled', '\(disabled)');"
            + "INSERT INTO ItemTable VALUES ('kiroAuth/token', '\(ImportFixtures.plantedSecrets[0])');"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(ImportVSCode.disabledExtensions(user: kiro.configPath) == ["k--kato.intellij-idea-keybindings"])
        let plan = plan(kiro, home)
        #expect(plan.preset == .vsCode)
        #expect(!plan.skipped.contains { $0.item.contains("IntelliJ") })
        // Turned off, it is one of the others.
        #expect(plan.skipped.contains(SkippedItem("2 other extensions", "extensions aren't imported")))
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    @Test func vimExtensionAndVimSettingsAddANote() throws {
        let home = try fixture()
        defer { remove(home) }
        let trae = try app(home, "Trae")
        let plan = plan(trae, home)
        #expect(plan.preset == .vsCode)
        #expect(plan.skipped.contains(SkippedItem("Vim keys (Vim extension)", "Next Term has no Vim mode yet")))
        #expect(!plan.skipped.contains { $0.item.contains("vim.* setting") }) // said once
        // Three others, one of them an id that looks like a token: counted, never named.
        #expect(plan.skipped.contains(SkippedItem("3 other extensions", "extensions aren't imported")))
        let settings: [ImportedSetting] = plan.settings.map(\.setting)
        #expect(settings == [.fontSize(14), .softWrap(true), .sidebarSingleClick(true)]) // the last, the app's own click
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
        // The extension removed, the settings still say Vim.
        try FileManager.default.removeItem(atPath: home + "/.trae/extensions/extensions.json")
        let settingsOnly = self.plan(trae, home)
        #expect(settingsOnly.skipped.contains(SkippedItem("Vim keys (3 vim.* settings)", "Next Term has no Vim mode yet")))
        #expect(!settingsOnly.skipped.contains { $0.item.hasSuffix("extensions") || $0.item.hasSuffix("extension") })
    }

    @Test func extensionsSymlinkedOutOfTheirFolderAreNeverRead() throws {
        let home = try fixture()
        defer { remove(home) }
        let forky = try app(home, "Forky")
        #expect(ImportVSCode.extensions(home: home, dataFolders: [".forky"], user: forky.configPath) == nil)
        let plan = plan(forky, home)
        #expect(plan.preset == .vsCode && !plan.skipped.contains { $0.item.contains("extension") })
        let settings: [ImportedSetting] = plan.settings.map(\.setting)
        #expect(settings == [.fontSize(16), .sidebarSingleClick(true)])
    }

    @Test func dataFoldersComeFromTheInstalledAppOrTheKnownList() throws {
        let home = try fixture()
        defer { remove(home) }
        // Installed: product.json's dataFolderName. Removed: the known list's.
        #expect(ImportVSCode.installedProduct(for: try app(home, "Trae"), applications: applications(home))?.dataFolderName == ".trae")
        let kiro = try app(home, "Kiro")
        #expect(ImportVSCode.installedProduct(for: kiro, applications: applications(home)) == nil)
        #expect(ImportVSCode.source(folder: ImportVSCode.settingsFolder(of: kiro))?.dataFolders == [".kiro"])
        // Found by nameShort when the detected app doesn't carry its bundle.
        let bare = DetectedApp(kind: .vsCodeFork, name: "Forky", configPath: support(home, "Forky"), lastUsed: nil)
        #expect(ImportVSCode.installedProduct(for: bare, applications: applications(home))?.bundle == home + "/Applications/Forky.app")
        // A data folder name that leaves the home folder is never used.
        #expect(ImportVSCode.extensions(home: home + "/Library", dataFolders: ["../.kiro"], user: kiro.configPath) == nil)
    }

    @Test func anExtensionsFolderThatWasNeverCheckedIsReadOnlyFromTheInstalledApp() throws {
        let home = try fixture()
        defer { remove(home) }
        // Qoder removed: its settings folder is known, its extensions folder isn't, so nothing in ~/.qoder is read.
        try FileManager.default.createDirectory(atPath: support(home, "Qoder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.qoder/extensions", withIntermediateDirectories: true)
        try #"[{"identifier": {"id": "k--kato.intellij-idea-keybindings"}}]"#
            .write(toFile: home + "/.qoder/extensions/extensions.json", atomically: true, encoding: .utf8)
        let qoder = try app(home, "Qoder")
        #expect(qoder.kind == .vsCodeFork && qoder.appPath == nil)
        #expect(ImportVSCode.source(folder: "Qoder")?.dataFolders == [])
        #expect(plan(qoder, home).preset == .vsCode)
        // Installed, its product.json names the folder, and the IntelliJ keys there choose the JetBrains set.
        let bundle = home + "/Applications/Qoder.app/Contents/Resources/app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        try #"{"nameShort": "Qoder", "dataFolderName": ".qoder", "version": "0.2.1"}"#
            .write(toFile: bundle + "/product.json", atomically: true, encoding: .utf8)
        let installed = try app(home, "Qoder")
        #expect(installed.appPath == home + "/Applications/Qoder.app" && installed.version == "0.2.1")
        #expect(plan(installed, home).preset == .jetBrains)
    }

    @Test func keymapExtensionIds() {
        #expect(ImportVSCode.keymapExtension("K--KATO.intellij-idea-keybindings")?.kind == .jetBrains)
        // Each new editor's own copy of the IntelliJ keys.
        #expect(ImportVSCode.keymapExtension("someone.antigravity-jetbrains-keybindings")
                == ImportVSCode.KeymapExtension(label: "a JetBrains keymap extension", kind: .jetBrains))
        #expect(ImportVSCode.keymapExtension("someone.intellij-keymap")?.kind == .jetBrains)
        #expect(ImportVSCode.keymapExtension("someone.jetbrains-theme") == nil)
        #expect(ImportVSCode.keymapExtension("asvetliakov.vscode-neovim")?.kind == .vim)
        #expect(ImportVSCode.keymapExtension("ms-vscode.atom-keybindings")?.kind == .other("Atom"))
        #expect(ImportVSCode.keymapExtension("esbenp.prettier-vscode") == nil)
        // Only the editor's own label is ever shown.
        let rows = ImportVSCode.keymapRows(ImportVSCode.Extensions(count: 2, keymaps: [ImportVSCode.keymapExtension("ms-vscode.atom-keybindings")!]),
                                           vimSettings: 0, preset: .vsCode)
        #expect(rows.preset == .vsCode)
        #expect(rows.skipped == [SkippedItem("Atom keys (Atom Keymap extension)", "Next Term has no Atom shortcut set"),
                                 SkippedItem("1 other extension", "extensions aren't imported")])
        // An app whose own keymap already chose another set keeps it.
        let jetBrains = ImportVSCode.Extensions(count: 1, keymaps: [ImportVSCode.keymapExtension("k--kato.intellij-idea-keybindings")!])
        #expect(ImportVSCode.keymapRows(jetBrains, vimSettings: 0, preset: .nextTerm).preset == .nextTerm)
        #expect(ImportVSCode.keymapRows(nil, vimSettings: 0, preset: .vsCode).skipped.isEmpty)
    }

    @Test func theRemovedAppsInTheKnownListAreCheckedNames() {
        // Each folder is the app's product.json nameShort, each data folder its dataFolderName.
        let folders = ImportVSCode.sources.map(\.folder)
        #expect(Set(folders).count == folders.count)
        #expect(folders.allSatisfy { ImportVSCode.plainName($0) == $0 })
        #expect(ImportVSCode.sources.flatMap(\.dataFolders).allSatisfy { $0.hasPrefix(".") && ImportVSCode.plainName($0) == $0 })
        #expect(Set(ImportVSCode.sources.map(\.kind)).isSubset(of: ImportVSCode.family))
    }
}

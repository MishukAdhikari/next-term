import Foundation
import Testing
@testable import NextTermCore

/// Editors built on VS Code found by their product.json or the folder a removed one left. Every test runs on a
/// copy of Fixtures/Import/VSCodeFamily.
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
        #expect(ImportVSCode.installedProducts(applications: [apps]).map(\.nameShort) == ["Forky", "Trae"])
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

    @Test func theRemovedAppsInTheKnownListAreCheckedNames() {
        // Each folder is the app's product.json nameShort, each data folder its dataFolderName.
        let folders = ImportVSCode.sources.map(\.folder)
        #expect(Set(folders).count == folders.count)
        #expect(folders.allSatisfy { ImportVSCode.plainName($0) == $0 })
        #expect(ImportVSCode.sources.flatMap(\.dataFolders).allSatisfy { $0.hasPrefix(".") && ImportVSCode.plainName($0) == $0 })
        #expect(Set(ImportVSCode.sources.map(\.kind)).isSubset(of: ImportVSCode.family))
    }
}

import Foundation
import Testing
@testable import NextTermCore

extension PlannedSetting {
    /// The row an import adds for the other app's own click when its settings say nothing (`addSingleClickDefault`).
    var isClickDefault: Bool {
        guard case .sidebarSingleClick = setting else { return false }
        return source.contains("(not set:") || source == "Zed's project panel"
    }
}

extension ImportPlan {
    /// This plan without the row for the other app's own click (ImportClickDefaultTests checks it): for the tests
    /// about everything else.
    var droppingClickDefault: ImportPlan {
        var plan = self
        plan.settings.removeAll(where: \.isClickDefault)
        return plan
    }
}

/// The sidebar's click an import sets: what the other app's settings say, or its own default when they say nothing,
/// and nothing for an app with no file tree. One editor's are in its importer's own tests.
@Suite struct ImportClickDefaultTests {
    var fm: FileManager { .default }

    func home() throws -> String {
        let home = canonicalPath(fm.temporaryDirectory.path) + "/nt-click-" + String(UUID().uuidString.prefix(8))
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    func write(_ text: String, to path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func clickRows(_ plan: ImportPlan) -> [PlannedSetting] {
        plan.settings.filter { if case .sidebarSingleClick = $0.setting { return true } else { return false } }
    }

    // MARK: the VS Code family

    /// The plan for a VS Code family app whose User folder holds `settings` (nil: no settings.json).
    func vsCode(_ settings: String?, kind: ImportSourceKind = .vsCode, name: String = "VS Code") throws -> ImportPlan {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let user = home + "/Library/Application Support/Code/User"
        try fm.createDirectory(atPath: user, withIntermediateDirectories: true)
        if let settings { try write(settings, to: user + "/settings.json") }
        let app = DetectedApp(kind: kind, name: name, configPath: user, lastUsed: nil)
        return ImportVSCode.plan(for: app, home: home, usKeyboard: true, applications: [], fonts: testFonts)
    }

    @Test func vsCodeFamilyUsesTheAppsDefaultWhenOpenModeIsNotSet() throws {
        let fallback = PlannedSetting(.sidebarSingleClick(true), source: "workbench.list.openMode (not set: singleClick)", note: "VS Code's default")
        #expect(clickRows(try vsCode(nil)) == [fallback])
        #expect(clickRows(try vsCode("{}")) == [fallback])
        #expect(clickRows(try vsCode(#"{"editor.fontSize": 13}"#)) == [fallback])
        for kind in [ImportSourceKind.vsCode, .vsCodeInsiders, .vsCodium, .cursor, .devinDesktop, .vsCodeFork] {
            let rows = clickRows(try vsCode(nil, kind: kind, name: "Forky"))
            #expect(rows.map(\.setting) == [.sidebarSingleClick(true)] && rows.first?.note == "Forky's default", "\(kind)")
        }
    }

    @Test func vsCodeFamilyFollowsOpenModeWhenItIsSet() throws {
        #expect(clickRows(try vsCode(#"{"workbench.list.openMode": "doubleClick"}"#))
                == [PlannedSetting(.sidebarSingleClick(false), source: "workbench.list.openMode doubleClick")])
        #expect(clickRows(try vsCode(#"{"workbench.list.openMode": "singleClick"}"#))
                == [PlannedSetting(.sidebarSingleClick(true), source: "workbench.list.openMode singleClick")])
    }

    /// A settings.json that can't be read, or a value not recognised, may say anything: no default is assumed.
    @Test func vsCodeFamilyAssumesNothingWhenTheFileCantBeRead() throws {
        #expect(clickRows(try vsCode("{ \"editor.fontSize\": ")).isEmpty)
        #expect(clickRows(try vsCode("[1, 2]")).isEmpty)
        let odd = try vsCode(#"{"workbench.list.openMode": "tripleClick"}"#)
        #expect(clickRows(odd).isEmpty && odd.skipped.contains(SkippedItem("workbench.list.openMode", "value not recognised")))
        // A settings.json too big to be one.
        #expect(clickRows(try vsCode("{\"a\": \"" + String(repeating: "x", count: 5 << 20) + "\"}")).isEmpty)
    }

    /// Next Term has one switch for files and folders: a folder click that differs is listed as skipped.
    @Test func vsCodeFamilyReportsAFolderClickThatDiffers() throws {
        let same = "Next Term opens folders with the same click as files"
        let differs = try vsCode(#"{"workbench.list.openMode": "singleClick", "workbench.tree.expandMode": "doubleClick"}"#)
        #expect(differs.singleClick == true && differs.skipped.contains(SkippedItem("workbench.tree.expandMode doubleClick", same)))
        let defaultDiffers = try vsCode(#"{"workbench.tree.expandMode": "doubleClick"}"#)
        #expect(defaultDiffers.singleClick == true && defaultDiffers.skipped.contains(SkippedItem("workbench.tree.expandMode doubleClick", same)))
        let offDiffers = try vsCode(#"{"workbench.list.openMode": "doubleClick", "workbench.tree.expandMode": "singleClick"}"#)
        #expect(offDiffers.singleClick == false && offDiffers.skipped.contains(SkippedItem("workbench.tree.expandMode singleClick", same)))
        for agreeing in [#"{"workbench.tree.expandMode": "singleClick"}"#,
                         #"{"workbench.list.openMode": "doubleClick", "workbench.tree.expandMode": "doubleClick"}"#] {
            let plan = try vsCode(agreeing)
            #expect(!plan.skipped.contains { $0.item.hasPrefix("workbench.tree.expandMode") }, "\(agreeing)")
            #expect(!plan.skipped.contains { $0.item.contains("expandMode") }, "not among the other settings either: \(agreeing)")
        }
        let odd = try vsCode(#"{"workbench.tree.expandMode": 2}"#)
        #expect(odd.skipped.contains(SkippedItem("workbench.tree.expandMode", "value not recognised")))
    }

    // MARK: Zed

    func zed(_ settings: String) throws -> ImportPlan {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        try write(settings, to: home + "/.config/zed/settings.json")
        let app = DetectedApp(kind: .zed, name: "Zed", configPath: home + "/.config/zed", lastUsed: nil)
        return ImportZed.plan(for: app, home: home, fonts: testFonts)
    }

    @Test func zedAlwaysOpensOnASingleClick() throws {
        let row = PlannedSetting(.sidebarSingleClick(true), source: "Zed's project panel",
                                 note: "Zed opens files and folders with a single click; no setting changes that")
        #expect(clickRows(try zed("{}")) == [row])
        #expect(clickRows(try zed(#"{"buffer_font_size": 15}"#)) == [row])
        let broken = try zed("{ not json")
        #expect(clickRows(broken) == [row])
        #expect(broken.skipped.contains(SkippedItem("settings.json", "isn't valid JSON, so none of its settings came over")))
    }

    // MARK: JetBrains

    func jetBrains(_ files: [String: String]) throws -> ImportPlan {
        let home = try home()
        defer { try? fm.removeItem(atPath: home) }
        let config = home + "/Library/Application Support/JetBrains/PhpStorm2026.1"
        try fm.createDirectory(atPath: config + "/options", withIntermediateDirectories: true)
        for (path, text) in files { try write(text, to: config + "/" + path) }
        let app = DetectedApp(kind: .jetBrains, name: "PhpStorm 2026.1", configPath: config, lastUsed: nil)
        return ImportJetBrains.plan(for: app, home: home, usKeyboard: true, now: Date(), fonts: testFonts)
    }

    func component(_ name: String, _ options: [(String, String)]) -> String {
        let rows = options.map { "    <option name=\"\($0.0)\" value=\"\($0.1)\" />" }.joined(separator: "\n")
        return "<application>\n  <component name=\"\(name)\">\n\(rows)\n  </component>\n</application>\n"
    }

    func projectView(_ options: [(String, String)]) -> [String: String] {
        ["options/projectView.xml": component("ProjectViewSharedSettings", options)]
    }

    @Test func jetBrainsOpensOnADoubleClickUnlessItsOptionsSayOtherwise() throws {
        let fallback = PlannedSetting(.sidebarSingleClick(false), source: "options/projectView.xml (not set: double click)",
                                      note: "JetBrains IDEs' default")
        #expect(clickRows(try jetBrains([:])) == [fallback])
        #expect(clickRows(try jetBrains(projectView([("hideEmptyMiddlePackages", "true")]))) == [fallback])
        #expect(clickRows(try jetBrains(projectView([("autoscrollToSource", "true")])))
                == [PlannedSetting(.sidebarSingleClick(true), source: "options/projectView.xml autoscrollToSource true")])
        let previewTab = ["options/ui.lnf.xml": component("UISettings", [("OPEN_IN_PREVIEW_TAB_IF_POSSIBLE", "true")])]
        #expect(clickRows(try jetBrains(previewTab))
                == [PlannedSetting(.sidebarSingleClick(true), source: "options/ui.lnf.xml OPEN_IN_PREVIEW_TAB_IF_POSSIBLE true")])
        var both = projectView([("autoscrollToSource", "false")])
        both["options/ui.lnf.xml"] = component("UISettings", [("OPEN_IN_PREVIEW_TAB_IF_POSSIBLE", "false")])
        #expect(clickRows(try jetBrains(both))
                == [PlannedSetting(.sidebarSingleClick(false), source: "options/projectView.xml autoscrollToSource false")])
        // Either one on is enough.
        var one = projectView([("autoscrollToSource", "false")])
        one["options/ui.lnf.xml"] = component("UISettings", [("OPEN_IN_PREVIEW_TAB_IF_POSSIBLE", "true")])
        #expect(try jetBrains(one).singleClick == true)
    }

    @Test func jetBrainsReportsAFolderClickThatDiffersAndValuesItCantUse() throws {
        let folders = try jetBrains(projectView([("openDirectoriesWithSingleClick", "true")]))
        #expect(folders.singleClick == false)
        #expect(folders.skipped.contains(SkippedItem("options/projectView.xml openDirectoriesWithSingleClick true",
                                                     "Next Term opens folders with the same click as files")))
        let agreeing = try jetBrains(projectView([("autoscrollToSource", "true"), ("openDirectoriesWithSingleClick", "true")]))
        #expect(agreeing.singleClick == true && !agreeing.skipped.contains { $0.item.contains("openDirectoriesWithSingleClick") })
        let odd = try jetBrains(projectView([("autoscrollToSource", "sometimes")]))
        #expect(clickRows(odd).isEmpty)
        #expect(odd.skipped.contains(SkippedItem("options/projectView.xml autoscrollToSource", "not a value Next Term can use")))
        // A file that is there but isn't XML may set it: nothing assumed.
        #expect(clickRows(try jetBrains(["options/projectView.xml": "\u{0}not xml"])).isEmpty)
    }

    // MARK: terminals and files

    @Test func terminalsLeaveTheClickAlone() {
        for kind in ImportSourceKind.allCases {
            #expect((kind.singleClickDefault == nil) == (kind.family == .terminals), "\(kind)")
        }
        var plan = ImportPlan(preset: .nextTerm)
        plan.addSingleClickDefault(for: .ghostty, source: "x", note: "y")
        #expect(plan.settings.isEmpty)
    }

    /// A single settings file an agent names, or a project's own: what it says, never the app's default.
    @Test func aFileOnItsOwnSaysNothingOfTheAppsDefault() throws {
        for text in ["{}", #"{"editor.fontSize": 13}"#] {
            let plan = try MCPImport.filePlan(text: text, format: .vsCodeSettings, name: "settings.json", preset: .nextTerm,
                                              projectSettings: false, usKeyboard: true, fonts: testFonts, home: "/nowhere").get()
            #expect(plan.singleClick == nil, "\(text)")
        }
        let set = try MCPImport.filePlan(text: #"{"workbench.list.openMode": "singleClick", "workbench.tree.expandMode": "doubleClick"}"#,
                                         format: .vsCodeSettings, name: "settings.json", preset: .nextTerm, projectSettings: false,
                                         usKeyboard: true, fonts: testFonts, home: "/nowhere").get()
        #expect(set.singleClick == true)
        #expect(set.skipped.contains(SkippedItem("workbench.tree.expandMode doubleClick", "Next Term opens folders with the same click as files")))
    }
}

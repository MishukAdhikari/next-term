import Foundation
import SQLite3
import Testing
@testable import NextTermCore

/// The import tools for agents (list_import_sources, preview_import, apply_import, undo_import): their own list, not
/// always loaded; answers built from the importers' plans with the window's rows and ids; nothing secret, no home
/// folder and no settings folder in what an agent gets. The plans come from the hand-written Cursor fixture
/// (Fixtures/Import/Cursor), never a real Mac's files.
@Suite struct MCPImportToolTests {
    let names = ["list_import_sources", "preview_import", "apply_import", "undo_import"]

    @Test func theImportToolsAreTheirOwnListAndNotAlwaysLoaded() throws {
        #expect(MCPServer.importTools.map(\.name) == names)
        for name in names {
            let tool = try #require(MCPServer.tool(named: name))
            #expect(MCPServer.isImportTool(name) && !MCPServer.isControlTool(name), "\(name)")
            #expect(!tool.alwaysLoad, "\(name)")
            #expect(tool.meta["anthropic/alwaysLoad"] == nil, "\(name)")
            #expect(!tool.openWorld, "\(name)")
            let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) as? [String: Any]
            #expect(schema?["type"] as? String == "object", "\(name)")
            #expect(tool.description.contains("This Mac only"), "\(name)")
        }
        // Every other tool stays loaded.
        for tool in MCPServer.tools where !MCPServer.isImportTool(tool.name) { #expect(tool.alwaysLoad, "\(tool.name)") }
        #expect(MCPServer.tool(named: "list_import_sources")?.scope == .read)
        #expect(MCPServer.tool(named: "preview_import")?.scope == .read)
        #expect(MCPServer.tool(named: "apply_import")?.scope == .write)
        #expect(MCPServer.tool(named: "undo_import")?.scope == .write)
    }

    @Test func theImportToolsAreAnnotatedAndWordedHonestly() throws {
        let timeouts: [String: TimeInterval] = ["list_import_sources": 15, "preview_import": 30, "apply_import": 60, "undo_import": 60]
        for name in names {
            let tool = try #require(MCPServer.tool(named: name))
            let reads = name == "list_import_sources" || name == "preview_import"
            #expect(tool.readOnly == reads && !tool.destructive && tool.idempotent, "\(name)")
            #expect(tool.timeout == timeouts[name], "\(name)")
        }
        let list = MCPServer.tool(named: "list_import_sources")?.description ?? ""
        #expect(list.contains("instead of reading those apps' files yourself") && list.contains("no settings file is read"))
        let apply = MCPServer.tool(named: "apply_import")?.description ?? ""
        #expect(apply.contains("Only the user's Apply changes anything") && apply.contains("they may change the rows"))
        #expect(apply.contains("asked on the Mac first") && apply.contains("pending") && apply.contains("changed_since_preview"))
        let undo = MCPServer.tool(named: "undo_import")?.description ?? ""
        #expect(undo.contains("asked on the Mac first") && undo.contains("stale_undo_id"))
        for name in names { #expect(MCPServer.instructions.contains(name), "\(name)") }
    }

    // MARK: the Cursor fixture

    var fm: FileManager { .default }

    /// The fixture, copied, with its project folders and its state database.
    func fixture() throws -> String {
        let home = try ImportFixtures.copy("Cursor")
        try fm.createDirectory(atPath: home + "/Code/web", withIntermediateDirectories: true)
        let folder = home + "/Library/Application Support/Cursor/User/globalStorage"
        let sql = try String(contentsOfFile: folder + "/state.sql", encoding: .utf8).replacingOccurrences(of: "HOME/", with: home + "/")
        var db: OpaquePointer?
        guard sqlite3_open(folder + "/state.vscdb", &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return home
    }

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    func cursor(_ home: String) throws -> DetectedApp {
        let apps = ImportVSCode.detect(home: home, applications: [home + "/Applications"])
        return try #require(apps.first { $0.kind == .cursor })
    }

    func plan(_ app: DetectedApp, home: String) -> ImportPlan {
        ImportVSCode.plan(for: app, home: home, usKeyboard: true, applications: [home + "/Applications"], fonts: testFonts)
    }

    /// Next Term's commands with no keys at all, so no row clashes.
    var noKeys: [String: KeyChord?] { Dictionary(uniqueKeysWithValues: ImportShortcuts.titles.keys.map { ($0, KeyChord?.none) }) }

    func context(_ home: String, isCurrent: @escaping (ImportedSetting) -> Bool = { _ in false }) -> MCPImport.PreviewContext {
        MCPImport.PreviewContext(currentPreset: .nextTerm, presetLines: ["Split Right   ⌘D → ⌘\\"], keysNow: noKeys,
                                 title: { "\($0.key) title" }, isCurrent: isCurrent, home: home)
    }

    func preview(_ home: String, isCurrent: @escaping (ImportedSetting) -> Bool = { _ in false }) throws -> [String: Any] {
        let app = try cursor(home)
        let raw = plan(app, home: home)
        let settled = raw.settlingShortcuts(current: noKeys)
        return MCPImport.preview(source: app.name, plan: settled, planID: MCPImport.planID(raw), context: context(home, isCurrent: isCurrent))
    }

    // MARK: listing

    /// AE1: the listing is built from the apps found alone (folders and dates), and names no settings folder.
    @Test func theListingNamesAppsNotTheirFolders() throws {
        let home = try fixture()
        defer { remove(home) }
        let apps = ImportVSCode.detect(home: home, applications: [home + "/Applications"])
        let listing = MCPImport.listing(apps, currentPreset: .nextTerm, last: nil)
        let sources = try #require(listing["sources"] as? [[String: Any]])
        let cursor = try #require(sources.first { $0["id"] as? String == "cursor" })
        #expect(cursor["name"] as? String == "Cursor" && cursor["family"] as? String == "editors")
        #expect(cursor["app_installed"] as? Bool == true && cursor["version"] as? String == "1.7.40")
        #expect(cursor["shortcut_set"] as? String == "VS Code" && cursor["not_used_lately"] as? Bool == false)
        #expect(cursor["can_bring"] as? [String] == ["shortcuts", "settings", "fonts", "colours", "projects"])
        #expect(listing["file_formats"] as? [String] == ["vscode-settings", "vscode-keybindings"])
        #expect(listing["current_shortcut_set"] as? String == "Next Term")
        #expect(listing["last_import"] is NSNull)
        let text = MCPImport.text(listing, home: home, hiding: apps.map(\.configPath))
        #expect(!text.contains(home) && !text.contains("Application Support") && !text.contains("/Users/"))
        #expect(ImportFixtures.secrets(in: text).isEmpty)
    }

    @Test func idsAreSlugsOfNamesAndUnique() {
        let apps = ["Cursor", "PhpStorm 2026.1", "VS Code", "VS Code", "Zed Preview"].map {
            DetectedApp(kind: .vsCode, name: $0, configPath: "/nonexistent", lastUsed: nil)
        }
        #expect(MCPImport.ids(of: apps) == ["cursor", "phpstorm-2026.1", "vs-code", "vs-code-2", "zed-preview"])
        #expect(MCPImport.source("PhpStorm 2026.1", in: apps)?.id == "phpstorm-2026.1")
        #expect(MCPImport.source("ZED-PREVIEW", in: apps)?.app.name == "Zed Preview")
        #expect(MCPImport.source("vim", in: apps) == nil)
    }

    @Test func theLastImportIsNamedByItsUndoID() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = ImportSnapshot(id: "AB12-CD", date: date, source: "Zed", summary: "3 settings", before: [:], touched: ["fontSize"], after: [:])
        #expect(MCPImport.undoID(snapshot) == "imp-ab12-cd")
        let old = ImportSnapshot(id: nil, date: date, source: "Zed", summary: "3 settings", before: [:], touched: ["fontSize"], after: nil)
        #expect(MCPImport.undoID(old) == "imp-1760000000")
        let last = MCPImport.lastImport(snapshot) as? [String: Any]
        #expect(last?["undo_id"] as? String == "imp-ab12-cd" && last?["source"] as? String == "Zed" && last?["summary"] as? String == "3 settings")
    }

    @Test func theTargetsCoverEverySettingAnImportSets() {
        let settings: [ImportedSetting] = [
            .fontSize(13), .terminalFontSize(13), .editorLineHeight(1.2), .softWrap(true), .optionAsMeta(true), .terminalPosition("bottom"),
            .sidebarSide("left"), .editorFontFamily("Menlo"), .terminalFontFamily("Menlo"), .terminalPalette(TerminalPalette(name: "x")),
            .terminalScrollback(1_000), .terminalStartFolder("project"), .terminalCursorShape("bar"), .terminalCursorBlink(true),
            .trimTrailingWhitespace(true), .insertFinalNewline(true), .hiddenFiles([]), .sidebarSingleClick(true), .backgroundFetch("5"),
            .diffLayout("unified"), .currentLineBlame(true), .openProjectsIn("ask"), .launchOpens("welcome"),
        ]
        let keys: [String] = MCPImport.settingTargets.map(\.key)
        #expect(Set(keys) == Set(settings.map(\.key)))
        let targets = MCPImport.targets(commands: [("goToFile:", "Go to File…", KeyChord(key: "p", command: true))])
        let first: [String: Any] = (targets["commands"] as? [[String: Any]])?.first ?? [:]
        let id: String? = first["id"] as? String
        let key: String? = first["key"] as? String
        #expect(id == "key:goToFile:" && key == "⌘P")
        let listed: [[String: Any]] = targets["settings"] as? [[String: Any]] ?? []
        #expect(listed.count == settings.count)
    }

    // MARK: preview

    /// AE2: a token under terminal.integrated.env.osx, an API key setting, a key binding's args and Cursor's sign-in rows
    /// never come out: the keys are named with why, the values appear nowhere, and MCPRedaction finds nothing to hide.
    @Test func thePreviewNamesSecretKeysNeverTheirValues() throws {
        let home = try fixture()
        defer { remove(home) }
        let answer = try preview(home)
        let json = MCPServer.json(answer)
        #expect(ImportFixtures.secrets(in: json).isEmpty)
        #expect(MCPRedaction.redact(json).count == 0)
        #expect(!json.contains("cursorAuth") && !json.contains("OPENAI_API_KEY") && !json.contains("prettier"))
        let skipped = try #require(answer["not_brought_over"] as? [[String: String]])
        let reasons = Dictionary(skipped.map { ($0["item"] ?? "", $0["reason"] ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(reasons["terminal.integrated.env.osx"] == "never imported: can hold secrets")
        #expect(reasons["cursor.general.apiKey"] == "never imported: can hold secrets")
        let text = MCPImport.text(answer, home: home, hiding: [try cursor(home).configPath])
        #expect(!text.contains(home) && ImportFixtures.secrets(in: text).isEmpty)
    }

    @Test func thePreviewHasTheWindowsRowsWithIDs() throws {
        let home = try fixture()
        defer { remove(home) }
        let answer = try preview(home)
        #expect(answer["source"] as? String == "Cursor")
        #expect((answer["plan_id"] as? String)?.hasPrefix("p-") == true)
        let set = try #require(answer["shortcut_set"] as? [String: Any])
        #expect(set["id"] as? String == "preset" && set["to"] as? String == "VS Code" && set["ticked"] as? Bool == true)
        #expect(set["differs"] as? Int == KeymapPreset.vsCode.overrides.count)
        let settings = try #require(answer["settings"] as? [[String: Any]])
        let ids = settings.compactMap { $0["id"] as? String }
        let expected = ["set:fontSize", "set:softWrap", "set:trimTrailingWhitespace", "set:hiddenFilePatterns", "set:terminalPalette"]
        #expect(Set(expected).isSubset(of: Set(ids)), "\(ids)")
        let palette = try #require(settings.first { $0["id"] as? String == "set:terminalPalette" })
        // Colours by count, never their values.
        #expect(palette["colours"] as? Int == 2 && !MCPServer.json(answer).contains("ff5555"))
        let shortcuts = try #require(answer["your_shortcuts"] as? [[String: Any]])
        let goToFile = try #require(shortcuts.first { $0["id"] as? String == "key:goToFile:" })
        #expect(goToFile["new"] as? String == "⌘T" && goToFile["now"] as? String == "no key" && goToFile["ticked"] as? Bool == true)
        let recents = try #require(answer["recent_projects"] as? [String: Any])
        #expect(recents["id"] as? String == "recents" && recents["count"] as? Int == 2 && recents["ticked"] as? Bool == true)
        let shown = recents["shown"] as? [String] ?? []
        #expect(shown.allSatisfy { $0.hasPrefix("~/Code/") }, "\(shown)")
        #expect((answer["changes_if_applied"] as? Int ?? 0) > 0 && answer["up_to_date"] as? Bool == false)
    }

    /// Settings Next Term has already change nothing: with every one already set and nothing else, it is up to date.
    @Test func aPlanNextTermHasAlreadyIsUpToDate() throws {
        let plan = ImportPlan(preset: .nextTerm, settings: [PlannedSetting(.fontSize(14), source: "editor.fontSize 14")])
        let context = MCPImport.PreviewContext(currentPreset: .nextTerm, title: { _ in "Font size" }, isCurrent: { _ in true }, home: "/Users/x")
        let answer = MCPImport.preview(source: "Zed", plan: plan, planID: MCPImport.planID(plan), context: context)
        #expect(answer["up_to_date"] as? Bool == true && answer["changes_if_applied"] as? Int == 0)
        #expect((answer["settings"] as? [[String: Any]])?.first?["already_set"] as? Bool == true)
        #expect((answer["shortcut_set"] as? [String: Any])?["in_use"] as? Bool == true)
    }

    /// AE7: the plan's id follows what the app's files hold, not Next Term's state, so a plan applied since keeps it.
    @Test func thePlanIDChangesOnlyWithTheAppsFiles() throws {
        let home = try fixture()
        defer { remove(home) }
        let app = try cursor(home)
        let first = MCPImport.planID(plan(app, home: home))
        #expect(MCPImport.planID(plan(app, home: home)) == first)
        let settings = app.configPath + "/settings.json"
        let text = try String(contentsOfFile: settings, encoding: .utf8).replacingOccurrences(of: "\"editor.fontSize\": 15", with: "\"editor.fontSize\": 16")
        try text.write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(MCPImport.planID(plan(app, home: home)) != first)
    }

    /// The exact answer preview_import gives for the Cursor fixture, the window's titles stubbed: Fixtures/Import/Cursor/
    /// preview.golden.json, read by hand. NEXTTERM_UPDATE_GOLDEN=1 writes it anew.
    @Test func thePreviewMatchesItsGoldenFile() throws {
        let home = try fixture()
        defer { remove(home) }
        var answer = try preview(home)
        // The id hashes the recent folders' full paths, which hold the temp copy's name.
        answer["plan_id"] = "p-(differs with the home folder)"
        let text = MCPImport.text(answer, home: home, hiding: [try cursor(home).configPath]) + "\n"
        let golden = ImportFixtures.root.appendingPathComponent("Cursor/preview.golden.json")
        if ProcessInfo.processInfo.environment["NEXTTERM_UPDATE_GOLDEN"] == "1" { try text.write(to: golden, atomically: true, encoding: .utf8) }
        let expected = try String(contentsOf: golden, encoding: .utf8)
        #expect(text == expected)
    }

    @Test func longListsAreCappedAndCounted() {
        let skipped = (0..<150).map { SkippedItem("key\($0)", "come later") }
        let shortcuts = (0..<120).map { PlannedShortcut(command: "c\($0)", title: "C\($0)", chord: nil, source: "s") }
        let plan = ImportPlan(preset: .nextTerm, shortcuts: shortcuts, skipped: skipped)
        let context = MCPImport.PreviewContext(currentPreset: .nextTerm, title: { _ in "" }, home: "/Users/x")
        let answer = MCPImport.preview(source: "x", plan: plan, planID: "p-1", context: context)
        #expect((answer["your_shortcuts"] as? [Any])?.count == 100 && answer["your_shortcuts_more"] as? Int == 20)
        #expect((answer["not_brought_over"] as? [Any])?.count == 100 && answer["not_brought_over_more"] as? Int == 50)
    }

    @Test func aSkippedNameThatLooksLikeACredentialIsNeverShown() {
        let secret = ImportFixtures.plantedSecrets[1]
        let plan = ImportPlan(preset: .nextTerm, skipped: [SkippedItem(secret, "looked like a credential")])
        let context = MCPImport.PreviewContext(currentPreset: .nextTerm, title: { _ in "" }, home: "/Users/x")
        let json = MCPServer.json(MCPImport.preview(source: "x", plan: plan, planID: "p-1", context: context))
        #expect(!json.contains(secret) && json.contains("a name that looked like a credential"))
    }

    // MARK: what an agent asks for

    @Test func theRowsAnAgentNamesAreChecked() throws {
        let home = try fixture()
        defer { remove(home) }
        let settled = plan(try cursor(home), home: home).settlingShortcuts(current: noKeys)
        let recents = MCPImport.newRecents(settled, known: [])
        let offered = MCPImport.offered(settled)
        #expect(offered.ids.isSuperset(of: ["preset", "set:fontSize", "key:goToFile:", "recents"]))
        // A Control key without ⌘ belongs to the shell: shown, never tickable.
        #expect(!offered.refused.isEmpty, "\(offered.refused)")
        let defaults = MCPImport.defaultTicks(settled, currentPreset: .nextTerm, newRecents: recents)
        #expect(defaults.isSuperset(of: ["preset", "set:fontSize", "key:goToFile:", "recents"]))
        #expect(defaults.isDisjoint(with: offered.refused.keys))
        func items(_ raw: Any?) -> Result<Set<String>?, MCPToolError> { MCPImport.items(raw, offered: offered.ids, refused: offered.refused) }
        #expect(try items(nil).get() == nil)
        #expect(try items(["preset", "set:fontSize"]).get() == ["preset", "set:fontSize"])
        #expect(throws: MCPToolError.self) { try items(["set:fontSize", "set:apiKey"]).get() }
        #expect(throws: MCPToolError.self) { try items([]).get() }
        #expect(throws: MCPToolError.self) { try items("preset").get() }
        let refused = try #require(offered.refused.keys.first)
        #expect(throws: MCPToolError.self) { try items([refused]).get() }
        // Ticking only the font size counts one change; with the set and the projects, their changes too.
        let one = MCPImport.changes(settled, ticks: ["set:fontSize"], currentPreset: .nextTerm, newRecents: recents) { _ in false }
        #expect(one == 1)
        let more = MCPImport.changes(settled, ticks: ["preset", "recents"], currentPreset: .nextTerm, newRecents: recents) { _ in false }
        #expect(more == KeymapPreset.vsCode.overrides.count + 1)
        let none = MCPImport.changes(settled, ticks: ["set:fontSize"], currentPreset: .nextTerm, newRecents: recents) { _ in true }
        #expect(none == 0)
    }

    /// AE4: what the user ticked or unticked against what the agent asked for.
    @Test func theUsersChangesAreNamed() {
        let changed = MCPImport.userChanged(asked: ["preset", "set:softWrap", "set:fontSize"], applied: ["preset", "set:fontSize", "recents"])
        #expect(changed == ["recents ticked", "set:softWrap unticked"])
        #expect(MCPImport.userChanged(asked: ["preset"], applied: ["preset"]).isEmpty)
    }

    @Test func rowIDsAreUniqueInAPlan() {
        let plan = ImportPlan(preset: .nextTerm, settings: [PlannedSetting(.fontSize(13), source: "a"), PlannedSetting(.fontSize(14), source: "b")])
        let ids: [String] = MCPImport.rowIDs(plan).settings
        let expected: [String] = ["set:fontSize", "set:fontSize#2"]
        #expect(ids == expected)
    }

    @Test func theArgumentsAreChecked() throws {
        #expect(try MCPImport.Asked.parse(["source": "cursor", "plan_id": "p-1", "reason": "Why."]).get().source == "cursor")
        let file = try MCPImport.Asked.parse(["path": ".vscode/settings.json", "format": "vscode-settings"]).get()
        #expect(file.path == ".vscode/settings.json" && file.format == .vsCodeSettings)
        #expect(try MCPImport.Asked.parse(["request_id": "AB12"]).get().requestID == "ab12")
        for bad: [String: Any] in [[:], ["source": "cursor", "path": "x"], ["path": "x"], ["path": "x", "format": "zed"], ["source": 3], ["source": " "]] {
            #expect(throws: MCPToolError.self, "\(bad)") { try MCPImport.Asked.parse(bad).get() }
        }
        #expect(try MCPImport.includeTargets([:]).get() == false)
        #expect(throws: MCPToolError.self) { try MCPImport.includeTargets(["include_targets": "yes"]).get() }
        #expect(try MCPImport.undoAsked(["undo_id": "IMP-1"]).get().undoID == "imp-1")
        #expect(throws: MCPToolError.self) { try MCPImport.undoAsked([:]).get() }
    }

    // MARK: answers

    @Test func answersHideTheHomeFolderOtherUsersAndSettingsFolders() {
        let home = "/Users/someone"
        let folder = home + "/Library/Application Support/Cursor/User"
        let value: [String: Any] = ["a": home + "/Code/api", "b": "/Users/other/Code/web", "c": folder + "/settings.json", "d": home,
                                    "e": "/Users/someone-else/x", "f": "token=" + ImportFixtures.plantedSecrets[0]]
        let text = MCPImport.text(value, home: home, hiding: [folder])
        #expect(text.contains("\"~/Code/api\"") && text.contains("\"/Users/•••/Code/web\"") && text.contains("\"(its settings folder)/settings.json\""))
        #expect(text.contains("\"d\" : \"~\"") && text.contains("\"/Users/•••/x\""))
        #expect(!text.contains("someone") && !text.contains("other") && ImportFixtures.secrets(in: text).isEmpty)
    }

    // MARK: a file an agent names

    /// AE9: a project's own .vscode/settings.json never sets hidden files or where new tabs open, says why, and its
    /// rows start unticked; nothing secret comes out.
    @Test func aNamedFileNeverSetsHiddenFilesOrTheStartFolder() throws {
        let home = try fixture()
        defer { remove(home) }
        let text = try String(contentsOfFile: home + "/Code/api/.vscode/settings.json", encoding: .utf8)
        #expect(MCPImport.isProjectSettings(".vscode/settings.json") && MCPImport.isProjectSettings("app/.vscode/settings.json"))
        #expect(!MCPImport.isProjectSettings("vscode/settings.json") && !MCPImport.isProjectSettings(".vscode/keybindings.json"))
        let plan = try MCPImport.filePlan(text: text, format: .vsCodeSettings, name: "settings.json in api", preset: .jetBrains,
                                          projectSettings: true, usKeyboard: true, fonts: testFonts, home: home).get()
        #expect(plan.preset == .jetBrains && plan.recentProjects.isEmpty && plan.shortcuts.isEmpty)
        for row in plan.settings {
            switch row.setting {
            case .hiddenFiles, .terminalStartFolder: Issue.record("a file set \(row.setting.key)")
            default: break
            }
            #expect(!row.ticked && row.note?.contains(MCPImport.projectSettingsNote) == true, "\(row.setting.key)")
        }
        #expect(plan.settings.contains { $0.setting == .fontSize(13) })
        let skipped = Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
        #expect(skipped.values.filter { $0 == MCPImport.notFromAFile }.count == 2, "\(skipped)")
        #expect(skipped["terminal.integrated.env.linux"] == "never imported: can hold secrets")
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
        // Not the project's own: ticked as the importer ticks them.
        let other = try MCPImport.filePlan(text: text, format: .vsCodeSettings, name: "settings.json", preset: .nextTerm,
                                           projectSettings: false, usKeyboard: true, fonts: testFonts, home: home).get()
        #expect(other.settings.contains { $0.ticked })
    }

    @Test func aNamedKeybindingsFileGivesShortcutsOnly() throws {
        let text = #"[{ "key": "cmd+t", "command": "workbench.action.quickOpen" }, { "key": "cmd+k cmd+s", "command": "x" }]"#
        let plan = try MCPImport.filePlan(text: text, format: .vsCodeKeybindings, name: "keybindings.json", preset: .nextTerm,
                                          projectSettings: false, usKeyboard: true, home: "/Users/x").get()
        #expect(plan.shortcuts.map(\.command) == ["goToFile:"] && plan.settings.isEmpty && plan.recentProjects.isEmpty)
        #expect(throws: MCPToolError.self) {
            try MCPImport.filePlan(text: "{", format: .vsCodeKeybindings, name: "k", preset: .nextTerm, projectSettings: false,
                                   usKeyboard: true, home: "/Users/x").get()
        }
        #expect(throws: MCPToolError.self) {
            try MCPImport.filePlan(text: "[1, 2", format: .vsCodeSettings, name: "s", preset: .nextTerm, projectSettings: false,
                                   usKeyboard: true, home: "/Users/x").get()
        }
        let empty = try MCPImport.filePlan(text: "// nothing yet\n", format: .vsCodeSettings, name: "s", preset: .nextTerm,
                                           projectSettings: false, usKeyboard: true, home: "/Users/x").get()
        #expect(empty == ImportPlan(preset: .nextTerm))
    }

    @Test func theCursorFixturePlantsItsSecrets() throws {
        let folder = ImportFixtures.root.appendingPathComponent("Cursor").path
        var text = ""
        let walker = FileManager.default.enumerator(atPath: folder)
        while let relative = walker?.nextObject() as? String {
            let path = (folder as NSString).appendingPathComponent(relative)
            if isRegularFile(path), let contents = try? String(contentsOfFile: path, encoding: .utf8) { text += contents }
        }
        let found: [String] = ImportFixtures.secrets(in: text)
        #expect(found == ImportFixtures.plantedSecrets)
    }
}

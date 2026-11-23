import Foundation
import Testing
@testable import NextTermCore

/// apply_setup (AgentSetup): what the call takes, each part checked as its own tool checks it and nothing set twice; the
/// rows the window shows and what Apply counts; and the snapshot Undo Agent Setup puts back, kept as JSON.
@Suite struct AgentSetupTests {
    static let fonts = FontCatalog { name in
        name.lowercased() == "menlo" ? InstalledFont(family: "Menlo", monospaced: true) : nil
    }

    func parse(_ arguments: [String: Any]) -> Result<AgentSetup.Asked, MCPToolError> {
        AgentSetup.parse(arguments, fonts: Self.fonts, folderExists: { $0 == "/Users/me/work" })
    }

    func refusal(_ arguments: [String: Any]) -> String? {
        if case .failure(let error) = parse(arguments) { return error.text }
        return nil
    }

    // MARK: arguments

    @Test func theThreePartsAreReadAsTheirOwnToolsReadThem() throws {
        let asked = try parse([
            "settings": ["font_size": 14, "shortcut_set": "vscode"],
            "layout": ["terminal_position": "right", "sidebar": "hidden", "project": "api"],
            "import": ["source": "cursor", "items": ["set:softWrap"], "plan_id": "p-1"],
            "reason": "Set up like Cursor.",
        ]).get()
        #expect(asked.settings.map(\.0.name) == ["font_size", "shortcut_set"])
        #expect(asked.settings.map(\.1) == [.number(14), .choice("vscode")])
        #expect(asked.layout == MCPLayoutChange(terminalPosition: "right", sidebarShown: false))
        #expect(asked.layoutArguments["project"] as? String == "api" && asked.layoutArguments.count == 1)
        #expect(asked.importAsked?.source == "cursor" && asked.importAsked?.planID == "p-1")
        #expect(asked.importArguments?["items"] as? [String] == ["set:softWrap"])
        #expect(asked.reason == "Set up like Cursor." && !asked.isEmpty)
        // One part is enough; a null part is one not given.
        #expect(try parse(["layout": ["terminal_tabs": "left"], "settings": NSNull()]).get().settings.isEmpty)
        // A request id alone waits for the answer, whatever else is there.
        #expect(try parse(["request_id": " AB12 "]).get().requestID == "ab12")
    }

    @Test func anythingElseIsRefusedAndNothingIsAsked() {
        #expect(refusal([:])?.contains("Give at least one of settings") == true)
        #expect(refusal(["settings": ["agent_control": false]])?.contains("not a setting agents may change; nothing was asked") == true)
        #expect(refusal(["settings": ["font_size": 99]])?.hasSuffix("nothing was asked.") == true)
        #expect(refusal(["settings": ["sidebar_side": "right"]]) == "“sidebar_side” goes in layout, as set_layout takes it; nothing was asked.")
        #expect(refusal(["settings": ["terminal_font_family": "Helvetica"]])?.contains("not a monospaced font family") == true)
        #expect(refusal(["settings": 14])?.contains("settings is an object") == true)
        #expect(refusal(["layout": ["shell_profile": "zsh"]])?.contains("not “shell_profile”") == true)
        #expect(refusal(["layout": [String: Any]()])?.contains("Give at least one of terminal_position") == true)
        #expect(refusal(["import": ["source": "cursor", "keys": ["x"]]])?.contains("not “keys”") == true)
        #expect(refusal(["import": ["path": "settings.json"]])?.contains("Give format with path") == true)
        #expect(refusal(["secrets": ["A": "b"]])?.contains("not “secrets”") == true)
        // Set twice: Undo could not say what was there before.
        #expect(refusal(["settings": ["terminal_position": "left"], "layout": ["terminal_position": "right"]])
                == "terminal_position is in both settings and layout; give it once. Nothing was asked.")
    }

    @Test func aSettingOrFieldAlsoInTheImportsRowsIsRefused() {
        let keys = ["fontSize": "set:fontSize", "keymapPreset": "preset", TerminalTabsSetting.key: "set:terminalTabs"]
        #expect(AgentSetup.overlap(settings: ["font_size"], layout: nil, importKeys: keys)?.text
                == "font_size is in settings and in the import (set:fontSize); give it once. Nothing was asked.")
        #expect(AgentSetup.overlap(settings: ["shortcut_set"], layout: nil, importKeys: keys)?.text.contains("(preset)") == true)
        #expect(AgentSetup.overlap(settings: [], layout: MCPLayoutChange(terminalTabs: "left"), importKeys: keys)?.text
                == "terminal_tabs is in layout and in the import (set:terminalTabs); give it once. Nothing was asked.")
        // The notification and agent choices, and the per-window fields, no import sets.
        #expect(AgentSetup.overlap(settings: ["notify_decisions", "soft_wrap"], layout: MCPLayoutChange(sidebarShown: false),
                                   importKeys: keys) == nil)
        // Each setting an import also sets is named by the key the import's snapshot keeps.
        for setting in MCPSettings.allowlist {
            let keys = AgentSetup.keys(ofSetting: setting.name)
            #expect(keys.allSatisfy { ImportSnapshot.title(of: $0) != $0 }, "\(setting.name)")
        }
    }

    // MARK: rows

    @Test func eachChangeIsARowInPlainWords() {
        func row(_ name: String, _ now: MCPSettings.Value, _ new: MCPSettings.Value) -> AgentSetup.Row {
            AgentSetup.settingRow(MCPSettings.setting(name)!, now: now, new: new, home: "/Users/me")
        }
        #expect(row("font_size", .number(13), .number(14)) == AgentSetup.Row(id: "setting:font_size", title: "Font size 13 → 14"))
        #expect(row("soft_wrap", .flag(true), .flag(false)).title == "Soft wrap: on → off")
        #expect(row("shortcut_set", .choice("next_term"), .choice("vscode")).title == "Shortcuts: VS Code set")
        #expect(row("shortcut_set", .choice("next_term"), .choice("vscode")).detail == "Replaces the Next Term set; your own shortcuts stay")
        #expect(row("terminal_position", .choice("bottom"), .choice("right")).title == "Terminal on the right")
        #expect(row("terminal_scrollback", .number(10_000), .number(50_000)).title == "Terminal scrollback: 10,000 lines → 50,000 lines")
        #expect(row("terminal_font_family", .choice("default"), .choice("Menlo")).title == "Terminal font: Next Term’s own → Menlo")
        #expect(row("terminal_font_size", .choice("same_as_editor"), .number(12)).title == "Terminal font size the editor’s → 12")
        #expect(row("new_tab_folder", .choice("project"), .choice("/Users/me/work")).title == "New tabs open in: the project’s folder → ~/work")
        #expect(row("at_launch", .choice("resume"), .choice("welcome")).title == "At launch: resume where I left off → show the Welcome window")
        #expect(row("open_projects_in", .choice("ask"), .choice("new_window")).title == "Open projects in: ask each time → new window")
        #expect(row("notify_commands", .choice("never"), .choice("in_another_app")).title == "Notify when a command finishes: never → while in another app")
        #expect(row("notify_threshold_seconds", .number(5), .number(30)).title == "Notify for finished work after: 5 seconds → 30 seconds")
        // Every setting on the allowlist has a row of its own words.
        for setting in MCPSettings.allowlist {
            let title = AgentSetup.settingRow(setting, now: .flag(false), new: .flag(true), home: "/Users/me").title
            #expect(!title.contains("_") && !title.contains("("), "\(setting.name): \(title)")
        }
    }

    @Test func theLayoutAndTheImportHaveRowsToo() {
        let change = MCPLayoutChange(terminalPosition: "bottom", sidebarSide: "right", terminalTabs: "left", sidebarShown: false,
                                     terminalFolded: true, windowColumnShown: true, windowColumnFolded: false)
        let rows = AgentSetup.layoutRows(change, place: "the window of api")
        #expect(rows.map(\.id) == ["layout:terminal_position", "layout:sidebar_side", "layout:terminal_tabs", "layout:window_column",
                                   "layout:window_column_folded", "layout:sidebar", "layout:terminal_folded"])
        #expect(rows.map(\.title) == ["Terminal at the bottom", "Project sidebar on the right", "Terminal tabs in a list on the left",
                                      "Window column shown", "Window column unfolded", "Project sidebar hidden in the window of api",
                                      "Terminal folded in the window of api"])
        #expect(AgentSetup.layoutRows(MCPLayoutChange(terminalTabs: "top"), place: "").first?.title == "Terminal tabs along the top")

        let imported = AgentSetup.importRow(source: "Cursor", preset: nil, keys: 12, settings: 0, recents: 0, notBroughtOver: 3, changes: 12)
        #expect(imported.id == "import" && imported.title == "12 keys from Cursor; 3 have no equivalent" && imported.count == 12)
        let more = AgentSetup.importRow(source: "Zed", preset: .vsCode, keys: 1, settings: 2, recents: 1, notBroughtOver: 1, changes: 30)
        #expect(more.title == "The VS Code shortcut set, 1 key, 2 settings and 1 recent project from Zed; 1 has no equivalent")
    }

    @Test func applyCountsTheTickedRowsChanges() {
        let rows = [AgentSetup.Row(id: "setting:font_size", title: "Font size 13 → 14"),
                    AgentSetup.Row(id: "layout:terminal_position", title: "Terminal on the right"),
                    AgentSetup.importRow(source: "Cursor", preset: nil, keys: 7, settings: 0, recents: 0, notBroughtOver: 0, changes: 7)]
        let all = Set(rows.map(\.id))
        #expect(AgentSetup.count(rows, ticked: all) == 9 && AgentSetup.applyTitle(9) == "Apply 9 Changes")
        #expect(AgentSetup.count(rows, ticked: ["setting:font_size"]) == 1 && AgentSetup.applyTitle(1) == "Apply 1 Change")
        #expect(AgentSetup.count(rows, ticked: []) == 0 && AgentSetup.applyTitle(0) == "Apply")
        // A layout change keeps only its ticked fields.
        let change = MCPLayoutChange(terminalPosition: "right", sidebarShown: false, windowColumnShown: true)
        #expect(AgentSetup.only(change, ticked: ["layout:terminal_position", "layout:window_column"])
                == MCPLayoutChange(terminalPosition: "right", windowColumnShown: true))
        #expect(AgentSetup.only(change, ticked: ["setting:font_size"]).isEmpty)
    }

    // MARK: the snapshot

    @Test func layoutValuesGoBothWays() {
        let change = MCPLayoutChange(terminalPosition: "left", sidebarSide: "right", terminalTabs: "top", sidebarShown: true,
                                     terminalFolded: false, windowColumnShown: false, windowColumnFolded: true)
        let values = AgentSetup.layoutValues(change)
        #expect(values.map(\.field) == ["terminal_position", "sidebar_side", "terminal_tabs", "window_column", "window_column_folded",
                                        "sidebar", "terminal_folded"])
        #expect(values.map(\.value) == ["left", "right", "top", "hidden", "true", "shown", "false"])
        #expect(AgentSetup.layoutChange(values) == change)
        #expect(AgentSetup.layoutChange([("shell", "zsh")]).isEmpty)
    }

    static let date = Date(timeIntervalSince1970: 1_793_628_120) // 2 Nov 2026, 14:02 in UTC

    static func snapshot() -> AgentSetupSnapshot? {
        AgentSetupSnapshot.applied(
            agent: "the agent in the tab “codex” in api",
            settings: [.init(name: "font_size", before: .number(13), after: .number(14)),
                       .init(name: "soft_wrap", before: .flag(true), after: .flag(true))],
            layout: [.init(field: "terminal_position", before: "bottom", after: "right"),
                     .init(field: "sidebar", before: "shown", after: "hidden", project: "/Users/me/api"),
                     .init(field: "window_column", before: "shown", after: "shown")],
            importUndoID: "imp-abc", importSource: "Cursor",
            lines: ["Font size 13 → 14", "Terminal on the right", "Project sidebar hidden in the window of api"], date: date)
    }

    @Test func theSnapshotKeepsWhatChangedAndReadsBack() throws {
        let snapshot = try #require(Self.snapshot())
        // What stayed the same is left out: Undo has nothing to put back there.
        #expect(snapshot.settings.map(\.name) == ["font_size"] && snapshot.layout.map(\.field) == ["terminal_position", "sidebar"])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AgentSetupSnapshot.self, from: data) == snapshot)
        // Nothing changed and no import: no snapshot, so the Undo kept is the earlier one.
        #expect(AgentSetupSnapshot.applied(agent: "x", settings: [.init(name: "font_size", before: .number(13), after: .number(13))],
                                           layout: [], importUndoID: nil, importSource: nil, lines: []) == nil)
        #expect(AgentSetupSnapshot.applied(agent: "x", settings: [], layout: [], importUndoID: "imp-1", importSource: "Zed", lines: []) != nil)
    }

    @Test func undoPutsBackTheValuesBeforeEachInItsWindow() throws {
        let snapshot = try #require(Self.snapshot())
        #expect(snapshot.layoutBefore(perWindow: false) == MCPLayoutChange(terminalPosition: "bottom"))
        #expect(snapshot.perWindowProjects == ["/Users/me/api"])
        #expect(snapshot.layoutBefore(perWindow: true, project: "/Users/me/api") == MCPLayoutChange(sidebarShown: true))
        #expect(snapshot.layoutBefore(perWindow: true, project: "/Users/me/web").isEmpty)
    }

    @Test func undoNamesWhatWasChangedSinceAndTheImport() throws {
        let snapshot = try #require(Self.snapshot())
        let untouched = snapshot.changedSince(settings: ["font_size": .number(14.0001)], layout: ["terminal_position": "right", "sidebar": "hidden"])
        #expect(untouched.isEmpty)
        let changed = snapshot.changedSince(settings: ["font_size": .number(16)], layout: ["terminal_position": "right", "sidebar": "shown"])
        #expect(changed == ["font_size", "sidebar"])

        let utc = TimeZone(identifier: "UTC")!, english = Locale(identifier: "en_GB")
        let line = snapshot.logLine(locale: english, timeZone: utc)
        #expect(line.hasPrefix("The agent in the tab “codex” in api changed font size 13 → 14 and 2 more, "))
        #expect(line.contains("2 Nov") && line.contains("14:02"))

        let message = snapshot.undoMessage(changedSince: changed, importIsLast: true)
        #expect(message.contains("go back to what they were before"))
        #expect(message.contains("You changed these since, and Undo puts them back too: Font size and Project sidebar."))
        #expect(message.hasSuffix("The import from Cursor is undone too, as Undo Import does."))
        let later = snapshot.undoMessage(changedSince: [], importIsLast: false)
        #expect(!later.contains("You changed") && later.hasSuffix("The import from Cursor stays: a later import, or its own Undo, came after it."))
    }

    @Test func aSetupThatWasOnlyAnImportHasNothingLeftOnceTheImportIsNotTheLast() throws {
        let snapshot = try #require(Self.snapshot())
        // Settings and layout are there to put back, whatever became of the import.
        #expect(snapshot.canUndo(importIsLast: false) && snapshot.canUndo(importIsLast: true))
        let onlyImport = try #require(AgentSetupSnapshot.applied(agent: "the agent in the tab “codex” in api", settings: [], layout: [],
                                                                 importUndoID: "imp-1", importSource: "Zed",
                                                                 lines: ["12 keys from Zed"], date: Self.date))
        #expect(onlyImport.canUndo(importIsLast: true) && !onlyImport.canUndo(importIsLast: false))
        // Its alert names only the import: no settings or layout go back.
        let message = onlyImport.undoMessage(changedSince: [], importIsLast: true)
        #expect(!message.contains("settings and layout"))
        #expect(message.hasSuffix(".\n\nThe import from Zed is undone, as Undo Import does."))
    }

    // MARK: the tool

    @Test func theToolIsListedDeferredAndAsksFirst() throws {
        let tool = try #require(MCPServer.tool(named: "apply_setup"))
        #expect(MCPServer.isSetupTool("apply_setup") && !MCPServer.isControlTool("apply_setup") && !MCPServer.isImportTool("apply_setup"))
        #expect(!tool.readOnly && !tool.destructive && !tool.openWorld && tool.timeout >= 60)
        #expect(!tool.alwaysLoad && MCPServer.isDeferred("apply_setup") && tool.scope == .write)
        #expect(MCPRestoreGate.isFollowUp("apply_setup", ["request_id": "ab12"]))
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == AgentSetup.arguments && schema["additionalProperties"] as? Bool == false)
        let layout = try #require((properties["layout"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(Set(layout.keys) == Set(MCPLayoutChange.arguments + ["project"]))
        let importing = try #require((properties["import"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(Set(importing.keys) == AgentSetup.importArguments)
        for words in ["one window on the Mac", "Apply N Changes", "untick", "Undo Agent Setup…", "undo_import", "pending with a request_id",
                      "Agent control, keys, other apps' files and shell profiles are never part of it", "This Mac only"] {
            #expect(tool.description.contains(words), "\(words)")
        }
        #expect(MCPServer.instructions.contains("apply_setup"))
    }
}

import Foundation
import Testing
@testable import NextTermCore

/// The Next Term settings and menu commands no import reached before: how files and projects open, what reopens at
/// launch, diffs and git, from VS Code and JetBrains (Zed's are in ImportZedRecentsTests); the commands VS Code,
/// JetBrains and Zed have keys for; and the JetBrains set's ⌘K Commit… and ⇧⌘K Push… outside the terminal.
@Suite struct ImportReachTests {
    func settings(_ json: String, appName: String = "VS Code") throws -> ImportVSCode.SettingsResult {
        let file = try #require(ImportVSCode.SettingsFile(json))
        return ImportVSCode.settingsPlan(file, appName: appName, usKeyboard: true, fonts: testFonts)
    }

    func rows(_ json: String) throws -> [ImportedSetting] { try settings(json).settings.map(\.setting) }

    // MARK: VS Code

    @Test func vsCodeWindowAndGitSettings() throws {
        #expect(try rows(#"{"workbench.list.openMode": "doubleClick"}"#) == [.sidebarSingleClick(false)])
        #expect(try rows(#"{"workbench.list.openMode": "singleClick"}"#) == [.sidebarSingleClick(true)])
        #expect(try rows(#"{"window.openFoldersInNewWindow": "on"}"#) == [.openProjectsIn("newWindow")])
        #expect(try rows(#"{"window.openFoldersInNewWindow": "off"}"#) == [.openProjectsIn("thisWindow")])
        let asDefault = try settings(#"{"window.openFoldersInNewWindow": "default"}"#, appName: "Cursor").settings
        #expect(asDefault == [PlannedSetting(.openProjectsIn("thisWindow"), source: "window.openFoldersInNewWindow default",
                                             note: "as Cursor opens a folder chosen in its File menu")])
        #expect(try rows(#"{"window.restoreWindows": "none"}"#) == [.launchOpens("welcome")])
        #expect(try rows(#"{"window.restoreWindows": "all"}"#) == [.launchOpens("lastProjects")])
        #expect(try settings(#"{"window.restoreWindows": "one"}"#).settings.first?.note
                == "VS Code reopens only the last window; Next Term reopens every project that was open")
        #expect(try rows(#"{"diffEditor.renderSideBySide": false}"#) == [.diffLayout("unified")])
        #expect(try rows(#"{"diffEditor.renderSideBySide": true}"#) == [.diffLayout("sideBySide")])
        #expect(try rows(#"{"git.blame.editorDecoration.enabled": true}"#) == [.currentLineBlame(true)])
        let odd = try settings(#"{"workbench.list.openMode": "tripleClick", "diffEditor.renderSideBySide": "maybe"}"#)
        #expect(odd.settings.isEmpty)
        #expect(odd.skipped == [SkippedItem("workbench.list.openMode", "value not recognised"),
                                SkippedItem("diffEditor.renderSideBySide", "value not recognised")])
        // Unset, nothing: VS Code's defaults say nothing about the user. An app's whole plan adds its own click, which
        // a file on its own never implies (ImportClickDefaultTests).
        #expect(try rows("{}").isEmpty)
    }

    @Test func vsCodeAutofetchToTheNearestFrequency() throws {
        #expect(try rows(#"{"git.autofetch": false}"#) == [.backgroundFetch("off")])
        #expect(try rows(#"{"git.autofetch": true, "git.autofetchPeriod": 300}"#) == [.backgroundFetch("5")])
        let ten = try settings(#"{"git.autofetch": "all", "git.autofetchPeriod": 600}"#).settings
        #expect(ten == [PlannedSetting(.backgroundFetch("10"), source: "git.autofetch all, git.autofetchPeriod 600")])
        #expect(try rows(#"{"git.autofetch": true, "git.autofetchPeriod": 900}"#) == [.backgroundFetch("10")])
        let hour = try settings(#"{"git.autofetch": true, "git.autofetchPeriod": 3600}"#).settings.first
        #expect(hour?.setting == .backgroundFetch("30") && hour?.note == "VS Code fetches every 60 minutes; Next Term every 5, 10 or 30")
        // The period alone: VS Code doesn't fetch by itself unless git.autofetch is on, so nothing comes over.
        #expect(try rows(#"{"git.autofetchPeriod": 60}"#).isEmpty)
        let bad = try settings(#"{"git.autofetch": true, "git.autofetchPeriod": "often"}"#)
        #expect(bad.settings.map(\.setting) == [.backgroundFetch("5")] && bad.skipped == [SkippedItem("git.autofetchPeriod", "value not recognised")])
        #expect(try settings(#"{"git.autofetch": "sometimes"}"#).skipped == [SkippedItem("git.autofetch", "value not recognised")])
    }

    // MARK: JetBrains

    @Test func jetBrainsReopenAndOpenProjectIn() throws {
        let home = try ImportFixtures.copy("JetBrains")
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let config = home + "/Library/Application Support/JetBrains/PhpStorm2026.1"
        let app = DetectedApp(kind: .jetBrains, name: "PhpStorm 2026.1", configPath: config, lastUsed: nil)
        func plan() -> ImportPlan { ImportJetBrains.plan(for: app, home: home, usKeyboard: true, now: Date(), fonts: testFonts) }
        let fixture = plan()
        #expect(fixture.settings.contains(PlannedSetting(.launchOpens("welcome"), source: "options/ide.general.xml reopenLastProject false")))
        #expect(fixture.settings.contains(PlannedSetting(.openProjectsIn("newWindow"), source: "options/ide.general.xml confirmOpenNewProject2 0")))
        #expect(!String(describing: fixture).contains("Browser.app") && ImportFixtures.secrets(in: fixture).isEmpty)

        func general(_ options: String) throws -> ImportPlan {
            let xml = "<application>\n  <component name=\"GeneralSettings\">\n\(options)\n  </component>\n</application>"
            try xml.write(toFile: config + "/options/ide.general.xml", atomically: true, encoding: .utf8)
            return plan()
        }
        let ask = try general(#"<option name="confirmOpenNewProject2" value="-1" /><option name="reopenLastProject" value="true" />"#)
        let chosen: [ImportedSetting] = ask.settings.map(\.setting).filter { $0.key == "openProjectsIn" || $0.key == "launchOpens" }
        let expected: [ImportedSetting] = [.launchOpens("lastProjects"), .openProjectsIn("ask")]
        #expect(chosen == expected)
        let attach = try general(#"<option name="confirmOpenNewProject2" value="2" />"#)
        #expect(attach.skipped.contains(SkippedItem("Open project attached to the open one", "Next Term opens a project in a window of its own")))
        let odd = try general(#"<option name="confirmOpenNewProject2" value="7" /><option name="reopenLastProject" value="maybe" />"#)
        #expect(odd.skipped.contains(SkippedItem("options/ide.general.xml confirmOpenNewProject2", "not a value Next Term can use")))
        #expect(odd.skipped.contains(SkippedItem("options/ide.general.xml reopenLastProject", "not a value Next Term can use")))
    }

    // MARK: menu commands

    @Test func theCommandsEachAppHasKeysFor() {
        let vsCode: [String: String] = [
            "workbench.action.closeOtherEditors": "closeOtherTabs:", "workbench.action.closeEditorsToTheRight": "closeTabsToTheRight:",
            "workbench.action.reopenClosedEditor": "reopenClosedTab:", "copyFilePath": "copyFilePath:",
            "copyRelativeFilePath": "copyRelativeFilePath:", "revealFileInOS": "revealInFinder:", "git.commit": "gitCommit:",
            "git.push": "gitPush:", "git.pull": "gitUpdate:", "git.fetch": "gitFetch:", "git.checkout": "showBranches:",
        ]
        for (command, id) in vsCode { #expect(ImportVSCode.commandMap[command] == id, "\(command)") }
        let jetBrains: [String: String] = [
            "CloseAllEditorsButActive": "closeOtherTabs:", "CloseAllToTheRight": "closeTabsToTheRight:", "ReopenClosedTab": "reopenClosedTab:",
            "CopyPaths": "copyFilePath:", "RevealIn": "revealInFinder:", "CheckinProject": "gitCommit:", "Vcs.Push": "gitPush:",
            "Vcs.UpdateProject": "gitUpdate:", "Git.Fetch": "gitFetch:", "Git.Branches": "showBranches:",
        ]
        for (action, id) in jetBrains { #expect(ImportJetBrains.actionMap[action] == id, "\(action)") }
        let zed: [String: String] = [
            "pane::CloseInactiveItems": "closeOtherTabs:", "pane::CloseItemsToTheRight": "closeTabsToTheRight:",
            "pane::ReopenClosedItem": "reopenClosedTab:", "workspace::CopyPath": "copyFilePath:", "editor::RevealInFileManager": "revealInFinder:",
            "workspace::ToggleZoom": "toggleZoomPane:", "git::Commit": "gitCommit:", "git::Push": "gitPush:", "git::Pull": "gitUpdate:",
            "git::Fetch": "gitFetch:", "git::Branch": "showBranches:",
        ]
        for (action, id) in zed { #expect(ImportZed.actionMap[action] == id, "\(action)") }
    }

    @Test func theJetBrainsSetCommitsAndPushesOutsideTheTerminal() {
        let jetBrains = ImportShortcutsTests.current(.jetBrains)
        let commandK = KeyChord(key: "k", command: true), shiftCommandK = KeyChord(key: "k", command: true, shift: true)
        #expect(jetBrains["gitCommit:"] == .some(commandK) && jetBrains["gitPush:"] == .some(shiftCommandK))
        #expect(jetBrains["newTab:"] == .some(KeyChord(key: "t", command: true)))
        // ⇧⌘K is Push… alone (Delete Line moved to ⌘⌫); ⌘K is Clear Buffer's in a terminal and Commit…'s elsewhere.
        let onShiftK: [String] = jetBrains.filter { $0.value == shiftCommandK }.map(\.key)
        let onK: Set<String> = Set(jetBrains.filter { $0.value == commandK }.map(\.key))
        let both: Set<String> = ["clearBuffer:", "gitCommit:"]
        #expect(onShiftK == ["gitPush:"])
        #expect(onK == both)
        #expect(KeyBindings.canShareKey("clearBuffer:", "gitCommit:") && KeyBindings.canShareKey("newWindow:", "clearBuffer:"))
        #expect(!KeyBindings.canShareKey("clearBuffer:", "splitRight:") && !KeyBindings.canShareKey("gitCommit:", "gitPush:"))
        let titles = ["clearBuffer:": "Clear Buffer", "gitCommit:": "Commit…"]
        #expect(KeyBindings.sharingNote(commandK, ["gitCommit:", "clearBuffer:"], title: { titles[$0] ?? $0 })
                == "⌘K is Clear Buffer while a terminal has the keyboard, Commit… everywhere else")
        // Under Next Term's own set, a Commit… key on ⌘K shares it with Clear Buffer and Link instead of taking it away
        // (with the menu's title for Link, as the app gives it).
        let row = ImportShortcuts.row("gitCommit:", commandK, source: "keymap: CheckinProject")
        let plan = ImportPlan(preset: .nextTerm, shortcuts: [row])
            .settlingShortcuts(current: ImportShortcutsTests.current(), titles: ["insertMarkdownLink:": "Link"])
        #expect(plan.shortcuts.first?.ticked == true)
        #expect(plan.shortcuts.first?.note == "⌘K is Link while a Markdown file’s editor has the keyboard, Clear Buffer while a terminal has "
                + "the keyboard, Commit… everywhere else")
    }

    // MARK: Undo names them

    @Test func everyNewSettingHasATitle() {
        let settings: [ImportedSetting] = [.sidebarSingleClick(true), .backgroundFetch("5"), .diffLayout("unified"), .currentLineBlame(true),
                                           .openProjectsIn("ask"), .launchOpens("welcome"), .terminalFontSize(12),
                                           .tabList(TabListImport(tabs: "right", sidebarSide: "left", showsFolders: true))]
        for key in settings.flatMap(\.keys) { #expect(ImportSnapshot.title(of: key) != key, "\(key)") }
        #expect(ImportedSetting.boolKeys.isSuperset(of: ["sidebarSingleClickOpens", "currentLineBlame", "tabListShowsFolders"]))
        #expect(ImportedSetting.launchOpens("welcome").key == LaunchSettings.Key.opens)
    }
}

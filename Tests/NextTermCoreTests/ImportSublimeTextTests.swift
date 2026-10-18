import Foundation
import Testing
@testable import NextTermCore

/// Sublime Text's settings, key bindings and recent folders, from the hand-written fixture home in
/// Fixtures/Import/SublimeText (never a real Mac's). Apps are looked for only in the fixture's Applications folder.
@Suite struct ImportSublimeTextTests {
    var fm: FileManager { .default }

    static let data = "/Library/Application Support/Sublime Text"
    static let user = data + "/Packages/User"

    func remove(_ home: String) { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    /// The fixture, its session file pointing into the copy.
    func fixture() throws -> String {
        let home = try ImportFixtures.copy("SublimeText")
        let session = home + Self.data + "/Local/Session.sublime_session"
        let text = try String(contentsOfFile: session, encoding: .utf8)
        try text.replacingOccurrences(of: "@HOME@", with: home).write(toFile: session, atomically: true, encoding: .utf8)
        return home
    }

    func importPlan(_ home: String) throws -> ImportPlan {
        let app = try #require(ImportSublimeText.detect(home: home, applications: [home + "/Applications"]).first)
        return ImportSublimeText.plan(for: app, home: home, fonts: testFonts)
    }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: detection

    @Test func detection() throws {
        let home = try fixture()
        defer { remove(home) }
        let used = Date(timeIntervalSince1970: 1_790_000_000), older = Date(timeIntervalSince1970: 1_780_000_000)
        try fm.setAttributes([.modificationDate: used], ofItemAtPath: home + Self.data + "/Local/Session.sublime_session")
        let three = home + "/Library/Application Support/Sublime Text 3/Packages/User"
        for path in [three, three + "/Preferences.sublime-settings"] {
            try fm.setAttributes([.modificationDate: older], ofItemAtPath: path)
        }
        let apps = [home + "/Applications"]
        let app = try #require(ImportSublimeText.detect(home: home, applications: apps).first)
        #expect(app.kind == .sublimeText && app.name == "Sublime Text" && app.preset == .nextTerm)
        #expect(app.configPath == home + Self.data && app.lastUsed ?? .distantPast >= used)
        #expect(app.appPath == home + "/Applications/Sublime Text.app" && app.version == "Build 4200" && !app.appRemoved)
        #expect(app.kind.family == .editors && app.kind.canBring == [.shortcuts, .settings, .fonts, .projects])

        // Without the app: listed, as an app removed.
        let removed = try #require(ImportSublimeText.detect(home: home, applications: []).first)
        #expect(removed.appPath == nil && removed.appRemoved)
        #expect(ImportSublimeText.detect(home: home + "/Code", applications: apps).isEmpty)
    }

    /// Sublime Text 3's folder is used when it is the newer one, and the app found then is 4's, so it counts as removed.
    @Test func olderVersionsFolder() throws {
        let home = try fixture()
        defer { remove(home) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for path in [Self.user + "/Preferences.sublime-settings", Self.user, Self.data + "/Local/Session.sublime_session"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: home + path)
        }
        let app = try #require(ImportSublimeText.detect(home: home, applications: [home + "/Applications"]).first)
        #expect(app.name == "Sublime Text 3" && app.configPath.hasSuffix("/Sublime Text 3"))
        #expect(app.appPath == nil && app.appRemoved, "Build 4200 keeps its data in the newer folder")
        let plan = ImportSublimeText.plan(for: app, home: home, fonts: testFonts)
        let expected: [ImportedSetting] = [.fontSize(15), .trimTrailingWhitespace(true), .sidebarSingleClick(true)] // its own click
        #expect(plan.settings.map(\.setting) == expected)
        #expect(plan.settings.first { $0.setting == .trimTrailingWhitespace(true) }?.ticked == true, "Sublime Text 3 trims every line, as Next Term does")
    }

    // MARK: settings

    @Test func settings() throws {
        let home = try fixture()
        defer { remove(home) }
        let plan = try importPlan(home)
        let expected: [ImportedSetting] = [
            .editorFontFamily("JetBrains Mono"), .fontSize(13), .editorLineHeight(1.25), .softWrap(true), .sidebarSingleClick(true),
            .trimTrailingWhitespace(true), .insertFinalNewline(true), .hiddenFiles(["*.log", "node_modules/"]),
        ]
        #expect(plan.settings.map(\.setting) == expected)
        #expect(plan.settings.allSatisfy { $0.ticked })
        let sources = plan.settings.map(\.source)
        #expect(sources.contains("font_size 13") && sources.contains("preview_on_click only_left"))
        #expect(sources.contains("line_padding_top 2, line_padding_bottom 2"))
        #expect(sources.contains("file_exclude_patterns and folder_exclude_patterns"))

        let reasons = reasons(plan)
        #expect(reasons["tab_size"] == "tab width and spaces come later" && reasons["translate_tabs_to_spaces"] == reasons["tab_size"])
        #expect(reasons["rulers"] == "a ruler column comes later")
        #expect(reasons["color_scheme"] == "colour themes come later" && reasons["caret_style"] == ImportRows.editorCaret)
        #expect(reasons["wrap_width 100"] == "Next Term wraps at the window edge; a wrap column isn't supported")
        #expect(reasons["http_proxy"] == "never imported: can hold secrets" && reasons["github_token"] == reasons["http_proxy"])
        #expect(reasons["Vim keys (Vintage)"] == "Next Term has no Vim mode yet")
        #expect(reasons["other settings: highlight_line, scroll_past_end"] == "no matching Next Term setting yet")
        #expect(reasons["1 excluded name"] == "looked like a credential")
        #expect(reasons["1 excluded pattern"] == "not a name the sidebar can hide")
        #expect(reasons["Sublime Text's own shortcuts"] == "there is no Sublime Text shortcut set, so Next Term's shortcuts stay")
        let vintage = plan.skipped.filter { $0.item.contains("vintage_") }
        #expect(vintage.isEmpty, "Vintage's own settings are its mode's, not listed: \(plan.skipped)")
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    /// Sublime Text 4 trims only the lines you changed unless told otherwise: offered unticked, saying so.
    @Test func trimmingChangedLinesOnly() throws {
        let home = try fixture()
        defer { remove(home) }
        let settings = "{ \"trim_trailing_white_space_on_save\": \"not_on_caret\", \"word_wrap\": \"auto\", \"line_padding_top\": 0 }"
        try write(settings, to: home + Self.user + "/Preferences.sublime-settings")
        let plan = try importPlan(home)
        let trim = try #require(plan.settings.first)
        #expect(plan.settings.count == 2 && trim.setting == .trimTrailingWhitespace(true) && !trim.ticked)
        #expect(plan.settings.last?.isClickDefault == true, "preview_on_click isn't set: Sublime Text's own click")
        #expect(trim.note == "Sublime Text trims only the lines you changed; Next Term trims every line of the file; the caret's line is trimmed too")
        #expect(reasons(plan)["word_wrap auto"] == "Next Term wraps every file or none, not by its kind")

        try write("{ \"trim_trailing_white_space_on_save\": false, \"preview_on_click\": false, \"ignored_packages\": [\"Vintage\"] }",
                  to: home + Self.user + "/Preferences.sublime-settings")
        let off = try importPlan(home)
        let offRows: [ImportedSetting] = [.sidebarSingleClick(false), .trimTrailingWhitespace(false)]
        #expect(off.settings.map(\.setting) == offRows)
        #expect(reasons(off)["Vim keys (Vintage)"] == nil)
    }

    @Test func unreadableSettings() throws {
        let home = try fixture()
        defer { remove(home) }
        let path = home + Self.user + "/Preferences.sublime-settings"
        try write("// only a comment\n", to: path)
        #expect(try importPlan(home).settings.map(\.setting) == [.sidebarSingleClick(true)], "nothing set: Sublime Text's own click")
        try write("{ \"font_size\": 13, ", to: path)
        #expect(try reasons(importPlan(home))["Preferences.sublime-settings"] == "couldn't be read as JSON, so no settings came over")
        try write(String(repeating: "[", count: 5_000), to: path)
        #expect(try reasons(importPlan(home))["Preferences.sublime-settings"] == "couldn't be read as JSON, so no settings came over")
    }

    /// A settings file that links out of the data folder is never read; one in a linked Packages/User still is.
    @Test func linksOutOfTheDataFolder() throws {
        let home = try fixture()
        defer { remove(home) }
        let path = home + Self.user + "/Preferences.sublime-settings"
        try fm.removeItem(atPath: path)
        try fm.createSymbolicLink(atPath: path, withDestinationPath: home + "/outside/Preferences.sublime-settings")
        let plan = try importPlan(home)
        #expect(reasons(plan)["Preferences.sublime-settings"] == ImportFile.linkedOut)
        #expect(!plan.settings.contains { $0.setting == .fontSize(30) })
        #expect(ImportFixtures.secrets(in: plan).isEmpty)

        // Packages/User kept elsewhere (a synced folder) and linked in: its files are the user's own.
        let synced = home + "/outside/User"
        try fm.moveItem(atPath: home + Self.user, toPath: synced)
        try fm.removeItem(atPath: synced + "/Preferences.sublime-settings")
        try write("{ \"font_size\": 16 }", to: synced + "/Preferences.sublime-settings")
        try fm.createSymbolicLink(atPath: home + Self.user, withDestinationPath: synced)
        #expect(try importPlan(home).settings.map(\.setting) == [.fontSize(16), .sidebarSingleClick(true)])
    }

    // MARK: key bindings

    @Test func keyBindings() throws {
        let home = try fixture()
        defer { remove(home) }
        let plan = try importPlan(home)
        var expected = ["saveAllDocuments: ⌥⌘S", "goToFile: ⇧⌘O", "goToLine: ⌥⌘L", "reopenClosedTab: ⇧⌘T", "deleteLine: ⇧⌘K"]
        expected += ["selectTabByNumber:#1 ⌘1", "toggleProjectSidebar: ⌘B", "replaceInFile: ⌥⌘F", "showNextTab: ⌥⌘→"]
        expected += ["closeOtherTabs: ⌥⌘W", "revealInFinder: ⌥⌘R", "toggleComment: ⌘/", "increaseFontSize: ⌘="]
        let rows: [String] = plan.shortcuts.map { "\($0.command) \($0.chord?.display ?? "none")" }
        #expect(rows == expected)
        #expect(plan.shortcuts.allSatisfy { $0.ticked && $0.allowed })
        let goToFile = try #require(plan.shortcuts.first { $0.command == "goToFile:" })
        #expect(goToFile.source == "Default (OSX).sublime-keymap: super+shift+o → show_overlay")

        let reasons = reasons(plan)
        #expect(reasons["super+shift+o → prompt_open"] == "replaced further down by show_overlay", "the macOS file is read last")
        #expect(reasons["super+t → show_overlay"] == "passes arguments in Sublime Text that make it another command")
        #expect(reasons["super+k, super+b → toggle_side_bar"] == ImportShortcuts.twoStep)
        #expect(reasons["ctrl+t → transpose"] == ImportShortcuts.noCommand)
        #expect(reasons["super+d → noop"] == "turning a key off isn't brought over")
        #expect(reasons["ctrl+tab → next_view"] == "one shortcut per command here; ⌥⌘→ comes over")
        #expect(reasons["super+e → insert"] == ImportShortcuts.noCommand, "a command's arguments are never shown")
        #expect(reasons["super+shift+e → slurp_find_string"] == "works only in some places in Sublime Text; keys for one context come later")
        #expect(reasons["super+j → toggle_comment"] == "replaced further down by join_lines")
        #expect(reasons["keypad_enter → find_next"] == ImportShortcuts.numpad)
        #expect(ImportFixtures.secrets(in: plan).isEmpty)
    }

    @Test func keyNames() {
        func display(_ raw: String) -> String {
            switch ImportSublimeText.key(raw, usKeyboard: true) {
            case .chord(let chord): return chord.display
            case .notSupported(let reason): return reason
            }
        }
        #expect(display("primary+shift+p") == "⇧⌘P")
        #expect(display("command+option+left") == "⌥⌘←")
        #expect(display("super+plus") == "⌘=" && display("super+equals") == "⌘=")
        #expect(display("super+forward_slash") == "⌘/" && display("ctrl+backquote") == "⌃`")
        #expect(display("super+keypad5") == ImportShortcuts.numpad)
        #expect(display("super++") == ImportShortcuts.notRecognised && display("super+") == ImportShortcuts.notRecognised)
        #expect(display("super+context_menu") == ImportShortcuts.notRecognised)
    }

    /// A command is told apart by its arguments, and only the arguments that do that are read.
    @Test func commandsByArguments() throws {
        func target(_ binding: String) -> String? {
            guard let document = JSONC(binding), case .object(let object)? = document.root else { return nil }
            return ImportSublimeText.binding(object, text: binding, file: "f").target
        }
        #expect(target(#"{"keys": ["super+p"], "command": "show_overlay", "args": {"overlay": "goto", "show_files": true}}"#) == "goToFile:")
        #expect(target(#"{"keys": ["super+p"], "command": "show_overlay", "args": {"overlay": "command_palette"}}"#) == nil)
        #expect(target(#"{"keys": ["super+f"], "command": "show_panel", "args": {"panel": "find", "reverse": true}}"#) == nil)
        #expect(target(#"{"keys": ["super+f"], "command": "show_panel", "args": {"panel": "find_in_files"}}"#) == "findInFiles:")
        #expect(target(#"{"keys": ["super+9"], "command": "select_by_index", "args": {"index": 8}}"#) == nil)
        #expect(target(#"{"keys": ["super+8"], "command": "select_by_index", "args": {"index": 7}}"#) == "selectTabByNumber:#8")
        #expect(target(#"{"keys": ["super+,"], "command": "edit_settings", "args": {"base_file": "${packages}/Default/Preferences.sublime-settings"}}"#)
            == "showSettings:")
        #expect(target(#"{"keys": ["super+s"], "command": "save", "args": {"async": true}}"#) == "saveDocument:")
        #expect(target(#"{"keys": ["super+w"], "command": "close", "args": {"extra": 1}}"#) == nil)
        #expect(target(#"{"keys": ["super+w"], "command": "close", "args": "nope"}"#) == nil)
        #expect(target(#"{"keys": ["super+k"], "command": "focus_neighboring_group", "args": {"forward": false}}"#) == "selectPreviousPane:")
        #expect(target(#"{"keys": ["super+k"], "command": "toggle_setting", "args": {"setting": "word_wrap"}}"#) == "toggleSoftWrap:")
    }

    @Test func unreadableKeyBindings() throws {
        let home = try fixture()
        defer { remove(home) }
        try write("{ \"keys\": [] }", to: home + Self.user + "/Default.sublime-keymap")
        try write("[ {\"keys\": [\"super+b\"], ", to: home + Self.user + "/Default (OSX).sublime-keymap")
        let plan = try importPlan(home)
        #expect(plan.shortcuts.isEmpty)
        #expect(reasons(plan)["Default.sublime-keymap"] == "couldn't be read as JSON; your shortcuts there were skipped")
        #expect(reasons(plan)["Default (OSX).sublime-keymap"] == "couldn't be read as JSON; your shortcuts there were skipped")
    }

    // MARK: recent projects

    @Test func recentProjects() throws {
        let home = try fixture()
        defer { remove(home) }
        let plan = try importPlan(home)
        #expect(plan.recentProjects == [home + "/Code/alpha", home + "/Code/beta"])
        let reasons = reasons(plan)
        #expect(reasons["beta.sublime-project"] == "only a project's first folder comes over (1 more folder left out)")
        #expect(reasons["1 recent project"] == "looked like a credential")
        #expect(ImportFixtures.secrets(in: plan).isEmpty)

        // At most 20, newest first.
        let session = home + Self.data + "/Local/Session.sublime_session"
        var folders: [String] = []
        for n in 0..<25 {
            let folder = home + "/Code/p\(n)"
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            folders.append("\"\(folder)\"")
        }
        try write("{ \"folder_history\": [\(folders.joined(separator: ", "))] }", to: session)
        let many = try importPlan(home).recentProjects
        #expect(many.count == 20 && many.first == home + "/Code/p0")

        try write("not JSON at all", to: session)
        #expect(try self.reasons(importPlan(home))["recent projects"] == "the session file couldn't be read as JSON")
    }

    // MARK: packages and safety

    @Test func packagesAreCounted() throws {
        let home = try fixture()
        defer { remove(home) }
        let reasons = try self.reasons(importPlan(home))
        #expect(reasons["Vim keys (NeoVintageous package)"] == "Next Term has no Vim mode yet")
        #expect(reasons["3 other packages"] == "packages aren't imported")
        #expect(reasons["2 other settings files"] == "settings for one language or package aren't imported")
        #expect(reasons["snippets"] == "snippets aren't supported")
        #expect(reasons["build systems"] == "never imported: runs commands")
        #expect(reasons.keys.allSatisfy { !$0.contains("LSP") && !$0.contains("Python") }, "packages are counted, never named")
    }

    @Test func fixturePlantsItsSecrets() throws {
        let folder = ImportFixtures.root.appendingPathComponent("SublimeText").path
        var text = ""
        let walker = fm.enumerator(atPath: folder)
        while let relative = walker?.nextObject() as? String {
            let path = (folder as NSString).appendingPathComponent(relative)
            if isRegularFile(path), let contents = try? String(contentsOfFile: path, encoding: .utf8) { text += contents }
        }
        let found: [String] = ImportFixtures.secrets(in: text)
        #expect(found == ImportFixtures.plantedSecrets)
    }

    /// File access is recorded: detection and the plan open only these files of the fixture, and the preview an
    /// agent gets matches the fixture's golden file (as ImportFileAccessTests checks the other fixtures).
    @Test func opensOnlyItsFilesAndPreviewsAsItsGoldenFile() throws {
        let home = try fixture()
        defer { remove(home) }
        let apps = [home + "/Applications"]
        let watched = ImportFixtures.watched(home: home, detect: { ImportSublimeText.detect(home: home, applications: apps) },
                                             plan: { ImportSublimeText.plan(for: $0, home: home, fonts: testFonts) })
        let expected: [String] = [
            "Applications/Sublime Text.app/Contents/Info.plist",
            "Code/beta/beta.sublime-project",
            "Library/Application Support/Sublime Text/Local/Session.sublime_session",
            "Library/Application Support/Sublime Text/Packages/User/Default (OSX).sublime-keymap",
            "Library/Application Support/Sublime Text/Packages/User/Default.sublime-keymap",
            "Library/Application Support/Sublime Text/Packages/User/Preferences.sublime-settings",
        ]
        #expect(watched.opened == expected)
        let text = ImportFixtures.previews(watched.plans, home: home)
        let secrets: [String] = ImportFixtures.secrets(in: text)
        #expect(secrets.isEmpty && !text.contains("•••"))
        let golden = try ImportFixtures.golden("SublimeText", text)
        #expect(text == golden)
    }

    // MARK: the sidebar's click

    func clickPlan(_ settings: String?) throws -> ImportPlan {
        let home = canonicalPath(fm.temporaryDirectory.path) + "/nt-click-" + String(UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(atPath: home) }
        let data = home + "/Library/Application Support/Sublime Text"
        try fm.createDirectory(atPath: data + "/Packages/User", withIntermediateDirectories: true)
        if let settings { try write(settings, to: data + "/Packages/User/Preferences.sublime-settings") }
        let app = DetectedApp(kind: .sublimeText, name: "Sublime Text", configPath: data, lastUsed: nil)
        return ImportSublimeText.plan(for: app, home: home, fonts: testFonts)
    }

    func clickRows(_ plan: ImportPlan) -> [PlannedSetting] {
        plan.settings.filter { if case .sidebarSingleClick = $0.setting { return true } else { return false } }
    }

    /// preview_on_click, or Sublime Text's own default (a single click) when it isn't set or there is no Preferences
    /// file; nothing when the file can't be read or the value isn't one.
    @Test func theClickIsPreviewOnClickOrSublimeTextsDefault() throws {
        let fallback = PlannedSetting(.sidebarSingleClick(true), source: "preview_on_click (not set: true)", note: "Sublime Text's default")
        #expect(clickRows(try clickPlan(#"{"font_size": 13}"#)) == [fallback])
        #expect(clickRows(try clickPlan(nil)) == [fallback], "no Preferences file: every setting is Sublime Text's default")
        #expect(clickRows(try clickPlan("// only comments\n")) == [fallback])
        #expect(try clickPlan(#"{"preview_on_click": false}"#).settings.map(\.setting) == [.sidebarSingleClick(false)])
        #expect(clickRows(try clickPlan(#"{"preview_on_click": "only_left"}"#))
                == [PlannedSetting(.sidebarSingleClick(true), source: "preview_on_click only_left")])
        #expect(clickRows(try clickPlan(#"{"preview_on_click": true}"#)).map(\.source) == ["preview_on_click true"])
        #expect(clickRows(try clickPlan("{ \"font_size\": ")).isEmpty)
        #expect(clickRows(try clickPlan(#"{"preview_on_click": "sometimes"}"#)).isEmpty)
    }

    /// The owner's rule: this editor is named only in its importer, the import window and the switching guide's
    /// import rows. In the sources, only these files may name it (ImportJetBrains.swift matches the IDEs' built-in
    /// keymap of that name, from before the importer).
    @Test func namedOnlyInItsImporter() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The tests too: only this importer's own tests, and two from before it that check another app's keymap of
        // that name is never shown.
        let allowed: Set<String> = ["ImportSublimeText.swift", "ImportModel.swift", "ImportUI.swift", "ImportJetBrains.swift",
                                    "ImportSublimeTextTests.swift", "ImportJetBrainsTests.swift", "ImportZedITermTests.swift"]
        var naming: [String] = []
        for folder in ["Sources", "Tests"] {
            let root = package.appendingPathComponent(folder)
            let walker = fm.enumerator(atPath: root.path)
            while let relative = walker?.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
                if text.range(of: "sublime", options: .caseInsensitive) != nil { naming.append((relative as NSString).lastPathComponent) }
            }
        }
        #expect(!naming.isEmpty && naming.allSatisfy(allowed.contains), "\(naming)")
        #expect(ImportSourceKind.sublimeText.family == .editors)
        let brings: [ImportContent] = [.shortcuts, .settings, .fonts, .projects]
        #expect(ImportSourceKind.sublimeText.canBring == brings)
    }
}

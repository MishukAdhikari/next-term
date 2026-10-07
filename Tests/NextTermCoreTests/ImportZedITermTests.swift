import Foundation
import Testing
@testable import NextTermCore

/// Fixtures are written into a fresh temporary home per test; the real home is never read.
@Suite struct ImportZedITermTests {
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-import-zi-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, to path: String, date: Date? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    /// Every string the plan holds, as the preview or the agent report could show it.
    func shown(_ plan: ImportPlan) -> String { "\(plan)" }

    func reasons(_ plan: ImportPlan) -> [String: String] {
        Dictionary(plan.skipped.map { ($0.item, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Zed

    func zedHome(settings: String) throws -> (home: String, app: DetectedApp) {
        let home = try home()
        try write(settings, to: home + "/.config/zed/settings.json")
        let apps = ImportZed.detect(home: home)
        try #require(apps.count == 1)
        return (home, apps[0])
    }

    @Test func zedDetection() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ImportZed.detect(home: home).isEmpty)

        // A folder where the file should be is not a settings file.
        try FileManager.default.createDirectory(atPath: home + "/.config/zed/settings.json", withIntermediateDirectories: true)
        #expect(ImportZed.detect(home: home).isEmpty)
        try FileManager.default.removeItem(atPath: home + "/.config/zed/settings.json")

        // Detection only looks at dates: a file that isn't even valid JSON is still found.
        let edited = Date(timeIntervalSince1970: 1_790_000_000)
        try write("{ not json", to: home + "/.config/zed/settings.json", date: edited)
        let app = try #require(ImportZed.detect(home: home).first)
        #expect(app.kind == .zed && app.name == "Zed")
        #expect(app.configPath == home + "/.config/zed")
        #expect(app.lastUsed == edited)
        #expect(app.preset == .nextTerm)

        // Zed's database is written whenever Zed runs, so it dates the last use better.
        let ran = Date(timeIntervalSince1970: 1_791_000_000)
        try write("", to: home + "/Library/Application Support/Zed/db/0-stable/db.sqlite", date: Date(timeIntervalSince1970: 1_780_000_000))
        try write("", to: home + "/Library/Application Support/Zed/db/0-stable/db.sqlite-wal", date: ran)
        try write("", to: home + "/Library/Application Support/Zed/db/other/db.sqlite", date: Date(timeIntervalSince1970: 1_799_000_000))
        #expect(ImportZed.detect(home: home).first?.lastUsed == ran)
    }

    @Test func zedBaseKeymapPicksThePreset() throws {
        let exact: [(String, KeymapPreset)] = [("\"VSCode\"", .vsCode), ("\"JetBrains\"", .jetBrains)]
        for (value, preset) in exact {
            let (home, app) = try zedHome(settings: "{\"base_keymap\": \(value)}")
            defer { try? FileManager.default.removeItem(atPath: home) }
            let plan = ImportZed.plan(for: app, home: home)
            #expect(plan.preset == preset)
            #expect(plan.skipped.isEmpty)
            #expect(plan.settings.isEmpty && plan.recentProjects.isEmpty)
        }

        let cursor = try zedHome(settings: "{\"base_keymap\": \"Cursor\"}")
        defer { try? FileManager.default.removeItem(atPath: cursor.home) }
        let cursorPlan = ImportZed.plan(for: cursor.app, home: cursor.home)
        #expect(cursorPlan.preset == .vsCode)
        #expect(reasons(cursorPlan)["Cursor's AI shortcuts"]?.contains("VS Code keys") == true)

        // Zed's own keymap (also what an unset value means) and None stay on Next Term's keys, with a note.
        for settings in ["{\"base_keymap\": \"Zed\"}", "{}", "{\"buffer_font_size\": 14}"] {
            let (home, app) = try zedHome(settings: settings)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let plan = ImportZed.plan(for: app, home: home)
            #expect(plan.preset == .nextTerm)
            #expect(reasons(plan)["Zed's own shortcuts"] == "there is no Zed preset, so Next Term's shortcuts stay")
        }
        let none = try zedHome(settings: "{\"base_keymap\": \"None\"}")
        defer { try? FileManager.default.removeItem(atPath: none.home) }
        let nonePlan = ImportZed.plan(for: none.app, home: none.home)
        #expect(nonePlan.preset == .nextTerm)
        #expect(reasons(nonePlan)["base_keymap"]?.contains("only your own shortcuts") == true)

        // Every other value lands on Next Term's keys, and the preview never names it.
        for value in ["SublimeText", "Atom", "TextMate", "Emacs", "SomethingNewer"] {
            let (home, app) = try zedHome(settings: "{\"base_keymap\": \"\(value)\"}")
            defer { try? FileManager.default.removeItem(atPath: home) }
            let plan = ImportZed.plan(for: app, home: home)
            #expect(plan.preset == .nextTerm)
            #expect(reasons(plan)["base_keymap"] == "this keymap has no preset here, so Next Term's shortcuts stay")
            #expect(!shown(plan).contains(value))
            #expect(!shown(plan).localizedCaseInsensitiveContains("sublime"))
        }
        // Not a string at all: no match either.
        for value in ["3", "null", "{\"name\": \"VSCode\"}"] {
            let (home, app) = try zedHome(settings: "{\"base_keymap\": \(value)}")
            defer { try? FileManager.default.removeItem(atPath: home) }
            #expect(ImportZed.plan(for: app, home: home).preset == .nextTerm)
        }
    }

    @Test func zedReportsTheRestByNameOnly() throws {
        let settings = """
            // Zed settings
            //
            // For information on how to configure Zed, see the Zed documentation.
            {
              "base_keymap": "JetBrains", // the keys my hands know
              "vim_mode": true,
              "helix_mode": false,
              "buffer_font_size": 15,
              "buffer_font_family": "Berkeley Mono",
              "buffer_line_height": { "custom": 1.7 },
              "soft_wrap": "editor_width",
              "ui_font_size": 16,
              "theme": { "mode": "system", "light": "One Light", "dark": "Gruvbox Dark Hard" },
              "terminal": {
                "shell": { "with_arguments": { "program": "/opt/bin/fish", "args": ["-c", "export GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123"] } },
                "env": { "OPENAI_API_KEY": "sk-proj-abcdefghijklmnopqrstuvwxyz" },
                "option_as_meta": true,
                "dock": "right",
                "font_size": 13,
                "blinking": "off",
              },
              "project_panel": { "dock": "right", "indent_size": 12 },
              "context_servers": {
                "github": { "command": { "path": "npx", "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "github_pat_abcdefghijklmnopqrstuvwxyz" } } }
              },
              "language_models": { "openai": { "api_url": "https://llm.internal.example/v1" } },
              "agent": { "default_model": { "provider": "zed.dev", "model": "claude-sonnet-4" } },
              "proxy": "http://me:hunter2-pass@proxy.internal.example:8080",
              "autosave": "on_focus_change",
              /* indentation */
              "tab_size": 2,
              "format_on_save": "on",
            }
            """
        let (home, app) = try zedHome(settings: settings)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let plan = ImportZed.plan(for: app, home: home, fonts: testFonts)
        #expect(plan.preset == .jetBrains)
        #expect(plan.settings.isEmpty, "the one font isn't installed, and the other settings come later")
        #expect(plan.recentProjects.isEmpty)

        let expected: [String: String] = [
            "vim_mode": "Next Term has no Vim mode",
            "buffer_font_size": "comes in a later version",
            "Editor font “Berkeley Mono”": "not installed on this Mac",
            "buffer_line_height": "comes in a later version",
            "soft_wrap": "comes in a later version",
            "ui_font_size": "Next Term's window text follows macOS",
            "theme": "colour themes come later",
            "terminal.shell": "never imported: can hold secrets",
            "terminal.env": "never imported: can hold secrets",
            "terminal.option_as_meta": "comes in a later version",
            "terminal.dock": "comes in a later version",
            "terminal.font_size": "comes in a later version",
            "project_panel.dock": "comes in a later version",
            "context_servers": "never imported: can hold secrets",
            "language_models": "never imported: can hold secrets",
            "agent": "never imported: can hold secrets",
            "proxy": "never imported: can hold secrets",
            "other settings: autosave, tab_size, format_on_save": "no matching Next Term setting yet",
        ]
        #expect(reasons(plan) == expected)
        #expect(plan.skipped.count == expected.count)

        // Only names (and a font's name): no other value reaches the plan.
        for value in ["ghp_", "sk-proj", "github_pat_", "hunter2", "/opt/bin/fish", "llm.internal", "Gruvbox",
                      "claude-sonnet", "npx", "on_focus_change", "editor_width"] {
            #expect(!shown(plan).contains(value), "\(value) leaked into the plan")
        }
    }

    @Test func zedFonts() throws {
        func plan(_ settings: String) throws -> ImportPlan {
            let (home, app) = try zedHome(settings: settings)
            defer { try? FileManager.default.removeItem(atPath: home) }
            return ImportZed.plan(for: app, home: home, fonts: testFonts)
        }
        // The terminal uses the buffer font while it has none of its own.
        let shared = try plan(#"{"base_keymap": "VSCode", "buffer_font_family": "Fira Code"}"#)
        #expect(shared.settings == [
            PlannedSetting(.editorFontFamily("Fira Code"), source: "buffer_font_family Fira Code"),
            PlannedSetting(.terminalFontFamily("Fira Code"), source: "buffer_font_family Fira Code",
                           note: "Zed's terminal uses the buffer font while terminal.font_family is unset"),
        ])
        #expect(shared.skipped.isEmpty)

        let both = try plan(#"{"buffer_font_family": "Hack", "terminal": {"font_family": "JetBrains Mono", "font_fallbacks": ["Menlo"]}}"#)
        #expect(both.settings.map(\.setting) == [.editorFontFamily("Hack"), .terminalFontFamily("JetBrains Mono")])
        #expect(reasons(both)["terminal.font_fallbacks"] == "font fallbacks aren't supported")

        // Zed's own font comes with Zed only; a terminal font that isn't installed doesn't fall back.
        let zedFont = try plan(#"{"buffer_font_family": ".ZedMono", "terminal": {"font_family": "Berkeley Mono"}}"#)
        #expect(zedFont.settings.isEmpty)
        #expect(reasons(zedFont)["buffer_font_family “.ZedMono”"] == "Zed's own font, which only Zed has")
        #expect(reasons(zedFont)["Terminal font “Berkeley Mono”"] == "not installed on this Mac")
        #expect(reasons(try plan(#"{"buffer_font_family": 3}"#))["buffer_font_family"] == "value not recognised")
    }

    @Test func zedOtherSettingsList() {
        func members(_ text: String) -> [JSONC.Member] {
            guard let document = JSONC(text), case .object(let root)? = document.root else { return [] }
            return root.members
        }
        let many = "{" + (1...15).map { "\"key\($0)\": \($0)" }.joined(separator: ", ") + "}"
        let items = ImportZed.report(members(many), in: many)
        #expect(items.count == 1)
        #expect(items.first?.item == "other settings: " + (1...12).map { "key\($0)" }.joined(separator: ", ") + " and 3 more")

        // A key that looks like a credential is not even named.
        let odd = "{\"sk-abcdefghijklmnopqrstuvwxyz\": 1, \"autosave\": \"off\", \"load_direnv\": \"direct\"}"
        let oddItems = ImportZed.report(members(odd), in: odd)
        #expect(oddItems.contains(SkippedItem("other settings: autosave", "no matching Next Term setting yet")))
        #expect(oddItems.contains(SkippedItem("load_direnv", "never imported: can hold secrets")))
        #expect(!"\(oddItems)".contains("sk-abc"))
    }

    @Test func zedOddFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let settings = home + "/.config/zed/settings.json"
        try write("{}", to: settings)
        let app = try #require(ImportZed.detect(home: home).first)

        func plan(_ text: String?) throws -> ImportPlan {
            try? FileManager.default.removeItem(atPath: settings)
            if let text { try write(text, to: settings) }
            return ImportZed.plan(for: app, home: home)
        }

        // Gone since detection.
        var result = try plan(nil)
        #expect(result.preset == .nextTerm)
        #expect(reasons(result)["settings.json"] == "couldn't be read, so no settings came over")

        for broken in ["{ \"base_keymap\": \"VSCode\"", "{ base_keymap: VSCode }", "[\"VSCode\"]", "\"VSCode\"", "{} {}"] {
            result = try plan(broken)
            #expect(result.preset == .nextTerm, "\(broken)")
            #expect(reasons(result)["settings.json"] == "isn't valid JSON, so no settings came over")
            #expect(!shown(result).contains("VSCode"))
        }

        // As Zed first writes it: comments only. And an empty file. Both mean "nothing set".
        for empty in ["// Zed settings\n//\n// See the docs.\n", "", "\n  \n", "/* nothing */"] {
            result = try plan(empty)
            #expect(result.preset == .nextTerm)
            #expect(reasons(result)["settings.json"] == nil)
            #expect(reasons(result)["Zed's own shortcuts"] != nil)
        }

        // A byte-order mark, and trailing commas.
        result = try plan("\u{FEFF}{\"base_keymap\": \"VSCode\",}")
        #expect(result.preset == .vsCode)

        // A named pipe is never opened (opening one waits for a writer).
        try FileManager.default.removeItem(atPath: settings)
        #expect(mkfifo(settings, 0o600) == 0)
        #expect(ImportZed.detect(home: home).isEmpty)
        #expect(reasons(ImportZed.plan(for: app, home: home))["settings.json"] == "couldn't be read, so no settings came over")

        // Another app's entry gets nothing from the Zed reader.
        let other = DetectedApp(kind: .iTerm2, name: "iTerm2", configPath: app.configPath, lastUsed: nil)
        #expect(ImportZed.plan(for: other, home: home) == ImportPlan(preset: .nextTerm))
    }

    @Test func zedKeymapFileAndRecentsAreReported() throws {
        let (home, app) = try zedHome(settings: "{\"base_keymap\": \"VSCode\"}")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let keymap = home + "/.config/zed/keymap.json"

        // The template Zed writes binds nothing.
        try write("""
            // Zed keymap
            [
              {
                "context": "Workspace",
                "bindings": {
                  // "shift shift": "file_finder::Toggle"
                }
              },
            ]
            """, to: keymap)
        #expect(ImportZed.plan(for: app, home: home).skipped.isEmpty)

        try write("""
            [
              { "context": "Workspace", "bindings": { "cmd-p": "file_finder::Toggle", "cmd-shift-p": "command_palette::Toggle" } },
              // Text a terminal would receive is never looked at.
              { "context": "Terminal", "bindings": { "ctrl-g": ["terminal::SendText", "export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123\\n"] } },
              { "context": "Editor" },
            ]
            """, to: keymap)
        var plan = ImportZed.plan(for: app, home: home)
        #expect(reasons(plan) == ["keymap.json (3 shortcuts)": "your own Zed shortcuts come in a later version"])
        #expect(!shown(plan).contains("ghp_"))

        try write("[{ \"bindings\": ", to: keymap)
        #expect(ImportZed.plan(for: app, home: home).skipped.isEmpty)

        // Recents are Phase 2b: the database is only noticed, never opened.
        try write("not a database", to: home + "/Library/Application Support/Zed/db/0-stable/db.sqlite")
        plan = ImportZed.plan(for: app, home: home)
        #expect(reasons(plan)["recent projects"] == "Zed's recent projects come in a later version")
        #expect(plan.recentProjects.isEmpty)
    }

    // MARK: iTerm2

    var plistPath: String { "/Library/Preferences/com.googlecode.iterm2.plist" }

    /// A profile as iTerm2 saves it, with the values v1 must never read filled with secrets.
    func profile(guid: String, font: String? = "Monaco 12", left: Int? = 0, right: Int? = 0,
                 extra: [String: Any] = [:]) -> [String: Any] {
        var values: [String: Any] = [
            "Guid": guid,
            "Name": "Profile \(guid)",
            "Non Ascii Font": "Monaco 12",
            "Use Non-ASCII Font": false,
            "Command": "/bin/zsh -c 'export AWS_KEY=AKIAABCDEFGHIJKLMNOP; exec zsh'",
            "Custom Command": "Yes",
            "Triggers": [["regex": "^Password:", "action": "PasswordTrigger", "parameter": "hunter2-trigger"]],
            "Keyboard Map": ["0xd-0x20000": ["Action": 12, "Text": "secret-keyboard-text"] as [String: Any]],
            "Bound Hosts": ["prod-db.internal.example"],
            "Custom Directory": "No",
            "Working Directory": "/Users/someone/private-folder",
            "Scrollback Lines": 1000,
            "Unlimited Scrollback": false,
            "Ansi 0 Color": ["Red Component": 0.0, "Green Component": 0.0, "Blue Component": 0.0, "Color Space": "sRGB"] as [String: Any],
            "Background Color": ["Red Component": 0.1, "Green Component": 0.1, "Blue Component": 0.1, "Color Space": "sRGB"] as [String: Any],
        ]
        if let font { values["Normal Font"] = font }
        if let left { values["Option Key Sends"] = left }
        if let right { values["Right Option Key Sends"] = right }
        values.merge(extra) { $1 }
        return values
    }

    func preferences(_ profiles: [[String: Any]], defaultGuid: String?, extra: [String: Any] = [:]) -> [String: Any] {
        var root: [String: Any] = [
            "New Bookmarks": profiles,
            "AITermAPIKey": "sk-abcdefghijklmnopqrstuvwxyz012345",
            "AiPluginCustomURL": "https://ai.internal.example",
            "NoSyncClaudeCodeToken": "sk-ant-abcdefghijklmnopqrstuvwxyz",
            "GlobalKeyMap": ["0xf702-0x280000": ["Action": 12, "Text": "global-secret-text"] as [String: Any],
                             "0xf703-0x280000": ["Action": 10, "Text": "f"] as [String: Any]],
        ]
        if let defaultGuid { root["Default Bookmark Guid"] = defaultGuid }
        root.merge(extra) { $1 }
        return root
    }

    func writePlist(_ root: [String: Any], home: String, format: PropertyListSerialization.PropertyListFormat = .binary,
                    date: Date? = nil) throws -> String {
        let path = home + plistPath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
        return path
    }

    func iTermPlan(_ root: [String: Any], usKeyboard: Bool = true, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> ImportPlan {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try writePlist(root, home: home, format: format)
        let app = try #require(ImportITerm2.detect(home: home).first)
        return ImportITerm2.plan(for: app, home: home, usKeyboard: usKeyboard, fonts: testFonts)
    }

    /// What the fixture profile's two colours become.
    let fixtureColours: TerminalPalette = {
        var ansi: [UInt32?] = Array(repeating: nil, count: 16)
        ansi[0] = 0x000000
        return TerminalPalette(name: "iTerm2 colours", ansi: ansi, background: 0x1A1A1A)
    }()

    let paneNote = SkippedItem("⌘] and ⌘[ (Next and Previous Pane in iTerm2)", "they indent and outdent here; ⌥⌘] and ⌥⌘[ move between panes")

    @Test func iTermDetection() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ImportITerm2.detect(home: home).isEmpty)
        try FileManager.default.createDirectory(atPath: home + plistPath, withIntermediateDirectories: true)
        #expect(ImportITerm2.detect(home: home).isEmpty, "a folder is not the preferences file")
        try FileManager.default.removeItem(atPath: home + plistPath)

        let used = Date(timeIntervalSince1970: 1_790_500_000)
        let path = try writePlist(preferences([profile(guid: "A")], defaultGuid: "A"), home: home, date: used)
        #expect(ImportITerm2.detect(home: home) == [DetectedApp(kind: .iTerm2, name: "iTerm2", configPath: path, lastUsed: used)])
        #expect(ImportITerm2.detect(home: home).first?.preset == .nextTerm)
    }

    @Test func iTermUsesTheDefaultProfile() throws {
        let root = preferences([profile(guid: "A", font: "Monaco 12", left: 0, right: 0),
                                profile(guid: "B", font: "JetBrainsMono-Regular 14", left: 2, right: 2)], defaultGuid: "B")
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let plan = try iTermPlan(root, format: format)
            #expect(plan.preset == .nextTerm)
            #expect(plan.settings == [
                PlannedSetting(.fontSize(14), source: "Normal Font JetBrainsMono-Regular 14",
                               note: "sets the editor too: Next Term has one size for both"),
                PlannedSetting(.terminalFontFamily("JetBrains Mono"), source: "Normal Font JetBrainsMono-Regular"),
                PlannedSetting(.optionAsMeta(true), source: "Option Key Sends Esc+, Right Option Key Sends Esc+"),
                PlannedSetting(.terminalPalette(fixtureColours), source: "the default profile's colours",
                               note: "2 of 20 colours; the others stay Next Term's"),
            ])
            #expect(plan.recentProjects.isEmpty)
            #expect(plan.skipped == [
                SkippedItem("iTerm2 key mappings (2)", "terminal key mappings aren't brought over"),
                paneNote,
            ])
        }

        // No default named, or one that no longer exists: the first profile.
        for guid in [nil, "gone"] as [String?] {
            let plan = try iTermPlan(preferences([profile(guid: "A", font: "Menlo 11"), profile(guid: "B", font: "Monaco 15")],
                                                 defaultGuid: guid))
            #expect(plan.settings.first?.setting == .fontSize(11))
        }
    }

    @Test func iTermFontSize() {
        func plan(_ font: String?) -> (PlannedSetting?, [SkippedItem]) {
            var skipped: [SkippedItem] = []
            var profile = ImportITerm2.Profile()
            profile.normalFont = font
            return (ImportITerm2.fontSize(profile, skipped: &skipped), skipped)
        }
        #expect(plan("Monaco 12").0?.setting == .fontSize(12))
        #expect(plan("SFMono-Regular 13.5").0?.setting == .fontSize(14))
        #expect(plan("Menlo-Regular 11.0").0?.setting == .fontSize(11))
        #expect(plan("Fira Code Retina 16").1.isEmpty) // the font itself: iTermFontFamily

        let big = plan("Menlo 40")
        #expect(big.0?.setting == .fontSize(32))
        #expect(big.0?.note == "iTerm2 has 40; Next Term's sizes go from 8 to 32, so 32; sets the editor too: Next Term has one size for both")
        #expect(big.0?.ticked == true)
        #expect(plan("Menlo 6.5").0?.setting == .fontSize(8))

        // No size, or no font at all: no row.
        #expect(plan("Monaco").0 == nil)
        #expect(plan("Monaco").1 == [SkippedItem("Normal Font", "the size couldn't be read")])
        #expect(plan("Monaco -3").0 == nil)
        #expect(plan(nil).0 == nil && plan(nil).1.isEmpty)
        #expect(plan("   ").0 == nil && plan("   ").1.isEmpty)

        // Something credential-shaped where the font should be is dropped, unseen.
        let odd = plan("ghp_abcdefghijklmnopqrstuvwxyz0123 12")
        #expect(odd.0 == nil)
        #expect(odd.1 == [SkippedItem("Normal Font", "looked like a credential")])
    }

    @Test func iTermFontFamily() {
        func row(_ font: String?) -> (setting: PlannedSetting?, skipped: [SkippedItem]) {
            var profile = ImportITerm2.Profile()
            profile.normalFont = font
            return ImportITerm2.fontFamily(profile, fonts: testFonts)
        }
        #expect(row("FiraCode-Regular 13").setting == PlannedSetting(.terminalFontFamily("Fira Code"), source: "Normal Font FiraCode-Regular"))
        #expect(row("Fira Code Retina 16").skipped == [SkippedItem("Terminal font “Fira Code Retina”", "not installed on this Mac")])
        #expect(row("Helvetica 12").skipped == [SkippedItem("Terminal font “Helvetica”", "not a monospaced font, which code and the terminal need")])
        // No size, no font, or a credential (reported by the size's row): nothing.
        for font in ["Menlo", nil, "ghp_abcdefghijklmnopqrstuvwxyz0123 12"] as [String?] {
            #expect(row(font).setting == nil && row(font).skipped.isEmpty)
        }
    }

    @Test func iTermColours() throws {
        func colour(_ r: Double, _ g: Double, _ b: Double, alpha: Double? = nil, space: String = "sRGB") -> [String: Any] {
            var colour: [String: Any] = ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": space]
            if let alpha { colour["Alpha Component"] = alpha }
            return colour
        }
        var extra: [String: Any] = [:]
        for n in 0...15 { extra["Ansi \(n) Color"] = colour(Double(n) / 15, 0, 0) }
        extra["Foreground Color"] = colour(1, 1, 1)
        extra["Background Color"] = colour(0, 0, 0)
        extra["Cursor Color"] = colour(1, 0.5, 0)
        extra["Selection Color"] = colour(1, 1, 1, alpha: 0.5)
        extra["Bold Color"] = colour(0, 1, 0) // not a Next Term colour
        let plan = try iTermPlan(preferences([profile(guid: "A", font: nil, extra: extra)], defaultGuid: "A"))
        let ansi: [UInt32?] = (0...15).map { UInt32((Double($0) / 15 * 255).rounded()) << 16 }
        let palette = TerminalPalette(name: "iTerm2 colours", ansi: ansi, foreground: 0xFFFFFF, background: 0, cursor: 0xFF8000, selection: 0x808080)
        #expect(plan.settings == [PlannedSetting(.terminalPalette(palette), source: "the default profile's colours")])

        // Separate light and dark colours: the dark ones; another colour space is said to be read as sRGB.
        extra["Use Separate Colors for Light and Dark Mode"] = true
        extra["Background Color (Dark)"] = colour(0.2, 0.2, 0.2, space: "P3")
        let dark = try iTermPlan(preferences([profile(guid: "A", font: nil, extra: extra)], defaultGuid: "A"))
        let row = try #require(dark.settings.first)
        guard case .terminalPalette(let darkPalette) = row.setting else { throw CancellationError() }
        #expect(darkPalette.background == 0x333333 && darkPalette.foreground == 0xFFFFFF) // a colour without a dark one keeps its own
        #expect(row.source == "the default profile's colours (its Dark Mode ones)")
        #expect(row.note == "colours in Display P3 or a calibrated space are read as sRGB, so a few may look slightly different")

        // Components out of range or missing: that colour is left out.
        let odd = try iTermPlan(preferences([profile(guid: "A", font: nil, extra: [
            "Ansi 0 Color": colour(2, 0, 0), "Background Color": ["Red Component": 0.5],
        ])], defaultGuid: "A"))
        #expect(odd.settings.isEmpty)
    }

    @Test func iTermOptionKeys() {
        func row(_ left: Int, _ right: Int, us: Bool = true) -> PlannedSetting? {
            var profile = ImportITerm2.Profile()
            profile.leftOption = left
            profile.rightOption = right
            return ImportITerm2.optionAsMeta(profile, usKeyboard: us)
        }
        #expect(row(0, 0) == nil)
        #expect(row(0, 0, us: false) == nil)
        for (left, right) in [(1, 1), (2, 2), (1, 2), (2, 1)] {
            let planned = row(left, right)
            #expect(planned?.setting == .optionAsMeta(true))
            #expect(planned?.ticked == true && planned?.note == nil)
        }
        #expect(row(1, 2)?.source == "Option Key Sends Meta, Right Option Key Sends Esc+")

        let leftOnly = row(2, 0)
        #expect(leftOnly?.setting == .optionAsMeta(true) && leftOnly?.ticked == false)
        #expect(leftOnly?.note == "on in iTerm2 for Left Option only; Next Term can't set one side yet")
        let rightOnly = row(0, 1)
        #expect(rightOnly?.ticked == false)
        #expect(rightOnly?.note == "on in iTerm2 for Right Option only; Next Term can't set one side yet")

        // A layout that needs Option for symbols: never ticked, whatever iTerm2 says.
        let layout = row(2, 2, us: false)
        #expect(layout?.ticked == false)
        #expect(layout?.note == "your keyboard layout may need Option to type @ [ ] { }")
        #expect(row(0, 2, us: false)?.note == "on in iTerm2 for Right Option only; Next Term can't set one side yet; your keyboard layout may need Option to type @ [ ] { }")
    }

    @Test func iTermOptionKeysFromTheFile() throws {
        // Unset keys are iTerm2's default, Normal; values outside 0–2 or of the wrong type count as Normal.
        let cases: [(left: Any?, right: Any?, expected: ImportedSetting?, ticked: Bool)] = [
            (nil, nil, nil, true), (2, nil, .optionAsMeta(true), false), (nil, 1, .optionAsMeta(true), false),
            (7, 2, .optionAsMeta(true), false), ("2", "2", nil, true), (2, 2, .optionAsMeta(true), true),
        ]
        for testCase in cases {
            var values = profile(guid: "A", font: nil, left: nil, right: nil)
            values["Option Key Sends"] = testCase.left
            values["Right Option Key Sends"] = testCase.right
            let plan = try iTermPlan(preferences([values], defaultGuid: "A"))
            let option = plan.settings.first { $0.setting.key == "optionAsMeta" }
            #expect(option?.setting == testCase.expected)
            if testCase.expected != nil { #expect(option?.ticked == testCase.ticked) }
        }
        let planned = try iTermPlan(preferences([profile(guid: "A", font: nil, left: 2, right: 2)], defaultGuid: "A"), usKeyboard: false)
        #expect(planned.settings.first?.ticked == false)
    }

    @Test func iTermNeverReadsWhatItMustNot() throws {
        let root = preferences([profile(guid: "A", left: 2, right: 0)], defaultGuid: "A")
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        // What survives parsing is the allowlisted values and nothing else.
        let parsed = try #require(ImportITerm2.Preferences(data))
        var expected = ImportITerm2.Profile()
        expected.normalFont = "Monaco 12"
        expected.leftOption = 2
        expected.palette = fixtureColours
        expected.customDirectory = "No"
        expected.scrollbackLines = 1000
        #expect(parsed.profile == expected)
        #expect(parsed.globalKeyMappings == 2)

        let plan = try iTermPlan(root)
        for secret in ["AKIA", "hunter2", "secret-keyboard-text", "prod-db", "private-folder", "global-secret-text",
                       "sk-", "ai.internal", "/bin/zsh", "Profile A"] {
            #expect(!shown(plan).contains(secret), "\(secret) leaked into the plan")
        }

        // The keys v1 reads are none of those the design forbids, and none SecretGuard flags.
        let forbidden = ["Command", "Custom Command", "Triggers", "Keyboard Map", "Bound Hosts", "Working Directory"]
        for key in ImportITerm2.profileKeys + ImportITerm2.colourKeys {
            #expect(!forbidden.contains(key))
            #expect(!SecretGuard.isSecretKey(key), "\(key)")
            #expect(!key.hasPrefix("AI") && !key.lowercased().contains("api"))
        }
    }

    @Test func iTermReportsWhatComesLater() throws {
        func later(_ extra: [String: Any], colours: Bool = true) throws -> [SkippedItem] {
            var values = profile(guid: "A", font: nil, extra: extra)
            if !colours { values = values.filter { !$0.key.hasSuffix("Color") } }
            return try iTermPlan(preferences([values], defaultGuid: "A")).skipped
        }
        let keyMaps = SkippedItem("iTerm2 key mappings (2)", "terminal key mappings aren't brought over")
        // iTerm2's defaults (home folder, 1,000 lines) aren't news, and colours come over.
        #expect(try later([:]) == [keyMaps, paneNote])
        #expect(try later([:], colours: false) == [keyMaps, paneNote])

        #expect(try later(["Custom Directory": "Recycle"]).contains(SkippedItem("Custom Directory (Recycle)", "a start folder setting comes later")))
        #expect(try later(["Custom Directory": "Advanced"]).contains(SkippedItem("Custom Directory (Advanced)", "a start folder setting comes later")))
        #expect(try later(["Custom Directory": "/somewhere"]) == [keyMaps, paneNote])
        #expect(try later(["Scrollback Lines": 5000]).contains(SkippedItem("Scrollback Lines 5000", "a scrollback setting comes later")))
        #expect(try later(["Unlimited Scrollback": true]).contains(SkippedItem("Unlimited Scrollback", "a scrollback setting comes later")))
    }

    @Test func iTermOddFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = try writePlist(preferences([], defaultGuid: nil), home: home)
        let app = try #require(ImportITerm2.detect(home: home).first)
        let unreadable = SkippedItem("com.googlecode.iterm2.plist", "couldn't be read, so no settings came over")

        // No profile saved yet (a fresh iTerm2 keeps its default profile built in).
        var plan = ImportITerm2.plan(for: app, home: home)
        #expect(plan.settings.isEmpty)
        #expect(plan.skipped.first == SkippedItem("profiles", "iTerm2 has no saved profile yet, so no settings came over"))
        #expect(plan.skipped.last == paneNote)

        // Profiles that aren't dictionaries are passed over.
        _ = try writePlist(preferences([], defaultGuid: "B", extra: ["New Bookmarks": ["junk", 3, profile(guid: "B", font: "Monaco 13")] as [Any]]), home: home)
        #expect(ImportITerm2.plan(for: app, home: home).settings.first?.setting == .fontSize(13))

        // Not a plist, a plist that isn't a dictionary, an empty file, a missing file.
        for contents in [Data("not a plist".utf8), try PropertyListSerialization.data(fromPropertyList: ["a"], format: .binary, options: 0), Data()] {
            try contents.write(to: URL(fileURLWithPath: path))
            plan = ImportITerm2.plan(for: app, home: home)
            #expect(plan == ImportPlan(preset: .nextTerm, skipped: [unreadable, paneNote]))
        }
        try FileManager.default.removeItem(atPath: path)
        #expect(ImportITerm2.plan(for: app, home: home) == ImportPlan(preset: .nextTerm, skipped: [unreadable, paneNote]))

        // A named pipe is never opened.
        #expect(mkfifo(path, 0o600) == 0)
        #expect(ImportITerm2.detect(home: home).isEmpty)
        #expect(ImportITerm2.plan(for: app, home: home) == ImportPlan(preset: .nextTerm, skipped: [unreadable, paneNote]))

        // Another app's entry gets nothing from the iTerm2 reader.
        let zed = DetectedApp(kind: .zed, name: "Zed", configPath: path, lastUsed: nil)
        #expect(ImportITerm2.plan(for: zed, home: home) == ImportPlan(preset: .nextTerm))
    }

    // MARK: safety

    @Test func importersHaveNoNetworking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NextTermCore/ImportZedITerm.swift"), encoding: .utf8)
        for word in ["URLSession", "import Network", "NWConnection", "CFNetwork", "URLRequest", "Process(", "NSTask"] {
            #expect(!source.contains(word), "\(word)")
        }
        // Only a parsed enum value may name that one editor; no string the user sees does.
        let strings = source.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        #expect(!strings.contains { $0.localizedCaseInsensitiveContains("sublime") })
    }
}

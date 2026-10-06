import Foundation
import SQLite3
import Testing
@testable import NextTermCore

@Suite struct ImportVSCodeTests {
    static let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0LXVzZXIifQ.c2lnbmF0dXJlLXZhbHVl"

    /// A temp home. Names stay short: a 40-character run of letters and dashes looks like a token to SecretGuard.
    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-vsc-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func folder(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func user(_ home: String, _ name: String = "Code") throws -> String {
        try folder(home + "/Library/Application Support/\(name)/User")
    }

    func app(_ user: String, _ kind: ImportSourceKind = .vsCode, name: String = "VS Code", preset: KeymapPreset? = nil) -> DetectedApp {
        DetectedApp(kind: kind, name: name, configPath: user, lastUsed: nil, preset: preset)
    }

    /// The plan with only the test's own Applications folder searched for the app bundle.
    func plan(_ app: DetectedApp, home: String, usKeyboard: Bool = true) -> ImportPlan {
        ImportVSCode.plan(for: app, home: home, usKeyboard: usKeyboard, applications: [home + "/Applications"])
    }

    func settings(_ json: String, usKeyboard: Bool = true, appName: String = "VS Code") throws -> ImportVSCode.SettingsResult {
        let file = try #require(ImportVSCode.SettingsFile(json))
        return ImportVSCode.settingsPlan(file, appName: appName, usKeyboard: usKeyboard)
    }

    func row(_ result: ImportVSCode.SettingsResult, _ key: String) -> PlannedSetting? {
        result.settings.first { $0.setting.key == key }
    }

    /// A file URI the way VS Code writes one (percent-escaped, no trailing slash).
    func uri(_ path: String) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    func modified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    // MARK: SQLite fixtures

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// A state.vscdb as VS Code keeps it: ItemTable(key, value) in WAL mode, with sign-in tokens beside the
    /// recents (as in Cursor's). Returns the writer connection still open, unless `close`.
    @discardableResult
    func stateDB(_ path: String, entries: [[String: Any]]?, blob: Bool = false, close: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let schema = "PRAGMA journal_mode=WAL; CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        var rows = [("cursorAuth/accessToken", Self.token), ("cursorAuth/refreshToken", Self.token), ("workbench.panel.width", "300")]
        if let entries {
            let data = try JSONSerialization.data(withJSONObject: ["entries": entries], options: [.withoutEscapingSlashes])
            rows.insert(("history.recentlyOpenedPathsList", String(decoding: data, as: UTF8.self)), at: 1)
        }
        for (key, value) in rows {
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES (?1, ?2)", -1, &statement, nil) == SQLITE_OK)
            sqlite3_bind_text(statement, 1, key, -1, Self.transient)
            if blob {
                let bytes = Array(value.utf8)
                sqlite3_bind_blob(statement, 2, bytes, Int32(bytes.count), Self.transient)
            } else {
                sqlite3_bind_text(statement, 2, value, -1, Self.transient)
            }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        if close {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    // MARK: detection

    @Test func detectsTheFamilyByFolderNewestFirst() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let now = Date()
        let code = try user(home, "Code")
        try write("{}", to: code + "/settings.json")
        let cursor = try user(home, "Cursor")
        let devin = try user(home, "Devin")
        _ = try user(home, "Windsurf") // the old name: ignored while Devin's folder is there
        try folder(home + "/Library/Application Support/Code - Insiders") // no User folder: never opened
        try write("not a folder", to: home + "/Library/Application Support/VSCodium/User")
        try modified(code + "/settings.json", now.addingTimeInterval(-86400))
        try modified(code, now.addingTimeInterval(-5 * 86400))
        try modified(cursor, now)
        try modified(devin, now.addingTimeInterval(-2 * 86400))

        let found = ImportVSCode.detect(home: home)
        #expect(found.map(\.kind) == [.cursor, .vsCode, .devinDesktop])
        #expect(found.map(\.name) == ["Cursor", "VS Code", "Devin Desktop"])
        #expect(found.map(\.configPath) == [cursor, code, devin])
        #expect(found.allSatisfy { $0.preset == .vsCode })
        // The later of settings.json's date and the folder's.
        let codeUsed = try #require(found[1].lastUsed)
        #expect(abs(codeUsed.timeIntervalSince(now.addingTimeInterval(-86400))) < 2)
    }

    @Test func windsurfFolderWhenDevinIsAbsent() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let windsurf = try user(home, "Windsurf")
        let found = ImportVSCode.detect(home: home)
        #expect(found == [DetectedApp(kind: .devinDesktop, name: "Windsurf", configPath: windsurf, lastUsed: found.first?.lastUsed)])
        #expect(found.first?.lastUsed != nil)
    }

    @Test func detectsInsidersAndVSCodium() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try user(home, "Code - Insiders")
        _ = try user(home, "VSCodium")
        #expect(Set(ImportVSCode.detect(home: home).map(\.name)) == ["VS Code Insiders", "VSCodium"])
    }

    @Test func nothingInstalled() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(ImportVSCode.detect(home: home).isEmpty)
    }

    // MARK: font size

    @Test func fontSizeFromEditorSizeAndZoom() throws {
        func size(_ json: String) throws -> PlannedSetting? { row(try settings(json), "fontSize") }
        #expect(try size(#"{"editor.fontSize": 13}"#) == PlannedSetting(.fontSize(13), source: "editor.fontSize 13"))
        #expect(try size(#"{"editor.fontSize": 12, "window.zoomLevel": 1}"#)
                == PlannedSetting(.fontSize(14), source: "editor.fontSize 12 at window.zoomLevel 1")) // 14.4
        #expect(try size(#"{"window.zoomLevel": 2}"#)
                == PlannedSetting(.fontSize(17), source: "window.zoomLevel 2 with the default editor.fontSize 12")) // 17.28
        #expect(try size(#"{"window.zoomLevel": -1}"#)?.setting == .fontSize(10))
        #expect(try size(#"{"window.zoomLevel": 0.5}"#)?.setting == .fontSize(13)) // 13.15
        #expect(try size(#"{"editor.fontSize": 16, "window.zoomLevel": 3}"#)?.setting == .fontSize(28)) // 27.6
        #expect(try size(#"{"editor.fontSize": 13.5}"#)?.setting == .fontSize(14))
        #expect(try size(#"{"editor.fontSize": 60}"#)?.setting == .fontSize(32)) // clamped to Next Term's range
        #expect(try size(#"{"editor.fontSize": 7}"#)?.setting == .fontSize(8))
        #expect(try size(#"{"editor.fontSize": 14, "window.zoomLevel": 9}"#)?.setting == .fontSize(32))
        #expect(try size("{}") == nil) // nothing set: keep Next Term's
        #expect(try size(#"{"editor.lineHeight": 20}"#) == nil)
        #expect(try settings(#"{"editor.fontSize": 0}"#).settings.isEmpty) // VS Code's default
        #expect(try settings(#"{"editor.fontSize": 0}"#).skipped.isEmpty)

        let text = try settings(#"{"editor.fontSize": "14", "window.zoomLevel": "big"}"#)
        #expect(text.settings.isEmpty)
        #expect(text.skipped == [SkippedItem("editor.fontSize", "value not recognised"), SkippedItem("window.zoomLevel", "value not recognised")])
        let flag = try settings(#"{"editor.fontSize": true}"#)
        #expect(flag.settings.isEmpty && flag.skipped == [SkippedItem("editor.fontSize", "value not recognised")])
    }

    @Test func terminalFontSizeOnlyWithoutAnEditorSize() throws {
        let alone = try settings(#"{"terminal.integrated.fontSize": 15}"#)
        #expect(alone.settings == [PlannedSetting(.fontSize(15), source: "terminal.integrated.fontSize 15")])
        let zoomed = try settings(#"{"terminal.integrated.fontSize": 15, "window.zoomLevel": 1}"#)
        #expect(zoomed.settings == [PlannedSetting(.fontSize(18), source: "terminal.integrated.fontSize 15 at window.zoomLevel 1")])

        let differ = try settings(#"{"editor.fontSize": 14, "terminal.integrated.fontSize": 16}"#)
        #expect(differ.settings == [PlannedSetting(.fontSize(14), source: "editor.fontSize 14")])
        #expect(differ.skipped == [SkippedItem("terminal.integrated.fontSize", "one font size for editor and terminal today; the editor's size is used")])
        let same = try settings(#"{"editor.fontSize": 14, "terminal.integrated.fontSize": 14}"#)
        #expect(same.settings.count == 1 && same.skipped.isEmpty)
    }

    // MARK: line height

    @Test func lineHeightConversion() throws {
        func height(_ json: String) throws -> ImportedSetting? { row(try settings(json), "editorLineHeight")?.setting }
        #expect(try height(#"{"editor.lineHeight": 0}"#) == nil) // VS Code's default, 1.5 × size
        #expect(try settings(#"{"editor.lineHeight": 0}"#).skipped.isEmpty)
        // A multiple of the size: 1.5 × 14 = 21 px over 1.2 × 14 = 16.8 → 1.25.
        #expect(try height(#"{"editor.fontSize": 14, "editor.lineHeight": 1.5}"#) == .editorLineHeight(1.25))
        // VS Code rounds the pixels: 1.5 × 13 = 19.5 → 20 px over 15.6 → 1.28 → 1.3.
        #expect(try height(#"{"editor.fontSize": 13, "editor.lineHeight": 1.5}"#) == .editorLineHeight(1.3))
        // Pixels: 22 over 16.8 → 1.31 → 1.3; at the default size 12, 22 over 14.4 → 1.53 → 1.55.
        #expect(try height(#"{"editor.fontSize": 14, "editor.lineHeight": 22}"#) == .editorLineHeight(1.3))
        #expect(try height(#"{"editor.lineHeight": 22}"#) == .editorLineHeight(1.55))
        // Window zoom scales the font and the lines alike, so it cancels: 18 over 1.2 × 12.
        #expect(try height(#"{"editor.fontSize": 12, "window.zoomLevel": 1, "editor.lineHeight": 18}"#) == .editorLineHeight(1.25))
        // Measured against the editor's size, not a terminal size that stands in for it.
        #expect(try height(#"{"terminal.integrated.fontSize": 16, "editor.lineHeight": 1.5}"#) == .editorLineHeight(1.25))
        // Clamped to 1.0–2.0.
        #expect(try height(#"{"editor.lineHeight": 60}"#) == .editorLineHeight(2.0))
        #expect(try height(#"{"editor.lineHeight": 4}"#) == .editorLineHeight(2.0)) // 4 × 12 = 48 px
        #expect(try height(#"{"editor.fontSize": 14, "editor.lineHeight": 8}"#) == .editorLineHeight(1.0))
        #expect(try height(#"{"editor.lineHeight": 1}"#) == .editorLineHeight(1.0))
        #expect(try height(#"{"editor.lineHeight": -3}"#) == nil)
        #expect(try row(settings(#"{"editor.lineHeight": 22}"#), "editorLineHeight")?.source == "editor.lineHeight 22")
        let text = try settings(#"{"editor.lineHeight": "tall"}"#)
        #expect(text.settings.isEmpty && text.skipped == [SkippedItem("editor.lineHeight", "value not recognised")])
    }

    // MARK: word wrap, Option, panels

    @Test func wordWrap() throws {
        #expect(try settings(#"{"editor.wordWrap": "off"}"#).settings == [PlannedSetting(.softWrap(false), source: "editor.wordWrap off")])
        #expect(try settings(#"{"editor.wordWrap": "on"}"#).settings == [PlannedSetting(.softWrap(true), source: "editor.wordWrap on")])
        #expect(try settings(#"{"editor.wordWrap": true}"#).settings.first?.setting == .softWrap(true)) // an old file
        for mode in ["wordWrapColumn", "bounded"] {
            let result = try settings(#"{"editor.wordWrap": "\#(mode)", "editor.wordWrapColumn": 100}"#)
            #expect(result.settings == [PlannedSetting(.softWrap(true), source: "editor.wordWrap \(mode)")])
            #expect(result.skipped.first == SkippedItem("editor.wordWrap \(mode)", "Next Term wraps at the window edge; a wrap column isn't supported"))
        }
        let odd = try settings(#"{"editor.wordWrap": "sideways"}"#)
        #expect(odd.settings.isEmpty && odd.skipped == [SkippedItem("editor.wordWrap", "value not recognised")])
    }

    @Test func optionAsMetaFollowsTheKeyboardPolicy() throws {
        let json = #"{"terminal.integrated.macOptionIsMeta": true}"#
        #expect(try settings(json, usKeyboard: true).settings
                == [PlannedSetting(.optionAsMeta(true), source: "terminal.integrated.macOptionIsMeta true")])
        let other = try #require(try settings(json, usKeyboard: false).settings.first)
        #expect(other.setting == .optionAsMeta(true) && !other.ticked)
        #expect(other.note == ImportVSCode.optionNote && other.note?.contains("@ [ ] { }") == true)
        let off = try #require(try settings(#"{"terminal.integrated.macOptionIsMeta": false}"#).settings.first)
        #expect(off.setting == .optionAsMeta(false) && off.ticked && off.note == nil)
        let offElsewhere = try #require(try settings(#"{"terminal.integrated.macOptionIsMeta": false}"#, usKeyboard: false).settings.first)
        #expect(!offElsewhere.ticked && offElsewhere.note != nil)
        #expect(try settings(#"{"terminal.integrated.macOptionIsMeta": "yes"}"#).skipped
                == [SkippedItem("terminal.integrated.macOptionIsMeta", "value not recognised")])
    }

    @Test func sidebarSideAndPanelPosition() throws {
        #expect(try settings(#"{"workbench.sideBar.location": "right"}"#).settings
                == [PlannedSetting(.sidebarSide("right"), source: "workbench.sideBar.location right")])
        #expect(try settings(#"{"workbench.sideBar.location": "left"}"#).settings.first?.setting == .sidebarSide("left"))
        #expect(try settings(#"{"workbench.sideBar.location": "center"}"#).skipped
                == [SkippedItem("workbench.sideBar.location", "value not recognised")])
        for position in ["bottom", "right", "left", "top"] {
            #expect(try settings(#"{"workbench.panel.defaultLocation": "\#(position)"}"#).settings
                    == [PlannedSetting(.terminalPosition(position), source: "workbench.panel.defaultLocation \(position)",
                                       note: "VS Code's default for new workspaces")])
        }
        #expect(try settings(#"{"workbench.panel.defaultLocation": "right"}"#, appName: "Cursor").settings.first?.note
                == "Cursor's default for new workspaces")
        #expect(try settings(#"{"workbench.panel.defaultLocation": "middle"}"#).skipped
                == [SkippedItem("workbench.panel.defaultLocation", "value not recognised")])
    }

    @Test func everyMappedSettingTogether() throws {
        let result = try settings("""
            {
              "editor.fontSize": 13, "window.zoomLevel": 1, "editor.lineHeight": 1.6, "editor.wordWrap": "on",
              "terminal.integrated.macOptionIsMeta": true, "workbench.sideBar.location": "right",
              "workbench.panel.defaultLocation": "left"
            }
            """)
        #expect(result.settings.map(\.setting) == [.fontSize(16), .editorLineHeight(1.35), .softWrap(true), .optionAsMeta(true),
                                                   .sidebarSide("right"), .terminalPosition("left")])
        #expect(result.skipped.isEmpty)
    }

    // MARK: what is left out

    @Test func skippedOnlyForKeysTheUserSet() throws {
        let result = try settings("""
            // User settings
            {
              /* sizes */
              "editor.fontSize": 14,
              "editor.fontFamily": "JetBrains Mono, Menlo, monospace",
              "terminal.integrated.fontFamily": "MesloLGS NF",
              "workbench.colorTheme": "One Dark Pro",
              "workbench.colorCustomizations": { "terminal.background": "#000000" },
              "editor.tabSize": 2,
              "editor.insertSpaces": true,
              "files.trimTrailingWhitespace": true,
              "files.exclude": { "**/.git": true, },
              "search.exclude": { "**/node_modules": true },
              "editor.cursorBlinking": "phase",
              "terminal.integrated.cursorStyle": "line",
              "terminal.integrated.scrollback": 50000,
              "[python]": { "editor.tabSize": 4, },
              "editor.minimap.enabled": false,
              "git.autofetch": true,
            }
            """)
        #expect(result.settings == [PlannedSetting(.fontSize(14), source: "editor.fontSize 14")])
        #expect(result.skipped == [
            SkippedItem("editor.fontFamily", "font choice is coming"),
            SkippedItem("terminal.integrated.fontFamily", "font choice is coming"),
            SkippedItem("workbench.colorTheme", "colour themes come later"),
            SkippedItem("workbench.colorCustomizations", "colour themes come later"),
            SkippedItem("editor.tabSize", "tab width and spaces come later"),
            SkippedItem("editor.insertSpaces", "tab width and spaces come later"),
            SkippedItem("files.trimTrailingWhitespace", "clean-up on save comes later"),
            SkippedItem("files.exclude", "hiding files by pattern comes later"),
            SkippedItem("search.exclude", "hiding files by pattern comes later"),
            SkippedItem("editor.cursorBlinking", "cursor style comes later"),
            SkippedItem("terminal.integrated.cursorStyle", "cursor style comes later"),
            SkippedItem("terminal.integrated.scrollback", "scrollback length comes later"),
            SkippedItem("[python]", "per-language settings come later"),
            SkippedItem("2 other settings", "Next Term has no matching setting"),
        ])
        #expect(try settings(#"{"editor.fontSize": 13}"#).skipped.isEmpty)
        #expect(try settings(#"{"editor.minimap.enabled": false}"#).skipped == [SkippedItem("1 other setting", "Next Term has no matching setting")])
    }

    @Test func secretAndCommandKeysAreNeverRead() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        try write("""
            {
              "terminal.integrated.env.osx": { "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789" },
              "http.proxy": "http://me:hunter2@proxy.example.com:8080",
              "http.proxyAuthorization": "Basic aHVudGVyMg==",
              "terminal.integrated.profiles.osx": { "zsh": { "path": "/bin/zsh", "args": ["-l"] } },
              "terminal.integrated.defaultProfile.osx": "zsh",
              "terminal.integrated.shellArgs.osx": ["--login", "secret-arg"],
              "terminal.integrated.automationProfile.osx": { "path": "/opt/bin/robot" },
              "openai.apiKey": "sk-proj-abcdefghijklmnopqrstuvwx",
              "github.token": "plain-token-value",
              "workbench.sideBar.location": "sk-abcdefghijklmnopqrstuvwxyz",
              "editor.fontFamily": "AKIAABCDEFGHIJKLMNOP",
              "[sk-abcdefghijklmnopq]": { "editor.tabSize": 2 }
            }
            """, to: user + "/settings.json")
        let plan = self.plan(app(user), home: home)
        #expect(plan.settings.isEmpty)
        let shown = String(describing: plan)
        for value in ["ghp_", "hunter2", "aHVudGVyMg", "/bin/zsh", "secret-arg", "robot", "sk-proj", "plain-token-value",
                      "sk-abc", "AKIA", "--login"] {
            #expect(!shown.contains(value), "\(value) reached the plan")
        }
        #expect(plan.skipped == [
            SkippedItem("workbench.sideBar.location", "value not recognised"), // mapped keys first, then the rest in file order
            SkippedItem("terminal.integrated.env.osx", "never imported: can hold secrets"),
            SkippedItem("http.proxy", "never imported: can hold secrets"),
            SkippedItem("http.proxyAuthorization", "never imported: can hold secrets"),
            SkippedItem("terminal.integrated.profiles.osx", "never imported: runs commands"),
            SkippedItem("terminal.integrated.defaultProfile.osx", "never imported: runs commands"),
            SkippedItem("terminal.integrated.shellArgs.osx", "never imported: runs commands"),
            SkippedItem("terminal.integrated.automationProfile.osx", "never imported: runs commands"),
            SkippedItem("openai.apiKey", "never imported: can hold secrets"),
            SkippedItem("github.token", "never imported: can hold secrets"),
            SkippedItem("editor.fontFamily", "font choice is coming"),
            SkippedItem("a setting", "looked like a credential"),
        ])
        // A secret key is never converted, even when asked for by name.
        let file = try #require(ImportVSCode.SettingsFile(try String(contentsOfFile: user + "/settings.json", encoding: .utf8)))
        #expect(file.value("terminal.integrated.env.osx") == nil && file.value("openai.apiKey") == nil)
        #expect(file.value("workbench.sideBar.location") as? String == "sk-abcdefghijklmnopqrstuvwxyz") // read, then refused as a string
        #expect(ImportVSCode.string(file.value("workbench.sideBar.location")) == nil)
    }

    @Test func filesBesideSettingsAreReportedNotOpened() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        try write(#"{"servers": {"x": {"env": {"API_KEY": "sk-live-abcdefghijklmnop"}}}}"#, to: user + "/mcp.json")
        try write(#"{"tasks": [{"command": "deploy --token sk-live-abcdefghijklmnop"}]}"#, to: user + "/tasks.json")
        try write("{}", to: user + "/launch.json")
        try write("{}", to: user + "/snippets/swift.json")
        let plan = self.plan(app(user), home: home)
        #expect(plan.skipped == [
            SkippedItem("mcp.json", "never imported: runs commands and can hold secrets"),
            SkippedItem("tasks.json", "never imported: runs commands"),
            SkippedItem("launch.json", "never imported: runs commands"),
            SkippedItem("snippets", "snippets aren't supported"),
        ])
        #expect(!String(describing: plan).contains("sk-live"))
        try FileManager.default.removeItem(atPath: user + "/snippets/swift.json")
        #expect(!self.plan(app(user), home: home).skipped.contains { $0.item == "snippets" }) // empty folder
    }

    @Test func oddSettingsFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        let path = user + "/settings.json"
        func result() -> ImportVSCode.SettingsResult { ImportVSCode.settingsPlan(user: user, appName: "VS Code", usKeyboard: true) }
        let unreadable = [SkippedItem("settings.json", "couldn't be read as JSON; settings were skipped")]

        #expect(result().settings.isEmpty && result().skipped.isEmpty) // missing
        try write("", to: path)
        #expect(result().settings.isEmpty && result().skipped.isEmpty) // VS Code treats an empty file as {}
        try write("\u{FEFF}  \n", to: path)
        #expect(result().skipped.isEmpty)
        try write(#"{ "editor.fontSize": 14 "#, to: path)
        #expect(result().settings.isEmpty && result().skipped == unreadable)
        try write(#"[{"editor.fontSize": 14}]"#, to: path)
        #expect(result().skipped == unreadable)
        try write("\u{FEFF}{\"editor.fontSize\": 15}", to: path) // a byte-order mark
        #expect(result().settings.first?.setting == .fontSize(15))
        try Data([0xFF, 0xFE, 0x7B, 0x7D]).write(to: URL(fileURLWithPath: path))
        #expect(result().skipped == [SkippedItem("settings.json", "couldn't be read")])
        try FileManager.default.removeItem(atPath: path)
        try folder(path) // a folder where the file should be
        #expect(result().settings.isEmpty && result().skipped.isEmpty)
        try FileManager.default.removeItem(atPath: path)
        #expect(mkfifo(path, 0o644) == 0) // a pipe: opening it would wait for a writer forever
        #expect(result().settings.isEmpty && result().skipped.isEmpty)
    }

    // MARK: profiles

    @Test func onlyTheDefaultProfileIsRead() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        try write(#"{"editor.fontSize": 13}"#, to: user + "/settings.json")
        try write(#"{"editor.fontSize": 20}"#, to: user + "/profiles/-1a2b3c/settings.json")
        try write("""
            {
              "windowsState": { "lastActiveWindow": { "folder": "file:///Users/me/app" } },
              "userDataProfiles": [
                { "location": "-1a2b3c", "name": "Work", "icon": "briefcase", "useDefaultFlags": { "keybindings": true } },
                { "location": "-4d5e6f", "name": "sk-abcdefghijklmnopqrstu" }
              ],
              "profileAssociations": { "workspaces": { "file:///Users/me/app": "-1a2b3c" } }
            }
            """, to: user + "/globalStorage/storage.json")
        let plan = self.plan(app(user), home: home)
        #expect(plan.settings == [PlannedSetting(.fontSize(13), source: "editor.fontSize 13")])
        #expect(plan.skipped == [SkippedItem("2 other profiles", "only the default profile is read; other profiles: choose in a later version")])
        #expect(!String(describing: plan).contains("Work") && !String(describing: plan).contains("sk-abc"))

        try write(#"{"userDataProfiles": [{"location": "x", "name": "Solo"}]}"#, to: user + "/globalStorage/storage.json")
        #expect(self.plan(app(user), home: home).skipped.first?.item == "1 other profile")
        try write(#"{"userDataProfiles": []}"#, to: user + "/globalStorage/storage.json")
        #expect(self.plan(app(user), home: home).skipped.isEmpty)
        try write("{ not json", to: user + "/globalStorage/storage.json")
        #expect(self.plan(app(user), home: home).skipped.isEmpty)
    }

    // MARK: recent projects

    @Test func recentsReadInPlaceFromGlobalStorage() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        let code = try folder(home + "/Code")
        let appFolder = try folder(code + "/app")
        let spaced = try folder(code + "/My Project")
        let web = try folder(code + "/web")
        let real = try folder(code + "/real")
        let other = try folder(code + "/other")
        let token = try folder(code + "/ghp_" + String(repeating: "A", count: 36))
        try FileManager.default.createSymbolicLink(atPath: code + "/alias", withDestinationPath: real)
        try write("""
            {
              // a team workspace
              "folders": [ { "path": "web" }, { "path": "../Code/real" }, { "uri": "file:///elsewhere" }, ],
              "settings": { "terminal.integrated.env.osx": { "TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789" } },
            }
            """, to: code + "/team.code-workspace")
        try write(#"{"folders": [{"uri": "\#(uri(other))"}]}"#, to: code + "/solo.code-workspace")
        let viaVar = home.hasPrefix("/private/") ? String(home.dropFirst("/private".count)) + "/Code/alias" : code + "/alias"
        let entries: [[String: Any]] = [
            ["folderUri": uri(appFolder)],
            ["fileUri": uri(code + "/notes.md")],
            ["folderUri": uri(spaced), "label": "my label"],
            ["folderUri": "vscode-remote://ssh-remote%2Bbox/home/me/x", "remoteAuthority": "ssh-remote+box"],
            ["folderUri": "vscode-vfs://github/me/repo"],
            ["folderUri": uri(code + "/gone")],
            ["workspace": ["id": "abc", "configPath": uri(code + "/team.code-workspace")]],
            ["folderUri": uri(appFolder)],
            ["folderUri": uri(viaVar)],
            ["workspace": ["id": "def", "configPath": uri(code + "/solo.code-workspace")]],
            ["workspace": ["id": "ghi", "configPath": uri(code + "/missing.code-workspace")]],
            ["folderUri": uri(token)],
            ["folderUri": "file://server/share/x"],
        ]
        let databaseFolder = user + "/globalStorage"
        let writer = try stateDB(databaseFolder + "/state.vscdb", entries: entries)
        defer { sqlite3_close(writer) }
        try write("backup", to: databaseFolder + "/state.vscdb.backup")
        let before = try FileManager.default.contentsOfDirectory(atPath: databaseFolder).sorted()
        let databaseDate = try FileManager.default.attributesOfItem(atPath: databaseFolder + "/state.vscdb")[.modificationDate] as? Date

        let plan = self.plan(app(user, .cursor, name: "Cursor"), home: home)
        #expect(plan.recentProjects == [appFolder, spaced, web, real, other])
        #expect(plan.skipped == [
            SkippedItem("team.code-workspace", "only a workspace's first folder comes over (2 more folders left out)"),
            SkippedItem("3 remote projects", "remote and virtual folders aren't imported"),
            SkippedItem("1 recent project", "looked like a credential"),
        ])
        #expect(!String(describing: plan).contains("eyJ") && !String(describing: plan).contains("ghp_"))
        // Read in place: nothing copied or added beside it, and the database untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: databaseFolder).sorted() == before)
        #expect(try FileManager.default.attributesOfItem(atPath: databaseFolder + "/state.vscdb")[.modificationDate] as? Date == databaseDate)
    }

    @Test func recentsAtMostTwentyNewestFirst() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        let folders = try (0..<25).map { try folder(home + "/p/\(String(format: "%02d", $0))") }
        let entries = [["folderUri": uri(home + "/p/missing")]] + folders.map { ["folderUri": uri($0)] }
        try stateDB(user + "/globalStorage/state.vscdb", entries: entries, blob: true, close: true)
        #expect(plan(app(user), home: home).recentProjects == Array(folders.prefix(20)))
    }

    @Test func walDatabaseWithNoWriterOpen() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        let project = try folder(home + "/app")
        let path = user + "/globalStorage/state.vscdb"
        try stateDB(path, entries: [["folderUri": uri(project)]], close: true)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        // macOS keeps -wal and -shm after the last close (as Cursor's are on a Mac where it isn't running).
        #expect(plan(app(user), home: home).recentProjects == [project])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)

        // With both gone, a read-only open fails (it can't create the -shm); with no -wal, the file holds every
        // committed row, so the read goes on as immutable, and still adds nothing beside the database.
        try FileManager.default.removeItem(atPath: path + "-wal")
        try FileManager.default.removeItem(atPath: path + "-shm")
        #expect(plan(app(user), home: home).recentProjects == [project])
        #expect(try FileManager.default.contentsOfDirectory(atPath: user + "/globalStorage") == ["state.vscdb"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)

        // An empty -wal without a -shm reads normally.
        try Data().write(to: URL(fileURLWithPath: path + "-wal"))
        #expect(plan(app(user), home: home).recentProjects == [project])

        // A -wal with frames but no -shm: the reader makes the -shm (as any reader may) and reads the log
        // normally, without the immutable fallback, and without writing the database.
        let cursor = try self.user(home, "Cursor")
        let other = cursor + "/globalStorage/state.vscdb"
        let writer = try stateDB(other, entries: [["folderUri": uri(project)]])
        let frames = try Data(contentsOf: URL(fileURLWithPath: other + "-wal"))
        #expect(!frames.isEmpty)
        sqlite3_close(writer)
        try FileManager.default.removeItem(atPath: other + "-shm")
        try frames.write(to: URL(fileURLWithPath: other + "-wal"))
        let file = try Data(contentsOf: URL(fileURLWithPath: other))
        #expect(plan(app(cursor, .cursor, name: "Cursor"), home: home).recentProjects == [project])
        #expect(try Data(contentsOf: URL(fileURLWithPath: other)) == file)
        #expect(try Data(contentsOf: URL(fileURLWithPath: other + "-wal")) == frames)
    }

    @Test func recentsFromSharedStorageNamedByProductJSON() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        let shared = try folder(home + "/shared-one")
        let older = try folder(home + "/older-one")
        try write("""
            { "nameShort": "Code", "aiConfig": { "ariaKey": "\(Self.token)" }, "sharedDataFolderName": ".vscode-shared-test" }
            """, to: home + "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json")
        let writer = try stateDB(home + "/.vscode-shared-test/sharedStorage/state.vscdb", entries: [["folderUri": uri(shared)]])
        defer { sqlite3_close(writer) }
        try stateDB(user + "/globalStorage/state.vscdb", entries: [["folderUri": uri(older)]], close: true)
        let plan = self.plan(app(user), home: home)
        #expect(plan.recentProjects == [shared])
        #expect(plan.skipped.isEmpty)
        #expect(ImportVSCode.sharedDataFolderName(bundles: ["Visual Studio Code.app"], applications: [home + "/Applications"]) == ".vscode-shared-test")
    }

    @Test func sharedStorageWithoutTheKeyFallsBackToGlobalStorage() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        let older = try folder(home + "/older-one")
        try write(#"{"sharedDataFolderName": ".vscode-shared-test"}"#, to: home + "/Applications/Visual Studio Code.app/Contents/Resources/app/product.json")
        try stateDB(home + "/.vscode-shared-test/sharedStorage/state.vscdb", entries: nil, close: true)
        try stateDB(user + "/globalStorage/state.vscdb", entries: [["folderUri": uri(older)]], close: true)
        let plan = self.plan(app(user), home: home)
        #expect(plan.recentProjects == [older] && plan.skipped.isEmpty)
    }

    @Test func missingSharedStorageIsSaidAndGlobalStorageUsed() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home, "Code - Insiders")
        let older = try folder(home + "/older-one")
        try write(#"{"sharedDataFolderName": ".vscode-insiders-shared"}"#,
                  to: home + "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/product.json")
        try stateDB(user + "/globalStorage/state.vscdb", entries: [["folderUri": uri(older)]], close: true)
        let plan = self.plan(app(user, .vsCodeInsiders, name: "VS Code Insiders"), home: home)
        #expect(plan.recentProjects == [older])
        #expect(plan.skipped == [SkippedItem("recent projects in ~/.vscode-insiders-shared/sharedStorage",
                                             "not found where VS Code Insiders keeps them; choose the file to bring them over")])
    }

    @Test func productJSONWithoutAUsableName() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let product = home + "/Applications/Cursor.app/Contents/Resources/app/product.json"
        let applications = [home + "/Applications"]
        #expect(ImportVSCode.sharedDataFolderName(bundles: ["Cursor.app"], applications: applications) == nil) // no app
        try write(#"{"nameShort": "Cursor", "dataFolderName": ".cursor"}"#, to: product)
        #expect(ImportVSCode.sharedDataFolderName(bundles: ["Cursor.app"], applications: applications) == nil)
        for bad in ["../escape", "", "a/b", ".."] {
            try write(#"{"sharedDataFolderName": "\#(bad)"}"#, to: product)
            #expect(ImportVSCode.sharedDataFolderName(bundles: ["Cursor.app"], applications: applications) == nil)
        }
        try write("{ broken", to: product)
        #expect(ImportVSCode.sharedDataFolderName(bundles: ["Cursor.app"], applications: applications) == nil)
        // Devin Desktop's bundle name isn't documented: both likely names are tried.
        try write(#"{"sharedDataFolderName": ".devin-shared"}"#, to: home + "/Applications/Devin Desktop.app/Contents/Resources/app/product.json")
        #expect(ImportVSCode.sharedDataFolderName(bundles: ["Devin.app", "Devin Desktop.app"], applications: applications) == ".devin-shared")
    }

    @Test func unreadableDatabaseSaysWhy() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        try write("this is not a database, just text that is long enough to have a header", to: user + "/globalStorage/state.vscdb")
        let plan = self.plan(app(user, .cursor, name: "Cursor"), home: home)
        #expect(plan.recentProjects.isEmpty)
        #expect(plan.skipped == [SkippedItem("recent projects", "couldn't be read; close Cursor and try again")])

        // A database without the table, and one without the key.
        let other = try self.user(home, "VSCodium")
        try folder(other + "/globalStorage")
        var db: OpaquePointer?
        #expect(sqlite3_open(other + "/globalStorage/state.vscdb", &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE other (x);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(self.plan(app(other, .vsCodium, name: "VSCodium"), home: home).skipped
                == [SkippedItem("recent projects", "couldn't be read; close VSCodium and try again")])
        let empty = try self.user(home, "Cursor")
        try stateDB(empty + "/globalStorage/state.vscdb", entries: nil, close: true)
        let none = self.plan(app(empty, .cursor, name: "Cursor"), home: home)
        #expect(none.recentProjects.isEmpty && none.skipped.isEmpty)
    }

    @Test func recentsValueShapes() throws {
        #expect(ImportVSCode.recentProjects(Data("not json".utf8)).skipped == [SkippedItem("recent projects", "couldn't be read")])
        #expect(ImportVSCode.recentProjects(Data(#"{"workspaces3": []}"#.utf8)).skipped == [SkippedItem("recent projects", "couldn't be read")])
        #expect(ImportVSCode.recentProjects(Data(#"{"entries": [1, "x", {}]}"#.utf8)).paths.isEmpty)
        #expect(ImportVSCode.localPath("file:///Users/me/My%20Project") == "/Users/me/My Project")
        #expect(ImportVSCode.localPath("file://localhost/Users/me/x") == "/Users/me/x")
        #expect(ImportVSCode.localPath("file://server/share") == nil)
        #expect(ImportVSCode.localPath("vscode-remote://ssh-remote%2Bbox/x") == nil)
        #expect(ImportVSCode.localPath("not a uri") == nil)
    }

    @Test func untitledWorkspaceIsNamedPlainly() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let one = try folder(home + "/one")
        let two = try folder(home + "/two")
        let file = home + "/Library/Application Support/Code/Workspaces/1700000000000/workspace.json"
        try write(#"{"folders": [{"path": "\#(one)"}, {"path": "\#(two)"}]}"#, to: file)
        let recents = ImportVSCode.recentProjects(try JSONSerialization.data(withJSONObject: ["entries": [["workspace": ["id": "1", "configPath": uri(file)]]]]))
        #expect(recents.paths == [one])
        #expect(recents.skipped == [SkippedItem("an untitled workspace", "only a workspace's first folder comes over (1 more folder left out)")])
    }

    @Test func theOnlyQueryIsOneKeyedSelect() throws {
        #expect(ImportVSCode.itemQuery == "SELECT value FROM ItemTable WHERE key = ?1")
        #expect(!ImportVSCode.itemQuery.contains("*"))
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/Library/Application Support/Code/User/globalStorage/state.vscdb"
        let writer = try stateDB(path, entries: [["folderUri": "file:///x"]])
        defer { sqlite3_close(writer) }
        guard case .value(let data) = ImportVSCode.readItem(path, key: ImportVSCode.recentsKey) else {
            Issue.record("no value")
            return
        }
        #expect(String(decoding: data, as: UTF8.self).contains("file:///x"))
        #expect(ImportVSCode.readItem(path, key: "no.such.key") == .missing)
        #expect(ImportVSCode.readItem(home + "/nothing.vscdb", key: ImportVSCode.recentsKey) == .failed)
    }

    // MARK: safety and the public entry points

    @Test func noNetworkingInTheImporter() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NextTermCore/ImportVSCode.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("URLSession") && !text.contains("import Network") && !text.contains("CFNetwork"))
        let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }
        #expect(imports == ["import Foundation", "import SQLite3"])
    }

    @Test func pathsAreCheckedAComponentAtATime() {
        let deep = "/Users/me/Code/next-term-landing/src/components"
        #expect(SecretGuard.looksSecret(deep)) // one long run as a whole
        #expect(!SecretGuard.pathLooksSecret(deep))
        #expect(SecretGuard.pathLooksSecret("/Users/me/ghp_" + String(repeating: "a", count: 36)))
        #expect(SecretGuard.pathLooksSecret("/Users/me/sk-abcdefghijklmnop/app"))
    }

    @Test func otherSourcesAndPresets() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home)
        try write(#"{"editor.fontSize": 13}"#, to: user + "/settings.json")
        let jetBrains = DetectedApp(kind: .jetBrains, name: "PhpStorm 2026.1", configPath: user, lastUsed: nil)
        #expect(plan(jetBrains, home: home) == ImportPlan(preset: .jetBrains))
        // The detected app's keymap decides the preset (an IntelliJ keybindings extension can point elsewhere).
        let cursor = self.plan(app(user, .cursor, name: "Cursor", preset: .jetBrains), home: home)
        #expect(cursor.preset == .jetBrains && cursor.settings.count == 1)
        #expect(plan(app(user), home: home).preset == .vsCode)
    }

    @Test func publicEntryPointsWithATempHome() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let user = try user(home, "VSCodium")
        try write(#"{"editor.fontSize": 15, "editor.wordWrap": "off"}"#, to: user + "/settings.json")
        let project = try folder(home + "/proj")
        try stateDB(user + "/globalStorage/state.vscdb", entries: [["folderUri": uri(project)]], close: true)
        let found = try #require(ImportVSCode.detect(home: home).first)
        let plan = ImportVSCode.plan(for: found, home: home, usKeyboard: false)
        #expect(plan.preset == .vsCode)
        #expect(plan.settings.map(\.setting) == [.fontSize(15), .softWrap(false)])
        #expect(plan.recentProjects == [project])
    }
}
